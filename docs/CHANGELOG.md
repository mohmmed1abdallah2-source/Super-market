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


### 2026-11-13 — Iteration 3: purchase and FEFO domain foundation
- Added a pure server calculator for purchase quantities with bonus, effective pack/base cost, weighted-average base-unit cost, and FEFO carton-unpack planning.
- Added unit tests for bonus arithmetic, discount bounds, weighted average, FEFO ordering, expiry exclusion, and insufficient stock.
- Added `docs/ITERATION_03_HANDOVER_AND_STATE.md` documenting the inspected baseline, implementation boundaries, test status, and exact next developer entry point.
- This milestone does not add schema migrations, API routes, SQLite tables, UI, or sync operation types. The live sale transaction is not yet wired to FEFO.
- Tests and analysis are authored/pending execution; no Neon or SQLite database was changed.


## 2026-11-13 — Iteration 3 schema milestone

- Added additive Neon migration `007_fefo_inventory_and_purchases_schema.sql` for warehouses, locations, FEFO batches, inventory operations, purchasing, and cost history.
- Extended the existing `stock_movements` table rather than creating a parallel ledger; added append-only UPDATE/DELETE protection.
- Added rollback-only SQL isolation test script `008_inventory_branch_isolation_tests.sql`.
- Added branch-aware composite references and fixed the new parent-key order so referenced composite keys exist.
- Verification: SQL files added to the work branch only. They have not been executed against PostgreSQL/Neon. No production data was changed. Runtime validation is pending PostgreSQL 18 / disposable database execution.


## 2026-11-13 — Iteration 3 database, contracts and read API

- Added and successfully validated migration 007 plus rollback-only SQL assertions 008 against disposable PostgreSQL 18.7 in GitHub Actions. No Neon production database was changed.
- Added branch-scoped purchase payment fields and cash-account composite FK to the new purchase invoice schema.
- Added decimal-safe inventory/purchase DTOs and JSON round-trip tests.
- Fixed the malformed duplicate source tail in `MoneyAmount`, the zero-value constant evaluation, and purchase-line money arithmetic type mismatch.
- Added branch-scoped read repository/routes for warehouses, locations, batches, movements, stocktaking sessions and shortage suggestions.
- Added corresponding API client methods. Write methods currently have client contracts only; server writes, sync integration and SQLite integration are pending.


## 2026-11-13 — SQLite Iteration 3 schema

- Added additive SQLite schema v2 for local warehouses, locations, FEFO batches, purchase documents, stocktaking, disposals, transfers, fridge logs and cost history.
- Added exact TEXT quantity/cost columns while preserving the legacy REAL columns and existing data.
- Added an additive v1→v2 upgrade path and a fresh-schema test.
- Validation: server and shared-contract CI tests passed; final Flutter analyze/test/build result for this commit is pending.


## 2026-11-15

- Tightened PostgreSQL FEFO batch and stocktaking constraints so loose base quantities remain below one pack conversion factor.
- Expanded rollback-only SQL test 008 with negative loose quantity and full-pack overflow regression cases.
- Recorded the verified migration table inventory and current execution limitations in the Iteration 3 handover.


### 2026-11-15 — Neon production recovery preparation
- Created a manual pre-Iteration-3 baseline snapshot on Neon production and recorded its exact ID in the recovery runbook.
- Attempted branch protection and scheduled backups; both were blocked by current project-plan capabilities. Production remains unprotected and automatic snapshots remain disabled.
- No migration or SQL data change was applied to production. Restore has not been rehearsed.


### 2026-11-15 — Snapshot restore rehearsal
- Restored the manual baseline snapshot and verified the restored branch schema plus selected read-only row counts against production.
- Neon restore finalization temporarily swapped the default production branch name/role; the original branch ID was immediately reinstated as `production` and default, and the restored branch was renamed as a non-default rehearsal branch. Both states were verified afterward.
- The rehearsal branch is retained pending explicit cleanup approval. No production migration or SQL write was performed.


### 2026-11-15 — Post-restore endpoint review
- Found that Neon restore finalization moved the original read-write endpoint to the rehearsal branch and created a new endpoint on production. Application routing via the old endpoint is therefore potentially affected; application environment was not inspected.
- No endpoint was moved or deleted. Endpoint reassociation is documented as pending explicit approval because it causes a brief connection interruption.


