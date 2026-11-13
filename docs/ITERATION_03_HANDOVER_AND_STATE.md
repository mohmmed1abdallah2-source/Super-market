# Iteration 03 — Handover and implementation state

**Branch:** `feature/multi-store-isolation-foundation`  
**Status:** In progress — domain calculation foundation only  
**Last updated:** 2026-11-13

## 1. Baseline inspected before implementation

The following existing files were inspected on the work branch before adding Iteration 3 code:

- `docs/API_INTEGRATION_REVIEW.md`
- `docs/FINANCIAL_PRECISION_AND_SYNC_CONTRACT_REVIEW.md`
- `docs/neon/001_erp_core_schema_only.sql`
- `docs/neon/002_pos_ledger_schema_only.sql`
- `docs/neon/003_branch_consistent_composite_constraints.sql`
- `docs/neon/004_baseline_accounting_accounts.sql`
- `docs/neon/006_branch_isolation_transactional_tests.sql`
- `packages/core_contracts/lib/money_amount.dart`
- `packages/core_contracts/lib/scaled_decimal.dart`
- `server/lib/features/sales_and_sync/domain/sale_money_calculator.dart`
- `server/lib/features/sales_and_sync/data/postgres_sales_sync_repository.dart`
- `server/lib/features/sales_and_sync/domain/sales_sync_domain.dart`
- `server/bin/server.dart`
- `lib/data/database/database_helper.dart`
- `lib/data/database/schema_builder.dart`
- `lib/data/services/scale_pos_and_ledger_service.dart`
- `lib/core/pdf/official_report_template.dart`
- `packages/core_contracts/lib/core_contracts.dart`
- `server/pubspec.yaml`

### Confirmed current architecture

- PostgreSQL is opened once by `server/bin/server.dart` from `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD`.
- Current routes use the existing branch bearer-token map and `X-Branch-Id`. This is branch-scoped access, not database-per-store tenant routing.
- The local POS commits to SQLite first and attempts network synchronization afterward.
- The current SQLite helper opens one shared database file. No per-store database provider was found.
- The existing sync batch is one PostgreSQL transaction (all-or-nothing). Existing operation types in the server are `PARTY_CREATE`, `SALE_INVOICE`, and `VOUCHER`. The local queue maps the existing parties, sales and vouchers tables to those types.
- Do not change queue states (`PENDING`, `FAILED`, `BATCHED_SENT`), stable operation UUIDs, batch idempotency keys, or the transaction contract as part of the inventory work without a separately designed compatibility change.
- Existing financial schema scales are mixed: money columns are generally `NUMERIC(20,4)`; stock quantities and conversion factors include `NUMERIC(20,6)`; sale quantity is `NUMERIC(20,4)`.
- `MoneyAmount` and `ScaledDecimal` are available from `core_contracts`. The reviewed live `_applySale` still uses `double`; the presence of helper classes is not evidence that live sale posting has migrated.
- `OfficialReportTemplate.preview` exists at `lib/core/pdf/official_report_template.dart` and accepts summary boxes, columns, rows and A4 page format. Reuse it rather than creating another PDF framework.

### Existing owner-reported verification

The user previously supplied a successful result for the rollback-only branch isolation test `006` (10 assertions true and rollback cleanup). This is recorded as owner-reported PASS, not as a test run by this implementation session. Do not rerun it unless a relevant schema/constraint change requires it.

## 2. Iteration 3 scope discrepancy requiring controlled resolution

The source specification says the migration creates 14 tables, but the listed entities enumerate 19 names, including `stock_movements`, which already exists in migration `001`. Therefore the correct additive implementation must not create a duplicate `stock_movements` table. It must alter the existing table additively where required and create only the missing entities. Confirm the final table count from the actual migration, not from the prose count.

The specification also uses paths under `app/lib/`, while the repository's Flutter source is under root `lib/`. Use the actual repository paths. For example, the existing PDF template is `lib/core/pdf/official_report_template.dart`.

The specification describes a full-stack feature set larger than a single safe commit. Keep it split into reviewable milestones: schema and rollback-only SQL tests; pure domain calculations; server transaction/use cases and API; safe local SQLite migration and queue contract; provider/UI/PDF; integration and handover.

## 3. Iteration 3 code added in this milestone

