# Changelog

All notable project changes are documented in this file.

The format follows Keep a Changelog. Version numbers will be assigned when releases are cut.

## [Unreleased] — Iteration 2

### Project-wide documentation
- Added `docs/PROJECT_STATUS_AND_ROADMAP.md` as the single project-wide status and delivery roadmap, covering Flutter, SQLite, Firebase, POS/ledger, PDF, Dart API, PostgreSQL/Neon, multi-store isolation, CI, security, deployment and acceptance gates.
- Appended a dated entry to `DEVELOPMENT_LOG.md` recording the repository review, documentation-only scope of this update, owner-reported Neon results, and explicit unverified/pending items.

### Neon setup progress
- User supplied the 40-row routine-name inventory. Three names are ledger-related (`assert_journal_entry_balanced`, `journal_entry_status_balance_constraint`, `journal_lines_balance_constraint`); the remaining names appear to be `pgcrypto` routines, with repeated names likely representing overloads. Signatures and definitions remain unreviewed.
- Owner reported successful verification of Neon relationships, keys and indexes; detailed query outputs have not been independently reviewed.
- Added schema-only Neon SQL scripts under `docs/neon/` without changing the original development/test migrations.
- Added `docs/neon/NEON_SETUP_PROGRESS.md` to record the owner-reported Neon project setup, successful execution of both schema-only scripts, reported 18-table result, verification checklist, deployment dependencies and remaining multi-store implementation. Neon execution results are owner-reported and have not been independently inspected.

### Added
- Added the Iteration 2 architecture specification for POS, scale barcode parsing, party balances, vouchers, accounting journal, batch synchronization and official/thermal printing.
- Added the OpenAPI 3.1 contract at `docs/openapi_v1.yaml` for parties, party statements, vouchers, cash accounts, sales invoices and batch sync.
- Added PostgreSQL foundation migration `20261109_001_erp_core.sql` because the repository did not contain the prerequisite server migration; it creates branch, product, unit-barcode and stock foundations with stable text identifiers.
- Added PostgreSQL migration `20261109_002_pos_sales_and_lah_alayh_ledger.sql` for balanced journal entries, party ledger, cash/wallet accounts, vouchers, invoices, payments and idempotency receipts.
- Added Dart server domain, use cases, PostgreSQL repositories, Shelf routes and server entry point.
- Added shared contracts and an HTTP API client with required branch context and idempotency headers.
- Added Flutter local POS/ledger engine, provider, keyboard-safe sheets, responsive cashier layout, party/voucher workflows and official/thermal PDF builders.
- Added Flutter and server unit-test files and a CI job to analyze/test the Dart server.
- Defined stable operation UUIDs and mandatory `Idempotency-Key` headers for write operations.
- Defined the server-side PostgreSQL target while preserving the current SQLite offline-first application as the local operational database.


- Added `docs/MULTI_STORE_ISOLATION_ARCHITECTURE.md` documenting the owner-to-many-stores flow, a separate PostgreSQL database and SQLite file per store, a minimal account/store control plane, secure store-scoped API routing, preservation of existing data, backup/restore requirements and the mandatory cross-store isolation test matrix. This is an architecture decision and implementation plan; multi-store runtime support is not yet implemented.
- Added the cross-platform consistency requirement: Windows and Android use per-store SQLite files, Web uses a browser-compatible per-store persistence adapter (IndexedDB-based), and all platforms synchronize through the same store-scoped API with idempotent operations and explicit conflict handling. This documents the target architecture; it does not claim the adapters or synchronization are implemented.

### Compatibility
- Existing Iteration 1 Flutter source files and SQLite schema remain the compatibility baseline.
- The repository currently uses a root Flutter application layout. The planned `server/` and `packages/` directories are new work and are not represented as implemented until their code and tests are added.
- Existing Firebase synchronization is not removed by this documentation change.

