# Control-plane implementation — phase 1

**Branch:** `feature/control-plane-store-sessions`  
**Base:** `04bc6850f922461bbb96227bc444fd1795b7295c`  
**Status:** Schema foundation added; runtime authentication, provisioning, routing and session endpoints are not yet complete.

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

This commit adds a migration file and this implementation record only. It has not been applied to any database. No production Neon DDL/DML, database creation, credentials, deployment, or live session was performed. Runtime support is not complete and no tests are claimed as passed.
