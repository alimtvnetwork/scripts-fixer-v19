# chrome-fix-ai (Linux/macOS) — disable Chrome built-in AI and reclaim disk

Linux/macOS port of `scripts/58-install-chrome/helpers/fix-ai.ps1`. Disables
the Optimization-Guide On-Device Model (Gemini Nano) and reclaims the 2–4 GB
it consumes under the user profile.

See the full problem statement and mechanism in
[`spec/chrome-fix-ai/fix-ai.md`](../../spec/chrome-fix-ai/fix-ai.md). This
readme is just the operator-facing quick reference.

## Usage

```bash
# via top-level dispatcher (preferred)
./scripts-linux/run.sh chrome-fix-ai                       # apply (chrome only)
./scripts-linux/run.sh chrome-fix-ai --browser all         # chrome + chromium + brave
./scripts-linux/run.sh chrome-fix-ai --verify              # print state, no changes
./scripts-linux/run.sh chrome-fix-ai --dry-run             # preview only
sudo ./scripts-linux/run.sh chrome-fix-ai                  # include layer-1 system policy
./scripts-linux/run.sh chrome-fix-ai --restore             # undo: remove policy + restore Local State

# direct
bash scripts-linux/chrome-fix-ai/fix-ai.sh --help
```

Aliases routed through `run.sh`: `fix-ai`, `chrome-ai`, `disable-chrome-ai`.

## Three layers (applied together)

| Layer | What                                                     | Requires    |
|-------|----------------------------------------------------------|-------------|
| 1     | System managed-policy JSON / per-user `defaults write`   | root (Linux); per-user only (macOS) |
| 2     | `Local State` JSON patch — preserves every other flag    | `jq` |
| 3     | On-disk model-cache sweep with bytes-freed report        | — |

Layer 1 is skipped gracefully with a warning when not root on Linux.

## Files

- `fix-ai.sh` — entry point, three-layer apply / verify / restore / dry-run
- `config.json` — policy names, flag slots, cache subdirs, per-OS browser paths
  (kept in lockstep with the Windows helper so new GenAI policies/flags land
  once and apply on every OS).

## Safety

- `Local State` patch refuses to run while the target browser is alive unless
  `--yes` is passed (the browser otherwise overwrites the patch on exit).
- Every patch writes a timestamped `Local State.bak-fixai-<ts>` next to the
  file; `--restore` replays the newest backup.
- Cache sweep prints exact bytes freed per root; missing roots are reported
  as "already clean", never as errors.
- Every file/path error logs the exact path + reason (CODE RED).
