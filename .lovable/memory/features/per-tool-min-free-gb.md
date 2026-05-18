---
name: Per-tool minimum free GB
description: scripts/shared/dev-dir.ps1 supports per-tool free-space requirements via config.minFreeGB + Resolve-SmartDevDir -MinFreeGB + $env:SCRIPTS_FIXER_MIN_FREE_GB; smart picker auto-falls-back to largest-free fixed drive instead of always prompting.
type: feature
---

# Per-tool minimum free space (dev-dir smart picker)

Default `$script:MinFreeSpaceGB = 10` is meant for heavy tools (models, Docker,
JDK, Android SDK). Lightweight tools (pip, git, sqlite client) should
override it so the picker doesn't refuse to install on capable boxes whose
non-system drives have 5-9 GB free.

## How install scripts opt in

1. Add `"minFreeGB": <N>` to the script's `config.json` (e.g. `0.5` for pip,
   `2` for git, `4` for JDK).
2. In the script's `run.ps1` (and any helper that calls `Resolve-SmartDevDir`
   directly), read the value and pass it explicitly:

   ```powershell
   $min = 0.5
   if ($null -ne $config.minFreeGB) { try { $min = [double]$config.minFreeGB } catch {} }
   $devDir = Resolve-SmartDevDir -MinFreeGB $min
   ```

3. Or set `$env:SCRIPTS_FIXER_MIN_FREE_GB = "<N>"` before calling
   `Resolve-SmartDevDir` (useful from orchestrators that run multiple scripts).

## Smart-picker fallback chain

`Resolve-SmartDevDir` now walks this chain:

1. Cached `.resolved/dev-drive-cache.json` (if drive is ready)
2. `Find-BestDevDrive` (E -> D -> any non-system fixed drive with >= MinFreeGB)
3. **NEW:** Largest-free fixed drive across ALL drives (including system
   drive) with >= MinFreeGB -- logs `[ WARN ] Auto-picked largest-free drive
   X: (...) -- no preferred drive qualified` so the user knows the fallback ran
4. `SCRIPTS_AUTO_YES` -> `$SystemDrive\dev-tool`
5. Interactive prompt
6. Last-resort `$SystemDrive\dev-tool`

This eliminates the previous "10 GB hard wall" prompt for small installers
on boxes where the only non-system drive has 5-9 GB free.

## Wired so far

- Script 04 (install-pnpm): `config.minFreeGB = 0.5`, `run.ps1` passes it to
  `Configure-PnpmStore`, and `helpers/pnpm.ps1` forwards `-MinFreeGB` to
  `Resolve-SmartDevDir`.
- Script 05 (install-python): `config.minFreeGB = 0.5`, both `run.ps1` and
  `helpers/python.ps1` pass it to `Resolve-SmartDevDir -MinFreeGB`.
- Script 07 (install-git): `config.minFreeGB = 1`. Installs via Chocolatey to
  system paths; no direct `Resolve-SmartDevDir` call. Config override exists for
  future dev-dir usage.
- Script 16 (install-php): `config.minFreeGB = 1`. Installs via Chocolatey to
  system paths; no direct `Resolve-SmartDevDir` call. Config override exists for
  future dev-dir usage.
- Script 21 (install-sqlite): `config.minFreeGB = 0.5`, `run.ps1` passes
  `-MinFreeGB` to `Resolve-DevDir`, and `scripts/shared/dev-dir.ps1`
  `Resolve-DevDir` forwards it to `Resolve-SmartDevDir`.
- Script 41 (install-python-libs): `config.minFreeGB = 1`. Installs via pip to
  user site; no direct `Resolve-SmartDevDir` call. Config override exists for
  future dev-dir usage.

## Still to wire (suggested per-tool values)

None -- all lightweight scripts in the batch are now wired.

- (Heavy tools keep the 10 GB default: 40 java, 39 dotnet, 44 rust,
  45 docker, 38 flutter, 42 ollama, 43 llama-cpp, models-download)
