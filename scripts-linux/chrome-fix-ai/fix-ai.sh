#!/usr/bin/env bash
# Linux/macOS port of scripts/58-install-chrome/helpers/fix-ai.ps1
#
# Disable Chrome/Chromium/Brave built-in AI (Gemini Nano / Optimization
# Guide On-Device Model) and reclaim the 2-4 GB it consumes.
#
# Three layers (applied together so the component-updater cannot resurrect
# the model after we delete it):
#
#   1) System managed-policy JSON (requires root -- gracefully skipped if not)
#      Linux:  /etc/opt/chrome/policies/managed/lovable-fix-ai.json
#              /etc/chromium/policies/managed/lovable-fix-ai.json
#              /etc/brave/policies/managed/lovable-fix-ai.json
#      macOS:  ~/Library/Preferences/<bundle>.plist via `defaults write`
#              (per-user; system /Library/Managed Preferences requires MDM).
#
#   2) Per-user `Local State` JSON patch -- preserves every other chrome://flag.
#
#   3) On-disk model cache sweep with bytes-freed report.
#
# Flags:  --dry-run | --verify | --restore | --yes | --browser <id> | --help
# Browser ids: chrome (default) | chromium | brave | all

set -u

# ---- locate shared helpers --------------------------------------------------
__SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__SHARED_DIR="$(cd "$__SELF_DIR/../_shared" && pwd 2>/dev/null || echo "$__SELF_DIR/../_shared")"
# shellcheck disable=SC1091
. "$__SHARED_DIR/logger.sh"
# shellcheck disable=SC1091
[ -f "$__SHARED_DIR/file-error.sh" ] && . "$__SHARED_DIR/file-error.sh"

# ---- args -------------------------------------------------------------------
DRY_RUN=0; DO_VERIFY=0; DO_RESTORE=0; ASSUME_YES=0; BROWSER="chrome"
show_help() {
  cat <<EOF
chrome-fix-ai (Linux/macOS) -- disable Chrome on-device AI + sweep cache

Usage:
  fix-ai.sh [--browser chrome|chromium|brave|all]
            [--dry-run] [--verify] [--restore] [--yes] [--help]

Layers (applied together):
  1) system managed-policy JSON     (root only; gracefully skipped if not)
  2) per-user Local State JSON      (preserves all other chrome://flags)
  3) on-disk model cache sweep      (reports bytes freed)

Examples:
  ./fix-ai.sh                       # apply (chrome only)
  ./fix-ai.sh --browser all         # apply to chrome+chromium+brave
  ./fix-ai.sh --verify              # print current state, no changes
  ./fix-ai.sh --dry-run             # preview only
  sudo ./fix-ai.sh                  # include layer-1 system policy
  ./fix-ai.sh --restore             # remove policies + restore Local State
EOF
}
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)         DRY_RUN=1 ;;
    --verify|-v)          DO_VERIFY=1 ;;
    --restore)            DO_RESTORE=1 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    --browser)            BROWSER="${2:-chrome}"; shift ;;
    --browser=*)          BROWSER="${1#*=}" ;;
    -h|--help|help)       show_help; exit 0 ;;
    *) log_warn "fix-ai: unknown arg '$1'" ;;
  esac
  shift
done

case "$BROWSER" in
  chrome|chromium|brave|all) ;;
  *) log_err "fix-ai: unknown --browser '$BROWSER' (use chrome|chromium|brave|all)"; exit 64 ;;
esac

# ---- platform detection -----------------------------------------------------
UNAME="$(uname -s)"
case "$UNAME" in
  Linux)  PLATFORM="linux" ;;
  Darwin) PLATFORM="macos" ;;
  *) log_err "fix-ai: unsupported platform '$UNAME' (Linux/macOS only)"; exit 65 ;;
esac

