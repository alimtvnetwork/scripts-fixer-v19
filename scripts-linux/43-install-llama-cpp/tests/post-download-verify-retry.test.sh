#!/usr/bin/env bash
# Smoke-test the post-download verify + retry loop in model-pull.sh.
#
# Stubs fast_download to always exit 0 WITHOUT writing the target file.
# Expectation:
#   * the [RETRY n/N] line fires for attempts 2..N
#   * the [POST-CHECK FAIL] line names the missing target path + size=0
#   * fast_download is called exactly N times for the single entry
#   * model-pull exits non-zero (fail counter > 0)
#
# A second scenario stubs fast_download to write the file on attempt #2
# and asserts the loop stops cleanly with fail=0.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; RST=""; }
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

printf '%s===== model-pull.sh post-download verify + retry =====%s\n' "$YEL" "$RST"

if ! command -v jq >/dev/null 2>&1; then
  printf '  %sSKIP%s jq not installed\n' "$YEL" "$RST"; exit 0
fi

SANDBOX="$(mktemp -d -t postdl-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

FAKE_CATALOG="$SANDBOX/models-catalog.json"
cat > "$FAKE_CATALOG" <<'JSON'
{
  "catalogVersion": "test",
  "models": [
    { "id": "ghost-id", "displayName": "Ghost (downloader lies about success)",
      "fileName": "ghost.gguf",
      "downloadUrl": "https://example.invalid/ghost.gguf" }
  ]
}
JSON

# ---- Scenario 1: downloader ALWAYS lies (rc=0, no file) -----------------
DL_LOG="$SANDBOX/scenario1-dl.log"; : > "$DL_LOG"
OUT_DIR_1="$SANDBOX/out1"; mkdir -p "$OUT_DIR_1"

cat > "$SANDBOX/run1.sh" <<RUN
#!/usr/bin/env bash
set -u
preflight_probe() { echo 200; }
fast_download() {
  echo "DL \$*" >> "$DL_LOG"
  return 0  # lie: success but write nothing
}
export -f preflight_probe fast_download
export PREFLIGHT_OVERRIDE_CMD=preflight_probe
export MODEL_PULL_CATALOG_OVERRIDE="$FAKE_CATALOG"
export MODEL_PULL_DEFAULT_DIR_OVERRIDE="$OUT_DIR_1"
export MODEL_PULL_SKIP_FASTDL_SOURCE=1
export MODELS_MAX_FILE_RETRIES=3
bash "$SCRIPT_DIR/model-pull.sh" ghost-id
echo "EXIT=\$?"
RUN
chmod +x "$SANDBOX/run1.sh"

OUT1="$(bash "$SANDBOX/run1.sh" 2>&1)"
EXIT1="$(printf '%s\n' "$OUT1" | grep '^EXIT=' | tail -1)"
DL_CALLS_1="$(wc -l < "$DL_LOG" | tr -d '[:space:]')"

# Scenario 1 assertions
if [ "$DL_CALLS_1" -eq 3 ]; then
  pass "downloader was invoked exactly MODELS_MAX_FILE_RETRIES=3 times"
else
  fail "expected 3 downloader calls, got $DL_CALLS_1" "$(cat "$DL_LOG")"
fi

printf '%s\n' "$OUT1" | grep -q "\[RETRY 2/3\]" \
  && pass "[RETRY 2/3] line fired" \
  || fail "[RETRY 2/3] line missing" "$OUT1"

printf '%s\n' "$OUT1" | grep -q "\[RETRY 3/3\]" \
  && pass "[RETRY 3/3] line fired" \
  || fail "[RETRY 3/3] line missing" "$OUT1"

printf '%s\n' "$OUT1" | grep -q "\[POST-CHECK FAIL\]" \
  && pass "[POST-CHECK FAIL] message emitted" \
  || fail "[POST-CHECK FAIL] missing" "$OUT1"

printf '%s\n' "$OUT1" | grep -q "ghost.gguf" \
  && pass "post-check named the missing target file" \
  || fail "post-check did not name ghost.gguf" "$OUT1"

if [ "$EXIT1" = "EXIT=0" ]; then
  fail "scenario 1: exit was 0 despite never landing the file" "$EXIT1"
else
  pass "scenario 1: non-zero exit when retries exhausted ($EXIT1)"
fi

# ---- Scenario 2: downloader succeeds for real on attempt #2 -------------
DL_LOG2="$SANDBOX/scenario2-dl.log"; : > "$DL_LOG2"
OUT_DIR_2="$SANDBOX/out2"; mkdir -p "$OUT_DIR_2"
ATTEMPT_FILE="$SANDBOX/attempt2.count"; echo 0 > "$ATTEMPT_FILE"

cat > "$SANDBOX/run2.sh" <<RUN
#!/usr/bin/env bash
set -u
preflight_probe() { echo 200; }
fast_download() {
  local n; n=\$(cat "$ATTEMPT_FILE")
  n=\$((n+1)); echo "\$n" > "$ATTEMPT_FILE"
  echo "DL attempt=\$n \$*" >> "$DL_LOG2"
  if [ "\$n" -ge 2 ]; then
    # \$1 = url, \$2 = out_dir; final path is \$2/<fileName from catalog>
    echo "real bytes" > "$OUT_DIR_2/ghost.gguf"
  fi
  return 0
}
export -f preflight_probe fast_download
export PREFLIGHT_OVERRIDE_CMD=preflight_probe
export MODEL_PULL_CATALOG_OVERRIDE="$FAKE_CATALOG"
export MODEL_PULL_DEFAULT_DIR_OVERRIDE="$OUT_DIR_2"
export MODEL_PULL_SKIP_FASTDL_SOURCE=1
export MODELS_MAX_FILE_RETRIES=5
bash "$SCRIPT_DIR/model-pull.sh" ghost-id
echo "EXIT=\$?"
RUN
chmod +x "$SANDBOX/run2.sh"

OUT2="$(bash "$SANDBOX/run2.sh" 2>&1)"
EXIT2="$(printf '%s\n' "$OUT2" | grep '^EXIT=' | tail -1)"
DL_CALLS_2="$(wc -l < "$DL_LOG2" | tr -d '[:space:]')"

if [ "$DL_CALLS_2" -eq 2 ]; then
  pass "scenario 2: downloader stopped after success on attempt #2"
else
  fail "scenario 2: expected 2 downloader calls, got $DL_CALLS_2" "$(cat "$DL_LOG2")"
fi

if [ -s "$OUT_DIR_2/ghost.gguf" ]; then
  pass "scenario 2: target file landed on disk"
else
  fail "scenario 2: target file missing in $OUT_DIR_2"
fi

if [ "$EXIT2" = "EXIT=0" ]; then
  pass "scenario 2: exit=0 when retry eventually succeeds"
else
  fail "scenario 2: expected EXIT=0, got $EXIT2" "$OUT2"
fi

printf '%s%s passed, %s failed%s\n' "$YEL" "$PASS" "$FAIL" "$RST"
[ "$FAIL" -eq 0 ]
