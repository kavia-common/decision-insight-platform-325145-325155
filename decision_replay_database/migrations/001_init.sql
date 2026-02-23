-- Decision Replay Database Schema (PostgreSQL)
-- Migration: 001_init
-- Notes:
-- - Uses UUID primary keys (pgcrypto gen_random_uuid()).
-- - Uses CITEXT for case-insensitive emails/usernames.
-- - Designed to be backend-friendly for common query patterns: per-user decision lists,
--   decision detail joins (outcomes/tags), analytics snapshots, and auditing.

BEGIN;

-- Extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- ---------------------------------------------------------------------
-- Helper trigger: updated_at
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Users / Authentication
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email CITEXT NOT NULL,
  username CITEXT,
  display_name TEXT,
  password_hash TEXT, -- For local auth; nullable if using SSO/OAuth in future
  status TEXT NOT NULL DEFAULT 'active', -- active|disabled|deleted
  email_verified_at TIMESTAMPTZ,
  last_login_at TIMESTAMPTZ,
  preferences JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  CONSTRAINT users_email_format_chk CHECK (position('@' in email) > 1),
  CONSTRAINT users_status_chk CHECK (status IN ('active', 'disabled', 'deleted'))
);

CREATE UNIQUE INDEX IF NOT EXISTS users_email_uq ON users (email);
CREATE UNIQUE INDEX IF NOT EXISTS users_username_uq ON users (username) WHERE username IS NOT NULL;
CREATE INDEX IF NOT EXISTS users_status_idx ON users (status);
CREATE INDEX IF NOT EXISTS users_created_at_idx ON users (created_at DESC);

CREATE TRIGGER users_set_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- Sessions / tokens: supports refresh tokens, API tokens, password reset tokens, etc.
CREATE TABLE IF NOT EXISTS auth_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_type TEXT NOT NULL DEFAULT 'refresh', -- refresh|access|api|password_reset|email_verify
  token_hash TEXT NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  last_used_at TIMESTAMPTZ,
  ip INET,
  user_agent TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT auth_sessions_type_chk CHECK (session_type IN ('refresh', 'access', 'api', 'password_reset', 'email_verify'))
);

-- Prevent duplicate token hashes; hash should be stored, not raw token.
CREATE UNIQUE INDEX IF NOT EXISTS auth_sessions_token_hash_uq ON auth_sessions (token_hash);
CREATE INDEX IF NOT EXISTS auth_sessions_user_id_idx ON auth_sessions (user_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS auth_sessions_expires_at_idx ON auth_sessions (expires_at);
CREATE INDEX IF NOT EXISTS auth_sessions_revoked_at_idx ON auth_sessions (revoked_at);

-- ---------------------------------------------------------------------
-- Roles / Authorization
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL, -- e.g. admin, user, analyst
  description TEXT,
  permissions JSONB NOT NULL DEFAULT '[]'::jsonb, -- array of permission strings
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT roles_name_format_chk CHECK (length(trim(name)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS roles_name_uq ON roles (name);

CREATE TRIGGER roles_set_updated_at
BEFORE UPDATE ON roles
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS user_roles (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  granted_by UUID REFERENCES users(id) ON DELETE SET NULL,

  PRIMARY KEY (user_id, role_id)
);

CREATE INDEX IF NOT EXISTS user_roles_role_id_idx ON user_roles (role_id);

-- ---------------------------------------------------------------------
-- Decisions (core)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  title TEXT NOT NULL,
  context TEXT,
  decision_date DATE NOT NULL DEFAULT CURRENT_DATE,
  status TEXT NOT NULL DEFAULT 'open', -- open|closed|archived

  -- Structured decision data
  options JSONB NOT NULL DEFAULT '[]'::jsonb, -- list of options considered
  criteria JSONB NOT NULL DEFAULT '[]'::jsonb, -- list of criteria used
  expected_outcome TEXT,
  selected_option JSONB, -- selected option object or identifier
  confidence NUMERIC(5,2), -- 0..100
  risk_level TEXT, -- low|medium|high or custom
  importance INTEGER, -- 1..5
  time_horizon TEXT, -- short|medium|long or custom

  -- AI/analytics fields
  quality_score NUMERIC(5,2),
  bias_signals JSONB NOT NULL DEFAULT '[]'::jsonb, -- detected biases
  notes TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ,

  CONSTRAINT decisions_status_chk CHECK (status IN ('open', 'closed', 'archived')),
  CONSTRAINT decisions_confidence_chk CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 100)),
  CONSTRAINT decisions_quality_score_chk CHECK (quality_score IS NULL OR (quality_score >= 0 AND quality_score <= 100)),
  CONSTRAINT decisions_importance_chk CHECK (importance IS NULL OR (importance >= 1 AND importance <= 5))
);

