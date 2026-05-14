---
name: models-download never auto-installs backends
description: models-download must only fetch models; never install llama.cpp or Ollama runtimes
type: constraint
---
`.\run.ps1 models-download <ids>` (and `models download`) must NEVER trigger
installation of the llama.cpp binaries or the Ollama runtime.

Implementation in `scripts/models/helpers/picker.ps1` `Invoke-BackendInstall`:
- Ollama branch: probe `Get-Command ollama`. If missing -> log error pointing
  user to `.\run.ps1 -I 42` and `continue` (skip group). If present, dispatch
  `& $script pull` (model-only). Never `all`.
- llama.cpp branch: probe `llama-cli` / `llama-server` / `main` / `llama` on
  PATH, then fall back to scanning `<DEV_DIR>\<config.devDirSubfolder>` for
  any `llama-*.exe`. If absent -> log error pointing user to
  `.\run.ps1 -I 43` and `continue`. If present, dispatch `& $script models`
  (model-only). Never `all` (which re-downloads CUDA/AVX2 zips).

The user installs backends explicitly via `-I 42` / `-I 43` (or
`install ollama` / `install llama-cpp`).
