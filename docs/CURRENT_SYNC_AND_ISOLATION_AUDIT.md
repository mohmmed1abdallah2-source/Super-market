# Current Sync and Isolation Audit

**Reviewed:** 2026-11-23  
**Repository:** `mohmmed1abdallah2-source/Super-market`  
**Branch:** `feature/multi-store-isolation-foundation`  
**Reviewed source commit:** `12e1e9fe7c08aebb315909cec37ade56646d0397`

This is a source-and-CI review, not a production penetration test or a live Neon inspection.

## Verified CI baseline

The reviewed commit passed both current workflows:

- Flutter Validation: [run 45255890755](https://github.com/mohmmed1abdallah2-source/Super-market/actions/runs/45255890755)
  - Flutter validation, Android APK, Web build, Windows build, and PostgreSQL-enabled server validation jobs all succeeded.
  - PostgreSQL suite: **31 tests passed**.
- Delivery Gates: [run 45255891002](https://github.com/mohmmed1abdallah2-source/Super-market/actions/runs/45255891002)
  - Dart API analysis/tests and Flutter analysis/tests/Android APK gates succeeded.

The PostgreSQL job uses a disposable PostgreSQL 18 test database. This does not prove that production Neon has been migrated or that the API has been deployed.

## Sync implementation now present

The server Sync Batch use case accepts these operation types:

- `PARTY_CREATE`
- `SALE_INVOICE`
- `VOUCHER`
- `PURCHASE_INVOICE`
- `PURCHASE_RETURN`
- `STOCKTAKE_APPROVE`
- `DISPOSAL_APPROVE`
- `STOCK_TRANSFER`

The implementation currently has the following safeguards:

1. One PostgreSQL transaction covers the entire batch; an operation failure aborts the batch.
2. Duplicate operation IDs in one request are rejected.
3. Operation receipts are scoped by `(branch_id, operation_id)`.
4. New receipts persist canonical payload hashes; reusing an operation ID with a different type or payload is rejected.
5. Transaction-scoped advisory locks serialize concurrent attempts for the same branch/operation identity.
6. The local SQLite queue retains a stable operation UUID across retries.
7. The client validates that accepted IDs exactly equal the submitted operation IDs before marking queue rows `BATCHED_SENT`. Missing, duplicate, or unexpected acknowledgements leave the queue retryable.
8. The PostgreSQL integration suite includes a mixed stocktake + disposal + transfer batch, replay, changed-payload rejection, and rollback assertions.

Compatibility limit: receipts created before payload hashes existed have a NULL hash. Their historic payload cannot be reconstructed, so replay compatibility can verify the operation type but cannot prove that the old payload matches.

## Branch isolation: what is implemented

- HTTP routes read `X-Branch-Id` and require a bearer token mapped to that branch in server environment configuration.
- The branch ID is passed into repository queries and write operations.
- Inventory posting validates branch ownership for warehouses, batches, documents, and approver records.
- PostgreSQL tests use separate branch IDs and exercise branch-scoped operations.

This is **branch-level isolation inside one database**, not the approved multi-store isolation architecture.

## Multi-store isolation: still not implemented

The reviewed server bootstrap opens one PostgreSQL connection from a single `PGHOST/PGDATABASE/PGUSER/PGPASSWORD` configuration and constructs all repositories around it. Authentication is currently a static branch-token map (`ERP_BRANCH_TOKENS`, with a development fallback `ERP_API_TOKEN`); it is not an owner/user identity and membership system.

The agreed target remains:

- a separate control-plane database for identities, stores, and memberships;
- an independently provisioned PostgreSQL database and database role per store;
- trusted server-side store selection from an authenticated session and verified membership;
- `branch_id` retained as a location/branch within a store, not used as the store identity;
- independent local SQLite data/queue context per store, with a safe migration path for existing local data.

The current local engine uses the shared `DatabaseHelper` database and stores `branch_id` on queue rows. That is not equivalent to a separate SQLite database per store.

## Remaining blockers and recommended order

1. **Authentication/control plane:** implement real user sessions, store membership checks, and server-derived store context before allowing production use. Do not treat `X-Branch-Id` plus a shared static token as production authentication.
2. **Database-per-store routing:** add a trusted store registry and connection resolver; prove that a request cannot select another store by changing a header, body field, or record ID.
3. **Local multi-store isolation:** make the local database and sync queue store-aware with independent per-store contexts; preserve existing SQLite data through a non-destructive migration.
4. **HTTP-level security tests:** cover missing/invalid tokens, token/branch mismatch, cross-branch IDs, unauthorized approvers, and cross-store attempts for read, write, and batch replay routes.
5. **Client integration:** verify the real application bootstrap configures the authenticated API client and that offline queue replay works after process restart and network interruption. The engine exposes API-client injection; source presence alone is not proof of a configured live application session.
6. **Financial precision:** complete the remaining audit of money calculations in live sales/voucher paths; inventory quantity/cost calculations already use fixed-scale decimal primitives in the newly added inventory approval/transfer paths, but this does not certify every financial path.

## Safety boundary

No Neon production DDL/DML, production data changes, deployment, or release was performed during this review. Continue to use disposable PostgreSQL for integration tests until the control plane, authentication, backups, and migration/restore procedures are reviewed.


## Update — stocktaking create contract (2026-11-24)

The client already exposed `createStocktakingSession` and sent POST `/v1/inventory/stocktaking`, while the server previously registered only GET and approval POST. The missing endpoint is now implemented as a separate create phase:
- one PostgreSQL transaction inserts the `COUNTING` header and all counted lines;
- branch, warehouse, product and FEFO batch ownership are verified;
- expected batch quantity and conversion factor are server-sourced and optional client snapshots are checked;
- duplicate batch lines and invalid carton/loose quantities are rejected;
- stable session/line IDs make identical retries replay-safe and changed payloads conflict;
- creation does not adjust stock or post a journal; the existing approval operation remains the only posting step.

A PostgreSQL integration test now covers creation, persistence, replay, changed-payload rejection, and approval. CI verification is pending on the latest source commit. No production database change or deployment was made.
