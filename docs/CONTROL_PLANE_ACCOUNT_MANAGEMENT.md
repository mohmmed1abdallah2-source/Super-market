# Control plane and account management — implementation milestone 1

**Branch:** `feature/control-plane-account-management`  
**Status:** schema migrations and domain tests passed in disposable PostgreSQL 18 CI; production deployment and HTTP/session integration are not performed.

## Scope

This milestone establishes the separate control-plane schema and the Dart domain boundary for verified account identities and store memberships. It is intentionally separate from the operational store databases.

## Database objects

- `cp_accounts`: account lifecycle and normalized unique email.
- `cp_account_identities`: external identity-provider subject mapping; provider subject is unique.
- `cp_stores`: opaque store UUID, display name and provisioning lifecycle.
- `cp_store_memberships`: account-to-store membership, role and status.
- `cp_store_database_bindings`: opaque secret-manager key only; no connection string or password.
- `cp_sessions`: hashed access-token identity, expiry/revocation and optional active store membership.

## Security invariants

1. The migration belongs in a dedicated control-plane database, not in any store database.
2. Account creation/resolution accepts verified identity-provider claims only. A client-supplied email or account ID is not proof of identity.
3. A store is visible only through an active membership; store activation requires an active, provisioned store.
4. `branch_id` is not used as a tenant/store identifier.
5. Raw access tokens and database credentials are not persisted in this schema.
6. The store database binding stores an opaque secret reference, never a password, hostname or connection URL.
7. This schema does not yet provision databases, issue cryptographically signed sessions, or replace the existing branch-token middleware.

## Apply and rollout

The migration is additive and transactional. Apply it only to a new, dedicated control-plane database after reviewing backup/restore and least-privilege roles. It has not been run against Neon or any production database. Do not point the existing API at it until the control-plane connection, verified identity provider, session issuer, membership authorization middleware and store database router are implemented and tested.

## Verification

Dart analysis and 11 control-plane domain/permission tests passed in GitHub Actions run `45294053429`. Both SQL migrations and rollback-only assertions passed against a disposable PostgreSQL 18 database. No production DDL/DML, credentials, provisioning, deployment or release was performed.
