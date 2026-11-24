# Operational API authorization and tenant boundary

## Enforcement

All sales, synchronization, inventory, purchasing and ledger route groups are mounted behind `ControlPlaneOperationalAccess`. The middleware runs before route handlers and:

1. Requires a valid, non-expired, non-revoked account bearer session.
2. Requires a selected `ACTIVE` store in that session. The session lookup also requires an active account, active membership, and a `READY` database binding.
3. Treats the session's store as authoritative. If `X-Store-Id` is supplied and differs from the session store, the request is rejected with 403.
4. Requires `X-Branch-Id` to be registered for that exact store in `cp_store_branches`. A branch ID belonging to another store is rejected with 403.
5. Enforces role permissions: GET/HEAD requires `viewOperations`; ordinary writes require `createOperations`; approval, disposal and transfer actions require `approveOperations`. Sync batches are inspected by operation type: batches containing `STOCKTAKE_APPROVE`, `DISPOSAL_APPROVE` or `STOCK_TRANSFER` require approval permission, while ordinary sale/purchase/create batches require create permission. The exact request body is replayed to the route handler after inspection.

The operational route handlers no longer authenticate using a caller-selected branch token. They use the account bearer token already authenticated by the middleware. The branch ID remains a branch-within-store identifier, not a tenant/store identity.

## Branch registration

Migrations `003_store_branch_registry.sql` and `004_store_scoped_branch_ids.sql` create and finalize `cp_store_branches`. A trusted provisioning/admin workflow must insert each branch mapping after creating that branch in its tenant database. Never accept this mapping from `X-Store-Id`, `X-Branch-Id`, a JSON body, or a mobile client. An absent mapping fails closed.

Example trusted provisioning statement (execute only from a trusted provisioning workflow after verifying the branch exists in the target store database):

```sql
INSERT INTO cp_store_branches(store_id, branch_id)
VALUES ('<trusted-store-uuid>', '<verified-branch-id>');
```

## Important rollout boundary

The API now rejects cross-store branch identifiers using the control-plane registry, but the current server bootstrap still constructs operational repositories from the single `PGDATABASE` connection. It does **not yet resolve `cp_store_database_bindings.database_key` into a separate per-store PostgreSQL connection**. Therefore this change is an API authorization barrier, not completion of physical per-tenant database routing/isolation. Do not onboard production stores with a shared operational database on the assumption that this completes the separate-database architecture.

Migration 004 removes the temporary global uniqueness rule for branch IDs. The registry now scopes uniqueness by `(store_id, branch_id)`, allowing different tenant databases to reuse local branch identifiers. The next required backend step is a secret-manager-backed store database connection resolver and request-scoped repository/use-case construction using the authenticated session's store ID. The resolver must fail closed for missing, unavailable or retired bindings. No secret-manager integration, tenant database provisioning, production migration or deployment was performed in this change.

## Tests

- Middleware tests cover missing/expired sessions, account A attempting to use store B's branch, account B attempting to use account A's branch, forged `X-Store-Id`, role restrictions, and allowed access to a branch registered to the active store.
- SQL assertions cover per-store branch registration, reject cross-account session membership, and verify identical branch IDs can be registered for different stores.
- The control-plane CI applies migrations 001, 002 and 003 to a disposable PostgreSQL database, analyzes Dart, and runs all `control_plane_*_test.dart` tests.

## CI verification

- GitHub Actions run [45481811752](https://github.com/mohmmed1abdallah2-source/Super-market/actions/runs/45481811752) completed successfully on code revision `93b4399c8825b200d8926ec38a1c8f694bbc6ac5`.
- Migrations 001, 002, 003 and 004 applied successfully to disposable PostgreSQL 18; rollback-only SQL assertions (including acceptance of the same local branch ID in two different stores) passed; `dart analyze` reported no issues; all 24 `control_plane_*_test.dart` tests passed, including cross-account/store isolation and mixed Sync Batch permission tests.
- No production database or deployment changes were performed.
