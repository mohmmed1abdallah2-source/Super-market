import 'control_plane_domain.dart';

final class ControlPlaneSession {
  const ControlPlaneSession({required this.sessionId, required this.accountId, required this.expiresAt, this.activeStore});
  final String sessionId;
  final String accountId;
  final DateTime expiresAt;
  final AccountStoreAccess? activeStore;
}

abstract interface class ControlPlaneSessionRepository {
  Future<void> createSession({required String sessionId, required String accountId, required String accessTokenHash, required DateTime expiresAt});
  Future<ControlPlaneSession?> findSession(String accessTokenHash);
  Future<AccountStoreAccess> activateStore({required String accessTokenHash, required String storeId});
  Future<void> revokeSession(String accessTokenHash);
  Future<bool> isBranchAssignedToStore({required String storeId, required String branchId});
}

abstract interface class StoreDatabaseBindingRepository {
  Future<String?> readyDatabaseKeyForStore(String storeId);
}

abstract interface class AccountIdentityTokenVerifier {
  Future<VerifiedAccountIdentity> verify({required String provider, required String idToken});
}
