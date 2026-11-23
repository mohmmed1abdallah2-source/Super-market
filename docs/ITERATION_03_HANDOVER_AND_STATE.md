# Iteration 03 — Handover and implementation state

**Branch:** `feature/multi-store-isolation-foundation`  
**Status:** In progress — purchase invoice/return posting and FEFO sale integration implemented; sync receipt identity/replay hardening added; inventory sync operation types, remaining workflows, UI/PDF and financial precision closure remain  
**Last updated:** 2026-11-23

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

## 4. Current implementation status — 2026-11-15

### Completed in the work branch
- PostgreSQL migration 007 and rollback-only isolation tests 008 were executed successfully on disposable PostgreSQL 18.7; additive migration 009 for purchase-order receiving progress was also applied in CI.
- Branch-scoped read APIs exist for warehouses, locations, FEFO batches, stock movements, stocktaking sessions and shortage suggestions.
- Inventory/purchase decimal contracts and the versioned SQLite v1→v2 additive schema migration exist. The exact local inventory columns are not yet maintained by every legacy POS write path.
- The existing `PostgresSalesSyncRepository._applySale` now integrates FEFO row locking/allocation, batch balances, sales-item batch allocations and stock movement rows. Sale stock quantity checks/deductions and movement quantities use exact six-place decimals. Dedicated FEFO sale concurrency/replay integration coverage is still required.
- Transactional supplier purchase invoice posting exists at `POST /v1/purchases/invoices`, including FEFO receipt batches, weighted-average cost, stock movements, cash account updates, supplier ledger, balanced journal, idempotency and purchase-order receipt reconciliation.
- Transactional supplier purchase return posting exists at `POST /v1/purchases/returns`, including invoice/batch linkage, over-return protection, carton/loose stock handling, supplier credit, stock movement and balanced journal.
- The PostgreSQL integration test covers purchase invoice replay, fractional pack receipt, purchase-order receiving, purchase return replay, batch quantities, journal balance and stock movement behavior.
- CI run #197 completed successfully: PostgreSQL 18 setup, Dart server analysis and all 25 server tests; Flutter analyze/tests; Android release APK; Windows build; and Web build all passed. Delivery Gates run #131 also passed the formatting and Dart API analyze/test jobs after aligning its file_picker compile SDK workaround.

### Remaining work — Iteration 3 is not complete
- Extend the existing all-or-nothing sync batch contract and server handlers for purchase invoice, purchase return, stocktaking, disposal and transfer operations. Preserve stable operation IDs, idempotency and receipts.
- Complete local-first SQLite inventory persistence, exact TEXT snapshot maintenance in all relevant POS paths, pending queue mapping, retry/recovery and offline replay.
- Implement stocktaking count/approval, disposal posting, transfer dispatch/receipt and fridge-temperature writes.
- Add dedicated FEFO sale PostgreSQL concurrency/replay/rollback tests; do not infer them from the pure planner tests or generic sale tests.
- Convert remaining sale invoice, COGS and journal money aggregation away from Dart `double` to `MoneyAmount`/fixed-scale arithmetic.
- Complete Flutter providers, screens, navigation, POS expiry/batch warnings, purchase workflows and shortage-to-order flow.
- Implement official PDF reports through `OfficialReportTemplate`.
- Complete full end-to-end offline/online replay tests and release-readiness review.
- Do not apply migrations 007/009 to Neon production or deploy without the separately required review and explicit approval.

## 5. Verification log — truthful state

| Check | Result |
|---|---|
| Source inspection of architecture and key integration points | Completed |
| Local Dart/Flutter executables in this session | Not installed; CI toolchains were used |
| New server and integration tests authored | Yes |
| PostgreSQL server tests | 25 passed on disposable PostgreSQL 18.7 in CI run #197 |
| Dart server analyzer | Passed in CI run #197 |
| Flutter analyzer and tests | Passed in CI run #197 |
| Android release APK / Windows / Web builds | Passed in CI run #197 |
| Delivery Gates formatting + Dart API analyze/tests | Passed in CI run #131 |
| PostgreSQL migrations 001–004, 006–009 and SQL isolation tests | Passed on disposable PostgreSQL 18.7 in CI; not applied to Neon production |
| Neon database modified | No |
| SQLite source schema | Additive v1→v2 migration exists; legacy write-path integration remains incomplete |
| Server API and live sale transaction | Modified and tested in CI |
| Production deployment | No |

