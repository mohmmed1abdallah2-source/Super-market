import 'package:test/test.dart';

import '../lib/features/control_plane/domain/control_plane_domain.dart';

void main() {
  group('VerifiedAccountIdentity', () {
    test('accepts a supported verified identity', () {
      const identity = VerifiedAccountIdentity(
        provider: 'google',
        subject: 'provider-subject-123',
        email: 'owner@example.com',
        emailVerified: true,
      );
      expect(identity.validate, returnsNormally);
    });

    test('rejects unverified email claims', () {
      const identity = VerifiedAccountIdentity(
        provider: 'oidc',
        subject: 'subject',
        email: 'owner@example.com',
        emailVerified: false,
      );
      expect(identity.validate, throwsArgumentError);
    });

    test('rejects unsupported providers', () {
      const identity = VerifiedAccountIdentity(
        provider: 'password-plaintext',
        subject: 'subject',
        email: 'owner@example.com',
        emailVerified: true,
      );
      expect(identity.validate, throwsArgumentError);
    });

    test('rejects empty provider subjects', () {
      const identity = VerifiedAccountIdentity(
        provider: 'email',
        subject: ' ',
        email: 'owner@example.com',
        emailVerified: true,
      );
      expect(identity.validate, throwsArgumentError);
    });
  });

  test('store can only be activated when provisioned and active', () {
    const active = AccountStoreAccess(
      storeId: 'opaque-store-id',
      displayName: 'Main store',
      role: StoreMembershipRole.owner,
      storeStatus: ControlPlaneStoreStatus.active,
    );
    const provisioning = AccountStoreAccess(
      storeId: 'another-opaque-id',
      displayName: 'New store',
      role: StoreMembershipRole.owner,
      storeStatus: ControlPlaneStoreStatus.provisioning,
    );
    expect(active.canActivate, isTrue);
    expect(provisioning.canActivate, isFalse);
  });
}
