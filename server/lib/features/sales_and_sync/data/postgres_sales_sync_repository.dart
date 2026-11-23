import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:core_contracts/core_contracts.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../../inventory_and_purchases/application/purchase_invoice_posting.dart';
import '../../inventory_and_purchases/application/purchase_return_posting.dart';
import '../../inventory_and_purchases/data/postgres_purchase_invoice_posting_repository.dart';
import '../../inventory_and_purchases/data/postgres_purchase_return_posting_repository.dart';
import '../../inventory_and_purchases/data/postgres_inventory_approval_repository.dart';
import '../../inventory_and_purchases/domain/purchase_and_fefo_calculator.dart';
import '../domain/sales_sync_domain.dart';

/// PostgreSQL implementation for sale posting and batch synchronization.
class PostgresSalesSyncRepository implements SalesSyncRepository {
  /// Creates the repository around an opened PostgreSQL connection.
  PostgresSalesSyncRepository(this._connection);

  final PostgreSQLConnection _connection;
  static const Uuid _uuid = Uuid();

  /// Lists branch invoices and expands each invoice's lines and payments.
  @override
  Future<List<Map<String, Object?>>> listSalesInvoices({
    required String branchId,
    DateTime? from,
    DateTime? to,
    String? cursor,
    int limit = 50,
  }) async {
    final invoiceRows = await _connection.mappedResultsQuery(
      '''SELECT id::text AS id, invoice_no AS "invoiceNo",
                customer_party_id AS "customerPartyId", price_tier AS "priceTier",
                net_total::text AS "netTotal", paid_total::text AS "paidTotal",
                change_returned::text AS "changeReturned",
                remaining_alayh::text AS "remainingAlayh",
                invoice_date AS "createdAt"
         FROM sales_invoices
         WHERE branch_id = @branch
           AND (@from::timestamptz IS NULL OR invoice_date >= @from)
           AND (@to::timestamptz IS NULL OR invoice_date <= @to)
           AND (@cursor::timestamptz IS NULL OR invoice_date < @cursor)
         ORDER BY invoice_date DESC, id DESC
         LIMIT @limit''',
      substitutionValues: {
        'branch': branchId,
        'from': from?.toUtc(),
        'to': to?.toUtc(),
        'cursor': cursor == null ? null : DateTime.parse(cursor).toUtc(),
        'limit': limit,
      },
    );
    final result = <Map<String, Object?>>[];
    for (final invoiceRow in invoiceRows) {
      final invoice = _flatten(invoiceRow);
      final id = invoice['id'] as String;
      final itemRows = await _connection.mappedResultsQuery(
        '''SELECT id::text AS id, product_id AS "productId",
                  barcode, unit_name AS "unitName", qty_sold::text AS "qtySold",
                  conversion_factor::text AS "conversionFactor",
                  qty_base::text AS "qtyBase", unit_price::text AS "unitPrice",
                  line_total::text AS "lineTotal"
           FROM sales_invoice_items WHERE invoice_id = @invoice ORDER BY id''',
        substitutionValues: {'invoice': id},
      );
      final paymentRows = await _connection.mappedResultsQuery(
        '''SELECT id::text AS id, method, amount::text AS amount,
                  cash_account_id AS "cashAccountId",
                  wallet_provider AS "walletProvider",
                  wallet_ref_no AS "walletRefNo"
           FROM sales_payments WHERE invoice_id = @invoice ORDER BY id''',
        substitutionValues: {'invoice': id},
      );
      result.add({
        ...invoice,
        'createdAt': _iso(invoice['createdAt']),
        'items': itemRows.map(_flatten).toList(growable: false),
        'payments': paymentRows.map(_flatten).toList(growable: false),
      });
    }
    return result;
  }

  /// Posts one invoice and its inventory, payments, ledger and journal effects.
  @override
  Future<Map<String, Object?>> postSale(SaleInvoiceCommand command) =>
      _connection.transaction((ctx) async {
        final replay = await _claimKey(
          ctx,
          command.branchId,
          command.idempotencyKey,
          command.requestHash,
        );
        if (replay != null) return replay;

        await ctx.mappedResultsQuery(
          'SELECT pg_advisory_xact_lock(hashtextextended(@lockKey, 0)) AS locked',
          substitutionValues: {
            'lockKey': '${command.branchId}|${command.operationId}',
          },
        );
        final existingReceipt = await ctx.mappedResultsQuery(
          '''SELECT operation_type AS "operationType",
                    payload_hash AS "payloadHash"
             FROM sync_operation_receipts
             WHERE branch_id = @branch AND operation_id = @operation''',
          substitutionValues: {
            'branch': command.branchId,
            'operation': command.operationId,
          },
        );
        if (existingReceipt.isNotEmpty) {
          final receipt = _flatten(existingReceipt.single);
          if (receipt['operationType'] != 'SALE_INVOICE' ||
              (receipt['payloadHash'] != null &&
                  receipt['payloadHash'] != _operationPayloadHash(command.request))) {
            throw StateError('OPERATION_ID_REUSED');
          }
        }

        final previous = await ctx.mappedResultsQuery(
          '''SELECT id::text AS id, invoice_no AS "invoiceNo",
                    net_total::text AS "netTotal", paid_total::text AS "paidTotal",
                    remaining_alayh::text AS "remainingAlayh",
                    created_at AS "createdAt"
             FROM sales_invoices
             WHERE branch_id = @branch AND operation_id = @operation''',
          substitutionValues: {
            'branch': command.branchId,
            'operation': command.operationId,
          },
        );
        if (previous.isNotEmpty) {
          final response = _flatten(previous.single);
          response['createdAt'] = _iso(response['createdAt']);
          await _completeKey(ctx, command.idempotencyKey, 201, response);
          return response;
        }

        final response = await _applySale(
          ctx,
          branchId: command.branchId,
          operationId: command.operationId,
          request: command.request,
        );
        await _completeKey(ctx, command.idempotencyKey, 201, response);
        await _recordOperation(
          ctx,
          branchId: command.branchId,
          operationId: command.operationId,
          operationType: 'SALE_INVOICE',
          payloadHash: _operationPayloadHash(command.request),
          idempotencyKey: command.idempotencyKey,
        );
        return response;
      }).then((value) => Map<String, Object?>.from(value as Map));