Do not change any of these statuses without new execution evidence.

## 6. Next developer entry point

1. Extend sync batch operation types and server handlers for purchase invoice/return, stocktaking, disposal and transfer; preserve all-or-nothing and idempotent replay.
2. Finish exact local SQLite inventory persistence and queue/retry/recovery integration without dropping pending operations.
3. Implement stocktaking approval, disposal, transfer and fridge-temperature write flows with branch-safe transactions.
4. Add dedicated PostgreSQL FEFO sale concurrency, rollback and replay tests.
5. Replace remaining sale/COGS/journal `double` calculations with fixed-scale decimal arithmetic.
6. Complete Flutter providers/screens/navigation and official PDF reports after local/API contracts stabilize.
7. Run full end-to-end offline replay and release-readiness tests. Keep production migrations gated behind review and explicit approval.
8. Update this handover and the API/financial reviews after each milestone.

## 7. Commits in this milestone

- `0f72fdb37f4ab098c89b00aa2f85c4a0d0413ea0` — initial purchase/FEFO calculator.
- `de99bc28d4590ccf87b85c801d3e760a260bfc49` — corrected carton arithmetic to stock scale.
- `6072925e462007adc459c2f2ff587a573c8c6b9e` — added purchase/FEFO unit tests.
- `04aab46aa256b0aa6d69dc6c8b1f6799c6a3be07` — tightened FEFO batch bounds and scale validation.

These early calculator commits are on `feature/multi-store-isolation-foundation`. Later server, migration, test and CI milestones are recorded below. No changes were made to `main`.


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


## 10. SQLite local schema milestone — 2026-11-13

- Added `lib/data/database/iteration3_inventory_schema.dart`.
- Increased `SchemaBuilder.version` from 1 to 2 and wired `DatabaseHelper.onUpgrade` to an additive v1→v2 migration.
- Added local tables for warehouses, locations, fridge temperature logs, purchase orders/invoices/returns, FEFO batches, sales-item batch allocations, stocktaking, disposals, transfers and cost history.
- Extended existing local `stock_movements` with optional warehouse/batch/reference/note columns; no replacement movement table was introduced.
- Added exact TEXT snapshot columns to products for new inventory quantity/cost handling while retaining legacy REAL columns for existing POS compatibility. Sale quantity deductions now use exact decimal values in PostgreSQL, but the local SQLite snapshots and every legacy POS write path still need to be wired to these exact columns.
- Added `test/iteration3_inventory_schema_test.dart` to verify fresh schema creation and the new columns.
- CI run #197 subsequently passed Dart server analysis and 25 server tests, Flutter analyze/tests, Android release APK, Windows and Web builds. This validates the current branch build, but does not mean local SQLite exact snapshots or offline replay are complete.


## 11. Independent handover audit — 2026-11-15

### GitHub state verified
- Repository: `mohmmed1abdallah2-source/Super-market`.
- Work branch exists: `feature/multi-store-isolation-foundation`.
- The branch was compared with commit `56fd908af3bb0cf9a758ed8825cc90adb2b7425f`; GitHub reported `identical` (0 ahead / 0 behind). This establishes that SHA as the branch head at the start of this audit, not as the current head after the audit commits.
- The reported commits `0f72fdb`, `de99bc2`, `6072925`, `04aab46`, `041cecf`, and `e68896f` were all found by exact SHA lookup.
- The calculator, its test file, migration 007, SQL tests 008, this handover, and the two architecture review documents were found on the work branch.
- No branch switch, merge, or production database operation was performed.

