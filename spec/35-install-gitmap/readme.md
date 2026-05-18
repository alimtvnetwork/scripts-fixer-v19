<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Spec 35 — Install Gitmap" width="128" height="128"/>

# Spec 35 — Install Gitmap

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v20#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v20#requirements)
[![Script](https://img.shields.io/badge/Script-35-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v20/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v20/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.70.0-f97316)](https://github.com/alimtvnetwork/gitmap-v20/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v20/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v19-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v20)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

# Install GitMap (Script 35)

## Overview

Script 35 installs the **GitMap CLI** -- a Git repository navigator tool for Windows. It uses the remote installer from GitHub (`alimtvnetwork/gitmap-v20`).

## Install Command

```powershell
# Via run.ps1
.\run.ps1 install gitmap
.\run.ps1 -I 35

# Pin a specific release version (overrides config.fallbackTag at runtime)
.\run.ps1 -I 35 -Version v1.2.0
.\run.ps1 install gitmap -Version v1.0.0

# Direct remote install (standalone)
irm https://raw.githubusercontent.com/alimtvnetwork/gitmap-v20/main/install.ps1 | iex
```

## `--Version` Flag

Pin gitmap to a specific release tag. When provided, the value overrides
`gitmap.fallbackTag` from `config.json` for this run only (config file is not
modified). The pinned tag is used by the ZIP fallback path when the remote
installer fails or is unreachable.

| Example | Behavior |
|---------|----------|
| `.\run.ps1 -I 35` | Uses `fallbackTag` from config (default `latest`) |
| `.\run.ps1 -I 35 -Version v1.2.0` | Forces tag `v1.2.0` for this run |
| `.\run.ps1 install gitmap -Version v1.0.0` | Same, via dispatcher keyword |
| `.\run.ps1 -I 35 -- -Help` | Shows help including `-Version` flag |

Notes:
- Tag must match an existing release in `alimtvnetwork/gitmap-v20` (e.g. `v1.2.0`).
- Use `latest` to resolve the newest release via the GitHub API.
- The flag has no effect if the remote installer succeeds and pins its own version internally.

## Config (`config.json`)

| Key                  | Description                                |
|----------------------|--------------------------------------------|
| `devDir.mode`        | Drive resolution mode (`smart` or legacy)  |
| `devDir.default`     | Default install directory                  |
| `devDir.override`    | Force a specific directory (overrides all) |
| `gitmap.enabled`     | Enable/disable GitMap install              |
| `gitmap.verifyCommand` | Command to check if GitMap is installed  |
| `gitmap.installUrl`  | URL to the remote install.ps1              |
| `gitmap.repo`        | GitHub repository                          |
| `gitmap.releaseZipUrl` | URL template for ZIP fallback (`{tag}` placeholder) |
| `gitmap.fallbackTag` | Tag for ZIP fallback (`latest` resolves via API) |
| `gitmap.installDir`  | Override install directory (bypasses devDir)|

Default install directory: `C:\dev-tool\GitMap` (resolved via `devDir` config).

## Install Directory Resolution

Priority order:
1. `gitmap.installDir` -- explicit override in config
2. `Resolve-DevDir` -- uses `$env:DEV_DIR`, smart drive detection (E: > D: > best drive), or user prompt
3. `devDir.default` -- legacy fallback from config
4. Hardcoded `C:\dev-tool\GitMap`

The resolved path is passed as `-InstallDir` to the remote installer script.

## Remote Installer Flags

| Flag           | Description                          | Example                          |
|----------------|--------------------------------------|----------------------------------|
| `-InstallDir`  | Custom install directory             | `-InstallDir C:\tools\gitmap`    |
| `-Version`     | Pin a specific release               | `-Version v2.49.1`              |
| `-Arch`        | Force architecture (amd64, arm64)    | `-Arch arm64`                   |
| `-NoPath`      | Skip adding to user PATH             | `-NoPath`                       |

## Detection

1. Checks `gitmap` in PATH (`Get-Command`)
2. Falls back to known install paths: `$env:LOCALAPPDATA\gitmap\gitmap.exe` and `C:\dev-tool\GitMap\gitmap.exe`
3. Also checks devDir-resolved path: `$env:DEV_DIR\GitMap\gitmap.exe`

## How It Works

1. Checks if GitMap is already installed
2. If not found, resolves install directory via devDir system
3. Downloads `install.ps1` from GitHub via `Invoke-RestMethod`
4. Executes the installer script with `-InstallDir <resolved-path>`
5. **If remote installer fails** -- falls back to ZIP download:
   - Resolves tag via GitHub API (or uses `fallbackTag` from config)
   - Downloads `gitmap-windows-amd64.zip` from releases
   - Extracts `gitmap.exe` to install directory
   - Adds install directory to user PATH
6. Refreshes PATH and verifies installation
7. Saves resolved state (includes installDir)

## Keywords

`gitmap`, `git-map`

## Install Keywords

| Keyword |
|---------|
| `gitmap` |
| `git-map` |

```powershell
.\run.ps1 install gitmap
```


---

<!-- spec-footer:v1 -->

## Author

<div align="center">

### [Md. Alim Ul Karim](https://www.google.com/search?q=alim+ul+karim)

**[Creator & Lead Architect](https://alimkarim.com)** | [Chief Software Engineer](https://www.google.com/search?q=alim+ul+karim), [Riseup Asia LLC](https://riseup-asia.com)

</div>

A system architect with **20+ years** of professional software engineering experience across enterprise, fintech, and distributed systems. His technology stack spans **.NET/C# (18+ years)**, **JavaScript (10+ years)**, **TypeScript (6+ years)**, and **Golang (4+ years)**.

Recognized as a **top 1% talent at Crossover** and one of the top software architects globally. He is also the **Chief Software Engineer of [Riseup Asia LLC](https://riseup-asia.com/)** and maintains an active presence on **[Stack Overflow](https://stackoverflow.com/users/513511/md-alim-ul-karim)** (2,452+ reputation, 961K+ reached, member since 2010) and **LinkedIn** (12,500+ followers).

| | |
|---|---|
| **Website** | [alimkarim.com](https://alimkarim.com/) · [my.alimkarim.com](https://my.alimkarim.com/) |
| **LinkedIn** | [linkedin.com/in/alimkarim](https://linkedin.com/in/alimkarim) |
| **Stack Overflow** | [stackoverflow.com/users/513511/md-alim-ul-karim](https://stackoverflow.com/users/513511/md-alim-ul-karim) |
| **Google** | [Alim Ul Karim](https://www.google.com/search?q=Alim+Ul+Karim) |
| **Role** | Chief Software Engineer, [Riseup Asia LLC](https://riseup-asia.com) |

### Riseup Asia LLC — Top Software Company in Wyoming, USA

[Riseup Asia LLC](https://riseup-asia.com) is a **top-leading software company headquartered in Wyoming, USA**, specializing in building **enterprise-grade frameworks**, **research-based AI models**, and **distributed systems architecture**. The company follows a **"think before doing"** engineering philosophy — every solution is researched, validated, and architected before implementation begins.

**Core expertise includes:**

- 🏗️ **Framework Development** — Designing and shipping production-grade frameworks used across enterprise and fintech platforms
- 🧠 **Research-Based AI** — Inventing and deploying AI models grounded in rigorous research methodologies
- 🔬 **Think Before Doing** — A disciplined engineering culture where architecture, planning, and validation precede every line of code
- 🌐 **Distributed Systems** — Building scalable, resilient systems for global-scale applications

| | |
|---|---|
| **Website** | [riseup-asia.com](https://riseup-asia.com) |
| **Facebook** | [riseupasia.talent](https://www.facebook.com/riseupasia.talent/) |
| **LinkedIn** | [Riseup Asia](https://www.linkedin.com/company/105304484/) |
| **YouTube** | [@riseup-asia](https://www.youtube.com/@riseup-asia) |

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](../../LICENSE) file for the full text.

```
Copyright (c) 2026 Alim Ul Karim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

---

<div align="center">

*Part of the Dev Tools Setup Scripts toolkit — see the [spec writing guide](../00-spec-writing-guide/readme.md) for the full readme contract.*

</div>
