import 'package:test/test.dart';

import '../lib/features/control_plane/application/store_provisioner.dart';
import '../lib/features/control_plane/data/store_database_router.dart';
import '../lib/features/control_plane/data/postgres_store_database_admin.dart';

void main() {
  test('provisioning creates secret, database, migrations then activates store', () async {
    final repository = _FakeProvisioningRepository();
    final secrets = _FakeSecretWriter();
    final admin = _FakeDatabaseAdmin();
    final migrator = _FakeMigrator();
    final provisioner = StoreProvisioner(
      repository: repository,
      secretWriter: secrets,
      databaseAdmin: admin,
      schemaMigrator: migrator,
      databaseHost: 'db.internal',
      databasePort: 5432,
    );

    final result = await provisioner.provision(
      ownerAccountId: 'owner-1',
      displayName: '  Main Store  ',
    );

    expect(result.status, 'ACTIVE');
    expect(result.displayName, 'Main Store');
    expect(result.schemaVersion, '20261124_008_inventory_adjustment_accounts');
    expect(repository.registered, isTrue);
    expect(repository.active, isTrue);
    expect(repository.failed, isFalse);
    expect(admin.databaseName, 'store_${result.storeId.replaceAll('-', '')}');
    expect(admin.databaseRole, admin.databaseName);
    expect(secrets.values, contains(repository.secretRef));
    expect(migrator.databaseName, admin.databaseName);
  });

  test('migration failure leaves a failed provisioning record for recovery', () async {
    final repository = _FakeProvisioningRepository();
    final provisioner = StoreProvisioner(
      repository: repository,
      secretWriter: _FakeSecretWriter(),
      databaseAdmin: _FakeDatabaseAdmin(),
      schemaMigrator: _FakeMigrator()..shouldFail = true,
      databaseHost: 'db.internal',
      databasePort: 5432,
    );

    await expectLater(
      provisioner.provision(ownerAccountId: 'owner-1', displayName: 'Store B'),
      throwsA(isA<StateError>()),
    );
    expect(repository.failed, isTrue);
    expect(repository.active, isFalse);
  });

  test('rejects blank or control-character store names before provisioning', () async {
    final repository = _FakeProvisioningRepository();
    final provisioner = StoreProvisioner(
      repository: repository,
      secretWriter: _FakeSecretWriter(),
      databaseAdmin: _FakeDatabaseAdmin(),
      schemaMigrator: _FakeMigrator(),
      databaseHost: 'db.internal',
      databasePort: 5432,
    );

    await expectLater(
      provisioner.provision(ownerAccountId: 'owner-1', displayName: '  '),
      throwsFormatException,
    );
    await expectLater(
      provisioner.provision(ownerAccountId: 'owner-1', displayName: 'bad\nname'),
      throwsFormatException,
    );
    expect(repository.registered, isFalse);
  });
}

final class _FakeProvisioningRepository implements StoreProvisioningRepository {
  bool registered = false;
  bool active = false;
  bool failed = false;
  String? secretRef;

  @override
  Future<void> registerProvisioning({
    required String storeId,
    required String operationId,
    required String membershipId,
    required String ownerAccountId,
    required String displayName,
    required String databaseName,
    required String databaseRole,
    required String secretRef,
  }) async {
    registered = true;
    this.secretRef = secretRef;
  }

  @override
  Future<void> setProvisioningStatus(String operationId, String status) async {}

  @override
  Future<void> markStoreActive({
    required String storeId,
    required String operationId,
    required String schemaVersion,
  }) async {
    active = true;
  }

  @override
  Future<void> markStoreProvisioningFailed({
    required String storeId,
    required String operationId,
    required String errorCode,
  }) async {
    failed = true;
  }
}

final class _FakeSecretWriter implements StoreSecretWriter {
  final Map<String, String> values = {};

  @override
  Future<void> writeSecret(String secretRef, String secret) async {
    values[secretRef] = secret;
  }

  @override
  Future<String> readSecret(String secretRef) async => values[secretRef]!;
}

final class _FakeDatabaseAdmin implements StoreDatabaseAdmin {
  String? databaseName;
  String? databaseRole;

  @override
  Future<void> createDatabase({
    required String storeId,
    required String databaseName,
    required String databaseRole,
    required String password,
  }) async {
    PostgresStoreDatabaseAdmin.validateProvisioningIdentifiers(
      storeId: storeId,
      databaseName: databaseName,
      databaseRole: databaseRole,
      password: password,
    );
    this.databaseName = databaseName;
    this.databaseRole = databaseRole;
  }
}

final class _FakeMigrator implements StoreSchemaMigrator {
  bool shouldFail = false;
  String? databaseName;

  @override
  Future<String> applyMigrations({
    required String host,
    required int port,
    required String databaseName,
    required String databaseRole,
    required String password,
  }) async {
    this.databaseName = databaseName;
    if (shouldFail) throw StateError('migration failed');
    return '20261124_008_inventory_adjustment_accounts';
  }
}
