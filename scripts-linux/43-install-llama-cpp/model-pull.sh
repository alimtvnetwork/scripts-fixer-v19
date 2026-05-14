#!/usr/bin/env bash
# scripts-linux/43-install-llama-cpp/model-pull.sh
# Linux mirror of scripts/43-install-llama-cpp/helpers/model-picker.ps1.
#
# Reads scripts/43-install-llama-cpp/models-catalog.json (the same Windows
# catalog -- single source of truth) and downloads selected GGUF models via
# fast_download (aria2c-first, 16 splits / 1M pieces).
#
# Usage (basic):
#   ./model-pull.sh                       interactive list + pick
#   ./model-pull.sh list                  print catalog and exit
#   ./model-pull.sh <id> [<id> ...]       download by model id(s)
#   ./model-pull.sh --dir /path <id>...   custom output dir (default $HOME/models/gguf)
#
# Usage (filters -- compose with `list` to preview, with `--all` to download):
#   --family <pat>     match family/displayName/id substring (case-insensitive)
#   --max-ram <gb>     keep models needing <= GB RAM           (ramRequiredGB)
#   --min-ram <gb>     keep models needing >= GB RAM
#   --max-size <gb>    keep models with fileSizeGB <= GB
#   --min-size <gb>    keep models with fileSizeGB >= GB
#   --coding | --reasoning | --writing | --voice | --multilingual | --chat
#                      keep models flagged with the matching capability
#   --exclude <pat>    drop ids/family/displayName matching (repeatable)
#   --all              download every model that survives the filters
#   --dry-run          show what would be downloaded; do not fetch
#
# Defaults: output dir = $HOME/models/gguf, splits=16, piece=1M.
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

# -- ANSI colour helpers (only when stdout is a tty) --------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_GRAY=$'\033[90m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_GRAY=""; C_BOLD=""
fi

rating_colour() {
  # $1 = numeric rating (0-10) -- echoes ANSI prefix.
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if   [ "$n" -ge 9 ]; then printf '%s' "$C_YELLOW"
  elif [ "$n" -ge 7 ]; then printf '%s' "$C_GREEN"
  elif [ "$n" -ge 5 ]; then printf '%s' ""
  else                       printf '%s' "$C_GRAY"
  fi
}

# -- Filters (env-driven; populated by arg parser) ----------------------------
FILTER_FAMILY=""
FILTER_MAX_RAM=""
FILTER_MIN_RAM=""
FILTER_MAX_SIZE=""
FILTER_MIN_SIZE=""
FILTER_CODING=0
FILTER_REASONING=0
FILTER_WRITING=0
FILTER_VOICE=0
FILTER_MULTILINGUAL=0
FILTER_CHAT=0
EXCLUDES=()

# Build a jq filter expression that keeps only models matching the active
# filter set. Pure jq -- no shell escaping pitfalls past the --arg surface.
build_jq_filter() {
  local jqf='.models[]'
  [ -n "$FILTER_MAX_RAM"  ] && jqf+=' | select((.ramRequiredGB // 0) <= ($mxr|tonumber))'
  [ -n "$FILTER_MIN_RAM"  ] && jqf+=' | select((.ramRequiredGB // 0) >= ($mnr|tonumber))'
  [ -n "$FILTER_MAX_SIZE" ] && jqf+=' | select((.fileSizeGB    // 0) <= ($mxs|tonumber))'
  [ -n "$FILTER_MIN_SIZE" ] && jqf+=' | select((.fileSizeGB    // 0) >= ($mns|tonumber))'
  [ "$FILTER_CODING"       -eq 1 ] && jqf+=' | select(.isCoding       == true)'
  [ "$FILTER_REASONING"    -eq 1 ] && jqf+=' | select(.isReasoning    == true)'
  [ "$FILTER_WRITING"      -eq 1 ] && jqf+=' | select(.isWriting      == true)'
  [ "$FILTER_VOICE"        -eq 1 ] && jqf+=' | select(.isVoice        == true)'
  [ "$FILTER_MULTILINGUAL" -eq 1 ] && jqf+=' | select(.isMultilingual == true)'
  [ "$FILTER_CHAT"         -eq 1 ] && jqf+=' | select(.isChat         == true)'
  if [ -n "$FILTER_FAMILY" ]; then
    jqf+=' | select(((.family // "") + " " + (.displayName // "") + " " + (.id // "")) | ascii_downcase | contains($fam | ascii_downcase))'
  fi
  for ex in "${EXCLUDES[@]:-}"; do
    [ -z "$ex" ] && continue
    jqf+=" | select(((.family // \"\") + \" \" + (.displayName // \"\") + \" \" + (.id // \"\")) | ascii_downcase | contains(\"$(printf '%s' "$ex" | tr 'A-Z' 'a-z')\") | not)"
  done
  printf '%s' "$jqf"
}

