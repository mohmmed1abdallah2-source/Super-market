-- Iteration 3 / Migration 007: FEFO inventory, warehouses and purchases.
-- PostgreSQL 18.6 / Neon. Prerequisites: migrations 001-004.
-- Additive only: no existing business rows or tables are dropped.
-- IMPORTANT: stock_movements already exists from 001. This migration extends it;
-- it does not create a parallel movement ledger.
BEGIN;

DO $$
BEGIN
  IF current_setting('server_version_num')::integer < 180000 THEN
    RAISE EXCEPTION 'Migration 007 requires PostgreSQL 18 or newer';
  END IF;
  IF to_regclass('public.branches') IS NULL
     OR to_regclass('public.products') IS NULL
     OR to_regclass('public.stock_movements') IS NULL
     OR to_regclass('public.parties') IS NULL
     OR to_regclass('public.sales_invoice_items') IS NULL THEN
    RAISE EXCEPTION 'Migration 007 requires migrations 001-003';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS warehouses (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  code VARCHAR(40) NOT NULL,
  name_ar VARCHAR(160) NOT NULL,
  warehouse_type VARCHAR(24) NOT NULL DEFAULT 'BACKROOM'
    CHECK (warehouse_type IN ('BACKROOM','SALES_FLOOR','COLD_STORAGE','OTHER')),
  is_sellable BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, code)
);

