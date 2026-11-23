import 'package:test/test.dart';

import '../lib/features/control_plane/data/postgres_store_database_admin.dart';

void main() {
  test('accepts database and role names derived from the opaque store UUID', () {
    expect(
      () => PostgresStoreDatabaseAdmin.validateProvisioningIdentifiers(
        storeId: '20000000-0000-4000-8000-000000000001',
        databaseName: 'store_20000000000040008000000000000001',
        databaseRole: 'store_20000000000040008000000000000001',
        password: 'a' * 43,
      ),
      returnsNormally,
    );
  });

  test('rejects user-controlled database identifiers and weak credentials', () {
    expect(
      () => PostgresStoreDatabaseAdmin.validateProvisioningIdentifiers(
        storeId: '20000000-0000-4000-8000-000000000001',
        databaseName: 'store_customer_supplied',
        databaseRole: 'postgres',
        password: 'short',
      ),
      throwsFormatException,
    );
  });
}
