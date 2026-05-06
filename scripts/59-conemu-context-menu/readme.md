<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Script 59 — ConEmu Context Menu" width="128" height="128"/>

# Script 59 — ConEmu Context Menu

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Script](https://img.shields.io/badge/Script-59-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)

*Mandatory spec header — see [spec/00-spec-writing-guide](../../spec/00-spec-writing-guide/readme.md).*

</div>

---

## Overview

Adds **"Open ConEmu Here"** (normal + admin) to the Windows right-click menu
for folders **and** folder backgrounds. Mirrors script 31 (PowerShell Here)
verb-for-verb so both behave identically.

## Quick start

```powershell
# From repo root
.\run.ps1 -I 59                      # install + verify
.\run.ps1 -I 59 -Help                # help
.\run.ps1 -I 59 uninstall            # remove all 4 registry entries

# Via install keywords
.\run.ps1 install conemu             # ConEmu + settings + context menu
.\run.ps1 install conemu-menu        # same as above (alias)
.\run.ps1 install conemu-context-menu # ensure ConEmu installed, then wire menu
.\run.ps1 install all-settings       # batch incl. ConEmu menu

# Bundle (script 57 -- runs all context-menu scripts in one pass)
.\run.ps1 -I 57 install
```

## Registry targets

| Mode | Folder | Folder background |
|------|--------|-------------------|
| Normal | `HKCR\Directory\shell\ConEmuHere` | `HKCR\Directory\Background\shell\ConEmuHere` |
| Admin  | `HKCR\Directory\shell\ConEmuHereAdmin` | `HKCR\Directory\Background\shell\ConEmuHereAdmin` |

The admin variants set `HasLUAShield` so Explorer shows the UAC shield icon
and triggers an elevation prompt on click. The command line is:

```
"<ConEmu64.exe>" -Dir "%V"
```

## ConEmu detection order

1. `ConEmu64` on PATH
2. `C:\Program Files\ConEmu\ConEmu64.exe`
3. `C:\Program Files (x86)\ConEmu\ConEmu64.exe`
4. `%ProgramData%\chocolatey\bin\ConEmu64.exe` (shim)
5. `%LOCALAPPDATA%\ConEmu\ConEmu64.exe`
6. `%ProgramData%\chocolatey\lib\conemu\tools\ConEmuPack\ConEmu64.exe`
7. 32-bit `ConEmu.exe` fallback in the same locations

If none is found, the script logs an error and exits without touching the
registry. Run `install conemu` first.

## Layout

| File | Purpose |
|------|---------|
| `run.ps1` | Entry point dispatched by the root `run.ps1`. |
| `config.json` | Registry paths, command templates, ConEmu locations. |
| `log-messages.json` | All user-facing messages. |
| `helpers/conemu-menu.ps1` | Detect + register + verify + uninstall. |

## See also

- [Script 31 -- PowerShell Here](../31-pwsh-context-menu/readme.md)
- [Script 48 -- Install ConEmu](../48-install-conemu/readme.md)
- [Script 57 -- Context Menu Bundle](../57-context-menu-bundle/readme.md)
- [Changelog](../../changelog.md)
