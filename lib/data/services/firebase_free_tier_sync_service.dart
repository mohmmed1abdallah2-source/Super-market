import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';

/// Provider-neutral contract for sending immutable branch sync batches.
abstract class ISyncTransport {
  /// Persists one idempotently identified compressed batch document.
  Future<void> putBatch({
    required String branchId,
    required String batchId,
    required Map<String, Object?> data,
  });

  /// Updates the branch's daily dashboard summary document.
  Future<void> putDailySummary({
    required String documentId,
    required Map<String, Object?> data,
  });
}

/// Firestore implementation of the sync transport; it never runs inside a sale transaction.
class FirestoreSyncTransport implements ISyncTransport {
  FirestoreSyncTransport(this.firestore);
  final FirebaseFirestore firestore;

  @override
  Future<void> putBatch({
    required String branchId,
    required String batchId,
    required Map<String, Object?> data,
  }) async {
    await firestore
        .collection('sync_batches')
        .doc(branchId)
        .collection('batches')
        .doc(batchId)
        .set(data, SetOptions(merge: false));
  }

  @override
  Future<void> putDailySummary({
    required String documentId,
    required Map<String, Object?> data,
  }) async {
    await firestore.collection('daily_summaries').doc(documentId)
        .set(data, SetOptions(merge: true));
  }
}

/// Compresses local pending changes into bounded Firestore documents and tracks quota.
class FirebaseFreeTierSyncService {
  FirebaseFreeTierSyncService({
    required ISyncTransport transport,
    DatabaseHelper? databaseHelper,
    this.maxEventsPerBatch = 100,
    this.dailyWriteSafetyLimit = 18000,
  })  : _transport = transport,
        _helper = databaseHelper ?? DatabaseHelper.instance;

  final ISyncTransport _transport;
  final DatabaseHelper _helper;
  final int maxEventsPerBatch;
  final int dailyWriteSafetyLimit;

