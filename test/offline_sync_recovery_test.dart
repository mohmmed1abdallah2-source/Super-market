import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supermarket_erp/data/database/database_helper.dart';
import 'package:supermarket_erp/data/database/schema_builder.dart';
import 'package:supermarket_erp/data/services/scale_pos_and_ledger_service.dart';
import 'package:api_client/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> openDatabaseAt(String path, {bool create = false}) async {
    final db = await databaseFactoryFfi.openDatabase(path);
    if (create) {
      await db.execute('PRAGMA foreign_keys = ON');
      await SchemaBuilder.createAll(db);
    }
    return db;
  }

  Map<String, dynamic> transferPayload(int index) => {
        'transferId': 'transfer-$index',
        'transferNo': 'TRF-$index',
        'sourceWarehouseId': 'warehouse-source',
        'destinationWarehouseId': 'warehouse-destination',
        'items': [
          {'productBatchId': 'batch-$index', 'qtyBase': '1.000000'},
        ],
      };

  http.Response acceptedResponse(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final operations = body['operations'] as List<dynamic>;
    final ids = operations
        .map((operation) => (operation as Map<String, dynamic>)['operationId'])
        .cast<String>()
        .toList(growable: false);
    return http.Response(
      jsonEncode({
        'batchId': body['batchId'],
        'acceptedIds': ids,
        'rejected': <Object>[],
        'serverTime': DateTime.now().toUtc().toIso8601String(),
        'replayed': true,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }

  ApiClient clientFor(http.Client client) => ApiClient(
        baseUri: Uri.parse('https://erp.example.test'),
        httpClient: client,
        accessTokenProvider: () async => 'test-token',
        branchIdProvider: () async => 'branch-a',
      );

  test('offline operation survives process restart and retries with identical identities', () async {
    final directory = await Directory.systemTemp.createTemp('erp-sync-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/recovery.db';

    final firstDb = await openDatabaseAt(path, create: true);
    final firstHelper = DatabaseHelper.forDatabase(firstDb);
    final firstEngine = LocalPosAndLedgerEngine(databaseHelper: firstHelper);
    final operationId = await firstEngine.enqueueSyncOperation(
      branchId: 'branch-a',
      operationType: 'STOCK_TRANSFER',
      payload: transferPayload(1),
    );

    Map<String, dynamic>? firstBody;
    String? firstIdempotencyKey;
    final disconnectedClient = MockClient((request) async {
      firstBody = jsonDecode(request.body) as Map<String, dynamic>;
      firstIdempotencyKey = request.headers.entries
          .firstWhere((entry) => entry.key.toLowerCase() == 'idempotency-key')
          .value;
      // The server may have committed, but the response was lost in transit.
      throw const SocketException('connection dropped after server commit');
    });
    final disconnectedApi = clientFor(disconnectedClient);
    firstEngine.configureApiClient(disconnectedApi);
    await expectLater(
      firstEngine.syncPendingBatch('branch-a'),
      throwsA(isA<SocketException>()),
    );

    final beforeRestart = await firstDb.query('sync_queue');
    expect(beforeRestart, hasLength(1));
    expect(beforeRestart.single['status'], 'PENDING');
    await firstHelper.close();
    disconnectedApi.close();

    // A new database handle models a new application process.
    final restoredDb = await openDatabaseAt(path);
    final restoredHelper = DatabaseHelper.forDatabase(restoredDb);
    final restoredEngine = LocalPosAndLedgerEngine(databaseHelper: restoredHelper);
    Map<String, dynamic>? retryBody;
    String? retryIdempotencyKey;
    final connectedApi = clientFor(MockClient((request) async {
      retryBody = jsonDecode(request.body) as Map<String, dynamic>;
      retryIdempotencyKey = request.headers.entries
          .firstWhere((entry) => entry.key.toLowerCase() == 'idempotency-key')
          .value;
      return acceptedResponse(request);
    }));
    restoredEngine.configureApiClient(connectedApi);

    final accepted = await restoredEngine.resumePendingSync('branch-a');
    expect(accepted, 1);
    expect((firstBody!['operations'] as List).single['operationId'], operationId);
    expect((retryBody!['operations'] as List).single['operationId'], operationId);
    expect(retryBody!['batchId'], firstBody!['batchId']);
    expect(retryIdempotencyKey, firstIdempotencyKey);

    final afterRestart = await restoredDb.query('sync_queue');
    expect(afterRestart, hasLength(1));
    expect(afterRestart.single['status'], 'BATCHED_SENT');
    expect(afterRestart.single['uuid'], beforeRestart.single['uuid']);

    connectedApi.close();
    await restoredHelper.close();
  });

  test('invalid or partial acknowledgement leaves every operation retryable', () async {
    final directory = await Directory.systemTemp.createTemp('erp-sync-ack-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await openDatabaseAt('${directory.path}/ack.db', create: true);
    final helper = DatabaseHelper.forDatabase(db);
    final engine = LocalPosAndLedgerEngine(databaseHelper: helper);
    await engine.enqueueSyncOperation(
      branchId: 'branch-a',
      operationType: 'STOCK_TRANSFER',
      payload: transferPayload(2),
    );

    final api = clientFor(MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'batchId': body['batchId'],
          'acceptedIds': <String>[],
          'rejected': <Object>[],
          'serverTime': DateTime.now().toUtc().toIso8601String(),
          'replayed': false,
        }),
        200,
      );
    }));
    engine.configureApiClient(api);
    await expectLater(
      engine.syncPendingBatch('branch-a'),
      throwsA(isA<StateError>()),
    );
    final rows = await db.query('sync_queue');
    expect(rows.single['status'], 'PENDING');

    api.close();
    await helper.close();
  });

  test('recovery drains more than one server batch without changing operation IDs', () async {
    final directory = await Directory.systemTemp.createTemp('erp-sync-drain-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await openDatabaseAt('${directory.path}/drain.db', create: true);
    final helper = DatabaseHelper.forDatabase(db);
    final engine = LocalPosAndLedgerEngine(databaseHelper: helper);
    for (var index = 0; index < 101; index++) {
      await engine.enqueueSyncOperation(
        branchId: 'branch-a',
        operationType: 'STOCK_TRANSFER',
        payload: transferPayload(index),
      );
    }

    var requests = 0;
    final api = clientFor(MockClient((request) async {
      requests++;
      return acceptedResponse(request);
    }));
    engine.configureApiClient(api);
    final accepted = await engine.resumePendingSync('branch-a', batchSize: 100);
    expect(accepted, 101);
    expect(requests, 2);
    final pending = await db.query(
      'sync_queue',
      where: 'branch_id=? AND status IN (?, ?)',
      whereArgs: ['branch-a', 'PENDING', 'FAILED'],
    );
    expect(pending, isEmpty);

    api.close();
    await helper.close();
  });
}
