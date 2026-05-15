---
name: Reset command (fresh-start wipe)
description: `reset` verb on Windows + Linux dispatchers wipes .logs/, .resolved/, .installed/ for a clean slate
type: feature
---

# Reset command — fresh-start wipe

Added in v1.5.27. Lets the user clear all per-run state from the repo root so the next install behaves like a first run.

## CLI surface

- Windows: `.\run.ps1 reset [--dry-run] [-y|--yes] [--keep-logs] [--keep-resolved] [--keep-installed]`
- Linux:   `./scripts-linux/run.sh reset [--dry-run] [--yes] [--keep-logs] [--keep-resolved] [--keep-installed]`

Aliases on Windows root only: `fresh`, `fresh-start`, `wipe-state`, `clear-state`.

## What it deletes

From repo root (PROJECT_ROOT on Linux = parent of `scripts-linux/`):
- `.logs/`        (unless `--keep-logs`)
- `.resolved/`    (unless `--keep-resolved`)
- `.installed/`   (unless `--keep-installed`)

Never touches `node_modules`, `dist`, git state, or user docs.

## Implementation

- `run.ps1` lines ~3680–3737: `$isBareResetCommand` detection + dispatch handler. Added to completion pool and help table.
- `scripts-linux/run.sh` lines ~168, 657–742: `reset)` case in the main verb switch, with PROJECT_ROOT calculated from `$ROOT/..`. Help text updated.

## Behaviour rules

- `--dry-run` prints the `[WOULD DELETE] <path>` lines but exits without removing anything.
- Without `-y/--yes` an interactive confirm is required; non-TTY runs without `--yes` abort.
- All file removal uses Write-FileError / log_file_error on failure (CODE RED contract).
