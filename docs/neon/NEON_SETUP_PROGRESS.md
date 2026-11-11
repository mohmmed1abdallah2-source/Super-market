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
| Constraints, indexes, views, functions, triggers audit | Pending |
| Production DB role and permissions | Pending |
| Dart server Neon TLS connection | Pending |
| API hosting and HTTPS | Pending |
| Flutter authentication and API wiring | Pending |
| Automated and end-to-end acceptance | Pending |
| Database-per-store isolation | Not implemented |
| Backup and restore drill | Pending |

**Next safe action:** complete the read-only structural audit in section 3. Only after reviewing those results should we proceed to API connection changes or create any baseline accounting data.