### Actual PostgreSQL schema inventory
- Migration 001 creates 6 tables, including the pre-existing `stock_movements`.
- Migration 002 creates 12 tables.
- Migration 003 adds composite constraints/triggers to existing tables; it creates no tables.
- Migration 004 inserts baseline accounting accounts; it creates no tables.
- Migration 006 is a rollback-only isolation test script; it creates no persistent tables.
- Migration 007 creates 18 new tables and alters the existing `stock_movements` and `sales_invoice_items` tables. It does not create a second movement ledger.
- Therefore the specification's stated count of 14 is inconsistent with its entity list: the actual implementation has 18 new tables plus the existing `stock_movements` table (19 entities in the specification's list).
- Migration 007 uses `NUMERIC(20,4)` for money and `NUMERIC(20,6)` for stock quantities/conversion factors/costs; temperature uses `NUMERIC(8,2)`.
- The migration defines 46 composite foreign-key declarations in the source inspection, extends the movement ledger, adds indexes, and installs the append-only UPDATE/DELETE trigger.

### Review correction applied
- Source review found that `product_batches_fefo.loose_base_qty` and `stocktaking_lines.counted_loose_base_qty` only had non-negative checks; they could still hold one full pack or more, contradicting the carton/loose-quantity invariant.
- Migration 007 now constrains both loose quantities to `0 <= loose < pack_conversion_factor`.
- SQL test 008 now additionally rejects negative loose quantity, loose quantity equal to one pack, and a stocktaking loose count equal to one pack. The notice now reports 10 assertions.
- These are source changes only. They have not yet been run against PostgreSQL in this session.

### Verification boundaries
- The prior handover records migration 007 and SQL 008 passing in disposable PostgreSQL 18.7 CI. This audit did not independently reproduce that run.
- GitHub returned no workflow runs and no combined status checks associated with the previously documented head `56fd908`; this audit therefore does not claim a current CI pass for the follow-up SQL edits.
- Local `psql`, Docker, Dart, and Flutter executables are not installed in the execution environment. No local SQL, Dart, Flutter, or APK command could be run.
- Neon production remains untouched. Migration 007 has not been applied to `neondb` by this session.

### Next implementation entry point
1. Run the revised migrations 001–004, 007 and test 008 as one controlled disposable PostgreSQL 18.x CI job, with SQL 008 executed as a single transaction and rollback.
2. Then implement transactional purchase invoice/return posting and supplier ledger/journal effects in the existing server transaction architecture.
3. Integrate FEFO batch row-locking, allocation, carton-unpack movements and sales-item batch allocations into the existing `PostgresSalesSyncRepository._applySale`; do not create a second sale path.
4. Only after server transaction tests pass, extend the existing all-or-nothing sync batch and local-first SQLite engine.


## Neon production protection and recovery — 2026-11-15

- Production Neon branch: `production` / `br-empty-brook-bab988pu`, PostgreSQL 18, default and primary.
- Baseline snapshot created successfully: `pre-iteration3-migration-baseline-2026-11-15` (`snap-hidden-shadow-bagbpujg`, 2026-11-15 12:41:20 UTC).
- Protection could not be enabled: Neon returned HTTP 422 because the current plan is at its protected-branch limit. The production branch remains unprotected.
- Automatic daily snapshot schedule could not be enabled: Neon returned HTTP 404 because backup schedule creation is not enabled for this project. The existing schedule remains empty.
- PITR history retention remains 6 hours (`21600` seconds). This is not a substitute for a longer retention policy or an independently stored backup.
- No production schema/data migration or SQL write was performed. Snapshot creation succeeded; a restore rehearsal has not yet been performed.
- Follow the exact restore procedure and approval gates in `docs/NEON_PRODUCTION_PROTECTION_AND_RECOVERY.md`.


## Snapshot restore rehearsal — 2026-11-15 (actual result and correction)

