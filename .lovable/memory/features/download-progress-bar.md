---
name: Download progress bar
description: scripts/shared/progress-bar.ps1 renders a winget-style colourful in-place download bar. Wired into Invoke-FastDownload (and therefore every model pull / `run download`). Suppresses aria2c's native summary blocks.
type: feature
---

# Download progress bar

Reusable helper at `scripts/shared/progress-bar.ps1`.

## Public functions

- `Write-DownloadProgressBar -Percent <int> [-Sizes -Speed -Eta -Label -Width]`
  - In-place CR-repaint bar. Colour graduates Red < 25% < Yellow < 50% <
    Cyan < 75% < Green. ASCII-only glyphs (`#` / `-`) per
    `mem://constraints/terminal-banners`.
- `Complete-DownloadProgressBar` -- newline + state reset.
- `Invoke-Aria2WithProgressBar -Arguments <string[]> -Label <string>`
  - Runs `aria2c.exe` via call-operator pipeline, parses its summary
    `[#gid X/Y(N%) ... DL:S ETA:E]` line, drives the bar, suppresses the
    `*** Download Progress Summary ***` banner / dividers / `FILE:` lines.
  - Returns aria2c exit code (or `-1` on spawn failure).

## Caller wiring

`scripts/shared/fast-download.ps1` `Invoke-FastDownload` builds aria2c
args with `--console-log-level=error --show-console-readout=false
--summary-interval=1` and dispatches to `Invoke-Aria2WithProgressBar`.

Every consumer of `Invoke-FastDownload` (`run download`, model picker
in `scripts/43-install-llama-cpp/helpers/model-picker.ps1`, batch
fallback in `scripts/shared/aria2c-batch.ps1`) automatically gets the
new bar -- no per-caller change required.