  /// Applies a batch atomically; any invalid financial operation rolls back all items.
  @override
  Future<Map<String, Object?>> processBatch(SyncBatchCommand command) =>
      _connection.transaction((ctx) async {
        final replay = await _claimKey(
          ctx,
          command.branchId,
          command.idempotencyKey,
          command.requestHash,
        );
        if (replay != null) {
          replay['replayed'] = true;
          return replay;
        }

        final accepted = <String>[];
        final operationResults = <String, Map<String, Object?>>{};
        for (final operation in command.operations) {
          await ctx.mappedResultsQuery(
            'SELECT pg_advisory_xact_lock(hashtextextended(@lockKey, 0)) AS locked',
            substitutionValues: {
              'lockKey': '${command.branchId}|${operation.operationId}',
            },
          );
          final alreadyApplied = await ctx.mappedResultsQuery(
            '''SELECT operation_id::text AS "operationId",
                      operation_type AS "operationType",
                      payload_hash AS "payloadHash"
               FROM sync_operation_receipts
               WHERE branch_id = @branch AND operation_id = @operation''',
            substitutionValues: {
              'branch': command.branchId,
              'operation': operation.operationId,
            },
          );
          if (alreadyApplied.isNotEmpty) {
            final receipt = _flatten(alreadyApplied.single);
            if (receipt['operationType'] != operation.operationType) {
              throw StateError('OPERATION_ID_REUSED');
            }
            final storedPayloadHash = receipt['payloadHash'] as String?;
            // Legacy receipts predate payload_hash. Preserve their retry behavior,
            // while enforcing exact payload identity for all newly recorded work.
            if (storedPayloadHash != null &&
                storedPayloadHash != _operationPayloadHash(operation.payload)) {
              throw StateError('OPERATION_ID_REUSED');
            }
            if (operation.operationType == 'STOCKTAKE_APPROVE') {
              operationResults[operation.operationId] =
                  await PostgresInventoryApprovalRepository(_connection)
                      .approveStocktakeInTransaction(ctx, branchId: command.branchId, payload: operation.payload);
            } else if (operation.operationType == 'DISPOSAL_APPROVE') {
              operationResults[operation.operationId] =
                  await PostgresInventoryApprovalRepository(_connection)
                      .postDisposalInTransaction(ctx, branchId: command.branchId, payload: operation.payload);
            }
            accepted.add(operation.operationId);
            continue;
          }

          switch (operation.operationType) {
            case 'PARTY_CREATE':
              await _applyParty(ctx, command.branchId, operation.payload);
              break;
            case 'SALE_INVOICE':
              await _applySale(
                ctx,
                branchId: command.branchId,
                operationId: operation.operationId,
                request: operation.payload,
              );
              break;
            case 'VOUCHER':
              await _applyVoucher(ctx, command.branchId, operation.operationId, operation.payload);
              break;
            case 'PURCHASE_INVOICE':
              await PostgresPurchaseInvoicePostingRepository(_connection)
                  .postPurchaseInvoiceInTransaction(
                ctx,
                PurchaseInvoiceCommand(
                  branchId: command.branchId,
                  operationId: operation.operationId,
                  idempotencyKey: command.idempotencyKey,
                  requestHash: _operationPayloadHash(operation.payload),
                  request: operation.payload,
                ),
                manageIdempotency: false,
              );
              break;
            case 'PURCHASE_RETURN':
              await PostgresPurchaseReturnPostingRepository(_connection)
                  .postPurchaseReturnInTransaction(
                ctx,
                PurchaseReturnCommand(
                  branchId: command.branchId,
                  operationId: operation.operationId,
                  idempotencyKey: command.idempotencyKey,
                  requestHash: _operationPayloadHash(operation.payload),
                  request: operation.payload,
                ),
                manageIdempotency: false,
              );
              break;
            case 'STOCKTAKE_APPROVE':
              operationResults[operation.operationId] =
                  await PostgresInventoryApprovalRepository(_connection)
                      .approveStocktakeInTransaction(
                ctx, branchId: command.branchId, payload: operation.payload);
              break;
            case 'DISPOSAL_APPROVE':
              operationResults[operation.operationId] =
                  await PostgresInventoryApprovalRepository(_connection)
                      .postDisposalInTransaction(
                ctx, branchId: command.branchId, payload: operation.payload);
              break;
            default:
              throw FormatException('Unsupported operation type: ${operation.operationType}');
          }
          await _recordOperation(
            ctx,
            branchId: command.branchId,
            operationId: operation.operationId,
            operationType: operation.operationType,
            payloadHash: _operationPayloadHash(operation.payload),
            idempotencyKey: command.idempotencyKey,
          );
          accepted.add(operation.operationId);
        }

        final response = <String, Object?>{
          'batchId': command.batchId,
          'acceptedIds': accepted,
          'results': operationResults,
          'rejected': const <Object>[],
          'serverTime': DateTime.now().toUtc().toIso8601String(),
          'replayed': false,
        };
        await _completeKey(ctx, command.idempotencyKey, 200, response);
        return response;
      }).then((value) => Map<String, Object?>.from(value as Map));

