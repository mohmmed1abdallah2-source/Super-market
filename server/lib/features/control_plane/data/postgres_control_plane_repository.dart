import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../data/store_database_router.dart';
import 'control_plane_security.dart';

final class StoreMembership {
  const StoreMembership({
    required this.membershipId,
    required this.storeId,
    required this.storeName,
    required this.role,
  });

  final String membershipId;
  final String storeId;
  final String storeName;
  final String role;

  Map<String, Object?> toJson() => {
        'membershipId': membershipId,
        'storeId': storeId,
        'storeName': storeName,
        'role': role,
      };
}

final class LoginTicket {
  const LoginTicket({
    required this.accountId,
    required this.token,
    required this.expiresAt,
    required this.memberships,
  });

  final String accountId;
  final String token;
  final DateTime expiresAt;
  final List<StoreMembership> memberships;
}

final class StoreSessionTokens {
  const StoreSessionTokens({
    required this.sessionId,
    required this.storeId,
    required this.role,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
  });

  final String sessionId;
  final String storeId;
  final String role;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'storeId': storeId,
        'role': role,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'accessExpiresAt': accessExpiresAt.toIso8601String(),
        'refreshExpiresAt': refreshExpiresAt.toIso8601String(),
      };
}

/// Control-plane persistence. This repository must be backed by the separate
/// control-plane database, never by a store's business database.
final class PostgresControlPlaneRepository {
  PostgresControlPlaneRepository(
    this._connection, {
    PasswordHasher? passwordHasher,
    Uuid? uuid,
  })  : _passwordHasher = passwordHasher ?? PasswordHasher(),
        _uuid = uuid ?? const Uuid();

  final PostgreSQLConnection _connection;
  final PasswordHasher _passwordHasher;
  final Uuid _uuid;

  Future<LoginTicket?> beginSignIn({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final rows = await _connection.mappedResultsQuery(
      '''SELECT account_id::text AS "accountId",
                password_hash AS "passwordHash", status
         FROM cp_accounts WHERE email_normalized = @email LIMIT 1''',
      substitutionValues: {'email': normalizedEmail},
    );
    if (rows.isEmpty) return null;
    final account = rows.single.values.first;
    if (account['status'] != 'ACTIVE' ||
        !_passwordHasher.verify(password, account['passwordHash'] as String)) {
      return null;
    }

    final accountId = account['accountId'] as String;
    final token = OpaqueSessionToken.generate();
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 10));
    await _connection.execute(
      '''INSERT INTO cp_login_sessions
           (login_session_id, account_id, token_hash, expires_at)
         VALUES (@id, @account, @tokenHash, @expiresAt)''',
      substitutionValues: {
        'id': _uuid.v4(),
        'account': accountId,
        'tokenHash': Uint8List.fromList(_hexBytes(token.hashHex)),
        'expiresAt': expiresAt,
      },
    );