run_filter() {
  # Echo the filtered model JSON stream (one model per line, compact).
  local jqf; jqf="$(build_jq_filter)"
  jq -c --arg fam "${FILTER_FAMILY:-}" \
        --arg mxr "${FILTER_MAX_RAM:-0}" --arg mnr "${FILTER_MIN_RAM:-0}" \
        --arg mxs "${FILTER_MAX_SIZE:-0}" --arg mns "${FILTER_MIN_SIZE:-0}" \
        "$jqf" "$CATALOG"
}

print_examples_footer() {
  cat <<EOF

${C_BOLD}${C_CYAN}========================================================================${C_RESET}
${C_BOLD}${C_CYAN}  How to download models -- syntax & examples${C_RESET}
${C_BOLD}${C_CYAN}========================================================================${C_RESET}

${C_BOLD}Output directory${C_RESET}
  default                       ${DEFAULT_DIR}
  custom                        --dir /path/to/dir   (alias: -d)

${C_BOLD}Single / multiple downloads${C_RESET}
  ./run.sh models qwen2.5-coder-3b
  ./run.sh models qwen2.5-coder-3b nemotron-8b-opus-distill
  ./run.sh models qwen2.5-coder-3b nemotron-8b-opus-distill --dir /mnt/ai

${C_BOLD}Filter examples (preview with 'list', commit with --all)${C_RESET}
  # Show every Qwen 3.7 family member
  ./run.sh models list --family qwen3.7

  # Download every Qwen 3.7 model that fits in 16 GB RAM
  ./run.sh models --family qwen3.7 --max-ram 16 --all --dir /mnt/ai

  # Same, but skip the giant 32B variant
  ./run.sh models --family qwen3.7 --max-ram 16 --exclude 32b --all

  # All coding models under 8 GB on disk, dry run first
  ./run.sh models list --coding --max-size 8
  ./run.sh models      --coding --max-size 8 --all --dry-run
  ./run.sh models      --coding --max-size 8 --all

  # Reasoning models, 8-32 GB RAM, exclude two specific ids
  ./run.sh models --reasoning --min-ram 8 --max-ram 32 \\
                  --exclude qwen3.5-32b-thinking --exclude nemotron-49b --all

  # Multilingual chat models that fit in 12 GB RAM, default dir
  ./run.sh models --multilingual --chat --max-ram 12 --all

${C_BOLD}Ratings legend${C_RESET}  (printed per model: (coding, reasoning, speed, overall) : numbers, 0-10 scale)
  ${C_YELLOW}9-10${C_RESET}  exceptional       ${C_GREEN}7-8${C_RESET}  strong       5-6   competent       ${C_GRAY}<5${C_RESET}    weak

${C_DIM}# 'list' shows the catalog with no downloads.
# Filters compose: each flag narrows the set further.
# --all is required when you want filtered selection to actually download;
# without --all, filters only affect 'list' output and 'models <id>' is exact.${C_RESET}
EOF
}

print_list() {
  # Header
  printf '%s%-26s %-22s %-7s %-6s %-6s   %s%s\n' \
    "$C_BOLD" "ID" "FAMILY" "PARAMS" "SIZE" "RAM" "RATINGS  (cod/rea/spd/ovr)    DISPLAY" "$C_RESET"
  printf '%-26s %-22s %-7s %-6s %-6s   %s\n' \
    "--------------------------" "----------------------" "-------" "------" "------" \
    "------------------------------------------"

  local total=0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    total=$((total+1))
    local id family params size ram cod rea spd ovr dn
    id="$(    printf '%s' "$row" | jq -r '.id // ""')"
    family="$(printf '%s' "$row" | jq -r '.family // ""')"
    params="$(printf '%s' "$row" | jq -r '.parameters // "?"')"
    size="$(  printf '%s' "$row" | jq -r '.fileSizeGB // 0')"
    ram="$(   printf '%s' "$row" | jq -r '.ramRequiredGB // 0')"
    cod="$(   printf '%s' "$row" | jq -r '.rating.coding    // 0')"
    rea="$(   printf '%s' "$row" | jq -r '.rating.reasoning // 0')"
    spd="$(   printf '%s' "$row" | jq -r '.rating.speed     // 0')"
    ovr="$(   printf '%s' "$row" | jq -r '.rating.overall   // 0')"
    dn="$(    printf '%s' "$row" | jq -r '.displayName // ""')"
    # Truncate long fields so the row stays readable
    [ "${#family}" -gt 22 ] && family="${family:0:21}~"
    [ "${#dn}"     -gt 40 ] && dn="${dn:0:39}~"
    local cc rc sc oc
    cc="$(rating_colour "$cod")"; rc="$(rating_colour "$rea")"
    sc="$(rating_colour "$spd")"; oc="$(rating_colour "$ovr")"
    printf '%-26s %-22s %-7s %5sG %5sG          %s%2s%s   %s%2s%s   %s%2s%s   %s%2s%s   %s\n' \
      "$id" "$family" "$params" "$size" "$ram" \
      "$cc" "$cod" "$C_RESET" \
      "$rc" "$rea" "$C_RESET" \
      "$sc" "$spd" "$C_RESET" \
      "$oc" "$ovr" "$C_RESET" \
      "$dn"
  done < <(run_filter)

  echo
  if [ "$total" -eq 0 ]; then
    printf '%s  (no models match the current filter set)%s\n' "$C_YELLOW" "$C_RESET"
  else
    printf '%s  Total: %d model(s) shown%s\n' "$C_CYAN" "$total" "$C_RESET"
  fi
  print_examples_footer
}

