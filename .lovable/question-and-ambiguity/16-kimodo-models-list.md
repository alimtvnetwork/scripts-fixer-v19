# 16 — Kimodo specialty model: where to add

- **Logged on:** 2026-05-10 (UTC+8)
- **Triggering task:** "add these models to our models list … and add as spec and other related stuff in our readme"
- **Original spec reference:** https://gist.github.com/Aero-Ex/3affd23c4c9632dbff3045f4ae3655ec (Kimodo Local Installation Guide)
- **Mode:** No-Questions (task 16 of 40)

## The point of confusion

The gist describes **Kimodo** (NVIDIA-based motion/video model) plus a custom **KIMODO-Meta3_llm2vec_NF4** text encoder. It is a Python repo install (clone + pip + wheels), not a GGUF or Ollama-pullable model. Our existing "models list" is `scripts/43-install-llama-cpp/models-catalog.json` (GGUF only) and `scripts/42-install-ollama/config.json` (Ollama slugs). Neither schema fits Kimodo cleanly.

## Options considered

### Option A — Force-fit into llama.cpp catalog
- Add a fake GGUF entry. **Cons:** breaks schema (no `downloadUrl` to a .gguf), pollutes hardware-aware picker, misleads users.

### Option B — New "specialty models" doc + spec, no catalog pollution
- Add `spec/kimodo/readme.md` mirroring the gist, reference it from a new "Specialty AI Models" subsection in the root readme below the existing "Local AI Models" block. No schema changes.
- **Pros:** zero risk to picker; preserves catalog integrity; honors gist's manual-install nature.
- **Cons:** not auto-installable via `run.ps1 install`.

### Option C — New install script slot (e.g. `47b-install-kimodo`)
- Full-blown installer. **Cons:** large effort, requires NVIDIA GPU/wheels per Python version, out of scope for a "add to readme" task.

## Recommendation

**Option B** — minimal, honest, reversible. User can later upgrade to Option C.

## Inference actually used

- Created `spec/kimodo/readme.md` with the gist's 8 steps verbatim (paraphrased headers, code blocks intact).
- Added a **Specialty AI Models** subsection to root `readme.md` right under the "Local AI Models" block, linking to the new spec.
- No changes to `models-catalog.json` or Ollama config.

## How to revert / change course

- Delete `spec/kimodo/readme.md` and the new readme subsection.
- To upgrade to Option C, add `scripts/47b-install-kimodo/` with a `run.ps1` wrapping the gist's commands, then register it.
