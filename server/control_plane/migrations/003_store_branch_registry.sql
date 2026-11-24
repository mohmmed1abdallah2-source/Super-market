-- Control-plane migration 003: trusted mapping of operational branches to stores.
-- A branch is authorized only after a trusted provisioning workflow registers it.
-- Never populate this table from client-supplied store/branch headers.
BEGIN;

CREATE TABLE IF NOT EXISTS cp_store_branches (
  store_id UUID NOT NULL REFERENCES cp_stores(id) ON DELETE RESTRICT,
  branch_id TEXT NOT NULL CHECK (length(btrim(branch_id)) BETWEEN 1 AND 160),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, branch_id),
);

CREATE INDEX IF NOT EXISTS cp_store_branches_branch_idx
  ON cp_store_branches(branch_id, store_id);

COMMIT;
