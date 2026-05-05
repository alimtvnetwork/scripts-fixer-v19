# 58 - Install Google Chrome

Installs Google Chrome via Chocolatey (`googlechrome`), with automatic fallback to
the official ChromeStandaloneSetup64.exe download when Chocolatey fails or the
post-install verify cannot find `chrome.exe`.

## Run

```powershell
# direct
.\scripts\58-install-chrome\run.ps1

# via dispatcher
.\run.ps1 -I 58
.\run.ps1 install chrome
.\run.ps1 install google-chrome

# uninstall
.\run.ps1 -I 58 uninstall
```

## What it does

1. Looks for `chrome.exe` in standard install locations (Program Files / Program Files (x86) / LocalAppData)
2. If found and tracked -> reports already installed
3. Otherwise runs `choco install googlechrome -y`
4. Verifies `chrome.exe` exists post-install
5. On any failure, downloads the official standalone installer and runs `/silent /install`
6. Records install via `Save-InstalledRecord`

## Uninstall

Runs `choco uninstall googlechrome -y`, then sweeps leftover registry keys, Start Menu
shortcuts, Desktop shortcuts. The Chrome user profile under `%LOCALAPPDATA%\Google\Chrome`
is preserved by default (`purgeAppData: false`); set it to `true` in `config.json`
to wipe profile data too.

## Wiring

- Registry: `scripts/registry.json` -> `"58": "58-install-chrome"`
- Keywords: `chrome`, `google-chrome`, `googlechrome`, `browser` -> `[58]`
- Included in `essentials` and `basic` keyword bundles, and in script 12's "All Core" + "Everything" groups.
