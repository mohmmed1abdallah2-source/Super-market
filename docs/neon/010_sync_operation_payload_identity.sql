-- Add payload identity to sync receipts so an operation UUID cannot
-- silently acknowledge a different payload on a later batch.
BEGIN;

ALTER TABLE sync_operation_receipts
  ADD COLUMN IF NOT EXISTS payload_hash CHAR(64);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'sync_operation_receipts_payload_hash_format'
      AND conrelid = 'sync_operation_receipts'::regclass
  ) THEN
    ALTER TABLE sync_operation_receipts
      ADD CONSTRAINT sync_operation_receipts_payload_hash_format
      CHECK (payload_hash IS NULL OR payload_hash ~ '^[0-9a-f]{64}$');
  END IF;
END $$;

COMMENT ON COLUMN sync_operation_receipts.payload_hash IS
  'SHA-256 of canonical JSON operation payload; NULL only for receipts created before migration 010.';

COMMIT;
