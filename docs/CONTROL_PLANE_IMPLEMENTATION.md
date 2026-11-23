# Control-plane implementation — phase 1

**Branch:** `feature/control-plane-store-sessions`  
**Base:** `04bc6850f922461bbb96227bc444fd1795b7295c`  
**Status:** Control-plane schema, identity/store-selection and store-session endpoints, password/token primitives, a session-derived database router, disposable-PostgreSQL assertions and CI wiring are present. Provisioning, secret-store integration, refresh endpoint, legacy business-route migration and production hardening remain incomplete.

## Scope and separation

The control plane is a separate PostgreSQL database. The migration at
`server/control_plane_migrations/20261124_001_control_plane.sql` belongs only
there and must not be run against a store's business database.

It defines:
- accounts with normalized unique email and a versioned password-hash field;
- stores with opaque UUIDs, lifecycle status, and server-only database/role/secret references;
- account-to-store memberships with constrained roles and lifecycle states;
- store-scoped sessions containing hashes of opaque access/refresh tokens, never raw tokens;
- provisioning-operation state to make the multi-step database creation workflow observable and recoverable.

The schema intentionally does not store PostgreSQL passwords or connection strings. `database_secret_ref`
must resolve through a server-side secret-store adapter. A secret reference is not itself a credential.

## Security invariants

- The API runtime role must have no DDL privileges in the control-plane or store databases.
- Control-plane migration execution must use a separate migration identity.
- Store database names and roles are generated only from opaque UUIDs; display names are never SQL identifiers.
- A client-provided store ID is a selection request only. The API must verify active membership and bind the resulting session to that store.
- Session lookup uses a hash of a high-entropy opaque token. Raw access and refresh tokens are returned only once to the authenticated client.
- Database routing must resolve `store_id` from the verified session, then load connection material by secret reference. It must not accept database names, roles, hosts or credentials from a request.
- `branch_id` remains an in-store operational branch identifier.

## Security primitives added

- Added PBKDF2-HMAC-SHA256 password hashing with a versioned encoded format, per-password random 16-byte salt, 600,000 default iterations, bounded accepted iteration counts, and constant-time digest comparison.
- Added 256-bit cryptographically random opaque session tokens; only SHA-256 token digests are intended for database persistence.
- Unit tests cover correct/wrong passwords, malformed hashes, weak passwords, and token uniqueness. CI must verify these tests before this code is considered accepted.
- These primitives are not yet wired into account sign-in or session endpoints. Rate limiting, account lockout policy, TLS enforcement and secret management remain mandatory.

## Required next implementation steps

1. Implement password verification with a reviewed password KDF and rate limiting; never use a fast unsalted hash for passwords.
2. Implement account sign-in, refresh, revoke, list-memberships and store activation handlers.
3. Implement a secret-store interface and an audited adapter; do not persist plaintext credentials in PostgreSQL or repository files.
4. Implement a provisioning saga using an administrative connection, validated generated identifiers, dedicated least-privilege store roles, per-store database creation and store migration execution. Record every step in `cp_provisioning_operations`; compensate safely on failure.
5. Implement a bounded per-store connection pool registry with lifecycle/eviction and no cross-store connection reuse.
6. Add PostgreSQL integration tests for membership authorization, token revocation/expiry, database-per-store routing, and A-to-B request tampering.
7. Wire existing business routes through a verified `StoreRequestContext`. Do not silently keep the legacy branch-token path enabled as a production fallback.
8. Add the local per-store SQLite adoption/switch flow only after the server session contract is stable.

## Validation boundary

The branch now includes a disposable PostgreSQL schema assertion script and a CI step that creates a separate `control_plane_test` database, applies this migration there, and runs the assertions. The migration has not been applied to any persistent or production database. No production Neon DDL/DML, database creation, credentials, deployment, or live session was performed. Runtime support is not complete and no tests are claimed as passed.


## Runtime foundation added

- `PostgresControlPlaneRepository` authenticates active accounts against the versioned password hash, lists only active memberships, issues a short-lived one-time login ticket, exchanges that ticket for a store-scoped access/refresh session, resolves access tokens to an immutable `StoreRequestContext`, and revokes sessions.
- `ControlPlaneRoutes` exposes `POST /v1/auth/sign-in`, `GET /v1/stores`, `POST /v1/stores/activate`, and `POST /v1/auth/sign-out`.
- The server can open a separate control-plane connection when all `CONTROL_PLANE_PG*` settings are configured. The settings are optional during staged rollout; the old branch-token business routes remain unchanged and must not be considered production multi-store authorization.
- `StoreDatabaseRouter` resolves a descriptor from the control plane using the verified context, validates database and role names against the opaque store UUID, obtains the password through a `StoreSecretStore` interface, opens a dedicated per-operation connection and closes it after the callback. It does not share a connection across stores.
- The actual secret-store adapter and provisioning workflow are intentionally not faked. Until a real secret manager and provisioner are installed, no store database can be safely created or routed end-to-end.

## Current endpoint flow

1. Sign in with email/password to receive a short-lived login ticket and active store list.
2. Exchange the one-time ticket and selected store UUID at `/v1/stores/activate`.
3. Use the returned store-scoped access token for `GET /v1/stores` and sign-out. Business routes are not yet wired to this context.
4. Store database connection code accepts only a server-generated `StoreRequestContext`, never a client-provided database name or credential.

## Outstanding security and delivery gates

- Add rate limiting, account lockout/backoff, refresh-token rotation, password-reset/invitation lifecycle and audit events.
- Implement the production secret-store adapter and the provisioning saga (create least-privilege role/database, run store migrations, save secret reference, mark store active; recover/compensate partial failure).
- Wire every business route and sync batch to the verified context and remove static branch-token auth from production paths.
- Add integration tests for sign-in, membership denial, token expiry/revocation, refresh replay, concurrent store switching and actual database A/B isolation.
- Run current CI on the exact head and fix any failures before considering this slice accepted.