- Snapshot `snap-hidden-shadow-bagbpujg` restored successfully. Neon created `br-summer-violet-baexllh2` and, because the restore call finalized immediately, temporarily made it the branch named/defaulted as `production`; the original branch ID `br-empty-brook-bab988pu` was renamed by Neon.
- This was not the intended isolated state. No SQL writes or migrations were run. The branch roles were corrected immediately: `br-empty-brook-bab988pu` was set back as default and renamed `production`; `br-summer-violet-baexllh2` was renamed `restore-rehearsal-pre-iteration3-20261115` and is now non-default/non-primary.
- Verified both branches are ready. Read-only counts for branches, products, parties, sales invoices, journal entries, journal lines, stock movements and users were all zero on both branches. Neon returned 18 public tables/views for the restored branch. These checks are limited and do not prove full application recovery or byte-identical data.
- The restored rehearsal branch remains available and has not been deleted. Do not delete without separate approval.
- Production remains unprotected, automated snapshots remain unavailable, and PITR remains 6 hours. No production migration was applied.


## Post-restore endpoint mapping — approval required

- Verified endpoint `ep-young-scene-bab6kmsp` (original endpoint, created 2026-11-11) is currently attached to restored rehearsal branch `br-summer-violet-baexllh2`.
- Production branch ID `br-empty-brook-bab988pu` currently has newly created endpoint `ep-floral-term-badqa5er` from the restore operation.
- Thus the original app connection string may now target the rehearsal branch if it uses the old endpoint host. Actual application configuration was not inspected.
- No endpoint changes were made. Restoring the original endpoint association requires removing/moving the new endpoint and reattaching the old endpoint, which drops active DB connections briefly. Explicit user approval is required before this corrective action.


## 2026-11-15 — حالة نقطة اتصال الإنتاج بعد تصحيح الربط
- نُفذت موافقة المستخدم على تصحيح ارتباط نقطة الاتصال بعد تجربة استعادة Snapshot.
- حُذفت نقطة الاتصال التي أنشأتها عملية الاستعادة على الإنتاج `ep-floral-term-badqa5er`، ثم أُعيدت نقطة الاتصال الأصلية `ep-young-scene-bab6kmsp` إلى الفرع `br-empty-brook-bab988pu` (`production`).
- تحققنا من أن نقطة الاتصال الأصلية أصبحت مرتبطة بفرع الإنتاج، وأن الإنتاج ما زال الفرع الأساسي والافتراضي وحالته `ready`. بقي فرع الاستعادة `br-summer-violet-baexllh2` وفرع التدقيق `br-odd-term-ba2iavg0` دون حذف.
- لم تُنفذ ترحيلات 007/008 على الإنتاج، ولم يحدث أي تعديل SQL أو بيانات ضمن هذه الخطوة.
- اسم مضيف الاتصال الأصلي لم يتغير، لكن لم تتم مراجعة متغيرات بيئة التطبيق أو إجراء اختبار اتصال من التطبيق؛ يجب اعتبار توجيه Neon مصححًا ومتحققًا، بينما تحقق التطبيق ما زال مطلوبًا.


## 2026-11-15 — CI gate expanded for Iteration 3 (implementation session)

- Updated `.github/workflows/flutter-validation.yml` on `feature/multi-store-isolation-foundation` in commit `fe9dde48836e554fad7f6b33ebec85732deaef18`.
- Added the work branch to push triggers so Flutter, server and platform validation can run for this development line.
- Changed the disposable PostgreSQL service used by server validation from PostgreSQL 16 to PostgreSQL 18, matching migration 007's explicit minimum-version guard.
- Extended the disposable-database setup to apply branch constraints (003), baseline accounting (004), rollback-only branch tests (006), inventory/purchase schema (007), and rollback-only inventory isolation assertions (008), after the existing server migrations 001/002.
- This is CI configuration only. The workflow result has not yet been observed; no Flutter/Dart test, APK build, Windows build, Web build, or SQL pass is claimed from this commit.
- Neon production and its data remain untouched. No production migration or deployment was performed.


## 12. FEFO integration milestone — 2026-11-15 (implementation, not yet validated)

