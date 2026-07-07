#!/usr/bin/env bash
# Phase 4 dump restore.
#
# Restores a prod Aurora pg_dump into the local postgres:14.6 container.
# Filters Aurora-specific objects (aws_* schemas, rdsadmin/rds_* grants,
# Aurora-only extensions) before pg_restore -- vanilla postgres refuses them.
#
# Hard rails:
#   - Refuses to run if ENCRYPTION_KEY or JWT_SECRET still placeholder/empty.
#     Without prod's ENCRYPTION_KEY the dump's encrypted columns become
#     unreadable -- the dry-run would produce invalid signal.
#   - Refuses to run if data/ is non-empty (prevents accidental clobber).
#     Operator must `docker compose down -v` first; documented in RUNBOOK
#     § Mid-walk recovery.
#   - Aborts if Aurora-filter delta > 50 (unexpected RDS content needs
#     operator review of restore.toc.raw).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$LOCAL_DEV_DIR/.env"
DATA_DIR="$LOCAL_DEV_DIR/data"
LOGS_DIR="$LOCAL_DEV_DIR/logs"
COMPOSE_FILE="$LOCAL_DEV_DIR/compose/compose.3-24.yml"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-local-dev}"

PLACEHOLDER_ENCRYPTION_KEY="PASTE_PROD_ENCRYPTION_KEY_HERE"
PLACEHOLDER_JWT_SECRET="PASTE_PROD_JWT_SECRET_HERE"

DUMP=""
SKIP_AURORA_FILTER="false"
FILTER_DELTA_MAX="50"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --dump <path> [--skip-aurora-filter] [--max-delta N]

  --dump <path>            pg_dump --format=custom file from Aurora
  --skip-aurora-filter     restore without stripping AWS/RDS objects (rare)
  --max-delta N            abort if filter strips more than N lines (default 50)
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dump)                DUMP="$2"; shift 2 ;;
    --skip-aurora-filter)  SKIP_AURORA_FILTER="true"; shift ;;
    --max-delta)           FILTER_DELTA_MAX="$2"; shift 2 ;;
    -h|--help)             usage ;;
    *)                     echo "[restore-dump] unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$DUMP" ] || usage
[ -f "$DUMP" ] || { echo "[restore-dump] FAIL: dump file not found: $DUMP" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "[restore-dump] FAIL: .env missing" >&2; exit 1; }

log()  { echo "[restore-dump] $*"; }
fail() { echo "[restore-dump] FAIL: $*" >&2; exit 1; }

env_get() {
  local key="$1" line val
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
  [ -z "$line" ] && { printf ''; return; }
  val="${line#${key}=}"
  printf '%s' "$val"
}

# --- Pre-check: ENCRYPTION_KEY / JWT_SECRET populated ---
enc="$(env_get ENCRYPTION_KEY)"
jwt="$(env_get JWT_SECRET)"
if [ -z "$enc" ] || [ "$enc" = "$PLACEHOLDER_ENCRYPTION_KEY" ]; then
  fail "ENCRYPTION_KEY not populated -- restored dump's encrypted columns would be unreadable. See RUNBOOK § Extract prod secrets."
fi
if [ -z "$jwt" ] || [ "$jwt" = "$PLACEHOLDER_JWT_SECRET" ]; then
  fail "JWT_SECRET not populated. See RUNBOOK § Extract prod secrets."
fi
log "secrets pre-check: OK."

POSTGRES_USER="$(env_get POSTGRES_USER)"
POSTGRES_DB="$(env_get POSTGRES_DB)"
: "${POSTGRES_USER:?POSTGRES_USER missing from .env}"
: "${POSTGRES_DB:?POSTGRES_DB missing from .env}"

# --- Pre-check: data/ is empty ---
if [ -d "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null || true)" ]; then
  fail "data/ is non-empty. Run: docker compose --env-file .env -f compose/compose.3-24.yml down -v  (drops volume) and then re-run restore-dump.sh. See RUNBOOK § Mid-walk recovery."
