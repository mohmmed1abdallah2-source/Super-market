-- Iteration 2 PostgreSQL migration.
-- Prerequisite: Iteration 1 PostgreSQL migration must have created branches(id)
-- and products(id, stock_base_qty). This migration is additive and does not edit it.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF to_regclass('public.branches') IS NULL THEN
    RAISE EXCEPTION 'Iteration 2 requires Iteration 1 table public.branches';
  END IF;
  IF to_regclass('public.products') IS NULL THEN
    RAISE EXCEPTION 'Iteration 2 requires Iteration 1 table public.products';
  END IF;
END
$$;

CREATE TABLE IF NOT EXISTS chart_of_accounts (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  code VARCHAR(40) NOT NULL,
  name_ar VARCHAR(160) NOT NULL,
  account_type VARCHAR(24) NOT NULL CHECK (account_type IN
    ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE')),
  parent_id TEXT REFERENCES chart_of_accounts(id),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, code)
);

CREATE TABLE IF NOT EXISTS journal_entries (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  entry_no VARCHAR(64) NOT NULL,
  entry_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  doc_type VARCHAR(32) NOT NULL,
  doc_id TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  status VARCHAR(16) NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT', 'POSTED', 'REVERSED')),
  posted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, entry_no),
  UNIQUE (branch_id, doc_type, doc_id)
);

CREATE TABLE IF NOT EXISTS journal_lines (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  journal_entry_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE RESTRICT,
  gl_account_id TEXT NOT NULL REFERENCES chart_of_accounts(id) ON DELETE RESTRICT,
  dr_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (dr_amount >= 0),
  cr_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (cr_amount >= 0),
  memo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((dr_amount > 0) <> (cr_amount > 0))
);

CREATE INDEX IF NOT EXISTS idx_journal_lines_entry ON journal_lines(journal_entry_id);
CREATE INDEX IF NOT EXISTS idx_journal_entries_doc ON journal_entries(branch_id, doc_type, doc_id);

