# Decision Replay Database Schema (PostgreSQL)

This container provisions PostgreSQL and provides a database viewer. This document defines the application schema for:

- users
- auth sessions/tokens
- roles
- decisions
- outcomes
- tags
- embeddings metadata (bookkeeping only)
- analytics snapshots
- audit logs

## Connection

Use the connection string from:

- `db_connection.txt`

Example:

```bash
psql "$(awk '{print $2}' db_connection.txt)"
```

## Apply migrations (schema + seed)

This repo includes an idempotent SQL migration:

- `migrations/001_init.sql`

Run it:

```bash
psql "$(awk '{print $2}' db_connection.txt)" -f migrations/001_init.sql
```

Re-running is safe (uses `IF NOT EXISTS` + `ON CONFLICT DO NOTHING`).

## Tables overview

- `users`: account profile, preferences, soft-delete (`deleted_at`)
- `auth_sessions`: hashed tokens/sessions with expiry/revocation for refresh/API/password-reset flows
- `roles`, `user_roles`: authorization model with JSONB permissions
- `decisions`: core decision log (JSONB for options/criteria/bias signals)
- `outcomes`: multiple outcomes per decision over time
- `tags`, `decision_tags`: per-user tags and decision tagging (unique per user)
- `embeddings_metadata`: metadata for embeddings stored in an external vector store
- `analytics_snapshots`: precomputed aggregates by period
- `audit_logs`: append-only security/trace logs

## Notes for backend integration

- All domain tables are tenant-scoped by `user_id` and indexed for per-user queries.
- Use `auth_sessions.token_hash` rather than storing raw tokens.
- `decisions.deleted_at` supports soft-delete; queries should filter `deleted_at IS NULL` unless explicitly requested.
- For tag lookups: `tags` enforces unique `(user_id, lower(name))`.

## Demo seed

A demo user is created (if not already present):

- email: `demo@decisionreplay.local`
- username: `demo`

Role seeds:

- `user`
- `admin`