  /// Builds a gzip-compressed JSON payload from at most 100 pending local events.
  Future<CompressedSyncBatch?> buildCompressedBatch(String branchId) async {
    final db = await _helper.database;
    final rows = await db.query(
      'sync_queue',
      where: 'branch_id=? AND status IN (?,?)',
      whereArgs: [branchId, 'PENDING', 'FAILED'],
      orderBy: 'queued_at ASC',
      limit: maxEventsPerBatch.clamp(1, 100).toInt(),
    );
    if (rows.isEmpty) return null;
    final batchId = _stableBatchId(rows);
    final payload = jsonEncode({
      'schemaVersion': 1,
      'branchId': branchId,
      'batchId': batchId,
      'events': rows.map((row) => {
        'eventId': row['uuid'],
        'table': row['table_name'],
        'rowUuid': row['row_uuid'],
        'operation': row['operation'],
        'version': row['sync_version'],
        'payload': jsonDecode(row['payload_json'] as String),
        'queuedAt': row['queued_at'],
      }).toList(),
    });
    final compressed = gzip.encode(utf8.encode(payload));
    return CompressedSyncBatch(
      id: batchId,
      branchId: branchId,
      eventIds: rows.map((row) => row['id'] as String).toList(),
      eventCount: rows.length,
      compressedPayload: base64Encode(compressed),
      checksum: sha256.convert(utf8.encode(payload)).toString(),
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Sends one batch and one daily summary if the local safety quota permits both writes.
  Future<SyncResult> syncNextBatch(String branchId) async {
    final db = await _helper.database;
    final batch = await buildCompressedBatch(branchId);
    if (batch == null) return const SyncResult.noPending();
    final dateKey = _dateKey(DateTime.now());
    final quota = await _readOrCreateQuota(db, branchId, dateKey);
    if (quota.writesUsed + 2 > quota.maxDailyWritesLimit ||
        quota.writesUsed + 2 > dailyWriteSafetyLimit) {
      return SyncResult.deferred(
        'تم إيقاف المزامنة مؤقتاً لحماية الحصة اليومية؛ بقيت البيانات محفوظة محلياً.',
      );
    }

    final batchDocument = <String, Object?>{
      'branchId': branchId,
      'batchId': batch.id,
      'schemaVersion': 1,
      'createdAt': batch.createdAt,
      'eventCount': batch.eventCount,
      'compressedPayload': batch.compressedPayload,
      'encoding': 'gzip+base64',
      'checksum': batch.checksum,
    };
    try {
      await _transport.putBatch(
        branchId: branchId, batchId: batch.id, data: batchDocument,
      );
      await db.transaction((txn) async {
        await _incrementQuota(txn, branchId, dateKey, writes: 1);
      });
      final summary = await _buildDailySummary(db, branchId, dateKey, batch.id);
      final summaryId = '${branchId}_${dateKey.replaceAll('-', '')}';
      await _transport.putDailySummary(documentId: summaryId, data: summary);
      await db.transaction((txn) async {
        await _incrementQuota(txn, branchId, dateKey, writes: 1);
      });

      await db.transaction((txn) async {
        final now = DateTime.now().toIso8601String();
        for (final id in batch.eventIds) {
          await txn.update('sync_queue', {
            'status': 'BATCHED_SENT',
            'batch_id': batch.id,
            'updated_at': now,
          }, where: 'id=?', whereArgs: [id]);
        }
      });
      return SyncResult.sent(batchId: batch.id, eventCount: batch.eventCount);
    } catch (error) {
      await db.update('sync_queue', {
        'status': 'FAILED', 'updated_at': DateTime.now().toIso8601String(),
      }, where: 'id IN (${batch.eventIds.map((_) => '?').join(',')})',
        whereArgs: batch.eventIds);
      return SyncResult.failed(error.toString());
    }
  }

  Future<Map<String, Object?>> _buildDailySummary(
    Database db, String branchId, String dateKey, String batchId,
  ) async {
    final start = '${dateKey}T00:00:00';
    final end = '${dateKey}T23:59:59';
    final rows = await db.rawQuery(
      '''SELECT COUNT(*) AS sales_count, COALESCE(SUM(net_total),0) AS sales_total,
         COALESCE(SUM(remaining_alayh),0) AS credit_total
         FROM sales_invoices WHERE branch_id=? AND status='COMPLETED'
         AND invoice_date BETWEEN ? AND ? AND is_deleted=0''',
      [branchId, start, end],
    );
    final paymentRows = await db.rawQuery(
      '''SELECT method, COALESCE(SUM(amount),0) AS amount
         FROM sales_payments sp JOIN sales_invoices si ON si.id=sp.invoice_id
         WHERE si.branch_id=? AND si.invoice_date BETWEEN ? AND ? AND si.status='COMPLETED'
         GROUP BY method''',
      [branchId, start, end],
    );
    double cash = 0, wallet = 0;
    for (final row in paymentRows) {
      if (row['method'] == 'CASH') cash += (row['amount'] as num).toDouble();
      if (row['method'] == 'WALLET') wallet += (row['amount'] as num).toDouble();
    }
    final lowStock = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM products WHERE branch_id=? AND stock_base_qty<=min_stock_alert_qty AND is_active=1 AND is_deleted=0',
      [branchId],
    );
    final summary = rows.first;
    return {
      'branchId': branchId,
      'dateKey': dateKey,
      'salesCount': summary['sales_count'],
      'salesTotal': summary['sales_total'],
      'cashTotal': cash,
      'walletTotal': wallet,
      'creditTotal': summary['credit_total'],
      'stockAlertsCount': lowStock.first['total'],
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'sourceBatchId': batchId,
    };
  }

  Future<QuotaSnapshot> _readOrCreateQuota(
    Database db, String branchId, String dateKey,
  ) async {
    final rows = await db.query('firebase_quota_tracker',
      where: 'date_key=?', whereArgs: [dateKey], limit: 1);
    if (rows.isNotEmpty) {
      final row = rows.first;
      return QuotaSnapshot(
        (row['writes_used'] as num).toInt(),
        (row['max_daily_writes_limit'] as num).toInt(),
      );
    }
    final now = DateTime.now().toIso8601String();
    await db.insert('firebase_quota_tracker', {
      'id': 'quota-$dateKey', 'uuid': 'uuid-quota-$dateKey',
      'branch_id': branchId, 'date_key': dateKey,
      'writes_used': 0, 'reads_used': 0, 'deletes_used': 0,
      'max_daily_writes_limit': dailyWriteSafetyLimit,
      'created_at': now, 'updated_at': now, 'is_deleted': 0,
      'sync_status': 'LOCAL', 'sync_version': 1,
    });
    return QuotaSnapshot(0, dailyWriteSafetyLimit);
  }

  Future<void> _incrementQuota(
    Transaction txn, String branchId, String dateKey, {required int writes},
  ) async {
    final now = DateTime.now().toIso8601String();
    await txn.rawUpdate(
      '''UPDATE firebase_quota_tracker
         SET writes_used=writes_used+?, updated_at=?
         WHERE date_key=? AND branch_id=?''',
      [writes, now, dateKey, branchId],
    );
  }

  String _stableBatchId(List<Map<String, Object?>> rows) {
    final identity = rows.map((row) => row['uuid']).join('|');
    return 'b${sha256.convert(utf8.encode(identity)).toString().substring(0, 24)}';
  }

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// Immutable compressed payload ready for transport.
class CompressedSyncBatch {
  const CompressedSyncBatch({
    required this.id, required this.branchId, required this.eventIds,
    required this.eventCount, required this.compressedPayload,
    required this.checksum, required this.createdAt,
  });
  final String id, branchId, compressedPayload, checksum, createdAt;
  final List<String> eventIds;
  final int eventCount;
}

/// Outcome of a single synchronization attempt.
class SyncResult {
  const SyncResult._(this.status, {this.batchId, this.eventCount = 0, this.message});
  const SyncResult.noPending() : this._('NO_PENDING');
  const SyncResult.sent({required String batchId, required int eventCount})
      : this._('SENT', batchId: batchId, eventCount: eventCount);
  const SyncResult.deferred(String message) : this._('DEFERRED', message: message);
  const SyncResult.failed(String message) : this._('FAILED', message: message);
  final String status;
  final String? batchId;
  final int eventCount;
  final String? message;
}

class QuotaSnapshot {
  const QuotaSnapshot(this.writesUsed, this.maxWrites);
  final int writesUsed;
  final int maxWrites;
}