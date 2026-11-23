-- Migration 009: track cumulative purchase-order receiving without replacing
-- the existing purchase order schema. Safe additive change; existing orders
-- begin with zero received quantity and are not rewritten.
BEGIN;

DO $$
BEGIN
  IF to_regclass('public.purchase_order_items') IS NULL THEN
    RAISE EXCEPTION 'Migration 009 requires migration 007 purchase_order_items';
  END IF;
END $$;

ALTER TABLE purchase_order_items
  ADD COLUMN IF NOT EXISTS qty_received NUMERIC(20,4) NOT NULL DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'purchase_order_items_received_range_check'
      AND conrelid = 'public.purchase_order_items'::regclass
  ) THEN
    ALTER TABLE purchase_order_items
      ADD CONSTRAINT purchase_order_items_received_range_check
      CHECK (qty_received >= 0 AND qty_received <= qty_ordered);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_purchase_order_items_receiving
  ON purchase_order_items(branch_id, purchase_order_id, product_id, unit_id);

COMMIT;
