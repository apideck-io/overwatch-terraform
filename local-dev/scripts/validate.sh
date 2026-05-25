#!/usr/bin/env bash
# Phase 2 validation script.
# Runs after each image hop to prove the stack is functional.
#
# Hard checks (fail -> exit non-zero, halt the walk):
#   - api + jobs-runner running (code-executor too if compose includes it)
#   - container healthchecks reporting healthy (when defined)
#   - HTTP 200 from /api/checkHealth (prod's ALB target)
#   - knex_migrations row count >= previous hop
#   - users/apps/pages/resources row counts >= previous hop (Retool never drops rows)
#
# Soft checks (failure -> annotate `notes=`, do not fail):
#   - migration-complete log line present in jobs-runner output
#   - error/fatal/panic line count in api logs
#
# Appends a TSV row per invocation:
#   ts_start ts_end version migration_seconds status \
#     knex_count users_count apps_count pages_count resources_count notes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_FILE="$LOCAL_DEV_DIR/hop-report.tsv"
ENV_FILE="$LOCAL_DEV_DIR/.env"

VERSION=""
MIGRATION_SECONDS="0"
PROJECT_NAME="local-dev"
NOTES=()
STATUS="fail"
KNEX_COUNT=""
USERS_COUNT=""
APPS_COUNT=""
PAGES_COUNT=""
RESOURCES_COUNT=""
TS_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --version <tag> [--migration-seconds N]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)            VERSION="$2"; shift 2 ;;
    --migration-seconds)  MIGRATION_SECONDS="$2"; shift 2 ;;
    --project)            PROJECT_NAME="$2"; shift 2 ;;
    -h|--help)            usage ;;
    *)                    echo "[validate] unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$VERSION" ] || { echo "[validate] --version required" >&2; usage; }

annotate() { NOTES+=("$1"); }
log()      { echo "[validate] $*" >&2; }

write_report_row() {
  # Header (created once).
  if [ ! -f "$REPORT_FILE" ]; then
    printf 'ts_start\tts_end\tversion\tmigration_seconds\tstatus\tknex_count\tusers_count\tapps_count\tpages_count\tresources_count\tnotes\n' > "$REPORT_FILE"
  fi
  local ts_end notes_joined
  ts_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "${#NOTES[@]}" -eq 0 ]; then
    notes_joined=""
  else
    notes_joined="$(printf '%s;' "${NOTES[@]}")"
    notes_joined="${notes_joined%;}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TS_START" "$ts_end" "$VERSION" "$MIGRATION_SECONDS" "$STATUS" \
    "$KNEX_COUNT" "$USERS_COUNT" "$APPS_COUNT" "$PAGES_COUNT" "$RESOURCES_COUNT" \
    "$notes_joined" >> "$REPORT_FILE"
}

fail() {
  log "FAIL: $*"
  STATUS="fail"
  annotate "fail=$*"
  write_report_row
  exit 1
}

# Snapshot of running services in our compose project. Empty -> stack down.
running_services() {
  docker compose -p "$PROJECT_NAME" ps --services --filter status=running 2>/dev/null || true
}

# Run `docker compose exec` against the postgres service.
psql_exec() {
  local sql="$1"
  docker compose -p "$PROJECT_NAME" exec -T postgres \
    psql -U "${POSTGRES_USER:-retool}" -d "${POSTGRES_DB:-hammerhead_production}" \
    -tA -c "$sql" 2>/dev/null
}

# --- Hard check 1: api + jobs-runner running ---
services="$(running_services)"
if ! grep -qx 'api' <<<"$services"; then
  fail "api container not running (services: ${services//$'\n'/,})"
fi
if ! grep -qx 'jobs-runner' <<<"$services"; then
  fail "jobs-runner container not running"
fi
HAS_CODE_EXECUTOR="no"
if grep -qx 'code-executor' <<<"$services"; then
  HAS_CODE_EXECUTOR="yes"
fi
log "OK: api + jobs-runner running (code-executor=$HAS_CODE_EXECUTOR)."

# --- Hard check 2: container healthchecks (only fail if status is unhealthy) ---
check_health() {
  local svc="$1" cid hstatus
  cid="$(docker compose -p "$PROJECT_NAME" ps -q "$svc" 2>/dev/null || true)"
  [ -n "$cid" ] || return 0
  hstatus="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "none")"
  case "$hstatus" in
    healthy|none|starting) return 0 ;;
    unhealthy)             fail "container $svc reports unhealthy" ;;
    *)                     annotate "health_$svc=$hstatus" ;;
  esac
}
check_health api
check_health jobs-runner
[ "$HAS_CODE_EXECUTOR" = "yes" ] && check_health code-executor
log "OK: healthchecks not unhealthy."

