import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import '../lib/features/control_plane/data/postgres_control_plane_repository.dart';
import '../lib/features/control_plane/data/store_database_connection_resolver.dart';

void main() {
  final env = Platform.environment;
  final enabled = [
    'PGTEST_HOST', 'PGTEST_PORT', 'PGTEST_DATABASE', 'PGTEST_USER',
    'PGTEST_PASSWORD', 'ERP_STORE_DATABASES_JSON',
  ].every((key) => (env[key] ?? '').isNotEmpty);

  test('same local branch ID resolves to separate tenant databases', () async {
    final control = PostgreSQLConnection(
      env['PGTEST_HOST']!, int.parse(env['PGTEST_PORT']!), env['PGTEST_DATABASE']!,
      username: env['PGTEST_USER']!, password: env['PGTEST_PASSWORD']!,
      timeoutInSeconds: 30, useSSL: false,
    );
    await control.open();
    final accountId = const Uuid().v4();
    final storeA = const Uuid().v4();
    final storeB = const Uuid().v4();
    final email = 'tenant-routing-${const Uuid().v4()}@example.test';
    PostgreSQLConnection? tenantA;
    PostgreSQLConnection? tenantB;
    try {
      await control.execute(
        "INSERT INTO cp_accounts(id, primary_email, display_name) VALUES (@id, @email, 'Tenant routing test')",
        substitutionValues: {'id': accountId, 'email': email},
      );
      for (final store in [storeA, storeB]) {
        await control.execute(
          "INSERT INTO cp_stores(id, display_name, status, created_by_account_id) VALUES (@id, @name, 'ACTIVE', @account)",
          substitutionValues: {'id': store, 'name': 'Test store $store', 'account': accountId},
        );
      }
      await control.execute(
        "INSERT INTO cp_store_database_bindings(store_id, database_key, status) VALUES (@storeA, 'tenant-a-test-key', 'READY'), (@storeB, 'tenant-b-test-key', 'READY')",
        substitutionValues: {'storeA': storeA, 'storeB': storeB},
      );
      final resolver = StoreDatabaseConnectionResolver(
        bindings: PostgresControlPlaneRepository(control),
        credentialsProvider: EnvironmentStoreDatabaseCredentialsProvider(env['ERP_STORE_DATABASES_JSON']),
      );
      tenantA = await resolver.openForStore(storeA);
      tenantB = await resolver.openForStore(storeB);
      final resultA = await tenantA.mappedResultsQuery(
        'SELECT marker FROM tenant_scope_test WHERE branch_id = @branch',
        substitutionValues: {'branch': 'shared-branch-id'},
      );
      final resultB = await tenantB.mappedResultsQuery(
        'SELECT marker FROM tenant_scope_test WHERE branch_id = @branch',
        substitutionValues: {'branch': 'shared-branch-id'},
      );
      expect(resultA.single.values.single['marker'], 'tenant-a-only');
      expect(resultB.single.values.single['marker'], 'tenant-b-only');
    } finally {
      await tenantA?.close();
      await tenantB?.close();
      await control.execute(
        'DELETE FROM cp_store_database_bindings WHERE store_id IN (@a, @b)',
        substitutionValues: {'a': storeA, 'b': storeB},
      );
      await control.execute(
        'DELETE FROM cp_stores WHERE id IN (@a, @b)',
        substitutionValues: {'a': storeA, 'b': storeB},
      );
      await control.execute('DELETE FROM cp_accounts WHERE id = @id',
        substitutionValues: {'id': accountId});
      await control.close();
    }
  }, skip: enabled ? false : 'PostgreSQL tenant-routing integration environment is not configured.');
}
