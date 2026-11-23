import 'dart:convert';
import 'dart:collection';

import 'package:crypto/crypto.dart';

import 'package:core_contracts/core_contracts.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../application/purchase_return_posting.dart';

/// Transactional supplier-return writer. Return valuation follows the
/// product's current moving-average carrying cost; the original invoice/batch
/// links are retained to prevent returning more physical stock than received.
final class PostgresPurchaseReturnPostingRepository
    implements PurchaseReturnPostingRepository {
  PostgresPurchaseReturnPostingRepository(this._connection);

  final PostgreSQLConnection _connection;
  static const Uuid _uuid = Uuid();

  @override
  Future<Map<String, Object?>> postPurchaseReturn(
    PurchaseReturnCommand command,
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
          if (receipt['operationType'] != 'PURCHASE_RETURN' ||
              (receipt['payloadHash'] != null &&
                  receipt['payloadHash'] != _payloadHash(command.request))) {
            throw StateError('OPERATION_ID_REUSED');
          }
        }

        final previousRows = await ctx.mappedResultsQuery(
          '''SELECT id::text AS id, return_no AS "returnNo",
                    purchase_invoice_id::text AS "purchaseInvoiceId",
                    supplier_party_id::text AS "supplierPartyId",
                    return_date AS "returnDate", net_total::text AS "netTotal",
                    status, journal_entry_id::text AS "journalEntryId"
             FROM purchase_returns
             WHERE branch_id = @branch AND operation_id = @operation''',
          substitutionValues: {
            'branch': command.branchId,
            'operation': command.operationId,
          },
        );
        if (previousRows.isNotEmpty) {
          final result = _flatten(previousRows.single);
          result['returnDate'] = _iso(result['returnDate']);
          await _completeKey(ctx, command.idempotencyKey, 201, result);
          return result;
        }

        final request = command.request;
        final invoiceId = _requiredText(request, 'purchaseInvoiceId');
        final returnNo = _requiredText(request, 'returnNo');
        final notes = _optionalText(request['notes']) ?? '';
        final now = DateTime.now().toUtc();
        final returnDate = request['returnDate'] == null
            ? now
            : DateTime.parse(_requiredText(request, 'returnDate')).toUtc();

        final invoiceRows = await ctx.mappedResultsQuery(
          '''SELECT id::text AS id, supplier_party_id::text AS "supplierPartyId",
                    status
             FROM purchase_invoices
             WHERE id = @invoice AND branch_id = @branch
             FOR UPDATE''',
          substitutionValues: {'invoice': invoiceId, 'branch': command.branchId},
        );
        if (invoiceRows.isEmpty) {
          throw StateError('Original purchase invoice was not found in this branch.');
        }
        final invoice = _flatten(invoiceRows.single);
        if (invoice['status'] != 'POSTED') {
          throw StateError('Only a posted purchase invoice can be returned.');
        }
        final supplierId = invoice['supplierPartyId'] as String;

        final returnId = _uuid.v4();
        await ctx.execute(
          '''INSERT INTO purchase_returns
            (id, branch_id, return_no, purchase_invoice_id, supplier_party_id,
             status, return_date, net_total, operation_id, notes)
           VALUES (@id, @branch, @number, @invoice, @supplier,
                   'DRAFT', @date, 0, @operation, @notes)''',
          substitutionValues: {
            'id': returnId,
            'branch': command.branchId,
            'number': returnNo,
            'invoice': invoiceId,
            'supplier': supplierId,
            'date': returnDate,
            'operation': command.operationId,
            'notes': notes,
          },
        );

        final rawItems = request['items'] as List<dynamic>;
        var netTotal = MoneyAmount.zero;
        final postedItems = <Map<String, Object?>>[];

        for (final raw in rawItems) {
          final item = Map<String, dynamic>.from(raw as Map);
          final purchaseItemId = _requiredText(item, 'purchaseInvoiceItemId');
          final batchId = _requiredText(item, 'productBatchId');
          final returnQuantity = ScaledDecimal.fromString(
            _decimalText(item['qtyBase'], 'qtyBase'),
            scale: 6,
          );
          if (returnQuantity.isNegative || returnQuantity.isZero) {
            throw const FormatException('qtyBase must be a positive decimal quantity.');
          }

          final sourceRows = await ctx.mappedResultsQuery(
            '''SELECT i.id::text AS "purchaseInvoiceItemId",
                      i.product_id::text AS "productId",
                      i.total_base_units_added::text AS "invoiceQtyBase",
                      b.id::text AS "batchId",
                      b.warehouse_id::text AS "warehouseId",
                      b.pack_conversion_factor::text AS "packFactor",
                      b.sealed_cartons AS "sealedCartons",
                      b.loose_base_qty::text AS "looseBaseQty",
                      b.status AS "batchStatus",
                      b.expiry_date AS "expiryDate"
               FROM purchase_invoice_items i
               JOIN product_batches_fefo b
                 ON b.purchase_invoice_item_id = i.id
                AND b.branch_id = i.branch_id
               WHERE i.id = @item AND i.purchase_invoice_id = @invoice
                 AND i.branch_id = @branch AND b.id = @batch
               FOR UPDATE OF i, b''',
            substitutionValues: {
              'item': purchaseItemId,
              'invoice': invoiceId,
              'branch': command.branchId,
              'batch': batchId,
            },
          );
          if (sourceRows.length != 1) {
            throw StateError(
              'Return item and FEFO batch must belong to the selected purchase invoice.',
            );
          }
          final source = _flatten(sourceRows.single);
          final productId = source['productId'] as String;

          final priorRows = await ctx.mappedResultsQuery(
            '''SELECT COALESCE(SUM(ri.qty_base), 0)::text AS returned
               FROM purchase_return_items ri
               JOIN purchase_returns r
                 ON r.id = ri.purchase_return_id AND r.branch_id = ri.branch_id
               WHERE ri.branch_id = @branch
                 AND ri.purchase_invoice_item_id = @item
                 AND ri.product_batch_id = @batch
                 AND r.status = 'POSTED' ''',
            substitutionValues: {
              'branch': command.branchId,
              'item': purchaseItemId,
              'batch': batchId,
            },
          );
          final alreadyReturned = ScaledDecimal.parse(
            _flatten(priorRows.single)['returned'],
            scale: 6,
          );
          final originalQuantity = ScaledDecimal.parse(
            source['invoiceQtyBase'],
            scale: 6,
          );
          if ((alreadyReturned + returnQuantity).compareTo(originalQuantity) > 0) {
            throw StateError('Return quantity exceeds the original invoice quantity.');
          }

          final factor = ScaledDecimal.parse(source['packFactor'], scale: 6);
          final loose = ScaledDecimal.parse(source['looseBaseQty'], scale: 6);
          var cartons = (source['sealedCartons'] as num).toInt();
          final physicalBatchQuantity =
              ScaledDecimal.fromString(cartons.toString(), scale: 6)
                  .multiply(factor, resultScale: 6) +
              loose;
          if (returnQuantity.compareTo(physicalBatchQuantity) > 0) {
            throw StateError('Return quantity exceeds the remaining physical batch stock.');
          }

          final productRows = await ctx.mappedResultsQuery(
            '''SELECT stock_base_qty::text AS stock,
                      avg_cost_base_unit::text AS "averageCost"
               FROM products
               WHERE id = @product AND branch_id = @branch
               FOR UPDATE''',
            substitutionValues: {
              'product': productId,
              'branch': command.branchId,
            },
          );
          if (productRows.isEmpty) throw StateError('Return product was not found.');
          final product = _flatten(productRows.single);
          final stock = ScaledDecimal.parse(product['stock'], scale: 6);
          final averageCost = ScaledDecimal.parse(
            product['averageCost'],
            scale: 6,
          );
          if (stock.compareTo(returnQuantity) < 0) {
            throw StateError('Return quantity exceeds aggregate product stock.');
          }

          // Remove loose stock first. Open only the minimum number of cartons
          // needed to satisfy the remainder; preserve all unopened cartons.
          var remainingLoose = loose;
          var openedCartons = 0;
          if (returnQuantity.compareTo(loose) <= 0) {
            remainingLoose = loose - returnQuantity;
          } else {
            final shortfall = returnQuantity - loose;
            final quotient = shortfall.units ~/ factor.units;
            final remainder = shortfall.units.remainder(factor.units);
            openedCartons =
                (quotient + (remainder == BigInt.zero ? BigInt.zero : BigInt.one))
                    .toInt();
            if (openedCartons > cartons) {
              throw StateError('FEFO batch carton balance is inconsistent.');
            }
            cartons -= openedCartons;
            remainingLoose = loose +
                ScaledDecimal.fromString(openedCartons.toString(), scale: 6)
                    .multiply(factor, resultScale: 6) -
                shortfall;
          }

          final depleted = cartons == 0 && remainingLoose.isZero;
          final batchStatus = depleted
              ? 'DEPLETED'
              : source['batchStatus'] == 'ACTIVE' &&
                      DateTime.parse(source['expiryDate'].toString())
                          .isBefore(DateTime.utc(now.year, now.month, now.day))
                  ? 'EXPIRED'
                  : source['batchStatus'];
          await ctx.execute(
            '''UPDATE product_batches_fefo
               SET sealed_cartons = @cartons, loose_base_qty = @loose,
                   status = @status, updated_at = @now
               WHERE id = @batch AND branch_id = @branch''',
            substitutionValues: {
              'cartons': cartons,
              'loose': remainingLoose.toFixedString(),
              'status': batchStatus,
              'now': now,
              'batch': batchId,
              'branch': command.branchId,
            },
          );

          // Supplier credit and inventory removal use the current moving
          // average carrying cost so aggregate inventory valuation remains
          // internally consistent after the quantity is removed.
          final lineValue = MoneyAmount.fromString(
            returnQuantity.multiply(averageCost, resultScale: 4).toFixedString(),
          );
          netTotal = netTotal + lineValue;
          final newStock = stock - returnQuantity;
          final newAverage = newStock.isZero
              ? ScaledDecimal.fromString('0', scale: 6)
              : averageCost;

          await ctx.execute(
            '''INSERT INTO purchase_return_items
              (id, branch_id, purchase_return_id, purchase_invoice_item_id,
               product_batch_id, qty_base, line_total)
             VALUES (@id, @branch, @return, @item, @batch, @quantity, @total)''',
            substitutionValues: {
              'id': _uuid.v4(),
              'branch': command.branchId,
              'return': returnId,
              'item': purchaseItemId,
              'batch': batchId,
              'quantity': returnQuantity.toFixedString(),
              'total': lineValue.toFixedString(),
            },
          );

          await ctx.execute(
            '''UPDATE products
               SET stock_base_qty = stock_base_qty - @quantity,
                   avg_cost_base_unit = @average, updated_at = @now
               WHERE id = @product AND branch_id = @branch''',
            substitutionValues: {
              'quantity': returnQuantity.toFixedString(),
              'average': newAverage.toFixedString(),
              'now': now,
              'product': productId,
              'branch': command.branchId,
            },
          );

          await ctx.execute(
            '''INSERT INTO price_cost_history
              (id, branch_id, product_id, source_type, source_id,
               old_cost_base, new_cost_base, effective_at)
             VALUES (@id, @branch, @product, 'PURCHASE_RETURN', @source,
                     @oldCost, @newCost, @date)''',
            substitutionValues: {
              'id': _uuid.v4(),
              'branch': command.branchId,
              'product': productId,
              'source': returnId,
              'oldCost': averageCost.toFixedString(),
              'newCost': newAverage.toFixedString(),
              'date': returnDate,
            },
          );

          await ctx.execute(
            '''INSERT INTO stock_movements
              (id, branch_id, product_id, movement_date, movement_type,
               quantity_base, unit_cost_base, doc_type, doc_id, warehouse_id,
               product_batch_id, reference_no, notes)
             VALUES (@id, @branch, @product, @date, 'PURCHASE_RETURN_OUT',
                     @quantity, @cost, 'PURCHASE_RETURN', @doc, @warehouse,
                     @batch, @reference, @notes)''',
            substitutionValues: {
              'id': _uuid.v4(),
              'branch': command.branchId,
              'product': productId,
              'date': returnDate,
              'quantity': '-' + returnQuantity.toFixedString(),
              'cost': averageCost.toFixedString(),
              'doc': returnId,
              'warehouse': source['warehouseId'],
              'batch': batchId,
              'reference': returnNo,
              'notes': 'Supplier return $returnNo; cartons opened: $openedCartons',
            },
          );

          postedItems.add({
            'purchaseInvoiceItemId': purchaseItemId,
            'productBatchId': batchId,
            'qtyBase': returnQuantity.toFixedString(),
            'lineTotal': lineValue.toFixedString(),
          });
        }

        String? journalId;
        if (!netTotal.isZero) {
          journalId = _uuid.v4();
          final supplierAccount = await _accountId(ctx, command.branchId, '2000');
          final inventoryAccount = await _accountId(ctx, command.branchId, '1200');
          await ctx.execute(
            '''INSERT INTO journal_entries
              (id, branch_id, entry_no, entry_date, doc_type, doc_id,
               description, status)
             VALUES (@id, @branch, @number, @date, 'PURCHASE_RETURN', @doc,
                     @description, 'DRAFT')''',
            substitutionValues: {
              'id': journalId,
              'branch': command.branchId,
              'number': 'PR-$returnId',
              'date': returnDate,
              'doc': returnId,
              'description': 'Supplier return $returnNo',
            },
          );
          await ctx.execute(
            '''INSERT INTO journal_lines
              (journal_entry_id, gl_account_id, dr_amount, cr_amount, memo)
             VALUES (@entry, @gl, @amount, 0, 'Supplier credit from purchase return')''',
            substitutionValues: {
              'entry': journalId,
              'gl': supplierAccount,
              'amount': netTotal.toFixedString(),
            },
          );
          await ctx.execute(
            '''INSERT INTO journal_lines
              (journal_entry_id, gl_account_id, dr_amount, cr_amount, memo)
             VALUES (@entry, @gl, 0, @amount, 'Inventory returned to supplier')''',
            substitutionValues: {
              'entry': journalId,
              'gl': inventoryAccount,
              'amount': netTotal.toFixedString(),
            },
          );
          await ctx.execute(
            '''INSERT INTO lah_alayh_ledger
              (branch_id, party_id, entry_date, entry_type, alayh_amount,
               lah_amount, doc_type, doc_id, statement_ar, journal_entry_id)
             VALUES (@branch, @party, @date, 'PURCHASE_RETURN', @amount,
                     0, 'PURCHASE_RETURN', @doc, @statement, @journal)''',
            substitutionValues: {
              'branch': command.branchId,
              'party': supplierId,
              'date': returnDate,
              'amount': netTotal.toFixedString(),
              'doc': returnId,
              'statement': 'رصيد دائن للمورد عن مردودات $returnNo',
              'journal': journalId,
            },
          );
          await ctx.execute(
            '''UPDATE journal_entries SET status = 'POSTED', posted_at = @now
               WHERE id = @id AND branch_id = @branch''',
            substitutionValues: {
              'now': now,
              'id': journalId,
              'branch': command.branchId,
            },
          );
        }

        await ctx.execute(
          '''UPDATE purchase_returns
             SET status = 'POSTED', net_total = @total, journal_entry_id = @journal
             WHERE id = @id AND branch_id = @branch AND status = 'DRAFT' ''',
          substitutionValues: {
            'total': netTotal.toFixedString(),
            'journal': journalId,
            'id': returnId,
            'branch': command.branchId,
          },
        );

        await ctx.execute(
          '''INSERT INTO sync_operation_receipts
            (branch_id, operation_id, operation_type, payload_hash, idempotency_key, result_status)
           VALUES (@branch, @operation, 'PURCHASE_RETURN', @payloadHash, @key, 'ACCEPTED')
           ON CONFLICT (branch_id, operation_id) DO NOTHING''',
          substitutionValues: {
            'branch': command.branchId,
            'operation': command.operationId,
            'payloadHash': _payloadHash(command.request),
            'key': command.idempotencyKey,
          },
        );

        final response = <String, Object?>{
          'id': returnId,
          'returnNo': returnNo,
          'purchaseInvoiceId': invoiceId,
          'supplierPartyId': supplierId,
          'returnDate': returnDate.toIso8601String(),
          'netTotal': netTotal.toFixedString(),
          'status': 'POSTED',
          'journalEntryId': journalId,
          'items': postedItems,
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

  String _payloadHash(Map<String, dynamic> payload) =>
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
      row.values.fold<Map<String, Object?>>(
        <String, Object?>{},
        (result, values) => result..addAll(values),
      );

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

  String _decimalText(Object? value, String field) {
    if (value is String) return value;
    if (value is int) return value.toString();
    throw FormatException('$field must be sent as a decimal string or integer.');
  }

  String _iso(Object? value) =>
      value is DateTime ? value.toUtc().toIso8601String() : value.toString();
}
