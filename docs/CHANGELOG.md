# Changelog

All notable project changes are documented in this file.

The format follows Keep a Changelog. Version numbers will be assigned when releases are cut.

## [Unreleased] — Iteration 2

### Added
- Added the Iteration 2 architecture specification for POS, scale barcode parsing, party balances, vouchers, accounting journal, batch synchronization and official/thermal printing.
- Added the OpenAPI 3.1 contract at `docs/openapi_v1.yaml` for parties, party statements, vouchers, cash accounts, sales invoices and batch sync.
- Defined stable operation UUIDs and mandatory `Idempotency-Key` headers for write operations.
- Defined the server-side PostgreSQL target while preserving the current SQLite offline-first application as the local operational database.

### Compatibility
- Existing Iteration 1 Flutter source files and SQLite schema remain the compatibility baseline.
- The repository currently uses a root Flutter application layout. The planned `server/` and `packages/` directories are new work and are not represented as implemented until their code and tests are added.
- Existing Firebase synchronization is not removed by this documentation change.

### Verification
- Documentation files were committed to the feature branch.
- No Dart server, PostgreSQL migration, Flutter feature, or integration test is claimed as implemented by this documentation-only change.
- API deployment and schema validation remain pending until the corresponding server implementation is added.
