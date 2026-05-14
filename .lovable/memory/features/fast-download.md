---
name: Fast download helper
description: scripts/shared/fast-download.ps1 + scripts-linux/_shared/fast-download.sh + run download|url dispatcher command. Defaults splits=16, piece=1M. aria2c bundled in minimal+terminal profiles. Used by all model pulls.
type: feature
---

# Fast Download Helper

## Purpose

Single shared entry point for ALL big-file downloads (models, installers,
assets). Wraps aria2c with sane defaults, auto-installs aria2c when
missing, falls back to curl/wget/Invoke-DownloadWithRetry only as a last
resort.

## Files

| Path | Role |
|------|------|
| `scripts/shared/fast-download.ps1` | Windows helper (`Invoke-FastDownload`) |
| `scripts-linux/_shared/fast-download.sh` | Linux/macOS helper (`fast_download`) |
| `spec/shared/fast-download.md` | Full spec |

## Defaults

- `--split` / `-x` = **16**
- `-k` (piece size) = **1M** (clamped — aria2c minimum)
- `--continue=true`, `--max-tries=3`, `--retry-wait=5`, `--file-allocation=none`

## Dispatcher

Both `./run.ps1` and `./run.sh` expose:

```
run download <url> [<dir>] [-s|--splits N] [-p|--piece-size SIZE]
run url      ...    (alias)
```

`<dir>` defaults to CWD. `-s 16`, `-p 1M`.

## Profile wiring

`minimal` and `terminal` profiles in `scripts/profile/config.json`
include `{ "kind": "choco", "package": "aria2" }` right after the
Chocolatey step. Linux relies on the helper's per-PM auto-install.

## Model pulls

`scripts/43-install-llama-cpp/helpers/model-picker.ps1` calls
`Invoke-FastDownload` per file. `scripts/shared/aria2c-batch.ps1` keeps
its batch role; per-item fallback now routes through fast-download too.

## CODE RED

Every failure logs the exact target path + reason via `Write-FileError`
or `log_file_error`. Helper returns `$false` / non-zero — never throws.
