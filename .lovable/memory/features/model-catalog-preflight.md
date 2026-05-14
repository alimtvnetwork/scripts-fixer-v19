---
name: model catalog preflight + no hallucinated repos
description: Catalog must only list HuggingFace repos that actually exist; downloader HEAD-probes URLs before aria2c retries
type: constraint
---
**Two-pronged guard against the "Authorization failed" / "Invalid username
or password" failure mode** (root cause: catalog entry pointed at a
non-existent HuggingFace repo, e.g. `Qwen/Qwen3.7-Coder-14B-Instruct-GGUF`
which doesn't exist — HF returns 401 for missing-or-gated repos).

1. **Preflight HEAD check** (`scripts/43-install-llama-cpp/helpers/model-picker.ps1`):
   Before calling `Invoke-FastDownload`, do `Invoke-WebRequest -Method Head`.
   On 401/403/404 (or any non-2xx), log a clear `[ FAIL ]` line with the
   exact status meaning + URL + the action the user should take
   ("remove or correct this entry in models-catalog.json"), increment
   `$failedCount`, and `continue` — do NOT let aria2c burn its 3 retries.

2. **Catalog hygiene**: never add fictional Qwen/Gemma/Phi versions
   (Qwen 3.5, Qwen 3.7, Gemma 4, Phi-4 mini-reasoning, etc. didn't exist
   when last verified). Only add entries whose `downloadUrl` you have
   actually `curl -sI`-verified to return 200/302. If you must stage an
   entry without verification, leave it `disabled: true` until SHA256
   fill confirms the file exists.

Removed 2026-05-15: 12 qwen3.5-*, 2 qwen3.7-coder-*, 4 gemma-4-*,
gemma-3-27b-it, phi-4-mini-reasoning. Catalog went 98 -> 78 entries.
