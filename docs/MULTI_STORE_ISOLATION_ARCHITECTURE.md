# Multi-store isolation — architecture decision and implementation plan

**Status:** Architecture decision approved for implementation; not yet implemented in application code or deployed.
**Applies to:** Flutter local databases, Dart API, PostgreSQL, synchronization, authentication, reporting and backups.
**User requirement:** One owner account may access multiple stores and chooses the active store after login. Every store remains completely independent, even when the same person owns all stores.

## 1. Non-negotiable invariants

1. A store is a tenant and a hard data-isolation boundary. Ownership does not imply shared business data.
2. No product, barcode, stock, purchase, sale, customer, supplier, debt, voucher, cash account, journal, report, PDF or sync operation may be visible to another store.
3. Selecting another store changes the active data context; it does not copy, merge, reconcile or share business records.
4. A device may hold more than one store, but each store must have a separate SQLite database file and separate pending-sync queue.
5. The API must derive the active store from a verified authenticated membership/session. A client-supplied store ID is only a requested context and must be checked against that membership.
6. A request authenticated for Store A must never be able to query or mutate Store B, including by changing path parameters, headers, UUIDs, invoice IDs or replaying a batch.
7. A retry of a financial operation must be idempotent inside the same store. Idempotency keys and operation UUIDs must be scoped to the store database.
8. Backups and restore procedures must operate per store and must be tested. A restore for one store must not overwrite another store.
9. The current local database and existing business records must not be deleted, renamed or migrated destructively as part of introducing this architecture.
10. No production readiness or successful migration is claimed until code, automated tests, restore drills and a live controlled acceptance test have actually passed.

## 2. Chosen database topology

Use one PostgreSQL cluster initially, with a separate PostgreSQL database and separate least-privilege login role for each store.

- A small **control-plane database** contains only account identity, store directory entries, owner/user-to-store memberships, store status, and the opaque database credential reference needed by the server to route a session.
- Each store receives its own database, for example store_<opaque_id>. Each database contains only that store's operational/business data and its own migrations.
- The API connects to the control-plane database for authentication and membership lookup, then obtains a connection to the selected store database using server-held credentials.
- Store database credentials must never be sent to Flutter, included in a repository, or returned in API responses.
- Store roles must not have CONNECT permission to other store databases. The API must not use a shared superuser for normal requests.
- PostgreSQL schemas and branch_id filters alone are not accepted as the primary tenant isolation boundary for this product requirement.
- Existing branch_id remains an operational branch/location identifier inside one store. It must not be repurposed as the global store/tenant identifier.

This topology gives strong logical database separation while sharing the initial VM and PostgreSQL cluster to fit the zero-dollar infrastructure constraint. It does not protect against loss of the entire VM or cloud account; independent encrypted backups are mandatory.

## 3. Local SQLite topology

Replace the current process-wide single-database assumption with a store-scoped database provider.

- Use a stable opaque store UUID to derive a safe local filename, e.g. stores/<store_uuid>/supermarket_erp.db.
- Never use a store display name as a path or database identity.
- Keep each store's tables, sync_queue, quota/transport metadata and migration history inside its own file.
- Switching stores must stop or drain in-flight work, close the old database handle, open the selected store file, and rebuild/rebind all store-scoped providers/services before rendering the store workspace.
- Do not keep a single DatabaseHelper.instance shared across multiple stores.
- Any background sync task must carry an immutable store context and use only the matching database file and server membership.
- The device's cached store directory may contain display names and membership metadata only; it must not contain another store's business rows.

### Existing data preservation

The current code opens one SQLite file named supermarket_erp.db, with SchemaBuilder.version = 1. Before enabling store switching, implement a one-time, transactional adoption flow that:
1. creates the first store identity after the owner has authenticated/claimed the existing installation;
2. copies or atomically migrates the existing database to that store's new scoped path;
3. validates row counts, foreign keys, journal balance and sync queue counts;
4. retains a recoverable original backup until validation and a successful restore test are complete;
5. only then switches the application to the new path.

