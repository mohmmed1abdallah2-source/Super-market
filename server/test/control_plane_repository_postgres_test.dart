import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../lib/features/control_plane/data/postgres_control_plane_repository.dart';
import '../lib/features/control_plane/domain/control_plane_security.dart';

void main() {
  final environment = Platform.environment;
  final enabled = environment['CONTROL_PLANE_TEST_HOST'] != null;

  test('control-plane sign-in, store activation, membership and revocation', () async {
    if (!enabled) return;
    final connection = PostgreSQLConnection(
      environment['CONTROL_PLANE_TEST_HOST']!,
      int.tryParse(environment['CONTROL_PLANE_TEST_PORT'] ?? '5432') ?? 5432,
      environment['CONTROL_PLANE_TEST_DATABASE']!,
      username: environment['CONTROL_PLANE_TEST_USER']!,
      password: environment['CONTROL_PLANE_TEST_PASSWORD']!,
      timeoutInSeconds: 30,
    );
    await connection.open();
    try {
      const uuid = Uuid();
      final accountId = uuid.v4();
      final storeId = uuid.v4();
      final membershipId = uuid.v4();
      final otherStoreId = uuid.v4();
      final suffix = accountId.substring(0, 8);
      final hasher = PasswordHasher(iterations: 100000);
      await connection.execute(
        '''INSERT INTO cp_accounts
             (account_id, email_normalized, display_name, password_hash)
           VALUES (@id, @email, 'Integration owner', @hash)''',
        substitutionValues: {
          'id': accountId,
          'email': 'owner-$suffix@example.test',
          'hash': hasher.hash('correct horse battery staple'),
        },
      );
      await connection.execute(
        '''INSERT INTO cp_stores
             (store_id, display_name, database_name, database_role,
              database_secret_ref, status, created_by_account_id)
           VALUES (@store, 'Integration Store',
                   @database, @role, @secret, 'ACTIVE', @account)''',
        substitutionValues: {
          'store': storeId,
          'database': 'store_${storeId.replaceAll('-', '')}',
          'role': 'store_${storeId.replaceAll('-', '')}',
          'secret': 'test://store/$storeId',
          'account': accountId,
        },
      );
      await connection.execute(
        '''INSERT INTO cp_stores
             (store_id, display_name, database_name, database_role,
              database_secret_ref, status, created_by_account_id)
           VALUES (@store, 'Unrelated Store',
                   @database, @role, @secret, 'ACTIVE', @account)''',
        substitutionValues: {
          'store': otherStoreId,
          'database': 'store_${otherStoreId.replaceAll('-', '')}',
          'role': 'store_${otherStoreId.replaceAll('-', '')}',
          'secret': 'test://store/$otherStoreId',
          'account': accountId,
        },
      );
      await connection.execute(
        '''INSERT INTO cp_memberships
             (membership_id, account_id, store_id, role)
           VALUES (@membership, @account, @store, 'OWNER')''',
        substitutionValues: {
          'membership': membershipId,
          'account': accountId,
          'store': storeId,
        },
      );

      final repository = PostgresControlPlaneRepository(
        connection,
        passwordHasher: hasher,
      );
      expect(
        await repository.beginSignIn(
          email: 'OWNER-$suffix@EXAMPLE.TEST',
          password: 'incorrect password',
        ),
        isNull,
      );

      final ticket = await repository.beginSignIn(
        email: 'OWNER-$suffix@EXAMPLE.TEST',
        password: 'correct horse battery staple',
      );
      expect(ticket, isNotNull);
      expect(ticket!.memberships.map((item) => item.storeId), [storeId]);

      final denied = await repository.activateStore(
        loginTicket: ticket.token,
        requestedStoreId: otherStoreId,
      );
      expect(denied, isNull); // Ticket is one-time and cannot cross membership.

      final secondTicket = await repository.beginSignIn(
        email: 'owner-$suffix@example.test',
        password: 'correct horse battery staple',
      );
      expect(secondTicket, isNotNull);
      final session = await repository.activateStore(
        loginTicket: secondTicket!.token,
        requestedStoreId: storeId,
      );
      expect(session, isNotNull);

      final context = await repository.resolveAccessToken(session!.accessToken);
      expect(context?.accountId, accountId);
      expect(context?.storeId, storeId);
      expect(context?.membershipId, membershipId);

      await repository.revokeSession(
        sessionId: session.sessionId,
        accountId: accountId,
      );
      expect(await repository.resolveAccessToken(session.accessToken), isNull);
    } finally {
      await connection.close();
    }
  }, skip: !enabled);
}
