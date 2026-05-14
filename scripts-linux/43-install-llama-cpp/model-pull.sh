#!/usr/bin/env bash
# scripts-linux/43-install-llama-cpp/model-pull.sh
# Linux mirror of scripts/43-install-llama-cpp/helpers/model-picker.ps1.
#
# Reads scripts/43-install-llama-cpp/models-catalog.json (the same
# Windows catalog -- single source of truth) and downloads selected
# GGUF models via fast_download (aria2c-first, 16 splits / 1M pieces).
#
# Usage:
#   ./model-pull.sh                       # interactive list + pick
#   ./model-pull.sh list                  # print catalog and exit
#   ./model-pull.sh <id> [<id> ...]       # download by model id(s)
#   ./model-pull.sh --dir /path <id>...   # custom output dir
#
# Defaults: output dir = $HOME/models/gguf
#
# Spec: spec/shared/fast-download.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DIR="$(cd "$SCRIPT_DIR/../_shared" && pwd)"

# shellcheck source=/dev/null
. "$SHARED_DIR/logger.sh"
# shellcheck source=/dev/null
. "$SHARED_DIR/file-error.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$SHARED_DIR/pkg-detect.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$SHARED_DIR/apt-install.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$SHARED_DIR/fast-download.sh"

CATALOG="$REPO_ROOT/scripts/43-install-llama-cpp/models-catalog.json"
DEFAULT_DIR="$HOME/models/gguf"

if [ ! -f "$CATALOG" ]; then
  log_file_error "$CATALOG" "models-catalog.json missing -- cannot resolve model ids"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log_err "[model-pull] jq is required to parse the catalog"
  exit 1
fi

print_list() {
  printf '%-32s %-10s %-8s  %s\n' "ID" "PARAMS" "SIZE_GB" "DISPLAY"
  printf '%-32s %-10s %-8s  %s\n' "--" "------" "-------" "-------"
  jq -r '.models[] | "\(.id)\t\(.parameters // "?")\t\(.fileSizeGB // "?")\t\(.displayName)"' "$CATALOG" \
    | while IFS=$'\t' read -r id params size name; do
        printf '%-32s %-10s %-8s  %s\n' "$id" "$params" "$size" "$name"
      done
}

resolve_model() {
  # Echo "<url>|<filename>" for a given id, or empty on miss.
  local id="$1"
  jq -r --arg id "$id" \
    '.models[] | select(.id == $id) | "\(.downloadUrl)|\(.fileName)"' \
    "$CATALOG"
}

pick_interactive() {
  print_list
  echo
  read -r -p "Enter model id(s), space-separated: " line
  echo "$line"
}

# -- Arg parsing ---------------------------------------------------------------
OUT_DIR="$DEFAULT_DIR"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    list)         print_list; exit 0 ;;
    --dir|-d)     OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then
  read -r -a ARGS <<< "$(pick_interactive)"
fi

if [ "${#ARGS[@]}" -eq 0 ]; then
  log_warn "[model-pull] no model ids supplied -- nothing to do"
  exit 0
fi

if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
  log_file_error "$OUT_DIR" "cannot create output directory"
  exit 1
fi

log_info "[model-pull] output dir: $OUT_DIR"

ok=0; fail=0
for id in "${ARGS[@]}"; do
  pair="$(resolve_model "$id")"
  if [ -z "$pair" ] || [ "$pair" = "|" ]; then
    log_file_error "$CATALOG" "model id '$id' not found in catalog"
    fail=$((fail+1)); continue
  fi
  url="${pair%%|*}"
  fname="${pair##*|}"
  target="$OUT_DIR/$fname"

  if [ -s "$target" ]; then
    log_ok "[model-pull] already present: $target"
    ok=$((ok+1)); continue
  fi

  log_info "[model-pull] downloading $id -> $target"
  if fast_download "$url" "$OUT_DIR" 16 1M; then
    ok=$((ok+1))
  else
    log_file_error "$target" "fast_download failed for model id '$id' (url=$url)"
    fail=$((fail+1))
  fi
done

echo
log_info "[model-pull] summary: ok=$ok fail=$fail"
[ "$fail" -eq 0 ]
