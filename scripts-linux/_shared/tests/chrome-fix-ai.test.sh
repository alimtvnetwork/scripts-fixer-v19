#!/usr/bin/env bash
# Tests for scripts-linux/chrome-fix-ai/fix-ai.sh.
# Pure-sandbox: $HOME is redirected to a mktemp dir; no real browser data,
# no system paths, no network. Requires `jq`.
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SHARED_DIR/../.." && pwd)"
FIXAI="$REPO_ROOT/scripts-linux/chrome-fix-ai/fix-ai.sh"
CFG="$REPO_ROOT/scripts-linux/chrome-fix-ai/config.json"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; RST=""; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"
         printf '       expected: %s\n       got:      %s\n' "$2" "$3"; }
assert_eq()       { [ "$1" = "$2" ] && pass "$3" || fail "$3" "$1" "$2"; }
assert_contains() { case "$2" in *"$1"*) pass "$3";; *) fail "$3" "contains: $1" "$2";; esac; }
assert_file()     { [ -f "$1" ] && pass "$2" || fail "$2" "file exists: $1" "missing"; }

printf '%s===== chrome-fix-ai =====%s\n' "$YEL" "$RST"

[ -f "$FIXAI" ] || { printf '  %sSKIP%s fix-ai.sh missing at %s\n' "$YEL" "$RST" "$FIXAI"; exit 0; }
[ -f "$CFG"   ] || { printf '  %sSKIP%s config.json missing at %s\n' "$YEL" "$RST" "$CFG"; exit 0; }
command -v jq >/dev/null 2>&1 || {
  printf '  %sSKIP%s jq not installed in sandbox\n' "$YEL" "$RST"; exit 0; }

# Schema sanity: required arrays non-empty.
N_POL=$(jq '.policyNames  | length' "$CFG")
N_FLG=$(jq '.flagNames    | length' "$CFG")
N_CAC=$(jq '.cacheSubdirs | length' "$CFG")
[ "$N_POL" -gt 0 ] && pass "config.json policyNames non-empty ($N_POL)"  || fail "policyNames"  ">0" "$N_POL"
[ "$N_FLG" -gt 0 ] && pass "config.json flagNames non-empty ($N_FLG)"    || fail "flagNames"    ">0" "$N_FLG"
[ "$N_CAC" -gt 0 ] && pass "config.json cacheSubdirs non-empty ($N_CAC)" || fail "cacheSubdirs" ">0" "$N_CAC"

# Lockstep check: every policy/flag in the Linux config must exist in the
# Windows source-of-truth helper. Drift means a quarterly Chrome update
# landed on one OS but not the other.
WIN_HELPER="$REPO_ROOT/scripts/58-install-chrome/helpers/fix-ai.ps1"
if [ -f "$WIN_HELPER" ]; then
  miss=0
  while IFS= read -r p; do
    grep -q "\"$p\"" "$WIN_HELPER" || { miss=$((miss+1)); printf '       missing in win helper: %s\n' "$p"; }
  done < <(jq -r '.policyNames[]' "$CFG")
  [ "$miss" = 0 ] && pass "policyNames lockstep with Windows fix-ai.ps1" \
                  || fail "policyNames lockstep with Windows" "0 missing" "$miss missing"
  miss=0
  while IFS= read -r f; do
    grep -q "\"$f\"" "$WIN_HELPER" || { miss=$((miss+1)); printf '       missing in win helper: %s\n' "$f"; }
  done < <(jq -r '.flagNames[]' "$CFG")
  [ "$miss" = 0 ] && pass "flagNames lockstep with Windows fix-ai.ps1" \
                  || fail "flagNames lockstep with Windows" "0 missing" "$miss missing"
else
  printf '  %sSKIP%s Windows helper missing -- cannot check lockstep\n' "$YEL" "$RST"
fi

# Sandbox HOME so every patch lands under mktemp.
SANDBOX="$(mktemp -d -t fixai-XXXXXX)"
export HOME="$SANDBOX"
UD="$SANDBOX/.config/google-chrome"
mkdir -p "$UD"
LS="$UD/Local State"

# Seed Local State with an unrelated flag we must preserve.
cat > "$LS" <<'JSON'
{"browser":{"enabled_labs_experiments":["unrelated-flag@1","prompt-api-for-gemini-nano@0"]}}
JSON

# --- 1. --help exits 0 and mentions the three layers ------------------------
HELP_OUT="$(bash "$FIXAI" --help 2>&1)"
assert_contains "managed-policy" "$HELP_OUT" "--help mentions layer 1"
assert_contains "Local State"    "$HELP_OUT" "--help mentions layer 2"
assert_contains "cache"          "$HELP_OUT" "--help mentions layer 3"

# --- 2. --dry-run does NOT mutate Local State -------------------------------
BEFORE="$(cat "$LS")"
bash "$FIXAI" --browser chrome --dry-run >/dev/null 2>&1
AFTER="$(cat "$LS")"
assert_eq "$BEFORE" "$AFTER" "--dry-run leaves Local State untouched"

# --- 3. Apply: preserves other flags, dedups stale slot, adds 5 disabled ---
bash "$FIXAI" --browser chrome --yes >/dev/null 2>&1
ENTRIES="$(jq -c '.browser.enabled_labs_experiments' "$LS")"
assert_contains '"unrelated-flag@1"'                    "$ENTRIES" "apply: preserves unrelated-flag"
assert_contains '"prompt-api-for-gemini-nano@2"'        "$ENTRIES" "apply: adds prompt-api at slot 2"
assert_contains '"optimization-guide-on-device-model@2"' "$ENTRIES" "apply: adds optimization-guide at slot 2"
# Stale @0 must be dropped (we dedupe by flag name before appending @2).
case "$ENTRIES" in
  *prompt-api-for-gemini-nano@0*) fail "apply: drops stale @0 slot" "no @0" "still present" ;;
  *)                              pass "apply: drops stale @0 slot" ;;
esac

# Backup file written with config-driven suffix.
SUFFIX="$(jq -r '.backupSuffix // "bak-fixai"' "$CFG")"
BAK_COUNT=$(ls -1 "$UD"/Local\ State."$SUFFIX"-* 2>/dev/null | wc -l)
[ "$BAK_COUNT" -ge 1 ] && pass "apply: backup file written (.${SUFFIX}-<ts>)" \
                       || fail "apply: backup file written" ">=1" "$BAK_COUNT"

# --- 4. Verify: 5/5 flags disabled, exit 0 ----------------------------------
VER_OUT="$(bash "$FIXAI" --browser chrome --verify 2>&1)"
assert_contains "Flags disabled     : 5/5" "$VER_OUT" "verify: reports 5/5 flags disabled"

# --- 5. Restore: round-trips to original ------------------------------------
bash "$FIXAI" --browser chrome --restore >/dev/null 2>&1
AFTER_RESTORE="$(cat "$LS")"
assert_eq "$BEFORE" "$AFTER_RESTORE" "--restore round-trips Local State exactly"

# --- 6. Unknown --browser exits non-zero with clear error -------------------
ERR_OUT="$(bash "$FIXAI" --browser firefox 2>&1)" || true
assert_contains "unknown --browser" "$ERR_OUT" "rejects unknown --browser"

# --- cleanup ----------------------------------------------------------------
rm -rf "$SANDBOX"

printf '\n%s===== chrome-fix-ai: %d pass, %d fail =====%s\n' \
  "$(if [ "$FAIL" = 0 ]; then printf '%s' "$GRN"; else printf '%s' "$RED"; fi)" \
  "$PASS" "$FAIL" "$RST"
[ "$FAIL" = 0 ] && exit 0 || exit 1
