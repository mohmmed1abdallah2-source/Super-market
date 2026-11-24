# Control plane — stores, memberships and permissions

**Branch:** `feature/control-plane-account-management`  
**Milestone:** store and membership administration foundation.

## Implemented

- Store creation is transactional: an active account creates a `PROVISIONING` store and receives its initial active `OWNER` membership in the same control-plane transaction.
- Active store listing returns only stores for which the account has an active membership and the account itself is active. It never exposes database binding keys.
- Membership invitations create `INVITED` rows for existing active accounts. The invited account accepts only its own invitation; an invitation cannot be activated by the inviter.
- Role changes and member suspension/revocation are transactional and validate the actor's current active membership and permission against the control-plane database.
- Admins cannot grant equal/higher roles or administer an owner. The owner role cannot be assigned through ordinary invite/role endpoints.
- The database enforces at most one active owner per store. The repository refuses to suspend or revoke the owner.
- Permission matrix is centralized in Dart: OWNER, ADMIN, MANAGER, STAFF and READ_ONLY.

## Permission summary

| Role | Store settings | Invite members | Change roles | Suspend members | View operations | Create operations | Approve operations |
|---|---:|---:|---:|---:|---:|---:|---:|
| OWNER | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| ADMIN | Yes (settings) | Yes | Yes* | Yes* | Yes | Yes | Yes |
| MANAGER | No | Yes* | No | No | Yes | Yes | Yes |
| STAFF | No | No | No | No | Yes | Yes | No |
| READ_ONLY | No | No | No | No | Yes | No | No |

`*` Admins/managers may act only below their own role rank. Owner assignment/transfer is intentionally excluded until a dedicated, audited transfer workflow exists.

## Store lifecycle

- A new store is created as `PROVISIONING` and is not selectable for operational use.
- Only the OWNER may suspend or close a store.
- A store may become `ACTIVE` only after its opaque database binding exists with status `READY`.
- A suspended store can be reactivated only while its binding remains `READY`; closed and failed stores are terminal in this workflow.

## Security boundaries / remaining integration

- The PostgreSQL repository must receive a connection to the dedicated control-plane database, never the store database.
- Service callers must derive `accountId` from a verified server-side session. Never accept actor account IDs as proof from request JSON or headers.
- The current API still uses branch-token authentication for operational routes. This milestone does **not** silently replace that middleware or expose unauthenticated store-management endpoints.
- API route integration waits for the verified control-plane session issuer and middleware. No untrusted client-supplied `storeId` can authorize access: every repository operation rechecks active membership and role.
- Store creation leaves the store in `PROVISIONING`; database provisioning and transition to `ACTIVE` are a later controlled workflow.
- No database binding credentials, connection strings, or passwords are returned to clients.

## Migrations and verification

Apply `server/control_plane/migrations/001_control_plane.sql` then `002_store_membership_invariants.sql` to a separate control-plane database only. Migration 002 adds a partial unique index for one active owner per store and an invitation lookup index. The CI workflow uses a disposable PostgreSQL database; no Neon/production database was changed.