  Future<Map<String, Object?>> _applyParty(
    PostgreSQLExecutionContext ctx,
    String branchId,
    Map<String, dynamic> payload,
  ) async {
    final id = _text(payload, 'id', fallback: _uuid.v4());
    await ctx.execute(
      '''INSERT INTO parties
        (id, branch_id, party_type, code, name_ar, phone, address,
         credit_limit, payment_terms_days, price_tier)
       VALUES (@id, @branch, @type, @code, @name, @phone, @address,
               @limit, @terms, @tier)
       ON CONFLICT (id) DO NOTHING''',
      substitutionValues: {
        'id': id,
        'branch': branchId,
        'type': _text(payload, 'partyType').toUpperCase(),
        'code': _text(payload, 'code'),
        'name': _text(payload, 'name'),
        'phone': payload['phone'],
        'address': payload['address'],
        'limit': _decimal(payload['creditLimit']),
        'terms': _integer(payload['paymentTermsDays']),
        'tier': _text(payload, 'priceTier', fallback: 'RETAIL').toUpperCase(),
      },
    );
    return {'id': id};
  }

  Future<Map<String, Object?>> _applyVoucher(
    PostgreSQLExecutionContext ctx,
    String branchId,
    String operationId,
    Map<String, dynamic> payload,
  ) async {
    final type = _text(payload, 'voucherType').toUpperCase();
    if (type != 'RECEIPT' && type != 'PAYMENT') {
      throw const FormatException('Voucher type must be RECEIPT or PAYMENT.');
    }
    final partyId = _text(payload, 'partyId');
    final cashId = _text(payload, 'cashAccountId');
    final amount = _decimal(payload['amount']);
    if (amount <= 0) throw const FormatException('Voucher amount must be positive.');
    final method = _text(payload, 'method', fallback: 'CASH').toUpperCase();
    final walletRef = payload['walletRefNo'] as String?;
    if (method == 'WALLET' && (walletRef == null || walletRef.trim().length < 6)) {
      throw const FormatException('Wallet notification reference is required.');
    }

    final partyRows = await ctx.mappedResultsQuery(
      'SELECT party_type AS type FROM parties WHERE id = @party AND branch_id = @branch FOR UPDATE',
      substitutionValues: {'party': partyId, 'branch': branchId},
    );
    if (partyRows.isEmpty) throw StateError('Party not found.');
    final partyType = _flatten(partyRows.single)['type'];
    if ((type == 'RECEIPT' && partyType != 'CUSTOMER') ||
        (type == 'PAYMENT' && partyType != 'SUPPLIER')) {
      throw StateError('Voucher type does not match party type.');
    }

    final cashRows = await ctx.mappedResultsQuery(
      '''SELECT id::text AS id, gl_account_id::text AS gl,
                current_balance::text AS balance
         FROM cash_accounts WHERE id = @id AND branch_id = @branch
         AND is_active = TRUE FOR UPDATE''',
      substitutionValues: {'id': cashId, 'branch': branchId},
    );
    if (cashRows.isEmpty) throw StateError('Cash account not found.');
    final cash = _flatten(cashRows.single);
    if (type == 'PAYMENT' && _decimal(cash['balance']) < amount) {
      throw StateError('Insufficient cash-account balance.');
    }
    final contraCode = type == 'RECEIPT' ? '1100' : '2000';
    final contraRows = await ctx.mappedResultsQuery(
      'SELECT id::text AS id FROM chart_of_accounts WHERE branch_id = @branch AND code = @code',
      substitutionValues: {'branch': branchId, 'code': contraCode},
    );
    if (contraRows.isEmpty) throw StateError('Required chart account is missing.');

    final voucherId = _uuid.v4();
    final journalId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final voucherNo = 'V-${now.microsecondsSinceEpoch}';
    await ctx.execute(
      '''INSERT INTO journal_entries
        (id, branch_id, entry_no, entry_date, doc_type, doc_id, description, status)
       VALUES (@id, @branch, @number, @date, 'VOUCHER', @doc, @description, 'DRAFT')''',
      substitutionValues: {
        'id': journalId,
        'branch': branchId,
        'number': voucherNo,
        'date': now,
        'doc': voucherId,
        'description': _text(payload, 'description', fallback: ''),
      },
    );
    final receipt = type == 'RECEIPT';
    await ctx.execute(
      '''INSERT INTO journal_lines
        (journal_entry_id, gl_account_id, dr_amount, cr_amount)
       VALUES (@entry, @cashGl, @cashDr, @cashCr),
              (@entry, @contraGl, @contraDr, @contraCr)''',
      substitutionValues: {
        'entry': journalId,
        'cashGl': cash['gl'],
        'cashDr': receipt ? amount : 0,
        'cashCr': receipt ? 0 : amount,
        'contraGl': _flatten(contraRows.single)['id'],
        'contraDr': receipt ? 0 : amount,
        'contraCr': receipt ? amount : 0,
      },
    );
    await ctx.execute(
      "UPDATE journal_entries SET status = 'POSTED', posted_at = @now WHERE id = @id",
      substitutionValues: {'now': now, 'id': journalId},
    );
    await ctx.execute(
      'UPDATE cash_accounts SET current_balance = current_balance + @delta, updated_at = @now WHERE id = @id',
      substitutionValues: {
        'delta': receipt ? amount : -amount,
        'now': now,
        'id': cashId,
      },
    );
    await ctx.execute(
      '''INSERT INTO vouchers
        (id, branch_id, voucher_no, voucher_type, voucher_date, party_id,
         cash_account_id, amount, method, wallet_ref_no, description,
         journal_entry_id, operation_id)
       VALUES (@id, @branch, @number, @type, @date, @party, @cash,
               @amount, @method, @walletRef, @description, @journal, @operation)''',
      substitutionValues: {
        'id': voucherId,
        'branch': branchId,
        'number': voucherNo,
        'type': type,
        'date': now,
        'party': partyId,
        'cash': cashId,
        'amount': amount,
        'method': method,
        'walletRef': walletRef,
        'description': _text(payload, 'description', fallback: ''),
        'journal': journalId,
        'operation': operationId,
      },
    );
    await ctx.execute(
      '''INSERT INTO lah_alayh_ledger
        (branch_id, party_id, entry_date, entry_type, alayh_amount, lah_amount,
         doc_type, doc_id, statement_ar, journal_entry_id)
       VALUES (@branch, @party, @date, @type, @alayh, @lah,
               'VOUCHER', @doc, @statement, @journal)''',
      substitutionValues: {
        'branch': branchId,
        'party': partyId,
        'date': now,
        'type': type,
        'alayh': receipt ? 0 : amount,
        'lah': receipt ? amount : 0,
        'doc': voucherId,
        'statement': _text(payload, 'description', fallback: ''),
        'journal': journalId,
      },
    );
    return {
      'id': voucherId,
      'voucherNo': voucherNo,
      'voucherType': type,
      'partyId': partyId,
      'cashAccountId': cashId,
      'amount': amount.toStringAsFixed(4),
      'method': method,
      'createdAt': now.toIso8601String(),
      'walletRefNo': walletRef,
      'description': _text(payload, 'description', fallback: ''),
    };
  }