fi
log "data/ empty: OK."

mkdir -p "$LOGS_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOGS_DIR/restore-$TS.log"
TOC_RAW="$LOGS_DIR/restore-$TS.toc.raw"
TOC_FILT="$LOGS_DIR/restore-$TS.toc"

exec > >(tee -a "$LOG_FILE") 2>&1

# --- Tear down compose to ensure a clean volume mount ---
log "stopping compose project..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down -v || true

# --- Boot postgres only, wait for healthy ---
log "starting postgres only..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d postgres
log "waiting for postgres healthy..."
deadline=$(( $(date +%s) + 120 ))
until docker compose -p "$PROJECT_NAME" exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  if [ "$(date +%s)" -gt "$deadline" ]; then
    fail "postgres did not become ready within 120s"
  fi
  sleep 2
done
log "postgres ready."

# --- Filter Aurora-specific objects from the dump TOC ---
PG_RESTORE_LIST_ARGS=()
if [ "$SKIP_AURORA_FILTER" = "false" ]; then
  log "listing dump TOC..."
  if ! command -v pg_restore >/dev/null 2>&1; then
    log "host pg_restore missing -- running list inside postgres container."
    docker run --rm -v "$(cd "$(dirname "$DUMP")" && pwd):/dump:ro" \
      postgres:14.6 pg_restore --list "/dump/$(basename "$DUMP")" > "$TOC_RAW"
  else
    pg_restore --list "$DUMP" > "$TOC_RAW"
  fi
  raw_count=$(wc -l < "$TOC_RAW")
  grep -vE "(SCHEMA - aws_|SCHEMA - .* rdsadmin|GRANT .* rdsadmin|GRANT .* rds_|EXTENSION - aws_|EXTENSION - pg_buffercache)" \
    "$TOC_RAW" > "$TOC_FILT"
  filt_count=$(wc -l < "$TOC_FILT")
  delta=$(( raw_count - filt_count ))
  log "TOC lines raw=$raw_count filtered=$filt_count (delta=$delta)"
  if [ "$delta" -gt "$FILTER_DELTA_MAX" ]; then
    fail "filter delta $delta exceeds max $FILTER_DELTA_MAX -- inspect $TOC_RAW for unexpected Aurora content."
  fi
  PG_RESTORE_LIST_ARGS=(--use-list="/tmp/restore.toc")
fi

# --- pg_restore via a one-shot postgres:14.6 container, networked to our compose ---
log "running pg_restore..."
NET="$(docker compose -p "$PROJECT_NAME" ps -q postgres | xargs -I {} docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{end}}' {})"
[ -n "$NET" ] || fail "could not resolve compose network for postgres service"

DUMP_DIR="$(cd "$(dirname "$DUMP")" && pwd)"
DUMP_FILE="$(basename "$DUMP")"

# Build the docker run args. We mount the dump dir read-only and the
# filtered TOC into /tmp/restore.toc.
TOC_MOUNT=()
if [ "$SKIP_AURORA_FILTER" = "false" ]; then
  TOC_MOUNT=(-v "$TOC_FILT:/tmp/restore.toc:ro")
fi

docker run --rm \
  --network "$NET" \
  -e PGPASSWORD="$(env_get POSTGRES_PASSWORD)" \
  -v "$DUMP_DIR:/dump:ro" \
  "${TOC_MOUNT[@]}" \
  postgres:14.6 \
  pg_restore \
    --host=postgres --port=5432 \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --clean --if-exists --no-owner --no-privileges \
    "${PG_RESTORE_LIST_ARGS[@]}" \
    "/dump/$DUMP_FILE"

log "pg_restore complete."

# --- Confirm uuid-ossp post-restore ---
log "running init-postgres..."
bash "$SCRIPT_DIR/init-postgres.sh"

log "restore done. Log: $LOG_FILE"
