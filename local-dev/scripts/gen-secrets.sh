#!/usr/bin/env bash
# Phase 3 secret generator.
#
# Generates POSTGRES_PASSWORD ONLY. Refuses to touch ENCRYPTION_KEY or
# JWT_SECRET -- those must be pasted from a live prod ECS task
# (see RUNBOOK § Extract prod secrets). Without prod's ENCRYPTION_KEY the
# restored dump's encrypted columns become unreadable and the dry-run
# produces invalid signal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$LOCAL_DEV_DIR/.env"
ENV_EXAMPLE="$LOCAL_DEV_DIR/.env.example"

PLACEHOLDER_ENCRYPTION_KEY="PASTE_PROD_ENCRYPTION_KEY_HERE"
PLACEHOLDER_JWT_SECRET="PASTE_PROD_JWT_SECRET_HERE"

if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$ENV_EXAMPLE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo "[gen-secrets] created .env from .env.example"
  else
    echo "[gen-secrets] FAIL: $ENV_EXAMPLE missing" >&2
    exit 1
  fi
fi

env_get() {
  local key="$1" line val
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
  [ -z "$line" ] && { printf ''; return; }
  val="${line#${key}=}"
  printf '%s' "$val"
}

# --- Refuse if ENCRYPTION_KEY / JWT_SECRET are still placeholder/empty ---
check_prod_secret() {
  local var="$1" placeholder="$2" val
  val="$(env_get "$var")"
  if [ -z "$val" ] || [ "$val" = "$placeholder" ]; then
    cat >&2 <<EOF
[gen-secrets] FAIL: $var is not populated.

$var must be pasted from a live prod ECS task -- this script will
NOT auto-generate it. See RUNBOOK § Extract prod secrets:

  aws ecs list-tasks --cluster overwatch-ecs --service-name overwatch-retool
  aws ecs execute-command \\
    --cluster overwatch-ecs --task <task-id> --container retool \\
    --interactive --command "/bin/sh"
  # inside the container:
  printenv ENCRYPTION_KEY JWT_SECRET

Paste both values into local-dev/.env, then re-run gen-secrets.sh.
EOF
    exit 1
  fi
}
check_prod_secret ENCRYPTION_KEY "$PLACEHOLDER_ENCRYPTION_KEY"
check_prod_secret JWT_SECRET     "$PLACEHOLDER_JWT_SECRET"

# --- Generate POSTGRES_PASSWORD if missing ---
current_pw="$(env_get POSTGRES_PASSWORD)"
if [ -n "$current_pw" ]; then
  echo "[gen-secrets] POSTGRES_PASSWORD already set -- leaving untouched."
  exit 0
fi

# 64 hex chars matches install.sh's `random 64` shape.
new_pw="$(openssl rand -hex 32)"

# In-place rewrite without sed -i portability concerns.
python3 - "$ENV_FILE" "$new_pw" <<'PY'
import re, sys
path, new_pw = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
text, n = re.subn(r'^POSTGRES_PASSWORD=.*$', f'POSTGRES_PASSWORD={new_pw}', text, flags=re.M)
if n == 0:
    text += f'\nPOSTGRES_PASSWORD={new_pw}\n'
with open(path, 'w') as f:
    f.write(text)
PY

echo "[gen-secrets] POSTGRES_PASSWORD generated (64 hex chars). Not echoed."
