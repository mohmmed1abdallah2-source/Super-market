import 'package:uuid/uuid.dart';

import '../domain/control_plane_security.dart';
import '../data/store_database_router.dart';

abstract interface class StoreProvisioningRepository {
  Future<void> registerProvisioning({
    required String storeId,
    required String operationId,
    required String ownerAccountId,
    required String displayName,
    required String databaseName,
    required String databaseRole,
    required String secretRef,
  });

  Future<void> setProvisioningStatus(String operationId, String status);

  Future<void> markStoreActive({
    required String storeId,
    required String operationId,
    required String schemaVersion,
  });

  Future<void> markStoreProvisioningFailed({
    required String storeId,
    required String operationId,
    required String errorCode,
  });
}

abstract interface class StoreDatabaseAdmin {
  Future<void> createDatabase({
    required String storeId,
    required String databaseName,
    required String databaseRole,
    required String password,
  });
}

abstract interface class StoreSchemaMigrator {
  Future<String> applyMigrations({
    required String host,
    required int port,
    required String databaseName,
    required String databaseRole,
    required String password,
  });
}

final class StoreProvisioningResult {
  const StoreProvisioningResult({
    required this.storeId,
    required this.displayName,
    required this.status,
    required this.schemaVersion,
  });

  final String storeId;
  final String displayName;
  final String status;
  final String schemaVersion;
}

/// Coordinates the non-transactional PostgreSQL database creation saga.
///
/// A failed operation is marked for operator recovery. This service never
/// silently deletes a partially-created database or its secret.
final class StoreProvisioner {
  StoreProvisioner({
    required StoreProvisioningRepository repository,
    required StoreSecretWriter secretWriter,
    required StoreDatabaseAdmin databaseAdmin,
    required StoreSchemaMigrator schemaMigrator,
    required this.databaseHost,
    required this.databasePort,
    Uuid? uuid,
  })  : _repository = repository,
        _secretWriter = secretWriter,
        _databaseAdmin = databaseAdmin,
        _schemaMigrator = schemaMigrator,
        _uuid = uuid ?? const Uuid();

  final StoreProvisioningRepository _repository;
  final StoreSecretWriter _secretWriter;
  final StoreDatabaseAdmin _databaseAdmin;
  final StoreSchemaMigrator _schemaMigrator;
  final String databaseHost;
  final int databasePort;
  final Uuid _uuid;

  Future<StoreProvisioningResult> provision({
    required String ownerAccountId,
    required String displayName,
  }) async {
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty ||
        normalizedName.length > 160 ||
        normalizedName.contains(RegExp(r'[\u0000-\u001f]'))) {
      throw const FormatException('Store name must contain 1 to 160 printable characters.');
    }

    final storeId = _uuid.v4();
    final operationId = _uuid.v4();
    final compactId = storeId.replaceAll('-', '').toLowerCase();
    final databaseName = 'store_$compactId';
    final databaseRole = 'store_$compactId';
    final secretRef = 'store-db/$storeId';
    final databasePassword = OpaqueSessionToken.generate().value;

    await _repository.registerProvisioning(
      storeId: storeId,
      operationId: operationId,
      ownerAccountId: ownerAccountId,
      displayName: normalizedName,
      databaseName: databaseName,
      databaseRole: databaseRole,
      secretRef: secretRef,
    );

    try {
      await _secretWriter.writeSecret(secretRef, databasePassword);
      await _databaseAdmin.createDatabase(
        storeId: storeId,
        databaseName: databaseName,
        databaseRole: databaseRole,
        password: databasePassword,
      );
      await _repository.setProvisioningStatus(operationId, 'DATABASE_CREATED');

      final schemaVersion = await _schemaMigrator.applyMigrations(
        host: databaseHost,
        port: databasePort,
        databaseName: databaseName,
        databaseRole: databaseRole,
        password: databasePassword,
      );
      await _repository.setProvisioningStatus(operationId, 'MIGRATED');
      await _repository.markStoreActive(
        storeId: storeId,
        operationId: operationId,
        schemaVersion: schemaVersion,
      );
      return StoreProvisioningResult(
        storeId: storeId,
        displayName: normalizedName,
        status: 'ACTIVE',
        schemaVersion: schemaVersion,
      );
    } catch (error) {
      try {
        await _repository.markStoreProvisioningFailed(
          storeId: storeId,
          operationId: operationId,
          errorCode: _safeErrorCode(error),
        );
      } catch (_) {
        // Preserve the original provisioning failure; reconciliation is manual.
      }
      rethrow;
    }
  }

  String _safeErrorCode(Object error) {
    final value = error is StateError ? error.message : error.runtimeType.toString();
    final normalized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return normalized.length > 120 ? normalized.substring(0, 120) : normalized;
  }
}