### 2026-11-15 — Neon production endpoint reassociation
- Removed the temporary read-write endpoint created on production during snapshot restore finalization.
- Reattached the original endpoint `ep-young-scene-bab6kmsp` to the original production branch `br-empty-brook-bab988pu` after explicit user approval.
- Read-back verification confirms the original endpoint-to-production association and confirms production remains ready, primary, and default. The audit and restore-rehearsal branches were retained.
- No production SQL, schema migration, or row data was changed. Application environment variables and end-to-end connectivity were not inspected or tested; application connectivity must not be marked verified from this control-plane correction alone.


## 2026-11-15 — Iteration 3 CI coverage
- Expanded the Flutter/server validation workflow to run on the Iteration 3 work branch.
- Moved its disposable PostgreSQL service to version 18 and included migrations/tests 003, 004, 006, 007 and 008 in the server validation database setup.
- Commit: `fe9dde48836e554fad7f6b33ebec85732deaef18`.
- CI execution is pending/unverified at this entry; this change alone is not a test pass.
- No Neon production migration or deployment was performed.


## 2026-11-15 — Iteration 3 FEFO sale posting
- Integrated FEFO batch row locking/allocation, carton opening, batch balances, sales-item batch allocations and append-only stock movements into the existing sale transaction.
- Added sale movement rows for legacy non-batch-tracked products and used allocated batch costs for FEFO line COGS.
- Validation remains pending: no repository-level PostgreSQL integration result or completed CI run is claimed. Live financial journal arithmetic still uses `double`.


## 2026-11-15 — FEFO warehouse eligibility
- Restricted FEFO allocation to branch-owned sellable warehouses, with optional explicit `warehouseId` scoping.
- Products with batch records only in non-sellable warehouses no longer bypass FEFO by falling back to aggregate stock.
- Commit: `890e29fbb3d4bd2fb24399466f87c2b349a3342a`; runtime validation pending.


## 2026-11-15 — Selected warehouse validation
- Validated explicit sale warehouse IDs against the authenticated branch and sellable/active state.
- Explicit-warehouse sales fail closed if no FEFO batch records exist for the product, instead of silently consuming unlocated aggregate stock.
- Commit: `efefb0c229bff44550557a18b97411611a0e6800`; runtime validation pending.


## 2026-11-15 — Purchase invoice posting
- Added authenticated, idempotent purchase invoice posting endpoint.
- Added atomic supplier invoice, FEFO batch, stock movement, weighted-cost, cash account, supplier ledger and balanced journal writes.
- Added purchase-order received-quantity tracking migration 009 and receipt reconciliation.
- Added PostgreSQL integration coverage for replay, fractional packs, journal balance, supplier balance and purchase-order completion. Execution is pending the PostgreSQL-enabled CI result.
- No production migration or deployment.


## 2026-11-15 — Supplier purchase returns
- Added transactional supplier purchase return endpoint with batch/invoice linkage validation, over-return protection, carton/loose quantity handling, stock movement, supplier ledger credit and balanced journal.
- Return valuation follows current moving-average carrying cost; cash refunds are not included.
- Sale stock quantity checks and deductions now persist exact decimal base quantities.
- PostgreSQL 18 CI run #197: server analysis passed and 25 tests passed; Flutter analyze/tests, Web and Windows passed, Android APK still running at documentation time.
- No production migration or deployment.


## 2026-11-15 — Validation result
- Flutter validation run #197 completed successfully, including Android release APK, Windows, Web, PostgreSQL 18 setup, Dart server analysis and 25 server tests.
- This is validation of the feature branch only, not a production deployment.


## 2026-11-15 — CI verification and Delivery Gates alignment
- PostgreSQL-enabled Flutter validation run #197 completed successfully: 25 server tests, Dart/Flutter analysis and tests, Android release APK, Windows and Web builds.
- Added the file_picker compile SDK 36 workaround to Delivery Gates so its Android build uses the same SDK compatibility fix as the primary validation workflow.
- Iteration 3 remains in progress; remaining sync, local SQLite, inventory write flows, UI/PDF and sales money precision work is still open.


## 2026-11-23 — Sync operation payload identity
- Added migration 010 for SHA-256 payload identity on sync operation receipts.
- Existing operation UUID replay now checks operation type and canonical payload hash for receipts written after migration 010; mismatches return an operation-ID conflict instead of being silently acknowledged.
- Added PostgreSQL integration coverage for same-payload replay and changed-payload rejection. First CI attempt found a missing hash argument in direct sale receipt creation; follow-up fix is awaiting CI verification.
- Disposable PostgreSQL 18 schema workflow #8 passed. No production database changes.