-- A posted journal entry must have at least two lines and equal totals.
-- Deferred triggers allow all lines to be inserted before the final POSTED update.
CREATE OR REPLACE FUNCTION assert_journal_entry_balanced(p_entry_id TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
  v_count BIGINT;
  v_dr NUMERIC(20,4);
  v_cr NUMERIC(20,4);
BEGIN
  SELECT status INTO v_status FROM journal_entries WHERE id = p_entry_id;
  IF NOT FOUND OR v_status <> 'POSTED' THEN
    RETURN;
  END IF;

  SELECT COUNT(*), COALESCE(SUM(dr_amount), 0), COALESCE(SUM(cr_amount), 0)
    INTO v_count, v_dr, v_cr
  FROM journal_lines
  WHERE journal_entry_id = p_entry_id;

  IF v_count < 2 OR v_dr <> v_cr THEN
    RAISE EXCEPTION 'Posted journal entry % is not balanced', p_entry_id
      USING ERRCODE = '23514';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION journal_lines_balance_constraint()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM assert_journal_entry_balanced(OLD.journal_entry_id);
    RETURN OLD;
  END IF;
  PERFORM assert_journal_entry_balanced(NEW.journal_entry_id);
  IF TG_OP = 'UPDATE' AND OLD.journal_entry_id <> NEW.journal_entry_id THEN
    PERFORM assert_journal_entry_balanced(OLD.journal_entry_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journal_lines_balanced ON journal_lines;
CREATE CONSTRAINT TRIGGER trg_journal_lines_balanced
AFTER INSERT OR UPDATE OR DELETE ON journal_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION journal_lines_balance_constraint();

CREATE OR REPLACE FUNCTION journal_entry_status_balance_constraint()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM assert_journal_entry_balanced(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journal_entry_status_balanced ON journal_entries;
CREATE CONSTRAINT TRIGGER trg_journal_entry_status_balanced
AFTER INSERT OR UPDATE OF status ON journal_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION journal_entry_status_balance_constraint();

CREATE TABLE IF NOT EXISTS cash_accounts (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  code VARCHAR(40) NOT NULL,
  name_ar VARCHAR(120) NOT NULL,
  account_kind VARCHAR(20) NOT NULL CHECK (account_kind IN ('CASH_DRAWER', 'WALLET', 'BANK')),
  wallet_provider VARCHAR(20) CHECK (wallet_provider IN ('JAWALI', 'JEEB', 'FLOOSAK', 'KURAIMI')),
  wallet_phone VARCHAR(32),
  gl_account_id TEXT NOT NULL REFERENCES chart_of_accounts(id),
  current_balance NUMERIC(20,4) NOT NULL DEFAULT 0,
  currency CHAR(3) NOT NULL DEFAULT 'YER',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, code),
  CHECK ((account_kind = 'WALLET' AND wallet_provider IS NOT NULL)
      OR (account_kind <> 'WALLET' AND wallet_provider IS NULL))
);

CREATE TABLE IF NOT EXISTS parties (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  party_type VARCHAR(20) NOT NULL CHECK (party_type IN
    ('CUSTOMER', 'SUPPLIER', 'EMPLOYEE', 'PARTNER', 'REPRESENTATIVE')),
  code VARCHAR(64) NOT NULL,
  name_ar VARCHAR(200) NOT NULL,
  phone VARCHAR(40),
  address TEXT,
  credit_limit NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  payment_terms_days INTEGER NOT NULL DEFAULT 0 CHECK (payment_terms_days >= 0),
  price_tier VARCHAR(16) NOT NULL DEFAULT 'RETAIL'
    CHECK (price_tier IN ('RETAIL', 'WHOLESALE')),
  is_blocked BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, code)
);

CREATE TABLE IF NOT EXISTS lah_alayh_ledger (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  party_id TEXT NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
  entry_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  entry_type VARCHAR(32) NOT NULL,
  alayh_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (alayh_amount >= 0),
  lah_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (lah_amount >= 0),
  doc_type VARCHAR(32) NOT NULL,
  doc_id TEXT NOT NULL,
  statement_ar TEXT NOT NULL DEFAULT '',
  journal_entry_id TEXT REFERENCES journal_entries(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((alayh_amount > 0) <> (lah_amount > 0))
);

CREATE INDEX IF NOT EXISTS idx_party_ledger_party_date
  ON lah_alayh_ledger(branch_id, party_id, entry_date, id);
CREATE INDEX IF NOT EXISTS idx_party_ledger_document
  ON lah_alayh_ledger(branch_id, doc_type, doc_id);

CREATE OR REPLACE VIEW v_party_balance AS
SELECT
  p.id AS party_id,
  p.branch_id,
  COALESCE(SUM(l.alayh_amount), 0)::NUMERIC(20,4) AS total_alayh,
  COALESCE(SUM(l.lah_amount), 0)::NUMERIC(20,4) AS total_lah,
  (COALESCE(SUM(l.alayh_amount), 0) - COALESCE(SUM(l.lah_amount), 0))::NUMERIC(20,4) AS net,
  CASE
    WHEN COALESCE(SUM(l.alayh_amount), 0) > COALESCE(SUM(l.lah_amount), 0) THEN 'ALAYH'
    WHEN COALESCE(SUM(l.alayh_amount), 0) < COALESCE(SUM(l.lah_amount), 0) THEN 'LAH'
    ELSE 'ZERO'
  END AS balance_side,
  ABS(COALESCE(SUM(l.alayh_amount), 0) - COALESCE(SUM(l.lah_amount), 0))::NUMERIC(20,4) AS balance_abs
FROM parties p
LEFT JOIN lah_alayh_ledger l
  ON l.party_id = p.id AND l.branch_id = p.branch_id
GROUP BY p.id, p.branch_id;

CREATE TABLE IF NOT EXISTS vouchers (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  voucher_no VARCHAR(64) NOT NULL,
  voucher_type VARCHAR(16) NOT NULL CHECK (voucher_type IN ('RECEIPT', 'PAYMENT', 'ADJUSTMENT')),
  voucher_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  party_id TEXT NOT NULL REFERENCES parties(id) ON DELETE RESTRICT,
  cash_account_id TEXT NOT NULL REFERENCES cash_accounts(id) ON DELETE RESTRICT,
  amount NUMERIC(20,4) NOT NULL CHECK (amount > 0),
  method VARCHAR(16) NOT NULL CHECK (method IN ('CASH', 'WALLET', 'CREDIT', 'MIXED')),
  wallet_ref_no VARCHAR(100),
  description TEXT NOT NULL DEFAULT '',
  journal_entry_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE RESTRICT,
  operation_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, voucher_no),
  UNIQUE (branch_id, operation_id),
  CHECK (method <> 'WALLET' OR length(trim(COALESCE(wallet_ref_no, ''))) >= 6)
);

CREATE TABLE IF NOT EXISTS sales_invoices (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  invoice_no VARCHAR(64) NOT NULL,
  invoice_date TIMESTAMPTZ NOT NULL DEFAULT now(),
  cashier_user_id TEXT,
  customer_party_id TEXT REFERENCES parties(id) ON DELETE RESTRICT,
  price_tier VARCHAR(16) NOT NULL DEFAULT 'RETAIL' CHECK (price_tier IN ('RETAIL', 'WHOLESALE')),
  sale_type VARCHAR(16) NOT NULL DEFAULT 'CASH' CHECK (sale_type IN ('CASH', 'CREDIT', 'MIXED')),
  status VARCHAR(16) NOT NULL DEFAULT 'POSTED' CHECK (status IN ('POSTED', 'VOIDED', 'RETURNED')),
  subtotal NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount_amount NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  net_total NUMERIC(20,4) NOT NULL CHECK (net_total >= 0),
  paid_total NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (paid_total >= 0),
  change_returned NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (change_returned >= 0),
  remaining_alayh NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (remaining_alayh >= 0),
  journal_entry_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE RESTRICT,
  operation_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, invoice_no),
  UNIQUE (branch_id, operation_id),
  CHECK (paid_total + remaining_alayh >= net_total OR change_returned > 0)
);

