#!/usr/bin/env bash
# Phase 5 single-hop runner.
#
# Bumps RETOOL_VERSION in .env, pulls the new image, restarts api +
# jobs-runner against the persistent postgres volume, waits for migrations
# to settle, runs validate.sh, and (on success) snapshots the postgres
# data dir to data-snapshots/<tag>/.
#
# Idempotent: if RETOOL_VERSION already matches --to AND a snapshot
# already exists, the script no-ops.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$LOCAL_DEV_DIR/.env"
DATA_DIR="$LOCAL_DEV_DIR/data"
SNAP_DIR="$LOCAL_DEV_DIR/data-snapshots"
LOGS_DIR="$LOCAL_DEV_DIR/logs"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-local-dev}"

TO_TAG=""
COMPOSE_FILES=()
SKIP_SNAPSHOT="false"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --to <tag> [--compose <file>] [--skip-snapshot]

  --to <tag>         tryretool/backend tag to upgrade to (e.g. 3.33.39-stable)
  --compose <file>   compose file to use (repeatable; overrides auto-select)
  --skip-snapshot    do not snapshot data/ after a successful validate
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --to)             TO_TAG="$2"; shift 2 ;;
    --compose)        COMPOSE_FILES+=("$2"); shift 2 ;;
    --skip-snapshot)  SKIP_SNAPSHOT="true"; shift ;;
    -h|--help)        usage ;;
    *)                echo "[upgrade-hop] unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$TO_TAG" ] || usage
[ -f "$ENV_FILE" ] || { echo "[upgrade-hop] FAIL: .env missing" >&2; exit 1; }

log()  { echo "[upgrade-hop] $*"; }
fail() { echo "[upgrade-hop] FAIL: $*" >&2; exit 1; }

env_get() {
  local key="$1" line val
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
  [ -z "$line" ] && { printf ''; return; }
  val="${line#${key}=}"
  printf '%s' "$val"
}

# --- Auto-select compose file by tag ---
# Compare Retool version strings as (major, minor) integer pairs.
# Naive float comparison breaks because "3.24" < "3.196" as versions
# but "3.24" > "3.196" as decimals.
ge_version() {
  # Returns 0 if version $1 >= version $2 (component-wise).
  awk -v a="$1" -v b="$2" '
    function comps(v, arr,   parts) {
      split(v, parts, /[.-]/)
      arr[1] = parts[1] + 0
      arr[2] = parts[2] + 0
    }
    BEGIN {
      comps(a, A); comps(b, B)
      if (A[1] != B[1]) exit !(A[1] > B[1])
      exit !(A[2] >= B[2])
    }
  '
}

if [ "${#COMPOSE_FILES[@]}" -eq 0 ]; then
  # 3-24 base for every hop; 3-196 overlay layered on top once code-executor
  # becomes required (3.251+). Compose merges environment maps additively,
  # which is what we want for the api service's CODE_EXECUTOR_INGRESS_DOMAIN.
  COMPOSE_FILES=("$LOCAL_DEV_DIR/compose/compose.3-24.yml")
  if ge_version "$TO_TAG" "3.196.0"; then
    COMPOSE_FILES+=("$LOCAL_DEV_DIR/compose/compose.3-196.yml")
  fi
fi
for f in "${COMPOSE_FILES[@]}"; do
  [ -f "$f" ] || fail "compose file not found: $f"
done
log "using compose files: $(IFS=,; printf '%s' "$(basename -a "${COMPOSE_FILES[@]}" | paste -sd, -)")"

# --- Idempotency check ---
current_version="$(env_get RETOOL_VERSION)"
if [ "$current_version" = "$TO_TAG" ] && [ -d "$SNAP_DIR/$TO_TAG" ]; then
  log "already at $TO_TAG and snapshot exists -- no-op."
  exit 0
fi

# --- Sed-replace RETOOL_VERSION in .env ---
log "setting RETOOL_VERSION=$TO_TAG in .env"
python3 - "$ENV_FILE" "$TO_TAG" <<'PY'
import re, sys
path, tag = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read()
text, n = re.subn(r'^RETOOL_VERSION=.*$', f'RETOOL_VERSION={tag}', text, flags=re.M)
if n == 0:
    text += f'\nRETOOL_VERSION={tag}\n'
with open(path, 'w') as f:
    f.write(text)
PY

mkdir -p "$LOGS_DIR" "$SNAP_DIR"

DC=(docker compose --env-file "$ENV_FILE")
for f in "${COMPOSE_FILES[@]}"; do
  DC+=(-f "$f")
done
DC+=(-p "$PROJECT_NAME")

# --- Pull new image, bring up ---
log "pulling images..."
"${DC[@]}" pull
log "starting services..."
"${DC[@]}" up -d

# --- Poll jobs-runner logs for migration completion ---
timeout_seconds="$(env_get DATABASE_MIGRATIONS_TIMEOUT_SECONDS)"
[ -n "$timeout_seconds" ] || timeout_seconds="900"
deadline=$(( $(date +%s) + timeout_seconds + 60 ))
ts_migr_start="$(date +%s)"
log "waiting for migration completion (timeout: ${timeout_seconds}s + 60s buffer)..."

migration_seconds=""
while true; do
  if "${DC[@]}" logs jobs-runner 2>&1 \
       | grep -qE "migration.*(complete|done|finished)"; then
    migration_seconds=$(( $(date +%s) - ts_migr_start ))
    log "migrations settled in ${migration_seconds}s."
    break
  fi
  if [ "$(date +%s)" -gt "$deadline" ]; then
    fail_log="$LOGS_DIR/hop-fail-$TO_TAG.log"
    "${DC[@]}" logs jobs-runner > "$fail_log" 2>&1 || true
    fail "migration timeout (${timeout_seconds}s+60s). Logs: $fail_log"
  fi
  sleep 5
done

# --- Run validate ---
if ! bash "$SCRIPT_DIR/validate.sh" --version "$TO_TAG" \
       --migration-seconds "$migration_seconds" --project "$PROJECT_NAME"; then
  fail_log="$LOGS_DIR/hop-fail-$TO_TAG.log"
  "${DC[@]}" logs api jobs-runner > "$fail_log" 2>&1 || true
  fail "validate.sh failed for $TO_TAG. Logs: $fail_log"
fi

# --- Snapshot data dir ---
if [ "$SKIP_SNAPSHOT" = "true" ]; then
  log "snapshot skipped (--skip-snapshot)."
elif [ -d "$SNAP_DIR/$TO_TAG" ]; then
  log "snapshot already exists for $TO_TAG -- skipping."
else
  log "snapshotting data/ -> data-snapshots/$TO_TAG/ ..."
  "${DC[@]}" stop postgres
  # Use cp -R to avoid sudo on perms; docker-managed files inherit current user via bind mount.
  if ! cp -R "$DATA_DIR" "$SNAP_DIR/$TO_TAG"; then
    "${DC[@]}" start postgres
    fail "cp -R data/ -> data-snapshots/$TO_TAG/ failed"
  fi
  "${DC[@]}" start postgres
  log "snapshot done."
fi

log "DONE: $TO_TAG"
