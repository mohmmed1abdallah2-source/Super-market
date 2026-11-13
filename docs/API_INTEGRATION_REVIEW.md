# API integration review — current implementation and remaining work

**Review date:** 2026-11-11  
**Reviewed branch:** `feature/multi-store-isolation-foundation`  
**Scope:** Dart Shelf API entry point, sales/sync routes and repository, ledger routes, local POS facade, and the approved multi-store architecture.

> This is a source-code review, not a claim that the API was deployed or that runtime/integration tests passed. Findings below describe the files inspected on this branch.

## 1. What is present in code

### API process and database connection
- `server/bin/server.dart` opens one PostgreSQL connection from `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, and `PGPASSWORD`.
- The same connection is passed to the ledger and sales/sync repositories.
- `/health` returns a simple process-level status response.
- Branch bearer tokens are loaded from `ERP_BRANCH_TOKENS`; `ERP_API_TOKEN` is retained as a single-branch fallback.
- The server currently has no control-plane connection, store directory, membership lookup, per-store database router, or per-store connection pool.

### Request authentication and scope
- Sales/sync and ledger routes require both `Authorization: Bearer ...` and `X-Branch-Id`.
- The supplied branch ID selects a token from the configured in-memory branch-token map.
- Business queries generally scope reads and writes using `branch_id`.
- This is branch-scoped bearer-token authentication, not account identity plus verified store membership. It does not implement the approved database-per-store tenant boundary.
- The current API has no sign-in, refresh, sign-out, list-stores, activate-store, or provision-store endpoints.

### Server-side sale posting
- `PostgresSalesSyncRepository.postSale` runs the sale path inside a PostgreSQL transaction.
- The transaction claims an idempotency key, checks an existing operation receipt/invoice path, applies the sale, completes the idempotency response, and records the operation receipt.
- `_applySale` validates item quantities, looks up active products in the requested branch with row locking, checks stock, and updates stock.
- It validates payment methods and totals, checks customer credit for credit sales, creates a draft journal, and writes financial records as part of the same transaction.
- This is evidence of a transactional server-side sale implementation in source. It is not evidence of a successful live end-to-end sale against the owner's Neon database.

### Batch synchronization
- `processBatch` also runs within a PostgreSQL transaction and tracks accepted operation IDs.
- Existing operation receipts are checked by branch and operation ID.
- The route accepts a JSON operations array and builds a request hash/idempotency command.
- The current repository implementation must still be validated against the client queue contract, especially retry behavior, duplicate operations, mixed valid/invalid batches, and whether every operation type is safely and completely handled.

### Local Flutter POS
- `LocalPosAndLedgerEngine.completeSale` calls the local posting service first, then starts best-effort synchronization after the local operation returns.
- This preserves the intended offline-first ordering: local write first, network sync afterward.
- The service currently defaults to `DatabaseHelper.instance`; it is not yet a per-store SQLite database provider.
- A configured API client is optional and attached through `configureApiClient`; the repository documentation correctly notes that a real authenticated session source is still missing.

## 2. Gaps and risks to close before production

1. **Tenant authentication:** replace static branch tokens as the user-facing identity model with authenticated accounts, memberships, roles, and a verified active-store session.
2. **Database-per-store routing:** introduce a control-plane database and route each authenticated request to a separate store database using server-held credentials and least-privilege roles. A branch header must never select a tenant database.
3. **Local store context:** replace the process-wide single SQLite handle assumption with separate store-scoped database files and isolated queues, including a non-destructive adoption path for existing local data.
4. **Financial precision:** inspect and remove binary floating-point arithmetic from financial calculations and persistence boundaries. PostgreSQL columns may be NUMERIC, but the reviewed sale implementation parses and accumulates amounts using Dart `double`; define decimal/currency precision and rounding explicitly.
5. **Concurrency and stock correctness:** add concurrent-sale tests for the same product, duplicate item lines, and multiple cash accounts; verify row locks and stock updates remain correct under contention.
6. **Idempotency contract:** test same key/same body replay, same key/different body conflict, operation UUID replay, duplicate operation IDs inside a batch, and retry after interrupted client response.
7. **Batch failure semantics:** verify whether the documented/client-required behavior is atomic-all-or-nothing or partial acceptance. Keep API response, server transaction, and local queue acknowledgment semantics identical.
8. **API hardening:** enforce request-size and batch-size limits at the route boundary, validate query limits and dates, add rate limiting/observability, and avoid leaking internal exception details.
9. **Neon connection security:** verify the actual Dart PostgreSQL driver's TLS configuration and connection-pooler compatibility; use a dedicated least-privilege API role and secret manager.
10. **Runtime evidence:** run Dart analysis, server unit tests, PostgreSQL integration tests, and controlled end-to-end acceptance tests in CI/staging. No result is asserted by this review.

## 3. Recommended implementation order

| Order | Work package | Exit evidence |
|---|---|---|
| 1 | Stabilize money/decimal model and transaction invariants | Unit + PostgreSQL tests for rounding, balance, stock and concurrent sales |
| 2 | Formalize sync contract and replay behavior | Contract tests for retries, duplicates, failures and queue acknowledgment |
| 3 | Implement control-plane identity, stores, memberships and roles | Auth tests proving unauthorized store selection is rejected |
| 4 | Implement server-side per-store database routing | Integration tests proving Store A credentials cannot read/write Store B |
| 5 | Implement per-store local database provider and safe adoption | Migration/adoption tests preserving existing data and isolating queues |
| 6 | Configure deployment, TLS, secrets, backups and restore | Staging health check, TLS verification, and a successful restore drill |
| 7 | End-to-end acceptance and release gate | Recorded sales, voucher, ledger, offline recovery and multi-device scenarios |

## 4. Release status

**Not production-ready.** The repository has a useful branch-scoped single-database API foundation and source-level transaction paths, but the approved multi-store isolation architecture is not implemented. No deployment, live Neon sale, complete sync acceptance, or production restore is claimed by this review.


## 2026-11-13 — Iteration 3 inventory/purchase foundation review

- Added a pure server-domain calculation layer at `server/lib/features/inventory_and_purchases/domain/purchase_and_fefo_calculator.dart` for purchase bonus arithmetic, weighted-average base cost, FEFO ordering, and carton-opening plans.
- The FEFO planner is deliberately not wired into `PostgresSalesSyncRepository._applySale`. It produces an allocation plan only; callers must lock batch rows and apply movements within the existing sale transaction.
- Existing `processBatch` still supports only `PARTY_CREATE`, `SALE_INVOICE`, and `VOUCHER`. Inventory/purchase operation types, routes, repositories, and queue mappings are not implemented in this milestone.
- No parallel server, PostgreSQL connection, auth scheme, or sync endpoint was introduced. No existing sync semantics were changed.
- The actual Flutter paths are rooted at `lib/`, not `app/lib/`. The existing `OfficialReportTemplate.preview` is available at `lib/core/pdf/official_report_template.dart`.
- Verification: source inspection completed; Dart/Flutter tools are unavailable in this execution environment, so new tests, analysis, and formatting were not run. No Neon/SQLite schema or data changed.
- Iteration 3 remains in progress and is not production-ready. See `docs/ITERATION_03_HANDOVER_AND_STATE.md` for exact next steps and unimplemented scope.


## Iteration 3 schema status (2026-11-13)

Migration `docs/neon/007_fefo_inventory_and_purchases_schema.sql` and rollback-only verification script `docs/neon/008_inventory_branch_isolation_tests.sql` have been added to the work branch. They are source artifacts only; neither was executed against PostgreSQL/Neon. The existing API process, branch bearer-token middleware, PostgreSQL connection, sales repository, and all-or-nothing sync batch remain unchanged. Inventory/purchase routes and repository operations are still not implemented. Migration 007 extends the existing `stock_movements` ledger and must be reviewed on PostgreSQL 18 before use.


## Iteration 3 API implementation update (2026-11-13)

Added `PostgresInventoryPurchasesReadRepository` and `InventoryPurchasesRoutes`. Read endpoints are:
- `GET /v1/inventory/warehouses`
- `GET /v1/inventory/locations`
- `GET /v1/inventory/batches`
- `GET /v1/inventory/movements`
- `GET /v1/inventory/stocktaking`
- `GET /v1/purchases/shortages`

They reuse the existing branch bearer-token map and require `X-Branch-Id`; repository SQL filters on that branch. Matching typed client reads and DTOs have been added. Purchase/return/stocktake/disposal/transfer client write methods are contracts only at this point: server write handlers, posting transactions, sync-batch integration, and SQLite local-first persistence remain outstanding. Do not treat these write methods as production-ready.


## Local SQLite status (2026-11-13)

The app schema is now version 2 with an additive v1→v2 migration in `Iteration3InventorySchema`. New local inventory/purchase tables and exact decimal TEXT fields are present in source; the old REAL columns remain for backward compatibility. Local purchase/stocktake/disposal/transfer transaction services, queue payload creation and sync acknowledgment behavior are not implemented yet. The local schema test is added; its Flutter test run is pending final CI result.
