# Financial Precision and Sync Contract Review

Date: 2026-11-11  
Branch: `feature/multi-store-isolation-foundation`  
Scope: source review only; no database or runtime changes.

## Reviewed source
- `pubspec.yaml`, `server/pubspec.yaml`
- `server/lib/features/sales_and_sync/data/postgres_sales_sync_repository.dart`
- `lib/data/services/scale_pos_and_ledger_service.dart`
- `server/migrations/20261109_002_pos_sales_and_lah_alayh_ledger.sql`

## Findings

### 1. Monetary precision — release blocker
Neither Dart package declares a decimal/money arithmetic dependency. The server parses monetary inputs through `_decimal()` into Dart `double`. In `_applySale`, line totals, subtotal, cost of goods, cash/wallet/credit totals, account aggregation, and payment reconciliation use binary floating-point arithmetic. The local service also exposes monetary inputs and journal amounts as `double`.

PostgreSQL journal amounts are `NUMERIC(20,4)`; the sales schema also uses fixed-scale numeric columns. This protects persisted column scale, but does not remove floating-point approximation that may already have occurred in Dart before binding values.

**Required decision before implementation:** establish one money representation and currency policy (minor-unit integer or decimal arithmetic), explicit scale per currency, line-total rounding, invoice-level rounding, discount allocation, tax policy if introduced, and cash-change rules. Add boundary tests for values such as 0.1 + 0.2, fractional quantities, repeated line multiplication, discounts, mixed tender, and maximum supported amounts. Do not silently change existing SQLite numeric storage or migrate live data as part of this review.

### 2. Sale payment reconciliation
The server computes each line as `qty * unitPrice`, sums subtotal, subtracts discount, and requires `cashGross + walletTotal + creditTotal` to equal net total within a hard-coded tolerance of `0.0001`. `paidTotal` is cash plus wallet only; credit is recorded as remaining receivable. `changeReturned` is checked only for non-negativity and is explicitly treated as informational because the comment says local payment rows already contain amounts after change is removed.

This is a specific contract that needs tests and a formal definition. In particular, the request currently does not demonstrate a server-side derivation/check that tendered cash minus change equals applied cash. A client could submit a mathematically inconsistent change value while satisfying the payment-total check. Clarify whether payload amounts mean tendered or applied amounts, then validate change consistently on the server. Add mixed cash/wallet/credit and change cases.

### 3. Idempotency scope and replay
The server inserts into `sync_idempotency` using `idempotency_key` as the conflict key, then locks the record and rejects reuse when either `branch_id` or `request_hash` differs. Therefore a key collision across branches does not replay another branch's result; it fails with `IDEMPOTENCY_KEY_REUSED`. This is safe against cross-branch response leakage, but means keys are globally unique rather than independently scoped by branch. Client-generated keys must be globally collision-resistant. Verify the schema's uniqueness constraint and hash construction in contract tests.

Separately, operation receipts are keyed by `(branch_id, operation_id)`. In batch processing, an already-receipted operation is added to `acceptedIds` without reapplying it. Test same operation/same payload replay, operation ID reused with different payload, same idempotency key/different body, and lost-response retry.

### 4. Batch atomicity
`processBatch` wraps the complete batch in one PostgreSQL transaction. Unsupported operations or any application error throw and roll back all operations and the idempotency response. The response's `rejected` list is always empty on success. This is **all-or-nothing**, not partial acceptance. The local client updates each queue row according to returned `acceptedIds`, but an exception means it receives no response and leaves the rows eligible for retry.

The API contract and client documentation must explicitly describe all-or-nothing behavior. Add integration tests proving that a failure in the final operation rolls back earlier inserts, stock changes, journal entries, receipts, and idempotency completion.

### 5. Local queue acknowledgment and retry
The local client selects `PENDING` and `FAILED` rows, sends up to 100 operations, then marks accepted IDs as `BATCHED_SENT` and all others as `FAILED`. It does not delete accepted rows in this method. A transport exception is swallowed by the best-effort caller, leaving the rows available for a later attempt. No bounded exponential backoff, retry counter, dead-letter state, or explicit server-acknowledgment reconciliation was established by the reviewed method.

The `BATCHED_SENT` state must have a documented retention/cleanup and recovery policy. A crash after server commit but before local acknowledgment should replay the same stable batch/operation identities and receive an idempotent result. Add tests for that crash window, repeated sync calls, stale `BATCHED_SENT` rows, and mixed accepted IDs.

### 6. Local/server contract parity risks
The local engine uses a shared `DatabaseHelper.instance`; it is not yet per-store SQLite. Local operations are committed before best-effort sync. This is intentional offline-first behavior but does not establish cross-device consistency or store-level isolation.

