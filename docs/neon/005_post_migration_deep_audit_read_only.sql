-- Neon post-migration deep audit (read-only).
-- Run in Neon SQL Editor after migrations 003 and 004.
-- This script does not insert, update, delete, or alter any database object.
-- Exact table counts are used for the core tables; no pg_stat estimates.
WITH
expected_fk(name, child_table, parent_table, child_cols, parent_cols) AS (
  VALUES
    ('product_units_barcodes_product_branch_fkey','product_units_barcodes','products',ARRAY['product_id','branch_id'],ARRAY['id','branch_id']),
    ('stock_movements_product_branch_fkey','stock_movements','products',ARRAY['product_id','branch_id'],ARRAY['id','branch_id']),
    ('chart_of_accounts_parent_branch_fkey','chart_of_accounts','chart_of_accounts',ARRAY['parent_id','branch_id'],ARRAY['id','branch_id']),
    ('cash_accounts_gl_account_branch_fkey','cash_accounts','chart_of_accounts',ARRAY['gl_account_id','branch_id'],ARRAY['id','branch_id']),
    ('journal_lines_entry_branch_fkey','journal_lines','journal_entries',ARRAY['journal_entry_id','branch_id'],ARRAY['id','branch_id']),
    ('journal_lines_account_branch_fkey','journal_lines','chart_of_accounts',ARRAY['gl_account_id','branch_id'],ARRAY['id','branch_id']),
    ('lah_alayh_ledger_party_branch_fkey','lah_alayh_ledger','parties',ARRAY['party_id','branch_id'],ARRAY['id','branch_id']),
    ('lah_alayh_ledger_journal_branch_fkey','lah_alayh_ledger','journal_entries',ARRAY['journal_entry_id','branch_id'],ARRAY['id','branch_id']),
    ('vouchers_party_branch_fkey','vouchers','parties',ARRAY['party_id','branch_id'],ARRAY['id','branch_id']),
    ('vouchers_cash_branch_fkey','vouchers','cash_accounts',ARRAY['cash_account_id','branch_id'],ARRAY['id','branch_id']),
    ('vouchers_journal_branch_fkey','vouchers','journal_entries',ARRAY['journal_entry_id','branch_id'],ARRAY['id','branch_id']),
    ('sales_invoices_customer_branch_fkey','sales_invoices','parties',ARRAY['customer_party_id','branch_id'],ARRAY['id','branch_id']),
    ('sales_invoices_journal_branch_fkey','sales_invoices','journal_entries',ARRAY['journal_entry_id','branch_id'],ARRAY['id','branch_id']),
    ('sales_invoices_cashier_branch_fkey','sales_invoices','users',ARRAY['cashier_user_id','branch_id'],ARRAY['id','branch_id']),
    ('sales_invoice_items_invoice_branch_fkey','sales_invoice_items','sales_invoices',ARRAY['invoice_id','branch_id'],ARRAY['id','branch_id']),
    ('sales_invoice_items_product_branch_fkey','sales_invoice_items','products',ARRAY['product_id','branch_id'],ARRAY['id','branch_id']),
    ('sales_payments_invoice_branch_fkey','sales_payments','sales_invoices',ARRAY['invoice_id','branch_id'],ARRAY['id','branch_id']),
    ('sales_payments_cash_branch_fkey','sales_payments','cash_accounts',ARRAY['cash_account_id','branch_id'],ARRAY['id','branch_id']),
    ('sync_operation_receipts_idempotency_branch_fkey','sync_operation_receipts','sync_idempotency',ARRAY['idempotency_key','branch_id'],ARRAY['idempotency_key','branch_id'])
),
actual_fk AS (
  SELECT c.conname, c.conrelid::regclass::text AS child_table,
         c.confrelid::regclass::text AS parent_table,
         pg_get_constraintdef(c.oid, true) AS definition,
         c.convalidated
  FROM pg_constraint c
  JOIN pg_namespace n ON n.oid=c.connamespace
  WHERE n.nspname='public' AND c.contype='f'
),
fk_audit AS (
  SELECT e.*, a.definition, a.convalidated,
         (a.conname IS NOT NULL) AS constraint_name_found,
         (a.conname IS NOT NULL AND a.child_table=e.child_table
          AND a.parent_table=e.parent_table
          AND a.definition LIKE '%(' || array_to_string(e.child_cols, ', ') || ')%'
          AND a.definition LIKE '%REFERENCES ' || e.parent_table || '(' || array_to_string(e.parent_cols, ', ') || ')%') AS definition_matches
  FROM expected_fk e LEFT JOIN actual_fk a ON a.conname=e.name
),
required_unique(name, table_name) AS (
  VALUES
    ('products_id_branch_key','products'),
    ('users_id_branch_key','users'),
    ('product_units_barcodes_id_branch_key','product_units_barcodes'),
    ('chart_of_accounts_id_branch_key','chart_of_accounts'),
    ('journal_entries_id_branch_key','journal_entries'),
    ('parties_id_branch_key','parties'),
    ('cash_accounts_id_branch_key','cash_accounts'),
    ('sales_invoices_id_branch_key','sales_invoices'),
    ('sync_idempotency_key_branch_key','sync_idempotency')
),
unique_audit AS (
  SELECT r.name,r.table_name,
         EXISTS (SELECT 1 FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
                 WHERE n.nspname='public' AND c.conname=r.name AND c.contype='u') AS present
  FROM required_unique r
),
branch_columns AS (
  SELECT x.table_name, x.column_name,
         (c.column_name IS NOT NULL) AS present,
         COALESCE(c.is_nullable='NO',false) AS not_null
  FROM (VALUES ('journal_lines','branch_id'),('sales_invoice_items','branch_id'),('sales_payments','branch_id')) x(table_name,column_name)
  LEFT JOIN information_schema.columns c ON c.table_schema='public' AND c.table_name=x.table_name AND c.column_name=x.column_name
),
trigger_audit AS (
  SELECT x.trigger_name,
         EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_class cl ON cl.oid=t.tgrelid
                 JOIN pg_namespace n ON n.oid=cl.relnamespace
                 WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgname=x.trigger_name) AS present
  FROM (VALUES ('trg_set_journal_line_branch'),('trg_set_sales_invoice_item_branch'),('trg_set_sales_payment_branch'),
               ('trg_journal_entry_status_balanced'),('trg_journal_lines_balanced')) x(trigger_name)
),
core_counts AS (
  SELECT jsonb_build_object(
    'branches',(SELECT count(*) FROM branches),
    'users',(SELECT count(*) FROM users),
    'products',(SELECT count(*) FROM products),
    'parties',(SELECT count(*) FROM parties),
    'chart_of_accounts',(SELECT count(*) FROM chart_of_accounts),
    'cash_accounts',(SELECT count(*) FROM cash_accounts),
    'journal_entries',(SELECT count(*) FROM journal_entries),
    'journal_lines',(SELECT count(*) FROM journal_lines),
    'sales_invoices',(SELECT count(*) FROM sales_invoices),
    'sales_invoice_items',(SELECT count(*) FROM sales_invoice_items),
    'sales_payments',(SELECT count(*) FROM sales_payments),
    'stock_movements',(SELECT count(*) FROM stock_movements),
    'sync_idempotency',(SELECT count(*) FROM sync_idempotency),
    'sync_operation_receipts',(SELECT count(*) FROM sync_operation_receipts)
  ) AS data
),
baseline AS (
  SELECT jsonb_build_object(
    'branches_without_all_12_gl_accounts',
      (SELECT count(*) FROM branches b WHERE
        (SELECT count(*) FROM chart_of_accounts a WHERE a.branch_id=b.id AND a.code IN
          ('1000','1010','1020','1030','1040','1050','1100','2000','3000','4000','5000','1200')) <> 12),
    'branches_without_all_6_cash_accounts',
      (SELECT count(*) FROM branches b WHERE
        (SELECT count(*) FROM cash_accounts c WHERE c.branch_id=b.id AND c.code IN
          ('CASH-MAIN','CASH-DRAWER','JAWALI','JAIB','FLOUSK','KURAIMI')) <> 6),
    'gl_account_rows',(SELECT count(*) FROM chart_of_accounts),
    'cash_account_rows',(SELECT count(*) FROM cash_accounts)
  ) AS data
),
journal_integrity AS (
  SELECT jsonb_build_object(
    'posted_unbalanced_or_empty',
      (SELECT count(*) FROM journal_entries je
       WHERE je.status='POSTED' AND
         ((SELECT count(*) FROM journal_lines jl WHERE jl.journal_entry_id=je.id) < 2
          OR (SELECT COALESCE(sum(jl.debit),0) FROM journal_lines jl WHERE jl.journal_entry_id=je.id)
             <> (SELECT COALESCE(sum(jl.credit),0) FROM journal_lines jl WHERE jl.journal_entry_id=je.id))),
    'invalid_ledger_amounts',
      (SELECT count(*) FROM lah_alayh_ledger
       WHERE alayh_amount < 0 OR lah_amount < 0
          OR (COALESCE(alayh_amount,0)=0 AND COALESCE(lah_amount,0)=0))
  ) AS data
)
SELECT jsonb_pretty(jsonb_build_object(
  'audit_name','NEON_POST_MIGRATION_DEEP_AUDIT_READ_ONLY',
  'database',current_database(),
  'checked_at',current_timestamp,
  'postgres_version',version(),
  'current_role',current_user,
  'role_flags',(SELECT jsonb_build_object('superuser',r.rolsuper,'createdb',r.rolcreatedb,'createrole',r.rolcreaterole,'login',r.rolcanlogin)
                FROM pg_roles r WHERE r.rolname=current_user),
  'core_exact_row_counts',(SELECT data FROM core_counts),
  'expected_branch_foreign_keys',(SELECT jsonb_agg(jsonb_build_object(
      'constraint',name,'child',child_table,'parent',parent_table,
      'present',constraint_name_found,'definition_matches',definition_matches,
      'validated',convalidated,'definition',definition) ORDER BY name) FROM fk_audit),
  'missing_or_mismatched_branch_foreign_keys',(SELECT count(*) FROM fk_audit WHERE NOT COALESCE(definition_matches,false) OR NOT COALESCE(convalidated,false)),
  'required_composite_unique_keys',(SELECT jsonb_agg(jsonb_build_object('constraint',name,'table',table_name,'present',present) ORDER BY name) FROM unique_audit),
  'missing_composite_unique_keys',(SELECT count(*) FROM unique_audit WHERE NOT present),
  'required_child_branch_columns',(SELECT jsonb_agg(jsonb_build_object('table',table_name,'column',column_name,'present',present,'not_null',not_null) ORDER BY table_name) FROM branch_columns),
  'missing_or_nullable_child_branch_columns',(SELECT count(*) FROM branch_columns WHERE NOT present OR NOT not_null),
  'required_triggers',(SELECT jsonb_agg(jsonb_build_object('trigger',trigger_name,'present',present) ORDER BY trigger_name) FROM trigger_audit),
  'missing_triggers',(SELECT count(*) FROM trigger_audit WHERE NOT present),
  'baseline_accounting',(SELECT data FROM baseline),
  'journal_and_ledger_integrity',(SELECT data FROM journal_integrity),
  'all_public_foreign_keys',(SELECT jsonb_agg(jsonb_build_object('name',conname,'child',child_table,'parent',parent_table,'validated',convalidated,'definition',definition) ORDER BY child_table,conname) FROM actual_fk),
  'public_table_count',(SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'),
  'extensions',(SELECT jsonb_agg(jsonb_build_object('name',extname,'version',extversion) ORDER BY extname) FROM pg_extension)
)) AS audit_report;
