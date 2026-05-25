#!/usr/bin/env bash
# Phase 1 prereq check.
# Verifies: Docker running, docker compose available, .env exists with required
# secrets populated, at least one dump file present.
# Exits non-zero with a clear diagnostic on any failure.
set -euo pipefail

# Resolve local-dev/ regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$LOCAL_DEV_DIR/.env"
ENV_EXAMPLE="$LOCAL_DEV_DIR/.env.example"
DUMPS_DIR="$LOCAL_DEV_DIR/dumps"

# Placeholder literals from .env.example -- must not survive into .env.
PLACEHOLDER_ENCRYPTION_KEY="PASTE_PROD_ENCRYPTION_KEY_HERE"
PLACEHOLDER_JWT_SECRET="PASTE_PROD_JWT_SECRET_HERE"
PLACEHOLDER_LICENSE_KEY="PASTE_FREE_LICENSE_FROM_MY_RETOOL_HERE"

fail() {
  echo "[check-prereqs] FAIL: $*" >&2
  exit 1
}

ok() {
  echo "[check-prereqs] OK:   $*"
}

# --- Docker daemon ---
command -v docker >/dev/null 2>&1 || fail "docker CLI not on PATH. Install Docker Desktop."
if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon not reachable. Start Docker Desktop and retry."
fi
ok "Docker daemon reachable."

# --- docker compose v2 ---
if ! docker compose version >/dev/null 2>&1; then
  fail "'docker compose' (v2) not available. Update Docker Desktop."
fi
ok "docker compose available ($(docker compose version --short 2>/dev/null || echo unknown))."

# --- .env file ---
[ -f "$ENV_FILE" ] || fail ".env not found. Run: cp $ENV_EXAMPLE $ENV_FILE then fill in secrets."
ok ".env present."

# Parse .env without shell-sourcing (values may contain `>`, spaces, etc).
# Returns the raw value (strips surrounding quotes if present) or empty string.
env_get() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
  [ -z "$line" ] && return 0
  local val="${line#${key}=}"
  # Strip matching surrounding quotes.
  if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
    val="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$val"
}

check_secret() {
  local var_name="$1"
  local placeholder="$2"
  local val
  val="$(env_get "$var_name")"
  if [ -z "$val" ]; then
    fail "$var_name is empty in .env -- see RUNBOOK § Extract prod secrets."
  fi
  if [ "$val" = "$placeholder" ]; then
    fail "$var_name still set to placeholder literal -- see RUNBOOK § Extract prod secrets."
  fi
  ok "$var_name populated."
}

check_secret ENCRYPTION_KEY "$PLACEHOLDER_ENCRYPTION_KEY"
check_secret JWT_SECRET     "$PLACEHOLDER_JWT_SECRET"

# --- LICENSE_KEY populated and not placeholder ---
license_key="$(env_get LICENSE_KEY)"
if [ -z "$license_key" ] || [ "$license_key" = "$PLACEHOLDER_LICENSE_KEY" ]; then
  fail "LICENSE_KEY not populated. Get a free key from https://my.retool.com -- do NOT copy prod's."
fi
ok "LICENSE_KEY populated."

# --- POSTGRES_PASSWORD set (anything non-empty -- gen-secrets.sh generates this) ---
postgres_password="$(env_get POSTGRES_PASSWORD)"
if [ -z "$postgres_password" ]; then
  fail "POSTGRES_PASSWORD empty. Run scripts/gen-secrets.sh to generate one."
fi
ok "POSTGRES_PASSWORD populated."

# --- Dump file present ---
if [ ! -d "$DUMPS_DIR" ]; then
  fail "dumps/ directory missing: $DUMPS_DIR"
fi
shopt -s nullglob
dumps=("$DUMPS_DIR"/*.dump "$DUMPS_DIR"/*.sql "$DUMPS_DIR"/*.sql.gz)
shopt -u nullglob
if [ "${#dumps[@]}" -eq 0 ]; then
  fail "No dump files in $DUMPS_DIR. See RUNBOOK § Pulling a fresh dump from Aurora."
fi
ok "Dump file(s) present: ${#dumps[@]} found."

echo "[check-prereqs] All checks passed."
