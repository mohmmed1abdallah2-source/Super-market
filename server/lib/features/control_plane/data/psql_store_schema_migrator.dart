import 'dart:io';

import 'package:crypto/crypto.dart';

import '../application/store_provisioner.dart';

/// Applies the ordered, versioned SQL migration bundle shipped with the API.
///
/// Requires the PostgreSQL `psql` client in the runtime image. Credentials are
/// passed through PGPASSWORD in the child process environment, never argv.
final class PsqlStoreSchemaMigrator implements StoreSchemaMigrator {
  const PsqlStoreSchemaMigrator({
    required this.migrationsDirectory,
  });

  final String migrationsDirectory;

  static final RegExp _migrationName =
      RegExp(r'^[0-9]{8}_[0-9]{3}_[a-z0-9_]+\.sql$');

  static bool isStoreMigrationFileName(String name) =>
      _migrationName.hasMatch(name);

  @override
  Future<String> applyMigrations({
    required String host,
    required int port,
    required String databaseName,
    required String databaseRole,
    required String password,
  }) async {
    final files = await Directory(migrationsDirectory)
        .list(followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    files.sort((left, right) =>
        left.uri.pathSegments.last.compareTo(right.uri.pathSegments.last));
    final migrations = files
        .where((file) => isStoreMigrationFileName(file.uri.pathSegments.last))
        .toList(growable: false);
    if (migrations.length < 8) {
      throw StateError('STORE_MIGRATION_BUNDLE_INCOMPLETE');
    }

    await _runPsql(
      host: host,
      port: port,
      database: databaseName,
      username: databaseRole,
      password: password,
      arguments: [
        '--command',
        '''CREATE TABLE IF NOT EXISTS public.schema_migrations (
             version TEXT PRIMARY KEY,
             checksum TEXT NOT NULL,
             applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
           )''',
      ],
    );

    String? latestVersion;
    for (final file in migrations) {
      final name = file.uri.pathSegments.last;
      final version = name.substring(0, name.length - 4);
      final checksum = sha256.convert(await file.readAsBytes()).toString();
      final existing = await _runPsql(
        host: host,
        port: port,
        database: databaseName,
        username: databaseRole,
        password: password,
        captureOutput: true,
        arguments: [
          '--command',
          "SELECT checksum FROM public.schema_migrations WHERE version = '$version'",
        ],
      );
      final storedChecksum = existing.trim();
      if (storedChecksum.isNotEmpty) {
        if (storedChecksum != checksum) {
          throw StateError('STORE_MIGRATION_CHECKSUM_MISMATCH');
        }
        latestVersion = version;
        continue;
      }

      await _runPsql(
        host: host,
        port: port,
        database: databaseName,
        username: databaseRole,
        password: password,
        arguments: ['--file', file.path],
      );
      await _runPsql(
        host: host,
        port: port,
        database: databaseName,
        username: databaseRole,
        password: password,
        arguments: [
          '--command',
          "INSERT INTO public.schema_migrations(version, checksum) VALUES ('$version', '$checksum')",
        ],
      );
      latestVersion = version;
    }
    if (latestVersion == null) {
      throw StateError('STORE_MIGRATION_BUNDLE_EMPTY');
    }
    return latestVersion;
  }

  Future<String> _runPsql({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
    required List<String> arguments,
    bool captureOutput = false,
  }) async {
    final result = await Process.run(
      'psql',
      [
        '--no-psqlrc',
        '--set=ON_ERROR_STOP=1',
        '--no-align',
        '--tuples-only',
        '--host',
        host,
        '--port',
        port.toString(),
        '--username',
        username,
        '--dbname',
        database,
        ...arguments,
      ],
      environment: {
        'PGPASSWORD': password,
        'PGCONNECT_TIMEOUT': '15',
      },
    );
    if (result.exitCode != 0) {
      throw StateError('STORE_DATABASE_MIGRATION_FAILED');
    }
    return captureOutput ? result.stdout.toString() : '';
  }
}
