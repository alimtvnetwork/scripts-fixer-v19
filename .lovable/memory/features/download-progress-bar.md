---
name: Download progress bar
description: scripts/shared/progress-bar.ps1 renders an ASCII-only colour-graduated in-place download bar. Wired into Invoke-FastDownload. Suppresses aria2c native summary blocks. ASCII-only per terminal-banners constraint (no emoji, no wide Unicode).
type: feature
---

# Download progress bar

Reusable helper at `scripts/shared/progress-bar.ps1`.

## Glyphs (ASCII only)

- Bar body: `=` filled, `>` moving head, ` ` empty, `|` bookends.
- Phase tags: `[WAIT ]`, `[ DL  ]`, `[ >>> ]`, `[DONE]`.
- Metadata prefixes: `spd`, `eta`, `up` (elapsed).
- Colour graduation: Red < 25% < Yellow < 50% < Cyan < 75% < Green.

Emoji and Unicode blocks were removed in v0.227.0 because legacy
conhost / non-UTF-8 sessions rendered them as `?`.

## Public functions

- `Write-DownloadProgressBar -Percent <int> [-Sizes -Speed -Eta -Label -Width]`
- `Complete-DownloadProgressBar` -- newline + state reset.
- `Invoke-Aria2WithProgressBar -Arguments <string[]> -Label <string>`
  - Parses aria2c summary `[#gid X/Y(N%) ... DL:S ETA:E]` lines.
  - Suppresses `*** Download Progress Summary ***`, dividers, `FILE:`.

## Caller wiring

`scripts/shared/fast-download.ps1` `Invoke-FastDownload` adds
`--console-log-level=error --show-console-readout=false --summary-interval=1`
and dispatches to `Invoke-Aria2WithProgressBar`. Every consumer
(`run download`, `install model <id>`, model picker, ollama registry
pull, batch fallback) gets the bar for free.

## already-downloaded skip

`Invoke-FastDownload` short-circuits when the target file exists,
is non-empty, and has no `.aria2` control file -- logs
`already-downloaded: <label> (<MB> MB) -- skipping. Path: <abs>` at
`success` level and returns `$true` without spawning aria2c.
