import 'package:uuid/uuid.dart';

import '../domain/control_plane_domain.dart';

/// Business rules for store creation, membership administration and authorization.
final class ControlPlaneStoreService {
  ControlPlaneStoreService(this._repository);

  final ControlPlaneRepository _repository;
  static const _uuid = Uuid();

  Future<String> createStore({
    required String ownerAccountId,
    required String displayName,
  }) {
    final name = displayName.trim();
    if (ownerAccountId.trim().isEmpty) {
      throw const FormatException('An authenticated owner account is required.');
    }
    if (name.isEmpty || name.length > 160) {
      throw const FormatException('Store name must contain 1 to 160 characters.');
    }
    return _repository.createStore(
      storeId: _uuid.v4(),
      membershipId: _uuid.v4(),
      ownerAccountId: ownerAccountId,
      displayName: name,
    );
  }

  Future<void> inviteMember({
    required String actorAccountId,
    required String targetAccountId,
    required String storeId,
    required StoreMembershipRole role,
  }) {
    _requiredIds(actorAccountId, targetAccountId, storeId);
    if (role == StoreMembershipRole.owner) {
      throw const FormatException('Ownership transfer must use a dedicated owner-transfer flow.');
    }
    return _repository.addMember(
      membershipId: _uuid.v4(),
      actorAccountId: actorAccountId,
      targetAccountId: targetAccountId,
      storeId: storeId,
      role: role,
    );
  }

  Future<void> acceptInvitation({
    required String accountId,
    required String storeId,
  }) {
    _requiredIds(accountId, storeId);
    return _repository.acceptInvitation(accountId: accountId, storeId: storeId);
  }

  Future<void> changeRole({
    required String actorAccountId,
    required String targetAccountId,
    required String storeId,
    required StoreMembershipRole role,
  }) {
    _requiredIds(actorAccountId, targetAccountId, storeId);
    if (role == StoreMembershipRole.owner) {
      throw const FormatException('Ownership transfer must use a dedicated owner-transfer flow.');
    }
    return _repository.changeMemberRole(
      actorAccountId: actorAccountId,
      targetAccountId: targetAccountId,
      storeId: storeId,
      role: role,
    );
  }

  Future<void> changeStatus({
    required String actorAccountId,
    required String targetAccountId,
    required String storeId,
    required StoreMembershipStatus status,
  }) {
    _requiredIds(actorAccountId, targetAccountId, storeId);
    if (status == StoreMembershipStatus.active ||
        status == StoreMembershipStatus.invited) {
      throw const FormatException('Membership activation is handled by invitation acceptance.');
    }
    if (actorAccountId == targetAccountId) {
      throw const FormatException('An account cannot suspend or revoke its own membership.');
    }
    return _repository.changeMemberStatus(
      actorAccountId: actorAccountId,
      targetAccountId: targetAccountId,
      storeId: storeId,
      status: status,
    );
  }

  Future<List<StoreMember>> listMembers({
    required String actorAccountId,
    required String storeId,
  }) {
    _requiredIds(actorAccountId, storeId);
    return _repository.listMembers(
      actorAccountId: actorAccountId,
      storeId: storeId,
    );
  }

  Future<bool> authorize({
    required String accountId,
    required String storeId,
    required StorePermission permission,
  }) {
    _requiredIds(accountId, storeId);
    return _repository.hasPermission(
      accountId: accountId,
      storeId: storeId,
      permission: permission,
    );
  }

  void _requiredIds(String actor, String target, [String? store]) {
    if (actor.trim().isEmpty || target.trim().isEmpty ||
        (store != null && store.trim().isEmpty)) {
      throw const FormatException('Account and store identifiers are required.');
    }
  }
}
