# PostgreSQL deployment and offline synchronization

## Current status

The repository contains the Dart API, PostgreSQL migrations, a local PostgreSQL
container stack, and PostgreSQL-backed integration tests. No production database
provider, production hostname, or production credentials are provisioned by this
repository. The Compose stack is a self-managed deployment option for development
or a controlled server; it is not a public production deployment by itself.

## Start a local PostgreSQL + API stack

1. Install Docker Engine and the Docker Compose plugin.
2. Copy `.env.server.example` to `.env.server`.
3. Replace both example secrets with long random values. Do not commit
   `.env.server`.
4. Start the stack:

   ```sh
   docker compose --env-file .env.server -f docker-compose.postgres.yml up --build -d
   ```

5. Check the API:

   ```sh
   curl http://localhost:8080/health
   ```

The PostgreSQL image runs migrations in filename order on first initialization
of an empty data volume. Migration 001 creates the core branch/product schema;
migration 002 creates the POS, ledger, voucher, cash-account, and sync schema.
PostgreSQL's init directory is only executed for a newly initialized data
directory. Existing databases must be migrated deliberately; do not delete a
volume to force migrations on a database containing business data.

## Required server environment

- `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`
- `ERP_BRANCH_TOKENS`: JSON object mapping each branch ID to a unique bearer
  token, for example `{"branch-main":"<secret>"}`
- `PORT` and `ERP_HOST` for the HTTP listener

The API checks the bearer token and `X-Branch-Id` together. Do not expose
PostgreSQL directly to the public internet. For remote deployments, use a
private database network, TLS at the API ingress, restricted database roles,
automated encrypted backups, and secret rotation. Use a managed PostgreSQL
provider's connection-pooler settings if required by that provider.

## Flutter client connection contract

The Flutter client must create `ApiClient` with:
- `baseUri`: the deployed HTTPS API origin (not the PostgreSQL connection URL)
- `accessTokenProvider`: returns the current branch-scoped bearer token
- `branchIdProvider`: returns the active branch ID

Then pass that configured client to `PosAndLedgerProvider.configureApiClient`.
The current application provider exposes this configuration hook, but the
repository does not yet have a production authentication/session source that
can safely supply the token and branch ID. Do not hardcode secrets in Dart
source or commit them as `--dart-define` values in a public repository.

Offline-first behavior remains: local SQLite writes are queued and retried with
stable operation IDs and idempotency keys. The server batch endpoint accepts at
most 100 operations. The client marks accepted operations as sent only after a
successful server response; a failed request must leave them retryable.

## PostgreSQL integration tests

The GitHub Actions server job starts PostgreSQL 16, applies both migrations,
then runs `dart analyze` and `dart test` with `PGTEST_*` variables. This
exercises real SQL, journal balancing, stock updates, payment allocation,
idempotent retries, and customer settlement against PostgreSQL.

For a local run, export the same `PGTEST_HOST`, `PGTEST_PORT`,
`PGTEST_DATABASE`, `PGTEST_USER`, and `PGTEST_PASSWORD` values after
starting the Compose database, then run:

```sh
cd server
dart pub get
dart analyze
dart test
```

## Production rollout checklist

- Choose and provision the production PostgreSQL provider and region.
- Create a least-privilege application role; do not use the database superuser.
- Apply migrations 001 and 002 to a backup-protected empty/staging database first.
- Configure the API host with database credentials and per-branch bearer tokens
  using the hosting provider's secret manager.
- Deploy the API behind HTTPS and verify `/health`.
- Wire the real authentication/session layer to `ApiClient` and configure
  `PosAndLedgerProvider` after branch selection.
- Run a controlled end-to-end acceptance test before enabling sync for live sales.
- Confirm backup restoration and token rotation procedures.