- Extended the existing sale transaction rather than creating a second sale path.
- For products with no FEFO batch records, the legacy aggregate-stock path remains available; a sale movement is now appended to the existing stock movement ledger.
- Once a product has FEFO batch records, the server locks its batch rows with `FOR UPDATE`, plans allocations using the pure decimal-scale FEFO planner, excludes expired/held/depleted batches, and rejects a sale if the remaining unexpired batch quantity is insufficient.
- Successful allocations update sealed-carton/loose-unit balances, mark depleted batches, create `sales_invoice_item_batches` rows, and append immutable `SALE_OUT` stock movements in the same PostgreSQL transaction as the invoice.
- COGS for FEFO-tracked lines is derived from allocated batch unit costs; the current accounting implementation still converts values to Dart `double` for journal totals. This does **not** close the financial-precision release blocker.
- Source commit: `036132e91cf195bbcbe70ef9c16aa848829cedea`; batch-cost valuation correction: `d435a0c2d375b112bd9c9d92f06face6eb40e8e4`.
- Existing pure FEFO planner tests cover expiry ordering, carton opening, inactive/expired exclusion and insufficient quantity. No new PostgreSQL repository integration test has been run for this wiring yet.
- The CI workflow was expanded in `fe9dde48836e554fad7f6b33ebec85732deaef18`, but GitHub has not returned a completed check result in this session. Treat all runtime/analyze/SQL validation of this integration as pending.
- No production Neon migration or deployment was performed.


### FEFO warehouse eligibility refinement — 2026-11-15

- FEFO sales now exclude batches held in non-sellable warehouses. An optional `warehouseId` in the sale request scopes the allocation to that warehouse; if omitted, FEFO allocation may use any sellable warehouse in the same branch.
- Existing batch rows in non-sellable warehouses do not trigger a fallback to aggregate legacy stock; if no eligible sellable FEFO stock can satisfy the sale, the transaction is rejected.
- Source commit: `890e29fbb3d4bd2fb24399466f87c2b349a3342a`. This refinement also awaits CI and PostgreSQL transaction verification.


### Selected-warehouse safety — 2026-11-15

- A supplied `warehouseId` is now checked against the authenticated branch and must identify an active, sellable warehouse.
- When a warehouse is explicitly selected, a product without FEFO batch tracking in the selected branch context is rejected rather than deducted from an unlocated aggregate stock balance.
- Commit: `efefb0c229bff44550557a18b97411611a0e6800`. Validation is pending.


## 2026-11-15 — Supplier purchase invoice posting milestone

- Added `PostPurchaseInvoiceUseCase` and `PostgresPurchaseInvoicePostingRepository`, exposed through the branch-authenticated `POST /v1/purchases/invoices` route and wired in `server/bin/server.dart`.
- The operation runs in one PostgreSQL transaction and uses both the HTTP idempotency key/request hash and stable operation ID. A completed operation replay returns its stored response; duplicate operation IDs are serialized with a transaction-scoped advisory lock.
- Validates supplier ownership/type, active receiving warehouse, optional active product unit and its exact conversion factor, optional location ownership, future/non-expired batch date, payment method/account compatibility, cash sufficiency, and purchase-order supplier/status/line quantity.
- Persisting each purchase line creates the invoice item and FEFO batch, updates aggregate stock and weighted average base cost using `ScaledDecimal`/`MoneyAmount`, appends price-cost history and a positive `PURCHASE_IN` stock movement, all inside the same transaction.
- Fractional packs are preserved as integer sealed cartons plus loose base quantity; they are not truncated into the integer carton column.
- Posts a balanced journal entry: debit inventory, credit cash for paid amount, and credit supplier payable for the outstanding amount. Updates the cash account and supplier `lah_alayh_ledger` balance consistently with the existing voucher convention.
- Added additive migration `docs/neon/009_purchase_order_receiving_progress.sql` to track cumulative received quantities and enforce `0 <= qty_received <= qty_ordered`. Purchase invoices linked to an order reconcile each line and set order status to PARTIALLY_RECEIVED or RECEIVED only when all lines are satisfied.
- Added `server/test/postgres_purchase_invoice_posting_test.dart` covering atomic posting, replay/no duplicate movement, fractional-pack receipt, balanced journal, supplier balance and full purchase-order receipt. This test requires `PGTEST_HOST`; it is intentionally skipped in workflows that do not provide PostgreSQL.
- Added migration 009 to the disposable PostgreSQL 18 CI setup and included the new Dart files in the delivery-gate formatting list.
- Source commits include `f17a236f`, `39af37c9`, `6770c5d5`, `1282d7d8`, and `a4cd3961`. PostgreSQL-enabled CI run #197 completed successfully with 25 server tests, including this purchase invoice integration coverage.
- No migration was applied to Neon production. Migration 009 is source-only and CI-only at this point.


