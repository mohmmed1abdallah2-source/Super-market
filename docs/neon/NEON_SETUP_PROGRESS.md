# Neon PostgreSQL setup — execution log and remaining work

**Repository:** `mohmmed1abdallah2-source/Super-market`  
**Working branch:** `feature/multi-store-isolation-foundation`  
**Project/database reported by the owner:** Neon project `supermarket-erp`, branch `production`, database `neondb`  
**Status:** Initial schema migrations reported successfully applied by the owner; structural verification and application integration remain pending.

> Evidence convention: statements marked **Owner-reported** are based on the user's confirmation in ChatGPT. They have not been independently inspected inside the Neon account. Never treat them as independently verified deployment evidence.

## 1. Completed

1. The owner created the Neon project `supermarket-erp` and selected the `production` branch and `neondb` database (owner-reported).
2. The owner ran a basic SQL connectivity query:
   `SELECT version(), current_database(), current_timestamp;`
   and reported that it succeeded (owner-reported).
3. Two schema-only migration copies were added to this repository branch:
   - `docs/neon/001_erp_core_schema_only.sql`
   - `docs/neon/002_pos_ledger_schema_only.sql`
4. The schema-only copies intentionally omit development/demo rows from the original migrations. The original migration files under `server/migrations/` were left unchanged.
5. The owner reports that both schema-only scripts executed successfully in Neon SQL Editor.
6. The owner reports that the subsequent public-schema table listing returned **18 tables**.

## 2. Important migration notes

- Execute migration 001 before migration 002 on a new, empty target database.
- The schema-only copies do not insert the sample branch, sample owner user, sample products, product unit/barcodes, demo parties, chart-of-accounts rows, or cash/wallet account rows.
- In particular, the chart-of-accounts and cash-account tables exist but their baseline rows were intentionally not seeded in these schema-only files. Before live accounting or POS use, define and review a deliberate, versioned baseline-data migration. Do not assume the tables are ready for transactions merely because they exist.
- The original files in `server/migrations/` remain the development/integration-test migration source and contain their original seed statements. Do not run those original scripts against this Neon database unless the seed behavior has been explicitly reviewed and authorized.
- The two schema-only files are currently stored under `docs/neon/`; they are operator-run scripts, not yet wired into an automated production migration runner or migration-history mechanism.
- SQL Editor success and a table count do not alone prove all constraints, indexes, views, functions, triggers, permissions, or application queries are correct.

## 3. Verification still required

**Update 2026-11-11:** The owner reports that relationship, key and index checks succeeded. These checks are marked complete based on the owner's report; the raw query output was not supplied for independent review.

Run these read-only checks in Neon SQL Editor and save the outputs in the deployment record:

1. List all tables in schema `public`.
2. List constraints and primary keys.
3. List foreign keys and confirm every intended relationship.
4. List indexes and verify uniqueness/index coverage.
5. List views, functions and triggers, including journal-balance enforcement.
6. Confirm no unintended business/demo rows exist in core tables:
   `branches`, `users`, `products`, and `parties`.
7. Confirm the database role used by the API is not a superuser and has only required privileges.
8. Confirm SSL/TLS is enabled for the server-to-Neon connection.

Do not insert production business data until these checks are reviewed.

## 4. Application and deployment work remaining

### Database connectivity
- Update the Dart server's PostgreSQL connection configuration for Neon TLS/SSL and its supported connection mode.
- Confirm the actual Dart PostgreSQL driver API/version supports the chosen Neon connection settings; do not assume a copied connection URI works with the current driver.
- Keep the database connection string and password in the API host's secret manager/environment only. Never commit them, put them in Flutter code, or paste them into chat.
- Use a least-privilege application role, not the Neon owner/superuser role.