resolve_model() {
  local id="$1"
  jq -r --arg id "$id" \
    '.models[] | select(.id == $id) | "\(.downloadUrl)|\(.fileName)"' \
    "$CATALOG"
}

resolve_filtered_ids() {
  run_filter | jq -r '.id'
}

pick_interactive() {
  print_list
  echo
  read -r -p "Enter model id(s), space-separated: " line
  echo "$line"
}

# -- Arg parsing --------------------------------------------------------------
OUT_DIR="$DEFAULT_DIR"
ARGS=()
WANT_LIST=0
WANT_ALL=0
WANT_DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    list)              WANT_LIST=1; shift ;;
    --dir|-d)          OUT_DIR="${2:-}"; shift 2 ;;
    --dir=*)           OUT_DIR="${1#*=}"; shift ;;
    --family)          FILTER_FAMILY="${2:-}"; shift 2 ;;
    --family=*)        FILTER_FAMILY="${1#*=}"; shift ;;
    --max-ram)         FILTER_MAX_RAM="${2:-}"; shift 2 ;;
    --max-ram=*)       FILTER_MAX_RAM="${1#*=}"; shift ;;
    --min-ram)         FILTER_MIN_RAM="${2:-}"; shift 2 ;;
    --min-ram=*)       FILTER_MIN_RAM="${1#*=}"; shift ;;
    --max-size)        FILTER_MAX_SIZE="${2:-}"; shift 2 ;;
    --max-size=*)      FILTER_MAX_SIZE="${1#*=}"; shift ;;
    --min-size)        FILTER_MIN_SIZE="${2:-}"; shift 2 ;;
    --min-size=*)      FILTER_MIN_SIZE="${1#*=}"; shift ;;
    --coding)          FILTER_CODING=1; shift ;;
    --reasoning)       FILTER_REASONING=1; shift ;;
    --writing)         FILTER_WRITING=1; shift ;;
    --voice)           FILTER_VOICE=1; shift ;;
    --multilingual)    FILTER_MULTILINGUAL=1; shift ;;
    --chat)            FILTER_CHAT=1; shift ;;
    --exclude)         EXCLUDES+=("${2:-}"); shift 2 ;;
    --exclude=*)       EXCLUDES+=("${1#*=}"); shift ;;
    --all)             WANT_ALL=1; shift ;;
    --dry-run)         WANT_DRY=1; shift ;;
    -h|--help)         sed -n '2,32p' "$0"; exit 0 ;;
    *)                 ARGS+=("$1"); shift ;;
  esac
done

if [ "$WANT_LIST" -eq 1 ]; then
  print_list; exit 0
fi

# Determine the effective id list
hasFilters=0
if [ -n "$FILTER_FAMILY$FILTER_MAX_RAM$FILTER_MIN_RAM$FILTER_MAX_SIZE$FILTER_MIN_SIZE" ] \
   || [ "$FILTER_CODING$FILTER_REASONING$FILTER_WRITING$FILTER_VOICE$FILTER_MULTILINGUAL$FILTER_CHAT" != "000000" ] \
   || [ "${#EXCLUDES[@]}" -gt 0 ]; then
  hasFilters=1
fi

if [ "${#ARGS[@]}" -eq 0 ] && [ "$WANT_ALL" -eq 1 ] && [ "$hasFilters" -eq 1 ]; then
  # Filtered bulk download
  while IFS= read -r mid; do [ -n "$mid" ] && ARGS+=("$mid"); done < <(resolve_filtered_ids)
fi

if [ "${#ARGS[@]}" -eq 0 ]; then
  if [ "$hasFilters" -eq 1 ] && [ "$WANT_ALL" -ne 1 ]; then
    log_warn "[model-pull] filters set but no --all and no explicit ids -- printing matching list instead"
    print_list; exit 0
  fi
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
log_info "[model-pull] selection : ${ARGS[*]}"
[ "$WANT_DRY" -eq 1 ] && log_info "[model-pull] DRY RUN -- no downloads will start"

ok=0; fail=0; skipped=0
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
    skipped=$((skipped+1)); continue
  fi

  if [ "$WANT_DRY" -eq 1 ]; then
    log_info "[model-pull] would download: $id -> $target  (url=$url)"
    continue
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
log_info "[model-pull] summary: ok=$ok skipped=$skipped fail=$fail"
[ "$fail" -eq 0 ]