## 2026-11-15 — Supplier returns and exact stock movement follow-up

- Added authenticated `POST /v1/purchases/returns`, `PostPurchaseReturnUseCase`, and `PostgresPurchaseReturnPostingRepository`.
- Return posting locks the original posted purchase invoice, invoice item, FEFO batch and product; verifies the batch/item/invoice linkage; checks previously returned quantity, remaining physical batch stock and aggregate stock; and rejects over-returns.
- The return consumes loose units first and opens only the minimum cartons required. It writes purchase-return items, updates batch/product quantities, appends negative `PURCHASE_RETURN_OUT` stock movements and cost history, and posts the balanced supplier-credit/inventory journal and supplier ledger adjustment in one transaction.
- Supplier return valuation uses the current moving-average carrying cost, keeping aggregate inventory value consistent with the quantity removed. It does not create a cash refund; any supplier credit remains on the supplier ledger.
- Sale stock availability checks, aggregate stock deductions, sale item quantity/factor persistence and stock movement quantities now use the exact six-place `ScaledDecimal` result rather than converting the stock quantity through `double`. Sale invoice/journal money aggregation still contains `double` and remains a release blocker.
- Extended the PostgreSQL integration test to cover supplier return posting, idempotent replay, batch carton/loose balance, negative stock movement, balanced journal and remaining product stock.
- Latest PostgreSQL-enabled run #197 completed successfully: server analysis and all 25 server tests passed, including purchase invoice and purchase return posting; Flutter analyze/tests, Android release APK, Web and Windows builds also passed.
- Delivery Gates Dart API analyze/tests also passed for the supplier-return source revision.
- CI concurrency for Flutter validation was changed to queue rather than cancel an in-progress run, so rapid documentation/commit updates do not terminate the current platform validation.
- No migration was applied to Neon production, no production data was changed, and no application deployment was performed.


### CI result update — 2026-11-15, run #197

- GitHub Actions run #197 completed successfully for the current supplier-return implementation commit `4b6258eb`.
- Confirmed: Flutter analyze/tests, Android release APK build and artifact upload, Windows build and artifact upload, Web build and artifact upload, PostgreSQL 18 schema setup, Dart server analyze, and all 25 server tests passed.
- The PostgreSQL integration test includes purchase invoice posting, idempotent replay, fractional pack receipt, purchase-order receiving, supplier return posting, return replay, batch balance and journal checks.
- Run URL: `https://github.com/mohmmed1abdallah2-source/Super-market/actions/runs/43724926715`.
- This confirms the tested source revision only; it does not complete the remaining Iteration 3 scope or authorize a production migration/deployment.


## 2026-11-23 — Sync receipt identity hardening (validation pending)

