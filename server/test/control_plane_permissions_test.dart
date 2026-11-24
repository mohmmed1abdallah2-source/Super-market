import 'package:test/test.dart';

import '../lib/features/control_plane/domain/control_plane_domain.dart';

void main() {
  group('role permission matrix', () {
    test('owner has all store permissions', () {
      expect(StoreMembershipRole.owner.permissions, containsAll(StorePermission.values));
    });

    test('admin can administer members but cannot manage store ownership', () {
      expect(StoreMembershipRole.admin.allows(StorePermission.inviteMembers), isTrue);
      expect(StoreMembershipRole.admin.allows(StorePermission.changeMemberRoles), isTrue);
      expect(StoreMembershipRole.admin.allows(StorePermission.manageStore), isFalse);
    });

    test('manager can invite but cannot change roles or suspend members', () {
      expect(StoreMembershipRole.manager.allows(StorePermission.inviteMembers), isTrue);
      expect(StoreMembershipRole.manager.allows(StorePermission.changeMemberRoles), isFalse);
      expect(StoreMembershipRole.manager.allows(StorePermission.suspendMembers), isFalse);
    });

    test('staff can create operations but cannot approve or administer members', () {
      expect(StoreMembershipRole.staff.allows(StorePermission.createOperations), isTrue);
      expect(StoreMembershipRole.staff.allows(StorePermission.approveOperations), isFalse);
      expect(StoreMembershipRole.staff.allows(StorePermission.inviteMembers), isFalse);
    });

    test('read-only role cannot mutate store operations', () {
      expect(StoreMembershipRole.readOnly.allows(StorePermission.viewOperations), isTrue);
      expect(StoreMembershipRole.readOnly.allows(StorePermission.createOperations), isFalse);
      expect(StoreMembershipRole.readOnly.allows(StorePermission.manageSettings), isFalse);
    });
  });

  test('store activation is limited to active stores', () {
    const active = AccountStoreAccess(
      storeId: 'store-a',
      displayName: 'Main',
      role: StoreMembershipRole.owner,
      storeStatus: ControlPlaneStoreStatus.active,
    );
    const provisioning = AccountStoreAccess(
      storeId: 'store-b',
      displayName: 'Pending',
      role: StoreMembershipRole.owner,
      storeStatus: ControlPlaneStoreStatus.provisioning,
    );
    expect(active.canActivate, isTrue);
    expect(provisioning.canActivate, isFalse);
  });
}
