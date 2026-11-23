-- Control-plane database only. Never apply this migration to a store business database.
-- Apply with a dedicated control-plane migration identity, not the API runtime role.
BEGIN;

CREATE TABLE IF NOT EXISTS cp_accounts (
  account_id UUID PRIMARY KEY,
  email_normalized TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  password_hash_version SMALLINT NOT NULL DEFAULT 1 CHECK (password_hash_version > 0),
  status TEXT NOT NULL DEFAULT 'ACTIVE'
    CHECK (status IN ('ACTIVE', 'LOCKED', 'DISABLED')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (email_normalized = lower(btrim(email_normalized))),
  CHECK (length(email_normalized) BETWEEN 3 AND 320),
  CHECK (length(display_name) BETWEEN 1 AND 160)
);

CREATE TABLE IF NOT EXISTS cp_stores (
  store_id UUID PRIMARY KEY,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PROVISIONING'
    CHECK (status IN ('PROVISIONING', 'ACTIVE', 'SUSPENDED', 'PROVISION_FAILED', 'DECOMMISSIONED')),
  database_name TEXT NOT NULL UNIQUE,
  database_role TEXT NOT NULL UNIQUE,
  database_secret_ref TEXT NOT NULL UNIQUE,
  schema_version TEXT,
  created_by_account_id UUID NOT NULL REFERENCES cp_accounts(account_id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (length(display_name) BETWEEN 1 AND 160),
  CHECK (database_name ~ '^store_[0-9a-f]{32}$'),
  CHECK (database_role ~ '^store_[0-9a-f]{32}$'),
  CHECK (length(database_secret_ref) BETWEEN 1 AND 512)
);

CREATE TABLE IF NOT EXISTS cp_memberships (
  membership_id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES cp_accounts(account_id) ON DELETE RESTRICT,
  store_id UUID NOT NULL REFERENCES cp_stores(store_id) ON DELETE RESTRICT,
  role TEXT NOT NULL CHECK (role IN ('OWNER', 'ADMIN', 'MANAGER', 'CASHIER', 'VIEWER')),
  status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'INVITED', 'SUSPENDED', 'REVOKED')),
  created_by_account_id UUID REFERENCES cp_accounts(account_id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, store_id),
  UNIQUE (membership_id, account_id, store_id)
);

CREATE INDEX IF NOT EXISTS cp_memberships_account_active_idx
  ON cp_memberships (account_id, store_id) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS cp_memberships_store_active_idx
  ON cp_memberships (store_id, account_id) WHERE status = 'ACTIVE';


-- Short-lived identity session used only between sign-in and store selection.
-- It grants no business-data access until exchanged for a store-scoped session.
CREATE TABLE IF NOT EXISTS cp_login_sessions (
  login_session_id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES cp_accounts(account_id) ON DELETE CASCADE,
  token_hash BYTEA NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS cp_login_sessions_account_idx
  ON cp_login_sessions (account_id, expires_at) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS cp_sessions (
  session_id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES cp_accounts(account_id) ON DELETE CASCADE,
  store_id UUID NOT NULL REFERENCES cp_stores(store_id) ON DELETE CASCADE,
  membership_id UUID NOT NULL,
  access_token_hash BYTEA NOT NULL UNIQUE,
  refresh_token_hash BYTEA NOT NULL UNIQUE,
  role_snapshot TEXT NOT NULL CHECK (role_snapshot IN ('OWNER', 'ADMIN', 'MANAGER', 'CASHIER', 'VIEWER')),
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  access_expires_at TIMESTAMPTZ NOT NULL,
  refresh_expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  last_used_at TIMESTAMPTZ,
  CHECK (access_expires_at > issued_at),
  CHECK (refresh_expires_at > access_expires_at),
  FOREIGN KEY (membership_id, account_id, store_id)
    REFERENCES cp_memberships (membership_id, account_id, store_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS cp_sessions_account_store_idx
  ON cp_sessions (account_id, store_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS cp_sessions_expiry_idx
  ON cp_sessions (access_expires_at) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS cp_provisioning_operations (
  operation_id UUID PRIMARY KEY,
  store_id UUID NOT NULL UNIQUE REFERENCES cp_stores(store_id) ON DELETE RESTRICT,
  requested_by_account_id UUID NOT NULL REFERENCES cp_accounts(account_id) ON DELETE RESTRICT,
  status TEXT NOT NULL CHECK (status IN ('PENDING', 'DATABASE_CREATED', 'MIGRATED', 'COMPLETED', 'FAILED')),
  error_code TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  CHECK ((status = 'COMPLETED') = (completed_at IS NOT NULL))
);

COMMIT;