- Current audited branch head before this documentation update: e85b8551148a3e077916777bfb5fc81c8230b521.
- Added additive migration 010, docs/neon/010_sync_operation_payload_identity.sql, to add nullable payload_hash CHAR(64) to sync_operation_receipts. Existing rows remain NULL because historical payloads cannot be reconstructed.
- Batch processing hashes canonical JSON payloads and compares the stored operation type/hash on replay. A changed type or payload for a new-format receipt is rejected as OPERATION_ID_REUSED; the route returns HTTP 409. Direct sale receipt writes also persist the hash.
- Added a PostgreSQL integration test for first acceptance, same-payload retry, and changed-payload rejection. The first CI attempt identified a missing hash parameter in the separate direct-sale receipt call; follow-up fix is committed in e85b8551148a3e077916777bfb5fc81c8230b521.
- Migration 010 was added to the PostgreSQL-enabled Flutter validation setup. Disposable PostgreSQL 18 schema validation run #8 passed. The new application/test commit has not yet received a successful full test run; status remains pending.
- Legacy receipts with NULL hashes retain same-type acceptance for backward compatibility. Their payload identity cannot be retroactively verified; this is an explicit migration-era limitation.
- Remaining Sync Batch operations are still only PARTY_CREATE, SALE_INVOICE, and VOUCHER; purchases, returns, stocktake, disposal and transfer are not yet batch-enabled.
- Neon production was not accessed for migration execution; no production DDL/DML or deployment was performed.


## 2026-11-23 — Sync receipt identity and validation update

- Current verified implementation source commit: b3351ced877c29095aa995739690c54066f43f8b.
- Migration 010 adds nullable payload_hash CHAR(64) to sync_operation_receipts. New operation receipts persist the SHA-256 of canonical JSON payloads. Replays verify operation type and hash; mismatches return HTTP 409 (OPERATION_ID_REUSED).
- A transaction-scoped advisory lock keyed by branch_id and operation_id serializes concurrent batches before the receipt check. The direct sale route uses the same lock and receipt identity check.
- Legacy receipts with NULL hashes remain replayable when their operation type matches; their old payload cannot be compared because it was never stored. This is a documented compatibility limitation.
- PostgreSQL Validation run #208 applied migration 010 on disposable PostgreSQL 18 and passed all 26 server tests. The new test executes two concurrent same-operation requests, verifies same-payload replay, and rejects a changed payload. Purchase invoice/return integration, sale retry, voucher and mixed-tender tests also passed.
- Delivery Gates run #138 passed Dart analysis/tests and shared contracts; 21 server unit tests and 5 shared-contract tests passed, while five PostgreSQL integration tests were skipped in that workflow. Flutter analysis/tests passed. In run #208, Flutter analysis/tests and Web build passed; Android APK and Windows build were still in progress at the time of this update.
- Previous source CI failures were caused by a missing payloadHash argument in the direct-sale receipt call; corrected in f91389f8. The route's 409 conflict mapping is in b3351ced.
- Remaining sync operations are still PARTY_CREATE, SALE_INVOICE and VOUCHER only. Purchase invoice/return, stocktake, disposal and transfer are not yet supported by Sync Batch. Offline queue acknowledgment/recovery, inventory workflows, sale money double removal, FEFO sale concurrency tests, Flutter inventory UI and official reports remain open.
- No production Neon migration/DML, deployment, restore, endpoint mutation, or branch deletion was performed.


## 2026-11-23 — Purchase receipt identity extension (validation pending)

- Current source commit for this extension: c36c130f0e7611d535f6b1ced4e43e85997ad03d.
- Purchase invoice and purchase return posting now store SHA-256 hashes of canonical JSON payloads in sync_operation_receipts. Before replaying an existing invoice/return operation, each repository checks the receipt's operation type and, for non-legacy receipts, the payload hash. Mismatched reuse raises OPERATION_ID_REUSED and the inventory route returns HTTP 409.
- Both posting paths retain branch+operation transaction advisory locks. Corrected the supplier-return lock key to interpolate the actual branch and operation IDs.
- Extended the PostgreSQL integration test to retry each purchase document with a new idempotency key and reject a changed payload under the same operation ID.
- Delivery Gates #141 passed Dart server analysis/tests and shared-contract tests; five PostgreSQL-only tests were skipped in that workflow. PostgreSQL-enabled validation #211 is pending for this exact source commit. Earlier run #208 passed 26 server tests on the previous source revision, but it does not validate this purchase-specific receipt-hash extension.
- Legacy receipts with NULL payload_hash remain same-type replayable because their original payload cannot be reconstructed. No Neon production migration/DML or deployment.
