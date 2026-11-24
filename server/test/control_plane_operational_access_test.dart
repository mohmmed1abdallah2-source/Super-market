import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/features/control_plane/domain/control_plane_domain.dart';
import '../lib/features/control_plane/domain/control_plane_sessions.dart';
import '../lib/features/control_plane/presentation/control_plane_operational_access.dart';

void main() {
  late _FakeSessions sessions;
  late Handler handler;

  setUp(() {
    sessions = _FakeSessions();
    handler = Pipeline()
        .addMiddleware(ControlPlaneOperationalAccess(sessions).middleware)
        .addHandler((request) => Response.ok('accepted'));
  });

  test('rejects requests without an account session', () async {
    final response = await handler(_request());
    expect(response.statusCode, 401);
  });

  test('rejects a forged store ID even with a valid session for another store', () async {
    final response = await handler(_request(
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-store-id': 'store-b',
        'x-branch-id': 'branch-b',
      },
    ));
    expect(response.statusCode, 403);
    expect(sessions.checkedBranches, isEmpty);
  });


  test('account B cannot use account A store branch', () async {
    final response = await handler(_request(
      headers: {
        'authorization': 'Bearer account-b-token',
        'x-branch-id': 'branch-a',
      },
    ));
    expect(response.statusCode, 403);
    expect(sessions.checkedBranches.last, 'store-b:branch-a');
  });

  test('rejects a branch registered to a different store when store header is omitted', () async {
    final response = await handler(_request(
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-branch-id': 'branch-b',
      },
    ));
    expect(response.statusCode, 403);
    expect(sessions.checkedBranches, ['store-a:branch-b']);
  });

  test('allows a branch registered to the active store', () async {
    final response = await handler(_request(
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-branch-id': 'branch-a',
      },
    ));
    expect(response.statusCode, 200);
  });

  test('enforces role permissions for write operations', () async {
    final response = await handler(_request(
      method: 'POST',
      path: '/v1/sales/invoices',
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-branch-id': 'branch-a',
      },
    ));
    expect(response.statusCode, 200); // STAFF may create operational records.

    final approval = await handler(_request(
      method: 'POST',
      path: '/v1/inventory/stocktaking/session-1/approve',
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-branch-id': 'branch-a',
      },
    ));
    expect(approval.statusCode, 403); // STAFF cannot approve.
  });

  test('allows STAFF to sync ordinary create operations', () async {
    final response = await handler(_request(
      method: 'POST',
      path: '/v1/sync/batch',
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-branch-id': 'branch-a',
      },
      body: jsonEncode({
        'operations': [
          {'operationType': 'SALE_INVOICE'},
          {'operationType': 'PURCHASE_INVOICE'},
        ],
      }),
    ));
    expect(response.statusCode, 200);
  });

  test('denies STAFF a sync batch containing an approval operation', () async {
    final response = await handler(_request(
      method: 'POST',
      path: '/v1/sync/batch',
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-branch-id': 'branch-a',
      },
      body: jsonEncode({
        'operations': [
          {'operationType': 'SALE_INVOICE'},
          {'operationType': 'STOCKTAKE_APPROVE'},
        ],
      }),
    ));
    expect(response.statusCode, 403);
  });

  test('rejects sessions whose membership is no longer active', () async {
    sessions.valid = false;
    final response = await handler(_request(
      headers: {
        'authorization': 'Bearer account-a-token',
        'x-branch-id': 'branch-a',
      },
    ));
    expect(response.statusCode, 401);
  });
}

Request _request({
  String method = 'GET',
  String path = '/v1/sales/invoices',
  Map<String, String> headers = const {},
  Object? body,
}) =>
    Request(method, Uri.parse('http://localhost$path'), headers: headers, body: body);

final class _FakeSessions implements ControlPlaneSessionRepository {
  bool valid = true;
  final List<String> checkedBranches = [];

  @override
  Future<ControlPlaneSession?> findSession(String accessTokenHash) async {
    final tokenA = sha256.convert(utf8.encode('account-a-token')).toString();
    final tokenB = sha256.convert(utf8.encode('account-b-token')).toString();
    if (!valid) return null;
    final isAccountA = accessTokenHash == tokenA;
    if (!isAccountA && accessTokenHash != tokenB) return null;
    final accountId = isAccountA ? 'account-a' : 'account-b';
    final storeId = isAccountA ? 'store-a' : 'store-b';
    return ControlPlaneSession(
      sessionId: 'session-$accountId',
      accountId: accountId,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      activeStore: AccountStoreAccess(
        storeId: storeId,
        displayName: isAccountA ? 'Store A' : 'Store B',
        role: StoreMembershipRole.staff,
        storeStatus: ControlPlaneStoreStatus.active,
      ),
    );
  }

  @override
  Future<String?> readyDatabaseKeyForStore(String storeId) async =>
      storeId == 'store-a' || storeId == 'store-b' ? 'db-$storeId' : null;

  @override
  Future<bool> isBranchAssignedToStore({
    required String storeId,
    required String branchId,
  }) async {
    checkedBranches.add('$storeId:$branchId');
    return (storeId == 'store-a' && branchId == 'branch-a') ||
        (storeId == 'store-b' && branchId == 'branch-b');
  }

  @override
  Future<void> createSession({
    required String sessionId,
    required String accountId,
    required String accessTokenHash,
    required DateTime expiresAt,
  }) async {}

  @override
  Future<AccountStoreAccess> activateStore({
    required String accessTokenHash,
    required String storeId,
  }) async => throw UnimplementedError();

  @override
  Future<void> revokeSession(String accessTokenHash) async {}
}