Never silently assign existing records to a newly created second store. Never clone the first store's business data into another store.

## 4. Authentication and store selection

Target user flow:

1. Owner signs in once using the account identity service.
2. API returns only stores for which the account has an active membership.
3. Owner selects one store.
4. API issues/returns a short-lived store-scoped session context, bound server-side to the authenticated account, selected store and allowed role.
5. Flutter opens that store's local database and configures all store-scoped providers and the sync transport.
6. Switching stores invalidates the old active context, drains/cancels old-store requests safely, opens the new local database and obtains a new scoped session.
7. On a device that is temporarily offline, an explicitly cached, previously verified membership may allow local work only for a store already provisioned on that device. Offline work remains in that store's local queue and cannot be uploaded until a valid store-scoped session is re-established.

Authorization rules:
- Never trust X-Store-Id, branch_id, a URL parameter or a payload field by itself.
- Resolve store_id from a verified token/session and membership record.
- Check role and store membership on every request.
- The database router maps the verified store UUID to a server-side database configuration. It must reject unknown, disabled or unprovisioned stores.
- Do not expose database names, hosts, usernames, passwords or connection strings to clients.
- Do not keep a single long-lived PostgreSQL connection and merely change a branch_id variable between requests. Use a correctly scoped pool/connection per store database.

## 5. API and synchronization contract

Introduce a store-scoped API context and versioned endpoints for:
- sign-in / refresh / sign-out;
- list stores available to the owner;
- select or activate a store;
- provision a store (authorized owner action);
- sync batches for the active store;
- health/status for the active store without disclosing infrastructure secrets.

For all business endpoints:
- store_id is resolved from the authenticated context, never accepted as an authority from the body.
- branch_id remains optional operational scope within that store and must be validated against that store's own database.
- All IDs, foreign keys, invoice sequences, customer codes, product barcodes, vouchers, cash accounts, journals and idempotency records are local to the selected store database.
- A sync batch is processed only against the database selected by its verified session.
- The client acknowledges queue rows only after the server has committed the batch and returned accepted operation UUIDs.
- Replayed identical batches return the prior result; reusing an idempotency key with different content returns a conflict.
- Cross-store UUID replay must fail because the request is routed to the selected store database and has no authority to reach another store.
- Partial sync failures must leave rejected or unprocessed operations retryable; do not mark the whole batch as synced.

The existing /v1 API currently uses branch-scoped bearer tokens and a single PostgreSQL connection opened from PGHOST/PGDATABASE/PGUSER/PGPASSWORD. This is a single-database model and must not be described as multi-store-ready.

## 6. Current repository findings (reviewed on 2026-11-10)

The following are confirmed by source inspection on feature/official-pdf-report-template:

- lib/main.dart opens DatabaseHelper.instance.database before the app starts and the login gate is local username/password.
- lib/data/database/database_helper.dart always opens one fixed supermarket_erp.db file.
- lib/data/database/schema_builder.dart is version 1. Many rows carry branch_id, but that is not an isolated store database. Some identifiers/unique constraints are global within that one SQLite file (for example products SKU and barcodes).
- lib/data/services/firebase_free_tier_sync_service.dart sends branch-scoped Firestore batches and daily summaries; it is not a PostgreSQL store-aware transport.
- lib/providers/pos_and_ledger_provider.dart receives a branchId argument for queries and sync; it depends on the singleton database helper.
- server/bin/server.dart opens exactly one PostgreSQL connection from environment variables and reads ERP_BRANCH_TOKENS.
- Existing PostgreSQL migrations create branch-scoped business tables in one database. Foreign keys and unique constraints are not a substitute for per-store database separation.
- docs/POSTGRES_DEPLOYMENT_AND_SYNC.md explicitly says production authentication/session wiring is not yet present and no production database/provider/credentials are provisioned.
- Existing PostgreSQL API and integration tests cover POS/ledger/sync behavior, but they do not prove owner-to-many-store membership, database-per-store routing, local database switching, or cross-store isolation.

