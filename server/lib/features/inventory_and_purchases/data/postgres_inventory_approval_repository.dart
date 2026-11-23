import 'package:core_contracts/scaled_decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

/// Transaction-aware approval posting. The caller owns the transaction.
final class PostgresInventoryApprovalRepository {
  PostgresInventoryApprovalRepository(this.connection);
  final PostgreSQLConnection connection;
  static const _uuid = Uuid();


  /// Creates a counted stocktake session without applying inventory adjustments.
  ///
  /// The session ID and line IDs are stable idempotency identities. Replaying
  /// the same request returns the existing session; reusing an identity with a
  /// different payload is rejected. Expected quantities and conversion factors
  /// are read from branch-owned FEFO batches, never trusted from the client.
  Future<Map<String, Object?>> createStocktakeSession({
    required String branchId,
    required Map<String, dynamic> payload,
  }) =>
      connection.transaction((ctx) => createStocktakeSessionInTransaction(
            ctx,
            branchId: branchId,
            payload: payload,
          )).then((value) => Map<String, Object?>.from(value));

  /// Creates a stocktake inside the caller's batch transaction.
  Future<Map<String, Object?>> createStocktakeSessionInTransaction(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required Map<String, dynamic> payload,
  }) async {
      final id = _required(payload, 'sessionId');
      final warehouse = _required(payload, 'warehouseId');
      final number = _required(payload, 'sessionNo');
      final blindValue = payload['blindCount'] ?? true;
      if (blindValue is! bool) {
        throw const FormatException('blindCount must be a boolean.');
      }
      final rawLines = payload['lines'];
      if (rawLines is! List || rawLines.isEmpty || rawLines.length > 500) {
        throw const FormatException('A stocktake must contain between 1 and 500 counted lines.');
      }
      final requestedLines = <Map<String, dynamic>>[];
      final seenBatches = <String>{};
      for (final raw in rawLines) {
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Every stocktake line must be a JSON object.');
        }
        final lineId = _required(raw, 'id');
        final product = _required(raw, 'productId');
        final batch = _required(raw, 'productBatchId');
        if (!seenBatches.add(batch)) {
          throw const FormatException('A stocktake cannot contain the same batch more than once.');
        }
        final cartons = raw['countedSealedCartons'];
        if (cartons is! int || cartons < 0) {
          throw const FormatException('countedSealedCartons must be a non-negative integer.');
        }
        final loose = _decimal6(_required(raw, 'countedLooseBaseQty'));
        if (loose.isNegative) {
          throw const FormatException('countedLooseBaseQty cannot be negative.');
        }
        requestedLines.add({
          'id': lineId,
          'productId': product,
          'productBatchId': batch,
          'countedSealedCartons': cartons,
          'countedLooseBaseQty': loose.toFixedString(),
          if (raw['expectedBaseQty'] != null)
            'expectedBaseQty': _required(raw, 'expectedBaseQty'),
          if (raw['packConversionFactor'] != null)
            'packConversionFactor': _required(raw, 'packConversionFactor'),
        });
      }

      final existingRows = await ctx.mappedResultsQuery(
        '''SELECT id, warehouse_id AS warehouse, session_no AS number, status,
                  blind_count AS blind, started_at AS started,
                  completed_at AS completed, approved_at AS approved
           FROM stocktaking_sessions
           WHERE id=@id AND branch_id=@branch FOR UPDATE''',
        substitutionValues: {'id': id, 'branch': branchId});
      if (existingRows.isNotEmpty) {
        final existing = _flat(existingRows.single);
        final existingLineRows = await ctx.mappedResultsQuery(
          '''SELECT id, product_id AS product, product_batch_id AS batch,
                    expected_base_qty::text AS expected,
                    counted_sealed_cartons AS cartons,
                    counted_loose_base_qty::text AS loose,
                    pack_conversion_factor::text AS factor
             FROM stocktaking_lines
             WHERE session_id=@id AND branch_id=@branch
             ORDER BY product_batch_id, id FOR UPDATE''',
          substitutionValues: {'id': id, 'branch': branchId});
        final persisted = <String, Map<String, Object?>>{
          for (final row in existingLineRows) _flat(row)['batch'].toString(): _flat(row),
        };
        var matches = existing['warehouse'] == warehouse &&
            existing['number'] == number &&
            existing['blind'] == blindValue &&
            persisted.length == requestedLines.length;
        for (final line in requestedLines) {
          final saved = persisted[line['productBatchId']];
          if (saved == null ||
              saved['id'] != line['id'] ||
              saved['product'] != line['productId'] ||
              saved['cartons'] != line['countedSealedCartons'] ||
              _decimal6(saved['loose']).compareTo(_decimal6(line['countedLooseBaseQty'])) != 0 ||
              (line['expectedBaseQty'] != null &&
                  _decimal6(saved['expected']).compareTo(_decimal6(line['expectedBaseQty'])) != 0) ||
              (line['packConversionFactor'] != null &&
                  _decimal6(saved['factor']).compareTo(_decimal6(line['packConversionFactor'])) != 0)) {
            matches = false;
            break;
          }
        }
        if (!matches) throw StateError('IDEMPOTENCY_KEY_REUSED');
        return _stocktakeSessionResponse(existing, true);
      }

      final warehouseRows = await ctx.mappedResultsQuery(
        '''SELECT id FROM warehouses
           WHERE id=@warehouse AND branch_id=@branch AND is_active=TRUE
           FOR SHARE''',
        substitutionValues: {'warehouse': warehouse, 'branch': branchId});
      if (warehouseRows.isEmpty) {
        throw StateError('Stocktake warehouse is not active in this branch.');
      }
      final normalizedLines = <Map<String, dynamic>>[];
      for (final line in requestedLines) {
        final batchRows = await ctx.mappedResultsQuery(
          '''SELECT product_id AS product, warehouse_id AS warehouse,
                    total_base_qty::text AS expected,
                    pack_conversion_factor::text AS factor
             FROM product_batches_fefo
             WHERE id=@batch AND branch_id=@branch
               AND warehouse_id=@warehouse FOR SHARE''',
          substitutionValues: {
            'batch': line['productBatchId'],
            'branch': branchId,
            'warehouse': warehouse,
          });
        if (batchRows.isEmpty) {
          throw StateError('Stocktake batch is not in the selected warehouse and branch.');
        }
        final batch = _flat(batchRows.single);
        if (batch['product'] != line['productId']) {
          throw StateError('Stocktake product does not match its FEFO batch.');
        }
        final expected = _decimal6(batch['expected']);
        final factor = _decimal6(batch['factor']);
        if (line['expectedBaseQty'] != null &&
            expected.compareTo(_decimal6(line['expectedBaseQty'])) != 0) {
          throw StateError('Batch stock changed before the stocktake session was created.');
        }
        if (line['packConversionFactor'] != null &&
            factor.compareTo(_decimal6(line['packConversionFactor'])) != 0) {
          throw StateError('Stocktake conversion factor differs from the FEFO batch.');
        }
        final loose = _decimal6(line['countedLooseBaseQty']);
        if (loose.compareTo(factor) >= 0) {
          throw const FormatException('countedLooseBaseQty must be less than the pack conversion factor.');
        }
        normalizedLines.add({
          ...line,
          'expectedBaseQty': expected.toFixedString(),
          'packConversionFactor': factor.toFixedString(),
        });
      }
      final duplicateNumber = await ctx.mappedResultsQuery(
        '''SELECT id FROM stocktaking_sessions
           WHERE branch_id=@branch AND session_no=@number''',
        substitutionValues: {'branch': branchId, 'number': number});
      if (duplicateNumber.isNotEmpty) {
        throw StateError('Stocktake session number already exists in this branch.');
      }
      await ctx.execute(
        '''INSERT INTO stocktaking_sessions
          (id,branch_id,warehouse_id,session_no,status,blind_count,started_at)
         VALUES (@id,@branch,@warehouse,@number,'COUNTING',@blind,now())''',
        substitutionValues: {
          'id': id, 'branch': branchId, 'warehouse': warehouse,
          'number': number, 'blind': blindValue,
        });
      await _insertStocktakeLines(ctx, branchId, id, normalizedLines);
      final createdRows = await ctx.mappedResultsQuery(
        '''SELECT id, warehouse_id AS warehouse, session_no AS number, status,
                  blind_count AS blind, started_at AS started,
                  completed_at AS completed, approved_at AS approved
           FROM stocktaking_sessions
           WHERE id=@id AND branch_id=@branch''',
        substitutionValues: {'id': id, 'branch': branchId});
      return _stocktakeSessionResponse(_flat(createdRows.single), false);

  }

  /// Persists one cold-storage temperature reading inside the caller's batch.
  Future<Map<String, Object?>> recordFridgeTemperatureInTransaction(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required Map<String, dynamic> payload,
  }) async {
    final id = _required(payload, 'logId');
    final warehouse = _required(payload, 'warehouseId');
    final temperature = ScaledDecimal.fromString(
      _required(payload, 'temperatureC'),
      scale: 2,
    );
    final measuredAtValue = payload['measuredAt'];
    final measuredAt = measuredAtValue == null
        ? DateTime.now().toUtc()
        : DateTime.parse(measuredAtValue.toString()).toUtc();
    final location = payload['locationId']?.toString();
    final user = payload['recordedByUserId']?.toString();

    final warehouseRows = await ctx.mappedResultsQuery(
      '''SELECT id FROM warehouses
         WHERE id=@warehouse AND branch_id=@branch AND is_active=TRUE
         FOR SHARE''',
      substitutionValues: {'warehouse': warehouse, 'branch': branchId},
    );
    if (warehouseRows.isEmpty) {
      throw StateError('Temperature-log warehouse is not active in this branch.');
    }
    if (location != null && location.isNotEmpty) {
      final locationRows = await ctx.mappedResultsQuery(
        '''SELECT id FROM aisle_shelf_locations
           WHERE id=@location AND branch_id=@branch AND warehouse_id=@warehouse
             AND is_active=TRUE FOR SHARE''',
        substitutionValues: {
          'location': location,
          'branch': branchId,
          'warehouse': warehouse,
        },
      );
      if (locationRows.isEmpty) {
        throw StateError('Temperature-log location does not belong to this warehouse and branch.');
      }
    }
    if (user != null && user.isNotEmpty) {
      final userRows = await ctx.mappedResultsQuery(
        '''SELECT id FROM users
           WHERE id=@user AND branch_id=@branch AND is_active=TRUE FOR SHARE''',
        substitutionValues: {'user': user, 'branch': branchId},
      );
      if (userRows.isEmpty) {
        throw StateError('Temperature-log recorder is not active in this branch.');
      }
    }
    await ctx.execute(
      '''INSERT INTO fridge_temp_logs
        (id,branch_id,warehouse_id,location_id,temperature_c,measured_at,
         recorded_by_user_id,note)
       VALUES (@id,@branch,@warehouse,@location,@temperature,@measuredAt,@user,@note)''',
      substitutionValues: {
        'id': id,
        'branch': branchId,
        'warehouse': warehouse,
        'location': location == null || location.isEmpty ? null : location,
        'temperature': temperature.toFixedString(),
        'measuredAt': measuredAt,
        'user': user == null || user.isEmpty ? null : user,
        'note': payload['note']?.toString() ?? '',
      },
    );
    return {
      'logId': id,
      'warehouseId': warehouse,
      'temperatureC': temperature.toFixedString(),
      'measuredAt': measuredAt.toIso8601String(),
    };
  }

  Future<Map<String, Object?>> approveStocktake({
    required String branchId,
    required Map<String, dynamic> payload,
  }) => connection.transaction((ctx) => approveStocktakeInTransaction(
        ctx, branchId: branchId, payload: payload))
      .then((value) => Map<String, Object?>.from(value as Map));

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
      if (rawLines is! List || rawLines.isEmpty) {
        throw FormatException('A new stocktake approval must include counted lines.');
      }
      await ctx.execute(
        '''INSERT INTO stocktaking_sessions
          (id,branch_id,warehouse_id,session_no,status,started_at,completed_at)
         VALUES (@id,@branch,@warehouse,@number,'COUNTING',now(),now())''',
        substitutionValues: {'id': id, 'branch': branchId, 'warehouse': warehouse, 'number': number});
      await _insertStocktakeLines(ctx, branchId, id, rawLines);
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
      return _stocktakeResult(session, id, null, '0.0000', '0.0000', true);
    }
    if (session['status'] != 'COUNTING') {
      throw StateError('Only a COUNTING stocktake can be approved.');
    }
    await _requireActiveUser(ctx, branchId, user);

    var rows = await _stocktakeLines(ctx, branchId, id);
    if (rows.isEmpty) {
      final rawLines = payload['lines'];
      if (rawLines is! List || rawLines.isEmpty) {
        throw StateError('Stocktake has no counted lines.');
      }
      await _insertStocktakeLines(ctx, branchId, id, rawLines);
      rows = await _stocktakeLines(ctx, branchId, id);
    }
    if (rows.isEmpty) throw StateError('Stocktake has no counted lines.');

    var gains = ScaledDecimal.fromString('0', scale: 4);
    var losses = ScaledDecimal.fromString('0', scale: 4);
    final seenBatches = <String>{};
    final now = DateTime.now().toUtc();
    for (final raw in rows) {
      final line = _flat(raw);
      if (line['countedAt'] == null) {
        throw StateError('Every stocktake line must be counted.');
      }
      if (line['batch'] == null) {
        throw StateError('Each stocktake line must identify a FEFO batch in this warehouse.');
      }
      final batchId = line['batch'].toString();
      if (!seenBatches.add(batchId)) {
        throw StateError('A stocktake cannot count the same batch more than once.');
      }
      final batchRows = await ctx.mappedResultsQuery(
        '''SELECT warehouse_id AS warehouse, total_base_qty::text AS actual,
                  pack_conversion_factor::text AS factor, unit_cost_base::text AS cost
           FROM product_batches_fefo
           WHERE id=@batch AND branch_id=@branch FOR UPDATE''',
        substitutionValues: {'batch': batchId, 'branch': branchId});
      if (batchRows.isEmpty) throw StateError('Stocktake batch was not found in this branch.');
      final batch = _flat(batchRows.single);
      if (batch['warehouse'] != session['warehouse']) {
        throw StateError('Each stocktake batch must belong to the session warehouse.');
      }
      if (_decimal6(line['factor']).compareTo(_decimal6(batch['factor'])) != 0) {
        throw StateError('Stocktake conversion factor differs from the batch factor.');
      }
      if (_decimal6(line['expected']).compareTo(_decimal6(batch['actual'])) != 0) {
        throw StateError('Batch stock changed after counting; recount before approval.');
      }
      final variance = _decimal6(line['variance']);
      final cost = _decimal6(batch['cost']);
      final absoluteVariance = _absolute(variance);
      final value = absoluteVariance.multiply(cost, resultScale: 4);
      if (variance.isNegative) {
        losses = losses + value;
      } else if (!variance.isZero) {
        gains = gains + value;
      }

      await ctx.execute(
        '''UPDATE product_batches_fefo
           SET sealed_cartons=@cartons, loose_base_qty=@loose,
               status=CASE WHEN @counted::numeric=0 THEN 'DEPLETED'
                 WHEN status='DEPLETED' AND expiry_date<CURRENT_DATE THEN 'EXPIRED'
                 WHEN status='DEPLETED' THEN 'ACTIVE' ELSE status END,
               updated_at=@now
           WHERE id=@batch AND branch_id=@branch AND warehouse_id=@warehouse''',
        substitutionValues: {
          'cartons': line['cartons'],
          'loose': line['loose'],
          'counted': line['counted'],
          'now': now,
          'batch': batchId,
          'branch': branchId,
          'warehouse': session['warehouse']});
      if (!variance.isZero) {
        await _applyProductDelta(ctx, branchId, line['product'].toString(),
            variance.toFixedString(), now);
        await _movement(ctx, branchId, line['product'].toString(),
          session['warehouse'].toString(), batchId, variance.toFixedString(),
          cost.toFixedString(), 'STOCKTAKE_ADJUSTMENT',
          'STOCKTAKE', id, session['number'].toString(), now);
      }
    }

    final gain = gains.toFixedString();
    final loss = losses.toFixedString();
    String? journal;
    if (!gains.isZero || !losses.isZero) {
      journal = await _postJournal(ctx, branchId, 'STOCKTAKE', id,
        'STK-' + id, now, 'Stocktake ' + session['number'].toString(), [
        if (!gains.isZero) _jline('1200', gain, '0.0000', 'Inventory surplus'),
        if (!gains.isZero) _jline('4100', '0.0000', gain, 'Stocktake surplus'),
        if (!losses.isZero) _jline('5100', loss, '0.0000', 'Inventory shrinkage'),
        if (!losses.isZero) _jline('1200', '0.0000', loss, 'Inventory shrinkage'),
      ]);
    }
    await ctx.execute(
      '''UPDATE stocktaking_sessions SET status='APPROVED', approved_at=@now,
         completed_at=COALESCE(completed_at,@now), approved_by_user_id=@user
         WHERE id=@id AND branch_id=@branch AND status='COUNTING' ''',
      substitutionValues: {'now': now, 'user': user, 'id': id, 'branch': branchId});
    session['completed'] = now;
    session['approved'] = now;
    return _stocktakeResult(session, id, journal, gain, loss, false);
  }

  Future<Map<String, Object?>> postDisposal({
    required String branchId,
    required Map<String, dynamic> payload,
  }) => connection.transaction((ctx) => postDisposalInTransaction(
        ctx, branchId: branchId, payload: payload))
      .then((value) => Map<String, Object?>.from(value as Map));

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
      if (rawItems is! List || rawItems.isEmpty) {
        throw FormatException('A new disposal approval must include batch items.');
      }
      await ctx.execute(
        '''INSERT INTO disposals (id,branch_id,warehouse_id,disposal_no,reason,status,disposal_date,notes)
           VALUES (@id,@branch,@warehouse,@number,@reason,'DRAFT',@date,@notes)''',
        substitutionValues: {'id': id, 'branch': branchId, 'warehouse': warehouse,
          'number': number, 'reason': reason,
          'date': payload['disposalDate'] == null ? DateTime.now().toUtc() :
            DateTime.parse(payload['disposalDate'].toString()).toUtc(),
          'notes': payload['notes']?.toString() ?? ''});
      await _insertDisposalItems(ctx, branchId, id, rawItems);
      headers = await _disposalHeader(ctx, branchId, id);
    }
    if (headers.isEmpty) throw StateError('Disposal not found in this branch.');
    final header = _flat(headers.single);
    if (header['status'] == 'APPROVED') {
      final valueRows = await ctx.mappedResultsQuery(
        '''SELECT COALESCE(round(sum(qty_base * unit_cost_base),4),0)::text AS value
           FROM disposal_items WHERE disposal_id=@id AND branch_id=@branch''',
        substitutionValues: {'id': id, 'branch': branchId});
      return _disposalResponse(header, true,
          _flat(valueRows.single)['value'].toString(), header['journal']?.toString());
    }
    if (header['status'] != 'DRAFT') {
      throw StateError('Only a DRAFT disposal can be approved.');
    }
    await _requireActiveUser(ctx, branchId, user);

    var items = await _disposalItems(ctx, branchId, id);
    if (items.isEmpty) {
      final rawItems = payload['items'];
      if (rawItems is! List || rawItems.isEmpty) {
        throw StateError('Disposal must contain at least one batch item.');
      }
      await _insertDisposalItems(ctx, branchId, id, rawItems);
      items = await _disposalItems(ctx, branchId, id);
    }
    if (items.isEmpty) throw StateError('Disposal must contain at least one batch item.');

    var value = ScaledDecimal.fromString('0', scale: 4);
    final seenBatches = <String>{};
    final now = DateTime.now().toUtc();
    for (final raw in items) {
      final item = _flat(raw);
      if (item['warehouse'] != header['warehouse']) {
        throw StateError('Disposal batch belongs to a different warehouse.');
      }
      final batchId = item['batch'].toString();
      if (!seenBatches.add(batchId)) {
        throw StateError('A disposal cannot list the same batch more than once.');
      }
      if (item['quantityValid'] != true) {
        throw StateError('Disposal quantity exceeds available batch stock.');
      }
      final quantity = _decimal6(item['quantity']);
      final cost = _decimal6(item['cost']);
      value = value + quantity.multiply(cost, resultScale: 4);
      final negativeQuantity = '-' + quantity.toFixedString();

      await ctx.execute(
        '''UPDATE product_batches_fefo
           SET sealed_cartons=FLOOR((total_base_qty-@quantity)/pack_conversion_factor)::integer,
               loose_base_qty=(total_base_qty-@quantity) -
                 FLOOR((total_base_qty-@quantity)/pack_conversion_factor)*pack_conversion_factor,
               status=CASE WHEN total_base_qty-@quantity=0 THEN 'DEPLETED'
                 WHEN expiry_date<CURRENT_DATE THEN 'EXPIRED' ELSE status END,
               updated_at=@now
           WHERE id=@batch AND branch_id=@branch''',
        substitutionValues: {'quantity': quantity.toFixedString(), 'now': now,
          'batch': batchId, 'branch': branchId});
      await ctx.execute(
        '''UPDATE disposal_items SET unit_cost_base=@cost
           WHERE id=@id AND branch_id=@branch''',
        substitutionValues: {'cost': cost.toFixedString(), 'id': item['id'], 'branch': branchId});
      await _applyProductDelta(ctx, branchId, item['product'].toString(),
          negativeQuantity, now);
      await _movement(ctx, branchId, item['product'].toString(),
        header['warehouse'].toString(), batchId, negativeQuantity,
        cost.toFixedString(), 'DISPOSAL_OUT', 'DISPOSAL', id,
        header['number'].toString(), now);
    }

    final amount = value.toFixedString();
    String? journal;
    if (!value.isZero) {
      journal = await _postJournal(ctx, branchId, 'DISPOSAL', id,
        'DSP-' + id, header['date'] as DateTime? ?? now,
        'Inventory disposal ' + header['number'].toString(), [
        _jline('5100', amount, '0.0000', 'Inventory disposal loss'),
        _jline('1200', '0.0000', amount, 'Inventory removed'),
      ]);
    }
    await ctx.execute(
      '''UPDATE disposals SET status='APPROVED', approved_by_user_id=@user,
         journal_entry_id=@journal WHERE id=@id AND branch_id=@branch AND status='DRAFT' ''',
      substitutionValues: {'user': user, 'journal': journal, 'id': id, 'branch': branchId});
    header['journal'] = journal;
    return _disposalResponse(header, false, amount, journal);
  }


  /// Moves exact FEFO batch quantities between two warehouses in one caller-owned transaction.
  /// The source batch is retained for audit history; a matching destination batch is merged,
  /// otherwise a destination batch is created with the same lot identity and cost metadata.
  Future<Map<String, Object?>> executeStockTransfer({
    required String branchId,
    required Map<String, dynamic> payload,
  }) => connection.transaction((ctx) => executeStockTransferInTransaction(
        ctx, branchId: branchId, payload: payload))
      .then((value) => Map<String, Object?>.from(value as Map));

  Future<Map<String, Object?>> executeStockTransferInTransaction(
    PostgreSQLExecutionContext ctx, {
    required String branchId,
    required Map<String, dynamic> payload,
  }) async {
    final id = _required(payload, 'transferId');
    var headers = await ctx.mappedResultsQuery(
      '''SELECT id, transfer_no AS number,
                source_warehouse_id AS source,
                destination_warehouse_id AS destination,
                status, transfer_date AS date, notes
         FROM stock_transfers
         WHERE id=@id AND branch_id=@branch FOR UPDATE''',
      substitutionValues: {'id': id, 'branch': branchId});
    if (headers.isEmpty) {
      final source = _required(payload, 'sourceWarehouseId');
      final destination = _required(payload, 'destinationWarehouseId');
      final number = _required(payload, 'transferNo');
      final rawItems = payload['items'];
      if (source == destination) {
        throw StateError('Source and destination warehouses must be different.');
      }
      if (rawItems is! List || rawItems.isEmpty) {
        throw FormatException('A stock transfer must contain at least one batch item.');
      }
      await ctx.execute(
        '''INSERT INTO stock_transfers
          (id,branch_id,transfer_no,source_warehouse_id,destination_warehouse_id,
           status,transfer_date,notes)
         VALUES (@id,@branch,@number,@source,@destination,'DRAFT',@date,@notes)''',
        substitutionValues: {
          'id': id, 'branch': branchId, 'number': number,
          'source': source, 'destination': destination,
          'date': payload['transferDate'] == null
              ? DateTime.now().toUtc()
              : DateTime.parse(payload['transferDate'].toString()).toUtc(),
          'notes': payload['notes']?.toString() ?? '',
        });
      for (final raw in rawItems) {
        if (raw is! Map<String, dynamic>) {
          throw FormatException('Every stock transfer item must be an object.');
        }
        final quantity = _decimal6(raw['qtyBase'] ?? raw['quantity']);
        if (quantity.isNegative || quantity.isZero) {
          throw FormatException('Transfer quantities must be positive.');
        }
        final batch = _required(raw, 'productBatchId');
        await ctx.execute(
          '''INSERT INTO stock_transfer_items
            (id,branch_id,transfer_id,product_batch_id,qty_base,cartons_moved)
           SELECT @item,@branch,@transfer,b.id,@quantity,
                  FLOOR(@quantity/b.pack_conversion_factor)::integer
           FROM product_batches_fefo b
           WHERE b.id=@batch AND b.branch_id=@branch
             AND b.warehouse_id=@source''',
          substitutionValues: {
            'item': raw['id'] is String ? raw['id'] : _uuid.v4(),
            'branch': branchId, 'transfer': id, 'quantity': quantity.toFixedString(),
            'batch': batch, 'source': source,
          });
      }
      headers = await ctx.mappedResultsQuery(
        '''SELECT id, transfer_no AS number,
                  source_warehouse_id AS source,
                  destination_warehouse_id AS destination,
                  status, transfer_date AS date, notes
           FROM stock_transfers
           WHERE id=@id AND branch_id=@branch FOR UPDATE''',
        substitutionValues: {'id': id, 'branch': branchId});
    }
    if (headers.isEmpty) throw StateError('Stock transfer not found in this branch.');
    final header = _flat(headers.single);
    if (header['status'] == 'RECEIVED' || header['status'] == 'APPROVED') {
      return _transferResponse(header, true);
    }
    if (header['status'] != 'DRAFT') {
      throw StateError('Only a DRAFT stock transfer can be executed.');
    }
    final source = header['source'].toString();
    final destination = header['destination'].toString();
    if (source == destination) {
      throw StateError('Source and destination warehouses must be different.');
    }
    final warehouseRows = await ctx.mappedResultsQuery(
      '''SELECT id FROM warehouses
         WHERE branch_id=@branch AND id IN (@source,@destination)
           AND is_active=TRUE
         ORDER BY id FOR SHARE''',
      substitutionValues: {'branch': branchId, 'source': source, 'destination': destination});
    if (warehouseRows.length != 2) {
      throw StateError('Both transfer warehouses must be active in this branch.');
    }
    final itemRows = await ctx.mappedResultsQuery(
      '''SELECT i.id, i.product_batch_id AS batch, i.qty_base::text AS quantity,
                i.cartons_moved AS cartons, b.product_id AS product,
                b.batch_no AS "batchNo", b.expiry_date::text AS expiry,
                b.pack_conversion_factor::text AS factor,
                b.total_base_qty::text AS available,
                b.unit_cost_base::text AS cost, b.status AS "batchStatus",
                b.purchase_invoice_item_id AS "purchaseItem", b.created_at AS "sourceCreated",
                b.warehouse_id AS warehouse
         FROM stock_transfer_items i
         JOIN product_batches_fefo b
           ON b.id=i.product_batch_id AND b.branch_id=i.branch_id
         WHERE i.transfer_id=@transfer AND i.branch_id=@branch
         ORDER BY b.product_id,b.expiry_date,b.id
         FOR UPDATE OF i,b''',
      substitutionValues: {'transfer': id, 'branch': branchId});
    if (itemRows.isEmpty) throw StateError('Stock transfer has no batch items.');
    final seen = <String>{};
    final now = DateTime.now().toUtc();
    for (final raw in itemRows) {
      final item = _flat(raw);
      final sourceBatchId = item['batch'].toString();
      if (!seen.add(sourceBatchId)) {
        throw StateError('A stock transfer cannot repeat the same source batch.');
      }
      if (item['warehouse'] != source) {
        throw StateError('Every source batch must belong to the transfer source warehouse.');
      }
      final quantity = _decimal6(item['quantity']);
      final available = _decimal6(item['available']);
      if (quantity.isZero || quantity.isNegative || quantity.compareTo(available) > 0) {
        throw StateError('Transfer quantity exceeds available source batch stock.');
      }
      final remaining = available - quantity;
      await ctx.execute(
        '''UPDATE product_batches_fefo
           SET sealed_cartons=FLOOR(@remaining/pack_conversion_factor)::integer,
               loose_base_qty=@remaining -
                 FLOOR(@remaining/pack_conversion_factor)*pack_conversion_factor,
               status=CASE WHEN @remaining::numeric=0 THEN 'DEPLETED'
                 WHEN expiry_date<CURRENT_DATE THEN 'EXPIRED' ELSE status END,
               updated_at=@now
         WHERE id=@batch AND branch_id=@branch AND warehouse_id=@source''',
        substitutionValues: {'remaining': remaining.toFixedString(), 'now': now,
          'batch': sourceBatchId, 'branch': branchId, 'source': source});

      await ctx.mappedResultsQuery(
        '''SELECT pg_advisory_xact_lock(
             hashtextextended(@lotKey, 0)) AS locked''',
        substitutionValues: {
          'lotKey': branchId + '|' + destination + '|' +
              item['product'].toString() + '|' + item['batchNo'].toString(),
        });
      final destinationRows = await ctx.mappedResultsQuery(
        '''SELECT id, expiry_date::text AS expiry,
                  pack_conversion_factor::text AS factor,
                  unit_cost_base::text AS cost, status,
                  purchase_invoice_item_id AS "purchaseItem"
           FROM product_batches_fefo
           WHERE branch_id=@branch AND product_id=@product
             AND warehouse_id=@destination AND batch_no=@batchNo
           FOR UPDATE''',
        substitutionValues: {'branch': branchId, 'product': item['product'],
          'destination': destination, 'batchNo': item['batchNo']});
      String destinationBatchId;
      if (destinationRows.isNotEmpty) {
        final target = _flat(destinationRows.single);
        if (target['expiry'] != item['expiry'] ||
            _decimal6(target['factor']).compareTo(_decimal6(item['factor'])) != 0 ||
            _decimal6(target['cost']).compareTo(_decimal6(item['cost'])) != 0 ||
            target['purchaseItem']?.toString() != item['purchaseItem']?.toString()) {
          throw StateError('Destination contains a conflicting lot with the same batch number.');
        }
        destinationBatchId = target['id'].toString();
        await ctx.execute(
          '''UPDATE product_batches_fefo
             SET sealed_cartons=FLOOR((total_base_qty+@quantity)/pack_conversion_factor)::integer,
                 loose_base_qty=(total_base_qty+@quantity) -
                   FLOOR((total_base_qty+@quantity)/pack_conversion_factor)*pack_conversion_factor,
                 status=CASE WHEN expiry_date<CURRENT_DATE OR @sourceStatus='EXPIRED' OR status='EXPIRED' THEN 'EXPIRED'
                   WHEN status='HOLD' OR @sourceStatus='HOLD' THEN 'HOLD'
                   ELSE 'ACTIVE' END,
                 updated_at=@now
             WHERE id=@id AND branch_id=@branch''',
          substitutionValues: {'quantity': quantity.toFixedString(), 'sourceStatus': item['batchStatus'],
            'now': now, 'id': destinationBatchId, 'branch': branchId});
      } else {
        destinationBatchId = _uuid.v4();
        await ctx.execute(
          '''INSERT INTO product_batches_fefo
            (id,branch_id,product_id,warehouse_id,location_id,purchase_invoice_item_id,
             batch_no,expiry_date,pack_conversion_factor,sealed_cartons,loose_base_qty,
             status,unit_cost_base,created_at,updated_at)
           SELECT @id,@branch,@product,@destination,NULL,@purchaseItem,@batchNo,@expiry,
             @factor,FLOOR(@quantity::numeric/@factor::numeric)::integer,
             @quantity::numeric-FLOOR(@quantity::numeric/@factor::numeric)*@factor::numeric,
             CASE WHEN @expiry::date<CURRENT_DATE OR @sourceStatus='EXPIRED' THEN 'EXPIRED'
               WHEN @sourceStatus='HOLD' THEN 'HOLD' ELSE 'ACTIVE' END,
             @cost,@createdAt,@now''',
          substitutionValues: {'id': destinationBatchId, 'branch': branchId,
            'product': item['product'], 'destination': destination,
            'batchNo': item['batchNo'], 'expiry': item['expiry'],
            'factor': item['factor'], 'quantity': quantity.toFixedString(),
            'sourceStatus': item['batchStatus'], 'cost': item['cost'],
            'purchaseItem': item['purchaseItem'], 'createdAt': item['sourceCreated'], 'now': now});
      }
      await _movement(ctx, branchId, item['product'].toString(), source,
        sourceBatchId, '-' + quantity.toFixedString(), item['cost'].toString(),
        'TRANSFER_OUT', 'STOCK_TRANSFER', id, header['number'].toString(), now);
      await _movement(ctx, branchId, item['product'].toString(), destination,
        destinationBatchId, quantity.toFixedString(), item['cost'].toString(),
        'TRANSFER_IN', 'STOCK_TRANSFER', id, header['number'].toString(), now);
    }
    await ctx.execute(
      '''UPDATE stock_transfers SET status='RECEIVED'
         WHERE id=@id AND branch_id=@branch AND status='DRAFT' ''',
      substitutionValues: {'id': id, 'branch': branchId});
    header['status'] = 'RECEIVED';
    return _transferResponse(header, false);
  }

  Map<String, Object?> _transferResponse(Map<String, Object?> header, bool replayed) => {
    'id': header['id'],
    'transferNo': header['number'],
    'sourceWarehouseId': header['source'],
    'destinationWarehouseId': header['destination'],
    'status': header['status'],
    'transferDate': (header['date'] as DateTime?)?.toUtc().toIso8601String() ??
        DateTime.now().toUtc().toIso8601String(),
    'notes': header['notes'] ?? '',
    'replayed': replayed,
  };

  Future<List<Map<String, Map<String, Object?>>>> _stocktakeLines(
      PostgreSQLExecutionContext ctx, String branch, String id) =>
    ctx.mappedResultsQuery(
      '''SELECT l.id, l.product_id AS product, l.product_batch_id AS batch,
                l.expected_base_qty::text AS expected,
                l.pack_conversion_factor::text AS factor,
                l.variance_base_qty::text AS variance,
                l.counted_base_qty::text AS counted,
                l.counted_sealed_cartons AS cartons,
                l.counted_loose_base_qty::text AS loose,
                l.counted_at AS "countedAt"
         FROM stocktaking_lines l
         WHERE l.session_id=@id AND l.branch_id=@branch
         ORDER BY l.product_id,l.product_batch_id,l.id
         FOR UPDATE OF l''',
      substitutionValues: {'id': id, 'branch': branch});

  Future<List<Map<String, Map<String, Object?>>>> _disposalHeader(
      PostgreSQLExecutionContext ctx, String branch, String id) =>
    ctx.mappedResultsQuery(
      '''SELECT id, warehouse_id AS warehouse, disposal_no AS number, reason,
                status, disposal_date AS date, notes, journal_entry_id AS journal
         FROM disposals WHERE id=@id AND branch_id=@branch FOR UPDATE''',
      substitutionValues: {'id': id, 'branch': branch});

  Future<List<Map<String, Map<String, Object?>>>> _disposalItems(
      PostgreSQLExecutionContext ctx, String branch, String id) =>
    ctx.mappedResultsQuery(
      '''SELECT i.id, i.product_batch_id AS batch, i.qty_base::text AS quantity,
                b.product_id AS product, b.warehouse_id AS warehouse,
                b.total_base_qty::text AS available, b.unit_cost_base::text AS cost,
                (i.qty_base>0 AND i.qty_base<=b.total_base_qty) AS "quantityValid"
         FROM disposal_items i JOIN product_batches_fefo b
           ON b.id=i.product_batch_id AND b.branch_id=i.branch_id
         WHERE i.disposal_id=@id AND i.branch_id=@branch
         ORDER BY b.product_id,b.id FOR UPDATE OF i,b''',
      substitutionValues: {'id': id, 'branch': branch});

  Future<void> _insertStocktakeLines(PostgreSQLExecutionContext ctx,
      String branch, String session, List<dynamic> lines) async {
    for (final raw in lines) {
      if (raw is! Map<String, dynamic>) throw FormatException('Invalid stocktake line.');
      await ctx.execute(
        '''INSERT INTO stocktaking_lines
          (id,branch_id,session_id,product_id,product_batch_id,expected_base_qty,
           counted_sealed_cartons,counted_loose_base_qty,pack_conversion_factor,counted_at)
         VALUES (@id,@branch,@session,@product,@batch,@expected,@cartons,@loose,@factor,now())''',
        substitutionValues: {'id': raw['id'] is String ? raw['id'] : _uuid.v4(),
          'branch': branch, 'session': session, 'product': _required(raw, 'productId'),
          'batch': _required(raw, 'productBatchId'),
          'expected': raw['expectedBaseQty']?.toString() ?? '0',
          'cartons': raw['countedSealedCartons'] ?? 0,
          'loose': raw['countedLooseBaseQty']?.toString() ?? '0',
          'factor': raw['packConversionFactor']?.toString() ?? '1'});
    }
  }

  Future<void> _insertDisposalItems(PostgreSQLExecutionContext ctx,
      String branch, String disposal, List<dynamic> items) async {
    for (final raw in items) {
      if (raw is! Map<String, dynamic>) throw FormatException('Invalid disposal item.');
      await ctx.execute(
        '''INSERT INTO disposal_items (id,branch_id,disposal_id,product_batch_id,qty_base,unit_cost_base,reason_note)
           VALUES (@item,@branch,@disposal,@batch,@quantity,0,@note)''',
        substitutionValues: {'item': raw['id'] is String ? raw['id'] : _uuid.v4(),
          'branch': branch, 'disposal': disposal, 'batch': _required(raw, 'productBatchId'),
          'quantity': raw['qtyBase']?.toString() ?? raw['quantity']?.toString() ?? '',
          'note': raw['reasonNote']?.toString() ?? ''});
    }
  }

  Future<void> _requireActiveUser(PostgreSQLExecutionContext ctx, String branch, String user) async {
    final rows = await ctx.mappedResultsQuery(
      '''SELECT id FROM users WHERE id=@user AND branch_id=@branch AND is_active=TRUE FOR SHARE''',
      substitutionValues: {'user': user, 'branch': branch});
    if (rows.isEmpty) throw StateError('Approving user is not active in this branch.');
  }

  Future<void> _applyProductDelta(PostgreSQLExecutionContext ctx, String branch,
      String product, String delta, DateTime now) async {
    final changed = await ctx.execute(
      '''UPDATE products SET stock_base_qty=stock_base_qty+@delta,updated_at=@now
         WHERE id=@product AND branch_id=@branch AND stock_base_qty+@delta>=0''',
      substitutionValues: {'delta': delta, 'now': now, 'product': product, 'branch': branch});
    if (changed != 1) throw StateError('Aggregate stock is insufficient or product is outside this branch.');
  }

  Future<void> _movement(PostgreSQLExecutionContext ctx, String branch, String product,
      String warehouse, String batch, String quantity, String cost, String movement,
      String docType, String doc, String reference, DateTime date) async {
    await ctx.execute(
      '''INSERT INTO stock_movements
        (id,branch_id,product_id,movement_date,movement_type,quantity_base,unit_cost_base,
         doc_type,doc_id,warehouse_id,product_batch_id,reference_no,notes)
       VALUES (@id,@branch,@product,@date,@movement,@quantity,@cost,@docType,@doc,
         @warehouse,@batch,@reference,@notes)''',
      substitutionValues: {'id': _uuid.v4(), 'branch': branch, 'product': product,
        'date': date, 'movement': movement, 'quantity': quantity, 'cost': cost,
        'docType': docType, 'doc': doc, 'warehouse': warehouse, 'batch': batch,
        'reference': reference, 'notes': movement == 'DISPOSAL_OUT'
            ? 'Approved disposal'
            : (movement == 'TRANSFER_OUT' || movement == 'TRANSFER_IN')
                ? 'Inter-warehouse stock transfer'
                : 'Approved stocktake adjustment'});
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
          'debit': line['debit'], 'credit': line['credit'], 'memo': line['memo']});
    }
    await ctx.execute(
      '''UPDATE journal_entries SET status='POSTED',posted_at=now()
         WHERE id=@id AND branch_id=@branch''',
      substitutionValues: {'id': id, 'branch': branch});
    return id;
  }

  Map<String, Object?> _jline(String code, String debit, String credit, String memo) =>
      {'code': code, 'debit': debit, 'credit': credit, 'memo': memo};


  Map<String, Object?> _stocktakeSessionResponse(
      Map<String, Object?> session, bool replayed) => {
    'id': session['id'],
    'warehouseId': session['warehouse'],
    'sessionNo': session['number'],
    'status': session['status'],
    'blindCount': session['blind'] == true,
    'startedAt': (session['started'] as DateTime).toUtc().toIso8601String(),
    'completedAt': (session['completed'] as DateTime?)?.toUtc().toIso8601String(),
    'approvedAt': (session['approved'] as DateTime?)?.toUtc().toIso8601String(),
    'replayed': replayed,
  };

  Map<String, Object?> _stocktakeResult(Map<String, Object?> session, String id,
      String? journal, String gain, String loss, bool replayed) => {
    'id': id, 'warehouseId': session['warehouse'], 'sessionNo': session['number'],
    'status': 'APPROVED', 'blindCount': session['blind'] == true,
    'startedAt': (session['started'] as DateTime).toUtc().toIso8601String(),
    'completedAt': (session['completed'] as DateTime?)?.toUtc().toIso8601String(),
    'approvedAt': (session['approved'] as DateTime?)?.toUtc().toIso8601String(),
    'journalEntryId': journal, 'gainValue': gain, 'lossValue': loss, 'replayed': replayed};

  Map<String, Object?> _disposalResponse(Map<String, Object?> header, bool replayed,
      String value, String? journal) => {
    'id': header['id'], 'warehouseId': header['warehouse'], 'disposalNo': header['number'],
    'reason': header['reason'], 'status': 'APPROVED',
    'disposalDate': (header['date'] as DateTime?)?.toUtc().toIso8601String() ??
      DateTime.now().toUtc().toIso8601String(),
    'netValue': value, 'journalEntryId': journal, 'notes': header['notes'] ?? '',
    'replayed': replayed};

  ScaledDecimal _decimal6(Object? value) =>
      ScaledDecimal.fromString(value.toString(), scale: 6);

  ScaledDecimal _absolute(ScaledDecimal value) =>
      ScaledDecimal.fromString(value.toFixedString().replaceFirst('-', ''), scale: 6);

  Map<String, Object?> _flat(Map<String, Map<String, Object?>> row) =>
    row.values.fold<Map<String, Object?>>({}, (out, values) => out..addAll(values));

  String _required(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) throw FormatException(key + ' is required.');
    return value.trim();
  }
}
