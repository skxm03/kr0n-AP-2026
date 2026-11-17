-- kr0n backend schema (PostgreSQL)

CREATE TABLE users (
    id UUID PRIMARY KEY,
    email TEXT NOT NULL,
    email_verified_at TIMESTAMPTZ,
    display_name TEXT NOT NULL,
    avatar_url TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    failed_login_attempts INT NOT NULL DEFAULT 0 CHECK (failed_login_attempts >= 0), -- migration 000002
    locked_until TIMESTAMPTZ,                                                        -- migration 000002

    CONSTRAINT users_email_key UNIQUE (email),
    CONSTRAINT users_email_canonical CHECK (email = LOWER(TRIM(email))),
    CONSTRAINT users_display_name_check CHECK (LENGTH(TRIM(display_name)) >= 1)
);

CREATE TABLE password_credentials (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT password_hash_non_empty CHECK (LENGTH(password_hash) > 0)
);

CREATE TABLE oauth_identities (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL CHECK (provider IN ('github', 'google')),
    provider_user_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT oauth_identities_provider_uid_key UNIQUE (provider, provider_user_id),
    CONSTRAINT oauth_identities_user_provider_key UNIQUE (user_id, provider)
);

CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    user_agent TEXT,
    ip_address INET,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT sessions_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX sessions_user_active_idx ON sessions (user_id, last_seen_at DESC)
WHERE revoked_at IS NULL;

CREATE TABLE email_verification_tokens (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT email_verification_tokens_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX email_verification_tokens_user_active_idx ON email_verification_tokens (user_id)
WHERE consumed_at IS NULL;

CREATE TABLE organizations (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    slug TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT organizations_slug_key UNIQUE (slug),
    CONSTRAINT organizations_name_check CHECK (LENGTH(TRIM(name)) >= 1),
    CONSTRAINT organizations_slug_canonical CHECK (slug = LOWER(TRIM(slug)))
);

CREATE TABLE roles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT roles_id_canonical CHECK (id = LOWER(TRIM(id)))
);

CREATE TABLE permissions (
    id TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT permissions_id_canonical CHECK (id = LOWER(TRIM(id)))
);

CREATE TABLE role_permissions (
    role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id TEXT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (role_id, permission_id)
);

CREATE INDEX role_permissions_permission_idx ON role_permissions (permission_id);

CREATE TABLE organization_memberships (
    id UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT org_memberships_org_user_key UNIQUE (organization_id, user_id)
);

CREATE INDEX org_memberships_user_idx ON organization_memberships (user_id);

CREATE TABLE outbox_events (
    id UUID PRIMARY KEY,
    event_type TEXT NOT NULL,
    aggregate_type TEXT NOT NULL,
    aggregate_id UUID NOT NULL,
    payload JSONB NOT NULL,
    headers JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'published', 'failed')),
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    scheduled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ,

    CONSTRAINT outbox_events_payload_object CHECK (jsonb_typeof(payload) = 'object'),
    CONSTRAINT outbox_events_headers_object CHECK (jsonb_typeof(headers) = 'object')
);

CREATE INDEX outbox_events_pending_idx ON outbox_events (scheduled_at, created_at)
WHERE status IN ('pending', 'failed');

-- Refresh-token rotation history (token reuse detection)
CREATE TABLE refresh_token_history (
    token_hash TEXT PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    rotated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX refresh_token_history_session_idx ON refresh_token_history (session_id);
CREATE INDEX refresh_token_history_user_idx ON refresh_token_history (user_id);

-- Password reset tokens (SHA-256 hash stored, single-use)
CREATE TABLE password_reset_tokens (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT password_reset_tokens_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX password_reset_tokens_user_active_idx ON password_reset_tokens (user_id)
WHERE consumed_at IS NULL;

-- API tokens (kr0n_pat_<random>, SHA-256 hash stored, org-scoped)
CREATE TABLE api_tokens (
    id UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (LENGTH(TRIM(name)) >= 1),
    token_prefix TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    permissions TEXT[] NOT NULL DEFAULT '{}',
    expires_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT api_tokens_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX api_tokens_org_active_idx ON api_tokens (organization_id, created_at DESC)
WHERE revoked_at IS NULL;
CREATE INDEX api_tokens_creator_idx ON api_tokens (created_by_user_id);

CREATE TABLE organization_invites (
    id UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    invited_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    accepted_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT organization_invites_token_hash_key UNIQUE (token_hash),
    CONSTRAINT organization_invites_email_canonical CHECK (email = LOWER(TRIM(email)))
);

CREATE INDEX organization_invites_org_pending_idx ON organization_invites (organization_id)
WHERE accepted_at IS NULL AND revoked_at IS NULL;
CREATE INDEX organization_invites_inviter_idx ON organization_invites (invited_by_user_id);

-- Append-only audit events.
-- In production the application DB role should only have SELECT, INSERT (no UPDATE/DELETE).
CREATE TABLE audit_events (
    id UUID PRIMARY KEY,
    organization_id UUID REFERENCES organizations(id) ON DELETE SET NULL,
    actor_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    actor_type TEXT NOT NULL DEFAULT 'user' CHECK (actor_type IN ('user', 'api_token', 'system')),
    action TEXT NOT NULL CHECK (LENGTH(TRIM(action)) >= 1),
    resource_type TEXT NOT NULL CHECK (LENGTH(TRIM(resource_type)) >= 1),
    resource_id TEXT,
    ip_address INET,
    user_agent TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX audit_events_org_created_idx ON audit_events (organization_id, created_at DESC);
CREATE INDEX audit_events_actor_created_idx ON audit_events (actor_user_id, created_at DESC);

CREATE TABLE github_installations (
    id UUID PRIMARY KEY,
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    installation_id BIGINT NOT NULL,
    account_login TEXT NOT NULL CHECK (LENGTH(TRIM(account_login)) >= 1),
    account_type TEXT NOT NULL DEFAULT 'Organization' CHECK (account_type IN ('Organization', 'User')),
    repository_selection TEXT NOT NULL DEFAULT 'all' CHECK (repository_selection IN ('all', 'selected')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'uninstalled')),
    created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT github_installations_installation_id_key UNIQUE (installation_id)
);

CREATE INDEX github_installations_org_idx ON github_installations (organization_id, created_at DESC);
