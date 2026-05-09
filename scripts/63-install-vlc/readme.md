# Script 63 -- Install VLC

Installs VLC media player via Chocolatey and repairs file associations.

## Why this script exists

Common Windows error after a VLC reinstall or upgrade:

```
failed to launch player
["C:\Program Files (x86)\VideoLAN\VLC\vlc.exe" --one-instance "Z:\...\Movie.mkv"]
```

Two real root causes:

1. **Stale 32-bit pointer.** Old `Program Files (x86)\VideoLAN\VLC\vlc.exe`
   registry entries linger after Chocolatey installs the 64-bit build into
   `C:\Program Files\VideoLAN\VLC\`. Windows tries to launch the dead path.
2. **`--one-instance` on UNC / mapped paths.** When no VLC instance is
   already running, Windows hands the file argument straight to the dead
   shim with `--one-instance`, which fails on `Z:\...` style network
   paths.

This script does the install and then rewrites every VLC association
key to point at the real on-disk `vlc.exe` with a clean
`"vlc.exe" "%1"` command (no `--one-instance`).

## Commands

| Command | What it does |
|---|---|
| `install` (default) | Choco install vlc + repair associations |
| `repair` | Repair associations only (no install) |
| `reinstall` | Full reinstall -- uninstalls VLC, installs fresh, then repairs associations. Use this when `repair` alone does not fix "failed to launch player". |
| `uninstall` | `choco uninstall vlc` |

## Examples

```powershell
.\run.ps1 install vlc
.\run.ps1 -I 63
.\run.ps1 -I 63 repair
.\run.ps1 -I 63 reinstall
.\run.ps1 -I 63 uninstall
```


## Registry targets rewritten

- `HKCU/HKLM\Software\Classes\Applications\vlc.exe\shell\Open\command`
- `HKCU/HKLM\Software\Classes\VLC.AssocFile.{AVI,MKV,MP3,MP4,WAV,WMV}\shell\Open\command`

Each key is rewritten only if its current value contains
`--one-instance`, points at the 32-bit `Program Files (x86)` path, or
points at a different `vlc.exe` than the resolved one. Otherwise it is
left alone.