### API hosting
- Choose and validate a separate API hosting provider. Neon hosts the PostgreSQL database; it does not by itself deploy the Dart Shelf API.
- Configure `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `ERP_BRANCH_TOKENS`, `PORT`, and `ERP_HOST` as appropriate for the selected host.
- Deploy the API behind HTTPS and verify its health endpoint.

### Flutter integration and acceptance
- Configure Flutter's API client to use the deployed HTTPS API URL, not the PostgreSQL URL.
- Implement a real authentication/session source for branch/store context; do not hardcode bearer tokens.
- Run Dart analysis, server unit tests and PostgreSQL integration tests.
- Run controlled end-to-end tests for create/read/update, sales, payments, ledger balancing, idempotent retries, offline queue recovery and multi-device sync.
- Verify backup creation and a restore drill before production use.

### Multi-store architecture
- The current schema and API are a single-database/branch-scoped foundation. They do **not** implement the approved database-per-store isolation architecture.
- Still required: separate control-plane database, accounts/stores/memberships, per-store database and least-privilege role provisioning, authenticated store routing, per-store local SQLite/IndexedDB context, safe adoption of existing local data, cross-store isolation tests and per-store backup/restore.
- Do not claim multi-store readiness until these are implemented and tested.

## 5. Safe operating rules

- Keep all work on `feature/multi-store-isolation-foundation`; do not modify or merge `main` without explicit approval.
- Before any future schema change, take/confirm a recoverable backup and inspect the target database state.
- Prefer additive, transactional, versioned migrations. Do not drop tables, truncate data, reset the Neon database, or rerun non-idempotent scripts on an already migrated database.
- If a migration fails, stop and inspect the exact error and transaction state before attempting a retry.
- Do not report a test as passed unless it was actually run and its result captured.

## 6. Current status summary

| Area | Status |
|---|---|
| Neon project and SQL connectivity | Owner-reported complete |
| Schema-only migration files | Added to feature branch |
| Migration 001 and 002 execution | Owner-reported successful |
| Public table count | Owner-reported: 18 |
| Constraints and indexes | Owner-reported complete; detailed output not reviewed |
| Functions / triggers / views inventory | Owner-reported: 40 / 5 / 1; definitions not reviewed |
| Production DB role and permissions | Pending |
| Dart server Neon TLS connection | Pending |
| API hosting and HTTPS | Pending |
| Flutter authentication and API wiring | Pending |
| Automated and end-to-end acceptance | Pending |
| Database-per-store isolation | Not implemented |
| Backup and restore drill | Pending |

**Function inventory received:** the user supplied 40 routine-name rows. Three names appear project/ledger-specific: `assert_journal_entry_balanced`, `journal_entry_status_balance_constraint`, and `journal_lines_balance_constraint`. The remaining names appear to be `pgcrypto` extension routines; repeated names likely represent overloaded signatures. The final displayed row omits its routine_type cell in the pasted table. No signatures or function bodies have been reviewed yet.

**Next safe action:** inspect the signatures and definitions of the three ledger-related functions, then review the five trigger definitions and the single view definition. Counts and names alone do not establish correctness. Do not proceed to API connection changes or baseline accounting data until this read-only review is complete.


## 2026-11-11 — Prepared branch-integrity and accounting baseline migrations

Two new operator-run SQL migrations were added to the feature branch after reviewing the live-schema outputs supplied by the owner:

- `docs/neon/003_branch_consistent_composite_constraints.sql`
  - Adds candidate composite unique keys `(id, branch_id)` to branch-owned parent tables.
  - Replaces single-column relationships with branch-aware composite foreign keys for products/units/stock, chart accounts, cash accounts, journal lines, party ledger, vouchers, sales invoices/items/payments, and cashier users.
  - Adds `branch_id` to child tables that previously lacked it (`journal_lines`, `sales_invoice_items`, `sales_payments`); BEFORE triggers derive it from the owning journal entry/invoice so existing application INSERT statements can omit it.
  - Adds supporting indexes and removes the exact duplicate non-unique index `idx_journal_entries_doc`, because the existing UNIQUE key already indexes the same columns.
  - Uses a transaction and fails if pre-existing child rows cannot inherit a branch. It is intended to be applied once, after a backup and after confirming constraint names against the target.

- `docs/neon/004_baseline_accounting_accounts.sql`
  - Idempotently inserts the reviewed baseline chart-of-accounts rows and six cash/wallet accounts for branches that already exist.
  - Does not create a demo branch, user, product, party, or opening balance.
  - Must be run only after the real first branch has been created. If run while `branches` is empty, it correctly inserts zero rows; it does not auto-seed branches created later.

**Important compatibility note:** Migration 003 adds database-managed `branch_id` columns to three child tables. The supplied INSERT patterns can continue omitting those columns because triggers populate them, but all application reads/updates and any code that assumes a fixed column list must be checked. This migration has been committed to GitHub only; it has NOT been run against Neon. No live database change is claimed.

**Index review:** `idx_journal_entries_doc` exactly duplicates the index created by UNIQUE `(branch_id, doc_type, doc_id)` and is dropped by migration 003. Other existing indexes are retained; supporting indexes for new composite foreign keys are added.

**Remaining before execution:** inspect current `pg_constraint` names and all branch-owned table relationships on the target; take/confirm a restorable backup; apply migration 003 once; run post-migration FK and cross-branch negative tests; create the real branch through the approved onboarding process; then apply migration 004 and verify expected account/cash rows. Do not run migration 004 before a real branch exists.

## 2026-11-11 — Corrected post-migration audit prepared

- Added `docs/neon/005_post_migration_deep_audit_read_only.sql` as a single read-only Neon audit report. It checks the exact expected composite foreign-key column pairs from migration 003 using PostgreSQL catalog metadata (not fragile string matching), required composite unique keys, `branch_id` child columns, triggers, exact core row counts, baseline account coverage, journal balance and ledger amount invariants, and current-role flags.
- Corrected the audit to use the actual journal amount columns `dr_amount` and `cr_amount`.
- The previously supplied SQL Editor capture shows all 18 core tables empty and still lists the original single-column foreign keys and only the two ledger-balance triggers. That capture therefore does **not** prove migration 003 was applied; it may predate the owner's later execution. A fresh run of audit 005 is required to establish the current state.
- Because the captured `branches` count is zero, migration 004 could not have inserted baseline chart/cash accounts at the time of that capture. After a real branch exists, rerun migration 004 only if its effects are absent; verify first and do not rerun blindly.
- The audit script has been committed to the feature branch. It has not been executed against Neon by the assistant. No production-readiness or migration-success claim is made.

**Next operator action:** run `docs/neon/005_post_migration_deep_audit_read_only.sql` in the intended Neon database and share its single JSON result. Do not run migration 003 again until the fresh report confirms it is absent. Do not create real production transactions until branch isolation, least-privilege role, TLS, backup/restore, and application integration are verified.