The reviewed server voucher path validates voucher type, party type, positive amount, and wallet reference presence, but the source excerpt does not show a complete method-to-cash-account-kind/provider consistency check equivalent to the local path. Add explicit server validation and tests before relying on client validation.

## Recommended implementation sequence
1. Approve the currency/scale/rounding and change semantics; then introduce decimal-safe domain arithmetic on both client and server without changing persisted data formats implicitly.
2. Add pure unit tests for money calculations and payment reconciliation.
3. Add PostgreSQL integration tests for sale rollback, stock/account locking, batch all-or-nothing behavior, idempotency/replay and operation-ID payload conflicts.
4. Specify queue states, acknowledgment, retry/backoff, and stale sent-row recovery; add deterministic tests.
5. Only then proceed to account/store identity and per-store database routing.

## Verification status
- **Source reviewed:** yes, for the files listed above.
- **Runtime tests executed in this review:** no.
- **Neon modified:** no.
- **Migration executed:** no.
- **Production readiness:** not established.

## Incremental implementation — fixed-scale primitive
A shared `MoneyAmount` primitive was added at `packages/core_contracts/lib/money_amount.dart` and exported from the package barrel. It stores integer ten-thousandths, parses decimal strings exactly, rejects more than four fractional digits, and rounds multiplication half away from zero. Unit tests were added at `test/money_amount_test.dart` for parsing, addition/subtraction, multiplication, precision rejection and comparisons.

**Important limitation:** the existing POS and server posting paths still use `double`; this primitive is not yet wired into sale, voucher, inventory-cost, or ledger posting. The tests have been authored but were not executed in this environment. Do not treat this incremental primitive as closure of the financial precision release blocker. The next implementation step is migrating calculations and wire serialization in a coordinated, backwards-compatible change, with SQLite compatibility and regression tests.

## Follow-up hardening — shared parser and server test wiring

A source inspection found that the decimal parser's regular-expression literal had an incorrectly escaped digit pattern, which would reject ordinary numeric strings. The pattern was corrected to match decimal digits. The server package now declares the shared `core_contracts` package as a local path dependency, and `server/test/money_amount_test.dart` adds server-side contract coverage for exact addition, fixed-scale serialization, multiplication rounding and invalid precision.

**Not yet integrated:** `PostgresSalesSyncRepository._applySale`, `_applyVoucher`, and the journal/payment aggregation still use `double`. The new server tests are authored but have not been run; dependency resolution and compilation have not been verified. No PostgreSQL or SQLite data/schema was changed. The financial release blocker remains open.

## Server sale arithmetic — isolated calculation layer added

Added `server/lib/features/sales_and_sync/domain/sale_money_calculator.dart`. It provides exact scale-four helpers for line totals, converted base quantities, inventory cost, summation, discount bounds, and exact payment-to-net-total reconciliation using the shared `MoneyAmount` type. Added `server/test/sale_money_calculator_test.dart` for representative decimal cases, payment balance, invalid discounts, and precision rejection.

**Integration status:** this helper is not yet called by `PostgresSalesSyncRepository._applySale`. The live posting method continues to use `double` for subtotal, cost, payments, credit checks, and cash-account aggregation. This deliberate separation avoids claiming that production calculations have been migrated before SQL parameter serialization and end-to-end transactional behavior are verified. The new tests have not been executed. No database schema or stored data changed.


## 2026-11-13 — Precision and PostgreSQL binding re-check

A follow-up source/schema inspection was completed before wiring the helper into the live transaction:

- `products.stock_base_qty`, `products.avg_cost_base_unit`, `products.last_cost_base_unit`, and product conversion factors use `NUMERIC(20,6)` in migration `20261109_001_erp_core.sql`.
- `sales_invoice_items.qty_sold` uses `NUMERIC(20,4)`, `conversion_factor` uses `NUMERIC(20,6)`, and `qty_base` is generated as `NUMERIC(20,6)` in migration `20261109_002_pos_sales_and_lah_alayh_ledger.sql`.
- Financial totals, payment amounts, journal amounts, cash balances, and party credit limits use `NUMERIC(20,4)`.
- The existing `SaleMoneyCalculator.baseQuantity` and `inventoryCost` helpers use scale-four `MoneyAmount`; they must not be used for six-place conversion factors or base-quantity/cost calculations. Their existence is not evidence that those fields are safely represented.
- The live `_applySale` path still performs quantity conversion, inventory costing, money aggregation, credit checks, and SQL parameter binding with `double`. No production call site was changed in this review.
- The `postgres: ^2.6.4` package documentation confirms named substitution parameters and typed SQL parameter syntax, but the reviewed repository source does not yet establish a tested exact-decimal binding contract for this specific legacy API. A string-to-`NUMERIC` integration test is required before relying on it.

