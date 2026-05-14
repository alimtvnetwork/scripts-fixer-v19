---
name: models-download no-binaries hard guard
description: Cross-OS sentinel + post-run binary-leak diff that aborts models-download if llama.cpp install path triggers
type: feature
---
`models-download` (Windows: `.\run.ps1 models-download`, Linux: `./run.sh models`) must NEVER install llama.cpp binaries. Guard has two layers on each OS:

1. Sentinel env var `MODELS_DOWNLOAD_NO_BINARIES=1` set by the orchestrator before invoking the model puller. Checked at the top of the binary-install entry point:
   - Windows: `Install-LlamaCppExecutables` in `scripts/43-install-llama-cpp/helpers/llama-cpp.ps1` — throws "HARD GUARD TRIPPED" + `Write-FileError`.
   - Linux: `verb_install` in `scripts-linux/43-install-llama-cpp/run.sh` — `log_file_error` + `return 87`.

2. Pre/post snapshot diff of the llama.cpp install dir (`llama-*.exe`, `*.dll`, `*.zip` on Windows; `llama-*`, `*.so`, `*.dylib`, `*.tar.gz`, `*.zip` on Linux). Any new/grown file → abort with the leaked path list and the install-explicitly hint (`-I 43`).

Linux smoke test: `scripts-linux/43-install-llama-cpp/tests/models-download-no-binaries.test.sh` (covers both layers via a stubbed `model-pull.sh`).
