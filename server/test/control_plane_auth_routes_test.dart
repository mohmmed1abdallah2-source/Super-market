import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/features/control_plane/domain/control_plane_domain.dart';
import '../lib/features/control_plane/domain/control_plane_sessions.dart';
import '../lib/features/control_plane/presentation/control_plane_auth_routes.dart';

void main() {
  late _FakeIdentityVerifier verifier;
  late _FakeStoreRepository stores;
  late _FakeSessionRepository sessions;
  late ControlPlaneAuthRoutes routes;

  setUp(() {
    verifier = _FakeIdentityVerifier();
    stores = _FakeStoreRepository();
    sessions = _FakeSessionRepository();
    routes = ControlPlaneAuthRoutes(
      identityVerifier: verifier,
      storeRepository: stores,
      sessionRepository: sessions,
    );
  });

  test('login verifies provider identity and persists only a token hash', () async {
    final response = await routes.router(_request(
      'POST',
      '/v1/auth/login',
      body: {'provider': 'google', 'idToken': 'signed-google-id-token'},
    ));
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final token = body['accessToken'] as String;
    expect(token.length, greaterThan(30));
    expect(body['tokenType'], 'Bearer');
    expect(body['accountId'], 'account-1');
    expect(verifier.calls, 1);
    expect(sessions.createdTokenHash, isNot(token));
    expect(sessions.createdTokenHash, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('store listing requires a valid bearer session', () async {
    final denied = await routes.router(_request('GET', '/v1/stores'));
    expect(denied.statusCode, 401);

    final allowed = await routes.router(_request(
      'GET',
      '/v1/stores',
      headers: {'authorization': 'Bearer test-session-token'},
    ));
    expect(allowed.statusCode, 200);
    final body = jsonDecode(await allowed.readAsString()) as Map<String, dynamic>;
    expect((body['items'] as List).length, 1);
  });

  test('store activation delegates lifecycle transition and selects the store', () async {
    final response = await routes.router(_request(
      'POST',
      '/v1/stores/store-1/activate',
      headers: {'authorization': 'Bearer test-session-token'},
    ));
    expect(response.statusCode, 200);
    expect(stores.lastStatus, ControlPlaneStoreStatus.active);
    expect(sessions.activatedStoreId, 'store-1');
  });

  test('session can select an already active store', () async {
    final response = await routes.router(_request(
      'POST',
      '/v1/session/active-store',
      headers: {'authorization': 'Bearer test-session-token'},
      body: {'storeId': 'store-1'},
    ));
    expect(response.statusCode, 200);
    expect(sessions.activatedStoreId, 'store-1');
    expect(stores.lastStatus, isNull);
  });
}

Request _request(
  String method,
  String path, {
  Map<String, String> headers = const {},
  Map<String, Object?>? body,
}) =>
    Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: headers,
      body: body == null ? null : jsonEncode(body),
    );

final class _FakeIdentityVerifier implements AccountIdentityTokenVerifier {
  int calls = 0;

  @override
  Future<VerifiedAccountIdentity> verify({
    required String provider,
    required String idToken,
  }) async {
    calls++;
    expect(provider, 'google');
    expect(idToken, 'signed-google-id-token');
    return const VerifiedAccountIdentity(
      provider: 'google',
      subject: 'google-subject-1',
      email: 'user@example.com',
      emailVerified: true,
    );
  }
}

final class _FakeStoreRepository implements ControlPlaneRepository {
  ControlPlaneStoreStatus? lastStatus;

  @override
  Future<String> resolveVerifiedAccount(VerifiedAccountIdentity identity) async => 'account-1';

  @override
  Future<List<AccountStoreAccess>> listActiveStores(String accountId) async => const [
        AccountStoreAccess(
          storeId: 'store-1',
          displayName: 'Main Store',
          role: StoreMembershipRole.owner,
          storeStatus: ControlPlaneStoreStatus.active,
        ),
      ];

  @override
  Future<void> changeStoreStatus({
    required String actorAccountId,
    required String storeId,
    required ControlPlaneStoreStatus status,
  }) async {
    expect(actorAccountId, 'account-1');
    expect(storeId, 'store-1');
    lastStatus = status;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeSessionRepository implements ControlPlaneSessionRepository {
  String? createdTokenHash;
  String? activatedStoreId;

  @override
  Future<void> createSession({
    required String sessionId,
    required String accountId,
    required String accessTokenHash,
    required DateTime expiresAt,
  }) async {
    expect(accountId, 'account-1');
    createdTokenHash = accessTokenHash;
  }

  @override
  Future<ControlPlaneSession?> findSession(String accessTokenHash) async =>
      ControlPlaneSession(
        sessionId: 'session-1',
        accountId: 'account-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

  @override
  Future<AccountStoreAccess> activateStore({
    required String accessTokenHash,
    required String storeId,
  }) async {
    activatedStoreId = storeId;
    return const AccountStoreAccess(
      storeId: 'store-1',
      displayName: 'Main Store',
      role: StoreMembershipRole.owner,
      storeStatus: ControlPlaneStoreStatus.active,
    );
  }

  @override
  Future<void> revokeSession(String accessTokenHash) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