### Verification
- Documentation files were committed to the feature branch.
- Implementation files have been added, but no PostgreSQL migration has yet been applied to a live database.
- CI analysis and test results are pending; no test pass is claimed until GitHub Actions completes.
- Full live integration verification still requires a PostgreSQL instance, branch-scoped credentials, a connected API client session and end-to-end test data.


### Neon — branch isolation and accounting setup (prepared, not applied)
- Added `docs/neon/003_branch_consistent_composite_constraints.sql` with branch-scoped composite keys/foreign keys across inventory, accounting, party ledger, vouchers, sales, payments and cashier references.
- Added database triggers to derive `branch_id` for journal lines, invoice items and sales payments, allowing existing inserts to omit the new column.
- Added supporting indexes and removed the duplicate `idx_journal_entries_doc` index that duplicates the journal document UNIQUE index.
- Added `docs/neon/004_baseline_accounting_accounts.sql` for idempotent per-existing-branch chart-of-accounts and cash/wallet baseline rows; it intentionally creates no sample business entities or opening balances.
- These are repository files only. They have not been executed against Neon; backup, constraint-name verification, SQL integration testing and post-migration checks remain mandatory.

### Neon — corrected post-migration audit
- Added `docs/neon/005_post_migration_deep_audit_read_only.sql`, a single read-only JSON audit for composite branch foreign keys (validated against actual ordered catalog column arrays), required unique keys, branch columns/triggers, exact core table counts, accounting baseline coverage, journal/ledger invariants, and current database-role flags.
- Fixed the FK audit to compare catalog column arrays rather than formatted constraint text, and aligned journal checks with the schema's `dr_amount` / `cr_amount` columns.
- The supplied earlier SQL Editor capture still showed the pre-003 single-column FK names and only two ledger triggers. It cannot establish whether the user's later migration execution succeeded; a fresh run of audit 005 is required. No live Neon execution is claimed.


### Neon — rollback-only integration test pack
- Added `docs/neon/006_branch_isolation_transactional_tests.sql` with temporary two-branch fixtures, same-branch positive paths, cross-branch FK rejection checks, parent-derived branch trigger checks, and an unbalanced posted-journal rejection check.
- The script is wrapped in a transaction and ends with `ROLLBACK`; it must be executed as one complete script against a disposable database with migrations 001–003 applied.
- The SQL is prepared but has not been run against PostgreSQL/Neon. No test pass is claimed. API authorization, sale atomicity, offline retry and multi-device sync are outside this SQL test pack.


### Neon — successful branch-isolation SQL test (owner-reported)
- The owner supplied the execution result for `docs/neon/006_branch_isolation_transactional_tests.sql`; all ten machine-readable assertions were `true`.
- Covered two temporary branches, balanced journal posting, parent-derived branch IDs, rejection of cross-branch journal accounts/products/payment accounts/idempotency receipts, valid same-branch payment, and rejection of an unbalanced posted journal.
- The output states that the test rows are temporary and removed by the final `ROLLBACK`.
- Status: **Owner-reported / output supplied: PASS**. The assistant did not execute the SQL or independently access Neon.
- This is database-constraint coverage only; API authorization, end-to-end sale atomicity, offline/multi-device synchronization and database-per-store isolation remain unverified.


### API integration source review
- Added `docs/API_INTEGRATION_REVIEW.md` describing the current branch-scoped API, transactional sale/batch source paths, local-first POS flow, and remaining production gaps.
- Recorded that current authentication is static branch-token plus `X-Branch-Id`, not verified account/store membership.
- Recorded that the API uses one PostgreSQL connection and the Flutter service still defaults to a shared `DatabaseHelper.instance`.
- Flagged Dart `double` monetary calculations for decimal/rounding hardening.
- Documentation-only review; no deployment or runtime test pass is claimed.

