#!/usr/bin/env bash
# 35-install-gitmap -- gitmap CLI (curl one-liner from gitmap-v20 main branch)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_ID="35"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/install-paths.sh"

CONFIG="$SCRIPT_DIR/config.json"
[ -f "$CONFIG" ] || { log_file_error "$CONFIG" "config.json missing for 35-install-gitmap"; exit 1; }

# ---------------------------------------------------------------------------
# Resolve effective git ref (branch / tag / commit)
# Precedence:  --tag flag  >  $GITMAP_TAG env  >  config install.releaseTag
#              >  hard default "main".
# Anywhere {tag} appears in install.installUrl is substituted. The ref now
# points at a path inside the gitmap-v20 repo (default: main branch).
# ---------------------------------------------------------------------------
TAG_FLAG=""
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)   TAG_FLAG="${2:-}"; shift 2 ;;
    --tag=*) TAG_FLAG="${1#--tag=}"; shift ;;
    *)       ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

CONFIG_TAG="$(grep -oE '"releaseTag"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)"
CONFIG_URL_TEMPLATE="$(grep -oE '"installUrl"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)"

EFFECTIVE_TAG="${TAG_FLAG:-${GITMAP_TAG:-${CONFIG_TAG:-main}}}"
# Numeric versions like "3.181" -> "v3.181"; branch names + explicit tags pass through.
case "$EFFECTIVE_TAG" in
  [0-9]*) EFFECTIVE_TAG="v${EFFECTIVE_TAG}" ;;
esac

URL_TEMPLATE="${CONFIG_URL_TEMPLATE:-https://raw.githubusercontent.com/alimtvnetwork/gitmap-v20/{tag}/gitmap/scripts/install.sh}"
INSTALL_URL="${URL_TEMPLATE//\{tag\}/$EFFECTIVE_TAG}"

log_info "[35] gitmap release tag: $EFFECTIVE_TAG"
log_info "[35] resolved install URL: $INSTALL_URL"

# Where the upstream installer drops the binary by default.
BIN_DIR="${HOME}/.local/bin"
DEST="$BIN_DIR/gitmap"
INSTALLED_MARK="$ROOT/.installed/35.ok"

verify_installed() { command -v gitmap >/dev/null 2>&1 || [ -x "$DEST" ]; }

# ---------------------------------------------------------------------------
# assert_gitmap_version -- authoritative post-install check.
#   1. Resolves the gitmap binary (PATH first, then $DEST fallback).
#   2. Runs `gitmap --version` and captures stdout+stderr+exit code.
#   3. Logs the resolved binary path and printed version on success.
#   4. Logs an explicit file-error with the exact path + reason on failure.
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
assert_gitmap_version() {
  log_info "[35] Verifying 'gitmap --version' works in current session..."

  local bin=""
  if command -v gitmap >/dev/null 2>&1; then
    bin="$(command -v gitmap)"
  elif [ -x "$DEST" ]; then
    bin="$DEST"
    log_warn "[35] gitmap not on PATH; falling back to $DEST"
  else
    log_file_error "$DEST" "gitmap binary not found on PATH and not present at \$DEST after install"
    return 1
  fi

  local out rc
  out="$("$bin" --version 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    log_file_error "$bin" "'gitmap --version' exited code=$rc output=${out:-<empty>}"
    return 1
  fi

  log_ok   "[35] Verified: gitmap --version -> $out"
  log_info "[35] gitmap binary path: $bin"
  return 0
}

verb_install() {
  write_install_paths \
    --tool   "gitmap" \
    --source "$INSTALL_URL (curl | sh)" \
    --temp   "${TMPDIR:-/tmp}/scripts-fixer/gitmap" \
    --target "$DEST"

  log_info "[35] Starting gitmap installer"
  if verify_installed; then
    log_ok "[35] Already installed"
    if assert_gitmap_version; then
      mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
    fi
    log_warn "[35] Binary present but version check failed; continuing to reinstall"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log_file_error "(curl)" "curl not found; cannot run gitmap install one-liner"
    return 1
  fi

  mkdir -p "$BIN_DIR" || { log_file_error "$BIN_DIR" "bin dir mkdir failed"; return 1; }

  log_info "[35] Invoking: curl -fsSL $INSTALL_URL | sh"
  if ! curl -fsSL "$INSTALL_URL" | sh; then
    log_file_error "$INSTALL_URL" "curl | sh one-liner exited non-zero"
    return 1
  fi

  # Refresh PATH so a freshly-created ~/.local/bin/gitmap resolves immediately.
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) export PATH="$BIN_DIR:$PATH" ;; esac

  if assert_gitmap_version; then
    mkdir -p "$ROOT/.installed"; touch "$INSTALLED_MARK"; return 0
  fi
  log_warn "[35] Verify FAILED after install (binary not on PATH or --version failed; check $DEST)"
  return 1
}

verb_check() {
  if assert_gitmap_version; then return 0; fi
  log_warn "[35] Verify FAILED"
  return 1
}
verb_repair()    { rm -f "$DEST" "$INSTALLED_MARK"; verb_install; }
verb_uninstall() {
  rm -f "$DEST" || log_file_error "$DEST" "removal failed"
  rm -f "$INSTALLED_MARK"
  log_ok "[35] Removed gitmap"
}

case "${1:-install}" in
  install)   verb_install ;;
  check)     verb_check ;;
  repair)    verb_repair ;;
  uninstall) verb_uninstall ;;
  *) log_err "[35] Unknown verb: $1"; exit 2 ;;
esac
