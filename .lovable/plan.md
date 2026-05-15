## Goal

Make aria2c the default fast downloader (16 splits × 1M pieces) for all model installs on Windows and Linux, expose it as a shared helper plus a top-level `download` / `url` command on both dispatchers, and make sure aria2c is installed as part of the `minimal` and `terminal` profiles and pre-flight-checked before any model pull.

## Deliverables

### 1. Spec (write first)

`spec/shared/fast-download.md` — single source of truth covering:

- Purpose: one helper, two OSes, identical CLI surface.
- Defaults: `-s/--splits 16`, `-p/--piece-size 1M`, `-x` connections-per-server = same as splits.
- Resolution order: aria2c → curl → wget (Linux) / `Invoke-DownloadWithRetry` (Windows).
- Pre-flight: helper auto-installs aria2c when missing (choco on Windows, apt/dnf/pacman/brew on Linux). Hard-fail with CODE-RED file-error if install impossible.
- Public API:
  - PS: `Invoke-FastDownload -Uri -OutFile [-Splits 16] [-PieceSize 1M] [-Label]`
  - Bash: `fast_download <url> [<output_dir>] [<splits>] [<piece_size>]`
- Dispatcher contract for `download` / `url` subcommand on both `run.ps1` and `scripts-linux/run.sh`:
  ```
  run download <url> [<dir>]  [-s|--splits N] [-p|--piece-size SIZE]
  run url      <url> [<dir>]  [-s N] [-p SIZE]
  ```
  Default dir = current working dir. Default splits = 16. Default piece = 1M.
- Models contract: `scripts/43-install-llama-cpp` (PS) and any future Linux model puller route through `Invoke-FastDownload` / `fast_download`. Existing `Invoke-Aria2BatchDownload` keeps its batch role but its per-file fallback path also goes through the shared helper.
- CODE-RED logging examples and exit codes.

### 2. Memory updates

- New: `.lovable/memory/features/fast-download.md` — describes the shared helper + dispatcher command + profile wiring.
- Update `.lovable/memory/index.md` Memories list with one line pointing to the new file. Keep all existing entries intact.

### 3. Implementation

#### Shared helper — Windows (`scripts/shared/fast-download.ps1`, new)

- Wraps existing `Assert-Aria2c` from `aria2c-download.ps1` then runs aria2c with `-x$Splits -s$Splits -k$PieceSize --file-allocation=none --max-tries=3 --retry-wait=5 --continue=true`.
- Falls back to `Invoke-DownloadWithRetry` only if aria2c install failed.
- Logs install path + bytes via existing `Write-Log` / `Write-FileError`.

#### Shared helper — Linux (`scripts-linux/_shared/fast-download.sh`, new)

- `fast_download(url, dir, splits=16, piece=1M)`.
- Reuses `__ensure_aria2c` from `aria2c-download.sh` for apt; extends it with dnf/pacman/brew detection (uses existing `pkg-detect.sh`).
- Maps piece size to aria2c `--min-split-size` (must be ≥ 1M for aria2c) and uses `-k` for piece size only when valid.
- curl/wget fallback retained.

#### Existing aria2c helpers

- `scripts/shared/aria2c-download.ps1` and `scripts-linux/_shared/aria2c-download.sh`: change defaults to `splits=16`, `piece=1M`, mark them as low-level and have them re-export through the new fast-download helper. No breaking change to public function names.

#### Dispatcher commands

`run.ps1` — add new branch:

```
download | url   →  scripts/shared/fast-download.ps1
                    parses [-s|-Splits] [-p|-PieceSize], positional <url> <dir?>
```

Wired beside the existing `models` / `update` / `path` cases. Help text updated (commands table near line 330 + main help block).

`scripts-linux/run.sh` — add `download)` and `url)` cases in the main `case "${VERB:-help}"` switch (around line 484) that call the new helper.

#### Profile wiring

- `scripts/profile/config.json`: add an early step to `minimal` and `terminal`:
  ```
  { "kind": "choco", "package": "aria2", "label": "aria2c fast downloader" }
  ```
  Inserted right after the Chocolatey step so later steps can use aria2c.
- Linux profiles do not exist yet, so add an `apt_install_packages_quiet aria2` line to the bootstrap path of `scripts-linux/run.sh` install verbs that touch downloads (covered by the helper's auto-install — no change needed beyond that).

#### Pre-model-download guard

- `scripts/43-install-llama-cpp/helpers/model-picker.ps1`: replace direct `Invoke-Aria2Download` call with `Invoke-FastDownload`; the helper guarantees aria2c is present and CODE-REDs out otherwise.
- `scripts/shared/aria2c-batch.ps1`: keep batch logic, but its per-item fallback path now calls `Invoke-FastDownload` instead of `Invoke-DownloadWithRetry`.

### 4. Help / README

- `run.ps1` and `scripts-linux/run.sh` `--help` blocks: add the `download` / `url` row with one-line example.
- Root `readme.md`: append a short subsection under the existing commands table:
  - `./run download <url> [<dir>] [-s 16] [-p 1M]` examples for both OSes.
  - Note: aria2c installed automatically; bundled in `minimal` + `terminal` profiles.

## Verification

- Run `./run.ps1 download https://example.com/file.bin C:\tmp -s 8 -p 2M` → expect aria2c spawned with `-x8 -s8 -k2M`.
- Run `./run.sh download https://example.com/file.bin /tmp` → defaults applied.
- Run `./run.ps1 models qwen2.5-coder-3b` after uninstalling aria2c → expect auto-install then fast download.
- Run `./run.ps1 profile minimal` on a fresh box → aria2c step present, succeeds.

## Out of scope

- Changing the model catalog or per-model URLs.
- BitTorrent/IPFS sources.
- Cross-host load balancing.
---

## Completed (v1.5.25 – v1.5.27)

- ✅ Fix `Count` property crash at `scripts/models/run.ps1:302` (guard non-array results).
- ✅ Replace generic "no match" message with `Catalog has N model(s) -- valid index range is 1..N` in `scripts/models/helpers/picker.ps1`.
- ✅ CODE RED: log upstream URL on every model-download failure path (Windows `model-picker.ps1` + Linux `model-pull.sh`).
- ✅ Linux smoke test for post-download verify retry: `scripts-linux/43-install-llama-cpp/tests/post-download-verify-retry.test.sh` (9/9 PASS).
- ✅ Add `reset` / `fresh` / `wipe-state` command on both dispatchers (Windows + Linux) with `--dry-run`, `--yes`, `--keep-logs`, `--keep-resolved`, `--keep-installed`.

## Pending (carried into next session)

- ⏳ Live smoke (Windows): `.\run.ps1 reset --dry-run` then `.\run.ps1 reset -y`.
- ⏳ Live smoke (Linux): `./scripts-linux/run.sh reset --dry-run` then `./scripts-linux/run.sh reset -y`.
- ⏳ Live smoke: `models-download 93` (range message) and `models-download 5` (real download path).
- ⏳ Mid-download deletion smoke: confirm post-condition retry loop fires + per-attempt `.logs/models-orchestrator.json` flush (Windows + Linux).
- ⏳ Notepad++ taskbar pin triage: waiting for user to paste tail of `.logs/33-install-notepadpp.json` and `.logs/62-pin-taskbar.json` from the failing run.
- ⏳ Carried: `Invoke-Pester scripts\43-install-llama-cpp\tests\` on Windows.
- ⏳ Carried: `os clean` vs `os advance-clean` smoke.
- ⏳ Carried: `.\run.ps1 doctor --self-check`.