  Future<Map<String, Object?>> _applySale(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required String operationId,
    required Map<String, dynamic> request,
  }) async {
    final items = request['items'] as List<dynamic>;
    final payments = request['payments'] as List<dynamic>;
    final invoiceId = _uuid.v4();
    final journalId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final invoiceNo = 'S-${now.microsecondsSinceEpoch}';
    final customerId = request['customerPartyId'] as String?;
    final priceTier = _text(request, 'priceTier', fallback: 'RETAIL').toUpperCase();
    if (priceTier != 'RETAIL' && priceTier != 'WHOLESALE') {
      throw const FormatException('Unsupported price tier.');
    }

    var subtotal = 0.0;
    var costTotal = 0.0;
    final parsedItems = <Map<String, Object?>>[];
    for (final raw in items) {
      if (raw is! Map<String, dynamic>) throw const FormatException('Invalid invoice item.');
      final productId = _text(raw, 'productId');
      final qty = _decimal(raw['qtySold']);
      final factor = _decimal(raw['conversionFactor']);
      final price = _decimal(raw['unitPrice']);
      if (qty <= 0 || factor <= 0 || price < 0) {
        throw const FormatException('Invalid item quantity, conversion factor or price.');
      }
      final qtyExact = ScaledDecimal.parse(raw['qtySold'], scale: 4);
      final factorExact = ScaledDecimal.parse(raw['conversionFactor'], scale: 6);
      final qtyBase = qty * factor;
      final qtyBaseExact = qtyExact.multiply(
        factorExact,
        resultScale: 6,
      );
      final lineTotal = qty * price;
      final productRows = await ctx.mappedResultsQuery(
        '''SELECT stock_base_qty::text AS stock,
                  avg_cost_base_unit::text AS "unitCost"
           FROM products WHERE id = @id AND branch_id = @branch AND is_active = TRUE FOR UPDATE''',
        substitutionValues: {'id': productId, 'branch': branchId},
      );
      if (productRows.isEmpty) throw StateError('Product not found: $productId');
      final product = _flatten(productRows.single);
      final availableBaseStock = ScaledDecimal.parse(
        product['stock'],
        scale: 6,
      );
      if (availableBaseStock.compareTo(qtyBaseExact) < 0) {
        throw StateError('Insufficient stock for product $productId.');
      }
      final requestedWarehouse = request['warehouseId'];
      if (requestedWarehouse != null && requestedWarehouse is! String) {
        throw const FormatException('warehouseId must be a string.');
      }
      final batchAllocations = await _allocateFefoBatches(
        ctx,
        branchId: branchId,
        productId: productId,
        warehouseId: requestedWarehouse as String?,
        requiredBaseQuantity: qtyBaseExact,
      );
      await ctx.execute(
        'UPDATE products SET stock_base_qty = stock_base_qty - @qty WHERE id = @id AND branch_id = @branch',
        substitutionValues: {
          'qty': qtyBaseExact.toFixedString(),
          'id': productId,
          'branch': branchId,
        },
      );
      subtotal += lineTotal;
      final itemCost = batchAllocations.isEmpty
          ? qtyBase * _decimal(product['unitCost'])
          : batchAllocations.fold<double>(
              0,
              (total, allocation) =>
                  total +
                  _decimal(allocation['quantityDeducted']) *
                      _decimal(allocation['unitCostBase']),
            );
      costTotal += itemCost;
      parsedItems.add({
        'id': _uuid.v4(),
        'productId': productId,
        'barcode': raw['barcode'],
        'unitName': _text(raw, 'unitName'),
        'qtySold': qtyExact.toFixedString(),
        'factor': factorExact.toFixedString(),
        'qtyBaseExact': qtyBaseExact.toFixedString(),
        'unitCostBase': product['unitCost'],
        'batchAllocations': batchAllocations,
        'unitPrice': price,
        'lineTotal': lineTotal,
      });
    }

    final discount = _decimal(request['discountAmount']);
    if (discount < 0 || discount > subtotal) {
      throw const FormatException('Discount is outside the permitted range.');
    }
    final netTotal = subtotal - discount;
    var cashGross = 0.0;
    var walletTotal = 0.0;
    var creditTotal = 0.0;
    var changeReturned = _decimal(request['changeReturned']);
    final parsedPayments = <Map<String, Object?>>[];
    for (final raw in payments) {
      if (raw is! Map<String, dynamic>) throw const FormatException('Invalid payment item.');
      final method = _text(raw, 'method').toUpperCase();
      final amount = _decimal(raw['amount']);
      if (amount <= 0) throw const FormatException('Payment amount must be positive.');
      final cashId = raw['cashAccountId'] as String?;
      final walletRef = raw['walletRefNo'] as String?;
      if (method == 'CASH') {
        if (cashId == null) throw const FormatException('Cash account is required.');
        cashGross += amount;
      } else if (method == 'WALLET') {
        if (cashId == null) throw const FormatException('Wallet account is required.');
        if (walletRef == null || walletRef.trim().length < 6) {
          throw const FormatException('Wallet notification reference must contain at least 6 characters.');
        }
        walletTotal += amount;
      } else if (method == 'CREDIT') {
        creditTotal += amount;
      } else {
        throw FormatException('Unsupported payment method: $method');
      }
      parsedPayments.add({
        'id': _uuid.v4(),
        'method': method,
        'amount': amount,
        'cashAccountId': cashId,
        'walletProvider': raw['walletProvider'],
        'walletRefNo': walletRef,
      });
    }
    if (changeReturned < 0) {
      throw const FormatException('Change returned cannot be negative.');
    }
    // Local sales_payments contain the applied amounts after change is removed.
    // changeReturned is therefore informational and must not be subtracted twice.
    final paidTotal = cashGross + walletTotal;
    if ((paidTotal + creditTotal - netTotal).abs() > 0.0001) {
      throw const FormatException('Payments, change and outstanding amount do not match invoice total.');
    }
    if (creditTotal > 0) {
      if (customerId == null) throw const FormatException('A customer is required for credit sales.');
      final customerRows = await ctx.mappedResultsQuery(
        '''SELECT p.credit_limit::text AS "creditLimit", p.is_blocked AS blocked,
                  b.balance_side AS "balanceSide", b.balance_abs::text AS balance
           FROM parties p JOIN v_party_balance b ON b.party_id = p.id
           WHERE p.id = @id AND p.branch_id = @branch FOR UPDATE OF p''',
        substitutionValues: {'id': customerId, 'branch': branchId},
      );
      if (customerRows.isEmpty) throw StateError('Customer not found.');
      final customer = _flatten(customerRows.single);
      if (customer['blocked'] == true) throw StateError('Customer is blocked from credit sales.');
      final current = customer['balanceSide'] == 'ALAYH'
          ? _decimal(customer['balance'])
          : 0.0;
      final limit = _decimal(customer['creditLimit']);
      if (limit <= 0 || current + creditTotal > limit) {
        throw StateError('Customer credit limit would be exceeded.');
      }
    }
    final remaining = creditTotal;
    final saleType = remaining > 0 && paidTotal > 0
        ? 'MIXED'
        : remaining > 0
            ? 'CREDIT'
            : 'CASH';

    await ctx.execute(
      '''INSERT INTO journal_entries
        (id, branch_id, entry_no, entry_date, doc_type, doc_id, description, status)
       VALUES (@id, @branch, @number, @date, 'SALE', @doc, @description, 'DRAFT')''',
      substitutionValues: {
        'id': journalId,
        'branch': branchId,
        'number': invoiceNo,
        'date': now,
        'doc': invoiceId,
        'description': 'POS sale $invoiceNo',
      },
    );

    final cashByAccount = <String, double>{};
    for (final payment in parsedPayments) {
      final method = payment['method'];
      if (method == 'CASH' || method == 'WALLET') {
        final cashId = payment['cashAccountId'] as String;
        cashByAccount[cashId] = (cashByAccount[cashId] ?? 0) + (payment['amount'] as double);
      }
    }
    for (final entry in cashByAccount.entries) {
      if (entry.value <= 0) continue;
      final accountRows = await ctx.mappedResultsQuery(
        '''SELECT gl_account_id::text AS gl FROM cash_accounts
           WHERE id = @id AND branch_id = @branch AND is_active = TRUE FOR UPDATE''',
        substitutionValues: {'id': entry.key, 'branch': branchId},
      );
      if (accountRows.isEmpty) throw StateError('Cash or wallet account not found.');
      final gl = _flatten(accountRows.single)['gl'];
      await ctx.execute(
        '''INSERT INTO journal_lines (journal_entry_id, gl_account_id, dr_amount, cr_amount)
           VALUES (@entry, @gl, @dr, 0)''',
        substitutionValues: {'entry': journalId, 'gl': gl, 'dr': entry.value},
      );
      await ctx.execute(
        '''UPDATE cash_accounts SET current_balance = current_balance + @amount,
           updated_at = @now WHERE id = @id''',
        substitutionValues: {'amount': entry.value, 'now': now, 'id': entry.key},
      );
    }

    if (remaining > 0) {
      final ar = await _accountId(ctx, branchId, '1100');
      await ctx.execute(
        '''INSERT INTO journal_lines (journal_entry_id, gl_account_id, dr_amount, cr_amount)
           VALUES (@entry, @gl, @amount, 0)''',
        substitutionValues: {'entry': journalId, 'gl': ar, 'amount': remaining},
      );
    }
    final revenue = await _accountId(ctx, branchId, '4000');
    await ctx.execute(
      '''INSERT INTO journal_lines (journal_entry_id, gl_account_id, dr_amount, cr_amount)
         VALUES (@entry, @gl, 0, @amount)''',
      substitutionValues: {'entry': journalId, 'gl': revenue, 'amount': netTotal},
    );
    if (costTotal > 0) {
      final cogs = await _accountId(ctx, branchId, '5000');
      final inventory = await _accountId(ctx, branchId, '1200');
      await ctx.execute(
        '''INSERT INTO journal_lines (journal_entry_id, gl_account_id, dr_amount, cr_amount)
           VALUES (@entry, @cogs, @cost, 0), (@entry, @inventory, 0, @cost)''',
        substitutionValues: {
          'entry': journalId,
          'cogs': cogs,
          'inventory': inventory,
          'cost': costTotal,
        },
      );
    }
    await ctx.execute(
      "UPDATE journal_entries SET status = 'POSTED', posted_at = @now WHERE id = @id",
      substitutionValues: {'now': now, 'id': journalId},
    );

    await ctx.execute(
      '''INSERT INTO sales_invoices
        (id, branch_id, invoice_no, invoice_date, customer_party_id, price_tier,
         sale_type, status, subtotal, discount_amount, net_total, paid_total,
         change_returned, remaining_alayh, journal_entry_id, operation_id)
       VALUES (@id, @branch, @number, @date, @customer, @tier, @saleType,
               'POSTED', @subtotal, @discount, @net, @paid, @change,
               @remaining, @journal, @operation)''',
      substitutionValues: {
        'id': invoiceId,
        'branch': branchId,
        'number': invoiceNo,
        'date': now,
        'customer': customerId,
        'tier': priceTier,
        'saleType': saleType,
        'subtotal': subtotal,
        'discount': discount,
        'net': netTotal,
        'paid': paidTotal,
        'change': changeReturned,
        'remaining': remaining,
        'journal': journalId,
        'operation': operationId,
      },
    );

    for (final item in parsedItems) {
      await ctx.execute(
        '''INSERT INTO sales_invoice_items
          (id, invoice_id, product_id, barcode, unit_name, qty_sold,
           conversion_factor, unit_price, line_total)
         VALUES (@id, @invoice, @product, @barcode, @unit, @qty,
                 @factor, @price, @total)''',
        substitutionValues: {
          'id': item['id'],
          'invoice': invoiceId,
          'product': item['productId'],
          'barcode': item['barcode'],
          'unit': item['unitName'],
          'qty': item['qtySold'],
          'factor': item['factor'],
          'price': item['unitPrice'],
          'total': item['lineTotal'],
        },
      );

      final allocations =
          item['batchAllocations'] as List<Map<String, Object?>>;
      if (allocations.isEmpty) {
        await _insertSaleStockMovement(
          ctx,
          branchId: branchId,
          productId: item['productId'] as String,
          invoiceId: invoiceId,
          invoiceNo: invoiceNo,
          quantityBase: '-${item['qtyBaseExact']}',
          unitCostBase: item['unitCostBase'].toString(),
        );
      } else {
        for (final allocation in allocations) {
          await ctx.execute(
            '''INSERT INTO sales_invoice_item_batches
              (id, branch_id, sales_invoice_item_id, product_batch_id,
               qty_base, cartons_opened)
             VALUES (@id, @branch, @item, @batch, @quantity, @cartons)''',
            substitutionValues: {
              'id': _uuid.v4(),
              'branch': branchId,
              'item': item['id'],
              'batch': allocation['batchId'],
              'quantity': allocation['quantityDeducted'],
              'cartons': allocation['cartonsOpened'],
            },
          );
          await _insertSaleStockMovement(
            ctx,
            branchId: branchId,
            productId: item['productId'] as String,
            invoiceId: invoiceId,
            invoiceNo: invoiceNo,
            quantityBase: '-${allocation['quantityDeducted']}',
            unitCostBase: allocation['unitCostBase'].toString(),
            warehouseId: allocation['warehouseId'] as String,
            productBatchId: allocation['batchId'] as String,
            notes: 'FEFO allocation; cartons opened: ${allocation['cartonsOpened']}',
          );
        }
      }
    }

    for (final payment in parsedPayments) {
      await ctx.execute(
        '''INSERT INTO sales_payments
          (id, invoice_id, cash_account_id, method, amount, wallet_provider, wallet_ref_no)
         VALUES (@id, @invoice, @cash, @method, @amount, @provider, @reference)''',
        substitutionValues: {
          'id': payment['id'],
          'invoice': invoiceId,
          'cash': payment['cashAccountId'],
          'method': payment['method'],
          'amount': payment['amount'],
          'provider': payment['walletProvider'],
          'reference': payment['walletRefNo'],
        },
      );
    }

    if (remaining > 0) {
      await ctx.execute(
        '''INSERT INTO lah_alayh_ledger
          (branch_id, party_id, entry_date, entry_type, alayh_amount, lah_amount,
           doc_type, doc_id, statement_ar, journal_entry_id)
         VALUES (@branch, @party, @date, 'SALE_CREDIT', @amount, 0,
                 'SALE', @doc, @statement, @journal)''',
        substitutionValues: {
          'branch': branchId,
          'party': customerId,
          'date': now,
          'amount': remaining,
          'doc': invoiceId,
          'statement': 'متبقي فاتورة $invoiceNo',
          'journal': journalId,
        },
      );
    }

    return {
      'id': invoiceId,
      'invoiceNo': invoiceNo,
      'customerPartyId': customerId,
      'priceTier': priceTier,
      'items': parsedItems.map((item) => {
        'id': item['id'],
        'productId': item['productId'],
        'barcode': item['barcode'],
        'unitName': item['unitName'],
        'qtySold': item['qtySold'].toString(),
        'conversionFactor': item['factor'].toString(),
        'qtyBase': item['qtyBaseExact'],
        'unitPrice': item['unitPrice'].toString(),
        'lineTotal': item['lineTotal'].toString(),
      }).toList(),
      'payments': parsedPayments.map((payment) => {
        'id': payment['id'],
        'method': payment['method'],
        'amount': payment['amount'].toString(),
        'cashAccountId': payment['cashAccountId'],
        'walletProvider': payment['walletProvider'],
        'walletRefNo': payment['walletRefNo'],
      }).toList(),
      'netTotal': netTotal.toStringAsFixed(4),
      'paidTotal': paidTotal.toStringAsFixed(4),
      'changeReturned': changeReturned.toStringAsFixed(4),
      'remainingAlayh': remaining.toStringAsFixed(4),
      'createdAt': now.toIso8601String(),
    };
  }

  Future<List<Map<String, Object?>>> _allocateFefoBatches(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required String productId,
    required String? warehouseId,
    required ScaledDecimal requiredBaseQuantity,
  }) async {
    if (warehouseId != null) {
      final warehouseRows = await ctx.mappedResultsQuery(
        '''SELECT id FROM warehouses
           WHERE id = @warehouse AND branch_id = @branch
             AND is_active = TRUE AND is_sellable = TRUE
           FOR SHARE''',
        substitutionValues: {'warehouse': warehouseId, 'branch': branchId},
      );
      if (warehouseRows.isEmpty) {
        throw StateError('Sellable warehouse not found: $warehouseId.');
      }
    }

    // Lock every batch for this product before planning. If the product has
    // never been batch-tracked, preserve the legacy stock path only when no
    // warehouse was explicitly selected; selected-warehouse sales require
    // batch tracking so stock cannot be deducted from an unknown location.
    final rows = await ctx.mappedResultsQuery(
      '''SELECT b.id::text AS id, b.warehouse_id::text AS "warehouseId",
                w.is_sellable AS "isSellable",
                b.expiry_date AS "expiryDate", b.created_at AS "createdAt",
                b.pack_conversion_factor::text AS "packConversionFactor",
                b.sealed_cartons AS "sealedCartons",
                b.loose_base_qty::text AS "looseBaseQty",
                b.status, b.unit_cost_base::text AS "unitCostBase"
         FROM product_batches_fefo b
         JOIN warehouses w ON w.id = b.warehouse_id AND w.branch_id = b.branch_id
         WHERE b.branch_id = @branch AND b.product_id = @product
         ORDER BY b.expiry_date, b.created_at, b.id
         FOR UPDATE OF b''',
      substitutionValues: {'branch': branchId, 'product': productId},
    );
    if (rows.isEmpty) {
      if (warehouseId != null) {
        throw StateError(
          'FEFO batch tracking is not configured for product $productId in warehouse $warehouseId.',
        );
      }
      return <Map<String, Object?>>[];
    }

    final flattened = rows.map(_flatten).toList(growable: false);
    DateTime asDate(Object? value) {
      final parsed = value is DateTime ? value : DateTime.parse(value.toString());
      return DateTime.utc(parsed.year, parsed.month, parsed.day);
    }

    final batches = flattened.map((row) => FefoBatchBalance(
          id: row['id'] as String,
          expiryDate: asDate(row['expiryDate']),
          createdAt: row['createdAt'] is DateTime
              ? row['createdAt'] as DateTime
              : DateTime.parse(row['createdAt'].toString()),
          sealedCartons: (row['sealedCartons'] as num).toInt(),
          looseBaseQuantity: ScaledDecimal.parse(row['looseBaseQty'], scale: 6),
          packConversionFactor:
              ScaledDecimal.parse(row['packConversionFactor'], scale: 6),
          active: row['status'] == 'ACTIVE' &&
              row['isSellable'] == true &&
              (warehouseId == null || row['warehouseId'] == warehouseId),
        )).toList(growable: false);

    final plan = FefoAllocationPlanner.plan(
      batches: batches,
      requiredBaseQuantity: requiredBaseQuantity,
      businessDate: DateTime.now().toUtc(),
    );
    if (!plan.isFullyAllocated) {
      throw StateError(
        'Insufficient unexpired FEFO batch stock for product $productId.',
      );
    }

    final byId = {for (final row in flattened) row['id'] as String: row};
    final result = <Map<String, Object?>>[];
    for (final allocation in plan.allocations) {
      final original = byId[allocation.batchId]!;
      final depleted = allocation.remainingSealedCartons == 0 &&
          allocation.remainingLooseBaseQuantity.isZero;
      await ctx.execute(
        '''UPDATE product_batches_fefo
           SET sealed_cartons = @cartons, loose_base_qty = @loose,
               status = @status, updated_at = @now
           WHERE id = @id AND branch_id = @branch''',
        substitutionValues: {
          'cartons': allocation.remainingSealedCartons,
          'loose': allocation.remainingLooseBaseQuantity.toFixedString(),
          'status': depleted ? 'DEPLETED' : 'ACTIVE',
          'now': DateTime.now().toUtc(),
          'id': allocation.batchId,
          'branch': branchId,
        },
      );
      result.add({
        'batchId': allocation.batchId,
        'warehouseId': original['warehouseId'],
        'unitCostBase': original['unitCostBase'],
        'quantityDeducted': allocation.quantityDeducted.toFixedString(),
        'cartonsOpened': allocation.cartonsOpened,
      });
    }
    return result;
  }

  Future<void> _insertSaleStockMovement(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required String productId,
    required String invoiceId,
    required String invoiceNo,
    required String quantityBase,
    required String unitCostBase,
    String? warehouseId,
    String? productBatchId,
    String notes = '',
  }) async {
    await ctx.execute(
      '''INSERT INTO stock_movements
        (id, branch_id, product_id, movement_date, movement_type,
         quantity_base, unit_cost_base, doc_type, doc_id, warehouse_id,
         product_batch_id, reference_no, notes)
       VALUES (@id, @branch, @product, @date, 'SALE_OUT',
               @quantity, @cost, 'SALE', @doc, @warehouse,
               @batch, @reference, @notes)''',
      substitutionValues: {
        'id': _uuid.v4(),
        'branch': branchId,
        'product': productId,
        'date': DateTime.now().toUtc(),
        'quantity': quantityBase,
        'cost': unitCostBase,
        'doc': invoiceId,
        'warehouse': warehouseId,
        'batch': productBatchId,
        'reference': invoiceNo,
        'notes': notes,
      },
    );
  }

  Future<String> _accountId(
    PostgreSQLExecutionContext ctx,
    String branchId,
    String code,
  ) async {
    final rows = await ctx.mappedResultsQuery(
      'SELECT id::text AS id FROM chart_of_accounts WHERE branch_id = @branch AND code = @code',
      substitutionValues: {'branch': branchId, 'code': code},
    );
    if (rows.isEmpty) throw StateError('Chart account $code is missing.');
    return _flatten(rows.single)['id'] as String;
  }

  Future<Map<String, Object?>?> _claimKey(
    PostgreSQLExecutionContext ctx,
    String branchId,
    String key,
    String hash,
  ) async {
    await ctx.execute(
      '''INSERT INTO sync_idempotency (idempotency_key, branch_id, request_hash)
         VALUES (@key, @branch, @hash)
         ON CONFLICT (idempotency_key) DO NOTHING''',
      substitutionValues: {'key': key, 'branch': branchId, 'hash': hash},
    );
    final rows = await ctx.mappedResultsQuery(
      '''SELECT branch_id::text AS "branchId", request_hash AS "requestHash",
                response_body AS "responseBody"
         FROM sync_idempotency WHERE idempotency_key = @key FOR UPDATE''',
      substitutionValues: {'key': key},
    );
    final record = _flatten(rows.single);
    if (record['branchId']?.toString().trim() != branchId.trim() ||
        record['requestHash']?.toString().trim() != hash.trim()) {
      throw StateError('IDEMPOTENCY_KEY_REUSED');
    }
    final response = record['responseBody'];
    if (response is Map) return Map<String, Object?>.from(response);
    if (response is String) {
      final decoded = jsonDecode(response);
      if (decoded is Map<String, dynamic>) return Map<String, Object?>.from(decoded);
    }
    return null;
  }

  Future<void> _completeKey(
    PostgreSQLExecutionContext ctx,
    String key,
    int status,
    Map<String, Object?> response,
  ) async {
    await ctx.execute(
      '''UPDATE sync_idempotency SET response_status = @status,
         response_body = @body::jsonb, completed_at = now()
         WHERE idempotency_key = @key''',
      substitutionValues: {
        'status': status,
        'body': jsonEncode(response),
        'key': key,
      },
    );
  }

  Future<void> _recordOperation(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required String operationId,
    required String operationType,
    required String payloadHash,
    required String idempotencyKey,
  }) async {
    await ctx.execute(
      '''INSERT INTO sync_operation_receipts
        (branch_id, operation_id, operation_type, payload_hash, idempotency_key, result_status)
       VALUES (@branch, @operation, @type, @payloadHash, @key, 'ACCEPTED')
       ON CONFLICT (branch_id, operation_id) DO NOTHING''',
      substitutionValues: {
        'branch': branchId,
        'operation': operationId,
        'type': operationType,
        'payloadHash': payloadHash,
        'key': idempotencyKey,
      },
    );
  }

  String _operationPayloadHash(Map<String, dynamic> payload) =>
      sha256
          .convert(utf8.encode(jsonEncode(_canonicalizeJson(payload))))
          .toString();

  Object? _canonicalizeJson(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((left, right) => left.key.toString().compareTo(right.key.toString()));
      return Map<String, Object?>.fromEntries(
        entries.map((entry) => MapEntry(
              entry.key.toString(),
              _canonicalizeJson(entry.value),
            )),
      );
    }
    if (value is List) {
      return value.map(_canonicalizeJson).toList(growable: false);
    }
    return value;
  }

  Map<String, Object?> _flatten(Map<String, Map<String, dynamic>> row) =>
      Map<String, Object?>.from(row.values.first);

  String _text(Map<String, dynamic> map, String key, {String? fallback}) {
    final value = map[key];
    if (value == null && fallback != null) return fallback;
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  double _decimal(Object? value) {
    final result = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    if (result == null || !result.isFinite) throw FormatException('Invalid decimal: $value');
    return result;
  }

  int _integer(Object? value) {
    if (value == null) return 0;
    final result = value is num ? value.toInt() : int.tryParse(value.toString());
    if (result == null) throw FormatException('Invalid integer: $value');
    return result;
  }

  String _iso(Object? value) =>
      value is DateTime ? value.toUtc().toIso8601String() : value.toString();
}
