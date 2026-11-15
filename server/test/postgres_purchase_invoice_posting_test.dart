import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:supermarket_erp_server/features/inventory_and_purchases/application/purchase_invoice_posting.dart';
import 'package:supermarket_erp_server/features/inventory_and_purchases/data/postgres_purchase_invoice_posting_repository.dart';

void main() {
  final enabled = Platform.environment['PGTEST_HOST']?.isNotEmpty == true;

  test(
    'posts a supplier invoice atomically and replays without duplicating stock',
    () async {
      final environment = Platform.environment;
      final connection = PostgreSQLConnection(
        environment['PGTEST_HOST']!,
        int.tryParse(environment['PGTEST_PORT'] ?? '5432') ?? 5432,
        environment['PGTEST_DATABASE']!,
        username: environment['PGTEST_USER']!,
        password: environment['PGTEST_PASSWORD']!,
        timeoutInSeconds: 30,
      );
      await connection.open();
      try {
        const uuid = Uuid();
        final branchId = uuid.v4();
        final supplierId = uuid.v4();
        final productId = uuid.v4();
        final warehouseId = uuid.v4();
        final inventoryAccountId = uuid.v4();
        final supplierAccountId = uuid.v4();
        final suffix = branchId.substring(0, 8);

        await connection.execute(
          '''INSERT INTO branches (id, code, name_ar)
             VALUES (@id, @code, @name)''',
          substitutionValues: {
            'id': branchId,
            'code': 'T-$suffix',
            'name': 'Purchase integration test',
          },
        );
        await connection.execute(
          '''INSERT INTO parties
             (id, branch_id, party_type, code, name_ar)
             VALUES (@id, @branch, 'SUPPLIER', @code, 'Test supplier')''',
          substitutionValues: {
            'id': supplierId,
            'branch': branchId,
            'code': 'SUP-$suffix',
          },
        );
        await connection.execute(
          '''INSERT INTO products
             (id, branch_id, sku_code, name_ar, base_unit_name)
             VALUES (@id, @branch, @sku, 'Test product', 'piece')''',
          substitutionValues: {
            'id': productId,
            'branch': branchId,
            'sku': 'SKU-$suffix',
          },
        );
        await connection.execute(
          '''INSERT INTO warehouses (id, branch_id, code, name_ar)
             VALUES (@id, @branch, @code, 'Receiving warehouse')''',
          substitutionValues: {
            'id': warehouseId,
            'branch': branchId,
            'code': 'WH-$suffix',
          },
        );
        await connection.execute(
          '''INSERT INTO chart_of_accounts
             (id, branch_id, code, name_ar, account_type)
             VALUES (@inventory, @branch, '1200', 'Inventory', 'ASSET'),
                    (@supplier, @branch, '2000', 'Suppliers', 'LIABILITY')''',
          substitutionValues: {
            'inventory': inventoryAccountId,
            'supplier': supplierAccountId,
            'branch': branchId,
          },
        );

        final operationId = uuid.v4();
        final invoiceNo = 'TEST-$suffix';
        final idempotencyKey = 'purchase-integration-$branchId';
        final request = <String, dynamic>{
          'operationId': operationId,
          'invoiceNo': invoiceNo,
          'supplierPartyId': supplierId,
          'warehouseId': warehouseId,
          'paymentMethod': 'CREDIT',
          'paidTotal': '0.0000',
          'items': [
            {
              'productId': productId,
              'batchNo': 'BATCH-$suffix',
              'expiryDate': DateTime.now()
                  .toUtc()
                  .add(const Duration(days: 90))
                  .toIso8601String()
                  .split('T')
                  .first,
              'qtyPaid': '2.0000',
              'bonusQty': '1.0000',
              'conversionFactor': '24.000000',
              'purchaseUnitPrice': '10.0000',
              'lineDiscountAmount': '0.0000',
            },
          ],
        };
        final command = PurchaseInvoiceCommand(
          branchId: branchId,
          operationId: operationId,
          idempotencyKey: idempotencyKey,
          requestHash: List.filled(64, 'a').join(),
          request: request,
        );
        final repository = PostgresPurchaseInvoicePostingRepository(connection);
        final first = await repository.postPurchaseInvoice(command);
        final replay = await repository.postPurchaseInvoice(command);

        expect(first['id'], isNotNull);
        expect(replay['id'], first['id']);
        expect(first['netTotal'], '20.0000');

        final productRows = await connection.mappedResultsQuery(
          '''SELECT stock_base_qty::text AS stock,
                    avg_cost_base_unit::text AS "averageCost"
             FROM products WHERE id = @id AND branch_id = @branch''',
          substitutionValues: {'id': productId, 'branch': branchId},
        );
        final product = _flattenRow(productRows.single);
        expect(product['stock'], '72.000000');
        expect(product['averageCost'], '0.277778');

        final batchRows = await connection.mappedResultsQuery(
          '''SELECT sealed_cartons, loose_base_qty::text AS loose,
                    total_base_qty::text AS total
             FROM product_batches_fefo
             WHERE branch_id = @branch AND product_id = @product''',
          substitutionValues: {'branch': branchId, 'product': productId},
        );
        expect(batchRows, hasLength(1));
        final batch = _flattenRow(batchRows.single);
        expect(batch['sealed_cartons'], 3);
        expect(batch['loose'], '0.000000');
        expect(batch['total'], '72.000000');

        final movementRows = await connection.mappedResultsQuery(
          '''SELECT COUNT(*)::int AS count
             FROM stock_movements
             WHERE branch_id = @branch AND doc_id = @invoice
               AND movement_type = 'PURCHASE_IN' ''',
          substitutionValues: {'branch': branchId, 'invoice': first['id']},
        );
        expect(_flattenRow(movementRows.single)['count'], 1);

        final journalRows = await connection.mappedResultsQuery(
          '''SELECT j.status, SUM(l.dr_amount)::text AS debit,
                    SUM(l.cr_amount)::text AS credit
             FROM journal_entries j
             JOIN journal_lines l ON l.journal_entry_id = j.id
             WHERE j.id = @id AND j.branch_id = @branch
             GROUP BY j.status''',
          substitutionValues: {
            'id': first['journalEntryId'],
            'branch': branchId,
          },
        );
        expect(_flattenRow(journalRows.single)['status'], 'POSTED');
        expect(_flattenRow(journalRows.single)['debit'], '20.0000');
        expect(_flattenRow(journalRows.single)['credit'], '20.0000');

        final ledgerRows = await connection.mappedResultsQuery(
          '''SELECT alayh_amount::text AS alayh, lah_amount::text AS lah
             FROM lah_alayh_ledger
             WHERE branch_id = @branch AND doc_id = @invoice''',
          substitutionValues: {'branch': branchId, 'invoice': first['id']},
        );
        expect(_flattenRow(ledgerRows.single)['alayh'], '0.0000');
        expect(_flattenRow(ledgerRows.single)['lah'], '20.0000');

        // A half-pack receipt must be represented as loose base units, not lost
        // by truncating the integer sealed-carton column.
        final fractionalOperationId = uuid.v4();
        final fractionalInvoiceNo = 'FRAC-$suffix';
        final fractionalRequest = <String, dynamic>{
          'operationId': fractionalOperationId,
          'invoiceNo': fractionalInvoiceNo,
          'supplierPartyId': supplierId,
          'warehouseId': warehouseId,
          'paymentMethod': 'CREDIT',
          'paidTotal': '0.0000',
          'items': [
            {
              'productId': productId,
              'batchNo': 'FRACTIONAL-$suffix',
              'expiryDate': DateTime.now()
                  .toUtc()
                  .add(const Duration(days: 120))
                  .toIso8601String()
                  .split('T')
                  .first,
              'qtyPaid': '0.5000',
              'bonusQty': '0.0000',
              'conversionFactor': '24.000000',
              'purchaseUnitPrice': '10.0000',
              'lineDiscountAmount': '0.0000',
            },
          ],
        };
        final fractionalCommand = PurchaseInvoiceCommand(
          branchId: branchId,
          operationId: fractionalOperationId,
          idempotencyKey: 'purchase-fractional-$branchId',
          requestHash: List.filled(64, 'b').join(),
          request: fractionalRequest,
        );
        await repository.postPurchaseInvoice(fractionalCommand);
        final fractionalBatchRows = await connection.mappedResultsQuery(
          '''SELECT sealed_cartons, loose_base_qty::text AS loose,
                    total_base_qty::text AS total
             FROM product_batches_fefo
             WHERE branch_id = @branch AND batch_no = @batch''',
          substitutionValues: {
            'branch': branchId,
            'batch': 'FRACTIONAL-$suffix',
          },
        );
        expect(fractionalBatchRows, hasLength(1));
        final fractionalBatch = _flattenRow(fractionalBatchRows.single);
        expect(fractionalBatch['sealed_cartons'], 0);
        expect(fractionalBatch['loose'], '12.000000');
        expect(fractionalBatch['total'], '12.000000');

        final purchaseOrderId = uuid.v4();
        await connection.execute(
          '''INSERT INTO purchase_orders
             (id, branch_id, order_no, supplier_party_id, status)
             VALUES (@id, @branch, @number, @supplier, 'APPROVED')''',
          substitutionValues: {
            'id': purchaseOrderId,
            'branch': branchId,
            'number': 'PO-$suffix',
            'supplier': supplierId,
          },
        );
        await connection.execute(
          '''INSERT INTO purchase_order_items
             (id, branch_id, purchase_order_id, product_id, qty_ordered,
              conversion_factor, expected_unit_price)
             VALUES (@id, @branch, @order, @product, 1.5000, 24.000000, 10.0000)''',
          substitutionValues: {
            'id': uuid.v4(),
            'branch': branchId,
            'order': purchaseOrderId,
            'product': productId,
          },
        );
        final orderOperationId = uuid.v4();
        final orderRequest = <String, dynamic>{
          'operationId': orderOperationId,
          'invoiceNo': 'PO-INV-$suffix',
          'supplierPartyId': supplierId,
          'warehouseId': warehouseId,
          'purchaseOrderId': purchaseOrderId,
          'paymentMethod': 'CREDIT',
          'paidTotal': '0.0000',
          'items': [
            {
              'productId': productId,
              'batchNo': 'PO-BATCH-$suffix',
              'expiryDate': DateTime.now()
                  .toUtc()
                  .add(const Duration(days: 150))
                  .toIso8601String()
                  .split('T')
                  .first,
              'qtyPaid': '1.0000',
              'bonusQty': '0.5000',
              'conversionFactor': '24.000000',
              'purchaseUnitPrice': '10.0000',
              'lineDiscountAmount': '0.0000',
            },
          ],
        };
        await repository.postPurchaseInvoice(
          PurchaseInvoiceCommand(
            branchId: branchId,
            operationId: orderOperationId,
            idempotencyKey: 'purchase-order-$branchId',
            requestHash: List.filled(64, 'c').join(),
            request: orderRequest,
          ),
        );
        final orderRows = await connection.mappedResultsQuery(
          '''SELECT status FROM purchase_orders
             WHERE id = @id AND branch_id = @branch''',
          substitutionValues: {'id': purchaseOrderId, 'branch': branchId},
        );
        expect(_flattenRow(orderRows.single)['status'], 'RECEIVED');
        final orderItemRows = await connection.mappedResultsQuery(
          '''SELECT qty_received::text AS received
             FROM purchase_order_items
             WHERE purchase_order_id = @order AND branch_id = @branch''',
          substitutionValues: {'order': purchaseOrderId, 'branch': branchId},
        );
        expect(_flattenRow(orderItemRows.single)['received'], '1.5000');
      } finally {
        await connection.close();
      }
    },
    skip: enabled ? false : 'PGTEST_HOST is not configured; PostgreSQL integration test skipped.',
  );
}

Map<String, Object?> _flattenRow(Map<String, Map<String, dynamic>> row) =>
    row.values.fold<Map<String, Object?>>(
      <String, Object?>{},
      (result, values) => result..addAll(values),
    );
