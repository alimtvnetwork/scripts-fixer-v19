# models-download must be 100% standalone

## Problem
`.\run.ps1 models-download deepseek-r1:8b` aborts with **"Ollama is not installed"**.
Same path on llama.cpp aborts with **"llama.cpp is not installed"**.
That coupling is wrong. Downloading model **weights** must be a disjoint operation from installing the **runtimes** (Ollama daemon / llama.cpp binaries).

## Hard rules (carry into memory)
1. `models-download` / `models download` MUST NEVER require Ollama or llama.cpp to be present.
2. It MUST NEVER install or fetch runtime binaries.
3. It MUST resolve every requested model to a standalone `.gguf` file in `<DEV_DIR>\models`.
4. If an Ollama catalog entry has no GGUF alias, skip it with a clear warning instead of downloading Ollama blobs.
5. Wiring weights to a runtime is a separate, explicit command (out of scope here).

## Fix

### Windows — `scripts/models/helpers/picker.ps1`
- Normalize numeric picks, CSV ids, and Ollama slug aliases through a shared standalone-GGUF resolver before dispatch.
- Route `Invoke-BackendInstall` to a single GGUF-only path that writes into `<DEV_DIR>\models`.
- Keep the existing `MODELS_DOWNLOAD_NO_BINARIES=1` sentinel + post-run binary-leak diff so `models-download` never leaks runtime installs.

### Linux — `scripts-linux/models/run.sh` (future parity)
- Mirror the same standalone GGUF-only normalization and download flow.
- Keep runtime installation fully separate from model-weight downloads.

### Memory
- Add a project memory entry stating `models-download` is GGUF-only and always writes standalone `.gguf` files into `<DEV_DIR>\models`.
- Update `mem://index.md` Core line.

### Verification
- `.\run.ps1 models-download deepseek-r1:8b` on a box with **no Ollama installed** -> `deepseek-r1-8b*.gguf` lands under `<DEV_DIR>\models`, exit 0.
- `.\run.ps1 models-download 93` (an Ollama catalog index) -> resolves to the GGUF alias and lands under `<DEV_DIR>\models`, exit 0.
- `.\run.ps1 models-download 5` (a llama.cpp catalog id) on a box with **no llama-cli on PATH** -> GGUF lands under `<DEV_DIR>\models` via aria2c, exit 0.
- Bump `version.json` patch.

## Out of scope
- Wiring downloaded weights into a freshly installed Ollama/llama.cpp runtime (separate command, not requested here).
- Changing the install scripts (`-I 42`, `-I 43`).