CREATE TABLE IF NOT EXISTS aisle_shelf_locations (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  warehouse_id TEXT NOT NULL,
  code VARCHAR(60) NOT NULL,
  name_ar VARCHAR(160) NOT NULL,
  location_type VARCHAR(24) NOT NULL DEFAULT 'SHELF'
    CHECK (location_type IN ('AISLE','SHELF','FRIDGE','FREEZER','DISPLAY','OTHER')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, warehouse_id, code),
  FOREIGN KEY (warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS fridge_temp_logs (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  warehouse_id TEXT NOT NULL,
  location_id TEXT,
  temperature_c NUMERIC(8,2) NOT NULL,
  measured_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  recorded_by_user_id TEXT,
  note TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (location_id, branch_id)
    REFERENCES aisle_shelf_locations(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (recorded_by_user_id, branch_id)
    REFERENCES users(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS purchase_orders (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  order_no VARCHAR(64) NOT NULL,
  supplier_party_id TEXT NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','APPROVED','PARTIALLY_RECEIVED','RECEIVED','CANCELLED')),
  order_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  expected_date DATE,
  notes TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, order_no),
  FOREIGN KEY (supplier_party_id, branch_id)
    REFERENCES parties(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS purchase_order_items (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  purchase_order_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  unit_id TEXT,
  qty_ordered NUMERIC(20,4) NOT NULL CHECK (qty_ordered > 0),
  conversion_factor NUMERIC(20,6) NOT NULL CHECK (conversion_factor > 0),
  expected_unit_price NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (expected_unit_price >= 0),
  notes TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (purchase_order_id, branch_id)
    REFERENCES purchase_orders(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_id, branch_id)
    REFERENCES products(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (unit_id, branch_id)
    REFERENCES product_units_barcodes(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS purchase_invoices (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  invoice_no VARCHAR(64) NOT NULL,
  supplier_invoice_no VARCHAR(100),
  supplier_party_id TEXT NOT NULL,
  warehouse_id TEXT NOT NULL,
  purchase_order_id TEXT,
  invoice_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  status VARCHAR(16) NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','POSTED','VOIDED','RETURNED')),
  subtotal NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  net_total NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (net_total >= 0),
  paid_total NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (paid_total >= 0),
  journal_entry_id TEXT,
  operation_id TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, invoice_no),
  UNIQUE (branch_id, operation_id),
  FOREIGN KEY (supplier_party_id, branch_id)
    REFERENCES parties(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (purchase_order_id, branch_id)
    REFERENCES purchase_orders(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (journal_entry_id, branch_id)
    REFERENCES journal_entries(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS purchase_invoice_items (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  purchase_invoice_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  unit_id TEXT,
  qty_paid NUMERIC(20,4) NOT NULL CHECK (qty_paid > 0),
  bonus_qty NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (bonus_qty >= 0),
  conversion_factor NUMERIC(20,6) NOT NULL CHECK (conversion_factor > 0),
  purchase_unit_price NUMERIC(20,4) NOT NULL CHECK (purchase_unit_price >= 0),
  line_discount_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (line_discount_amount >= 0),
  line_total NUMERIC(20,4) NOT NULL CHECK (line_total >= 0),
  total_base_units_added NUMERIC(20,6) NOT NULL CHECK (total_base_units_added > 0),
  effective_pack_cost NUMERIC(20,4) NOT NULL CHECK (effective_pack_cost >= 0),
  effective_base_cost NUMERIC(20,6) NOT NULL CHECK (effective_base_cost >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (purchase_invoice_id, branch_id)
    REFERENCES purchase_invoices(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_id, branch_id)
    REFERENCES products(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (unit_id, branch_id)
    REFERENCES product_units_barcodes(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS product_batches_fefo (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  product_id TEXT NOT NULL,
  warehouse_id TEXT NOT NULL,
  location_id TEXT,
  purchase_invoice_item_id TEXT,
  batch_no VARCHAR(100) NOT NULL,
  expiry_date DATE NOT NULL,
  pack_conversion_factor NUMERIC(20,6) NOT NULL CHECK (pack_conversion_factor > 0),
  sealed_cartons INTEGER NOT NULL DEFAULT 0 CHECK (sealed_cartons >= 0),
  loose_base_qty NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (loose_base_qty >= 0),
  total_base_qty NUMERIC(20,6) GENERATED ALWAYS AS
    ((sealed_cartons::NUMERIC * pack_conversion_factor) + loose_base_qty) STORED,
  status VARCHAR(16) NOT NULL DEFAULT 'ACTIVE'
    CHECK (status IN ('ACTIVE','HOLD','EXPIRED','DEPLETED')),
  unit_cost_base NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (unit_cost_base >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, product_id, warehouse_id, batch_no),
  FOREIGN KEY (product_id, branch_id)
    REFERENCES products(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (location_id, branch_id)
    REFERENCES aisle_shelf_locations(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (purchase_invoice_item_id, branch_id)
    REFERENCES purchase_invoice_items(id, branch_id) ON DELETE RESTRICT
);

-- Preserve the existing stock movement ledger from migration 001 and extend it.
ALTER TABLE stock_movements
  ADD COLUMN IF NOT EXISTS warehouse_id TEXT,
  ADD COLUMN IF NOT EXISTS product_batch_id TEXT,
  ADD COLUMN IF NOT EXISTS reference_no VARCHAR(100),
  ADD COLUMN IF NOT EXISTS notes TEXT NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS sales_invoice_item_batches (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  sales_invoice_item_id TEXT NOT NULL,
  product_batch_id TEXT NOT NULL,
  qty_base NUMERIC(20,6) NOT NULL CHECK (qty_base > 0),
  cartons_opened INTEGER NOT NULL DEFAULT 0 CHECK (cartons_opened >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (sales_invoice_item_id, branch_id)
    REFERENCES sales_invoice_items(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_batch_id, branch_id)
    REFERENCES product_batches_fefo(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS stocktaking_sessions (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  warehouse_id TEXT NOT NULL,
  session_no VARCHAR(64) NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','COUNTING','APPROVED','CANCELLED')),
  blind_count BOOLEAN NOT NULL DEFAULT TRUE,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  approved_at TIMESTAMPTZ,
  approved_by_user_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, session_no),
  FOREIGN KEY (warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (approved_by_user_id, branch_id)
    REFERENCES users(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS stocktaking_lines (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  session_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  product_batch_id TEXT,
  expected_base_qty NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (expected_base_qty >= 0),
  counted_sealed_cartons INTEGER NOT NULL DEFAULT 0 CHECK (counted_sealed_cartons >= 0),
  counted_loose_base_qty NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (counted_loose_base_qty >= 0),
  pack_conversion_factor NUMERIC(20,6) NOT NULL CHECK (pack_conversion_factor > 0),
  counted_base_qty NUMERIC(20,6) GENERATED ALWAYS AS
    ((counted_sealed_cartons::NUMERIC * pack_conversion_factor) + counted_loose_base_qty) STORED,
  variance_base_qty NUMERIC(20,6) GENERATED ALWAYS AS
    (((counted_sealed_cartons::NUMERIC * pack_conversion_factor) + counted_loose_base_qty) - expected_base_qty) STORED,
  counted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (session_id, branch_id)
    REFERENCES stocktaking_sessions(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_id, branch_id)
    REFERENCES products(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_batch_id, branch_id)
    REFERENCES product_batches_fefo(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS disposals (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  warehouse_id TEXT NOT NULL,
  disposal_no VARCHAR(64) NOT NULL,
  reason VARCHAR(24) NOT NULL CHECK (reason IN ('EXPIRED','DAMAGED','CONTAMINATED','OTHER')),
  status VARCHAR(16) NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','APPROVED','CANCELLED')),
  disposal_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_by_user_id TEXT,
  notes TEXT NOT NULL DEFAULT '',
  journal_entry_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, disposal_no),
  FOREIGN KEY (warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (approved_by_user_id, branch_id)
    REFERENCES users(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (journal_entry_id, branch_id)
    REFERENCES journal_entries(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS disposal_items (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  disposal_id TEXT NOT NULL,
  product_batch_id TEXT NOT NULL,
  qty_base NUMERIC(20,6) NOT NULL CHECK (qty_base > 0),
  unit_cost_base NUMERIC(20,6) NOT NULL CHECK (unit_cost_base >= 0),
  reason_note TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (disposal_id, branch_id)
    REFERENCES disposals(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_batch_id, branch_id)
    REFERENCES product_batches_fefo(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS stock_transfers (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  transfer_no VARCHAR(64) NOT NULL,
  source_warehouse_id TEXT NOT NULL,
  destination_warehouse_id TEXT NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','APPROVED','IN_TRANSIT','RECEIVED','CANCELLED')),
  transfer_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  notes TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, transfer_no),
  CHECK (source_warehouse_id <> destination_warehouse_id),
  FOREIGN KEY (source_warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (destination_warehouse_id, branch_id)
    REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS stock_transfer_items (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  transfer_id TEXT NOT NULL,
  product_batch_id TEXT NOT NULL,
  qty_base NUMERIC(20,6) NOT NULL CHECK (qty_base > 0),
  cartons_moved INTEGER NOT NULL DEFAULT 0 CHECK (cartons_moved >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (transfer_id, branch_id)
    REFERENCES stock_transfers(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_batch_id, branch_id)
    REFERENCES product_batches_fefo(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS purchase_returns (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  return_no VARCHAR(64) NOT NULL,
  purchase_invoice_id TEXT NOT NULL,
  supplier_party_id TEXT NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','POSTED','CANCELLED')),
  return_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  net_total NUMERIC(20,4) NOT NULL CHECK (net_total >= 0),
  journal_entry_id TEXT,
  operation_id TEXT NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  UNIQUE (branch_id, return_no),
  UNIQUE (branch_id, operation_id),
  FOREIGN KEY (purchase_invoice_id, branch_id)
    REFERENCES purchase_invoices(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (supplier_party_id, branch_id)
    REFERENCES parties(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (journal_entry_id, branch_id)
    REFERENCES journal_entries(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS purchase_return_items (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  purchase_return_id TEXT NOT NULL,
  purchase_invoice_item_id TEXT NOT NULL,
  product_batch_id TEXT NOT NULL,
  qty_base NUMERIC(20,6) NOT NULL CHECK (qty_base > 0),
  line_total NUMERIC(20,4) NOT NULL CHECK (line_total >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (purchase_return_id, branch_id)
    REFERENCES purchase_returns(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (purchase_invoice_item_id, branch_id)
    REFERENCES purchase_invoice_items(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (product_batch_id, branch_id)
    REFERENCES product_batches_fefo(id, branch_id) ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS price_cost_history (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id) ON DELETE RESTRICT,
  product_id TEXT NOT NULL,
  unit_id TEXT,
  source_type VARCHAR(24) NOT NULL
    CHECK (source_type IN ('PURCHASE','PURCHASE_RETURN','MANUAL_ADJUSTMENT','OPENING')),
  source_id TEXT NOT NULL,
  old_cost_base NUMERIC(20,6) NOT NULL CHECK (old_cost_base >= 0),
  new_cost_base NUMERIC(20,6) NOT NULL CHECK (new_cost_base >= 0),
  effective_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, id),
  UNIQUE (id, branch_id),
  FOREIGN KEY (product_id, branch_id)
    REFERENCES products(id, branch_id) ON DELETE RESTRICT,
  FOREIGN KEY (unit_id, branch_id)
    REFERENCES product_units_barcodes(id, branch_id) ON DELETE RESTRICT
);

-- Composite parent keys and constraints for the existing movement ledger.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sales_invoice_items_id_branch_key') THEN
    ALTER TABLE sales_invoice_items ADD CONSTRAINT sales_invoice_items_id_branch_key UNIQUE (id, branch_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_id_branch_key') THEN
    ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_id_branch_key UNIQUE (id, branch_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_warehouse_branch_fkey') THEN
    ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_warehouse_branch_fkey
      FOREIGN KEY (warehouse_id, branch_id) REFERENCES warehouses(id, branch_id) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_batch_branch_fkey') THEN
    ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_batch_branch_fkey
      FOREIGN KEY (product_batch_id, branch_id) REFERENCES product_batches_fefo(id, branch_id) ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_batches_fefo_lookup
  ON product_batches_fefo(branch_id, product_id, status, expiry_date, created_at, id);
CREATE INDEX IF NOT EXISTS idx_batches_warehouse
  ON product_batches_fefo(branch_id, warehouse_id, product_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_branch_product_date
  ON stock_movements(branch_id, product_id, movement_date DESC);
CREATE INDEX IF NOT EXISTS idx_purchase_invoices_supplier_date
  ON purchase_invoices(branch_id, supplier_party_id, invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_fridge_temp_location_date
  ON fridge_temp_logs(branch_id, location_id, measured_at DESC);

-- Stock movements are an append-only audit ledger. Corrections must be new
-- compensating movements; existing rows are never edited or deleted.
CREATE OR REPLACE FUNCTION reject_stock_movement_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'stock_movements is append-only; create a compensating movement'
    USING ERRCODE = '55000';
END $$;

DROP TRIGGER IF EXISTS trg_stock_movements_append_only ON stock_movements;
CREATE TRIGGER trg_stock_movements_append_only
BEFORE UPDATE OR DELETE ON stock_movements
FOR EACH ROW EXECUTE FUNCTION reject_stock_movement_mutation();

COMMIT;