CREATE INDEX IF NOT EXISTS decisions_user_id_created_at_idx ON decisions (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS decisions_user_id_decision_date_idx ON decisions (user_id, decision_date DESC);
CREATE INDEX IF NOT EXISTS decisions_status_idx ON decisions (status);
CREATE INDEX IF NOT EXISTS decisions_deleted_at_idx ON decisions (deleted_at);

CREATE TRIGGER decisions_set_updated_at
BEFORE UPDATE ON decisions
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Outcomes (time series)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outcomes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id UUID NOT NULL REFERENCES decisions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  outcome_date DATE NOT NULL DEFAULT CURRENT_DATE,
  status TEXT NOT NULL DEFAULT 'observed', -- observed|final|revised
  summary TEXT,
  metrics JSONB NOT NULL DEFAULT '{}'::jsonb, -- structured outcome measures
  satisfaction NUMERIC(5,2), -- 0..100
  lessons_learned TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT outcomes_status_chk CHECK (status IN ('observed', 'final', 'revised')),
  CONSTRAINT outcomes_satisfaction_chk CHECK (satisfaction IS NULL OR (satisfaction >= 0 AND satisfaction <= 100))
);

CREATE INDEX IF NOT EXISTS outcomes_decision_id_outcome_date_idx ON outcomes (decision_id, outcome_date DESC);
CREATE INDEX IF NOT EXISTS outcomes_user_id_outcome_date_idx ON outcomes (user_id, outcome_date DESC);

CREATE TRIGGER outcomes_set_updated_at
BEFORE UPDATE ON outcomes
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Tags
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  name TEXT NOT NULL,
  color TEXT, -- optional hex
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT tags_name_format_chk CHECK (length(trim(name)) > 0)
);

-- Tag names are unique per user (so different users can reuse same tag text).
CREATE UNIQUE INDEX IF NOT EXISTS tags_user_name_uq ON tags (user_id, lower(name));
CREATE INDEX IF NOT EXISTS tags_user_id_idx ON tags (user_id);