These findings mean the existing code is a useful POS/ledger foundation, but it is **not yet safe to enable multiple stores under one owner**.

## 7. Required implementation phases

### Phase A — control plane and store provisioning
- Add control-plane migration for accounts, stores, memberships, store status and secret references.
- Add a provisioning service that creates a database and dedicated role for a store, applies store migrations and registers its opaque database reference.
- Enforce naming/identifier validation and parameter-safe database creation. Never interpolate user-controlled store names into SQL identifiers.
- Add tests proving a member can list only their stores and cannot activate another owner's store.

### Phase B — local store context
- Introduce store directory, active-store session and store-scoped database factory.
- Add local schema migration/version tracking per store.
- Implement safe switching and the existing-database adoption flow.
- Rebind providers and services to the active store database; remove implicit singleton access from store-scoped code.

### Phase C — API routing and isolation
- Replace branch-token-only authentication with account + membership + store-scoped authorization.
- Add a connection registry/pool that selects the correct database from verified session claims.
- Route every ledger, POS, voucher and sync repository through the selected store database.
- Keep branch_id as an internal branch/location identifier only.

### Phase D — sync and offline safety
- Add a PostgreSQL sync transport in Flutter and bind it to the active store session.
- Keep each store's queue local to its own database.
- Verify idempotency, retries, lost responses, device restart, offline switching and concurrent devices.

### Phase E — backup, restore and production acceptance
- Schedule encrypted per-store logical backups and separate control-plane backups.
- Copy backups outside the VM/cloud account (for example to an owner-controlled computer or separately controlled storage).
- Test restoring Store A without touching Store B and vice versa.
- Add monitoring for failed backups, failed sync, disk pressure and unavailable databases.
- Run cross-store penetration/authorization tests and a controlled real-world acceptance test before live accounting data is used.

## 8. Mandatory isolation test matrix

1. Owner has Stores A and B; store list returns exactly A and B.
2. User belonging only to A cannot list, select or activate B.
3. Change a request header/body/path from A to B: API rejects it and no B database query is made.
4. Reuse A's token against B's invoice, customer, product, voucher, cash account, journal or sync endpoint: reject.
5. Create identical product codes, barcodes, customer codes and invoice numbers in A and B: both succeed independently and remain unrelated.
6. Submit a batch to A, then replay its UUIDs and idempotency key to B: no B records are created and A's response is not leaked.
7. Switch A → B → A on the same device: each store reopens its own SQLite file and its own pending queue.
8. Disconnect the network, create sales in A and B separately, reconnect, and verify each queue syncs only to its own server database.
9. Fail a sync request after server commit but before client acknowledgement: retry must not duplicate financial effects.
10. Back up A and B, restore A to a test database, and prove B is unchanged.
11. Run two concurrent devices for the same store and verify stock, invoice numbering and idempotency remain correct.
12. Confirm all reports, PDF exports and dashboards query only the active store database.

## 9. Deployment and cost constraints

- Target infrastructure budget remains USD 0/month.
- A single eligible Oracle Cloud Always Free VM may host the API and PostgreSQL cluster for initial controlled use, subject to account/region capacity and Oracle's free-tier terms.
- The VM is a single failure domain. A database-per-store design does not make the VM highly available.
- Do not claim zero risk, guaranteed uptime, or guaranteed data preservation from a free VM.
- Keep PostgreSQL private; expose only the HTTPS API and tightly restricted administration access.
- If the free VM is reclaimed, suspended or the cloud account becomes inaccessible, recovery depends on independently stored backups. Therefore an off-VM/off-account backup is a release gate, not an optional enhancement.

## 10. Release gate

Do not connect real stores or enable live financial synchronization until Phases A–E have been implemented and the full isolation test matrix, migration validation, backup restoration drill and end-to-end acceptance tests have passed. Existing single-store operation must remain available throughout the migration and rollback plan.
