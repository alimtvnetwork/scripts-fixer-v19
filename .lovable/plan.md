# models-download must be 100% standalone

## Problem
`.\run.ps1 models-download deepseek-r1:8b` aborts with **"Ollama is not installed"**.
Same path on llama.cpp aborts with **"llama.cpp is not installed"**.
That coupling is wrong. Downloading model **weights** must be a disjoint operation from installing the **runtimes** (Ollama daemon / llama.cpp binaries).

## Hard rules (carry into memory)
1. `models-download` / `models download` MUST NEVER require Ollama or llama.cpp to be present.
2. It MUST NEVER install or fetch runtime binaries.
3. It only fetches weights into the configured model dirs.
4. Wiring weights to a runtime is a separate, explicit command (out of scope here).

## Fix

### Windows — `scripts/models/helpers/picker.ps1` `Invoke-BackendInstall`
- **llama.cpp branch**: delete the `Get-Command llama-cli` / `llama-server` / DEV_DIR scan presence guard. Direct GGUF download via aria2c already works without llama.cpp installed. Keep the existing `MODELS_DOWNLOAD_NO_BINARIES=1` sentinel + post-run binary-leak diff.
- **Ollama branch**: replace the `Get-Command ollama` guard + `& $script pull` dispatch with a new direct-registry puller `Invoke-OllamaRegistryPull`:
  - Resolve target dir from `Get-ModelDownloadPaths` (Ollama scope) — no daemon required.
  - For each slug `name[:tag]` (default tag `latest`):
    1. `GET https://registry.ollama.ai/v2/library/<name>/manifests/<tag>` with `Accept: application/vnd.docker.distribution.manifest.v2+json`.
    2. For each `layers[]` + `config` blob, `GET https://registry.ollama.ai/v2/library/<name>/blobs/<digest>` → save to `<ollama-dir>/blobs/sha256-<hex>` (sha256 verified, resumable via aria2c when available, fallback `Invoke-WebRequest -Resume`).
    3. Write the manifest JSON to `<ollama-dir>/manifests/registry.ollama.ai/library/<name>/<tag>`.
  - This matches the on-disk layout the Ollama daemon expects, so a later `-I 42` install picks the weights up automatically.
  - Every failure logs upstream URL + target path + reason via `Write-FileError` (CODE RED contract).

### Linux — `scripts-linux/models/run.sh` (and helper)
Mirror the same two changes:
- Drop the `command -v llama-cli` / `command -v ollama` presence guards in the dispatcher.
- Add `scripts-linux/models/helpers/ollama-registry-pull.sh` using `aria2c` (preferred) or `curl -L --continue-at -`, identical layout (`<ollama-dir>/blobs/sha256-…`, `<ollama-dir>/manifests/registry.ollama.ai/library/<name>/<tag>`).

### Memory
- Update `mem://features/models-download-no-auto-install` and `mem://features/models-download-no-binaries-guard` to state: not only "must not install", but also "must not REQUIRE either backend to be installed". Standalone direct-registry pull is the contract.
- Add new `mem://features/ollama-registry-direct-pull` documenting the manifest+blob layout we write so future code doesn't regress.
- Update `mem://index.md` Core line.

### Verification
- `.\run.ps1 models-download deepseek-r1:8b` on a box with **no Ollama installed** → blobs land under `<ollama-dir>/blobs/sha256-…`, manifest under `<ollama-dir>/manifests/registry.ollama.ai/library/deepseek-r1/8b`, exit 0.
- `.\run.ps1 models-download 5` (a llama.cpp catalog id) on a box with **no llama-cli on PATH** → GGUF lands under `<llama-dir>` via aria2c, exit 0.
- Bump `version.json` patch.

## Out of scope
- Wiring downloaded weights into a freshly installed Ollama/llama.cpp runtime (separate command, not requested here).
- Changing the install scripts (`-I 42`, `-I 43`).
