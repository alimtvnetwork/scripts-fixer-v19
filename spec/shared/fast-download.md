# Fast Download Helper (`fast-download`)

**Status:** Active. Added 2026-05.
**Files:**
- `scripts/shared/fast-download.ps1` — Windows
- `scripts-linux/_shared/fast-download.sh` — Linux/macOS
- Dispatcher commands: `run download` / `run url` (both OSes)

## Why

Every model pull, large installer, and bulk asset fetch in this repo should
use a single, fast, resumable downloader. aria2c is the chosen engine
(parallel splits, HTTP/1.1 + HTTP/2, automatic resume, well-supported on
Windows + every major Linux/macOS package manager).

This helper:

1. Installs aria2c on demand (Choco / apt / dnf / pacman / brew).
2. Downloads with `--split=16 -k 1M -x 16` defaults — tunable per call.
3. Falls back to `Invoke-DownloadWithRetry` (Windows) or `curl` → `wget`
   (Linux) when aria2c truly cannot be installed (locked-down CI, etc.).
4. CODE-RED file-error logging on every failure path: every error names
   the exact target path and the exact reason.

Models, profiles, and ad-hoc users all reach aria2c through this one
surface; nothing else should shell out to aria2c directly.

## Defaults

| Knob | Default | CLI flag (dispatcher) | Notes |
|------|---------|-----------------------|-------|
| Splits (`--split`) | `16` | `-s` / `--splits` | Also applied to `-x` (connections per server). |
| Piece size (`-k`) | `1M` | `-p` / `--piece-size` | aria2c minimum is `1M`; smaller values are clamped to `1M`. |
| Continue (`--continue`) | `true` | n/a | Always resumable. |
| Retries | `3` (`--max-tries=3 --retry-wait=5`) | n/a | |
| File allocation | `none` | n/a | Avoids upfront disk pre-allocation stalls. |

## Public API

### PowerShell

```powershell
. scripts/shared/fast-download.ps1

Invoke-FastDownload `
    -Uri        "https://example.com/big.bin" `
    -OutFile    "C:\downloads\big.bin" `
    [-Splits     16] `
    [-PieceSize  "1M"] `
    [-Label      "big.bin"]
# Returns $true on success, $false on failure.
```

### Bash

```bash
. scripts-linux/_shared/fast-download.sh

fast_download <url> [<output_dir>] [<splits>] [<piece_size>]
# Returns 0 on success, non-zero on failure.
```

## Dispatcher contract

Both `./run.ps1` and `./run.sh` expose two synonymous verbs:

```
run download <url> [<dir>] [-s|--splits N] [-p|--piece-size SIZE]
run url      <url> [<dir>] [-s N] [-p SIZE]
```

- `<dir>` defaults to the current working directory.
- `-s` defaults to `16`; `-p` defaults to `1M`.
- The output filename is taken from the URL path component (basename
  before `?`); collisions are resolved by aria2c's resume logic, not by
  rename — set a different `<dir>` if you want a clean copy.

Examples:

```powershell
.\run.ps1 download https://hf.co/foo/model.gguf
.\run.ps1 url      https://hf.co/foo/model.gguf D:\models -s 12 -p 2M
```

```bash
./run.sh download https://hf.co/foo/model.gguf
./run.sh url      https://hf.co/foo/model.gguf /var/models -s 12 -p 2M
```

## Profile wiring

aria2c is bundled with every "fresh box" profile so later steps can rely
on it being present:

- `scripts/profile/config.json` → `minimal` and `terminal` profiles each
  include `{ "kind": "choco", "package": "aria2", "label": "aria2c fast downloader" }`
  inserted right after the Chocolatey step.
- Linux: the helper auto-installs via the detected package manager on
  first use; no separate profile step required.

## Pre-flight (model installs)

`scripts/43-install-llama-cpp/helpers/model-picker.ps1` (and any future
Linux equivalent) call `Invoke-FastDownload` / `fast_download` directly.
The helper guarantees aria2c is available before the first byte is
downloaded; if install fails the call returns `false`/non-zero and the
caller logs a CODE-RED file error before aborting the model pipeline.

`scripts/shared/aria2c-batch.ps1` retains its multi-file batch role for
parallel multi-model pulls. Its per-item fallback path now routes through
`Invoke-FastDownload` too, so single-file retries get the same defaults.

## Error contract (CODE RED)

Every failure path emits:

```
[ERROR] [fast-download] <abs/path/to/file> -- <reason>
```

via `Write-FileError` (Windows) or `log_file_error` (Linux). Reasons
include: `aria2c install failed`, `aria2c exit=N`, `file missing after
download`, `file empty after download`, `cannot create output dir`.

## Progress UI

**Decision (2026-05): keep aria2c's native console summary; do not wrap
in `Write-Progress`.**

Rationale:

- aria2c already prints a compact `[#abcd 1.2GiB/5.0GiB(24%) CN:16
  DL:35MiB ETA:1m48s]` line every 5s (`--summary-interval=5`) showing
  percentage, per-connection throughput, total speed, and ETA. That is
  more information than a single `Write-Progress` bar can carry.
- Parsing aria2c's output to drive `Write-Progress` would require a
  background reader, ANSI-stripping, and per-line state -- adds
  complexity, breaks `--console-log-level=warn`, and loses the
  per-connection breakdown.
- Batch mode (`aria2c-batch.ps1`) already aggregates the same summary
  across N parallel files; a wrapped bar would have to fight that.

If a unified bar is ever required (e.g. for a GUI front-end), parse
aria2c's `--summary-interval` lines from a piped stdout reader rather
than replacing the engine. Until then, native output wins on signal-
to-noise.

## Out of scope

- BitTorrent / IPFS / Magnet sources.
- Cross-host load balancing.
- Per-URL header injection (use raw `aria2c` for that).
- Wrapped progress bar (see "Progress UI" above for rationale).

