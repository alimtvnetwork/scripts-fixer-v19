# Spec — Kimodo (Specialty AI Model)

**Status:** Documentation-only spec (manual install, not yet wired into `run.ps1`).
**Upstream gist:** https://gist.github.com/Aero-Ex/3affd23c4c9632dbff3045f4ae3655ec
**Upstream repos:**
- https://github.com/Aero-Ex/kimodo
- https://github.com/nv-tlabs/kimodo-viser
- https://huggingface.co/Aero-Ex/KIMODO-Meta3_llm2vec_NF4 (custom NF4 text encoder, ~5.4 GB)

## What is Kimodo?

Kimodo is an NVIDIA-derived motion/video pipeline that uses a custom
**LLM2Vec** text encoder (NF4-quantized Meta-Llama-3 8B) for text
conditioning. Unlike the GGUF catalog (script 43) and the Ollama
catalog (script 42), Kimodo is **not a chat LLM** — it's a generative
motion model with its own demo UI. It is therefore tracked here as a
specialty model rather than added to the GGUF/Ollama lists.

## Hardware

| Resource | Minimum | Recommended |
|---|---|---|
| GPU VRAM | 8 GB (with `--offload`) | 12 GB+ |
| System RAM | 16 GB | 32 GB |
| Disk | ~15 GB free | ~20 GB free |
| OS | Windows 10/11 or Linux | Linux preferred |
| Python | 3.10 / 3.11 / 3.12 | 3.12 |

## Install (manual, mirrors the upstream gist)

### 1. Python venv

```bash
python -m venv venv
source venv/bin/activate          # Linux / macOS
.\venv\Scripts\activate           # Windows PowerShell
```

### 2. Download the custom text encoder

```bash
pip install --upgrade huggingface_hub
python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='Aero-Ex/KIMODO-Meta3_llm2vec_NF4', local_dir='./KIMODO-Meta3_llm2vec_NF4')"
```

### 3. Clone Kimodo + Viser

```bash
git clone https://github.com/Aero-Ex/kimodo.git
cd kimodo
git clone https://github.com/nv-tlabs/kimodo-viser.git
pip install -e kimodo-viser
# Skip native motion_correction build (we install the prebuilt wheel below)
SKIP_MOTION_CORRECTION_IN_SETUP=1 pip install -e .            # Linux / macOS
set SKIP_MOTION_CORRECTION_IN_SETUP=1 && pip install -e .     # Windows
```

### 4. Install the prebuilt `motion_correction` wheel

Pick the wheel matching your OS + Python version from the
[Kimodo v1.0.0 release page](https://github.com/Aero-Ex/kimodo/releases/tag/v1.0.0).
Example (Windows + Python 3.12):

```bash
pip install https://github.com/Aero-Ex/kimodo/releases/download/v1.0.0/motion_correction-1.0.0-cp312-cp312-win_amd64.whl
```

### 5. Quantization + transformers

```bash
pip install bitsandbytes
pip install -U transformers==5.1.0
```

### 6. Point the encoder at your local model

Edit `kimodo/kimodo/model/llm2vec/llm2vec_wrapper.py` and update the
`custom_dir` field on **line 27** to the **absolute path** of the
`KIMODO-Meta3_llm2vec_NF4` folder downloaded in step 2.

```python
self.custom_dir = "/absolute/path/to/KIMODO-Meta3_llm2vec_NF4"
```

This forces Kimodo to load the encoder offline instead of hitting
Hugging Face on every run.

### 7. Node.js (Windows-only, required by the demo UI)

```powershell
winget install -e --id OpenJS.NodeJS.LTS    # stable LTS
# or
winget install -e --id OpenJS.NodeJS        # current
node -v ; npm -v ; npx -v
```

> Toolkit users can install Node via `.\run.ps1 install nodejs`
> (script 03) instead of winget.

### 8. Launch

```bash
python -m kimodo.demo
# Low-VRAM (<8 GB) — offload weights:
python -m kimodo.demo --offload
```

## Why not in the GGUF / Ollama catalogs?

- **No GGUF artifact.** The encoder ships as a HuggingFace snapshot
  (NF4 / safetensors), not a quantized GGUF the llama.cpp picker can
  load.
- **Not Ollama-pullable.** No matching `ollama pull` slug exists.
- **Pipeline, not a single weight.** Requires a Python repo, prebuilt
  CUDA wheel, and a manual edit to one Python source file — outside
  the schema of `scripts/43-install-llama-cpp/models-catalog.json`.

## Future work

A dedicated installer (`scripts/47b-install-kimodo/`) could automate
steps 1–6 and expose `.\run.ps1 install kimodo`. Tracked in
`.lovable/question-and-ambiguity/16-kimodo-models-list.md` (Option C).

## See also

- [Local AI Models — 90 GGUFs + Ollama](../../readme.md#-local-ai-models--90-ggufs--ollama)
- [Script 42 — Ollama](../42-install-ollama/readme.md)
- [Script 43 — llama.cpp + GGUF picker](../../scripts/43-install-llama-cpp/models-list.md)
