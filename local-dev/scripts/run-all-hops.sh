#!/usr/bin/env bash
# Phase 7 walk orchestrator.
#
# Drives the 8-hop walk from 3.24.6 to 3.334.x. Per-hop work lives in
# upgrade-hop.sh; this script supplies the HOPS list, halts cleanly on
# first failure, and supports --from <tag> resumption (restores postgres
# data dir from the preceding green hop's snapshot).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DEV_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$LOCAL_DEV_DIR/data"
SNAP_DIR="$LOCAL_DEV_DIR/data-snapshots"
REPORT_FILE="$LOCAL_DEV_DIR/hop-report.tsv"

# --- HOPS list (latest stable of each line as of 2026-05-25) ---
# Reconciled with Docker Hub during Phase 7 implementation:
#   - 3.33.9 (not 3.33.39 -- the 3.33 line only got 9 stable patches).
#   - 3.163.x dropped: 3.163 was published only on Edge; no Stable release.
#     The walk goes 3.148 -> 3.196 instead. If a future hop is needed
#     between them, switch to the Edge channel (against plan policy).
# Operator must verify each tag still exists on
# https://hub.docker.com/r/tryretool/backend/tags before invoking;
# scripts/check-tags.sh automates this.
HOPS=(
  "3.24.6"
  "3.33.9-stable"
  "3.114.28-stable"
  "3.148.13-stable"
  "3.196.33-stable"
  "3.253.29-stable"
  "3.284.30-stable"
  "3.334.15-stable"
)

# When sourced from check-tags.sh just expose HOPS and return.
if [ -n "${CHECK_TAGS_SOURCING:-}" ]; then
  export HOPS
  return 0 2>/dev/null || exit 0
fi

FROM_TAG=""
DRY_RUN="false"
SKIP_TAG_CHECK="false"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [--from <tag>] [--dry-run] [--skip-tag-check]

  --from <tag>       resume from this hop. Restores data/ from the snapshot
                     of the PRECEDING green hop before resuming.
  --dry-run          print sequence + tag-existence status, do not execute.
  --skip-tag-check   do not run check-tags.sh first (use when offline).
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from)            FROM_TAG="$2"; shift 2 ;;
    --dry-run)         DRY_RUN="true"; shift ;;
    --skip-tag-check)  SKIP_TAG_CHECK="true"; shift ;;
    -h|--help)         usage ;;
    *)                 echo "[run-all-hops] unknown arg: $1" >&2; usage ;;
  esac
done

log()  { echo "[run-all-hops] $*"; }
fail() { echo "[run-all-hops] FAIL: $*" >&2; exit 1; }

# --- Resolve --from ---
start_idx=0
if [ -n "$FROM_TAG" ]; then
  found="no"
  for i in "${!HOPS[@]}"; do
    if [ "${HOPS[$i]}" = "$FROM_TAG" ]; then
      start_idx="$i"; found="yes"; break
    fi
  done
  [ "$found" = "yes" ] || fail "--from tag '$FROM_TAG' not in HOPS list"
fi

# --- Dry run ---
if [ "$DRY_RUN" = "true" ]; then
  echo "[run-all-hops] sequence (start_idx=$start_idx):"
  for i in "${!HOPS[@]}"; do
    if [ "$i" -lt "$start_idx" ]; then
      printf '  [skip] %s\n' "${HOPS[$i]}"
    else
      printf '  [run]  %s\n' "${HOPS[$i]}"
    fi
  done
  if [ "$SKIP_TAG_CHECK" = "false" ]; then
    echo "[run-all-hops] running check-tags.sh (read-only)..."
    bash "$SCRIPT_DIR/check-tags.sh"
  fi
  exit 0
fi

# --- Pre-flight tag check ---
if [ "$SKIP_TAG_CHECK" = "false" ]; then
  log "running check-tags.sh..."
  bash "$SCRIPT_DIR/check-tags.sh"
fi

# --- If --from was set, restore data/ from the previous hop's snapshot ---
if [ "$start_idx" -gt 0 ]; then
  prev_tag="${HOPS[$(( start_idx - 1 ))]}"
  src="$SNAP_DIR/$prev_tag"
  if [ ! -d "$src" ]; then
    fail "--from $FROM_TAG requires snapshot $src/ -- not found. Restore from dump or pick an earlier --from."
  fi
  log "tearing compose down (preserving image cache only)..."
  bash "$SCRIPT_DIR/upgrade-hop.sh" --to "$prev_tag" 2>/dev/null || true  # bring env to known state
  log "restoring data/ from $src ..."
  # Stop postgres if running so the cp is safe.
  (cd "$LOCAL_DEV_DIR" && docker compose --env-file .env -f compose/compose.3-24.yml -p local-dev down -v) || true
  rm -rf "$DATA_DIR"
  cp -R "$src" "$DATA_DIR"
fi

# --- Run hops ---
overall_start="$(date +%s)"
for i in "${!HOPS[@]}"; do
  [ "$i" -lt "$start_idx" ] && continue
  tag="${HOPS[$i]}"
  log "==> Hop $((i+1))/${#HOPS[@]}: $tag"
  if ! bash "$SCRIPT_DIR/upgrade-hop.sh" --to "$tag"; then
    fail "hop $tag failed. State left intact for inspection. See logs/hop-fail-$tag.log and 'docker compose logs jobs-runner'."
  fi
done
overall_end="$(date +%s)"
log "walk complete in $(( overall_end - overall_start ))s"

# --- Summary table ---
if [ -f "$REPORT_FILE" ]; then
  echo
  echo "=== hop-report.tsv (last ${#HOPS[@]} rows) ==="
  awk -F'\t' 'NR==1 || /pass|fail/' "$REPORT_FILE" | column -t -s $'\t' || cat "$REPORT_FILE"
fi
