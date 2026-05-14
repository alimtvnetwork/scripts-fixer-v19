#!/usr/bin/env bash
# remote-install.sh -- generic SHA256-pinned remote installer for Linux/macOS.
#
# Mirror of the Windows `remote.<key>` system in scripts/shared/install-keywords.json.
# Reads a small JSON descriptor (url + sha256 + label), downloads the body to a
# tempfile, verifies the hash BEFORE any execution, and -- on match -- pipes
# the verified body into `bash`. On hash mismatch the body is moved to
# .quarantine/ for forensic review and execution is REFUSED (CODE RED).
#
# Usage:  remote_install <descriptor.json>
#
# Descriptor schema (minimal):
#   { "url": "...", "sha256": "<lowercase-hex>", "label": "..." }
set -u

# Resolve helpers relative to this file so the function is reusable from
# any caller (run.sh, ad-hoc scripts, tests).
_RI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RI_SHARED="$(cd "$_RI_DIR/.." && pwd)"
. "$_RI_SHARED/logger.sh"
. "$_RI_SHARED/file-error.sh"

remote_install() {
  local descriptor="${1:-}"
  if [ -z "$descriptor" ]; then
    log_file_error "(descriptor)" "remote_install: descriptor path argument is required"
    return 64
  fi
  if [ ! -f "$descriptor" ]; then
    log_file_error "$descriptor" "remote_install: descriptor JSON file not found on disk"
    return 1
  fi

  # Parse with jq if available, else fall back to grep+sed (single-line only).
  local url sha label
  if command -v jq >/dev/null 2>&1; then
    url="$(jq -r '.url   // empty' "$descriptor")"
    sha="$(jq -r '.sha256 // empty' "$descriptor")"
    label="$(jq -r '.label // empty' "$descriptor")"
  else
    url="$(  grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]*"'    "$descriptor" | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)"
    sha="$(  grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[^"]*"' "$descriptor" | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)"
    label="$(grep -oE '"label"[[:space:]]*:[[:space:]]*"[^"]*"'  "$descriptor" | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)"
  fi

  if [ -z "$url" ]; then
    log_file_error "$descriptor" "remote_install: descriptor missing required 'url' field"
    return 1
  fi
  if [ -z "$sha" ]; then
    log_file_error "$descriptor" "remote_install: descriptor missing required 'sha256' pin (CODE RED -- refuse to run unpinned remote scripts)"
    return 1
  fi
  case "$url" in
    https://*) : ;;
    *)
      log_file_error "$url" "remote_install: refusing non-https URL (got: $url)"
      return 1 ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    log_file_error "(curl)" "remote_install: curl not found on PATH; cannot download remote installer"
    return 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    log_file_error "(sha256sum|shasum)" "remote_install: no SHA256 hashing tool available"
    return 1
  fi

  log_info  "[remote] label : ${label:-<unlabelled>}"
  log_info  "[remote] url   : $url"
  log_info  "[remote] pin   : $sha"

  # Download to a tempfile owned by mktemp so concurrent runs don't collide.
  local tmpdir tmp
  tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t ri)"
  if [ ! -d "$tmpdir" ]; then
    log_file_error "(mktemp)" "remote_install: could not create temp dir for download"
    return 1
  fi
  tmp="$tmpdir/installer.sh"

  log_info "[remote] downloading -> $tmp"
  if ! curl -fsSL "$url" -o "$tmp"; then
    log_file_error "$url" "remote_install: curl download failed (network/4xx/5xx)"
    rm -rf "$tmpdir"
    return 1
  fi

  # Verify. Compute hash exactly the way Windows side does -- raw body bytes.
  local got
  if command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$tmp" | awk '{print $1}')"
  else
    got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  fi
  log_info "[remote] computed: $got"

  # Lower-case both sides before comparing.
  local sha_lc got_lc
  sha_lc="$(printf '%s' "$sha" | tr 'A-Z' 'a-z')"
  got_lc="$(printf '%s' "$got" | tr 'A-Z' 'a-z')"
  if [ "$got_lc" != "$sha_lc" ]; then
    # Quarantine the suspect body so the user can audit it later.
    local quarantine
    quarantine="$_RI_DIR/.quarantine"
    mkdir -p "$quarantine" 2>/dev/null || true
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "now")"
    local quar_path="$quarantine/$(basename "$descriptor" .json)-$stamp.sh"
    mv "$tmp" "$quar_path" 2>/dev/null || cp "$tmp" "$quar_path" 2>/dev/null || true
    log_file_error "$quar_path" "remote_install: SHA256 MISMATCH (expected=$sha_lc got=$got_lc) -- REFUSING to execute. Body quarantined for review."
    rm -rf "$tmpdir"
    return 1
  fi

  log_ok "[remote] SHA256 verified -- executing $url"
  # Stream the verified body into bash. We pipe the file rather than
  # `bash <file>` so the upstream installer sees the same `read-from-stdin`
  # invocation pattern as `curl ... | bash`.
  bash <"$tmp"
  local rc=$?
  rm -rf "$tmpdir"
  if [ "$rc" -ne 0 ]; then
    log_file_error "$url" "remote_install: installer exited rc=$rc"
    return "$rc"
  fi
  log_ok "[remote] installer completed (rc=0)"
  return 0
}