# ---- per-browser path table -------------------------------------------------
# Echoes:  user_data_dir | local_state | policy_path | proc_name | plist_id
browser_paths() {
  local id="$1"
  if [ "$PLATFORM" = "linux" ]; then
    case "$id" in
      chrome)   printf '%s|%s|%s|%s|%s\n' \
                  "$HOME/.config/google-chrome" \
                  "$HOME/.config/google-chrome/Local State" \
                  "/etc/opt/chrome/policies/managed/lovable-fix-ai.json" \
                  "chrome" "" ;;
      chromium) printf '%s|%s|%s|%s|%s\n' \
                  "$HOME/.config/chromium" \
                  "$HOME/.config/chromium/Local State" \
                  "/etc/chromium/policies/managed/lovable-fix-ai.json" \
                  "chromium" "" ;;
      brave)    printf '%s|%s|%s|%s|%s\n' \
                  "$HOME/.config/BraveSoftware/Brave-Browser" \
                  "$HOME/.config/BraveSoftware/Brave-Browser/Local State" \
                  "/etc/brave/policies/managed/lovable-fix-ai.json" \
                  "brave" "" ;;
    esac
  else
    case "$id" in
      chrome)   printf '%s|%s|%s|%s|%s\n' \
                  "$HOME/Library/Application Support/Google/Chrome" \
                  "$HOME/Library/Application Support/Google/Chrome/Local State" \
                  "$HOME/Library/Preferences/com.google.Chrome.plist" \
                  "Google Chrome" "com.google.Chrome" ;;
      chromium) printf '%s|%s|%s|%s|%s\n' \
                  "$HOME/Library/Application Support/Chromium" \
                  "$HOME/Library/Application Support/Chromium/Local State" \
                  "$HOME/Library/Preferences/org.chromium.Chromium.plist" \
                  "Chromium" "org.chromium.Chromium" ;;
      brave)    printf '%s|%s|%s|%s|%s\n' \
                  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser" \
                  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Local State" \
                  "$HOME/Library/Preferences/com.brave.Browser.plist" \
                  "Brave Browser" "com.brave.Browser" ;;
    esac
  fi
}

POLICY_NAMES=(
  GenAiDefaultSettings
  GenAILocalFoundationalModelSettings
  HelpMeWriteSettings
  CreateThemesSettings
  TabOrganizerSettings
  TabCompareSettings
  HistorySearchSettings
  AutofillPredictionSettings
)
FLAG_NAMES=(
  optimization-guide-on-device-model
  prompt-api-for-gemini-nano
  summarization-api-for-gemini-nano
  writer-api-for-gemini-nano
  rewriter-api-for-gemini-nano
)
DISABLED_SLOT=2
CACHE_SUBDIRS=( OptimizationGuideOnDeviceModel OptGuideOnDeviceModel )

# ---- utilities --------------------------------------------------------------
fmt_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB", u);
    i=1; while (b>=1024 && i<5){ b=b/1024; i++ }
    if (i==1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i];
  }'
}
folder_size() {
  local p="$1"
  [ -d "$p" ] || { echo 0; return; }
  # du -sb is Linux-only; macOS lacks -b. Use find+stat for portability.
  if [ "$PLATFORM" = "linux" ]; then
    du -sb "$p" 2>/dev/null | awk '{print $1+0}' || echo 0
  else
    find "$p" -type f -print0 2>/dev/null \
      | xargs -0 stat -f '%z' 2>/dev/null \
      | awk '{s+=$1} END{print s+0}'
  fi
}
browser_running() {
  local proc="$1"
  pgrep -x -f "$proc" >/dev/null 2>&1 && return 0
  if [ "$PLATFORM" = "macos" ]; then
    pgrep -f "/$proc" >/dev/null 2>&1 && return 0
  fi
  return 1
}
require_jq() {
  command -v jq >/dev/null 2>&1 || {
    log_err "fix-ai: 'jq' is required for Local State JSON patching."
    log_info "       Install:  apt-get install jq   |   dnf install jq   |   brew install jq"
    return 1
  }
}
is_root() { [ "$(id -u 2>/dev/null || echo 1000)" = "0" ]; }

# NOTE: helpers that "return" via globals (POLICY_RESULT, PATCH_*, SWEEP_*)
# because the shared logger writes to stdout; capturing stdout would mix log
# lines into the return value.

