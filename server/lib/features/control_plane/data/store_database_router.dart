import 'package:postgres/postgres.dart';

/// Immutable authorization result produced only after token and membership
/// verification against the control plane.
final class StoreRequestContext {
  const StoreRequestContext({
    required this.accountId,
    required this.storeId,
    required this.membershipId,
    required this.sessionId,
    required this.role,
  });

  final String accountId;
  final String storeId;
  final String membershipId;
  final String sessionId;
  final String role;
}

/// Server-side database locator. Never serialize this type into an API response.
final class StoreDatabaseDescriptor {
  const StoreDatabaseDescriptor({
    required this.storeId,
    required this.databaseName,
    required this.databaseRole,
    required this.secretRef,
    required this.status,
  });

  final String storeId;
  final String databaseName;
  final String databaseRole;
  final String secretRef;
  final String status;
}

abstract interface class StoreDatabaseDirectory {
  Future<StoreDatabaseDescriptor?> findByStoreId(String storeId);
}

abstract interface class StoreSecretStore {
  Future<String> readSecret(String secretRef);
}

/// Write capability required only by the privileged store-provisioning service.
abstract interface class StoreSecretWriter implements StoreSecretStore {
  Future<void> writeSecret(String secretRef, String secret);
}

typedef StorePostgresConnectionFactory = PostgreSQLConnection Function({
  required String host,
  required int port,
  required String database,
  required String username,
  required String password,
});

/// Resolves the database exclusively from a verified store session.
///
/// A fresh connection is opened per scoped operation and always closed by
/// [withStoreConnection]. This deliberately avoids a shared connection whose
/// tenant context could be changed between requests.
final class StoreDatabaseRouter {
  StoreDatabaseRouter({
    required this.host,
    required this.port,
    required StoreDatabaseDirectory directory,
    required StoreSecretStore secretStore,
    StorePostgresConnectionFactory? connectionFactory,
  })  : _directory = directory,
        _secretStore = secretStore,
        _connectionFactory = connectionFactory ?? _defaultConnectionFactory;

  final String host;
  final int port;
  final StoreDatabaseDirectory _directory;
  final StoreSecretStore _secretStore;
  final StorePostgresConnectionFactory _connectionFactory;

  Future<T> withStoreConnection<T>(
    StoreRequestContext context,
    Future<T> Function(PostgreSQLConnection connection) action,
  ) async {
    final descriptor = await _directory.findByStoreId(context.storeId);
    if (descriptor == null) {
      throw StateError('STORE_DATABASE_NOT_FOUND');
    }
    validateDescriptor(context.storeId, descriptor);
    final password = await _secretStore.readSecret(descriptor.secretRef);
    if (password.isEmpty) {
      throw StateError('STORE_DATABASE_SECRET_UNAVAILABLE');
    }

    final connection = _connectionFactory(
      host: host,
      port: port,
      database: descriptor.databaseName,
      username: descriptor.databaseRole,
      password: password,
    );
    try {
      await connection.open();
      return await action(connection);
    } finally {
      await connection.close();
    }
  }

  /// Rejects any locator not generated from the opaque store UUID.
  static void validateDescriptor(
    String requestedStoreId,
    StoreDatabaseDescriptor descriptor,
  ) {
    final compactId = requestedStoreId.replaceAll('-', '').toLowerCase();
    final uuidPattern = RegExp(r'^[0-9a-f]{32}$');
    if (!uuidPattern.hasMatch(compactId) ||
        descriptor.storeId.toLowerCase() != requestedStoreId.toLowerCase() ||
        descriptor.databaseName != 'store_$compactId' ||
        descriptor.databaseRole != 'store_$compactId' ||
        descriptor.secretRef.trim().isEmpty ||
        descriptor.status != 'ACTIVE') {
      throw StateError('STORE_DATABASE_NOT_ROUTABLE');
    }
  }

  static PostgreSQLConnection _defaultConnectionFactory({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
  }) =>
      PostgreSQLConnection(
        host,
        port,
        database,
        username: username,
        password: password,
        timeoutInSeconds: 30,
      );
}

/// Reads only the server-side locator fields from the control-plane database.
final class PostgresStoreDatabaseDirectory implements StoreDatabaseDirectory {
  const PostgresStoreDatabaseDirectory(this._controlPlane);

  final PostgreSQLConnection _controlPlane;

  @override
  Future<StoreDatabaseDescriptor?> findByStoreId(String storeId) async {
    final rows = await _controlPlane.mappedResultsQuery(
      '''SELECT store_id::text AS "storeId",
                database_name AS "databaseName",
                database_role AS "databaseRole",
                database_secret_ref AS "secretRef",
                status
         FROM cp_stores WHERE store_id = @storeId LIMIT 1''',
      substitutionValues: {'storeId': storeId},
    );
    if (rows.isEmpty) return null;
    final row = rows.single.values.first;
    return StoreDatabaseDescriptor(
      storeId: row['storeId'] as String,
      databaseName: row['databaseName'] as String,
      databaseRole: row['databaseRole'] as String,
      secretRef: row['secretRef'] as String,
      status: row['status'] as String,
    );
  }
}
