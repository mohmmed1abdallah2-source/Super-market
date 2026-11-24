# Control-plane account API

**Branch:** `feature/control-plane-account-management`

## Routes

These routes are mounted only when the dedicated control-plane database settings and Google OAuth client ID are configured. They are separate from branch-token operational APIs.

### Sign in

`POST /v1/auth/login`

Request:

```json
{
  "provider": "google",
  "idToken": "<Google-issued ID token>"
}
```

The server validates the token with Google's HTTPS tokeninfo endpoint, pins the configured OAuth audience, checks issuer, expiry, subject and verified email, resolves the control-plane account, and issues a cryptographically random 256-bit bearer token. Only SHA-256 of the API token is persisted in `cp_sessions`. Raw provider tokens and API bearer tokens are not stored.

Response includes `accessToken`, `tokenType`, `expiresAt`, `accountId` and the account's current store memberships. The API bearer token is returned once and must be stored securely by the client.

### List stores

`GET /v1/stores`

Requires `Authorization: Bearer <accessToken>`. Returns only stores attached to an active membership of an active account. Database binding references and credentials are never returned.

### Activate a store

`POST /v1/stores/{storeId}/activate`

Requires an authenticated session and the OWNER role for the store. The control-plane service permits transition from `PROVISIONING` or `SUSPENDED` to `ACTIVE` only when the store's opaque database binding is `READY`. Closed/failed stores and invalid lifecycle transitions are rejected. After the lifecycle transition, the store is selected in the current session.

This endpoint activates the store lifecycle; it does not provision the database or create credentials.

### Select an already active store in the session

`POST /v1/session/active-store`

Request: `{"storeId":"<store UUID>"}`

Requires an active API session, an active account, an active membership for the requested store, and store lifecycle status `ACTIVE`. The server writes the selected store and exact membership ID into that session. The client cannot set an account ID or membership ID.

### Sign out

`POST /v1/auth/logout`

Revokes the current session and clears its active store context.

## Runtime configuration

Configure the following server environment variables to mount these routes:

- `ERP_CONTROL_PLANE_PGHOST`
- `ERP_CONTROL_PLANE_PGPORT` (optional, defaults to 5432)
- `ERP_CONTROL_PLANE_PGDATABASE`
- `ERP_CONTROL_PLANE_PGUSER`
- `ERP_CONTROL_PLANE_PGPASSWORD`
- `ERP_GOOGLE_OAUTH_CLIENT_ID`

The control-plane database must be the dedicated database with migrations 001 and 002 applied. Do not point it at a store database. If `ERP_CONTROL_PLANE_PGHOST` is absent, the existing operational API starts without mounting account routes. If it is present but another required setting is absent or invalid, startup fails closed.

Google ID-token verification currently supports the Google provider only. Other providers must not be enabled until a separate verifier is implemented and configured. Deploy behind TLS and apply gateway-level rate limiting to login; do not log Authorization headers or response tokens.

## Security and rollout notes

- The actor account is derived exclusively from a verified bearer session, never from JSON, query parameters or caller-supplied identity headers.
- Session token hashes, not raw bearer tokens, are persisted.
- Store selection requires current active membership and an `ACTIVE` store.
- The existing branch-token middleware remains unchanged for legacy operational routes. This work does not yet bind all sales, inventory, purchasing and ledger routes to the active control-plane store session.
- No production database was modified and no secret or OAuth client credential was added to the repository.
- CI must verify server analysis and control-plane tests before merge. Runtime credentials and Google OAuth client ID must be configured separately by the deployment operator.
