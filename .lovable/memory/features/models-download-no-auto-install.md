---
name: models-download is fully standalone
description: models-download must NEVER install AND must NEVER REQUIRE llama.cpp or Ollama runtimes
type: constraint
---
`.\run.ps1 models-download <ids>` (and `models download`, Linux `./run.sh models <ids>`)
is **fully standalone**. Two hard rules — both enforced:

1. MUST NEVER install runtime binaries (llama.cpp `llama-*.exe` / Ollama daemon).
2. MUST NEVER REQUIRE either runtime to already be installed.

Only model **weights** are downloaded. Wiring weights into a runtime is a
separate, explicit operation (`-I 42` / `-I 43`).

Implementation in `scripts/models/helpers/picker.ps1` `Invoke-BackendInstall`:
- **Ollama branch**: NO `Get-Command ollama` presence guard. Calls
  `Invoke-OllamaRegistryPull` (see `mem://features/ollama-registry-direct-pull`)
  which pulls blobs+manifest directly from `registry.ollama.ai` into
  `<ollama-dir>` using the daemon's on-disk layout.
- **llama.cpp branch**: NO `Get-Command llama-cli` / DEV_DIR scan presence
  guard. Calls `Invoke-ModelInstaller` directly to fetch GGUFs via aria2c into
  `<llama-dir>`. The `MODELS_DOWNLOAD_NO_BINARIES=1` sentinel + post-run
  binary-leak diff still enforce rule #1.

Removing either of these rules is a regression — `mem://constraints/strictly-prohibited`-class.
