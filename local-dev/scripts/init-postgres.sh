#!/usr/bin/env bash
# Phase 3 init: ensure `uuid-ossp` extension and confirm Read Committed
# isolation against the local postgres container.
# Idempotent -- safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$LOCAL_DEV_DIR/.env"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-local-dev}"

[ -f "$ENV_FILE" ] || { echo "[init-postgres] .env missing" >&2; exit 1; }

POSTGRES_USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | tail -n 1 | cut -d= -f2-)"
POSTGRES_DB="$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | tail -n 1 | cut -d= -f2-)"
: "${POSTGRES_USER:?POSTGRES_USER missing from .env}"
: "${POSTGRES_DB:?POSTGRES_DB missing from .env}"

psql_exec() {
  docker compose -p "$PROJECT_NAME" exec -T postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "$1"
}

echo "[init-postgres] enabling uuid-ossp..."
psql_exec 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"' >/dev/null

echo "[init-postgres] verifying extension..."
present="$(psql_exec "SELECT extname FROM pg_extension WHERE extname='uuid-ossp'")"
if [ "$present" != "uuid-ossp" ]; then
  echo "[init-postgres] FAIL: uuid-ossp not present after create" >&2
  exit 1
fi

echo "[init-postgres] checking default isolation level..."
isolation="$(psql_exec "SHOW default_transaction_isolation")"
if [ "$isolation" != "read committed" ]; then
  echo "[init-postgres] WARN: default_transaction_isolation='$isolation' (expected 'read committed')" >&2
fi

echo "[init-postgres] OK: uuid-ossp present, isolation=$isolation"
