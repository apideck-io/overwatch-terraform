#!/usr/bin/env bash
# Phase 7 pre-flight: verify the Docker Hub tags pinned in run-all-hops.sh
# (and tryretool/code-executor-service for hops >= 3.196) still exist.
# Retool occasionally pulls patches; this catches the failure mode before
# the walk wastes 20 minutes pulling, only to discover the tag is gone.
#
# Reads HOPS from run-all-hops.sh via `source`. Exits non-zero if any
# tag is missing on Docker Hub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ALL="$SCRIPT_DIR/run-all-hops.sh"

[ -f "$RUN_ALL" ] || { echo "[check-tags] FAIL: $RUN_ALL missing" >&2; exit 1; }

# shellcheck disable=SC1090
# run-all-hops.sh exports HOPS when sourced via CHECK_TAGS_SOURCING=1.
CHECK_TAGS_SOURCING=1 . "$RUN_ALL"

command -v jq   >/dev/null 2>&1 || { echo "[check-tags] FAIL: jq required (brew install jq)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[check-tags] FAIL: curl required" >&2; exit 1; }

# tag_minor "3.196.33-stable" -> "3.196" (used only for Docker Hub cache key)
tag_minor() { printf '%s' "$1" | awk -F. '{print $1"."$2}'; }
# Component-wise version compare -- "3.24" must be < "3.196".
ge_version() {
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

# Cache one page per (repo, minor) -- Docker Hub serves them filtered.
tag_exists() {
  local repo="$1" tag="$2" minor
  minor="$(tag_minor "$tag")"
  local cache="/tmp/dh-${repo//\//_}-${minor}.json"
  if [ ! -f "$cache" ]; then
    curl -fsS "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&name=${minor}" > "$cache"
  fi
  jq -e --arg t "$tag" '.results[] | select(.name == $t)' "$cache" >/dev/null
}

missing=0
for tag in "${HOPS[@]}"; do
  if tag_exists "tryretool/backend" "$tag"; then
    echo "[check-tags] OK    tryretool/backend:$tag"
  else
    echo "[check-tags] MISS  tryretool/backend:$tag" >&2
    missing=$(( missing + 1 ))
  fi
  if ge_version "$tag" "3.196.0"; then
    if tag_exists "tryretool/code-executor-service" "$tag"; then
      echo "[check-tags] OK    tryretool/code-executor-service:$tag"
    else
      echo "[check-tags] MISS  tryretool/code-executor-service:$tag" >&2
      missing=$(( missing + 1 ))
    fi
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "[check-tags] $missing tag(s) missing -- bump pins in run-all-hops.sh before walking." >&2
  exit 1
fi

echo "[check-tags] All tags exist."
