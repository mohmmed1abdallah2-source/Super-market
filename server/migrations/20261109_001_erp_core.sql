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

INSERT INTO branches (id, code, name_ar, is_main)
VALUES ('branch-main', 'MAIN', 'الفرع الرئيسي', TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, branch_id, username, full_name, role_code, is_active)
VALUES ('user-owner', 'branch-main', 'admin', 'مدير النظام', 'OWNER', TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO products
  (id, branch_id, sku_code, name_ar, product_type, scale_plu_code,
   base_unit_name, stock_base_qty, avg_cost_base_unit, last_cost_base_unit, min_stock_alert_qty)
VALUES
  ('p-rice', 'branch-main', '1001', 'أرز بسمتي', 'STANDARD', NULL, 'جرام', 500000, 0, 0, 5),
  ('p-milk', 'branch-main', '1002', 'حليب سائل', 'STANDARD', NULL, 'حبة', 240, 0, 0, 5),
  ('p-oil', 'branch-main', '1003', 'زيت طبخ', 'STANDARD', NULL, 'ملليلتر', 120000, 0, 0, 5),
  ('p-sugar', 'branch-main', '1004', 'سكر', 'STANDARD', NULL, 'جرام', 200000, 0, 0, 5),
  ('p-flour', 'branch-main', '1005', 'دقيق', 'STANDARD', NULL, 'جرام', 300000, 0, 0, 5),
  ('p-tea', 'branch-main', '1006', 'شاي', 'STANDARD', NULL, 'جرام', 50000, 0, 0, 5),
  ('p-cheese', 'branch-main', '1007', 'جبن رومي موزون', 'WEIGHTED_SCALE', '1025', 'جرام', 25000, 0, 0, 5),
  ('p-water', 'branch-main', '1008', 'مياه شرب', 'STANDARD', NULL, 'حبة', 300, 0, 0, 5)
ON CONFLICT (id) DO NOTHING;

INSERT INTO product_units_barcodes
  (id, branch_id, product_id, unit_name, conversion_factor, barcode,
   cost_price, retail_price, wholesale_price, min_sell_price, is_default_pos_unit)
VALUES
  ('u-rice-sack', 'branch-main', 'p-rice', 'شوال 10 كيلو', 10000, '6281000001001', 4500, 5500, 5100, 5500, FALSE),
  ('u-milk-piece', 'branch-main', 'p-milk', 'حبة', 1, '6281000001002', 250, 300, 275, 300, TRUE),
  ('u-milk-pack', 'branch-main', 'p-milk', 'باكت 6', 6, '6281000001102', 1450, 1700, 1550, 1700, FALSE),
  ('u-milk-carton', 'branch-main', 'p-milk', 'كرتون 24', 24, '6281000001202', 5700, 6600, 6200, 6600, FALSE),
  ('u-oil-bottle', 'branch-main', 'p-oil', 'قارورة لتر', 1000, '6281000001003', 800, 1000, 900, 1000, FALSE),
  ('u-sugar-kg', 'branch-main', 'p-sugar', 'كيلو', 1000, '6281000001004', 500, 650, 580, 650, FALSE),
  ('u-flour-kg', 'branch-main', 'p-flour', 'كيلو', 1000, '6281000001005', 400, 550, 490, 550, FALSE),
  ('u-tea-pack', 'branch-main', 'p-tea', 'علبة', 100, '6281000001006', 600, 750, 680, 750, FALSE),
  ('u-cheese-kg', 'branch-main', 'p-cheese', 'كيلو', 1000, NULL, 3000, 3800, 3500, 3800, TRUE),
  ('u-water-piece', 'branch-main', 'p-water', 'حبة', 1, '6281000001008', 80, 100, 90, 100, FALSE)
ON CONFLICT (id) DO NOTHING;

COMMIT;
