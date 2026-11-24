import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/control_plane_domain.dart';
import '../domain/control_plane_sessions.dart';

/// PostgreSQL persistence for the dedicated control-plane database.
/// This connection must never point at an operational store database.
final class PostgresControlPlaneRepository implements ControlPlaneRepository, ControlPlaneSessionRepository {
  PostgresControlPlaneRepository(this._connection);

  final PostgreSQLConnection _connection;
  static const _uuid = Uuid();

  @override
  Future<String> resolveVerifiedAccount(VerifiedAccountIdentity identity) async {
    identity.validate();
    return _connection.transaction((ctx) async {
      final existingIdentity = await ctx.mappedResultsQuery(
        '''SELECT account_id::text AS "accountId"
           FROM cp_account_identities
           WHERE provider = @provider AND provider_subject = @subject''',
        substitutionValues: {'provider': identity.provider, 'subject': identity.subject},
      );
      if (existingIdentity.isNotEmpty) {
        final accountId = _flatten(existingIdentity.single)['accountId'] as String;
        final account = await ctx.mappedResultsQuery(
          "SELECT status FROM cp_accounts WHERE id = @id",
          substitutionValues: {'id': accountId},
        );
        if (account.isEmpty || _flatten(account.single)['status'] != 'ACTIVE') {
          throw StateError('Account is not active.');
        }
        return accountId;
      }
      final matchingAccount = await ctx.mappedResultsQuery(
        '''SELECT id::text AS id, status FROM cp_accounts
           WHERE lower(btrim(primary_email)) = lower(btrim(@email)) FOR UPDATE''',
        substitutionValues: {'email': identity.email},
      );
      late final String accountId;
      if (matchingAccount.isNotEmpty) {
        final row = _flatten(matchingAccount.single);
        if (row['status'] != 'ACTIVE') throw StateError('Account is not active.');
        accountId = row['id'] as String;
      } else {
        accountId = _uuid.v4();
        await ctx.execute(
          '''INSERT INTO cp_accounts(id, primary_email, display_name)
             VALUES (@id, @email, @name)''',
          substitutionValues: {
            'id': accountId,
            'email': identity.email.trim(),
            'name': identity.displayName?.trim(),
          },
        );
      }
      await ctx.execute(
        '''INSERT INTO cp_account_identities(
             id, account_id, provider, provider_subject, email, email_verified
           ) VALUES (@id, @account, @provider, @subject, @email, TRUE)''',
        substitutionValues: {
          'id': _uuid.v4(), 'account': accountId,
          'provider': identity.provider, 'subject': identity.subject,
          'email': identity.email.trim(),
        },
      );
      return accountId;
    });
  }

