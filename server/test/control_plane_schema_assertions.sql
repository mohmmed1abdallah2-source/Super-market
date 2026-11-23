-- Disposable control-plane database schema assertions.
-- Run only in CI/test: psql ... -f server/test/control_plane_schema_assertions.sql
BEGIN;

INSERT INTO cp_accounts (account_id, email_normalized, display_name, password_hash)
VALUES
 ('10000000-0000-4000-8000-000000000001', 'owner@example.test', 'Owner', 'test-only-hash'),
 ('10000000-0000-4000-8000-000000000002', 'member@example.test', 'Member', 'test-only-hash');

INSERT INTO cp_stores
 (store_id, display_name, database_name, database_role, database_secret_ref, created_by_account_id)
VALUES
 ('20000000-0000-4000-8000-000000000001', 'Store A',
  'store_20000000000040008000000000000001', 'store_20000000000040008000000000000001',
  'test-secret://store-a', '10000000-0000-4000-8000-000000000001'),
 ('20000000-0000-4000-8000-000000000002', 'Store B',
  'store_20000000000040008000000000000002', 'store_20000000000040008000000000000002',
  'test-secret://store-b', '10000000-0000-4000-8000-000000000001');

INSERT INTO cp_memberships
 (membership_id, account_id, store_id, role)
VALUES
 ('30000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001', 'OWNER'),
 ('30000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002', 'OWNER'),
 ('30000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000002',
  '20000000-0000-4000-8000-000000000001', 'CASHIER');

INSERT INTO cp_login_sessions
 (login_session_id, account_id, token_hash, expires_at)
VALUES
 ('50000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  decode(repeat('55', 32), 'hex'), now() + interval '10 minutes');

INSERT INTO cp_sessions
 (session_id, account_id, store_id, membership_id, access_token_hash, refresh_token_hash,
  role_snapshot, access_expires_at, refresh_expires_at)
VALUES
 ('40000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000002',
  decode(repeat('11', 32), 'hex'), decode(repeat('22', 32), 'hex'), 'OWNER',
  now() + interval '15 minutes', now() + interval '30 days');

DO $$
BEGIN
  IF (SELECT count(*) FROM cp_memberships
      WHERE account_id = '10000000-0000-4000-8000-000000000001'
        AND status = 'ACTIVE') <> 2 THEN
    RAISE EXCEPTION 'owner-to-many-stores membership assertion failed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM cp_login_sessions
    WHERE account_id = '10000000-0000-4000-8000-000000000001'
      AND revoked_at IS NULL AND expires_at > now()
  ) THEN
    RAISE EXCEPTION 'short-lived identity session assertion failed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM cp_sessions s
    JOIN cp_memberships m
      ON m.membership_id = s.membership_id
     AND m.account_id = s.account_id
     AND m.store_id = s.store_id
    WHERE s.session_id = '40000000-0000-4000-8000-000000000001'
  ) THEN
    RAISE EXCEPTION 'session membership binding assertion failed';
  END IF;

  BEGIN
    INSERT INTO cp_sessions
      (session_id, account_id, store_id, membership_id, access_token_hash,
       refresh_token_hash, role_snapshot, access_expires_at, refresh_expires_at)
    VALUES
      ('40000000-0000-4000-8000-000000000002',
       '10000000-0000-4000-8000-000000000002',
       '20000000-0000-4000-8000-000000000002',
       '30000000-0000-4000-8000-000000000003',
       decode(repeat('33', 32), 'hex'), decode(repeat('44', 32), 'hex'),
       'CASHIER', now() + interval '15 minutes', now() + interval '30 days');
    RAISE EXCEPTION 'cross-account/store session binding unexpectedly succeeded';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END $$;

ROLLBACK;
