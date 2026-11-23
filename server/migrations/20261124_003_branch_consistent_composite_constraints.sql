-- Migration 003: branch-consistent composite relationships.
-- Safe for the currently reported empty Neon schema and additive for existing rows.
-- Review/backup the target database before execution. Do not run against another store DB.
BEGIN;

-- Parent keys: allow foreign keys to reference a record and its owning branch together.
ALTER TABLE products ADD CONSTRAINT products_id_branch_key UNIQUE (id, branch_id);
ALTER TABLE users ADD CONSTRAINT users_id_branch_key UNIQUE (id, branch_id);
ALTER TABLE product_units_barcodes ADD CONSTRAINT product_units_barcodes_id_branch_key UNIQUE (id, branch_id);
ALTER TABLE chart_of_accounts ADD CONSTRAINT chart_of_accounts_id_branch_key UNIQUE (id, branch_id);
ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_id_branch_key UNIQUE (id, branch_id);
ALTER TABLE parties ADD CONSTRAINT parties_id_branch_key UNIQUE (id, branch_id);
ALTER TABLE cash_accounts ADD CONSTRAINT cash_accounts_id_branch_key UNIQUE (id, branch_id);
ALTER TABLE sync_idempotency ADD CONSTRAINT sync_idempotency_key_branch_key UNIQUE (idempotency_key, branch_id);
ALTER TABLE sales_invoices ADD CONSTRAINT sales_invoices_id_branch_key UNIQUE (id, branch_id);

-- Child rows that previously had no branch_id receive it from their owning invoice/entry.
ALTER TABLE journal_lines ADD COLUMN branch_id TEXT;
ALTER TABLE sales_invoice_items ADD COLUMN branch_id TEXT;
ALTER TABLE sales_payments ADD COLUMN branch_id TEXT;

UPDATE journal_lines jl
SET branch_id = je.branch_id
FROM journal_entries je
WHERE je.id = jl.journal_entry_id AND jl.branch_id IS NULL;

UPDATE sales_invoice_items sii
SET branch_id = si.branch_id
FROM sales_invoices si
WHERE si.id = sii.invoice_id AND sii.branch_id IS NULL;

UPDATE sales_payments sp
SET branch_id = si.branch_id
FROM sales_invoices si
WHERE si.id = sp.invoice_id AND sp.branch_id IS NULL;

-- Fail closed if existing rows cannot be assigned a branch.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM journal_lines WHERE branch_id IS NULL)
     OR EXISTS (SELECT 1 FROM sales_invoice_items WHERE branch_id IS NULL)
     OR EXISTS (SELECT 1 FROM sales_payments WHERE branch_id IS NULL) THEN
    RAISE EXCEPTION 'Migration 003 stopped: one or more child rows could not inherit branch_id';
  END IF;
END $$;

ALTER TABLE journal_lines ALTER COLUMN branch_id SET NOT NULL;
ALTER TABLE sales_invoice_items ALTER COLUMN branch_id SET NOT NULL;
ALTER TABLE sales_payments ALTER COLUMN branch_id SET NOT NULL;

-- Keep branch_id authoritative: callers do not supply it for these child rows.
CREATE OR REPLACE FUNCTION set_journal_line_branch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  SELECT branch_id INTO NEW.branch_id
  FROM journal_entries WHERE id = NEW.journal_entry_id;
  IF NEW.branch_id IS NULL THEN
    RAISE EXCEPTION 'Journal entry % does not exist', NEW.journal_entry_id
      USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION set_sales_invoice_item_branch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  SELECT branch_id INTO NEW.branch_id
  FROM sales_invoices WHERE id = NEW.invoice_id;
  IF NEW.branch_id IS NULL THEN
    RAISE EXCEPTION 'Sales invoice % does not exist', NEW.invoice_id
      USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION set_sales_payment_branch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  SELECT branch_id INTO NEW.branch_id
  FROM sales_invoices WHERE id = NEW.invoice_id;
  IF NEW.branch_id IS NULL THEN
    RAISE EXCEPTION 'Sales invoice % does not exist', NEW.invoice_id
      USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_set_journal_line_branch
BEFORE INSERT OR UPDATE OF journal_entry_id, branch_id ON journal_lines
FOR EACH ROW EXECUTE FUNCTION set_journal_line_branch();

CREATE TRIGGER trg_set_sales_invoice_item_branch
BEFORE INSERT OR UPDATE OF invoice_id, branch_id ON sales_invoice_items
FOR EACH ROW EXECUTE FUNCTION set_sales_invoice_item_branch();

CREATE TRIGGER trg_set_sales_payment_branch
BEFORE INSERT OR UPDATE OF invoice_id, branch_id ON sales_payments
FOR EACH ROW EXECUTE FUNCTION set_sales_payment_branch();

