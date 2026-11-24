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
    if (!supportedProviders.contains(provider)) throw ArgumentError.value(provider, 'provider', 'Unsupported identity provider.');
    if (subject.trim().isEmpty || subject.length > 512) throw ArgumentError.value(subject, 'subject', 'A valid provider subject is required.');
    if (!email.contains('@') || email.trim().length > 320) throw ArgumentError.value(email, 'email', 'A valid email address is required.');
    if (!emailVerified) throw ArgumentError('The identity provider must verify the email address.');
  }
}

enum StoreMembershipRole { owner, admin, manager, staff, readOnly }
enum StoreMembershipStatus { invited, active, suspended, revoked }
enum ControlPlaneAccountStatus { active, suspended, closed }
enum ControlPlaneStoreStatus { provisioning, active, suspended, failed, closed }
enum StorePermission {
  viewStore, manageStore, viewMembers, inviteMembers, changeMemberRoles,
  suspendMembers, viewOperations, createOperations, approveOperations, manageSettings,
}

extension StoreRolePermissions on StoreMembershipRole {
  Set<StorePermission> get permissions => switch (this) {
    StoreMembershipRole.owner => StorePermission.values.toSet(),
    StoreMembershipRole.admin => {
      StorePermission.viewStore, StorePermission.viewMembers,
      StorePermission.inviteMembers, StorePermission.changeMemberRoles,
      StorePermission.suspendMembers, StorePermission.viewOperations,
      StorePermission.createOperations, StorePermission.approveOperations,
      StorePermission.manageSettings,
    },
    StoreMembershipRole.manager => {
      StorePermission.viewStore, StorePermission.viewMembers,
      StorePermission.inviteMembers, StorePermission.viewOperations,
      StorePermission.createOperations, StorePermission.approveOperations,
    },
    StoreMembershipRole.staff => {
      StorePermission.viewStore, StorePermission.viewOperations,
      StorePermission.createOperations,
    },
    StoreMembershipRole.readOnly => {
      StorePermission.viewStore, StorePermission.viewOperations,
    },
  };
  bool allows(StorePermission permission) => permissions.contains(permission);
}

final class AccountStoreAccess {
  const AccountStoreAccess({required this.storeId, required this.displayName, required this.role, required this.storeStatus});
  final String storeId;
  final String displayName;
  final StoreMembershipRole role;
  final ControlPlaneStoreStatus storeStatus;
  bool get canActivate => storeStatus == ControlPlaneStoreStatus.active;
}

final class StoreMember {
  const StoreMember({required this.accountId, required this.storeId, required this.role, required this.status});
  final String accountId;
  final String storeId;
  final StoreMembershipRole role;
  final StoreMembershipStatus status;
}

abstract interface class ControlPlaneRepository {
  Future<String> resolveVerifiedAccount(VerifiedAccountIdentity identity);
  Future<List<AccountStoreAccess>> listActiveStores(String accountId);
  Future<String> createStore({required String storeId, required String membershipId, required String ownerAccountId, required String displayName});
  Future<void> addMember({required String membershipId, required String actorAccountId, required String targetAccountId, required String storeId, required StoreMembershipRole role});
  Future<void> acceptInvitation({required String accountId, required String storeId});
  Future<void> changeStoreStatus({required String actorAccountId, required String storeId, required ControlPlaneStoreStatus status});
  Future<void> changeMemberRole({required String actorAccountId, required String targetAccountId, required String storeId, required StoreMembershipRole role});
  Future<void> changeMemberStatus({required String actorAccountId, required String targetAccountId, required String storeId, required StoreMembershipStatus status});
  Future<List<StoreMember>> listMembers({required String actorAccountId, required String storeId});
  Future<bool> hasPermission({required String accountId, required String storeId, required StorePermission permission});
}