  @override
  Future<List<AccountStoreAccess>> listActiveStores(String accountId) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT s.id::text AS "storeId", s.display_name AS "displayName",
                s.status AS "storeStatus", m.role
         FROM cp_store_memberships m
         JOIN cp_accounts a ON a.id = m.account_id
         JOIN cp_stores s ON s.id = m.store_id
         WHERE m.account_id = @account AND m.status = 'ACTIVE'
           AND a.status = 'ACTIVE' AND s.status IN ('ACTIVE', 'PROVISIONING', 'SUSPENDED')
         ORDER BY s.display_name''',
      substitutionValues: {'account': accountId},
    );
    return rows.map((row) {
      final data = _flatten(row);
      return AccountStoreAccess(
        storeId: data['storeId'] as String,
        displayName: data['displayName'] as String,
        role: _role(data['role'] as String),
        storeStatus: _storeStatus(data['storeStatus'] as String),
      );
    }).toList(growable: false);
  }

  @override
  Future<String> createStore({
    required String storeId,
    required String membershipId,
    required String ownerAccountId,
    required String displayName,
  }) =>
      _connection.transaction((ctx) async {
        final account = await ctx.mappedResultsQuery(
          "SELECT status FROM cp_accounts WHERE id = @id FOR UPDATE",
          substitutionValues: {'id': ownerAccountId},
        );
        if (account.isEmpty || _flatten(account.single)['status'] != 'ACTIVE') {
          throw StateError('An active account is required to create a store.');
        }
        await ctx.execute(
          '''INSERT INTO cp_stores(id, display_name, status, created_by_account_id)
             VALUES (@id, @name, 'PROVISIONING', @owner)''',
          substitutionValues: {
            'id': storeId, 'name': displayName, 'owner': ownerAccountId,
          },
        );
        await ctx.execute(
          '''INSERT INTO cp_store_memberships(id, account_id, store_id, role, status)
             VALUES (@membership, @owner, @store, 'OWNER', 'ACTIVE')''',
          substitutionValues: {
            'membership': membershipId,
            'owner': ownerAccountId,
            'store': storeId,
          },
        );
        return storeId;
      });


  @override
  Future<void> changeStoreStatus({
    required String actorAccountId,
    required String storeId,
    required ControlPlaneStoreStatus status,
  }) =>
      _connection.transaction((ctx) async {
        final actorRole = await _requireActor(
          ctx, actorAccountId, storeId, StorePermission.manageStore,
          allowSuspended: true,
        );
        if (actorRole != StoreMembershipRole.owner) {
          throw StateError('Only the store owner can change store lifecycle state.');
        }
        final rows = await ctx.mappedResultsQuery(
          "SELECT status FROM cp_stores WHERE id = @store FOR UPDATE",
          substitutionValues: {'store': storeId},
        );
        if (rows.isEmpty) throw StateError('Store was not found.');
        final current = _flatten(rows.single)['status'] as String;
        if (current == 'CLOSED' || current == 'FAILED') {
          throw StateError('Closed or failed stores cannot be reactivated.');
        }
        final next = status.name.toUpperCase();
        if (next == 'ACTIVE') {
          final binding = await ctx.mappedResultsQuery(
            '''SELECT status FROM cp_store_database_bindings
               WHERE store_id = @store''',
            substitutionValues: {'store': storeId},
          );
          if (binding.isEmpty || _flatten(binding.single)['status'] != 'READY') {
            throw StateError('Store database binding must be READY before activation.');
          }
          if (current != 'PROVISIONING' && current != 'SUSPENDED') {
            throw StateError('Store cannot transition to ACTIVE from its current state.');
          }
        } else if (next == 'SUSPENDED') {
          if (current != 'ACTIVE') {
            throw StateError('Only an active store can be suspended.');
          }
        } else if (next != 'CLOSED') {
          throw StateError('Unsupported store lifecycle transition.');
        }
        await ctx.execute(
          '''UPDATE cp_stores SET status = @status, updated_at = now()
             WHERE id = @store''',
          substitutionValues: {'status': next, 'store': storeId},
        );
      });

  @override
  Future<void> addMember({
    required String membershipId,
    required String actorAccountId,
    required String targetAccountId,
    required String storeId,
    required StoreMembershipRole role,
  }) =>
      _connection.transaction((ctx) async {
        final actorRole = await _requireActor(ctx, actorAccountId, storeId, StorePermission.inviteMembers);
        if (actorRole != StoreMembershipRole.owner &&
            _roleRank(role) >= _roleRank(actorRole)) {
          throw StateError('An administrator cannot invite an equal or higher role.');
        }
        final target = await ctx.mappedResultsQuery(
          "SELECT status FROM cp_accounts WHERE id = @id FOR UPDATE",
          substitutionValues: {'id': targetAccountId},
        );
        if (target.isEmpty || _flatten(target.single)['status'] != 'ACTIVE') {
          throw StateError('Target account is not active.');
        }
        await ctx.execute(
          '''INSERT INTO cp_store_memberships(id, account_id, store_id, role, status)
             VALUES (@id, @account, @store, @role, 'INVITED')''',
          substitutionValues: {
            'id': membershipId,
            'account': targetAccountId,
            'store': storeId,
            'role': _roleName(role),
          },
        );
      });


  @override
  Future<void> acceptInvitation({
    required String accountId,
    required String storeId,
  }) =>
      _connection.transaction((ctx) async {
        final account = await ctx.mappedResultsQuery(
          "SELECT status FROM cp_accounts WHERE id = @account FOR UPDATE",
          substitutionValues: {'account': accountId},
        );
        if (account.isEmpty || _flatten(account.single)['status'] != 'ACTIVE') {
          throw StateError('An active account is required to accept an invitation.');
        }
        final store = await ctx.mappedResultsQuery(
          "SELECT status FROM cp_stores WHERE id = @store FOR UPDATE",
          substitutionValues: {'store': storeId},
        );
        if (store.isEmpty || !const {'ACTIVE', 'PROVISIONING'}.contains(_flatten(store.single)['status'])) {
          throw StateError('Store is not accepting membership invitations.');
        }
        final result = await ctx.execute(
          '''UPDATE cp_store_memberships
             SET status = 'ACTIVE', updated_at = now()
             WHERE account_id = @account AND store_id = @store
               AND status = 'INVITED' ''',
          substitutionValues: {'account': accountId, 'store': storeId},
        );
        if (result == 0) throw StateError('No pending invitation was found.');
      });

  @override
  Future<void> changeMemberRole({
    required String actorAccountId,
    required String targetAccountId,
    required String storeId,
    required StoreMembershipRole role,
  }) =>
      _connection.transaction((ctx) async {
        final actorRole = await _requireActor(
          ctx, actorAccountId, storeId, StorePermission.changeMemberRoles,
        );
        if (actorRole != StoreMembershipRole.owner &&
            _roleRank(role) <= _roleRank(actorRole)) {
          throw StateError('An administrator cannot assign an equal or higher role.');
        }
        final target = await ctx.mappedResultsQuery(
          '''SELECT role, status FROM cp_store_memberships
             WHERE account_id = @account AND store_id = @store FOR UPDATE''',
          substitutionValues: {'account': targetAccountId, 'store': storeId},
        );
        if (target.isEmpty) throw StateError('Membership was not found.');
        final targetData = _flatten(target.single);
        if (targetData['role'] == 'OWNER') {
          throw StateError('Owner role cannot be changed through member role management.');
        }
        if (targetData['status'] == 'REVOKED') {
          throw StateError('Revoked membership cannot be changed.');
        }
        await ctx.execute(
          '''UPDATE cp_store_memberships
             SET role = @role, updated_at = now()
             WHERE account_id = @account AND store_id = @store''',
          substitutionValues: {
            'role': _roleName(role),
            'account': targetAccountId,
            'store': storeId,
          },
        );
      });

  @override
  Future<void> changeMemberStatus({
    required String actorAccountId,
    required String targetAccountId,
    required String storeId,
    required StoreMembershipStatus status,
  }) =>
      _connection.transaction((ctx) async {
        final actorRole = await _requireActor(
          ctx, actorAccountId, storeId, StorePermission.suspendMembers,
        );
        final target = await ctx.mappedResultsQuery(
          '''SELECT role, status FROM cp_store_memberships
             WHERE account_id = @account AND store_id = @store FOR UPDATE''',
          substitutionValues: {'account': targetAccountId, 'store': storeId},
        );
        if (target.isEmpty) throw StateError('Membership was not found.');
        final data = _flatten(target.single);
        if (data['role'] == 'OWNER') {
          throw StateError('Store owner membership cannot be suspended or revoked.');
        }
        if (actorRole != StoreMembershipRole.owner &&
            _roleRank(data['role'] as String) >= _roleRank(actorRole)) {
          throw StateError('An administrator cannot suspend an equal or higher role.');
        }
        await ctx.execute(
          '''UPDATE cp_store_memberships
             SET status = @status, updated_at = now()
             WHERE account_id = @account AND store_id = @store''',
          substitutionValues: {
            'status': _statusName(status),
            'account': targetAccountId,
            'store': storeId,
          },
        );
      });

  @override
  Future<List<StoreMember>> listMembers({
    required String actorAccountId,
    required String storeId,
  }) async {
    await _requireActor(
      _connection, actorAccountId, storeId, StorePermission.viewMembers,
    );
    final rows = await _connection.mappedResultsQuery(
      '''SELECT account_id::text AS "accountId", store_id::text AS "storeId",
                role, status
         FROM cp_store_memberships WHERE store_id = @store
         ORDER BY created_at, account_id''',
      substitutionValues: {'store': storeId},
    );
    return rows.map((row) {
      final data = _flatten(row);
      return StoreMember(
        accountId: data['accountId'] as String,
        storeId: data['storeId'] as String,
        role: _role(data['role'] as String),
        status: _membershipStatus(data['status'] as String),
      );
    }).toList(growable: false);
  }

  @override
  Future<bool> hasPermission({
    required String accountId,
    required String storeId,
    required StorePermission permission,
  }) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT m.role
         FROM cp_store_memberships m
         JOIN cp_accounts a ON a.id = m.account_id
         JOIN cp_stores s ON s.id = m.store_id
         WHERE m.account_id = @account AND m.store_id = @store
           AND m.status = 'ACTIVE' AND a.status = 'ACTIVE'
           AND s.status = 'ACTIVE'
         LIMIT 1''',
      substitutionValues: {'account': accountId, 'store': storeId},
    );
    if (rows.isEmpty) return false;
    return _role(_flatten(rows.single)['role'] as String).allows(permission);
  }

  Future<StoreMembershipRole> _requireActor(
    dynamic executor,
    String actor,
    String store,
    StorePermission permission, {
    bool allowSuspended = false,
  }) async {
    final rows = await executor.mappedResultsQuery(
      '''SELECT m.role
         FROM cp_store_memberships m
         JOIN cp_accounts a ON a.id = m.account_id
         JOIN cp_stores s ON s.id = m.store_id
         WHERE m.account_id = @account AND m.store_id = @store
           AND m.status = 'ACTIVE' AND a.status = 'ACTIVE'
           AND s.status IN ('ACTIVE', 'PROVISIONING'${allowSuspended ? ", 'SUSPENDED'" : ''})
         FOR UPDATE OF m''',
      substitutionValues: {'account': actor, 'store': store},
    );
    if (rows.isEmpty) throw StateError('Active store membership is required.');
    final role = _role(_flatten(rows.single)['role'] as String);
    if (!role.allows(permission)) throw StateError('Permission denied.');
    return role;
  }


  @override
  Future<void> createSession({
    required String sessionId,
    required String accountId,
    required String accessTokenHash,
    required DateTime expiresAt,
  }) async {
    final inserted = await _connection.execute(
      '''INSERT INTO cp_sessions(id, account_id, access_token_hash, expires_at)
         SELECT @id, a.id, @tokenHash, @expires
         FROM cp_accounts a WHERE a.id = @account AND a.status = 'ACTIVE' ''',
      substitutionValues: {
        'id': sessionId,
        'account': accountId,
        'tokenHash': accessTokenHash,
        'expires': expiresAt.toUtc(),
      },
    );
    if (inserted != 1) throw StateError('An active account is required to create a session.');
  }

  @override
  Future<ControlPlaneSession?> findSession(String accessTokenHash) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT se.id::text AS "sessionId", se.account_id::text AS "accountId",
                se.expires_at AS "expiresAt",
                s.id::text AS "storeId", s.display_name AS "displayName",
                s.status AS "storeStatus", m.role AS "storeRole"
         FROM cp_sessions se
         JOIN cp_accounts a ON a.id = se.account_id
         LEFT JOIN cp_stores s ON s.id = se.active_store_id
         LEFT JOIN cp_store_memberships m
           ON m.id = se.active_membership_id
          AND m.account_id = se.account_id AND m.store_id = se.active_store_id
          AND m.status = 'ACTIVE'
         WHERE se.access_token_hash = @tokenHash
           AND se.revoked_at IS NULL AND se.expires_at > now()
           AND a.status = 'ACTIVE'
         LIMIT 1''',
      substitutionValues: {'tokenHash': accessTokenHash},
    );
    if (rows.isEmpty) return null;
    final data = _flatten(rows.single);
    AccountStoreAccess? activeStore;
    if (data['storeId'] != null &&
        data['storeStatus'] == 'ACTIVE' &&
        data['storeRole'] != null) {
      activeStore = AccountStoreAccess(
        storeId: data['storeId'] as String,
        displayName: data['displayName'] as String,
        role: _role(data['storeRole'] as String),
        storeStatus: ControlPlaneStoreStatus.active,
      );
    }
    return ControlPlaneSession(
      sessionId: data['sessionId'] as String,
      accountId: data['accountId'] as String,
      expiresAt: (data['expiresAt'] as DateTime).toUtc(),
      activeStore: activeStore,
    );
  }

  @override
  Future<AccountStoreAccess> activateStore({
    required String accessTokenHash,
    required String storeId,
  }) => _connection.transaction((ctx) async {
        final rows = await ctx.mappedResultsQuery(
          '''SELECT se.account_id::text AS "accountId",
                    m.id::text AS "membershipId", m.role,
                    s.id::text AS "storeId", s.display_name AS "displayName",
                    s.status AS "storeStatus"
             FROM cp_sessions se
             JOIN cp_accounts a ON a.id = se.account_id
             JOIN cp_store_memberships m
               ON m.account_id = se.account_id AND m.store_id = @store
              AND m.status = 'ACTIVE'
             JOIN cp_stores s ON s.id = m.store_id AND s.status = 'ACTIVE'
             WHERE se.access_token_hash = @tokenHash
               AND se.revoked_at IS NULL AND se.expires_at > now()
               AND a.status = 'ACTIVE'
             FOR UPDATE OF se, m, s''',
          substitutionValues: {'tokenHash': accessTokenHash, 'store': storeId},
        );
        if (rows.isEmpty) {
          throw StateError('An active account, active membership and ACTIVE store are required.');
        }
        final data = _flatten(rows.single);
        await ctx.execute(
          '''UPDATE cp_sessions
             SET active_store_id = @store, active_membership_id = @membership,
                 last_seen_at = now()
             WHERE access_token_hash = @tokenHash
               AND revoked_at IS NULL AND expires_at > now()''',
          substitutionValues: {
            'store': storeId,
            'membership': data['membershipId'],
            'tokenHash': accessTokenHash,
          },
        );
        return AccountStoreAccess(
          storeId: data['storeId'] as String,
          displayName: data['displayName'] as String,
          role: _role(data['role'] as String),
          storeStatus: ControlPlaneStoreStatus.active,
        );
      });

  @override
  Future<void> revokeSession(String accessTokenHash) async {
    await _connection.execute(
      '''UPDATE cp_sessions SET revoked_at = now(), active_store_id = NULL,
                active_membership_id = NULL
         WHERE access_token_hash = @tokenHash AND revoked_at IS NULL''',
      substitutionValues: {'tokenHash': accessTokenHash},
    );
  }

  Map<String, dynamic> _flatten(Map<String, Map<String, dynamic>> row) =>
      row.values.first;

  StoreMembershipRole _role(String value) => StoreMembershipRole.values
      .firstWhere((role) => _roleName(role) == value);

  String _roleName(StoreMembershipRole role) => switch (role) {
        StoreMembershipRole.owner => 'OWNER',
        StoreMembershipRole.admin => 'ADMIN',
        StoreMembershipRole.manager => 'MANAGER',
        StoreMembershipRole.staff => 'STAFF',
        StoreMembershipRole.readOnly => 'READ_ONLY',
      };

  int _roleRank(Object role) => switch (role) {
        StoreMembershipRole.owner || 'OWNER' => 5,
        StoreMembershipRole.admin || 'ADMIN' => 4,
        StoreMembershipRole.manager || 'MANAGER' => 3,
        StoreMembershipRole.staff || 'STAFF' => 2,
        StoreMembershipRole.readOnly || 'READ_ONLY' => 1,
        _ => 0,
      };

  ControlPlaneStoreStatus _storeStatus(String value) =>
      ControlPlaneStoreStatus.values.firstWhere(
        (status) => status.name.toUpperCase() == value,
      );

  StoreMembershipStatus _membershipStatus(String value) =>
      StoreMembershipStatus.values.firstWhere(
        (status) => status.name.toUpperCase() == value,
      );

  String _statusName(StoreMembershipStatus status) => status.name.toUpperCase();
}
