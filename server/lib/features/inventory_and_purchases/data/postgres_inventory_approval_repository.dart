import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

/// Transaction-aware approval posting. The caller owns the transaction.
final class PostgresInventoryApprovalRepository {
  PostgresInventoryApprovalRepository(this.connection);
  final PostgreSQLConnection connection;
  static const _uuid = Uuid();

  Future<Map<String, Object?>> approveStocktake({
    required String branchId,
    required Map<String, dynamic> payload,
  }) => connection.transaction((ctx) => approveStocktakeInTransaction(
        ctx, branchId: branchId, payload: payload));

  Future<Map<String, Object?>> approveStocktakeInTransaction(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required Map<String, dynamic> payload,
  }) async {
    final id = _required(payload, 'sessionId');
    final user = _required(payload, 'approvedByUserId');
    var sessions = await ctx.mappedResultsQuery(
      '''SELECT id, warehouse_id AS warehouse, session_no AS number, status,
                blind_count AS blind, started_at AS started, completed_at AS completed,
                approved_at AS approved
         FROM stocktaking_sessions WHERE id=@id AND branch_id=@branch FOR UPDATE''',
      substitutionValues: {'id': id, 'branch': branchId});
    if (sessions.isEmpty) {
      final warehouse = _required(payload, 'warehouseId');
      final number = _required(payload, 'sessionNo');
      final rawLines = payload['lines'];
      if (rawLines is! List || rawLines.isEmpty) throw FormatException('A new stocktake approval must include counted lines.');
      await ctx.execute(
        '''INSERT INTO stocktaking_sessions (id,branch_id,warehouse_id,session_no,status,started_at,completed_at)
           VALUES (@id,@branch,@warehouse,@number,'COUNTING',now(),now())''',
        substitutionValues: {'id': id, 'branch': branchId, 'warehouse': warehouse, 'number': number});
      for (final raw in rawLines) {
        if (raw is! Map<String, dynamic>) throw FormatException('Invalid stocktake line.');
        await ctx.execute(
          '''INSERT INTO stocktaking_lines
            (id,branch_id,session_id,product_id,product_batch_id,expected_base_qty,
             counted_sealed_cartons,counted_loose_base_qty,pack_conversion_factor,counted_at)
           VALUES (@id,@branch,@session,@product,@batch,@expected,@cartons,@loose,@factor,now())''',
          substitutionValues: {'id': raw['id'] is String ? raw['id'] : _uuid.v4(),
            'branch': branchId, 'session': id,
            'product': _required(raw, 'productId'),
            'batch': _required(raw, 'productBatchId'),
            'expected': raw['expectedBaseQty']?.toString() ?? '0',
            'cartons': raw['countedSealedCartons'] ?? 0,
            'loose': raw['countedLooseBaseQty']?.toString() ?? '0',
            'factor': raw['packConversionFactor']?.toString() ?? '1'});
      }
      sessions = await ctx.mappedResultsQuery(
        '''SELECT id, warehouse_id AS warehouse, session_no AS number, status,
                  blind_count AS blind, started_at AS started, completed_at AS completed,
                  approved_at AS approved
           FROM stocktaking_sessions WHERE id=@id AND branch_id=@branch FOR UPDATE''',
        substitutionValues: {'id': id, 'branch': branchId});
    }
    if (sessions.isEmpty) throw StateError('Stocktake session not found in this branch.');
    final session = _flat(sessions.single);
    if (session['status'] == 'APPROVED') {
      return {'id': id, 'warehouseId': session['warehouse'], 'sessionNo': session['number'],
        'status': 'APPROVED', 'blindCount': session['blind'] == true,
        'startedAt': (session['started'] as DateTime).toUtc().toIso8601String(),
        'completedAt': (session['completed'] as DateTime?)?.toUtc().toIso8601String(),
        'approvedAt': (session['approved'] as DateTime?)?.toUtc().toIso8601String(),
        'replayed': true};
    }
    if (session['status'] != 'COUNTING') throw StateError('Only a COUNTING stocktake can be approved.');
    await _requireActiveUser(ctx, branchId, user);

    final rows = await ctx.mappedResultsQuery(
      '''SELECT l.id, l.product_id AS product, l.product_batch_id AS batch,
                l.expected_base_qty::text AS expected, l.counted_base_qty::text AS counted,
                l.variance_base_qty::text AS variance, l.pack_conversion_factor::text AS factor,
                l.counted_at AS counted_at, b.warehouse_id AS warehouse,
                b.pack_conversion_factor::text AS batch_factor,
                b.total_base_qty::text AS actual, b.unit_cost_base::text AS cost
         FROM stocktaking_lines l
         JOIN product_batches_fefo b ON b.id=l.product_batch_id AND b.branch_id=l.branch_id
         WHERE l.session_id=@id AND l.branch_id=@branch
         ORDER BY l.product_id, l.product_batch_id, l.id
         FOR UPDATE OF l, b''',
      substitutionValues: {'id': id, 'branch': branchId});
    if (rows.isEmpty) throw StateError('Stocktake has no counted lines.');

    var gains = 0.0;
    var losses = 0.0;
    final seenBatches = <String>{};
    final deltas = <String, double>{};
    final now = DateTime.now().toUtc();
    for (final raw in rows) {
      final line = _flat(raw);
      if (line['counted_at'] == null) throw StateError('Every stocktake line must be counted.');
      if (line['batch'] == null || line['warehouse'] != session['warehouse']) {
        throw StateError('Each stocktake line must identify a FEFO batch in this warehouse.');
      }
      final batchId = line['batch'].toString();
      if (!seenBatches.add(batchId)) throw StateError('A stocktake cannot count the same batch more than once.');
      final factor = _n(line['factor']);
      final actual = _n(line['actual']);
      final variance = _n(line['variance']);
      final counted = _n(line['counted']);
      if ((factor - _n(line['batch_factor'])).abs() > 0.0000001) {
        throw StateError('Stocktake conversion factor differs from the batch factor.');
      }
      if ((actual - _n(line['expected'])).abs() > 0.0000001) {
        throw StateError('Batch stock changed after counting; recount before approval.');
      }
      if ((counted - actual - variance).abs() > 0.0000001) {
        throw StateError('Stocktake line quantity/variance is inconsistent.');
      }
      final cost = _n(line['cost']);
      if (variance > 0) gains += variance * cost;
      if (variance < 0) losses += -variance * cost;
      final product = line['product'].toString();
      deltas[product] = (deltas[product] ?? 0) + variance;
      final cartons = (counted / factor).floor();
      final loose = counted - cartons * factor;
      await ctx.execute(
        '''UPDATE product_batches_fefo
           SET sealed_cartons=@cartons, loose_base_qty=@loose,
               status=CASE WHEN @counted=0 THEN 'DEPLETED'
                 WHEN status='DEPLETED' AND expiry_date<CURRENT_DATE THEN 'EXPIRED'
                 WHEN status='DEPLETED' THEN 'ACTIVE' ELSE status END,
               updated_at=@now
           WHERE id=@batch AND branch_id=@branch AND warehouse_id=@warehouse''',
        substitutionValues: {
          'cartons': cartons, 'loose': loose.toStringAsFixed(6),
          'counted': counted.toStringAsFixed(6), 'now': now,
          'batch': line['batch'], 'branch': branchId, 'warehouse': session['warehouse']});
      if (variance != 0) {
        await _movement(ctx, branchId, product, session['warehouse'].toString(),
          line['batch'].toString(), variance, cost, 'STOCKTAKE_ADJUSTMENT',
          'STOCKTAKE', id, session['number'].toString(), now);
      }
    }
    await _applyProductDeltas(ctx, branchId, deltas, now);
    final gain = _money(gains);
    final loss = _money(losses);
    String? journal;
    if (gain > 0 || loss > 0) {
      journal = await _postJournal(ctx, branchId, 'STOCKTAKE', id,
        'STK-' + id, now, 'Stocktake ' + session['number'].toString(), [
        if (gain > 0) _jline('1200', gain, 0, 'Inventory surplus'),
        if (gain > 0) _jline('4100', 0, gain, 'Stocktake surplus'),
        if (loss > 0) _jline('5100', loss, 0, 'Inventory shrinkage'),
        if (loss > 0) _jline('1200', 0, loss, 'Inventory shrinkage'),
      ]);
    }
    await ctx.execute(
      '''UPDATE stocktaking_sessions SET status='APPROVED', approved_at=@now,
         completed_at=COALESCE(completed_at,@now), approved_by_user_id=@user
         WHERE id=@id AND branch_id=@branch AND status='COUNTING' ''',
      substitutionValues: {'now': now, 'user': user, 'id': id, 'branch': branchId});
    return {'id': id, 'warehouseId': session['warehouse'], 'sessionNo': session['number'],
      'status': 'APPROVED', 'blindCount': session['blind'] == true,
      'startedAt': (session['started'] as DateTime).toUtc().toIso8601String(),
      'completedAt': now.toIso8601String(), 'approvedAt': now.toIso8601String(),
      'journalEntryId': journal, 'gainValue': gain.toStringAsFixed(4),
      'lossValue': loss.toStringAsFixed(4), 'replayed': false};
  }

  Future<Map<String, Object?>> postDisposal({
    required String branchId,
    required Map<String, dynamic> payload,
  }) => connection.transaction((ctx) => postDisposalInTransaction(
        ctx, branchId: branchId, payload: payload));

  Future<Map<String, Object?>> postDisposalInTransaction(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required Map<String, dynamic> payload,
  }) async {
    final id = _required(payload, 'disposalId');
    final user = _required(payload, 'approvedByUserId');
    var headers = await ctx.mappedResultsQuery(
      '''SELECT id, warehouse_id AS warehouse, disposal_no AS number, reason,
                status, disposal_date AS date, notes, journal_entry_id AS journal
         FROM disposals WHERE id=@id AND branch_id=@branch FOR UPDATE''',
      substitutionValues: {'id': id, 'branch': branchId});
    if (headers.isEmpty) {
      final warehouse = _required(payload, 'warehouseId');
      final number = _required(payload, 'disposalNo');
      final reason = _required(payload, 'reason').toUpperCase();
      final rawItems = payload['items'];
      if (rawItems is! List || rawItems.isEmpty) throw FormatException('A new disposal approval must include batch items.');
      await ctx.execute(
        '''INSERT INTO disposals (id,branch_id,warehouse_id,disposal_no,reason,status,disposal_date,notes)
           VALUES (@id,@branch,@warehouse,@number,@reason,'DRAFT',@date,@notes)''',
        substitutionValues: {'id': id, 'branch': branchId, 'warehouse': warehouse,
          'number': number, 'reason': reason,
          'date': payload['disposalDate'] == null ? DateTime.now().toUtc() : DateTime.parse(payload['disposalDate'].toString()).toUtc(),
          'notes': payload['notes']?.toString() ?? ''});
      for (final raw in rawItems) {
        if (raw is! Map<String, dynamic>) throw FormatException('Invalid disposal item.');
        await ctx.execute(
          '''INSERT INTO disposal_items (id,branch_id,disposal_id,product_batch_id,qty_base,unit_cost_base,reason_note)
             VALUES (@item,@branch,@disposal,@batch,@quantity,0,@note)''',
          substitutionValues: {'item': raw['id'] is String ? raw['id'] : _uuid.v4(),
            'branch': branchId, 'disposal': id,
            'batch': _required(raw, 'productBatchId'),
            'quantity': raw['qtyBase']?.toString() ?? raw['quantity']?.toString() ?? '',
            'note': raw['reasonNote']?.toString() ?? ''});
      }
      headers = await ctx.mappedResultsQuery(
        '''SELECT id, warehouse_id AS warehouse, disposal_no AS number, reason,
                  status, disposal_date AS date, notes, journal_entry_id AS journal
           FROM disposals WHERE id=@id AND branch_id=@branch FOR UPDATE''',
        substitutionValues: {'id': id, 'branch': branchId});
    }
    if (headers.isEmpty) throw StateError('Disposal not found in this branch.');
    final header = _flat(headers.single);
    if (header['status'] == 'APPROVED') {
      return _disposalResponse(header, true, 0, header['journal']?.toString());
    }
    if (header['status'] != 'DRAFT') throw StateError('Only a DRAFT disposal can be approved.');
    await _requireActiveUser(ctx, branchId, user);

    final items = await ctx.mappedResultsQuery(
      '''SELECT i.id, i.product_batch_id AS batch, i.qty_base::text AS quantity,
                b.product_id AS product, b.warehouse_id AS warehouse,
                b.total_base_qty::text AS available, b.unit_cost_base::text AS cost,
                b.pack_conversion_factor::text AS factor
         FROM disposal_items i JOIN product_batches_fefo b
           ON b.id=i.product_batch_id AND b.branch_id=i.branch_id
         WHERE i.disposal_id=@id AND i.branch_id=@branch
         ORDER BY b.product_id, b.id FOR UPDATE OF i,b''',
      substitutionValues: {'id': id, 'branch': branchId});
    if (items.isEmpty) throw StateError('Disposal must contain at least one batch item.');
    var value = 0.0;
    final seenBatches = <String>{};
    final deltas = <String, double>{};
    final now = DateTime.now().toUtc();
    for (final raw in items) {
      final item = _flat(raw);
      if (item['warehouse'] != header['warehouse']) {
        throw StateError('Disposal batch belongs to a different warehouse.');
      }
      final batchId = item['batch'].toString();
      if (!seenBatches.add(batchId)) throw StateError('A disposal cannot list the same batch more than once.');
      final quantity = _n(item['quantity']);
      final available = _n(item['available']);
      if (quantity <= 0 || quantity > available) {
        throw StateError('Disposal quantity exceeds available batch stock.');
      }
      final cost = _n(item['cost']);
      value += quantity * cost;
      final product = item['product'].toString();
      deltas[product] = (deltas[product] ?? 0) - quantity;
      final remaining = available - quantity;
      final factor = _n(item['factor']);
      final cartons = (remaining / factor).floor();
      final loose = remaining - cartons * factor;
      await ctx.execute(
        '''UPDATE product_batches_fefo SET sealed_cartons=@cartons, loose_base_qty=@loose,
           status=CASE WHEN @remaining=0 THEN 'DEPLETED'
             WHEN expiry_date<CURRENT_DATE THEN 'EXPIRED' ELSE status END, updated_at=@now
           WHERE id=@batch AND branch_id=@branch''',
        substitutionValues: {'cartons': cartons, 'loose': loose.toStringAsFixed(6),
          'remaining': remaining.toStringAsFixed(6), 'now': now,
          'batch': item['batch'], 'branch': branchId});
      await ctx.execute(
        'UPDATE disposal_items SET unit_cost_base=@cost WHERE id=@id AND branch_id=@branch',
        substitutionValues: {'cost': cost.toStringAsFixed(6), 'id': item['id'], 'branch': branchId});
      await _movement(ctx, branchId, product, header['warehouse'].toString(),
        item['batch'].toString(), -quantity, cost, 'DISPOSAL_OUT',
        'DISPOSAL', id, header['number'].toString(), now);
    }
    await _applyProductDeltas(ctx, branchId, deltas, now);
    final amount = _money(value);
    String? journal;
    if (amount > 0) {
      journal = await _postJournal(ctx, branchId, 'DISPOSAL', id,
        'DSP-' + id, header['date'] as DateTime? ?? now,
        'Inventory disposal ' + header['number'].toString(), [
        _jline('5100', amount, 0, 'Inventory disposal loss'),
        _jline('1200', 0, amount, 'Inventory removed'),
      ]);
    }
    await ctx.execute(
      '''UPDATE disposals SET status='APPROVED', approved_by_user_id=@user,
         journal_entry_id=@journal WHERE id=@id AND branch_id=@branch AND status='DRAFT' ''',
      substitutionValues: {'user': user, 'journal': journal, 'id': id, 'branch': branchId});
    return _disposalResponse(header, false, amount, journal);
  }

  Future<void> _requireActiveUser(PostgreSQLExecutionContext ctx, String branch, String user) async {
    final rows = await ctx.mappedResultsQuery(
      '''SELECT id FROM users WHERE id=@user AND branch_id=@branch AND is_active=TRUE FOR SHARE''',
      substitutionValues: {'user': user, 'branch': branch});
    if (rows.isEmpty) throw StateError('Approving user is not active in this branch.');
  }

  Future<void> _applyProductDeltas(PostgreSQLExecutionContext ctx, String branch,
      Map<String, double> deltas, DateTime now) async {
    for (final entry in deltas.entries) {
      final changed = await ctx.execute(
        '''UPDATE products SET stock_base_qty=stock_base_qty+@delta, updated_at=@now
           WHERE id=@product AND branch_id=@branch AND stock_base_qty+@delta>=0''',
        substitutionValues: {'delta': entry.value.toStringAsFixed(6), 'now': now,
          'product': entry.key, 'branch': branch});
      if (changed != 1) throw StateError('Aggregate stock is insufficient or product is outside this branch.');
    }
  }

  Future<void> _movement(PostgreSQLExecutionContext ctx, String branch, String product,
      String warehouse, String batch, double quantity, double cost, String movement,
      String docType, String doc, String reference, DateTime date) async {
    await ctx.execute(
      '''INSERT INTO stock_movements
        (id,branch_id,product_id,movement_date,movement_type,quantity_base,unit_cost_base,
         doc_type,doc_id,warehouse_id,product_batch_id,reference_no,notes)
       VALUES (@id,@branch,@product,@date,@movement,@quantity,@cost,@docType,@doc,
         @warehouse,@batch,@reference,@notes)''',
      substitutionValues: {'id': _uuid.v4(), 'branch': branch, 'product': product,
        'date': date, 'movement': movement, 'quantity': quantity.toStringAsFixed(6),
        'cost': cost.toStringAsFixed(6), 'docType': docType, 'doc': doc,
        'warehouse': warehouse, 'batch': batch, 'reference': reference,
        'notes': movement == 'DISPOSAL_OUT' ? 'Approved disposal' : 'Approved stocktake adjustment'});
  }

  Future<String> _postJournal(PostgreSQLExecutionContext ctx, String branch, String type,
      String doc, String number, DateTime date, String description,
      List<Map<String, Object?>> lines) async {
    final accountIds = <String, String>{};
    for (final code in lines.map((line) => line['code'] as String).toSet()) {
      final rows = await ctx.mappedResultsQuery(
        '''SELECT id FROM chart_of_accounts
           WHERE branch_id=@branch AND code=@code AND is_active=TRUE''',
        substitutionValues: {'branch': branch, 'code': code});
      if (rows.isEmpty) throw StateError('Required accounting account is missing: ' + code);
      accountIds[code] = _flat(rows.single)['id'].toString();
    }
    final id = _uuid.v4();
    await ctx.execute(
      '''INSERT INTO journal_entries
        (id,branch_id,entry_no,entry_date,doc_type,doc_id,description,status)
       VALUES (@id,@branch,@number,@date,@type,@doc,@description,'DRAFT')''',
      substitutionValues: {'id': id, 'branch': branch, 'number': number,
        'date': date, 'type': type, 'doc': doc, 'description': description});
    for (final line in lines) {
      await ctx.execute(
        '''INSERT INTO journal_lines (journal_entry_id,gl_account_id,dr_amount,cr_amount,memo)
           VALUES (@entry,@account,@debit,@credit,@memo)''',
        substitutionValues: {'entry': id, 'account': accountIds[line['code']],
          'debit': (line['debit'] as double).toStringAsFixed(4),
          'credit': (line['credit'] as double).toStringAsFixed(4), 'memo': line['memo']});
    }
    await ctx.execute(
      '''UPDATE journal_entries SET status='POSTED',posted_at=now()
         WHERE id=@id AND branch_id=@branch''',
      substitutionValues: {'id': id, 'branch': branch});
    return id;
  }

  Map<String, Object?> _jline(String code, double debit, double credit, String memo) =>
      {'code': code, 'debit': debit, 'credit': credit, 'memo': memo};

  Map<String, Object?> _disposalResponse(Map<String, Object?> header, bool replayed,
      double value, String? journal) => {
    'id': header['id'], 'warehouseId': header['warehouse'], 'disposalNo': header['number'],
    'reason': header['reason'], 'status': 'APPROVED',
    'disposalDate': (header['date'] as DateTime?)?.toUtc().toIso8601String() ??
      DateTime.now().toUtc().toIso8601String(),
    'netValue': value.toStringAsFixed(4), 'journalEntryId': journal,
    'notes': header['notes'] ?? '', 'replayed': replayed};

  Map<String, Object?> _flat(Map<String, Map<String, Object?>> row) =>
    row.values.fold<Map<String, Object?>>({}, (out, values) => out..addAll(values));

  String _required(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) throw FormatException(key + ' is required.');
    return value.trim();
  }

  double _n(Object? value) {
    final result = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
    if (result == null || !result.isFinite) throw FormatException('Invalid numeric value.');
    return result;
  }

  double _money(double value) => double.parse(value.toStringAsFixed(4));
}