### `server/lib/features/inventory_and_purchases/domain/purchase_and_fefo_calculator.dart`

Added pure domain types and calculations:

- `PurchaseMoneyCalculator.calculateLine`: paid packs, bonus packs, received base units, net line amount, effective pack cost, and effective base-unit cost.
- `PurchaseMoneyCalculator.weightedAverageBaseCost`: weighted-average base-unit cost with six-place stock/cost scale and explicit rounding to four-place money before division.
- `FefoBatchBalance`, `FefoBatchAllocation`, and `FefoAllocationPlan`.
- `FefoAllocationPlanner.plan`: deterministic expiry/created/id ordering, expired/inactive batch exclusion, carton opening using ceiling division, and explicit unallocated quantity instead of allowing negative stock.

The planner is intentionally pure. It does not lock database rows, mutate inventory, create movements, or participate in the live sale transaction. The caller must load and lock eligible batches within the existing sale transaction before applying the returned plan.

### `server/test/purchase_and_fefo_calculator_test.dart`

Added unit tests for bonus quantity arithmetic, line discount validation, weighted-average cost, FEFO ordering and auto-unpack, expired/inactive batch exclusion, and insufficient batch stock.

## 4. Not implemented yet — do not represent as complete

- Created additive Neon migration `007` and rollback-only SQL isolation tests `008` on the work branch. They have **not** been executed against PostgreSQL/Neon; review and disposable-database execution remain required.
- Warehouse, aisle/shelf, fridge temperature, FEFO batch, stocktaking, disposal, transfer, purchase order/invoice/return, and cost-history persistence.
- Immutable append-only enforcement for PostgreSQL and SQLite stock movements.
- Server repositories, use cases, and inventory/purchase routes.
- Extension of the existing sync contract to new operation types while preserving all-or-nothing behavior and idempotency.
- Local SQLite additive migration. The existing schema version is 1; the existing `onUpgrade` only handles old versions below 1 and is not an implementation of Iteration 3.
- Purchase/inventory DTOs and API client methods.
- Wiring FEFO deductions into the existing `PostgresSalesSyncRepository._applySale` transaction.
- Local POS purchase/stock workflows and queue mapping.
- Provider, screens, responsive layouts, and official PDF reports.
- Live Neon NUMERIC string bind/round-trip verification.
- Integration tests against PostgreSQL/Neon and end-to-end offline replay.
- Any deployment or production-readiness evidence.

## 5. Verification log — truthful state

| Check | Result |
|---|---|
| Source inspection of architecture and key integration points | Completed |
| Dart/Flutter toolchain available in this execution environment | No — `dart` and `flutter` commands are not installed |
| New Dart tests authored | Yes |
| New Dart tests executed | No |
| Dart analyzer / formatter | Not run |
| PostgreSQL migration 007 / SQL tests 008 | Passed on disposable PostgreSQL 18.7 in CI; not applied to Neon production |
| Neon database modified | No |
| SQLite schema/data modified | No |
| Server API or live sale transaction modified | No |
| Production deployment | No |

Do not change any of these statuses without new execution evidence.

## 6. Next developer entry point

1. Read this handover and the two existing architecture reviews.
2. Inspect the new calculator and its tests. Run formatting, analysis and tests in a Dart-enabled environment; fix issues before integration.
3. Add migration `007` as an additive migration. Preserve the existing `stock_movements` table and establish composite branch-safe references for every new branch-scoped relationship.
4. Add rollback-only SQL tests `008`; execute them against a disposable database with the required migrations, not a live business database.
5. Implement inventory and purchase repository/use cases in the existing Dart server and reuse its PostgreSQL connection, auth middleware and branch scope.
6. Integrate FEFO into the existing sale transaction only after row-locking, rollback, concurrency and replay tests exist. Do not create a second sale path.
7. Extend the existing batch operation contract only after defining payloads and replay semantics. Preserve batch all-or-nothing behavior and the existing stable IDs/idempotency keys.
8. Add a versioned, non-destructive SQLite migration and explicit tests that preserve all existing rows and pending sync queue entries.
9. Wire UI and `OfficialReportTemplate.preview` only after API/local contracts stabilize.
10. Update this document, the API/financial reviews, development log and changelog after every milestone.

## 7. Commits in this milestone

