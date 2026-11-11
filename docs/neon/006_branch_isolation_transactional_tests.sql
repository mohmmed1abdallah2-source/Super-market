-- Neon integration test pack: branch isolation + accounting invariants.
-- READ THIS FIRST:
--   * Run only against a disposable PostgreSQL database with migrations 001-003 applied.
--   * This script creates temporary test rows inside one transaction and ALWAYS rolls them back.
--   * It does not create or modify persistent business data.
--   * Do not run with an autocommit-per-statement SQL client. Execute the entire file as one script.
--   * It is a database-constraint test, not a substitute for API/authentication or multi-device tests.
--
-- Expected result: one final row with all assertions = true, followed by ROLLBACK.
-- Any failed assertion raises an exception and aborts the transaction.

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $test$
DECLARE
  b1 TEXT := 'it_branch_a_' || replace(gen_random_uuid()::text, '-', '');
  b2 TEXT := 'it_branch_b_' || replace(gen_random_uuid()::text, '-', '');
  u1 TEXT := 'it_user_a_' || replace(gen_random_uuid()::text, '-', '');
  u2 TEXT := 'it_user_b_' || replace(gen_random_uuid()::text, '-', '');
  p1 TEXT := 'it_product_a_' || replace(gen_random_uuid()::text, '-', '');
  p2 TEXT := 'it_product_b_' || replace(gen_random_uuid()::text, '-', '');
  a1 TEXT := 'it_asset_a_' || replace(gen_random_uuid()::text, '-', '');
  a2 TEXT := 'it_asset_b_' || replace(gen_random_uuid()::text, '-', '');
  a3 TEXT := 'it_revenue_a_' || replace(gen_random_uuid()::text, '-', '');
  party1 TEXT := 'it_party_a_' || replace(gen_random_uuid()::text, '-', '');
  party2 TEXT := 'it_party_b_' || replace(gen_random_uuid()::text, '-', '');
  cash1 TEXT := 'it_cash_a_' || replace(gen_random_uuid()::text, '-', '');
  cash2 TEXT := 'it_cash_b_' || replace(gen_random_uuid()::text, '-', '');
  je1 TEXT := 'it_journal_a_' || replace(gen_random_uuid()::text, '-', '');
  je_bad TEXT := 'it_journal_bad_' || replace(gen_random_uuid()::text, '-', '');
  inv1 TEXT := 'it_invoice_a_' || replace(gen_random_uuid()::text, '-', '');
  idem1 TEXT := 'it_idem_a_' || replace(gen_random_uuid()::text, '-', '');
  idem2 TEXT := 'it_idem_b_' || replace(gen_random_uuid()::text, '-', '');
  caught BOOLEAN;
  actual_branch TEXT;
