-- Neon post-migration verification (read-only).
-- Run once in Neon SQL Editor AFTER migrations 003 and 004.
-- This script performs no INSERT/UPDATE/DELETE/DDL and returns one row per audit section.
-- Exact FK comparison uses ordered attnum arrays; it does not compare name[] to text[].

WITH
expected_fks(child_table, child_cols, parent_table, parent_cols) AS (
  VALUES
    ('product_units_barcodes', ARRAY['product_id','branch_id']::text[], 'products', ARRAY['id','branch_id']::text[]),
    ('stock_movements', ARRAY['product_id','branch_id']::text[], 'products', ARRAY['id','branch_id']::text[]),
    ('chart_of_accounts', ARRAY['parent_id','branch_id']::text[], 'chart_of_accounts', ARRAY['id','branch_id']::text[]),
    ('cash_accounts', ARRAY['gl_account_id','branch_id']::text[], 'chart_of_accounts', ARRAY['id','branch_id']::text[]),
    ('journal_lines', ARRAY['journal_entry_id','branch_id']::text[], 'journal_entries', ARRAY['id','branch_id']::text[]),
    ('journal_lines', ARRAY['gl_account_id','branch_id']::text[], 'chart_of_accounts', ARRAY['id','branch_id']::text[]),
    ('lah_alayh_ledger', ARRAY['party_id','branch_id']::text[], 'parties', ARRAY['id','branch_id']::text[]),
    ('lah_alayh_ledger', ARRAY['journal_entry_id','branch_id']::text[], 'journal_entries', ARRAY['id','branch_id']::text[]),
    ('vouchers', ARRAY['party_id','branch_id']::text[], 'parties', ARRAY['id','branch_id']::text[]),
    ('vouchers', ARRAY['cash_account_id','branch_id']::text[], 'cash_accounts', ARRAY['id','branch_id']::text[]),
    ('vouchers', ARRAY['journal_entry_id','branch_id']::text[], 'journal_entries', ARRAY['id','branch_id']::text[]),
    ('sales_invoices', ARRAY['customer_party_id','branch_id']::text[], 'parties', ARRAY['id','branch_id']::text[]),
    ('sales_invoices', ARRAY['journal_entry_id','branch_id']::text[], 'journal_entries', ARRAY['id','branch_id']::text[]),
    ('sales_invoices', ARRAY['cashier_user_id','branch_id']::text[], 'users', ARRAY['id','branch_id']::text[]),
    ('sales_invoice_items', ARRAY['invoice_id','branch_id']::text[], 'sales_invoices', ARRAY['id','branch_id']::text[]),
    ('sales_invoice_items', ARRAY['product_id','branch_id']::text[], 'products', ARRAY['id','branch_id']::text[]),
    ('sales_payments', ARRAY['invoice_id','branch_id']::text[], 'sales_invoices', ARRAY['id','branch_id']::text[]),
    ('sales_payments', ARRAY['cash_account_id','branch_id']::text[], 'cash_accounts', ARRAY['id','branch_id']::text[]),
    ('sync_operation_receipts', ARRAY['idempotency_key','branch_id']::text[], 'sync_idempotency', ARRAY['idempotency_key','branch_id']::text[])
),
actual_fks AS (
  SELECT
    child.relname::text AS child_table,
    ARRAY(
      SELECT ca.attname::text
      FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
      JOIN pg_attribute ca ON ca.attrelid = con.conrelid AND ca.attnum = k.attnum
      ORDER BY k.ord
    ) AS child_cols,
    parent.relname::text AS parent_table,
    ARRAY(
      SELECT pa.attname::text
      FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
      JOIN pg_attribute pa ON pa.attrelid = con.confrelid AND pa.attnum = k.attnum
      ORDER BY k.ord
    ) AS parent_cols,
    con.conname::text AS constraint_name,
    con.convalidated AS validated
  FROM pg_constraint con
  JOIN pg_class child ON child.oid = con.conrelid
  JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
  JOIN pg_class parent ON parent.oid = con.confrelid
  JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
  WHERE con.contype = 'f'
    AND child_ns.nspname = 'public'
    AND parent_ns.nspname = 'public'
),
fk_audit AS (
  SELECT e.*, a.constraint_name, a.validated,
         (a.constraint_name IS NOT NULL) AS exists,
         COALESCE(a.validated, false) AS validated
  FROM expected_fks e
  LEFT JOIN actual_fks a
    ON a.child_table = e.child_table
   AND a.child_cols = e.child_cols
   AND a.parent_table = e.parent_table
   AND a.parent_cols = e.parent_cols
),
required_parent_keys(table_name, constraint_name) AS (
  VALUES
    ('products','products_id_branch_key'),
    ('users','users_id_branch_key'),
    ('product_units_barcodes','product_units_barcodes_id_branch_key'),
    ('chart_of_accounts','chart_of_accounts_id_branch_key'),
    ('journal_entries','journal_entries_id_branch_key'),
    ('parties','parties_id_branch_key'),
    ('cash_accounts','cash_accounts_id_branch_key'),
    ('sales_invoices','sales_invoices_id_branch_key'),
    ('sync_idempotency','sync_idempotency_key_branch_key')
),
parent_key_audit AS (
  SELECT r.table_name, r.constraint_name,
         EXISTS (
           SELECT 1 FROM pg_constraint c
           JOIN pg_class t ON t.oid=c.conrelid
           JOIN pg_namespace n ON n.oid=t.relnamespace
           WHERE n.nspname='public' AND t.relname=r.table_name
             AND c.conname=r.constraint_name AND c.contype='u' AND c.convalidated
         ) AS exists
  FROM required_parent_keys r
),
required_triggers(table_name, trigger_name) AS (
  VALUES
    ('journal_lines','trg_set_journal_line_branch'),
    ('sales_invoice_items','trg_set_sales_invoice_item_branch'),
    ('sales_payments','trg_set_sales_payment_branch'),
    ('journal_entries','trg_journal_entry_status_balanced'),
    ('journal_lines','trg_journal_lines_balanced')
),
trigger_audit AS (
  SELECT r.table_name, r.trigger_name,
         EXISTS (
           SELECT 1 FROM pg_trigger t
           JOIN pg_class c ON c.oid=t.tgrelid
           JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE n.nspname='public' AND c.relname=r.table_name
             AND t.tgname=r.trigger_name AND NOT t.tgisinternal
         ) AS exists
  FROM required_triggers r
),
table_counts AS (
  SELECT jsonb_agg(jsonb_build_object('table', table_name, 'rows', row_count) ORDER BY table_name) AS data
  FROM (
    SELECT c.relname AS table_name,
           (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', c.relname), false, true, '')))[1]::text::bigint AS row_count
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r'
  ) x
),
child_columns AS (
  SELECT t.table_name,
         bool_and(c.is_nullable='NO') AS branch_not_null
  FROM (VALUES ('journal_lines'),('sales_invoice_items'),('sales_payments')) t(table_name)
  LEFT JOIN information_schema.columns c
    ON c.table_schema='public' AND c.table_name=t.table_name AND c.column_name='branch_id'
  GROUP BY t.table_name
),
baseline_gl AS (
  SELECT b.id AS branch_id, expected.code,
         (coa.id IS NOT NULL) AS exists
  FROM branches b
  CROSS JOIN (VALUES ('1000'),('1010'),('1020'),('1030'),('1040'),('1050'),
                     ('1100'),('1200'),('2000'),('3000'),('4000'),('5000')) expected(code)
  LEFT JOIN chart_of_accounts coa ON coa.branch_id=b.id AND coa.code=expected.code
),
baseline_cash AS (
  SELECT b.id AS branch_id, expected.code,
         (ca.id IS NOT NULL) AS exists
  FROM branches b
  CROSS JOIN (VALUES ('CASH-MAIN'),('CASH-DRAWER'),('JAWALI'),('JAIB'),('FLOUSK'),('KURAIMI')) expected(code)
  LEFT JOIN cash_accounts ca ON ca.branch_id=b.id AND ca.code=expected.code
),
data_checks AS (
  SELECT 'product_units_barcodes_product_branch_mismatch' AS check_name,
         count(*) FILTER (WHERE p.branch_id IS DISTINCT FROM u.branch_id) AS violations
  FROM product_units_barcodes u JOIN products p ON p.id=u.product_id
  UNION ALL
  SELECT 'stock_movements_product_branch_mismatch',
         count(*) FILTER (WHERE p.branch_id IS DISTINCT FROM s.branch_id)
  FROM stock_movements s JOIN products p ON p.id=s.product_id
  UNION ALL
  SELECT 'cash_accounts_gl_branch_mismatch',
         count(*) FILTER (WHERE coa.branch_id IS DISTINCT FROM ca.branch_id)
  FROM cash_accounts ca JOIN chart_of_accounts coa ON coa.id=ca.gl_account_id
  UNION ALL
  SELECT 'journal_lines_entry_branch_mismatch',
         count(*) FILTER (WHERE je.branch_id IS DISTINCT FROM jl.branch_id)
  FROM journal_lines jl JOIN journal_entries je ON je.id=jl.journal_entry_id
  UNION ALL
  SELECT 'journal_lines_account_branch_mismatch',
         count(*) FILTER (WHERE coa.branch_id IS DISTINCT FROM jl.branch_id)
  FROM journal_lines jl JOIN chart_of_accounts coa ON coa.id=jl.gl_account_id
  UNION ALL
  SELECT 'ledger_party_branch_mismatch',
         count(*) FILTER (WHERE p.branch_id IS DISTINCT FROM l.branch_id)
  FROM lah_alayh_ledger l JOIN parties p ON p.id=l.party_id
  UNION ALL
  SELECT 'ledger_journal_branch_mismatch',
         count(*) FILTER (WHERE je.branch_id IS DISTINCT FROM l.branch_id)
  FROM lah_alayh_ledger l JOIN journal_entries je ON je.id=l.journal_entry_id
  UNION ALL
  SELECT 'sales_items_invoice_branch_mismatch',
         count(*) FILTER (WHERE si.branch_id IS DISTINCT FROM i.branch_id)
  FROM sales_invoice_items i JOIN sales_invoices si ON si.id=i.invoice_id
  UNION ALL
  SELECT 'sales_items_product_branch_mismatch',
         count(*) FILTER (WHERE p.branch_id IS DISTINCT FROM i.branch_id)
  FROM sales_invoice_items i JOIN products p ON p.id=i.product_id
  UNION ALL
  SELECT 'sales_payments_invoice_branch_mismatch',
         count(*) FILTER (WHERE si.branch_id IS DISTINCT FROM p.branch_id)
  FROM sales_payments p JOIN sales_invoices si ON si.id=p.invoice_id
  UNION ALL
  SELECT 'sales_payments_cash_branch_mismatch',
         count(*) FILTER (WHERE ca.branch_id IS DISTINCT FROM p.branch_id)
  FROM sales_payments p JOIN cash_accounts ca ON ca.id=p.cash_account_id
  UNION ALL
  SELECT 'vouchers_party_branch_mismatch',
         count(*) FILTER (WHERE p.branch_id IS DISTINCT FROM v.branch_id)
  FROM vouchers v JOIN parties p ON p.id=v.party_id
  UNION ALL
  SELECT 'vouchers_cash_branch_mismatch',
         count(*) FILTER (WHERE ca.branch_id IS DISTINCT FROM v.branch_id)
  FROM vouchers v JOIN cash_accounts ca ON ca.id=v.cash_account_id
  UNION ALL
  SELECT 'vouchers_journal_branch_mismatch',
         count(*) FILTER (WHERE je.branch_id IS DISTINCT FROM v.branch_id)
  FROM vouchers v JOIN journal_entries je ON je.id=v.journal_entry_id
  UNION ALL
  SELECT 'posted_journal_unbalanced',
         count(*) FILTER (WHERE totals.debit <> totals.credit OR totals.line_count < 2)
  FROM journal_entries je
  JOIN LATERAL (
    SELECT COALESCE(sum(dr_amount),0) AS debit,
           COALESCE(sum(cr_amount),0) AS credit, count(*) AS line_count
    FROM journal_lines jl WHERE jl.journal_entry_id=je.id AND jl.branch_id=je.branch_id
  ) totals ON true
  WHERE je.status='POSTED'
  UNION ALL
  SELECT 'ledger_zero_or_invalid_amount',
         count(*) FILTER (
           WHERE alayh_amount < 0 OR lah_amount < 0
              OR (alayh_amount > 0 AND lah_amount > 0)
              OR (alayh_amount = 0 AND lah_amount = 0)
         )
  FROM lah_alayh_ledger
),
role_audit AS (
  SELECT jsonb_build_object(
    'current_user', current_user,
    'is_superuser', r.rolsuper,
    'can_create_role', r.rolcreaterole,
    'can_create_database', r.rolcreatedb,
    'is_replication_role', r.rolreplication,
    'session_user', session_user
  ) AS data
  FROM pg_roles r WHERE r.rolname=current_user
),
duplicate_index_candidates AS (
  SELECT i1.indexrelid::regclass::text AS index_name,
         i1.indrelid::regclass::text AS table_name,
         pg_get_indexdef(i1.indexrelid) AS definition
  FROM pg_index i1
  JOIN pg_index i2
    ON i1.indrelid=i2.indrelid
   AND i1.indexrelid < i2.indexrelid
   AND i1.indkey=i2.indkey
   AND i1.indclass=i2.indclass
   AND i1.indcollation=i2.indcollation
   AND i1.indoption=i2.indoption
   AND COALESCE(pg_get_expr(i1.indexprs,i1.indrelid),'')=COALESCE(pg_get_expr(i2.indexprs,i2.indrelid),'')
   AND COALESCE(pg_get_expr(i1.indpred,i1.indrelid),'')=COALESCE(pg_get_expr(i2.indpred,i2.indrelid),'')
   AND i1.indisvalid AND i2.indisvalid
)
SELECT '01_database' AS section,
       jsonb_build_object('database',current_database(),'version',version(),'checked_at',now()) AS result
UNION ALL
SELECT '02_branch_aware_foreign_keys',
       jsonb_build_object(
         'expected_count',count(*),
         'present_and_valid',count(*) FILTER (WHERE exists AND validated),
         'missing_or_unvalidated',jsonb_agg(to_jsonb(f) ORDER BY child_table,child_cols)
           FILTER (WHERE NOT exists OR NOT validated)
       ) FROM fk_audit f
UNION ALL
SELECT '03_required_composite_unique_keys',
       jsonb_build_object('expected_count',count(*),
         'present',count(*) FILTER (WHERE exists),
         'missing',jsonb_agg(to_jsonb(k) ORDER BY table_name) FILTER (WHERE NOT exists))
       FROM parent_key_audit k
UNION ALL
SELECT '04_branch_columns_and_triggers',
       jsonb_build_object(
         'child_branch_columns', (SELECT jsonb_agg(to_jsonb(c) ORDER BY table_name) FROM child_columns c),
         'required_triggers', (SELECT jsonb_agg(to_jsonb(t) ORDER BY table_name,trigger_name) FROM trigger_audit t),
         'missing_triggers', (SELECT jsonb_agg(to_jsonb(t)) FROM trigger_audit t WHERE NOT exists)
       )
UNION ALL
SELECT '05_exact_table_row_counts', COALESCE(data,'[]'::jsonb) FROM table_counts
UNION ALL
SELECT '06_baseline_accounting',
       jsonb_build_object(
         'branches', (SELECT count(*) FROM branches),
         'expected_gl_rows', (SELECT count(*) FROM baseline_gl),
         'present_gl_rows', (SELECT count(*) FROM baseline_gl WHERE exists),
         'missing_gl', (SELECT COALESCE(jsonb_agg(to_jsonb(g) ORDER BY branch_id,code),'[]'::jsonb) FROM baseline_gl g WHERE NOT exists),
         'expected_cash_rows', (SELECT count(*) FROM baseline_cash),
         'present_cash_rows', (SELECT count(*) FROM baseline_cash WHERE exists),
         'missing_cash', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY branch_id,code),'[]'::jsonb) FROM baseline_cash c WHERE NOT exists)
       )
UNION ALL
SELECT '07_data_integrity_checks',
       jsonb_build_object(
         'checks', (SELECT jsonb_agg(jsonb_build_object('check',check_name,'violations',violations) ORDER BY check_name) FROM data_checks),
         'total_violations', (SELECT COALESCE(sum(violations),0) FROM data_checks)
       )
UNION ALL
SELECT '08_current_role_security', data FROM role_audit
UNION ALL
SELECT '09_exact_duplicate_index_candidates',
       COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY table_name,index_name) FROM duplicate_index_candidates d),'[]'::jsonb)
ORDER BY section;
