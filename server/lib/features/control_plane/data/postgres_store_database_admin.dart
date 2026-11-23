import 'package:postgres/postgres.dart';

import '../application/store_provisioner.dart';

/// Creates a dedicated non-superuser role and one database for a single store.
///
/// The supplied connection must use a separately managed provisioning
/// administrator. It must never be the normal API runtime connection.
final class PostgresStoreDatabaseAdmin implements StoreDatabaseAdmin {
  const PostgresStoreDatabaseAdmin(this._administrator);

  final PostgreSQLConnection _administrator;

  @override
  Future<void> createDatabase({
    required String storeId,
    required String databaseName,
    required String databaseRole,
    required String password,
  }) async {
    validateProvisioningIdentifiers(
      storeId: storeId,
      databaseName: databaseName,
      databaseRole: databaseRole,
      password: password,
    );

    await _administrator.execute(
      '''CREATE ROLE "$databaseRole"
         LOGIN PASSWORD '$password'
         NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
         CONNECTION LIMIT 20''',
    );
    await _administrator.execute(
      '''CREATE DATABASE "$databaseName"
         OWNER "$databaseRole"
         TEMPLATE template0
         ENCODING 'UTF8'
         CONNECTION LIMIT 50''',
    );
    await _administrator.execute(
      'REVOKE CONNECT ON DATABASE "$databaseName" FROM PUBLIC',
    );
    await _administrator.execute(
      'GRANT CONNECT ON DATABASE "$databaseName" TO "$databaseRole"',
    );
  }

  static void validateProvisioningIdentifiers({
    required String storeId,
    required String databaseName,
    required String databaseRole,
    required String password,
  }) {
    final compactId = storeId.replaceAll('-', '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(compactId) ||
        databaseName != 'store_$compactId' ||
        databaseRole != 'store_$compactId' ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(password)) {
      throw const FormatException('Invalid generated store provisioning identity.');
    }
  }
}