CREATE TABLE IF NOT EXISTS sales_invoice_items (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  invoice_id TEXT NOT NULL REFERENCES sales_invoices(id) ON DELETE RESTRICT,
  product_id TEXT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  barcode VARCHAR(64),
  unit_name VARCHAR(80) NOT NULL,
  qty_sold NUMERIC(20,4) NOT NULL CHECK (qty_sold > 0),
  conversion_factor NUMERIC(20,6) NOT NULL CHECK (conversion_factor > 0),
  qty_base NUMERIC(20,6) GENERATED ALWAYS AS (qty_sold * conversion_factor) STORED,
  unit_price NUMERIC(20,4) NOT NULL CHECK (unit_price >= 0),
  line_total NUMERIC(20,4) NOT NULL CHECK (line_total >= 0)
);

CREATE INDEX IF NOT EXISTS idx_sales_items_product ON sales_invoice_items(product_id);

CREATE TABLE IF NOT EXISTS sales_payments (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  invoice_id TEXT NOT NULL REFERENCES sales_invoices(id) ON DELETE RESTRICT,
  cash_account_id TEXT REFERENCES cash_accounts(id) ON DELETE RESTRICT,
  method VARCHAR(16) NOT NULL CHECK (method IN ('CASH', 'WALLET', 'CREDIT')),
  amount NUMERIC(20,4) NOT NULL CHECK (amount > 0),
  wallet_provider VARCHAR(20) CHECK (wallet_provider IN ('JAWALI', 'JEEB', 'FLOOSAK', 'KURAIMI')),
  wallet_ref_no VARCHAR(100),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (method <> 'WALLET' OR
    (wallet_provider IS NOT NULL AND length(trim(COALESCE(wallet_ref_no, ''))) >= 6)),
  CHECK (method = 'CREDIT' OR cash_account_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS sync_idempotency (
  idempotency_key VARCHAR(200) PRIMARY KEY,
  branch_id TEXT NOT NULL REFERENCES branches(id),
  request_hash CHAR(64) NOT NULL,
  response_status INTEGER,
  response_body JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS sync_operation_receipts (
  id TEXT PRIMARY KEY DEFAULT (gen_random_uuid()::text),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  operation_id TEXT NOT NULL,
  operation_type VARCHAR(32) NOT NULL,
  idempotency_key VARCHAR(200) NOT NULL REFERENCES sync_idempotency(idempotency_key),
  result_status VARCHAR(16) NOT NULL CHECK (result_status IN ('ACCEPTED', 'REJECTED')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (branch_id, operation_id)
);

CREATE INDEX IF NOT EXISTS idx_sales_invoice_date
  ON sales_invoices(branch_id, invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_vouchers_party_date
  ON vouchers(branch_id, party_id, voucher_date DESC);

-- Seed a minimal chart of accounts and the required cash/wallet accounts
-- independently for each branch created by Iteration 1.
INSERT INTO chart_of_accounts (branch_id, code, name_ar, account_type)
SELECT b.id, seed.code, seed.name_ar, seed.account_type
FROM branches b
CROSS JOIN (VALUES
  ('1000', 'الصندوق الرئيسي', 'ASSET'),
  ('1010', 'درج الكاشير', 'ASSET'),
  ('1020', 'محفظة جوالي', 'ASSET'),
  ('1030', 'محفظة جيب', 'ASSET'),
  ('1040', 'محفظة فلوسك', 'ASSET'),
  ('1050', 'محفظة كريمي', 'ASSET'),
  ('1100', 'ذمم العملاء', 'ASSET'),
  ('2000', 'ذمم الموردين', 'LIABILITY'),
  ('3000', 'رأس المال', 'EQUITY'),
  ('4000', 'إيرادات المبيعات', 'REVENUE'),
  ('5000', 'تكلفة البضاعة المباعة', 'EXPENSE'),
  ('1200', 'المخزون', 'ASSET')
) AS seed(code, name_ar, account_type)
ON CONFLICT (branch_id, code) DO NOTHING;

INSERT INTO cash_accounts
  (branch_id, code, name_ar, account_kind, wallet_provider, gl_account_id, currency)
SELECT b.id, seed.code, seed.name_ar, seed.account_kind, seed.wallet_provider,
       coa.id, 'YER'
FROM branches b
CROSS JOIN (VALUES
  ('CASH-MAIN', 'الصندوق الرئيسي', 'CASH_DRAWER', NULL::VARCHAR(20), '1000'),
  ('CASH-DRAWER', 'درج الكاشير', 'CASH_DRAWER', NULL::VARCHAR(20), '1010'),
  ('WALLET-JAWALI', 'محفظة جوالي', 'WALLET', 'JAWALI', '1020'),
  ('WALLET-JEEB', 'محفظة جيب', 'WALLET', 'JEEB', '1030'),
  ('WALLET-FLOOSAK', 'محفظة فلوسك', 'WALLET', 'FLOOSAK', '1040'),
  ('WALLET-KURAIMI', 'محفظة كريمي', 'WALLET', 'KURAIMI', '1050')
) AS seed(code, name_ar, account_kind, wallet_provider, gl_code)
JOIN chart_of_accounts coa ON coa.branch_id = b.id AND coa.code = seed.gl_code
ON CONFLICT (branch_id, code) DO NOTHING;

COMMIT;