**Decision:** do not partially wire `MoneyAmount` into `_applySale`. First introduce a scale-aware decimal representation for six-place quantities/conversion and four-place money, define the rounding boundary for quantity×conversion and base-cost×unit-cost, and verify exact `NUMERIC` parameter binding against PostgreSQL. Preserve the current API shape and schema until those tests pass.

**Verification:** source/schema inspection only; no Dart tests, PostgreSQL integration tests, Neon SQL, SQLite changes, or runtime posting were performed. The financial precision release blocker remains open.


## 2026-11-13 — Scale-aware decimal foundation

Added `ScaledDecimal` to `packages/core_contracts/lib/scaled_decimal.dart` and exported it from the package barrel. It stores decimal values as `BigInt` units with an explicit scale, rejects excess fractional digits, requires matching scales for addition/subtraction/comparison, and requires callers to specify the multiplication result scale. Multiplication uses explicit half-away-from-zero rounding.

The server-side `SaleMoneyCalculator` was corrected to follow the actual migration scales: sale quantity and unit price are parsed at scale four; conversion factors and base quantities at scale six; line totals at scale four; inventory cost is rounded explicitly to scale four after multiplying six-place base quantity by six-place average unit cost. This corrects the earlier helper-only assumption that all quantity and cost inputs could use scale four.

Added `packages/core_contracts/test/scaled_decimal_test.dart` for six-place conversion, four-place line totals, positive/negative half-unit rounding, precision rejection, mixed-scale rejection, and JSON numeric parsing. Updated `server/test/sale_money_calculator_test.dart` to cover six-place conversion factors.

**Integration status:** `ScaledDecimal` and the corrected calculator remain domain/test foundations; `PostgresSalesSyncRepository._applySale` still uses `double`. The current API JSON numeric decoding may already have converted numeric literals to `double`; string decimal inputs are needed to preserve their original decimal digits. The driver documentation shows named substitution parameters but does not establish exact numeric-string binding for this code path. Do not wire the live transaction until an actual PostgreSQL integration test proves NUMERIC parameter binding and round-trip behavior, and the API amount contract is explicitly settled.

**Verification:** tests were authored but not run in this environment; no CI pass is claimed. No Neon, SQLite, migration, or live transaction changes were made. The financial precision release blocker remains open.


## 2026-11-13 — Iteration 3 pure purchase/FEFO calculations

Added `server/lib/features/inventory_and_purchases/domain/purchase_and_fefo_calculator.dart`:

- Purchase paid/bonus quantities use scale 4, conversion factors and base quantities use scale 6, and money uses scale 4.
- Purchase line calculation excludes bonus packs from the paid amount while including them in received stock; it calculates effective pack/base costs and validates discounts.
- Weighted average base-unit cost uses six-place stock/cost representation and explicit four-place extended-money rounding before division.
- FEFO planning sorts by expiry date, creation time and ID; excludes expired/inactive batches; opens the minimum whole cartons needed; and reports any unallocated quantity rather than creating negative stock.

The new helper is pure and is not connected to SQL, the live sale transaction, SQLite, or sync. It does not prove exact PostgreSQL NUMERIC string binding. Tests were authored in `server/test/purchase_and_fefo_calculator_test.dart` but were not executed because Dart/Flutter are not installed in the execution environment. Existing live sale and voucher paths still require their separately documented financial-precision migration.


## Iteration 3 decimal persistence contract (schema source only, 2026-11-13)

Migration 007 uses `NUMERIC(20,4)` for monetary totals/prices and `NUMERIC(20,6)` for base quantities, conversion factors, and unit costs, aligned with the currently documented scales of `MoneyAmount` and `ScaledDecimal`. JSON DTOs, API parsing, and PostgreSQL text round-trip behavior have not yet been implemented or verified for Iteration 3. The live sale path's existing `double` usage remains an independent open issue; adding this schema does not resolve it. Do not pass monetary/quantity JSON through a binary floating-point conversion when implementing the new routes.


## Iteration 3 contracts update (2026-11-13)

The new inventory/purchase DTO layer serializes money and measured quantities as decimal strings and rejects floating-point JSON values. Purchase-line calculation now multiplies paid quantity using `MoneyAmount` at scale 4 and computes stock quantities/costs with `ScaledDecimal` at scale 6. Server analyzer/tests passed after this correction. The existing live sales `_applySale` still uses `double`; the Iteration 3 calculator and DTO work do not migrate that path or resolve the earlier sales precision release blocker.


## SQLite decimal storage update (2026-11-13)

Iteration 3 adds exact decimal TEXT columns for product stock/cost snapshots and stores new batch, purchase and inventory quantities/costs as TEXT. Existing REAL columns are retained to avoid a destructive rewrite and preserve the current POS contract. At present the existing sale engine still updates the legacy REAL stock field only; the exact columns must be maintained as part of the upcoming unified local transaction/FEFO integration. No claim is made that the full application has switched to exact arithmetic.
