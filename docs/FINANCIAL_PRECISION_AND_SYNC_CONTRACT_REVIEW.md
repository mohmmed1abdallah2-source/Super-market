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