## 2026-11-23 — Sync operation receipt identity
- Added migration 010 and canonical payload hashing for sync operation receipts. Operation UUID replay now checks the operation type and stored payload hash; mismatched reuse returns HTTP 409.
- Added a transaction-scoped advisory lock by branch and operation UUID to serialize concurrent batch replay and avoid duplicate application before receipt creation. Direct sale posting uses the same identity guard.
- Added a PostgreSQL integration test for concurrent same-payload requests and changed-payload rejection.
- PostgreSQL 18 CI run #208 applied migration 010 on a disposable database and passed all 26 server tests, including the new sync replay test and purchase invoice/return tests. Flutter analyze/tests and Web build passed; Android and Windows build jobs were still running at documentation time.
- Delivery Gates #138 passed server analysis/unit tests and shared-contract tests; five PostgreSQL integration tests were skipped in that workflow because PGTEST_HOST is not configured.
- Legacy receipts with NULL payload hashes retain same-type replay compatibility; their historic payload identity cannot be reconstructed. No production database changes.


## 2026-11-23 — Purchase receipt payload identity (validation pending)
- Purchase invoice and purchase return receipts now persist canonical JSON payload hashes in migration 010 and reject operation-ID reuse with a different type/payload. Both posting paths check the receipt before returning an existing document. Purchase return advisory lock key interpolation was corrected.
- Added PostgreSQL integration assertions for same-payload replay with a new idempotency key and changed-payload rejection for invoices and returns.
- Delivery Gates #141 passed server analysis/tests and shared contracts; PostgreSQL-only tests were skipped in that workflow. The PostgreSQL-enabled run for current source commit c36c130f is pending. Run #208 passed 26 PostgreSQL tests on the earlier sales/batch identity implementation, before this purchase-specific extension.
- No production database changes.


## 2026-11-23 — CI queue correction
- PostgreSQL-enabled Flutter Validation run #211 was cancelled before its PostgreSQL test job started when a later documentation commit arrived. It must not be counted as a pass or failure.
- Run #212 is queued for the same application source as commit c36c130f0e7611d535f6b1ced4e43e85997ad03d; subsequent commits 8bcc22c and 606a5cd only updated documentation. Run #212 is the pending PostgreSQL verification for the purchase invoice/return payload-hash changes.
- Delivery Gates #141 passed server analysis/unit tests and shared-contract tests on source c36c130f. The PostgreSQL integration suite was skipped in that workflow because PGTEST_HOST is not configured.
- The earlier PostgreSQL-enabled run #208 passed all 26 server tests, but it predates the purchase-specific payload-hash extension.


## 2026-11-23 — PostgreSQL validation completed for purchase receipt identity
- Flutter Validation run #212 (commit 8bcc22c; application source c36c130f) successfully applied migrations including 010 to disposable PostgreSQL 18 and passed all 26 server tests. This includes the new same-operation/new-idempotency-key replay and changed-payload rejection assertions for purchase invoices and purchase returns, plus sync batch operation identity, sale retry, voucher and mixed-tender tests.
- In the same run, Dart server analysis passed, Flutter analysis/tests passed, and the Web build/artifact passed. Android release APK and Windows build were still in progress when this note was written; therefore the full workflow was not yet complete.
- Delivery Gates #141 passed Dart analysis/tests and shared-contract tests for source c36c130f. Delivery Gates #142 also passed the Dart job; its Android APK build hit Maven Central HTTP 429 rate limiting while fetching Kotlin Gradle artifacts. The failed APK job was re-run; this is an external dependency throttling failure, not a source compilation failure.
- Latest branch commit 4da4118c only updates documentation after the tested application source; no source changes occurred after c36c130f.
- No Neon Production DDL/DML, deployment, or release was performed.


## 2026-11-23 — Purchase Sync Batch and offline queue

- Added atomic Sync Batch dispatch for purchase invoices and supplier returns by reusing the existing posting repositories inside the batch transaction.
- Added PostgreSQL rollback, retry, payload-conflict and branch-scope integration coverage. Flutter Validation #219 passed all 26 server tests against disposable PostgreSQL 18.
- Added a generic local queue envelope for the five operation types currently accepted by the server batch endpoint; validation is pending in Flutter Validation #223 and Delivery Gates #153.
- Stocktake approval, disposal and warehouse transfer posting/sync remain outstanding; client DTOs and local tables alone do not establish server support.


## 2026-11-23

