-- Iteration 3 / Migration 011: dedicated inventory adjustment accounts.
-- Additive and branch-scoped. No production execution is implied by this file.
BEGIN;

DO $$
BEGIN
  IF to_regclass('public.branches') IS NULL
     OR to_regclass('public.chart_of_accounts') IS NULL THEN
    RAISE EXCEPTION 'Migration 011 requires the ERP core and ledger schema';
  END IF;
END $$;

INSERT INTO chart_of_accounts (branch_id, code, name_ar, account_type)
SELECT b.id, seed.code, seed.name_ar, seed.account_type
FROM branches b
CROSS JOIN (VALUES
  ('4100', 'أرباح فروقات الجرد', 'REVENUE'),
  ('5100', 'خسائر نقص وإتلاف المخزون', 'EXPENSE')
) AS seed(code, name_ar, account_type)
ON CONFLICT (branch_id, code) DO NOTHING;

COMMIT;