BEGIN
  -- Two isolated branches and their branch-owned parents.
  INSERT INTO branches (id, code, name_ar) VALUES
    (b1, 'IT-' || substr(b1, 1, 12), 'اختبار الفرع أ'),
    (b2, 'IT-' || substr(b2, 1, 12), 'اختبار الفرع ب');

  INSERT INTO users (id, branch_id, username, full_name, role_code) VALUES
    (u1, b1, u1, 'Integration User A', 'CASHIER'),
    (u2, b2, u2, 'Integration User B', 'CASHIER');

  INSERT INTO products (id, branch_id, sku_code, name_ar, base_unit_name) VALUES
    (p1, b1, p1, 'منتج اختبار أ', 'قطعة'),
    (p2, b2, p2, 'منتج اختبار ب', 'قطعة');

  INSERT INTO chart_of_accounts (id, branch_id, code, name_ar, account_type) VALUES
    (a1, b1, 'IT-ASSET', 'أصل اختبار أ', 'ASSET'),
    (a3, b1, 'IT-REV', 'إيراد اختبار أ', 'REVENUE'),
    (a2, b2, 'IT-ASSET', 'أصل اختبار ب', 'ASSET');

  INSERT INTO parties (id, branch_id, party_type, code, name_ar) VALUES
    (party1, b1, 'CUSTOMER', party1, 'طرف اختبار أ'),
    (party2, b2, 'CUSTOMER', party2, 'طرف اختبار ب');

  INSERT INTO cash_accounts (id, branch_id, code, name_ar, account_kind, gl_account_id) VALUES
    (cash1, b1, 'IT-CASH', 'نقد اختبار أ', 'CASH_DRAWER', a1),
    (cash2, b2, 'IT-CASH', 'نقد اختبار ب', 'CASH_DRAWER', a2);

  -- Positive path: balanced posted journal entry in branch A.
  INSERT INTO journal_entries
    (id, branch_id, entry_no, doc_type, doc_id, description, status)
  VALUES (je1, b1, je1, 'INTEGRATION_TEST', je1, 'balanced test entry', 'DRAFT');

  INSERT INTO journal_lines (id, journal_entry_id, gl_account_id, dr_amount, cr_amount)
  VALUES
    ('it_jl_dr_' || substr(je1, 1, 24), je1, a1, 25.00, 0),
    ('it_jl_cr_' || substr(je1, 1, 24), je1, a3, 0, 25.00);

  UPDATE journal_entries SET status = 'POSTED', posted_at = now() WHERE id = je1;
  SET CONSTRAINTS trg_journal_entry_status_balanced, trg_journal_lines_balanced IMMEDIATE;

  -- Verify the trigger derives the owning branch, not a caller-supplied value.
  INSERT INTO journal_entries
    (id, branch_id, entry_no, doc_type, doc_id, description, status)
  VALUES (je_bad, b1, je_bad, 'INTEGRATION_TEST', je_bad, 'branch derivation probe', 'DRAFT');

  INSERT INTO journal_lines (id, journal_entry_id, branch_id, gl_account_id, dr_amount, cr_amount)
  VALUES ('it_jl_branch_probe_' || substr(je_bad, 1, 18), je_bad, b2, a1, 1.00, 0);

  SELECT branch_id INTO actual_branch FROM journal_lines
   WHERE journal_entry_id = je_bad;
  IF actual_branch IS DISTINCT FROM b1 THEN
    RAISE EXCEPTION 'FAIL: journal_lines branch trigger did not derive branch A';
  END IF;

  -- Negative path 1: branch A journal entry cannot reference branch B account.
  caught := FALSE;
  BEGIN
    INSERT INTO journal_lines (id, journal_entry_id, gl_account_id, dr_amount, cr_amount)
    VALUES ('it_jl_cross_' || substr(je1, 1, 20), je1, a2, 2.00, 0);
  EXCEPTION WHEN foreign_key_violation THEN
    caught := TRUE;
  END;
  IF NOT caught THEN RAISE EXCEPTION 'FAIL: cross-branch journal account reference was accepted'; END IF;

  -- Positive sale in A; invoice must point to A's user, party and journal entry.
  INSERT INTO sales_invoices
    (id, branch_id, invoice_no, cashier_user_id, customer_party_id, sale_type,
     subtotal, net_total, paid_total, journal_entry_id, operation_id)
  VALUES
    (inv1, b1, inv1, u1, party1, 'CASH', 10.00, 10.00, 10.00, je1, inv1);

  -- Trigger derives A even if the client attempts to submit B.
  INSERT INTO sales_invoice_items
    (id, invoice_id, product_id, branch_id, unit_name, qty_sold,
     conversion_factor, unit_price, line_total)
  VALUES
    ('it_item_ok_' || substr(inv1, 1, 20), inv1, p1, b2, 'قطعة', 1, 1, 10, 10);

  SELECT branch_id INTO actual_branch FROM sales_invoice_items WHERE invoice_id = inv1;
  IF actual_branch IS DISTINCT FROM b1 THEN
    RAISE EXCEPTION 'FAIL: sales_invoice_items branch trigger did not derive branch A';
  END IF;

  -- Negative path 2: A invoice cannot contain B product, even though the trigger
  -- overwrites a forged branch_id with A.
  caught := FALSE;
  BEGIN
    INSERT INTO sales_invoice_items
      (id, invoice_id, product_id, unit_name, qty_sold, conversion_factor, unit_price, line_total)
    VALUES ('it_item_cross_' || substr(inv1, 1, 18), inv1, p2, 'قطعة', 1, 1, 10, 10);
  EXCEPTION WHEN foreign_key_violation THEN
    caught := TRUE;
  END;
  IF NOT caught THEN RAISE EXCEPTION 'FAIL: cross-branch invoice product was accepted'; END IF;

  -- Negative path 3: A invoice cannot receive a payment from B cash account.
  caught := FALSE;
  BEGIN
    INSERT INTO sales_payments (id, invoice_id, cash_account_id, method, amount)
    VALUES ('it_payment_cross_' || substr(inv1, 1, 16), inv1, cash2, 'CASH', 10.00);
  EXCEPTION WHEN foreign_key_violation THEN
    caught := TRUE;
  END;
  IF NOT caught THEN RAISE EXCEPTION 'FAIL: cross-branch payment cash account was accepted'; END IF;

  -- Positive payment against A cash account.
  INSERT INTO sales_payments (id, invoice_id, cash_account_id, method, amount)
  VALUES ('it_payment_ok_' || substr(inv1, 1, 18), inv1, cash1, 'CASH', 10.00);

  -- Negative path 4: a sync receipt in A cannot reference B's idempotency row.
  INSERT INTO sync_idempotency (idempotency_key, branch_id, request_hash)
  VALUES (idem1, b1, repeat('a', 64)), (idem2, b2, repeat('b', 64));

  caught := FALSE;
  BEGIN
    INSERT INTO sync_operation_receipts
      (id, branch_id, operation_id, operation_type, idempotency_key, result_status)
    VALUES ('it_receipt_cross_' || substr(inv1, 1, 16), b1, inv1,
            'SALE', idem2, 'ACCEPTED');
  EXCEPTION WHEN foreign_key_violation THEN
    caught := TRUE;
  END;
  IF NOT caught THEN RAISE EXCEPTION 'FAIL: cross-branch idempotency receipt was accepted'; END IF;

  -- Negative path 5: an unbalanced journal entry must not be POSTED.
  caught := FALSE;
  BEGIN
    INSERT INTO journal_entries
      (id, branch_id, entry_no, doc_type, doc_id, description, status)
    VALUES ( 'it_unbalanced_' || substr(je1, 1, 16), b1,
             'it_unbalanced_' || substr(je1, 1, 16),
             'INTEGRATION_TEST', 'it_unbalanced_' || substr(je1, 1, 16),
             'must fail', 'POSTED');
    SET CONSTRAINTS trg_journal_entry_status_balanced IMMEDIATE;
  EXCEPTION WHEN check_violation THEN
    caught := TRUE;
  END;
  IF NOT caught THEN RAISE EXCEPTION 'FAIL: unbalanced posted journal entry was accepted'; END IF;

  RAISE NOTICE 'PASS: branch isolation and accounting assertions completed';
END
$test$;

-- Machine-readable success summary. Reaching this SELECT means all DO assertions passed.
SELECT
  TRUE AS two_branches_created_inside_test,
  TRUE AS balanced_journal_posted,
  TRUE AS journal_branch_derived_from_parent,
  TRUE AS cross_branch_journal_account_rejected,
  TRUE AS invoice_item_branch_derived_from_parent,
  TRUE AS cross_branch_product_rejected,
  TRUE AS cross_branch_payment_account_rejected,
  TRUE AS valid_same_branch_payment_accepted,
  TRUE AS cross_branch_idempotency_receipt_rejected,
  TRUE AS unbalanced_posted_journal_rejected,
  'All rows are temporary; the following ROLLBACK removes them.' AS cleanup;

ROLLBACK;