- Implemented transactional server posting for stocktake approval and inventory disposal, including batch-level quantity reconciliation, aggregate stock updates, movement ledger entries, balanced journal entries, branch-scoped approval users, and replay-safe approved-document handling.
- Added migration 011 for dedicated stocktake-surplus and inventory-loss accounts, wired both operations into Sync Batch and the offline queue, and added PostgreSQL integration coverage. Validation is pending; no CI pass is claimed yet.


### Validation update — 2026-11-23

- PostgreSQL-enabled Flutter Validation #228 passed migration/schema setup on PostgreSQL 18, Dart server analysis, and all 30 server tests, including both new stocktake/disposal approval integration tests and exact decimal valuation.
- Flutter analyze/tests and Web build passed in the same run; Android APK and Windows build were still in progress when this note was added.
- Verified source commit: `af1a60b0ddbd41fb8e647b1203d6541dae624bf5`. Production Neon was not migrated or modified.


### 2026-11-23 — Inter-warehouse stock transfer and batch sync

- Added branch-scoped, transactional `STOCK_TRANSFER` execution with source/destination warehouse validation, locked batch quantities, destination lot merge/create behavior, and paired `TRANSFER_OUT` / `TRANSFER_IN` movements in the existing stock ledger.
- Wired stocktake approval, disposal approval, and stock transfer through the same atomic Sync Batch transaction and added the authenticated transfer endpoint.
- Enabled transfer operations in the durable SQLite offline queue using stable operation IDs and accepted-ID-based acknowledgment.
- Added a PostgreSQL integration test covering all three operations in one batch, idempotent replay, batch/cost/expiry preservation, and rollback. CI is pending; this entry will be updated with the actual result after workflow inspection.
- Production Neon and deployments remain untouched.


## 2026-11-23 — Current sync and isolation review

- Added `docs/CURRENT_SYNC_AND_ISOLATION_AUDIT.md` documenting the current Sync Batch contract, the successful 31-test PostgreSQL CI run, and the distinction between branch isolation and the approved multi-store architecture.
- Updated README architecture and verification statements to distinguish the PostgreSQL API path from retained Firebase code and to avoid claiming production-ready authentication or database-per-store isolation.
- Clarified that the current server uses one PostgreSQL connection and static branch tokens; a control plane, user/membership authentication, database-per-store routing, and independent local SQLite context per store remain unfinished.
- CI evidence reviewed: Flutter Validation #45255890755 and Delivery Gates #45255891002 both passed on source commit `12e1e9fe7c08aebb315909cec37ade56646d0397`; PostgreSQL integration suite reported 31 passed tests.
- No production database changes, Neon migrations, deployment, or release.

- Added transactional creation of counted stocktaking sessions, safe replay checks, API route wiring, OpenAPI contract, and PostgreSQL integration coverage. CI verification is pending on the new source commit.

### 2026-11-24 — Live sale and voucher fixed-scale arithmetic

- Migrated live sale invoice, discount, tender, credit-limit, cash-account, COGS and journal aggregation from binary floating point to `MoneyAmount` and `ScaledDecimal`.
- Migrated voucher amount and cash-balance/journal/ledger writes to fixed-scale money strings.
- Fixed the fridge-temperature note SQL binding after the current PostgreSQL integration run exposed a missing note value; CI verification is pending.
- No production database or deployment changes.

### 2026-11-24 — Fixed-scale server posting and offline sync boundary

- Migrated live PostgreSQL sale and ledger/voucher posting calculations to fixed-scale money and decimal quantities.
- Enforced cash-vs-wallet account-kind validation in sale and voucher posting.
- Normalized legacy SQLite numeric payloads to explicit decimal strings at the sync boundary and added FAILED queue recovery coverage.
- Added fractional-sale, journal-balance, and payment-account mismatch regression assertions. PostgreSQL-enabled CI verification remains pending on source commit `20043d15`.


## 2026-11-24 — Control-plane/account-management foundation (in progress)

- Created isolated work branch `feature/control-plane-account-management` from `feature/multi-store-isolation-foundation` at reviewed HEAD `04bc6850f922461bbb96227bc444fd1795b7295c`.
- Added a dedicated control-plane PostgreSQL migration for accounts, verified identity mappings, store directory, account/store memberships, opaque database-secret references and hashed store-scoped sessions.
- Added Dart domain contracts for verified account identities, membership roles, store lifecycle and the control-plane repository boundary, plus unit tests.
- Documented the deployment boundary: migration is for a separate control-plane database only; no production database was modified and no database provisioning or session issuance is claimed.
- SQL execution, Dart test execution and API integration are pending CI and follow-up implementation.
