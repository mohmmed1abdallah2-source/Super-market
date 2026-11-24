# Operational API authorization and tenant database isolation

## Request security boundary

All sales, synchronization, inventory, purchasing and ledger routes are behind ControlPlaneOperationalAccess. Before any operational handler runs, the middleware:

1. Validates the opaque bearer session, expiry and revocation state.
2. Requires the session's active store to be ACTIVE, its account and membership to be ACTIVE, and its database binding to be READY.
3. Treats the session store as authoritative and rejects a conflicting X-Store-Id.
4. Requires X-Branch-Id to be registered to that exact store in the control-plane branch registry.
5. Applies role permissions before routing the request.

The request's store context is written by middleware only. A caller-supplied store ID in a body, query, path or header cannot select a tenant database.

## Physical tenant database routing

The server no longer opens one global operational PGDATABASE connection. After authentication, it:

1. Reads the opaque database_key from the READY binding for the session's ACTIVE store.
2. Resolves that key through EnvironmentStoreDatabaseCredentialsProvider.
3. Opens a PostgreSQL connection for that store only.
4. Builds a fresh sales, sync, inventory, purchasing and ledger repository/use-case graph around that connection.
5. Closes the connection after the request completes.

No operational repository or connection is shared across stores. If a binding is missing, not READY, credentials are absent/invalid, or the database cannot be reached, the API fails closed with HTTP 503 before entering an operational route.

## Secret manager contract

The control-plane database stores only an opaque reference in cp_store_database_bindings.database_key. It must never contain a URL, password, username, host or serialized credentials.

The deployment platform must inject ERP_STORE_DATABASES_JSON from its secret manager. Its value is a JSON object keyed by the exact opaque database reference. Each entry contains host, port, database, username, password and optional ssl (defaults to true).

Example structure only; use secret-manager values and never commit real credentials:

    {
      "opaque-secret-reference-for-store-a": {
        "host": "db-a.example.internal",
        "port": 5432,
        "database": "store_a",
        "username": "store_a_app",
        "password": "<injected-secret>",
        "ssl": true
      }
    }

The environment variable is a deployment bridge to the secret manager, not a place to hardcode secrets in repository files. Rotate credentials in the secret manager and update the injected value without changing the control-plane database. Use a distinct least-privilege PostgreSQL role per store.

The control-plane connection remains configured separately using ERP_CONTROL_PLANE_PGHOST, ERP_CONTROL_PLANE_PGDATABASE, ERP_CONTROL_PLANE_PGUSER, ERP_CONTROL_PLANE_PGPASSWORD and optional ERP_CONTROL_PLANE_PGSSL (default true). The old global operational PGHOST/PGDATABASE/PGUSER/PGPASSWORD settings are no longer used by the API bootstrap.

## Branch registration

Migrations 003_store_branch_registry.sql and 004_store_scoped_branch_ids.sql maintain a trusted mapping keyed by (store_id, branch_id). Different tenant databases may reuse the same local branch ID. Register branches only through trusted provisioning after verifying the branch exists in the target tenant database; never accept mappings from mobile clients.

## Tests

- Middleware tests cover missing sessions, forged store IDs, cross-account/store branch attempts, role restrictions and mixed sync-batch privileges.
- Resolver unit tests cover store-key lookup, missing READY bindings, missing secrets and malformed credentials.
- PostgreSQL integration test creates two independent tenant databases with the same branch ID but different marker rows. It verifies that each store resolves to its own database and cannot read the other store's row.
- CI applies control-plane migrations 001–004 to a disposable control-plane database, creates two disposable tenant databases, runs SQL assertions, Dart analysis, middleware/resolver tests and the tenant database routing integration test.

## Rollout boundary

This implements request-scoped physical database routing in the API code. Production onboarding remains blocked until the deployment environment injects ERP_STORE_DATABASES_JSON from its secret manager, every store has a READY binding, each database has its tenant schema and least-privilege role, and branch provisioning is complete. No production database, credentials or deployment were changed by this repository work.
