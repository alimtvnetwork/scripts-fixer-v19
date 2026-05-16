<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Spec — Bump Version" width="128" height="128"/>

# Spec — Bump Version

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Spec](https://img.shields.io/badge/Spec-Toolkit-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v1.2.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

# Spec: Bump Version (bump-version.ps1)

## Overview

The root-level `bump-version.ps1` updates the project version in
`scripts/version.json` -- the single source of truth for all scripts.
All scripts pick up the new version automatically via `Write-Banner`.

---

## Usage

```powershell
.\bump-version.ps1 -Patch            # 0.3.0 -> 0.3.1
.\bump-version.ps1 -Minor            # 0.3.0 -> 0.4.0
.\bump-version.ps1 -Major            # 0.3.0 -> 1.0.0
.\bump-version.ps1 -Set "2.0.0"     # Explicit version
.\bump-version.ps1                   # Show usage help
```

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-Patch` | switch | No | Bump patch version (e.g. 0.3.0 -> 0.3.1) |
| `-Minor` | switch | No | Bump minor version, reset patch (e.g. 0.3.0 -> 0.4.0) |
| `-Major` | switch | No | Bump major version, reset minor and patch (e.g. 0.3.0 -> 1.0.0) |
| `-Set` | string | No | Set an explicit version string (must be `Major.Minor.Patch` format) |

When no parameter is provided, the script prints usage help and exits.

---

## Execution Flow

1. Read current version from `scripts/version.json`
2. Display current version
3. Calculate new version based on the flag provided
4. Validate format (must be `N.N.N`)
5. Skip if new version equals current version
6. Write updated version to `scripts/version.json`
7. Update Changelog badge version in `readme.md` (if badge exists)
8. **Regenerate `spec/script-registry-summary.md`** by invoking
   `node scripts/_internal/generate-registry-summary.cjs` (skipped with a
   warning if Node is not on PATH -- bump still succeeds)
9. Display confirmation

---

## Validation

| Condition | Behaviour |
|-----------|-----------|
| `scripts/version.json` missing | `[ FAIL ]` and exit |
| `-Set` with invalid format (not `N.N.N`) | `[ FAIL ]` and exit |
| New version same as current | `[ SKIP ]` and exit |
| No flags provided | Show usage help and exit |

---

## Version Propagation

The version is consumed automatically by `Write-Banner` in
`scripts/shared/logging.ps1`. Every script that calls `Write-Banner -Title`
reads from `scripts/version.json` at runtime -- no per-script version
fields are needed.

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Single `version.json` source of truth | Eliminates version drift across 31+ scripts |
| No per-script version fields | Removed from all `log-messages.json` files; `Write-Banner` auto-loads |
| Explicit `-Set` validation | Prevents malformed version strings |
| Skip on same version | Avoids unnecessary file writes |
| Root-level placement | Easy to find alongside `run.ps1` |


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