# ---- Layer 1: system policy -------------------------------------------------
POLICY_RESULT=""
apply_policy_linux() {
  local policy_path="$1"
  if ! is_root; then
    log_warn "Skipping system policy ($policy_path): not running as root. Re-run with sudo to apply enterprise policy."
    POLICY_RESULT="skipped"; return 0
  fi
  local dir; dir="$(dirname "$policy_path")"
  if [ "$DRY_RUN" = 1 ]; then
    log_info "DRY-RUN: would mkdir -p $dir and write managed policy JSON (${#POLICY_NAMES[@]} keys)"
    POLICY_RESULT="ok"; return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    log_file_error "$dir" "mkdir failed (cannot create managed-policy directory)"
    POLICY_RESULT="fail"; return 1
  fi
  {
    printf '{\n'
    local i=0 n=${#POLICY_NAMES[@]}
    for k in "${POLICY_NAMES[@]}"; do
      i=$((i+1))
      if [ "$i" -lt "$n" ]; then printf '  "%s": 1,\n' "$k"
      else                       printf '  "%s": 1\n'  "$k"
      fi
    done
    printf '}\n'
  } > "$policy_path.tmp" 2>/dev/null || {
    log_file_error "$policy_path.tmp" "write failed (cannot stage managed policy)"
    POLICY_RESULT="fail"; return 1
  }
  mv -f "$policy_path.tmp" "$policy_path" 2>/dev/null || {
    log_file_error "$policy_path" "rename failed (cannot publish managed policy)"
    POLICY_RESULT="fail"; return 1
  }
  log_success "Managed policy written: $policy_path  (${#POLICY_NAMES[@]} keys)"
  POLICY_RESULT="ok"; return 0
}
apply_policy_macos() {
  local plist_id="$1"
  [ -n "$plist_id" ] || { POLICY_RESULT="skipped"; return 0; }
  if [ "$DRY_RUN" = 1 ]; then
    log_info "DRY-RUN: would 'defaults write $plist_id <key> -int 1' for ${#POLICY_NAMES[@]} keys"
    POLICY_RESULT="ok"; return 0
  fi
  for k in "${POLICY_NAMES[@]}"; do
    if defaults write "$plist_id" "$k" -int 1 2>/dev/null; then
      log_success "Per-user policy set: $plist_id $k = 1"
    else
      log_warn "Could not set per-user policy: $plist_id $k  (reason: defaults write failed)"
    fi
  done
  POLICY_RESULT="ok"; return 0
}
remove_policy_linux() {
  local policy_path="$1"
  if [ ! -f "$policy_path" ]; then
    log_info "Policy file not present (already clean): $policy_path"
    return 0
  fi
  if ! is_root; then
    log_warn "Cannot remove $policy_path: not root."
    return 0
  fi
  rm -f "$policy_path" && log_success "Policy removed: $policy_path" \
    || log_file_error "$policy_path" "rm failed (cannot remove managed policy)"
}
remove_policy_macos() {
  local plist_id="$1"
  [ -n "$plist_id" ] || return 0
  for k in "${POLICY_NAMES[@]}"; do
    defaults delete "$plist_id" "$k" >/dev/null 2>&1 \
      && log_success "Per-user policy removed: $plist_id $k" \
      || log_info "Per-user policy not set (clean): $plist_id $k"
  done
}

# ---- Layer 2: Local State JSON patch ----------------------------------------
patch_local_state() {
  local local_state="$1" proc_name="$2"
  if [ ! -f "$local_state" ]; then
    log_warn "Local State not found at: $local_state  (reason: browser never launched on this profile or user-data dir differs)"
    echo "skipped|0|"; return 0
  fi
  if browser_running "$proc_name"; then
    if [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
      log_err "Refusing to patch Local State: '$proc_name' is running. Close it and retry, or pass --yes (the browser may overwrite the patch on exit)."
      echo "skipped|0|"; return 1
    fi
  fi
  require_jq || { echo "skipped|0|"; return 1; }

  local additions kept_count add_count
  additions="$(printf '%s\n' "${FLAG_NAMES[@]}" | awk -v slot="$DISABLED_SLOT" '{printf "\"%s@%d\"\n", $0, slot}' | paste -sd, -)"
  local flag_pattern; flag_pattern="$(printf '|^%s@' "${FLAG_NAMES[@]}" | sed 's/^|//')"

  local merged_json
  if ! merged_json="$(jq --argjson add "[$additions]" \
       --arg pat "$flag_pattern" \
       '.browser = (.browser // {})
        | .browser.enabled_labs_experiments =
            (((.browser.enabled_labs_experiments // []) | map(select(test($pat) | not))) + $add)' \
       "$local_state" 2>/dev/null)"; then
    log_file_error "$local_state" "jq parse failed (cannot read Local State JSON)"
    echo "skipped|0|"; return 1
  fi

  kept_count=$(printf '%s' "$merged_json" | jq -r --arg pat "$flag_pattern" \
                 '.browser.enabled_labs_experiments | map(select(test($pat) | not)) | length' 2>/dev/null || echo 0)
  add_count=${#FLAG_NAMES[@]}

  if [ "$DRY_RUN" = 1 ]; then
    log_info "DRY-RUN: would write $add_count flag entries into $local_state (preserving $kept_count existing)"
    for f in "${FLAG_NAMES[@]}"; do log_info "  + ${f}@${DISABLED_SLOT}"; done
    echo "ok|$add_count|"; return 0
  fi

  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${local_state}.bak-fixai-${stamp}"
  if ! cp -f "$local_state" "$backup" 2>/dev/null; then
    log_file_error "$backup" "backup copy failed (refusing to patch without backup)"
    echo "skipped|0|"; return 1
  fi
  log_info "Backup written: $backup"

  if ! printf '%s' "$merged_json" > "$local_state.tmp" 2>/dev/null \
     || ! mv -f "$local_state.tmp" "$local_state" 2>/dev/null; then
    log_file_error "$local_state" "write failed (could not publish patched Local State)"
    echo "skipped|0|$backup"; return 1
  fi
  log_success "Local State patched: $add_count AI flag(s) disabled, $kept_count other flag(s) preserved"
  echo "ok|$add_count|$backup"; return 0
}

restore_local_state() {
  local user_data="$1" local_state="$2"
  if [ ! -d "$user_data" ]; then
    log_warn "User-Data folder missing: $user_data  (reason: nothing to restore)"
    return 0
  fi
  local newest
  newest="$(ls -1t "$user_data"/Local\ State.bak-fixai-* 2>/dev/null | head -1)"
  if [ -z "$newest" ]; then
    log_warn "No fix-ai backup found in: $user_data  (reason: nothing to restore)"
    return 0
  fi
  if cp -f "$newest" "$local_state" 2>/dev/null; then
    log_success "Restored Local State from: $newest"
  else
    log_file_error "$local_state" "restore copy failed from $newest"
  fi
}

# ---- Layer 3: cache sweep ---------------------------------------------------
sweep_cache() {
  local user_data="$1"
  local total_freed=0 swept=0
  for sub in "${CACHE_SUBDIRS[@]}"; do
    local root="$user_data/$sub"
    if [ ! -d "$root" ]; then
      log_info "Cache root missing: $root  (reason: already clean)"
      continue
    fi
    local size; size="$(folder_size "$root")"
    if [ "$DRY_RUN" = 1 ]; then
      log_info "DRY-RUN: would delete $root ($(fmt_bytes "$size"))"
      total_freed=$((total_freed + size)); swept=$((swept + 1))
      continue
    fi
    if rm -rf "$root" 2>/dev/null; then
      log_success "Cache swept: $root ($(fmt_bytes "$size") freed)"
      total_freed=$((total_freed + size)); swept=$((swept + 1))
    else
      log_file_error "$root" "rm -rf failed (cannot delete model cache)"
    fi
  done
  echo "$total_freed|$swept"
}

# ---- verify ------------------------------------------------------------------
show_status_one() {
  local id="$1" line
  line="$(browser_paths "$id")"
  local user_data local_state policy_path proc_name plist_id
  IFS='|' read -r user_data local_state policy_path proc_name plist_id <<<"$line"

  printf '\n  --- %s ---\n' "$id" >&2
  # policy
  if [ "$PLATFORM" = "linux" ]; then
    if [ -f "$policy_path" ]; then
      local keys; keys=$(grep -c '"[A-Za-z]\+Settings"\|"GenAi' "$policy_path" 2>/dev/null || echo 0)
      log_info "Policy file        : $policy_path  ($keys key(s))"
    else
      log_info "Policy file        : (absent) $policy_path"
    fi
  else
    if [ -n "$plist_id" ]; then
      local hit=0
      for k in "${POLICY_NAMES[@]}"; do
        defaults read "$plist_id" "$k" >/dev/null 2>&1 && hit=$((hit+1))
      done
      log_info "Per-user policy    : $hit/${#POLICY_NAMES[@]} keys set on $plist_id"
    fi
  fi
  # flags
  if [ -f "$local_state" ] && command -v jq >/dev/null 2>&1; then
    local hit=0
    for f in "${FLAG_NAMES[@]}"; do
      jq -e --arg e "${f}@${DISABLED_SLOT}" \
        '(.browser.enabled_labs_experiments // []) | index($e)' \
        "$local_state" >/dev/null 2>&1 && hit=$((hit+1))
    done
    log_info "Flags disabled     : $hit/${#FLAG_NAMES[@]}"
  else
    log_info "Flags disabled     : (Local State or jq missing)"
  fi
  # cache
  local total=0
  for sub in "${CACHE_SUBDIRS[@]}"; do
    total=$((total + $(folder_size "$user_data/$sub")))
  done
  log_info "Model cache on disk: $(fmt_bytes "$total")"
  # process
  if browser_running "$proc_name"; then
    log_info "Process            : '$proc_name' is RUNNING"
  else
    log_info "Process            : '$proc_name' not running"
  fi
}

# ---- targets ----------------------------------------------------------------
TARGETS=()
if [ "$BROWSER" = "all" ]; then TARGETS=(chrome chromium brave)
else TARGETS=("$BROWSER")
fi

# ---- install-paths banner (informational) ----------------------------------
if [ -f "$__SHARED_DIR/install-paths.sh" ]; then
  # shellcheck disable=SC1091
  . "$__SHARED_DIR/install-paths.sh"
  _first="${TARGETS[0]}"
  _line="$(browser_paths "$_first")"
  _ud="${_line%%|*}"
  write_install_paths \
    --tool   "Chrome fix-ai ($BROWSER)" \
    --source "$__SELF_DIR/fix-ai.sh" \
    --temp   "${_ud}/OptimizationGuideOnDeviceModel" \
    --target "$_ud" \
    --action "Configure"
fi

# ---- verify mode ------------------------------------------------------------
if [ "$DO_VERIFY" = 1 ]; then
  log_info "Verifying Chrome AI state ($PLATFORM, browser=$BROWSER)..."
  for t in "${TARGETS[@]}"; do show_status_one "$t"; done
  exit 0
fi

# ---- restore mode -----------------------------------------------------------
if [ "$DO_RESTORE" = 1 ]; then
  log_info "Restoring previous Chrome AI configuration ($PLATFORM, browser=$BROWSER)..."
  for t in "${TARGETS[@]}"; do
    line="$(browser_paths "$t")"
    IFS='|' read -r ud ls pp pn pid <<<"$line"
    if [ "$PLATFORM" = "linux" ]; then remove_policy_linux "$pp"
    else                                remove_policy_macos "$pid"
    fi
    restore_local_state "$ud" "$ls"
  done
  log_info "Restore complete. Run with --verify to confirm."
  exit 0
fi

# ---- apply mode -------------------------------------------------------------
MODE="APPLY"; [ "$DRY_RUN" = 1 ] && MODE="DRY-RUN"
log_info "Chrome fix-ai: disabling on-device AI ($MODE, platform=$PLATFORM, browser=$BROWSER)"

OVERALL_OK=1
SUMMARY_LINES=()
TOTAL_FREED=0
for t in "${TARGETS[@]}"; do
  line="$(browser_paths "$t")"
  IFS='|' read -r ud ls pp pn pid <<<"$line"
  printf '\n  ===== %s =====\n' "$t" >&2

  # Layer 1
  if [ "$PLATFORM" = "linux" ]; then pol_result="$(apply_policy_linux "$pp")"
  else                                pol_result="$(apply_policy_macos "$pid")"
  fi

  # Layer 2
  ps_out="$(patch_local_state "$ls" "$pn")" || true
  IFS='|' read -r ps_status ps_count ps_backup <<<"$ps_out"

  # Layer 3
  sw_out="$(sweep_cache "$ud")"
  IFS='|' read -r sw_freed sw_roots <<<"$sw_out"
  TOTAL_FREED=$((TOTAL_FREED + sw_freed))

  SUMMARY_LINES+=("$(printf '  %-9s policy=%-8s flags=%-9s cache=%s freed across %s root(s)' \
    "$t" "$pol_result" "${ps_status}(${ps_count:-0}/${#FLAG_NAMES[@]})" "$(fmt_bytes "$sw_freed")" "${sw_roots:-0}")")

  [ "$ps_status" = "ok" ] || [ "$DRY_RUN" = 1 ] || OVERALL_OK=0
done

printf '\n' >&2
log_info "Summary:"
for l in "${SUMMARY_LINES[@]}"; do printf '%s\n' "$l" >&2; done
log_info "Total freed across all browsers: $(fmt_bytes "$TOTAL_FREED")"

[ "$OVERALL_OK" = 1 ] && exit 0 || exit 1
