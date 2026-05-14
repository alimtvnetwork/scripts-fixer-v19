#!/usr/bin/env bash
# scripts-linux/_shared/fast-download.sh
# Shared fast-download helper. aria2c-first with 16 splits / 1M pieces.
# Auto-installs aria2c via the detected package manager (apt / dnf /
# pacman / brew). Falls back to curl, then wget.
#
# Source order (caller must source these first):
#   . _shared/logger.sh
#   . _shared/file-error.sh   (for log_file_error; falls back to log_err)
#   . _shared/pkg-detect.sh
#   . _shared/apt-install.sh
#
# Spec: spec/shared/fast-download.md

FAST_DL_DEFAULT_SPLITS=16
FAST_DL_DEFAULT_PIECE="1M"

__fd_log_path_error() {
  local path="$1"
  local reason="$2"
  if command -v log_file_error >/dev/null 2>&1; then
    log_file_error "$path" "$reason"
  else
    log_err "[fast-download] $path -- $reason"
  fi
}

__fd_clamp_piece() {
  # aria2c minimum is 1M. Accept "1M", "2M", "512K", "1G".
  local raw="${1:-$FAST_DL_DEFAULT_PIECE}"
  local up; up=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')
  case "$up" in
    *M)
      local n="${up%M}"
      if ! printf '%s' "$n" | grep -qE '^[0-9]+$'; then echo "1M"; return; fi
      [ "$n" -lt 1 ] && n=1
      printf '%dM' "$n"
      ;;
    *G)
      local n="${up%G}"
      if ! printf '%s' "$n" | grep -qE '^[0-9]+$'; then echo "1M"; return; fi
      printf '%dG' "$n"
      ;;
    *K)
      log_warn "[fast-download] piece size '$raw' below aria2c minimum, clamped to 1M"
      echo "1M"
      ;;
    *)
      log_warn "[fast-download] unrecognised piece size '$raw', using 1M"
      echo "1M"
      ;;
  esac
}

__fd_ensure_aria2c() {
  command -v aria2c >/dev/null 2>&1 && return 0

  log_info "[fast-download] aria2c not found -- installing"

  if command -v apt-get >/dev/null 2>&1; then
    if command -v apt_install_packages_quiet >/dev/null 2>&1; then
      apt_install_packages_quiet aria2 || true
    else
      sudo apt-get update -qq && sudo apt-get install -y aria2 || true
    fi
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y aria2 || true
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y aria2 || true
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm aria2 || true
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y aria2 || true
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache aria2 || true
  elif command -v brew >/dev/null 2>&1; then
    brew install aria2 || true
  else
    log_warn "[fast-download] no supported package manager detected for aria2c"
  fi

  command -v aria2c >/dev/null 2>&1
}

# Public: fast_download <url> [<output_dir>] [<splits>] [<piece_size>]
# Returns 0 on success, non-zero on failure.
fast_download() {
  local url="$1"
  local out_dir="${2:-.}"
  local splits="${3:-$FAST_DL_DEFAULT_SPLITS}"
  local piece; piece=$(__fd_clamp_piece "${4:-$FAST_DL_DEFAULT_PIECE}")

  if [ -z "$url" ]; then
    log_err "fast_download: <url> is required"
    return 2
  fi
  if ! mkdir -p "$out_dir" 2>/dev/null; then
    __fd_log_path_error "$out_dir" "cannot create output directory"
    return 1
  fi

  # Strip query string when deriving the basename.
  local fname; fname=$(basename "${url%%\?*}")
  local target="$out_dir/$fname"

  log_info "[fast-download] $url -> $target (splits=$splits piece=$piece)"

  if __fd_ensure_aria2c; then
    if aria2c \
        -x "$splits" -s "$splits" \
        -k "$piece" --min-split-size="$piece" \
        --file-allocation=none \
        --max-tries=3 --retry-wait=5 --timeout=60 \
        --continue=true --auto-file-renaming=false \
        --console-log-level=warn --summary-interval=5 \
        -d "$out_dir" -o "$fname" "$url"; then
      if [ -s "$target" ]; then
        log_ok "[fast-download] OK aria2c -> $target"
        return 0
      fi
      __fd_log_path_error "$target" "aria2c reported success but file empty/missing"
    else
      log_warn "[fast-download] aria2c failed -- falling back to curl/wget"
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --retry 3 -o "$target" "$url"; then
      [ -s "$target" ] && { log_ok "[fast-download] OK curl -> $target"; return 0; }
      __fd_log_path_error "$target" "curl reported success but file empty"
    else
      log_warn "[fast-download] curl failed -- trying wget"
    fi
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget -q --tries=3 -O "$target" "$url"; then
      [ -s "$target" ] && { log_ok "[fast-download] OK wget -> $target"; return 0; }
      __fd_log_path_error "$target" "wget reported success but file empty"
    fi
  fi

  __fd_log_path_error "$target" "all downloaders failed for $url"
  return 1
}
