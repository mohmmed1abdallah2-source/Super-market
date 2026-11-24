-- Control-plane migration 002: enforce a single active owner and support
-- deterministic membership administration. Apply after migration 001 only.
BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS cp_one_active_owner_per_store_uq
  ON cp_store_memberships(store_id)
  WHERE role = 'OWNER' AND status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS cp_memberships_invitation_lookup_idx
  ON cp_store_memberships(account_id, store_id)
  WHERE status = 'INVITED';

COMMIT;
