<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Spec — Models" width="128" height="128"/>

# Spec — Models

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Spec](https://img.shields.io/badge/Spec-Toolkit-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.70.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

# Spec: Models Orchestrator

## Purpose

Single entry point (`./run.ps1 models` / `model` / `-M`) for browsing,
filtering, and installing AI models across both supported backends:

| Backend     | Folder                          | What it installs                    |
|-------------|---------------------------------|-------------------------------------|
| `llama-cpp` | `scripts/43-install-llama-cpp/` | Raw GGUF files for llama.cpp runtime |
| `ollama`    | `scripts/42-install-ollama/`    | Runtime tooling + slug catalog only |

The orchestrator never duplicates picker logic -- it dispatches to the
existing scripts (which already own catalogs, filters, and downloaders).

## CLI surface

| Invocation                                           | Behaviour                                                    |
|------------------------------------------------------|--------------------------------------------------------------|
| `.\run.ps1 models`                                   | Interactive: pick backend, then dispatch to its picker        |
| `.\run.ps1 model`                                    | Alias for `models`                                           |
| `.\run.ps1 -M`                                       | Shortcut flag, same as `models`                              |
| `.\run.ps1 models qwen2.5-coder-3b,llama3.2`         | CSV direct install (auto-routes per backend)                 |
| `.\run.ps1 models -Backend llama-cpp`                | Skip backend prompt, go straight to llama.cpp picker          |
| `.\run.ps1 models -Backend ollama -Install llama3.2,qwen2.5-coder` | Non-interactive install on a specific backend |
| `.\run.ps1 models list`                              | List all models from both catalogs                            |
| `.\run.ps1 models list llama`                        | List only llama.cpp catalog                                   |
| `.\run.ps1 models list ollama`                       | List only Ollama defaults                                    |
| `.\run.ps1 models -Help`                             | Help text                                                    |
| `.\run.ps1 models search llama`                      | **Live search** of ollama.com/library; pick results to pull  |
| `.\run.ps1 models search`                            | Prompts for query, then live search                          |
| `.\run.ps1 models uninstall`                         | List local installs (both backends), multi-select, delete    |
| `.\run.ps1 models uninstall llama`                   | Uninstall picker scoped to llama.cpp GGUF files only         |
| `.\run.ps1 models uninstall ollama`                  | Uninstall picker scoped to Ollama daemon models only         |
| `.\run.ps1 models rm`                                | Alias for `uninstall`                                        |
| `.\run.ps1 models uninstall -Force`                  | Skip the `yes` confirmation prompt (CI / scripts)            |

## File layout

```
scripts/models/
  run.ps1                  # Thin dispatcher (this file is intentionally small)
  config.json              # Backend registry: scriptFolder, catalogFile, idField
  log-messages.json        # All user-facing strings (per logging convention)
  helpers/
    picker.ps1             # Backend picker, catalog loader, CSV resolver, dispatcher
    ollama-search.ps1      # Live Ollama Hub search + HTML parser + result picker
    uninstall.ps1          # Local-installs scanner, multi-select picker, deleter
```

`run.ps1` only handles arg parsing + flow control. All real logic lives in
`helpers/*.ps1` so the file stays under ~200 lines per the project's
"keep run.ps1 small" rule.

## Ollama Hub search

`.\run.ps1 models search <query>` performs a live HTTP GET against
`https://ollama.com/search?q=<query>`, parses the result HTML using stable
`x-test-*` markers (`x-test-model`, `x-test-search-response-title`,
`x-test-size`, `x-test-capability`, `x-test-pull-count`, `x-test-tag-count`,
`x-test-updated`), and renders a numbered table. Selection accepts the
same syntax as the other pickers (`1,3`, `1-5`, `all`, `q`) plus an
optional `:tag` suffix per pick to target a specific size, e.g. `2:7b`
pulls `<slug>:7b`. Selected slugs are joined into a CSV and dispatched to
script 42 via the `OLLAMA_PULL_MODELS` env var (the same handoff used by
the CSV install path), so unknown slugs become ad-hoc `ollama pull <slug>`
calls without needing config edits.

The href parser tolerates both absolute (`href="https://ollama.com/library/X"`)
and relative (`href="/library/X"`) shapes. Network failures and empty
result sets are logged and return cleanly -- they never throw.

## Uninstall

`.\run.ps1 models uninstall` (or `rm` / `remove`) enumerates everything
currently on this machine across both backends:

- **llama.cpp**: source of truth is `.installed/model-*.json` (the same
  tracking files written by `Install-SelectedModels`). Each id is
  cross-referenced with `43-install-llama-cpp/models-catalog.json` to
  recover `fileName`, `displayName`, and `fileSizeGB`. The GGUF folder is
  resolved from `.resolved/43-install-llama-cpp.json` first, then
  `$env:DEV_DIR/llama-models` as fallback. The picker shows whether the
  file is still on disk so users can also clean up stale tracking entries.
- **Ollama**: shells out to `ollama list` and parses its tabular output
  (columns `NAME / ID / SIZE / MODIFIED`, separated by 2+ spaces). When
  the binary or the daemon are unavailable, this returns an empty array
  and logs a warning -- never throws.

After multi-select (same syntax as the install pickers), the orchestrator
prints the proposed deletions and requires an explicit `yes` to proceed.
Pass `-Force` to skip the confirmation prompt entirely -- useful for CI
pipelines and unattended cleanup scripts. Deletion routes per backend:
`Remove-Item` + `Remove-InstalledRecord` for GGUFs, `ollama rm <id>` for
Ollama models. Per-item success/failure is logged and a final summary
line is printed.

## Algorithm

1. **Parse args**: detect list mode vs CSV vs interactive.
2. **List mode**: load catalogs, render flat table, exit.
3. **CSV / download mode**: load catalog(s), match each id (exact, then
   `-like *id*`), normalize every selected model to a standalone GGUF alias,
   then download directly into `<DEV_DIR>\models` via the llama.cpp model
   installer helper. `models-download` never pulls Ollama blobs.
4. **Interactive mode**: prompt for backend (1=llama, 2=ollama, 3=both),
   then either show combined list or invoke the backend script's own
   picker.

## Catalog wiring

`config.json` declares each backend:

```json
{
  "backends": {
    "llama-cpp": {
      "scriptFolder": "43-install-llama-cpp",
      "catalogFile":  "models-catalog.json",
      "idField":      "id",
      "displayField": "displayName"
    },
    "ollama": {
      "scriptFolder": "42-install-ollama",
      "catalogFile":  "config.json",
      "catalogPath":  "defaultModels",
      "idField":      "slug",
      "displayField": "displayName"
    }
  }
}
```

To add a third backend, drop a config entry and a script that accepts
either an env var or a CSV positional arg -- no changes to `picker.ps1`.

## Dispatcher contract

The orchestrator passes resolved ids to backends via env vars rather than
positional args, since both backend scripts already use positional args
for their own subcommands (`install`, `pull`, `models`, `uninstall`).

| Backend     | Env var passed          | Subcommand invoked | Honored by (since) |
|-------------|-------------------------|--------------------|--------------------|
| `llama-cpp` | `LLAMA_CPP_INSTALL_IDS` | `all`              | `Invoke-ModelInstaller` -- v0.33.0 |
| `ollama`    | `OLLAMA_PULL_MODELS`    | `pull`             | `Pull-OllamaModels` -- v0.33.0 |

**llama-cpp** behaviour when `LLAMA_CPP_INSTALL_IDS` is set: skip all RAM/size/speed/capability filter prompts, resolve each CSV id against the catalog (exact match first, then `-like *id*`), download only the matched subset. Unmatched ids are warned and skipped; empty result aborts cleanly.

**models-download contract**: numeric picks, CSV ids, and Ollama slug aliases are all normalized to standalone GGUF ids first. If no GGUF alias exists, the model is skipped with a warning. Download mode never shells out to `ollama`, never writes Ollama blob layouts, and always saves GGUF files to the resolved shared models folder.

## Examples

```powershell
# Interactive: friendliest path
.\run.ps1 models

# Direct install across backends, comma-separated
.\run.ps1 models qwen2.5-coder-3b,llama3.2,deepseek-r1:8b

# Browse before deciding
.\run.ps1 models list
.\run.ps1 models list llama

# Force a backend, skip prompt
.\run.ps1 models -Backend llama-cpp
```

## Why not just point users at scripts 42 and 43?

- Discoverability: `models` is the obvious verb; users don't need to
  know which numbered script handles what.
- Cross-backend CSV: `qwen2.5-coder-3b,llama3.2` mixes backends; users
  shouldn't have to split the call.
- Single help surface: one `--help` lists every model id from every backend.


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