### Financial precision and sync contract review
- Added `docs/FINANCIAL_PRECISION_AND_SYNC_CONTRACT_REVIEW.md` documenting source findings for floating-point money calculations versus PostgreSQL fixed-scale numeric columns, sale change/payment reconciliation, idempotency scope, all-or-nothing batch transactions, and local queue acknowledgment/retry.
- Documentation-only review: no application code or Neon database changes, and no runtime test pass is claimed.

### Fixed-scale money primitive (incremental)
- Added shared `MoneyAmount` using integer ten-thousandths, exact decimal-string parsing, explicit four-place precision rejection, and half-away-from-zero multiplication rounding.
- Exported it through `core_contracts` and added unit tests.
- Existing sale/voucher posting still uses `double`; migration is intentionally incomplete pending coordinated client/server integration and compatibility tests. Tests are authored, not yet run.

### 2026-11-13 — Fixed-scale money parser and server test wiring
- Corrected the `MoneyAmount` decimal regex so ordinary digit sequences are parsed correctly.
- Added the shared `core_contracts` path dependency to the server package.
- Added server-side unit tests for exact arithmetic, scale-four serialization, rounding and invalid precision.
- The repository's sale and voucher posting paths still use `double`; tests are authored but unrun. No Neon or SQLite changes.

### 2026-11-13 — Exact sale calculation layer
- Added isolated `SaleMoneyCalculator` helpers using shared `MoneyAmount` for line totals, base quantities, inventory cost, sums and invoice/payment validation.
- Added server unit tests for exact arithmetic, reconciliation, discount bounds and precision rejection.
- The helper is not yet wired into the live PostgreSQL sale-posting method; that path still uses `double`. Tests are authored but unrun; no Neon/SQLite changes.

### 2026-11-13 — Re-check of numeric scales and driver contract
- Re-inspected the current sale repository, shared money type, helper/tests, and PostgreSQL migrations 001/002 before integration.
- Confirmed six-place database fields for stock, average unit cost and conversion factors; sale quantity is four-place, generated base quantity is six-place, and monetary fields are four-place.
- Identified that the isolated scale-four helper methods for base quantity/inventory cost are not suitable for six-place quantity/cost columns and must not be wired into inventory arithmetic as-is.
- The `postgres ^2.6.4` named substitution API is present, but exact decimal-string-to-`NUMERIC` binding has not been demonstrated by a repository integration test.
- No partial `_applySale` conversion was made. Next work must establish scale-aware decimal arithmetic and an actual PostgreSQL numeric binding test before the live sale transaction is changed.
- Source/schema review only; no runtime tests, Neon/SQLite changes, or successful posting claim.

### 2026-11-13 — Scale-aware decimal foundation
- Added and exported `ScaledDecimal`, a `BigInt`-backed decimal type with explicit field scale, strict precision validation, same-scale arithmetic, and explicit-result-scale multiplication rounding.
- Corrected `SaleMoneyCalculator` to use four-place sale quantities/unit prices, six-place conversion factors/base quantities/unit costs, and explicit four-place monetary result rounding.
- Added shared-package tests and expanded server calculator coverage for six-place conversion and signed half-away-from-zero rounding.
- This supersedes the earlier helper-only assumption that base quantities and inventory costs could be represented at scale four.
- The live `_applySale` transaction still uses `double`; no API, SQLite, Neon, or migration changes were made. PostgreSQL exact NUMERIC binding is not yet proven by an integration test. Tests are authored but unrun; financial precision remains an open release blocker.

 
### 2026-11-13 — Delivery gates
- Added `.github/workflows/delivery-gates.yml` for Flutter Android dependency resolution, formatting, analysis, tests, release APK artifact, and Dart API analysis/tests.
- Workflow targets only `feature/multi-store-isolation-foundation` pushes and pull requests, plus manual dispatch.
- Workflow has been added but has not run yet; no CI pass or APK artifact is claimed.
- Recorded a three-day delivery closeout plan and retained existing owner-reported Neon SQL test results without rerunning them.