    return LoginTicket(
      accountId: accountId,
      token: token.value,
      expiresAt: expiresAt,
      memberships: await listActiveMemberships(accountId),
    );
  }

  Future<List<StoreMembership>> listActiveMemberships(
      String accountId) async {
    final rows = await _connection.mappedResultsQuery(
      '''SELECT m.membership_id::text AS "membershipId",
                s.store_id::text AS "storeId",
                s.display_name AS "storeName",
                m.role
         FROM cp_memberships m
         JOIN cp_stores s ON s.store_id = m.store_id
         JOIN cp_accounts a ON a.account_id = m.account_id
         WHERE m.account_id = @account
           AND m.status = 'ACTIVE'
           AND s.status = 'ACTIVE'
           AND a.status = 'ACTIVE'
         ORDER BY s.display_name, s.store_id''',
      substitutionValues: {'account': accountId},
    );
    return rows.map((row) {
      final value = row.values.first;
      return StoreMembership(
        membershipId: value['membershipId'] as String,
        storeId: value['storeId'] as String,
        storeName: value['storeName'] as String,
        role: value['role'] as String,
      );
    }).toList(growable: false);
  }

  /// Exchanges a short-lived identity ticket for a store-bound session.
  /// The ticket is consumed before issuing the store session.
  Future<StoreSessionTokens?> activateStore({
    required String loginTicket,
    required String requestedStoreId,
  }) async {
    final digest = sha256.convert(utf8.encode(loginTicket)).bytes;
    final claimed = await _connection.mappedResultsQuery(
      '''UPDATE cp_login_sessions l
         SET revoked_at = now()
         FROM cp_accounts a
         WHERE l.account_id = a.account_id
           AND l.token_hash = @tokenHash
           AND l.revoked_at IS NULL
           AND l.expires_at > now()
           AND a.status = 'ACTIVE'
         RETURNING l.account_id::text AS "accountId"''',
      substitutionValues: {
        'tokenHash': Uint8List.fromList(digest),
      },
    );
    if (claimed.isEmpty) return null;
    final accountId = claimed.single.values.first['accountId'] as String;

    final memberships = await _connection.mappedResultsQuery(
      '''SELECT m.membership_id::text AS "membershipId",
                m.role
         FROM cp_memberships m
         JOIN cp_stores s ON s.store_id = m.store_id
         WHERE m.account_id = @account
           AND m.store_id = @store
           AND m.status = 'ACTIVE'
           AND s.status = 'ACTIVE'
         LIMIT 1''',
      substitutionValues: {
        'account': accountId,
        'store': requestedStoreId,
      },
    );
    if (memberships.isEmpty) return null;
    final membership = memberships.single.values.first;
    return _issueStoreSession(
      accountId: accountId,
      storeId: requestedStoreId,
      membershipId: membership['membershipId'] as String,
      role: membership['role'] as String,
    );
  }

  Future<StoreSessionTokens> _issueStoreSession({
    required String accountId,
    required String storeId,
    required String membershipId,
    required String role,
  }) async {
    final access = OpaqueSessionToken.generate();
    final refresh = OpaqueSessionToken.generate();
    final now = DateTime.now().toUtc();
    final accessExpiry = now.add(const Duration(minutes: 15));
    final refreshExpiry = now.add(const Duration(days: 30));
    final sessionId = _uuid.v4();

    await _connection.execute(
      '''INSERT INTO cp_sessions
           (session_id, account_id, store_id, membership_id,
            access_token_hash, refresh_token_hash, role_snapshot,
            issued_at, access_expires_at, refresh_expires_at)
         VALUES (@session, @account, @store, @membership,
                 @accessHash, @refreshHash, @role,
                 @issued, @accessExpiry, @refreshExpiry)''',
      substitutionValues: {
        'session': sessionId,
        'account': accountId,
        'store': storeId,
        'membership': membershipId,
        'accessHash': Uint8List.fromList(_hexBytes(access.hashHex)),
        'refreshHash': Uint8List.fromList(_hexBytes(refresh.hashHex)),
        'role': role,
        'issued': now,
        'accessExpiry': accessExpiry,
        'refreshExpiry': refreshExpiry,
      },
    );

    return StoreSessionTokens(
      sessionId: sessionId,
      storeId: storeId,
      role: role,
      accessToken: access.value,
      refreshToken: refresh.value,
      accessExpiresAt: accessExpiry,
      refreshExpiresAt: refreshExpiry,
    );
  }

  Future<StoreRequestContext?> resolveAccessToken(String rawToken) async {
    final digest = sha256.convert(utf8.encode(rawToken)).bytes;
    final rows = await _connection.mappedResultsQuery(
      '''SELECT s.session_id::text AS "sessionId",
                s.account_id::text AS "accountId",
                s.store_id::text AS "storeId",
                s.membership_id::text AS "membershipId",
                m.role
         FROM cp_sessions s
         JOIN cp_accounts a ON a.account_id = s.account_id
         JOIN cp_memberships m
           ON m.membership_id = s.membership_id
          AND m.account_id = s.account_id
          AND m.store_id = s.store_id
         JOIN cp_stores st ON st.store_id = s.store_id
         WHERE s.access_token_hash = @tokenHash
           AND s.revoked_at IS NULL
           AND s.access_expires_at > now()
           AND a.status = 'ACTIVE'
           AND m.status = 'ACTIVE'
           AND st.status = 'ACTIVE'
         LIMIT 1''',
      substitutionValues: {
        'tokenHash': Uint8List.fromList(digest),
      },
    );
    if (rows.isEmpty) return null;
    final row = rows.single.values.first;
    await _connection.execute(
      'UPDATE cp_sessions SET last_used_at = now() WHERE session_id = @id',
      substitutionValues: {'id': row['sessionId']},
    );
    return StoreRequestContext(
      accountId: row['accountId'] as String,
      storeId: row['storeId'] as String,
      membershipId: row['membershipId'] as String,
      sessionId: row['sessionId'] as String,
      role: row['role'] as String,
    );
  }

  Future<void> revokeSession({
    required String sessionId,
    required String accountId,
  }) async {
    await _connection.execute(
      '''UPDATE cp_sessions SET revoked_at = now()
         WHERE session_id = @session AND account_id = @account
           AND revoked_at IS NULL''',
      substitutionValues: {
        'session': sessionId,
        'account': accountId,
      },
    );
  }

  List<int> _hexBytes(String value) => List<int>.generate(
        value.length ~/ 2,
        (index) => int.parse(value.substring(index * 2, index * 2 + 2), radix: 16),
      );
}
