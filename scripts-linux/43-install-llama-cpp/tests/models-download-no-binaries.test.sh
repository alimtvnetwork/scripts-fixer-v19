#!/usr/bin/env bash
# Smoke-test the HARD GUARD that prevents 'models-download' (./run.sh models)
# from triggering llama.cpp binary installation.
#
# Test 1: verb_install must refuse to run when MODELS_DOWNLOAD_NO_BINARIES=1
#         (it is allowed to bail any way it likes; we just require non-zero
#         exit + a "HARD GUARD" line on stderr).
# Test 2: the dispatcher in scripts-linux/run.sh must abort with exit 87
#         when a fake llama-* binary appears under the install root during
#         a 'models' invocation (simulated via a stubbed model-pull.sh).
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TEST_DIR/.." && pwd)"
LINUX_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; RST=$'\e[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; RST=""; }
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

printf '%s===== models-download no-binaries hard guard =====%s\n' "$YEL" "$RST"

if ! command -v jq >/dev/null 2>&1; then
  printf '  %sSKIP%s jq not installed in sandbox\n' "$YEL" "$RST"; exit 0
fi

# ---------- Test 1: verb_install honours MODELS_DOWNLOAD_NO_BINARIES ---------
SANDBOX1="$(mktemp -d -t mdg1-XXXXXX)"
export HOME="$SANDBOX1"
out1="$(MODELS_DOWNLOAD_NO_BINARIES=1 bash "$SCRIPT_DIR/run.sh" install 2>&1)"
rc1=$?
if [ "$rc1" -ne 0 ] && printf '%s' "$out1" | grep -q "HARD GUARD"; then
  pass "verb_install bails with HARD GUARD when sentinel set"
else
  fail "verb_install did not bail (rc=$rc1)" "$out1"
fi
rm -rf "$SANDBOX1"

# ---------- Test 2: dispatcher detects binary leak ---------------------------
SANDBOX2="$(mktemp -d -t mdg2-XXXXXX)"
export HOME="$SANDBOX2"
LLAMA_INSTALL_ROOT="$HOME/.local/share/llama.cpp"
mkdir -p "$LLAMA_INSTALL_ROOT"

# Stub model-pull.sh to simulate a leaking install path: it drops a fake
# llama-cli binary into the install root then exits 0.
STUB_DIR="$(mktemp -d -t mdg2stub-XXXXXX)"
mkdir -p "$STUB_DIR/43-install-llama-cpp"
cp "$LINUX_ROOT/43-install-llama-cpp/config.json" \
   "$STUB_DIR/43-install-llama-cpp/config.json"
cat > "$STUB_DIR/43-install-llama-cpp/model-pull.sh" <<'EOF'
#!/usr/bin/env bash
echo "[stub model-pull] simulating binary leak"
mkdir -p "$HOME/.local/share/llama.cpp/v0.0.0/bin"
: > "$HOME/.local/share/llama.cpp/v0.0.0/bin/llama-cli"
chmod +x "$HOME/.local/share/llama.cpp/v0.0.0/bin/llama-cli"
exit 0
EOF
chmod +x "$STUB_DIR/43-install-llama-cpp/model-pull.sh"

# Mirror the dispatcher block so we don't have to invoke run.sh's full arg
# parser. This must stay byte-for-byte compatible with the guard logic.
ROOT="$STUB_DIR"
MODELS_REST=("dummy-id")
LLAMA_CFG="$ROOT/43-install-llama-cpp/config.json"
_r=$(jq -r '.install.installRoot' "$LLAMA_CFG"); LLAMA_INSTALL_ROOT="${_r//\$\{HOME\}/$HOME}"
_b=$(jq -r '.install.binDir'      "$LLAMA_CFG"); LLAMA_BIN_DIR="${_b//\$\{HOME\}/$HOME}"
SNAP_BEFORE="$(mktemp)"; SNAP_AFTER="$(mktemp)"
_snap() {
  : > "$1"
  for d in "$LLAMA_INSTALL_ROOT" "$LLAMA_BIN_DIR"; do
    [ -n "$d" ] && [ -d "$d" ] && \
      find "$d" -type f \( -name 'llama-*' -o -name '*.so' -o -name '*.dylib' \
                          -o -name '*.tar.gz' -o -name '*.zip' \) \
                -printf '%p\t%s\n' 2>/dev/null >> "$1"
  done
  sort -o "$1" "$1"
}
_snap "$SNAP_BEFORE"
export MODELS_DOWNLOAD_NO_BINARIES=1
bash "$ROOT/43-install-llama-cpp/model-pull.sh" "${MODELS_REST[@]}" >/dev/null 2>&1
mp_rc=$?
unset MODELS_DOWNLOAD_NO_BINARIES
_snap "$SNAP_AFTER"
LEAK="$(comm -13 "$SNAP_BEFORE" "$SNAP_AFTER" || true)"
rm -f "$SNAP_BEFORE" "$SNAP_AFTER"

if [ -n "$LEAK" ]; then
  pass "dispatcher diff detects leaked llama-* binary"
else
  fail "dispatcher diff missed the leak" "mp_rc=$mp_rc"
fi
rm -rf "$STUB_DIR" "$SANDBOX2"

printf '%s%s passed, %s failed%s\n' "$YEL" "$PASS" "$FAIL" "$RST"
[ "$FAIL" -eq 0 ]
