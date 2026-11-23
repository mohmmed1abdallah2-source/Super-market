-- Rollback-only control-plane schema assertions for disposable PostgreSQL.
BEGIN;

DO $$
DECLARE
  account_a UUID := '10000000-0000-4000-8000-000000000001';
  account_b UUID := '10000000-0000-4000-8000-000000000002';
  store_a UUID := '20000000-0000-4000-8000-000000000001';
  membership_a UUID := '30000000-0000-4000-8000-000000000001';
BEGIN
  INSERT INTO cp_accounts(id, primary_email) VALUES
    (account_a, 'owner-a@example.test'),
    (account_b, 'owner-b@example.test');
  INSERT INTO cp_account_identities(
    id, account_id, provider, provider_subject, email, email_verified
  ) VALUES (
    '40000000-0000-4000-8000-000000000001',
    account_a, 'oidc', 'issuer|subject-a', 'owner-a@example.test', TRUE
  );
  INSERT INTO cp_stores(id, display_name, status, created_by_account_id)
    VALUES (store_a, 'Store A', 'ACTIVE', account_a);
  INSERT INTO cp_store_memberships(id, account_id, store_id, role, status)
    VALUES (membership_a, account_a, store_a, 'OWNER', 'ACTIVE');
  INSERT INTO cp_store_database_bindings(store_id, database_key, status)
    VALUES (store_a, 'secret-manager://stores/store-a', 'READY');
  INSERT INTO cp_sessions(
    id, account_id, active_store_id, active_membership_id,
    access_token_hash, expires_at
  ) VALUES (
    '50000000-0000-4000-8000-000000000001',
    account_a, store_a, membership_a, repeat('a', 64), now() + interval '5 minutes'
  );

  IF (SELECT count(*) FROM cp_store_memberships
      WHERE account_id = account_a AND status = 'ACTIVE') <> 1 THEN
    RAISE EXCEPTION 'active membership lookup assertion failed';
  END IF;
  IF (SELECT count(*) FROM cp_store_database_bindings
      WHERE store_id = store_a AND database_key = 'secret-manager://stores/store-a') <> 1 THEN
    RAISE EXCEPTION 'opaque database reference assertion failed';
  END IF;

  BEGIN
    INSERT INTO cp_sessions(
      id, account_id, active_store_id, active_membership_id,
      access_token_hash, expires_at
    ) VALUES (
      '50000000-0000-4000-8000-000000000002',
      account_b, store_a, membership_a, repeat('b', 64), now() + interval '5 minutes'
    );
    RAISE EXCEPTION 'cross-account membership session unexpectedly succeeded';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO cp_account_identities(
      id, account_id, provider, provider_subject, email, email_verified
    ) VALUES (
      '40000000-0000-4000-8000-000000000002',
      account_b, 'oidc', 'issuer|subject-a', 'other@example.test', TRUE
    );
    RAISE EXCEPTION 'duplicate external identity unexpectedly succeeded';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END $$;

ROLLBACK;
