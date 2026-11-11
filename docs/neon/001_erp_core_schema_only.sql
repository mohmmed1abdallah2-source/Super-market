-- Iteration 1 PostgreSQL foundation required by Iteration 2 migration 002.
-- This migration mirrors the stable identifiers and product catalogue fixtures
-- used by the current offline-first Flutter application.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS branches (
  id TEXT PRIMARY KEY,
  code VARCHAR(40) NOT NULL UNIQUE,
  name_ar VARCHAR(160) NOT NULL,
  address TEXT NOT NULL DEFAULT '',
  phone VARCHAR(40) NOT NULL DEFAULT '',
  tax_no VARCHAR(80) NOT NULL DEFAULT '',
  is_main BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  branch_id TEXT NOT NULL REFERENCES branches(id),
  username VARCHAR(80) NOT NULL UNIQUE,
  full_name VARCHAR(160) NOT NULL,
  role_code VARCHAR(24) NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
  id TEXT PRIMARY KEY,
  branch_id TEXT NOT NULL REFERENCES branches(id),
  sku_code VARCHAR(80) NOT NULL,
  name_ar VARCHAR(200) NOT NULL,
  name_en VARCHAR(200),
  product_type VARCHAR(24) NOT NULL DEFAULT 'STANDARD'
    CHECK (product_type IN ('STANDARD', 'WEIGHTED_SCALE', 'SERVICE')),
  scale_plu_code VARCHAR(12),
  base_unit_name VARCHAR(80) NOT NULL,
  stock_base_qty NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (stock_base_qty >= 0),
  avg_cost_base_unit NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (avg_cost_base_unit >= 0),
  last_cost_base_unit NUMERIC(20,6) NOT NULL DEFAULT 0 CHECK (last_cost_base_unit >= 0),
  min_stock_alert_qty NUMERIC(20,6) NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, sku_code)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_products_branch_scale_plu
  ON products(branch_id, scale_plu_code)
  WHERE scale_plu_code IS NOT NULL;

CREATE TABLE IF NOT EXISTS product_units_barcodes (
  id TEXT PRIMARY KEY,
  branch_id TEXT NOT NULL REFERENCES branches(id),
  product_id TEXT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  unit_name VARCHAR(100) NOT NULL,
  conversion_factor NUMERIC(20,6) NOT NULL CHECK (conversion_factor > 0),
  barcode VARCHAR(64) UNIQUE,
  cost_price NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (cost_price >= 0),
  retail_price NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (retail_price >= 0),
  wholesale_price NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (wholesale_price >= 0),
  min_sell_price NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (min_sell_price >= 0),
  is_default_pos_unit BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS number_sequences (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  doc_type VARCHAR(32) NOT NULL,
  prefix VARCHAR(12) NOT NULL DEFAULT '',
  year INTEGER NOT NULL,
  last_no BIGINT NOT NULL DEFAULT 0,
  pad_length INTEGER NOT NULL DEFAULT 6,
  UNIQUE (branch_id, doc_type, year)
);

CREATE TABLE IF NOT EXISTS stock_movements (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  product_id TEXT NOT NULL REFERENCES products(id),
  movement_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  movement_type VARCHAR(32) NOT NULL,
  quantity_base NUMERIC(20,6) NOT NULL,
  unit_cost_base NUMERIC(20,6) NOT NULL DEFAULT 0,
  doc_type VARCHAR(32) NOT NULL,
  doc_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Production schema-only variant: development seed rows intentionally omitted.

COMMIT;
