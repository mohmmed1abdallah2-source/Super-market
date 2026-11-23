import 'package:postgres/postgres.dart';

import '../application/store_provisioner.dart';

/// PostgreSQL persistence for the store-provisioning saga.
final class PostgresStoreProvisioningRepository
    implements StoreProvisioningRepository {
  const PostgresStoreProvisioningRepository(this._connection);

  final PostgreSQLConnection _connection;

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
    await _connection.transaction((ctx) async {
      await ctx.execute(
        '''INSERT INTO cp_stores
             (store_id, display_name, status, database_name, database_role,
              database_secret_ref, created_by_account_id)
           VALUES (@store, @name, 'PROVISIONING', @database, @role,
                   @secretRef, @owner)''',
        substitutionValues: {
          'store': storeId,
          'name': displayName,
          'database': databaseName,
          'role': databaseRole,
          'secretRef': secretRef,
          'owner': ownerAccountId,
        },
      );
      await ctx.execute(
        '''INSERT INTO cp_memberships
             (membership_id, account_id, store_id, role, status, created_by_account_id)
           VALUES (@membership, @owner, @store, 'OWNER', 'ACTIVE', @owner)''',
        substitutionValues: {
          'membership': membershipId,
          'owner': ownerAccountId,
          'store': storeId,
        },
      );
      await ctx.execute(
        '''INSERT INTO cp_provisioning_operations
             (operation_id, store_id, requested_by_account_id, status)
           VALUES (@operation, @store, @owner, 'PENDING')''',
        substitutionValues: {
          'operation': operationId,
          'store': storeId,
          'owner': ownerAccountId,
        },
      );
    });
  }

  @override
  Future<void> setProvisioningStatus(String operationId, String status) async {
    if (!const {'DATABASE_CREATED', 'MIGRATED'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    final result = await _connection.execute(
      '''UPDATE cp_provisioning_operations
         SET status = @status
         WHERE operation_id = @operation
           AND status IN ('PENDING', 'DATABASE_CREATED')''',
      substitutionValues: {'status': status, 'operation': operationId},
    );
    if (result.affectedRowCount != 1) {
      throw StateError('PROVISIONING_OPERATION_STATE_CONFLICT');
    }
  }

  @override
  Future<void> markStoreActive({
    required String storeId,
    required String operationId,
    required String schemaVersion,
  }) async {
    await _connection.transaction((ctx) async {
      final store = await ctx.execute(
        '''UPDATE cp_stores
           SET status = 'ACTIVE', schema_version = @version, updated_at = now()
           WHERE store_id = @store AND status = 'PROVISIONING' ''',
        substitutionValues: {'version': schemaVersion, 'store': storeId},
      );
      if (store.affectedRowCount != 1) {
        throw StateError('STORE_ACTIVATION_STATE_CONFLICT');
      }
      final operation = await ctx.execute(
        '''UPDATE cp_provisioning_operations
           SET status = 'COMPLETED', completed_at = now()
           WHERE operation_id = @operation AND store_id = @store
             AND status = 'MIGRATED' ''',
        substitutionValues: {'operation': operationId, 'store': storeId},
      );
      if (operation.affectedRowCount != 1) {
        throw StateError('PROVISIONING_OPERATION_STATE_CONFLICT');
      }
    });
  }

  @override
  Future<void> markStoreProvisioningFailed({
    required String storeId,
    required String operationId,
    required String errorCode,
  }) async {
    await _connection.transaction((ctx) async {
      await ctx.execute(
        '''UPDATE cp_stores SET status = 'PROVISION_FAILED', updated_at = now()
           WHERE store_id = @store AND status <> 'ACTIVE' ''',
        substitutionValues: {'store': storeId},
      );
      await ctx.execute(
        '''UPDATE cp_provisioning_operations
           SET status = 'FAILED', error_code = @error
           WHERE operation_id = @operation AND store_id = @store
             AND status <> 'COMPLETED' ''',
        substitutionValues: {
          'operation': operationId,
          'store': storeId,
          'error': errorCode,
        },
      );
    });
  }
}
