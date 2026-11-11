# Changelog

All notable project changes are documented in this file.

The format follows Keep a Changelog. Version numbers will be assigned when releases are cut.

## [Unreleased] — Iteration 2

### Project-wide documentation
- Added `docs/PROJECT_STATUS_AND_ROADMAP.md` as the single project-wide status and delivery roadmap, covering Flutter, SQLite, Firebase, POS/ledger, PDF, Dart API, PostgreSQL/Neon, multi-store isolation, CI, security, deployment and acceptance gates.
- Appended a dated entry to `DEVELOPMENT_LOG.md` recording the repository review, documentation-only scope of this update, owner-reported Neon results, and explicit unverified/pending items.

### Neon setup progress
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
