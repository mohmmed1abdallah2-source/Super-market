import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:supermarket_erp_server/features/sales_and_sync/data/postgres_sales_sync_repository.dart';
import 'package:supermarket_erp_server/features/sales_and_sync/domain/sales_sync_domain.dart';
import 'package:supermarket_erp_server/features/inventory_and_purchases/data/postgres_inventory_approval_repository.dart';

void main() {
  final enabled = Platform.environment['PGTEST_HOST']?.isNotEmpty == true;

  test('stocktake approval adjusts batch and aggregate stock once and posts balanced variance', () async {
    if (!enabled) return;
    final env = Platform.environment;
    final db = PostgreSQLConnection(env['PGTEST_HOST']!,
      int.tryParse(env['PGTEST_PORT'] ?? '5432') ?? 5432,
      env['PGTEST_DATABASE']!, username: env['PGTEST_USER']!,
      password: env['PGTEST_PASSWORD']!, timeoutInSeconds: 30);
    await db.open();
    try {
      const uuid = Uuid();
      final branch = uuid.v4(), user = uuid.v4(), product = uuid.v4();
      final warehouse = uuid.v4(), batch = uuid.v4(), session = uuid.v4();
      final suffix = branch.substring(0, 8);
      await _fixture(db, branch, user, product, warehouse, batch, suffix);
      await db.execute(
        '''INSERT INTO stocktaking_sessions
          (id,branch_id,warehouse_id,session_no,status,completed_at)
         VALUES (@id,@branch,@warehouse,@number,'COUNTING',now())''',
        substitutionValues: {'id': session, 'branch': branch, 'warehouse': warehouse, 'number': 'STK-$suffix'});
      await db.execute(
        '''INSERT INTO stocktaking_lines
          (id,branch_id,session_id,product_id,product_batch_id,expected_base_qty,
           counted_sealed_cartons,counted_loose_base_qty,pack_conversion_factor,counted_at)
         VALUES (@id,@branch,@session,@product,@batch,10,0,8,10,now())''',
        substitutionValues: {'id': uuid.v4(), 'branch': branch, 'session': session,
          'product': product, 'batch': batch});

      final repository = PostgresInventoryApprovalRepository(db);
      final payload = {'sessionId': session, 'approvedByUserId': user};
      final first = await repository.approveStocktake(branchId: branch, payload: payload);
      final retry = await repository.approveStocktake(branchId: branch, payload: payload);
      expect(first['status'], 'APPROVED');
      expect(first['lossValue'], '4.2469');
      expect(retry['replayed'], isTrue);
      final productRows = await db.mappedResultsQuery(
        'SELECT stock_base_qty::text AS qty FROM products WHERE id=@id AND branch_id=@branch',
        substitutionValues: {'id': product, 'branch': branch});
      final batchRows = await db.mappedResultsQuery(
        'SELECT total_base_qty::text AS qty FROM product_batches_fefo WHERE id=@id AND branch_id=@branch',
        substitutionValues: {'id': batch, 'branch': branch});
      expect(productRows.single.values.first['qty'], '8.000000');
      expect(batchRows.single.values.first['qty'], '8.000000');
      final journalRows = await db.mappedResultsQuery(
        '''SELECT SUM(dr_amount)::text AS debit,SUM(cr_amount)::text AS credit
           FROM journal_lines WHERE journal_entry_id=@id''',
        substitutionValues: {'id': first['journalEntryId']});
      expect(journalRows.single.values.first['debit'], journalRows.single.values.first['credit']);
      final movementRows = await db.mappedResultsQuery(
        '''SELECT COUNT(*)::int AS count FROM stock_movements
           WHERE branch_id=@branch AND doc_type='STOCKTAKE' AND doc_id=@doc''',
        substitutionValues: {'branch': branch, 'doc': session});
      expect(movementRows.single.values.first['count'], 1);
    } finally {
      await db.close();
    }
  }, skip: !enabled ? 'PGTEST_HOST is not configured' : false);

  test('disposal approval removes batch stock and posts a balanced loss once', () async {
    if (!enabled) return;
    final env = Platform.environment;
    final db = PostgreSQLConnection(env['PGTEST_HOST']!,
      int.tryParse(env['PGTEST_PORT'] ?? '5432') ?? 5432,
      env['PGTEST_DATABASE']!, username: env['PGTEST_USER']!,
      password: env['PGTEST_PASSWORD']!, timeoutInSeconds: 30);
    await db.open();
    try {
      const uuid = Uuid();
      final branch = uuid.v4(), user = uuid.v4(), product = uuid.v4();
      final warehouse = uuid.v4(), batch = uuid.v4(), disposal = uuid.v4();
      final suffix = branch.substring(0, 8);
      await _fixture(db, branch, user, product, warehouse, batch, suffix);
      await db.execute(
        '''INSERT INTO disposals
          (id,branch_id,warehouse_id,disposal_no,reason,status,disposal_date)
         VALUES (@id,@branch,@warehouse,@number,'DAMAGED','DRAFT',now())''',
        substitutionValues: {'id': disposal, 'branch': branch, 'warehouse': warehouse, 'number': 'DSP-$suffix'});
      await db.execute(
        '''INSERT INTO disposal_items
          (id,branch_id,disposal_id,product_batch_id,qty_base,unit_cost_base)
         VALUES (@id,@branch,@disposal,@batch,3,0)''',
        substitutionValues: {'id': uuid.v4(), 'branch': branch, 'disposal': disposal, 'batch': batch});

      final repository = PostgresInventoryApprovalRepository(db);
      final payload = {'disposalId': disposal, 'approvedByUserId': user};
      final first = await repository.postDisposal(branchId: branch, payload: payload);
      final retry = await repository.postDisposal(branchId: branch, payload: payload);
      expect(first['status'], 'APPROVED');
      expect(first['netValue'], '6.3704');
      expect(retry['replayed'], isTrue);
      final productRows = await db.mappedResultsQuery(
        'SELECT stock_base_qty::text AS qty FROM products WHERE id=@id AND branch_id=@branch',
        substitutionValues: {'id': product, 'branch': branch});
      final batchRows = await db.mappedResultsQuery(
        'SELECT total_base_qty::text AS qty FROM product_batches_fefo WHERE id=@id AND branch_id=@branch',
        substitutionValues: {'id': batch, 'branch': branch});
      expect(productRows.single.values.first['qty'], '7.000000');
      expect(batchRows.single.values.first['qty'], '7.000000');
      final journalRows = await db.mappedResultsQuery(
        '''SELECT SUM(dr_amount)::text AS debit,SUM(cr_amount)::text AS credit
           FROM journal_lines WHERE journal_entry_id=@id''',
        substitutionValues: {'id': first['journalEntryId']});
      expect(journalRows.single.values.first['debit'], journalRows.single.values.first['credit']);
      final movementRows = await db.mappedResultsQuery(
        '''SELECT COUNT(*)::int AS count FROM stock_movements
           WHERE branch_id=@branch AND doc_type='DISPOSAL' AND doc_id=@doc''',
        substitutionValues: {'branch': branch, 'doc': disposal});
      expect(movementRows.single.values.first['count'], 1);
    } finally {
      await db.close();
    }
  }, skip: !enabled ? 'PGTEST_HOST is not configured' : false);
  test('mixed stocktake, disposal and stock transfer batch is atomic and idempotent', () async {
    if (!enabled) return;
    final env = Platform.environment;
    final db = PostgreSQLConnection(env['PGTEST_HOST']!,
      int.tryParse(env['PGTEST_PORT'] ?? '5432') ?? 5432,
      env['PGTEST_DATABASE']!, username: env['PGTEST_USER']!,
      password: env['PGTEST_PASSWORD']!, timeoutInSeconds: 30);
    await db.open();
    try {
      const uuid = Uuid();
      final branch = uuid.v4(), user = uuid.v4(), product = uuid.v4();
      final source = uuid.v4(), destination = uuid.v4();
      final batchStocktake = uuid.v4(), batchDisposal = uuid.v4(), batchTransfer = uuid.v4();
      final session = uuid.v4(), disposal = uuid.v4(), transfer = uuid.v4();
      final suffix = branch.substring(0, 8);
      await _fixture(db, branch, user, product, source, batchStocktake, suffix);
      await db.execute(
        'UPDATE products SET stock_base_qty=30 WHERE id=@product AND branch_id=@branch',
        substitutionValues: {'product': product, 'branch': branch});
      await db.execute(
        '''INSERT INTO warehouses (id,branch_id,code,name_ar)
           VALUES (@id,@branch,@code,'Transfer destination')''',
        substitutionValues: {'id': destination, 'branch': branch, 'code': 'IA-DST-$suffix'});
      for (final entry in [
        {'id': batchDisposal, 'number': 'IA-DSP-$suffix'},
        {'id': batchTransfer, 'number': 'IA-TRF-$suffix'},
      ]) {
        await db.execute(
          '''INSERT INTO product_batches_fefo
            (id,branch_id,product_id,warehouse_id,batch_no,expiry_date,
             pack_conversion_factor,sealed_cartons,loose_base_qty,status,unit_cost_base)
           VALUES (@id,@branch,@product,@warehouse,@batch,CURRENT_DATE+90,10,1,0,'ACTIVE',2.123456)''',
          substitutionValues: {'id': entry['id'], 'branch': branch, 'product': product,
            'warehouse': source, 'batch': entry['number']});
      }
      await db.execute(
        '''INSERT INTO stocktaking_sessions
          (id,branch_id,warehouse_id,session_no,status,completed_at)
         VALUES (@id,@branch,@warehouse,@number,'COUNTING',now())''',
        substitutionValues: {'id': session, 'branch': branch, 'warehouse': source,
          'number': 'STK-MIX-$suffix'});
      await db.execute(
        '''INSERT INTO stocktaking_lines
          (id,branch_id,session_id,product_id,product_batch_id,expected_base_qty,
           counted_sealed_cartons,counted_loose_base_qty,pack_conversion_factor,counted_at)
         VALUES (@id,@branch,@session,@product,@batch,10,0,9,10,now())''',
        substitutionValues: {'id': uuid.v4(), 'branch': branch, 'session': session,
          'product': product, 'batch': batchStocktake});
      await db.execute(
        '''INSERT INTO disposals
          (id,branch_id,warehouse_id,disposal_no,reason,status,disposal_date)
         VALUES (@id,@branch,@warehouse,@number,'DAMAGED','DRAFT',now())''',
        substitutionValues: {'id': disposal, 'branch': branch, 'warehouse': source,
          'number': 'DSP-MIX-$suffix'});
      await db.execute(
        '''INSERT INTO disposal_items
          (id,branch_id,disposal_id,product_batch_id,qty_base,unit_cost_base)
         VALUES (@id,@branch,@disposal,@batch,1,0)''',
        substitutionValues: {'id': uuid.v4(), 'branch': branch, 'disposal': disposal,
          'batch': batchDisposal});

      final operations = [
        SyncOperation(operationId: uuid.v4(), operationType: 'STOCKTAKE_APPROVE',
          payload: {'sessionId': session, 'approvedByUserId': user}),
        SyncOperation(operationId: uuid.v4(), operationType: 'DISPOSAL_APPROVE',
          payload: {'disposalId': disposal, 'approvedByUserId': user}),
        SyncOperation(operationId: uuid.v4(), operationType: 'STOCK_TRANSFER',
          payload: {'transferId': transfer, 'transferNo': 'TRF-MIX-$suffix',
            'sourceWarehouseId': source, 'destinationWarehouseId': destination,
            'items': [{'productBatchId': batchTransfer, 'qtyBase': '4.000000'}]}),
      ];
      final command = SyncBatchCommand(
        branchId: branch, batchId: uuid.v4(), idempotencyKey: 'inventory-mixed-$suffix-key',
        requestHash: List.filled(64, 'a').join(), operations: operations);
      final repository = PostgresSalesSyncRepository(db);
      final first = await repository.processBatch(command);
      final retry = await repository.processBatch(command);
      expect((first['acceptedIds'] as List).length, 3);
      expect(first['results'], contains(operations[2].operationId));
      expect(retry['replayed'], isTrue);

      // A new batch envelope with the same operation IDs must replay the receipts,
      // not apply the inventory effects a second time.
      final operationReplay = await repository.processBatch(SyncBatchCommand(
        branchId: branch, batchId: uuid.v4(),
        idempotencyKey: 'inventory-operation-replay-$suffix',
        requestHash: List.filled(64, 'c').join(), operations: operations));
      expect((operationReplay['acceptedIds'] as List).length, 3);

      final mismatchedTransfer = Map<String, dynamic>.from(operations[2].payload)
        ..['items'] = [{'productBatchId': batchTransfer, 'qtyBase': '5.000000'}];
      await expectLater(repository.processBatch(SyncBatchCommand(
        branchId: branch, batchId: uuid.v4(),
        idempotencyKey: 'inventory-operation-mismatch-$suffix',
        requestHash: List.filled(64, 'd').join(),
        operations: [SyncOperation(
          operationId: operations[2].operationId,
          operationType: 'STOCK_TRANSFER',
          payload: mismatchedTransfer,
        )],
      )), throwsA(isA<StateError>()));

      final totals = await db.mappedResultsQuery(
        '''SELECT stock_base_qty::text AS qty FROM products
           WHERE id=@product AND branch_id=@branch''',
        substitutionValues: {'product': product, 'branch': branch});
      expect(totals.single.values.first['qty'], '28.000000');
      final destinationRows = await db.mappedResultsQuery(
        '''SELECT total_base_qty::text AS qty, batch_no AS "batchNumber",
                  unit_cost_base::text AS cost
           FROM product_batches_fefo
           WHERE branch_id=@branch AND product_id=@product AND warehouse_id=@warehouse''',
        substitutionValues: {'branch': branch, 'product': product, 'warehouse': destination});
      expect(destinationRows.single.values.first['qty'], '4.000000');
      expect(destinationRows.single.values.first['batchNumber'], 'IA-TRF-$suffix');
      expect(destinationRows.single.values.first['cost'], '2.123456');
      final movements = await db.mappedResultsQuery(
        '''SELECT movement_type AS type, COUNT(*)::int AS count
           FROM stock_movements WHERE branch_id=@branch
             AND doc_type='STOCK_TRANSFER' AND doc_id=@transfer
           GROUP BY movement_type ORDER BY movement_type''',
        substitutionValues: {'branch': branch, 'transfer': transfer});
      expect(movements.length, 2);
      expect(movements.map((row) => row.values.first['type']).toSet(),
        {'TRANSFER_IN', 'TRANSFER_OUT'});

      // A valid stocktake followed by an invalid transfer must roll back as one batch.
      final rollbackSession = uuid.v4();
      await db.execute(
        '''INSERT INTO stocktaking_sessions
          (id,branch_id,warehouse_id,session_no,status,completed_at)
         VALUES (@id,@branch,@warehouse,@number,'COUNTING',now())''',
        substitutionValues: {'id': rollbackSession, 'branch': branch, 'warehouse': source,
          'number': 'STK-ROLLBACK-$suffix'});
      await db.execute(
        '''INSERT INTO stocktaking_lines
          (id,branch_id,session_id,product_id,product_batch_id,expected_base_qty,
           counted_sealed_cartons,counted_loose_base_qty,pack_conversion_factor,counted_at)
         VALUES (@id,@branch,@session,@product,@batch,9,0,8,10,now())''',
        substitutionValues: {'id': uuid.v4(), 'branch': branch, 'session': rollbackSession,
          'product': product, 'batch': batchDisposal});
      final rollbackTransfer = uuid.v4();
      final rollbackCommand = SyncBatchCommand(
        branchId: branch, batchId: uuid.v4(), idempotencyKey: 'inventory-rollback-$suffix-key',
        requestHash: List.filled(64, 'b').join(),
        operations: [
          SyncOperation(operationId: uuid.v4(), operationType: 'STOCKTAKE_APPROVE',
            payload: {'sessionId': rollbackSession, 'approvedByUserId': user}),
          SyncOperation(operationId: uuid.v4(), operationType: 'STOCK_TRANSFER',
            payload: {'transferId': rollbackTransfer, 'transferNo': 'TRF-BAD-$suffix',
              'sourceWarehouseId': source, 'destinationWarehouseId': destination,
              'items': [{'productBatchId': batchTransfer, 'qtyBase': '999.000000'}]}),
        ]);
      await expectLater(repository.processBatch(rollbackCommand), throwsA(anything));
      final rolledBack = await db.mappedResultsQuery(
        'SELECT id FROM stock_transfers WHERE id=@id AND branch_id=@branch',
        substitutionValues: {'id': rollbackTransfer, 'branch': branch});
      expect(rolledBack, isEmpty);
      final rollbackState = await db.mappedResultsQuery(
        '''SELECT status FROM stocktaking_sessions
           WHERE id=@id AND branch_id=@branch''',
        substitutionValues: {'id': rollbackSession, 'branch': branch});
      expect(rollbackState.single.values.first['status'], 'COUNTING');
      final postRollbackStock = await db.mappedResultsQuery(
        'SELECT stock_base_qty::text AS qty FROM products WHERE id=@id AND branch_id=@branch',
        substitutionValues: {'id': product, 'branch': branch});
      expect(postRollbackStock.single.values.first['qty'], '28.000000');
    } finally {
      await db.close();
    }
  }, skip: !enabled ? 'PGTEST_HOST is not configured' : false);
}