-- Replace single-column references with branch-aware composite foreign keys.
ALTER TABLE product_units_barcodes DROP CONSTRAINT product_units_barcodes_product_id_fkey;
ALTER TABLE product_units_barcodes
  ADD CONSTRAINT product_units_barcodes_product_branch_fkey
  FOREIGN KEY (product_id, branch_id) REFERENCES products(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_product_id_fkey;
ALTER TABLE stock_movements
  ADD CONSTRAINT stock_movements_product_branch_fkey
  FOREIGN KEY (product_id, branch_id) REFERENCES products(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE chart_of_accounts DROP CONSTRAINT chart_of_accounts_parent_id_fkey;
ALTER TABLE chart_of_accounts
  ADD CONSTRAINT chart_of_accounts_parent_branch_fkey
  FOREIGN KEY (parent_id, branch_id) REFERENCES chart_of_accounts(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE cash_accounts DROP CONSTRAINT cash_accounts_gl_account_id_fkey;
ALTER TABLE cash_accounts
  ADD CONSTRAINT cash_accounts_gl_account_branch_fkey
  FOREIGN KEY (gl_account_id, branch_id) REFERENCES chart_of_accounts(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE journal_lines DROP CONSTRAINT journal_lines_journal_entry_id_fkey;
ALTER TABLE journal_lines DROP CONSTRAINT journal_lines_gl_account_id_fkey;
ALTER TABLE journal_lines
  ADD CONSTRAINT journal_lines_entry_branch_fkey
  FOREIGN KEY (journal_entry_id, branch_id) REFERENCES journal_entries(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT journal_lines_account_branch_fkey
  FOREIGN KEY (gl_account_id, branch_id) REFERENCES chart_of_accounts(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE lah_alayh_ledger DROP CONSTRAINT lah_alayh_ledger_party_id_fkey;
ALTER TABLE lah_alayh_ledger DROP CONSTRAINT lah_alayh_ledger_journal_entry_id_fkey;
ALTER TABLE lah_alayh_ledger
  ADD CONSTRAINT lah_alayh_ledger_party_branch_fkey
  FOREIGN KEY (party_id, branch_id) REFERENCES parties(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT lah_alayh_ledger_journal_branch_fkey
  FOREIGN KEY (journal_entry_id, branch_id) REFERENCES journal_entries(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE vouchers DROP CONSTRAINT vouchers_party_id_fkey;
ALTER TABLE vouchers DROP CONSTRAINT vouchers_cash_account_id_fkey;
ALTER TABLE vouchers DROP CONSTRAINT vouchers_journal_entry_id_fkey;
ALTER TABLE vouchers
  ADD CONSTRAINT vouchers_party_branch_fkey
  FOREIGN KEY (party_id, branch_id) REFERENCES parties(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT vouchers_cash_branch_fkey
  FOREIGN KEY (cash_account_id, branch_id) REFERENCES cash_accounts(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT vouchers_journal_branch_fkey
  FOREIGN KEY (journal_entry_id, branch_id) REFERENCES journal_entries(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE sales_invoices DROP CONSTRAINT sales_invoices_customer_party_id_fkey;
ALTER TABLE sales_invoices DROP CONSTRAINT sales_invoices_journal_entry_id_fkey;
ALTER TABLE sales_invoices
  ADD CONSTRAINT sales_invoices_customer_branch_fkey
  FOREIGN KEY (customer_party_id, branch_id) REFERENCES parties(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_invoices_journal_branch_fkey
  FOREIGN KEY (journal_entry_id, branch_id) REFERENCES journal_entries(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_invoices_cashier_branch_fkey
  FOREIGN KEY (cashier_user_id, branch_id) REFERENCES users(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE sales_invoice_items DROP CONSTRAINT sales_invoice_items_invoice_id_fkey;
ALTER TABLE sales_invoice_items DROP CONSTRAINT sales_invoice_items_product_id_fkey;
ALTER TABLE sales_invoice_items
  ADD CONSTRAINT sales_invoice_items_invoice_branch_fkey
  FOREIGN KEY (invoice_id, branch_id) REFERENCES sales_invoices(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_invoice_items_product_branch_fkey
  FOREIGN KEY (product_id, branch_id) REFERENCES products(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE sales_payments DROP CONSTRAINT sales_payments_invoice_id_fkey;
ALTER TABLE sales_payments DROP CONSTRAINT sales_payments_cash_account_id_fkey;
ALTER TABLE sales_payments
  ADD CONSTRAINT sales_payments_invoice_branch_fkey
  FOREIGN KEY (invoice_id, branch_id) REFERENCES sales_invoices(id, branch_id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_payments_cash_branch_fkey
  FOREIGN KEY (cash_account_id, branch_id) REFERENCES cash_accounts(id, branch_id) ON DELETE RESTRICT;

ALTER TABLE sync_operation_receipts DROP CONSTRAINT sync_operation_receipts_idempotency_key_fkey;
ALTER TABLE sync_operation_receipts
  ADD CONSTRAINT sync_operation_receipts_idempotency_branch_fkey
  FOREIGN KEY (idempotency_key, branch_id)
  REFERENCES sync_idempotency(idempotency_key, branch_id) ON DELETE RESTRICT;

-- Idempotency keys remain globally unique; the composite reference additionally
-- proves that each receipt belongs to the same branch as its idempotency record.
-- Add supporting indexes for the new composite child foreign keys.
CREATE INDEX IF NOT EXISTS idx_product_units_product_branch ON product_units_barcodes(product_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_product_branch ON stock_movements(product_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_cash_accounts_gl_branch ON cash_accounts(gl_account_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_ledger_party_branch ON lah_alayh_ledger(party_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_entry_branch ON journal_lines(journal_entry_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_account_branch ON journal_lines(gl_account_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_sales_items_invoice_branch ON sales_invoice_items(invoice_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_sales_items_product_branch ON sales_invoice_items(product_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_sales_payments_invoice_branch ON sales_payments(invoice_id, branch_id);
CREATE INDEX IF NOT EXISTS idx_sales_payments_cash_branch ON sales_payments(cash_account_id, branch_id);

-- This index duplicates the UNIQUE index on (branch_id, doc_type, doc_id).
DROP INDEX IF EXISTS idx_journal_entries_doc;

COMMIT;
