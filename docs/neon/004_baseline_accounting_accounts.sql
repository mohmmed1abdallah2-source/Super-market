-- Migration 004: idempotent baseline chart-of-accounts and cash/wallet accounts.
-- Creates baseline accounts only for branches that already exist.
-- Does not create demo branches, users, products, parties, or opening balances.
BEGIN;

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
  (id, branch_id, code, name_ar, account_kind, wallet_provider, gl_account_id, currency)
SELECT
  b.id || ':' || seed.code,
  b.id,
  seed.code,
  seed.name_ar,
  seed.account_kind,
  seed.wallet_provider,
  coa.id,
  'YER'
FROM branches b
CROSS JOIN (VALUES
  ('CASH-MAIN', 'الصندوق الرئيسي', 'CASH_DRAWER', NULL::VARCHAR(20), '1000'),
  ('CASH-DRAWER', 'درج الكاشير', 'CASH_DRAWER', NULL::VARCHAR(20), '1010'),
  ('JAWALI', 'محفظة جوالي', 'WALLET', 'JAWALI', '1020'),
  ('JAIB', 'محفظة جيب', 'WALLET', 'JEEB', '1030'),
  ('FLOUSK', 'محفظة فلوسك', 'WALLET', 'FLOOSAK', '1040'),
  ('KURAIMI', 'محفظة كريمي', 'WALLET', 'KURAIMI', '1050')
) AS seed(code, name_ar, account_kind, wallet_provider, gl_code)
JOIN chart_of_accounts coa
  ON coa.branch_id = b.id AND coa.code = seed.gl_code
ON CONFLICT (branch_id, code) DO NOTHING;

COMMIT;
