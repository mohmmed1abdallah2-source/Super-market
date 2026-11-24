import 'dart:convert';
import 'package:postgres/postgres.dart';
import '../domain/control_plane_sessions.dart';

final class StoreDatabaseCredentials {
  const StoreDatabaseCredentials({required this.host, required this.port, required this.database, required this.username, required this.password, required this.useSsl});
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final bool useSsl;
}

abstract interface class StoreDatabaseCredentialsProvider {
  StoreDatabaseCredentials? credentialsFor(String databaseKey);
}

/// Deployment should inject this JSON from its secret manager.
final class EnvironmentStoreDatabaseCredentialsProvider implements StoreDatabaseCredentialsProvider {
  EnvironmentStoreDatabaseCredentialsProvider(String? encoded) {
    if (encoded == null || encoded.trim().isEmpty) {
      _entries = const {};
      return;
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ERP_STORE_DATABASES_JSON must be a JSON object.');
    }
    _entries = decoded;
  }
  late final Map<String, dynamic> _entries;

  @override
  StoreDatabaseCredentials? credentialsFor(String databaseKey) {
    final value = _entries[databaseKey];
    if (value is! Map<String, dynamic>) return null;
    final host = value['host'];
    final database = value['database'];
    final username = value['username'];
    final password = value['password'];
    final portValue = value['port'] ?? 5432;
    final ssl = value['ssl'] ?? true;
    final port = portValue is int ? portValue : int.tryParse('$portValue');
    if (host is! String || host.trim().isEmpty ||
        database is! String || database.trim().isEmpty ||
        username is! String || username.trim().isEmpty ||
        password is! String || password.isEmpty ||
        port == null || port < 1 || port > 65535 || ssl is! bool) {
      return null;
    }
    return StoreDatabaseCredentials(host: host.trim(), port: port,
      database: database.trim(), username: username.trim(),
      password: password, useSsl: ssl);
  }
}

final class StoreDatabaseUnavailableException implements Exception {
  const StoreDatabaseUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class StoreDatabaseConnectionResolver {
  const StoreDatabaseConnectionResolver({required this.bindings, required this.credentialsProvider});
  final StoreDatabaseBindingRepository bindings;
  final StoreDatabaseCredentialsProvider credentialsProvider;

  Future<StoreDatabaseCredentials> resolveCredentialsForStore(String storeId) async {
    String? key;
    try {
      key = await bindings.readyDatabaseKeyForStore(storeId);
    } catch (_) {
      throw const StoreDatabaseUnavailableException(
        'The active store database binding could not be resolved.',
      );
    }
    if (key == null || key.trim().isEmpty) {
      throw const StoreDatabaseUnavailableException('The active store has no READY database binding.');
    }
    final credentials = credentialsProvider.credentialsFor(key);
    if (credentials == null) {
      throw const StoreDatabaseUnavailableException('Credentials for the active store database are unavailable.');
    }
    return credentials;
  }

  Future<PostgreSQLConnection> openForStore(String storeId) async {
    final credentials = await resolveCredentialsForStore(storeId);
    final connection = PostgreSQLConnection(credentials.host, credentials.port, credentials.database,
      username: credentials.username, password: credentials.password,
      timeoutInSeconds: 30, useSSL: credentials.useSsl);
    try {
      await connection.open();
      return connection;
    } catch (_) {
      try { await connection.close(); } catch (_) {}
      throw const StoreDatabaseUnavailableException('The active store database could not be reached.');
    }
  }
}
