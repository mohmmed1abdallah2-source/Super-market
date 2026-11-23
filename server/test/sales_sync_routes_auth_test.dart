import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/features/sales_and_sync/application/sales_sync_use_cases.dart';
import '../lib/features/sales_and_sync/domain/sales_sync_domain.dart';
import '../lib/features/sales_and_sync/presentation/sales_sync_routes.dart';

void main() {
  late _RecordingSalesSyncRepository repository;
  late Handler handler;

  setUp(() {
    repository = _RecordingSalesSyncRepository();
    final routes = SalesSyncRoutes(
      postSale: PostSaleInvoiceUseCase(repository),
      listSalesInvoices: ListSalesInvoicesUseCase(repository),
      processBatch: ProcessSyncBatchUseCase(repository),
      branchTokens: const {
        'branch-a': 'token-a',
        'branch-b': 'token-b',
      },
    );
    handler = routes.router;
  });

  test('rejects a request without branch credentials', () async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/v1/sales/invoices')),
    );

    expect(response.statusCode, 401);
    expect(repository.lastReadBranch, isNull);
  });

  test('rejects a token belonging to a different branch', () async {
    final response = await handler(
      Request(
        'GET',
        Uri.parse('http://localhost/v1/sales/invoices'),
        headers: const {
          'x-branch-id': 'branch-a',
          'authorization': 'Bearer token-b',
        },
      ),
    );

    expect(response.statusCode, 401);
    expect(repository.lastReadBranch, isNull);
  });

  test('valid branch token scopes invoice reads to its configured branch', () async {
    final response = await handler(
      Request(
        'GET',
        Uri.parse('http://localhost/v1/sales/invoices'),
        headers: const {
          'x-branch-id': 'branch-a',
          'authorization': 'Bearer token-a',
        },
      ),
    );

    expect(response.statusCode, 200);
    expect(repository.lastReadBranch, 'branch-a');
  });

  test('valid branch token scopes Sync Batch to its configured branch', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/v1/sync/batch'),
        headers: const {
          'x-branch-id': 'branch-b',
          'authorization': 'Bearer token-b',
          'idempotency-key': 'route-auth-test-key-0001',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'batchId': 'batch-auth-test',
          'operations': [
            {
              'operationId': 'operation-auth-test',
              'operationType': 'PARTY_CREATE',
              'payload': {
                'id': 'party-auth-test',
                'partyType': 'CUSTOMER',
                'code': 'AUTH-TEST',
                'name': 'Auth test',
              },
            },
          ],
        }),
      ),
    );

    expect(response.statusCode, 200);
    expect(repository.lastBatchBranch, 'branch-b');
    expect(repository.lastBatchOperationIds, ['operation-auth-test']);
  });
}

final class _RecordingSalesSyncRepository implements SalesSyncRepository {
  String? lastReadBranch;
  String? lastBatchBranch;
  List<String> lastBatchOperationIds = const [];

  @override
  Future<Map<String, Object?>> postSale(SaleInvoiceCommand command) async =>
      {'id': 'sale-test'};

  @override
  Future<List<Map<String, Object?>>> listSalesInvoices({
    required String branchId,
    DateTime? from,
    DateTime? to,
    String? cursor,
    int limit = 50,
  }) async {
    lastReadBranch = branchId;
    return const [];
  }

  @override
  Future<Map<String, Object?>> processBatch(SyncBatchCommand command) async {
    lastBatchBranch = command.branchId;
    lastBatchOperationIds =
        command.operations.map((operation) => operation.operationId).toList();
    return {
      'batchId': command.batchId,
      'acceptedIds': lastBatchOperationIds,
      'rejected': const <Object>[],
      'replayed': false,
    };
  }
}
