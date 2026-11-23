/// Trusted identity claims returned by a verified identity provider.
final class VerifiedAccountIdentity {
  const VerifiedAccountIdentity({
    required this.provider,
    required this.subject,
    required this.email,
    required this.emailVerified,
    this.displayName,
  });

  final String provider;
  final String subject;
  final String email;
  final bool emailVerified;
  final String? displayName;

  void validate() {
    const supportedProviders = {'oidc', 'google', 'apple', 'email'};
    if (!supportedProviders.contains(provider)) {
      throw ArgumentError.value(provider, 'provider', 'Unsupported identity provider.');
    }
    if (subject.trim().isEmpty || subject.length > 512) {
      throw ArgumentError.value(subject, 'subject', 'A valid provider subject is required.');
    }
    if (!email.contains('@') || email.trim().length > 320) {
      throw ArgumentError.value(email, 'email', 'A valid email address is required.');
    }
    if (!emailVerified) {
      throw ArgumentError('The identity provider must verify the email address.');
    }
  }
}

enum StoreMembershipRole { owner, admin, manager, staff, readOnly }

enum ControlPlaneAccountStatus { active, suspended, closed }

enum ControlPlaneStoreStatus { provisioning, active, suspended, failed, closed }

/// A store directory entry visible to an authenticated account through membership.
final class AccountStoreAccess {
  const AccountStoreAccess({
    required this.storeId,
    required this.displayName,
    required this.role,
    required this.storeStatus,
  });

  final String storeId;
  final String displayName;
  final StoreMembershipRole role;
  final ControlPlaneStoreStatus storeStatus;

  bool get canActivate =>
      storeStatus == ControlPlaneStoreStatus.active;
}

/// Persistence boundary. Implementations must use the dedicated control-plane DB.
abstract interface class ControlPlaneRepository {
  /// Creates or resolves an account only from verified provider claims.
  Future<String> resolveVerifiedAccount(VerifiedAccountIdentity identity);

  /// Returns active memberships only; never returns database credentials.
  Future<List<AccountStoreAccess>> listActiveStores(String accountId);
}