# --- Hard check 3: /api/checkHealth returns 200 (retry: HTTP listener may lag migrations) ---
health_ok="no"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if curl -fsS --max-time 5 http://localhost:3000/api/checkHealth >/dev/null 2>&1; then
    health_ok="yes"
    break
  fi
  sleep 5
done
if [ "$health_ok" != "yes" ]; then
  fail "http://localhost:3000/api/checkHealth did not return 2xx after 60s"
fi
log "OK: /api/checkHealth -> 200."

# --- Source POSTGRES_USER / POSTGRES_DB from .env (without sourcing the file) ---
if [ -f "$ENV_FILE" ]; then
  POSTGRES_USER="$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | tail -n 1 | cut -d= -f2-)"
  POSTGRES_DB="$(grep -E '^POSTGRES_DB=' "$ENV_FILE" | tail -n 1 | cut -d= -f2-)"
  export POSTGRES_USER POSTGRES_DB
fi

# --- Hard check 4: migration row count >= previous hop's value ---
# Retool uses SequelizeMeta in older versions; newer versions may add knex_migrations.
# Sum both when present so the count is monotonic across the upgrade walk.
SEQ_COUNT="$(psql_exec 'SELECT count(*) FROM "SequelizeMeta"' 2>/dev/null || echo 0)"
SEQ_COUNT="${SEQ_COUNT//[!0-9]/}"
KNX_COUNT="$(psql_exec "SELECT count(*) FROM knex_migrations" 2>/dev/null || echo 0)"
KNX_COUNT="${KNX_COUNT//[!0-9]/}"
SEQ_COUNT="${SEQ_COUNT:-0}"
KNX_COUNT="${KNX_COUNT:-0}"
KNEX_COUNT=$(( SEQ_COUNT + KNX_COUNT ))
if [ "$KNEX_COUNT" -eq 0 ]; then
  fail "could not read migration counts (SequelizeMeta + knex_migrations both 0 or missing)"
fi
log "migration counts: SequelizeMeta=$SEQ_COUNT knex_migrations=$KNX_COUNT total=$KNEX_COUNT"

prev_count_for() {
  # $1 = column name in header. Returns last numeric value seen, or empty.
  local col="$1"
  [ -f "$REPORT_FILE" ] || { echo ""; return; }
  awk -v col="$col" '
    NR==1 { for (i=1;i<=NF;i++) idx[$i]=i; next }
    { val=$idx[col]; if (val ~ /^[0-9]+$/) last=val }
    END { print last }
  ' "$REPORT_FILE"
}

prev_knex="$(prev_count_for knex_count)"
if [ -n "$prev_knex" ] && [ "$KNEX_COUNT" -lt "$prev_knex" ]; then
  fail "knex_migrations count regressed: $prev_knex -> $KNEX_COUNT"
fi

# --- Hard check 5: spot-check row counts (>= previous) ---
spot_check() {
  local label="$1" table="$2"
  local val
  val="$(psql_exec "SELECT count(*) FROM $table" || true)"
  val="${val//[!0-9]/}"
  if [ -z "$val" ]; then
    # Table may legitimately not exist on early empty-DB run; treat as 0.
    val="0"
    annotate "${label}_missing=table_or_query_failed"
  fi
  local prev
  prev="$(prev_count_for "${label}_count")"
  if [ -n "$prev" ] && [ "$val" -lt "$prev" ]; then
    fail "$label count regressed: $prev -> $val"
  fi
  printf '%s' "$val"
}

USERS_COUNT="$(spot_check users users)"
APPS_COUNT="$(spot_check apps apps)"
PAGES_COUNT="$(spot_check pages pages)"
RESOURCES_COUNT="$(spot_check resources resources)"
log "row counts: users=$USERS_COUNT apps=$APPS_COUNT pages=$PAGES_COUNT resources=$RESOURCES_COUNT"

# --- Soft check: migration-complete log line ---
if docker compose -p "$PROJECT_NAME" logs jobs-runner 2>&1 \
     | grep -qE "migration.*(complete|done|finished)"; then
  annotate "migrations_logged=yes"
else
  annotate "migrations_logged=no"
fi

# --- Soft check: error/fatal/panic in api logs ---
error_lines="$(docker compose -p "$PROJECT_NAME" logs api 2>&1 \
  | grep -ciE '(error|fatal|panic)' || true)"
annotate "error_lines=${error_lines:-0}"

STATUS="pass"
write_report_row
log "PASS: $VERSION"