CREATE TABLE IF NOT EXISTS decision_tags (
  decision_id UUID NOT NULL REFERENCES decisions(id) ON DELETE CASCADE,
  tag_id UUID NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (decision_id, tag_id),

  -- Ensure join row belongs to the same owner (helps prevent cross-tenant joins).
  CONSTRAINT decision_tags_owner_consistency_chk CHECK (user_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS decision_tags_tag_id_idx ON decision_tags (tag_id);
CREATE INDEX IF NOT EXISTS decision_tags_user_id_idx ON decision_tags (user_id);

-- ---------------------------------------------------------------------
-- Embeddings metadata (vector content stored elsewhere; here we store bookkeeping)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS embeddings_metadata (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  -- Embeddings can be attached to decisions, outcomes, notes, etc.
  entity_type TEXT NOT NULL, -- decision|outcome|note|other
  entity_id UUID NOT NULL,    -- points to the entity row id
  provider TEXT,             -- openai|cohere|local, etc.
  model TEXT,                -- text-embedding-3-large, etc.
  dimensions INTEGER,
  content_hash TEXT,         -- used to avoid recomputing embeddings
  vector_store_key TEXT,     -- pointer key in vector DB (e.g., Pinecone id)
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT embeddings_entity_type_chk CHECK (entity_type IN ('decision', 'outcome', 'note', 'other'))
);

CREATE INDEX IF NOT EXISTS embeddings_user_entity_idx ON embeddings_metadata (user_id, entity_type, entity_id);
CREATE UNIQUE INDEX IF NOT EXISTS embeddings_unique_content_idx
  ON embeddings_metadata (user_id, entity_type, entity_id, content_hash)
  WHERE content_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS embeddings_vector_store_key_idx ON embeddings_metadata (vector_store_key);

CREATE TRIGGER embeddings_metadata_set_updated_at
BEFORE UPDATE ON embeddings_metadata
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- Analytics snapshots (precomputed aggregates per user/time window)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  snapshot_type TEXT NOT NULL, -- daily|weekly|monthly|custom
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,

  metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
  generated_by TEXT NOT NULL DEFAULT 'system', -- system|admin|job_name|etc

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT analytics_period_chk CHECK (period_end >= period_start),
  CONSTRAINT analytics_snapshot_type_chk CHECK (snapshot_type IN ('daily', 'weekly', 'monthly', 'custom'))
);

CREATE UNIQUE INDEX IF NOT EXISTS analytics_snapshots_unique_idx
  ON analytics_snapshots (user_id, snapshot_type, period_start, period_end);

CREATE INDEX IF NOT EXISTS analytics_snapshots_user_period_idx
  ON analytics_snapshots (user_id, period_start DESC, period_end DESC);

-- ---------------------------------------------------------------------
-- Audit logs (security + traceability)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL, -- actor (nullable for system)
  org_user_id UUID REFERENCES users(id) ON DELETE SET NULL, -- optional: "impersonated" user

  action TEXT NOT NULL,       -- e.g. decision.create, auth.login, admin.role.grant
  entity_type TEXT,           -- decision|outcome|tag|user|session|...
  entity_id UUID,
  severity TEXT NOT NULL DEFAULT 'info', -- info|warn|error|security
  message TEXT,

  ip INET,
  user_agent TEXT,
  request_id TEXT,            -- correlate with backend logs
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT audit_severity_chk CHECK (severity IN ('info', 'warn', 'error', 'security'))
);

CREATE INDEX IF NOT EXISTS audit_logs_user_id_created_at_idx ON audit_logs (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_action_created_at_idx ON audit_logs (action, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_entity_idx ON audit_logs (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS audit_logs_severity_idx ON audit_logs (severity);

-- ---------------------------------------------------------------------
-- Seed data (minimal, safe defaults)
-- ---------------------------------------------------------------------

-- Roles
INSERT INTO roles (name, description, permissions)
VALUES
  ('user', 'Default end-user role', '["decisions:read","decisions:write","outcomes:read","outcomes:write","analytics:read"]'::jsonb)
ON CONFLICT (name) DO NOTHING;

INSERT INTO roles (name, description, permissions)
VALUES
  ('admin', 'Administrator role', '["*"]'::jsonb)
ON CONFLICT (name) DO NOTHING;

-- Demo user (for local/dev). password_hash is placeholder; backend should set real hash on signup.
-- NOTE: email must be unique; safe to run repeatedly due to ON CONFLICT.
INSERT INTO users (email, username, display_name, password_hash, status, preferences, email_verified_at)
VALUES (
  'demo@decisionreplay.local',
  'demo',
  'Demo User',
  'demo-password-hash-placeholder',
  'active',
  '{"theme":"light","demo":true}'::jsonb,
  NOW()
)
ON CONFLICT (email) DO NOTHING;

-- Assign demo user the 'user' role (idempotent).
INSERT INTO user_roles (user_id, role_id, granted_by)
SELECT u.id, r.id, u.id
FROM users u
JOIN roles r ON r.name = 'user'
WHERE u.email = 'demo@decisionreplay.local'
ON CONFLICT DO NOTHING;

COMMIT;
