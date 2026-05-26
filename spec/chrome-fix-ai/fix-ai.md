# Chrome `fix-ai` — Linux/macOS port

Mirrors `spec/58-install-chrome/fix-ai.md` for Chrome/Chromium/Brave on Linux
and macOS. The Windows spec is the source of truth for the **what and why**;
this document only records the platform-specific **paths and mechanisms** that
differ from Windows.

## Goal

Provide a single command —

```
./scripts-linux/run.sh chrome-fix-ai
./scripts-linux/run.sh chrome-fix-ai --browser all
```

— that disables Chrome's on-device AI, preserves every other `chrome://flag`
the user already configured, and reclaims the 2–4 GB the model consumes.

## Mechanism

Same three-layer contract as Windows. Only paths and the layer-1 transport
differ.

### Layer 1 — managed policy (system-level when possible)

| OS    | Transport                                              | Path / target                                                       | Requires |
|-------|--------------------------------------------------------|---------------------------------------------------------------------|----------|
| Linux | JSON file in the per-browser `policies/managed/` dir   | `/etc/opt/chrome/policies/managed/lovable-fix-ai.json` (chrome), `/etc/chromium/policies/managed/...` (chromium), `/etc/brave/policies/managed/...` (brave) | root |
| macOS | `defaults write <bundle> <key> -int 1`                 | `~/Library/Preferences/com.google.Chrome.plist` (chrome), `org.chromium.Chromium`, `com.brave.Browser` | per-user (no MDM) |

The macOS *system* equivalent lives under `/Library/Managed Preferences/` and
is owned by MDM — we deliberately do not touch it. Per-user `defaults` is
authoritative for unmanaged Macs and is enough to disable the on-device
model.

If we are not root on Linux, layer 1 is **skipped** with a warning. Layers
2 + 3 still run and are enough on their own to disable the model for the
current user (component-updater on Linux respects the per-user disabled
flags).

### Layer 2 — `Local State` JSON patch

Identical to Windows. Implementation uses `jq` (required) to:

- Read the JSON.
- Drop any prior slot for each of our 5 flags so we don't accumulate dupes.
- Append the 5 flags at slot `2` (Disabled).
- Preserve every other entry in `browser.enabled_labs_experiments`.
- Take a `Local State.bak-fixai-<yyyymmdd-hhmmss>` snapshot first.

Per-OS `Local State` paths:

- Linux: `$HOME/.config/{google-chrome,chromium,BraveSoftware/Brave-Browser}/Local State`
- macOS: `$HOME/Library/Application Support/{Google/Chrome,Chromium,BraveSoftware/Brave-Browser}/Local State`

The patch refuses to run while the browser is alive (`pgrep -x` /
`pgrep -f`) unless `--yes` is passed.

### Layer 3 — cache sweep

Same subdirs as Windows (`OptimizationGuideOnDeviceModel`,
`OptGuideOnDeviceModel`), rooted in the per-browser user-data dir.
Bytes freed is computed via `du -sb` on Linux and `find … -print0 | xargs
stat -f %z` on macOS.

## Verification & restore

| Flag         | Effect                                                                 |
|--------------|------------------------------------------------------------------------|
| `--verify`   | Read-only audit: policy file presence + key count, flags-disabled count, cache size, browser running state — per browser. |
| `--restore`  | Removes the managed-policy file (Linux) / `defaults delete` keys (macOS), then `cp` restores the newest `Local State.bak-fixai-*`. |
| `--dry-run`  | Plans every mutation, performs none. |
| `--yes`      | Bypass the "browser is running" refusal. |

## Constants & paths

All policy names, flag IDs, the disabled slot index, cache subdirs and the
per-OS browser paths live in `scripts-linux/chrome-fix-ai/config.json`. Keep
that file in lockstep with `scripts/58-install-chrome/helpers/fix-ai.ps1`
when Chrome adds or renames GenAI policies.

## CODE RED

Every file/path error MUST log the exact path and the reason — via
`log_file_error "$path" "<reason>"` from `_shared/file-error.sh`. The
Linux/macOS port follows this without exception (mkdir, write, rename, cp,
rm, jq parse, defaults read/write/delete).
