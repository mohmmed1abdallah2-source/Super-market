import 'package:test/test.dart';

import '../lib/features/control_plane/data/psql_store_schema_migrator.dart';

void main() {
  test('migration bundle accepts only ordered versioned SQL files', () {
    expect(
      PsqlStoreSchemaMigrator.isStoreMigrationFileName(
        '20261124_003_branch_consistent_composite_constraints.sql',
      ),
      isTrue,
    );
    expect(
      PsqlStoreSchemaMigrator.isStoreMigrationFileName(
        '008_inventory_branch_isolation_tests.sql',
      ),
      isFalse,
    );
    expect(
      PsqlStoreSchemaMigrator.isStoreMigrationFileName(
        '005_post_migration_deep_audit_read_only.sql',
      ),
      isFalse,
    );
  });
}