Future<void> _fixture(PostgreSQLConnection db, String branch, String user,
    String product, String warehouse, String batch, String suffix) async {
  await db.execute(
    'INSERT INTO branches (id,code,name_ar) VALUES (@id,@code,@name)',
    substitutionValues: {'id': branch, 'code': 'IA-$suffix', 'name': 'Inventory approval test'});
  await db.execute(
    '''INSERT INTO users (id,branch_id,username,full_name,role_code,is_active)
       VALUES (@id,@branch,@username,'Inventory approver','OWNER',TRUE)''',
    substitutionValues: {'id': user, 'branch': branch, 'username': 'ia-$suffix'});
  await db.execute(
    '''INSERT INTO products (id,branch_id,sku_code,name_ar,base_unit_name,stock_base_qty,avg_cost_base_unit)
       VALUES (@id,@branch,@sku,'Approval test product','piece',10,2)''',
    substitutionValues: {'id': product, 'branch': branch, 'sku': 'IA-SKU-$suffix'});
  await db.execute(
    '''INSERT INTO warehouses (id,branch_id,code,name_ar)
       VALUES (@id,@branch,@code,'Approval test warehouse')''',
    substitutionValues: {'id': warehouse, 'branch': branch, 'code': 'IA-WH-$suffix'});
  await db.execute(
    '''INSERT INTO product_batches_fefo
       (id,branch_id,product_id,warehouse_id,batch_no,expiry_date,
        pack_conversion_factor,sealed_cartons,loose_base_qty,status,unit_cost_base)
       VALUES (@id,@branch,@product,@warehouse,@batch,CURRENT_DATE+90,10,1,0,'ACTIVE',2.123456)''',
    substitutionValues: {'id': batch, 'branch': branch, 'product': product,
      'warehouse': warehouse, 'batch': 'IA-BATCH-$suffix'});
  await db.execute(
    '''INSERT INTO chart_of_accounts (id,branch_id,code,name_ar,account_type)
       VALUES (@inventory,@branch,'1200','Inventory','ASSET'),
              (@gain,@branch,'4100','Stocktake gain','REVENUE'),
              (@loss,@branch,'5100','Inventory loss','EXPENSE')''',
    substitutionValues: {'inventory': 'coa-inv-$suffix', 'gain': 'coa-gain-$suffix',
      'loss': 'coa-loss-$suffix', 'branch': branch});



}