- `0f72fdb37f4ab098c89b00aa2f85c4a0d0413ea0` — initial purchase/FEFO calculator.
- `de99bc28d4590ccf87b85c801d3e760a260bfc49` — corrected carton arithmetic to stock scale.
- `6072925e462007adc459c2f2ff587a573c8c6b9e` — added purchase/FEFO unit tests.
- `04aab46aa256b0aa6d69dc6c8b1f6799c6a3be07` — tightened FEFO batch bounds and scale validation.

These commits are on `feature/multi-store-isolation-foundation`. No changes were made to `main`.


## 8. Iteration 3 schema milestone — 2026-11-13

- Added `docs/neon/007_fefo_inventory_and_purchases_schema.sql` on `feature/multi-store-isolation-foundation`.
- Added `docs/neon/008_inventory_branch_isolation_tests.sql` with rollback-only assertions for generated FEFO quantity, cross-branch warehouse/supplier/batch references, negative carton balance, and append-only stock movements.
- Migration 007 creates warehouses, aisle/shelf locations, fridge temperature logs, FEFO batches, sales-item batch allocations, stocktaking sessions/lines, disposals/items, transfers/items, purchase orders/items, purchase invoices/items, purchase returns/items, and cost history. It extends the existing `stock_movements` table; it does not create a duplicate movement table.
- Composite branch-aware keys are added for the new relationships. Existing `stock_movements` receives nullable warehouse/batch references to preserve all historical rows.
- No production database was contacted or changed. SQL 008 has not been executed. CI workflow run 16 was observed as in progress at handover time; no result is claimed here.
- **Next:** inspect SQL syntax and constraints with PostgreSQL 18, execute 008 on a disposable database, then implement server repositories/use cases/routes and the transactional FEFO integration. Do not begin UI wiring until server and local persistence contracts are stable.


## 9. Additional implementation completed — 2026-11-13

### Database
- Migration 007 and rollback-only tests 008 were executed by GitHub Actions against a disposable PostgreSQL 18.7 service after applying migrations 001–004.
- Result: migration application succeeded; SQL 008 completed successfully; the fixture transaction ended with ROLLBACK.
- This is not a Neon production migration and does not authorize running 007 on the production branch.
- Purchase invoice schema now also carries branch-scoped cash-account reference, payment method and wallet reference validation.

### Shared contracts and calculations
- Added `packages/core_contracts/lib/inventory_purchase_contracts.dart` and exported it from `core_contracts.dart`.
- Added decimal-string DTOs for warehouses, locations, FEFO batches, stock movements, stocktaking sessions/lines, disposals, transfers, purchase invoice headers/lines, returns and shortage suggestions.
- Added tests for scale-preserving JSON round-trip and rejection of floating-point JSON decimals.
- Fixed a duplicated trailing source block in `money_amount.dart`, changed its zero constant to a runtime static final value, and corrected purchase line multiplication to use `MoneyAmount` rather than mixing `MoneyAmount` and `ScaledDecimal`.
- Dart server analyze and tests passed in CI after these fixes.

### API read layer
- Added branch-scoped read repository and Shelf routes for warehouses, locations, FEFO batches, stock movements, stocktaking sessions and shortage suggestions.
- Existing bearer-token and `X-Branch-Id` verification is reused; each query filters by the authenticated branch.
- Added matching API client read methods.
- The API client currently also contains write method contracts, but the corresponding server write handlers are not yet implemented. Do not call those methods in production until the server posting use cases are completed.

### Remaining work — not complete
- Transactional purchase invoice/return posting, supplier ledger and journal effects.
- FEFO allocation inside the live `_applySale` transaction, including row locks, stock movement rows and sales-item batch allocations.
- Sync batch support for purchase, stocktake, disposal and transfer operations with existing idempotency/receipt behavior.
- SQLite version upgrade, exact local inventory persistence, local-first operation queue integration and recovery/retry behavior.
- Stocktaking count/approval writes, disposal posting, transfer dispatch/receipt, fridge temperature write flow.
- Flutter providers, screens, app navigation, POS batch/expiry warnings, purchase workflows, shortage-to-order workflow.
- Official PDF reports using `OfficialReportTemplate`.
- Full end-to-end tests, Flutter test suite and APK build.
