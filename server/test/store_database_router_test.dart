import 'package:test/test.dart';

import '../lib/features/control_plane/data/store_database_router.dart';

void main() {
  test('accepts only active database locators derived from opaque store UUID', () {
    const storeId = '20000000-0000-4000-8000-000000000001';
    const descriptor = StoreDatabaseDescriptor(
      storeId: storeId,
      databaseName: 'store_20000000000040008000000000000001',
      databaseRole: 'store_20000000000040008000000000000001',
      secretRef: 'vault://stores/20000000-0000-4000-8000-000000000001',
      status: 'ACTIVE',
    );

    expect(
      () => StoreDatabaseRouter.validateDescriptor(storeId, descriptor),
      returnsNormally,
    );
  });

  test('rejects a descriptor that points to another store database', () {
    const storeId = '20000000-0000-4000-8000-000000000001';
    const descriptor = StoreDatabaseDescriptor(
      storeId: storeId,
      databaseName: 'store_20000000000040008000000000000002',
      databaseRole: 'store_20000000000040008000000000000002',
      secretRef: 'vault://stores/store-b',
      status: 'ACTIVE',
    );

    expect(
      () => StoreDatabaseRouter.validateDescriptor(storeId, descriptor),
      throwsA(isA<StateError>()),
    );
  });

  test('does not route suspended or malformed store records', () {
    const storeId = '20000000-0000-4000-8000-000000000001';
    const descriptor = StoreDatabaseDescriptor(
      storeId: storeId,
      databaseName: 'store_20000000000040008000000000000001',
      databaseRole: 'store_20000000000040008000000000000001',
      secretRef: 'vault://store-a',
      status: 'SUSPENDED',
    );

    expect(
      () => StoreDatabaseRouter.validateDescriptor(storeId, descriptor),
      throwsA(isA<StateError>()),
    );
  });
}
