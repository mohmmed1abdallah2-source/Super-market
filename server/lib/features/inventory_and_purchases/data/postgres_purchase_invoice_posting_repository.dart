import 'dart:convert';

import 'package:core_contracts/core_contracts.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../application/purchase_invoice_posting.dart';
import '../domain/purchase_and_fefo_calculator.dart';

/// Transactional PostgreSQL writer for supplier purchase invoices.
final class PostgresPurchaseInvoicePostingRepository
    implements PurchaseInvoicePostingRepository {
  PostgresPurchaseInvoicePostingRepository(this._connection);

  final PostgreSQLConnection _connection;
  static const Uuid _uuid = Uuid();

  @override
  Future<Map<String, Object?>> postPurchaseInvoice(
    PurchaseInvoiceCommand command,
  ) =>
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

        final previous = await ctx.mappedResultsQuery(
          '''SELECT id::text AS id, invoice_no AS "invoiceNo",
                    net_total::text AS "netTotal", paid_total::text AS "paidTotal",
                    journal_entry_id::text AS "journalEntryId",
                    created_at AS "createdAt"
             FROM purchase_invoices
             WHERE branch_id = @branch AND operation_id = @operation''',
          substitutionValues: {
            'branch': command.branchId,
            'operation': command.operationId,
          },
        );
        if (previous.isNotEmpty) {
          final result = _flatten(previous.single);
          result['createdAt'] = _iso(result['createdAt']);
          await _completeKey(ctx, command.idempotencyKey, 201, result);
          return result;
        }

        final request = command.request;
        final supplierId = _requiredText(request, 'supplierPartyId');
        final warehouseId = _requiredText(request, 'warehouseId');
        final invoiceNo = _requiredText(request, 'invoiceNo');
        final supplierInvoiceNo = _optionalText(request['supplierInvoiceNo']);
        final purchaseOrderId = _optionalText(request['purchaseOrderId']);
        final notes = _optionalText(request['notes']) ?? '';
        final now = DateTime.now().toUtc();
        final invoiceDate = request['invoiceDate'] == null
            ? now
            : DateTime.parse(_requiredText(request, 'invoiceDate')).toUtc();

        final supplierRows = await ctx.mappedResultsQuery(
          '''SELECT id::text AS id, party_type AS "partyType"
             FROM parties
             WHERE id = @supplier AND branch_id = @branch
             FOR UPDATE''',
          substitutionValues: {'supplier': supplierId, 'branch': command.branchId},
        );
        if (supplierRows.isEmpty ||
            _flatten(supplierRows.single)['partyType'] != 'SUPPLIER') {
          throw StateError('Supplier was not found in the authenticated branch.');
        }

        final warehouseRows = await ctx.mappedResultsQuery(
          '''SELECT id::text AS id FROM warehouses
             WHERE id = @warehouse AND branch_id = @branch AND is_active = TRUE
             FOR SHARE''',
          substitutionValues: {
            'warehouse': warehouseId,
            'branch': command.branchId,
          },
        );
        if (warehouseRows.isEmpty) {
          throw StateError('Active receiving warehouse was not found.');
        }

        if (purchaseOrderId != null) {
          final orderRows = await ctx.mappedResultsQuery(
            '''SELECT id::text AS id, supplier_party_id::text AS supplier,
                      status
               FROM purchase_orders
               WHERE id = @order AND branch_id = @branch
               FOR UPDATE''',
            substitutionValues: {
              'order': purchaseOrderId,
              'branch': command.branchId,
            },
          );
          if (orderRows.isEmpty) throw StateError('Purchase order was not found.');
          final order = _flatten(orderRows.single);
          if (order['supplier'] != supplierId ||
              !const {'APPROVED', 'PARTIALLY_RECEIVED'}.contains(order['status'])) {
            throw StateError('Purchase order is not receivable for this supplier.');
          }
        }

        final rawItems = request['items'] as List<dynamic>;
        final invoiceId = _uuid.v4();
        final journalId = _uuid.v4();
        var subtotal = MoneyAmount.zero;
        var totalDiscount = MoneyAmount.zero;
        var netTotal = MoneyAmount.zero;
        final postedItems = <Map<String, Object?>>[];

        // Create the parent document first because purchase_invoice_items has
        // an immediate branch-scoped foreign key to purchase_invoices.
        await ctx.execute(
          '''INSERT INTO purchase_invoices
            (id, branch_id, invoice_no, supplier_invoice_no, supplier_party_id,
             warehouse_id, purchase_order_id, invoice_date, status, subtotal,
             discount_amount, net_total, paid_total, cash_account_id,
             payment_method, wallet_ref_no, journal_entry_id, operation_id, notes)
           VALUES (@id, @branch, @number, @supplierNumber, @supplier,
                   @warehouse, @order, @date, 'DRAFT', 0, 0, 0, 0, NULL,
                   'CREDIT', NULL, NULL, @operation, @notes)''',
          substitutionValues: {
            'id': invoiceId,
            'branch': command.branchId,
            'number': invoiceNo,
            'supplierNumber': supplierInvoiceNo,
            'supplier': supplierId,
            'warehouse': warehouseId,
            'order': purchaseOrderId,
            'date': invoiceDate,
            'operation': command.operationId,
            'notes': notes,
          },
        );

        for (final raw in rawItems) {
          final item = Map<String, dynamic>.from(raw as Map);
          final productId = _requiredText(item, 'productId');
          final unitId = _optionalText(item['unitId']);
          final batchNo = _requiredText(item, 'batchNo');
          final expiryDate = DateTime.parse(_requiredText(item, 'expiryDate'));
          final expiryDay = DateTime.utc(expiryDate.year, expiryDate.month, expiryDate.day);
          final today = DateTime.now().toUtc();
          final todayDay = DateTime.utc(today.year, today.month, today.day);
          if (expiryDay.isBefore(todayDay)) {
            throw FormatException('Expired batch $batchNo cannot be received as active stock.');
          }
          final locationId = _optionalText(item['locationId']);
          final paidQuantity = ScaledDecimal.fromString(
            _decimalText(item['qtyPaid'], 'qtyPaid'),
            scale: PurchaseMoneyCalculator.quantityScale,
          );
          final bonusQuantity = ScaledDecimal.fromString(
            _decimalText(item['bonusQty'] ?? '0', 'bonusQty'),
            scale: PurchaseMoneyCalculator.quantityScale,
          );
          final conversionFactor = ScaledDecimal.fromString(
            _decimalText(item['conversionFactor'], 'conversionFactor'),
            scale: PurchaseMoneyCalculator.stockScale,
          );
          final unitPrice = MoneyAmount.fromString(
            _decimalText(item['purchaseUnitPrice'], 'purchaseUnitPrice'),
          );
          final lineDiscount = MoneyAmount.fromString(
            _decimalText(item['lineDiscountAmount'] ?? '0', 'lineDiscountAmount'),
          );
          final calculation = PurchaseMoneyCalculator.calculateLine(
            paidQuantity: paidQuantity.toFixedString(),
            bonusQuantity: bonusQuantity.toFixedString(),
            conversionFactor: conversionFactor.toFixedString(),
            purchaseUnitPrice: unitPrice.toFixedString(),
            lineDiscountAmount: lineDiscount.toFixedString(),
          );

          final productRows = await ctx.mappedResultsQuery(
            '''SELECT stock_base_qty::text AS stock,
                      avg_cost_base_unit::text AS "averageCost",
                      last_cost_base_unit::text AS "lastCost"
               FROM products
               WHERE id = @product AND branch_id = @branch AND is_active = TRUE
               FOR UPDATE''',
            substitutionValues: {
              'product': productId,
              'branch': command.branchId,
            },
          );
          if (productRows.isEmpty) {
            throw StateError('Active product was not found: $productId.');
          }
          final product = _flatten(productRows.single);

          if (unitId != null) {
            final unitRows = await ctx.mappedResultsQuery(
              '''SELECT id, conversion_factor::text AS factor
                 FROM product_units_barcodes
                 WHERE id = @unit AND product_id = @product
                   AND branch_id = @branch AND is_active = TRUE''',
              substitutionValues: {
                'unit': unitId,
                'product': productId,
                'branch': command.branchId,
              },
            );
            if (unitRows.isEmpty) {
              throw StateError('Purchase unit does not belong to product $productId.');
            }
            final unitFactor = ScaledDecimal.parse(
              _flatten(unitRows.single)['factor'],
              scale: PurchaseMoneyCalculator.stockScale,
            );
            if (unitFactor.compareTo(conversionFactor) != 0) {
              throw const FormatException(
                'conversionFactor does not match the selected product unit.',
              );
            }
          }

          if (purchaseOrderId != null) {
            final orderItemRows = await ctx.mappedResultsQuery(
              '''SELECT id::text AS id, qty_ordered::text AS "qtyOrdered",
                        qty_received::text AS "qtyReceived",
                        conversion_factor::text AS factor
                 FROM purchase_order_items
                 WHERE purchase_order_id = @order AND branch_id = @branch
                   AND product_id = @product
                   AND unit_id IS NOT DISTINCT FROM @unit
                 FOR UPDATE''',
              substitutionValues: {
                'order': purchaseOrderId,
                'branch': command.branchId,
                'product': productId,
                'unit': unitId,
              },
            );
            if (orderItemRows.length != 1) {
              throw StateError(
                'Purchase order must contain exactly one matching line for product $productId and selected unit.',
              );
            }
            final orderItem = _flatten(orderItemRows.single);
            final orderFactor = ScaledDecimal.parse(
              orderItem['factor'],
              scale: PurchaseMoneyCalculator.stockScale,
            );
            if (orderFactor.compareTo(conversionFactor) != 0) {
              throw StateError('Purchase order conversion factor does not match.');
            }
            final ordered = ScaledDecimal.parse(
              orderItem['qtyOrdered'],
              scale: PurchaseMoneyCalculator.quantityScale,
            );
            final received = ScaledDecimal.parse(
              orderItem['qtyReceived'],
              scale: PurchaseMoneyCalculator.quantityScale,
            );
            final remaining = ordered - received;
            if (calculation.totalPacksReceived.compareTo(remaining) > 0) {
              throw StateError(
                'Received quantity exceeds the remaining purchase-order quantity for product $productId.',
              );
            }
            await ctx.execute(
              '''UPDATE purchase_order_items
                 SET qty_received = qty_received + @quantity
                 WHERE id = @id AND branch_id = @branch''',
              substitutionValues: {
                'quantity': calculation.totalPacksReceived.toFixedString(),
                'id': orderItem['id'],
                'branch': command.branchId,
              },
            );
          }

          if (locationId != null) {
            final locationRows = await ctx.mappedResultsQuery(
              '''SELECT id FROM aisle_shelf_locations
                 WHERE id = @location AND warehouse_id = @warehouse
                   AND branch_id = @branch AND is_active = TRUE''',
              substitutionValues: {
                'location': locationId,
                'warehouse': warehouseId,
                'branch': command.branchId,
              },
            );
            if (locationRows.isEmpty) {
              throw StateError('Receiving location does not belong to the selected warehouse.');
            }
          }

          final oldStock = ScaledDecimal.parse(
            product['stock'],
            scale: PurchaseMoneyCalculator.stockScale,
          );
          final oldAverage = ScaledDecimal.parse(
            product['averageCost'],
            scale: PurchaseMoneyCalculator.stockScale,
          );
          final newAverage = PurchaseMoneyCalculator.weightedAverageBaseCost(
            oldStockBaseQuantity: oldStock.toFixedString(),
            oldAverageBaseCost: oldAverage.toFixedString(),
            addedBaseQuantity: calculation.totalBaseUnitsAdded.toFixedString(),
            purchaseLineTotal: calculation.lineTotal,
          );

          final grossLine = MoneyAmount
              .fromString(paidQuantity.toFixedString())
              .multiply(unitPrice);
          subtotal = subtotal + grossLine;
          totalDiscount = totalDiscount + lineDiscount;
          netTotal = netTotal + calculation.lineTotal;

          final totalPacks = calculation.totalPacksReceived;
          final wholeCartons =
              totalPacks.units ~/ BigInt.from(10).pow(totalPacks.scale);
          final fractionalPacks = ScaledDecimal.fromString(
            '0.${totalPacks.units.remainder(BigInt.from(10).pow(totalPacks.scale)).toString().padLeft(totalPacks.scale, '0')}',
            scale: totalPacks.scale,
          );
          final looseBaseQuantity = fractionalPacks.multiply(
            conversionFactor,
            resultScale: PurchaseMoneyCalculator.stockScale,
          );
          final itemId = _uuid.v4();
          final batchId = _uuid.v4();
          await ctx.execute(
            '''INSERT INTO purchase_invoice_items
              (id, branch_id, purchase_invoice_id, product_id, unit_id,
               qty_paid, bonus_qty, conversion_factor, purchase_unit_price,
               line_discount_amount, line_total, total_base_units_added,
               effective_pack_cost, effective_base_cost)
             VALUES (@id, @branch, @invoice, @product, @unit, @paid, @bonus,
                     @factor, @price, @discount, @total, @base, @packCost, @baseCost)''',
            substitutionValues: {
              'id': itemId,
              'branch': command.branchId,
              'invoice': invoiceId,
              'product': productId,
              'unit': unitId,
              'paid': paidQuantity.toFixedString(),
              'bonus': bonusQuantity.toFixedString(),
              'factor': conversionFactor.toFixedString(),
              'price': unitPrice.toFixedString(),
              'discount': lineDiscount.toFixedString(),
              'total': calculation.lineTotal.toFixedString(),
              'base': calculation.totalBaseUnitsAdded.toFixedString(),
              'packCost': calculation.effectivePackCost.toFixedString(),
              'baseCost': calculation.effectiveBaseCost.toFixedString(),
            },
          );

          await ctx.execute(
            '''INSERT INTO product_batches_fefo
              (id, branch_id, product_id, warehouse_id, location_id,
               purchase_invoice_item_id, batch_no, expiry_date,
               pack_conversion_factor, sealed_cartons, loose_base_qty,
               status, unit_cost_base)
             VALUES (@id, @branch, @product, @warehouse, @location, @item,
                     @batchNo, @expiry, @factor, @cartons, @loose, 'ACTIVE', @cost)''',
            substitutionValues: {
              'id': batchId,
              'branch': command.branchId,
              'product': productId,
              'warehouse': warehouseId,
              'location': locationId,
              'item': itemId,
              'batchNo': batchNo,
              'expiry': DateTime.utc(expiryDate.year, expiryDate.month, expiryDate.day),
              'factor': conversionFactor.toFixedString(),
              'cartons': wholeCartons.toInt(),
              'loose': looseBaseQuantity.toFixedString(),
              'cost': calculation.effectiveBaseCost.toFixedString(),
            },
          );

          await ctx.execute(
            '''UPDATE products
               SET stock_base_qty = stock_base_qty + @quantity,
                   avg_cost_base_unit = @average,
                   last_cost_base_unit = @lastCost,
                   updated_at = @now
               WHERE id = @product AND branch_id = @branch''',
            substitutionValues: {
              'quantity': calculation.totalBaseUnitsAdded.toFixedString(),
              'average': newAverage.toFixedString(),
              'lastCost': calculation.effectiveBaseCost.toFixedString(),
              'now': now,
              'product': productId,
              'branch': command.branchId,
            },
          );

          await ctx.execute(
            '''INSERT INTO price_cost_history
              (id, branch_id, product_id, unit_id, source_type, source_id,
               old_cost_base, new_cost_base, effective_at)
             VALUES (@id, @branch, @product, @unit, 'PURCHASE', @source,
                     @oldCost, @newCost, @now)''',
            substitutionValues: {
              'id': _uuid.v4(),
              'branch': command.branchId,
              'product': productId,
              'unit': unitId,
              'source': invoiceId,
              'oldCost': oldAverage.toFixedString(),
              'newCost': newAverage.toFixedString(),
              'now': invoiceDate,
            },
          );

          await ctx.execute(
            '''INSERT INTO stock_movements
              (id, branch_id, product_id, movement_date, movement_type,
               quantity_base, unit_cost_base, doc_type, doc_id, warehouse_id,
               product_batch_id, reference_no, notes)
             VALUES (@id, @branch, @product, @date, 'PURCHASE_IN',
                     @quantity, @cost, 'PURCHASE', @doc, @warehouse,
                     @batch, @reference, @notes)''',
            substitutionValues: {
              'id': _uuid.v4(),
              'branch': command.branchId,
              'product': productId,
              'date': invoiceDate,
              'quantity': calculation.totalBaseUnitsAdded.toFixedString(),
              'cost': calculation.effectiveBaseCost.toFixedString(),
              'doc': invoiceId,
              'warehouse': warehouseId,
              'batch': batchId,
              'reference': invoiceNo,
              'notes': 'Purchase invoice $invoiceNo',
            },
          );

          postedItems.add({
            'id': itemId,
            'productId': productId,
            'batchId': batchId,
            'batchNo': batchNo,
            'qtyPaid': paidQuantity.toFixedString(),
            'bonusQty': bonusQuantity.toFixedString(),
            'totalBaseUnitsAdded': calculation.totalBaseUnitsAdded.toFixedString(),
            'lineTotal': calculation.lineTotal.toFixedString(),
            'effectiveBaseCost': calculation.effectiveBaseCost.toFixedString(),
          });
        }

        if (netTotal.isZero || netTotal.isNegative) {
          throw const FormatException('A posted purchase invoice must have a positive net total.');
        }
        final paidTotal = MoneyAmount.fromString(
          _decimalText(request['paidTotal'] ?? '0', 'paidTotal'),
        );
        if (paidTotal.isNegative || paidTotal.compareTo(netTotal) > 0) {
          throw const FormatException('paidTotal must be between zero and the invoice net total.');
        }
        final outstanding = netTotal - paidTotal;
        final paymentMethod = _requiredText(request, 'paymentMethod').toUpperCase();
        if (!const {'CASH', 'WALLET', 'CREDIT', 'MIXED'}.contains(paymentMethod)) {
          throw const FormatException('Unsupported purchase payment method.');
        }
        if ((paidTotal.isZero && paymentMethod != 'CREDIT') ||
            (!paidTotal.isZero && outstanding.isZero &&
                !const {'CASH', 'WALLET'}.contains(paymentMethod)) ||
            (!paidTotal.isZero && !outstanding.isZero && paymentMethod != 'MIXED')) {
          throw const FormatException('Payment method does not match the paid and outstanding totals.');
        }
        final cashAccountId = _optionalText(request['cashAccountId']);
        final walletRefNo = _optionalText(request['walletRefNo']);
        Map<String, Object?>? cashAccount;
        if (paidTotal.isZero) {
          if (cashAccountId != null) {
            throw const FormatException('cashAccountId must be omitted for a credit-only purchase.');
          }
        } else {
          if (cashAccountId == null) {
            throw const FormatException('cashAccountId is required when paidTotal is positive.');
          }
          if (paymentMethod == 'WALLET' &&
              (walletRefNo == null || walletRefNo.trim().length < 6)) {
            throw const FormatException('Wallet notification reference is required.');
          }
          final cashRows = await ctx.mappedResultsQuery(
            '''SELECT id::text AS id, gl_account_id::text AS gl,
                      current_balance::text AS balance, account_kind AS kind
               FROM cash_accounts
               WHERE id = @id AND branch_id = @branch AND is_active = TRUE
               FOR UPDATE''',
            substitutionValues: {'id': cashAccountId, 'branch': command.branchId},
          );
          if (cashRows.isEmpty) throw StateError('Cash or wallet account was not found.');
          cashAccount = _flatten(cashRows.single);
          if (ScaledDecimal.parse(cashAccount['balance'], scale: 4)
                  .compareTo(ScaledDecimal.fromString(paidTotal.toFixedString(), scale: 4)) <
              0) {
            throw StateError('Insufficient cash-account balance for purchase payment.');
          }
          if ((paymentMethod == 'WALLET') != (cashAccount['kind'] == 'WALLET')) {
            throw const FormatException('Payment method does not match the selected cash account.');
          }
        }

        final inventoryAccount = await _accountId(ctx, command.branchId, '1200');
        final supplierAccount = await _accountId(ctx, command.branchId, '2000');
        final journalNo = 'PUR-$invoiceId';
        await ctx.execute(
          '''INSERT INTO journal_entries
            (id, branch_id, entry_no, entry_date, doc_type, doc_id,
             description, status)
           VALUES (@id, @branch, @number, @date, 'PURCHASE', @doc,
                   @description, 'DRAFT')''',
          substitutionValues: {
            'id': journalId,
            'branch': command.branchId,
            'number': journalNo,
            'date': invoiceDate,
            'doc': invoiceId,
            'description': 'Purchase invoice $invoiceNo',
          },
        );

        final cashGl = cashAccount?['gl'];
        if (cashGl != null) {
          await ctx.execute(
            '''INSERT INTO journal_lines
              (journal_entry_id, gl_account_id, dr_amount, cr_amount, memo)
             VALUES (@entry, @gl, 0, @amount, @memo)''',
            substitutionValues: {
              'entry': journalId,
              'gl': cashGl,
              'amount': paidTotal.toFixedString(),
              'memo': 'Purchase payment',
            },
          );
        }
        if (!outstanding.isZero) {
          await ctx.execute(
            '''INSERT INTO journal_lines
              (journal_entry_id, gl_account_id, dr_amount, cr_amount, memo)
             VALUES (@entry, @gl, 0, @amount, @memo)''',
            substitutionValues: {
              'entry': journalId,
              'gl': supplierAccount,
              'amount': outstanding.toFixedString(),
              'memo': 'Supplier payable',
            },
          );
        }
        await ctx.execute(
          '''INSERT INTO journal_lines
            (journal_entry_id, gl_account_id, dr_amount, cr_amount, memo)
           VALUES (@entry, @gl, @amount, 0, @memo)''',
          substitutionValues: {
            'entry': journalId,
            'gl': inventoryAccount,
            'amount': netTotal.toFixedString(),
            'memo': 'Inventory received',
          },
        );

        await ctx.execute(
          '''UPDATE purchase_invoices
             SET status = 'POSTED', subtotal = @subtotal,
                 discount_amount = @discount, net_total = @net,
                 paid_total = @paid, cash_account_id = @cash,
                 payment_method = @method, wallet_ref_no = @walletRef,
                 journal_entry_id = @journal
             WHERE id = @id AND branch_id = @branch AND status = 'DRAFT' ''',
          substitutionValues: {
            'id': invoiceId,
            'branch': command.branchId,
            'subtotal': subtotal.toFixedString(),
            'discount': totalDiscount.toFixedString(),
            'net': netTotal.toFixedString(),
            'paid': paidTotal.toFixedString(),
            'cash': cashAccountId,
            'method': paymentMethod,
            'walletRef': walletRefNo,
            'journal': journalId,
          },
        );

        if (cashAccount != null) {
          await ctx.execute(
            '''UPDATE cash_accounts
               SET current_balance = current_balance - @amount, updated_at = @now
               WHERE id = @id AND branch_id = @branch''',
            substitutionValues: {
              'amount': paidTotal.toFixedString(),
              'now': now,
              'id': cashAccountId,
              'branch': command.branchId,
            },
          );
        }

        if (!outstanding.isZero) {
          await ctx.execute(
            '''INSERT INTO lah_alayh_ledger
              (branch_id, party_id, entry_date, entry_type, alayh_amount,
               lah_amount, doc_type, doc_id, statement_ar, journal_entry_id)
             VALUES (@branch, @party, @date, 'PURCHASE_INVOICE', 0,
                     @amount, 'PURCHASE', @doc, @statement, @journal)''',
            substitutionValues: {
              'branch': command.branchId,
              'party': supplierId,
              'date': invoiceDate,
              'amount': outstanding.toFixedString(),
              'doc': invoiceId,
              'statement': 'مستحق للمورد عن فاتورة $invoiceNo',
              'journal': journalId,
            },
          );
        }

        if (purchaseOrderId != null) {
          await ctx.execute(
            '''UPDATE purchase_orders
               SET status = CASE
                 WHEN EXISTS (
                   SELECT 1 FROM purchase_order_items i
                   WHERE i.purchase_order_id = purchase_orders.id
                     AND i.branch_id = purchase_orders.branch_id
                     AND i.qty_received < i.qty_ordered
                 ) THEN 'PARTIALLY_RECEIVED'
                 ELSE 'RECEIVED'
               END,
               updated_at = @now
               WHERE id = @id AND branch_id = @branch''',
            substitutionValues: {
              'now': now,
              'id': purchaseOrderId,
              'branch': command.branchId,
            },
          );
        }

        await ctx.execute(
          '''UPDATE journal_entries SET status = 'POSTED', posted_at = @now
             WHERE id = @id AND branch_id = @branch''',
          substitutionValues: {
            'now': now,
            'id': journalId,
            'branch': command.branchId,
          },
        );

        await ctx.execute(
          '''INSERT INTO sync_operation_receipts
            (branch_id, operation_id, operation_type, idempotency_key, result_status)
           VALUES (@branch, @operation, 'PURCHASE_INVOICE', @key, 'ACCEPTED')
           ON CONFLICT (branch_id, operation_id) DO NOTHING''',
          substitutionValues: {
            'branch': command.branchId,
            'operation': command.operationId,
            'key': command.idempotencyKey,
          },
        );

        final response = <String, Object?>{
          'id': invoiceId,
          'invoiceNo': invoiceNo,
          'supplierPartyId': supplierId,
          'warehouseId': warehouseId,
          'items': postedItems,
          'subtotal': subtotal.toFixedString(),
          'discountAmount': totalDiscount.toFixedString(),
          'netTotal': netTotal.toFixedString(),
          'paidTotal': paidTotal.toFixedString(),
          'remainingAlayh': outstanding.toFixedString(),
          'paymentMethod': paymentMethod,
          'journalEntryId': journalId,
          'createdAt': invoiceDate.toIso8601String(),
        };
        await _completeKey(ctx, command.idempotencyKey, 201, response);
        return response;
      }).then((value) => Map<String, Object?>.from(value as Map));

  Future<String> _accountId(
    PostgreSQLExecutionContext ctx,
    String branchId,
    String code,
  ) async {
    final rows = await ctx.mappedResultsQuery(
      '''SELECT id::text AS id FROM chart_of_accounts
         WHERE branch_id = @branch AND code = @code AND is_active = TRUE''',
      substitutionValues: {'branch': branchId, 'code': code},
    );
    if (rows.isEmpty) throw StateError('Required chart account $code is missing.');
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
    final stored = record['responseBody'];
    if (stored is Map) return Map<String, Object?>.from(stored);
    if (stored is String) {
      final decoded = jsonDecode(stored);
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

  Map<String, Object?> _flatten(Map<String, Map<String, dynamic>> row) =>
      Map<String, Object?>.from(row.values.first);

  String _decimalText(Object? value, String field) {
    if (value is String) return value;
    if (value is int) return value.toString();
    throw FormatException('$field must be sent as a decimal string or integer, not a floating-point number.');
  }

  String _requiredText(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  String? _optionalText(Object? value) {
    if (value == null) return null;
    if (value is! String) throw const FormatException('Optional text field must be a string.');
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _iso(Object? value) =>
      value is DateTime ? value.toUtc().toIso8601String() : value.toString();
}
