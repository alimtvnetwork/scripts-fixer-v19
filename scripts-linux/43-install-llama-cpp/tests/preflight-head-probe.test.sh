#!/usr/bin/env bash
# Smoke-test the pre-batch HEAD preflight in model-pull.sh.
# Uses MODEL_PULL_CATALOG_OVERRIDE + MODEL_PULL_DEFAULT_DIR_OVERRIDE so we
# never touch the real catalog or models dir, and PREFLIGHT_OVERRIDE_CMD so
# we never hit the network. fast_download is stubbed via PATH so any leak
# (the bad entry reaching the downloader) is observable.
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; RST=""; }
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

printf '%s===== model-pull.sh preflight HEAD probe =====%s\n' "$YEL" "$RST"

if ! command -v jq >/dev/null 2>&1; then
  printf '  %sSKIP%s jq not installed\n' "$YEL" "$RST"; exit 0
fi

SANDBOX="$(mktemp -d -t prefl-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Fake catalog: one good + one bad entry.
FAKE_CATALOG="$SANDBOX/models-catalog.json"
cat > "$FAKE_CATALOG" <<'JSON'
{
  "catalogVersion": "test",
  "models": [
    { "id": "good-id", "displayName": "Good entry",
      "fileName": "good.gguf",
      "downloadUrl": "https://example.invalid/good.gguf" },
    { "id": "bad-id",  "displayName": "Bad entry (fictional)",
      "fileName": "bad.gguf",
      "downloadUrl": "https://example.invalid/bad.gguf" }
  ]
}
JSON

PROBE_LOG="$SANDBOX/probe.log"; : > "$PROBE_LOG"
DL_LOG="$SANDBOX/downloader.log"; : > "$DL_LOG"

# Stub fast_download via a wrapper that records any invocation and forces
# the script to use it instead of the real helper.
cat > "$SANDBOX/run.sh" <<RUN
#!/usr/bin/env bash
set -u
preflight_probe() {
  echo "PROBE \$1" >> "$PROBE_LOG"
  case "\$1" in
    *good*) echo 200 ;;
    *bad*)  echo 404 ;;
    *)      echo 0   ;;
  esac
}
fast_download() {
  echo "DL \$*" >> "$DL_LOG"
  return 0
}
export -f preflight_probe fast_download
export PREFLIGHT_OVERRIDE_CMD=preflight_probe
export MODEL_PULL_CATALOG_OVERRIDE="$FAKE_CATALOG"
export MODEL_PULL_DEFAULT_DIR_OVERRIDE="$SANDBOX/out"
# Source the script in the same shell so our exported fast_download wins
# over the one defined by fast-download.sh. The script runs at source time.
. "$SCRIPT_DIR/model-pull.sh" good-id bad-id
echo "EXIT=\$?"
RUN
chmod +x "$SANDBOX/run.sh"

OUT="$(bash "$SANDBOX/run.sh" 2>&1)"
EXIT_LINE="$(printf '%s\n' "$OUT" | grep '^EXIT=' | tail -1)"

# --- Assertions -------------------------------------------------------------
grep -q "PROBE https://example.invalid/good.gguf" "$PROBE_LOG" \
  && pass "preflight probed the good URL" \
  || fail "preflight did not probe the good URL" "$(cat "$PROBE_LOG")"

grep -q "PROBE https://example.invalid/bad.gguf" "$PROBE_LOG" \
  && pass "preflight probed the bad URL" \
  || fail "preflight did not probe the bad URL" "$(cat "$PROBE_LOG")"

printf '%s\n' "$OUT" | grep -q "404 Not Found" \
  && pass "preflight emitted '404 Not Found' for the bad entry" \
  || fail "missing 404 Not Found message" "$OUT"

printf '%s\n' "$OUT" | grep -q "ACTION: remove or correct this entry" \
  && pass "preflight emitted the ACTION hint" \
  || fail "missing ACTION hint" "$OUT"

printf '%s\n' "$OUT" | grep -qE "\[ FAIL \] bad-id" \
  && pass "preflight FAIL line names the bad id" \
  || fail "preflight FAIL line missing the bad id" "$OUT"

# fast_download MUST have been called for good-id (proves preflight allowed it)
# and MUST NOT have been called with the bad URL.
if grep -q "https://example.invalid/good.gguf" "$DL_LOG"; then
  pass "downloader invoked for the good entry"
else
  fail "downloader skipped the good entry" "$(cat "$DL_LOG")"
fi

if grep -q "https://example.invalid/bad.gguf" "$DL_LOG"; then
  fail "downloader was invoked for the bad entry (LEAK)" "$(cat "$DL_LOG")"
else
  pass "downloader did NOT touch the bad entry"
fi

# Exit code must be non-zero when any preflight fails.
if [ "$EXIT_LINE" = "EXIT=0" ]; then
  fail "exit code was 0 despite preflight failure" "$EXIT_LINE"
else
  pass "non-zero exit on preflight failure ($EXIT_LINE)"
fi

printf '%s%s passed, %s failed%s\n' "$YEL" "$PASS" "$FAIL" "$RST"
[ "$FAIL" -eq 0 ]
