-- Control-plane migration 004: branch identifiers are scoped to a store.
-- Separate tenant databases may legitimately reuse local branch IDs.
BEGIN;

ALTER TABLE cp_store_branches
  DROP CONSTRAINT IF EXISTS cp_store_branches_branch_id_key;

CREATE INDEX IF NOT EXISTS cp_store_branches_branch_idx
  ON cp_store_branches(branch_id);

COMMIT;
