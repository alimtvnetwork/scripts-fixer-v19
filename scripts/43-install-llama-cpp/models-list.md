# Local AI Models Catalog
> 96 downloadable GGUF models for `llama.cpp` (script `43-install-llama-cpp`).
> Catalog version **4.1.2** — auto-grouped by family, size, capability.
> Models marked **★** are curated picks. Models tagged **[Leaderboard #N]** are the open-weight portion of the OpenRouter LLM Leaderboard (Nov 2025).

## Quick install
```powershell
# Interactive picker (4-filter chain: RAM -> Size -> Speed -> Capability)
.\run.ps1 install llama-cpp

# Direct CSV install (skip filters, picks by id)
.\run.ps1 models qwen2.5-coder-3b,phi-4-mini-3.8b,gemma-3-4b-it

# Browse without installing
.\run.ps1 models list llama
```

## Capability flags
| Flag | Meaning |
|---|---|
| `isCoding` | Model is trained/optimized for code generation, completion, and debugging |
| `isReasoning` | Model supports chain-of-thought, step-by-step logical reasoning |
| `isVoice` | Model supports voice/audio input or output (speech-to-text, TTS) |
| `isWriting` | Model is good at creative writing, long-form content, essays, documentation |
| `isMultilingual` | Model supports multiple human languages (not just English) |
| `isChat` | Model is optimized for conversational/chat interactions |
| `leaderboardRank` | Position on OpenRouter LLM Leaderboard (Nov 2025) if applicable. Open-weight models only. |

## OpenRouter Leaderboard (Open-Weight Coverage)
Source: OpenRouter LLM Leaderboard, Nov 2025. Closed-source API models (Claude, GPT-5.4, Gemini, Grok) are intentionally excluded — this catalog only ships locally-runnable GGUF models.

| Rank | Model | Size (GB) | RAM (GB) | Capabilities | Source |
|---|---|---|---|---|---|
| 1 | [★ Xiaomi MiMo V2 Flash (Leaderboard #1)](https://huggingface.co/unsloth/MiMo-V2-Flash-GGUF) | 4.5 | 8+ | Coding, Reasoning, Writing, Multilingual, Chat | Xiaomi MiMo Team |
| 2 | [★ Qwen 3.6 27B (Leaderboard #2 family)](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF) | 16.5 | 24+ | Coding, Reasoning, Writing, Multilingual, Chat | Alibaba Cloud Qwen Team |
| 3 | [★ DeepSeek V3.2 (Leaderboard #3) [XLarge]](https://huggingface.co/unsloth/DeepSeek-V3.2-GGUF) | 380.0 | 256+ | Coding, Reasoning, Writing, Multilingual, Chat | DeepSeek AI |
| 5 | [★ MiniMax M2 (Leaderboard #5) [XLarge]](https://huggingface.co/unsloth/MiniMax-M2-GGUF) | 130.0 | 96+ | Coding, Reasoning, Writing, Multilingual, Chat | MiniMax AI |
| 8 | [★ MiniMax M2.7 (Leaderboard #8 newer) [XLarge]](https://huggingface.co/unsloth/MiniMax-M2.7-GGUF) | 135.0 | 96+ | Coding, Reasoning, Writing, Multilingual, Chat | MiniMax AI |
| 9 | [★ StepFun Step 3.5 Flash (Leaderboard #9)](https://huggingface.co/stepfun-ai/Step-3.5-Flash-GGUF-Q8_0) | 11.0 | 14+ | Coding, Reasoning, Writing, Multilingual, Chat | StepFun AI |
| 12 | [★ NVIDIA Nemotron 3 Super 120B-A12B (Leaderboard #12) [XLarge]](https://huggingface.co/unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF) | 70.0 | 80+ | Coding, Reasoning, Writing, Multilingual, Chat | NVIDIA |
| 14 | [★ Z.AI GLM 5.1 (Leaderboard #14/#20) [XLarge]](https://huggingface.co/unsloth/GLM-5.1-GGUF) | 200.0 | 128+ | Coding, Reasoning, Writing, Multilingual, Chat | Z.AI (Zhipu AI) |
| 15 | [★ Moonshot Kimi K2.6 (Leaderboard #15) [XLarge]](https://huggingface.co/unsloth/Kimi-K2.6-GGUF) | 350.0 | 384+ | Coding, Reasoning, Writing, Multilingual, Chat | Moonshot AI |
| 17 | [★ OpenAI gpt-oss-120b (Leaderboard #17) [XLarge]](https://huggingface.co/bartowski/openai_gpt-oss-120b-GGUF) | 65.0 | 80+ | Coding, Reasoning, Writing, Multilingual, Chat | OpenAI |

## All Models by Family

### Alibaba Qwen (14)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `qwen2-0.5b` | Qwen2 0.5B (Tiny) | 0.5B | 0.5 | Tiny | Instant | 1 | Multilingual, Chat | 2/10 | 2/10 | Q8_0 | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2-0.5B-Instruct-GGUF) |
| `qwen2.5-coder-3b` | ★ Qwen 2.5 Coder 3B | 3B | 1.8 | Small | Fast | 4 | Coding, Multilingual, Chat | 7/10 | 5/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF) |
| `qwen3-4b-reasoning` | Qwen3 4B Reasoning Distill | 4B | 2.3 | Small | Fast | 4 | Coding, Reasoning, Multilingual, Chat | 5/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/mradermacher/Qwen3-4B-Thinking-2507-Claude-4.5-Opus-High-Reasoning-Distill-i1-GGUF) |
| `qwen3-4b` | Qwen3 4B | 4B | 2.5 | Small | Fast | 4 | Coding, Reasoning, Writing, Multilingual, Chat | 6/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen3-4B-GGUF) |
| `qwen2.5-coder-7b` | Qwen 2.5 Coder 7B | 7B | 5.1 | Medium | Moderate | 8 | Coding, Multilingual, Chat | 7/10 | 5/10 | Q5_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF) |
| `qwen2.5-coder-14b` | ★ Qwen 2.5 Coder 14B | 14B | 8.4 | Large | Slow | 12 | Coding, Reasoning, Multilingual, Chat | 9/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-14B-Instruct-GGUF) |
| `qwen2.5-14b` | Qwen 2.5 14B Instruct | 14B | 8.4 | Large | Slow | 12 | Coding, Reasoning, Writing, Multilingual, Chat | 7/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF) |
| `qwen2.5-coder-14b-q5` | ★ Qwen 2.5 Coder 14B Q5_K_M | 14B | 10.5 | Large | Slow | 14 | Coding, Reasoning, Multilingual, Chat | 9/10 | 7/10 | Q5_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-14B-Instruct-GGUF) |
| `qwen2.5-coder-14b-q6` | ★ Qwen 2.5 Coder 14B Q6_K | 14B | 12.3 | XLarge | Slow | 16 | Coding, Reasoning, Multilingual, Chat | 9/10 | 7/10 | Q6_K | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-14B-Instruct-GGUF) |
| `qwen2.5-coder-14b-q8` | ★ Qwen 2.5 Coder 14B Q8_0 | 14B | 15.7 | XLarge | Slow | 20 | Coding, Reasoning, Multilingual, Chat | 10/10 | 8/10 | Q8_0 | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-14B-Instruct-GGUF) |
| `qwen3-30b-a3b` | ★ Qwen3 30B-A3B (MoE Reasoning) | 30B (3B active) | 18.4 | XLarge | Slow | 24 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/bartowski/Qwen_Qwen3-30B-A3B-GGUF) |
| `qwen2.5-coder-32b` | Qwen 2.5 Coder 32B | 32B | 18.5 | XLarge | Slow | 24 | Coding, Reasoning, Multilingual, Chat | 10/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct-GGUF) |
| `qwen2.5-coder-32b-q5` | Qwen 2.5 Coder 32B Q5_K_M | 32B | 22.6 | XLarge | Slow | 28 | Coding, Reasoning, Multilingual, Chat | 10/10 | 8/10 | Q5_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct-GGUF) |
| `qwen3-coder-next` | ★ Qwen3 Coder Next (MoE) | 80B (3B active) | 48.4 | XLarge | Slow | 56 | Coding, Reasoning, Multilingual, Chat | 10/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF) |

### Alibaba Qwen 3.5 (Claude Distill) (3)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `qwen3.5-4b-opus-distill` | ★ Qwen 3.5 4B Claude Opus 4.6 Distill | 4B | 2.7 | Small | Fast | 5 | Coding, Reasoning, Writing, Multilingual, Chat | 7/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Jackrong/Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-GGUF) |
| `qwen3.5-9b-opus-distill` | ★ Qwen 3.5 9B Claude Opus 4.6 Distill v2 | 9B | 5.6 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Jackrong/Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-v2-GGUF) |
| `qwen3.5-27b-opus-distill` | ★ Qwen 3.5 27B Claude Opus 4.6 Distill | 27B | 16.5 | XLarge | Slow | 20 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-GGUF) |

### NVIDIA Nemotron (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `nemotron-8b-opus-distill` | ★ Nemotron 8B Claude 4.5 Opus Distill | 8B | 5.0 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/mradermacher/Nemotron-Orchestrator-8B-Claude-4.5-Opus-Distill-i1-GGUF) |
| `nemotron-3-super-120b` | ★ NVIDIA Nemotron 3 Super 120B-A12B (Leaderboard #12) [XLarge] | 120B (MoE 12B active) | 70.0 | XLarge | Slow | 80 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | NVIDIA Open Model License | [HF](https://huggingface.co/unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF) |

### Claude Distill (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `sonnet-4.6-distill-8b` | ★ Sonnet 4.6 Distill 8B | 8B | 5.2 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/mradermacher/Sonnet-4.6-Distill-8B-GGUF) |
| `claude-4.7-opus-distill-8b` | ★ Claude 4.7 Opus Distill 8B | 8B | 5.4 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/mradermacher/Claude-4.7-Opus-Distill-8B-GGUF) |

### Alibaba Qwen 3.5 (9)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `qwen3.5-0.8b` | Qwen 3.5 0.8B | 0.8B | 0.5 | Tiny | Instant | 2 | Coding, Reasoning, Writing, Multilingual, Chat | 4/10 | 4/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF) |
| `qwen3.5-2b` | Qwen 3.5 2B | 2B | 1.3 | Small | Fast | 3 | Coding, Reasoning, Writing, Multilingual, Chat | 5/10 | 5/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF) |
| `qwen3.5-4b` | Qwen 3.5 4B | 4B | 2.7 | Small | Fast | 5 | Coding, Reasoning, Writing, Multilingual, Chat | 6/10 | 6/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) |
| `qwen3.5-9b` | ★ Qwen 3.5 9B | 9B | 5.7 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 7/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF) |
| `qwen3.5-9b-q6` | ★ Qwen 3.5 9B Q6_K | 9B | 7.8 | Large | Moderate | 10 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q6_K | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF) |
| `qwen3.5-27b` | ★ Qwen 3.5 27B | 27B | 16.7 | XLarge | Slow | 20 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-27B-GGUF) |
| `qwen3.5-27b-q5` | ★ Qwen 3.5 27B Q5_K_M | 27B | 20.0 | XLarge | Slow | 24 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q5_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-27B-GGUF) |
| `qwen3.5-35b-a3b` | ★ Qwen 3.5 35B-A3B (Turbo MoE) | 35B (3B active) | 22.0 | XLarge | Slow | 26 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF) |
| `qwen3.5-122b-a10b` | Qwen 3.5 122B-A10B (Max MoE) | 122B (10B active) | 76.5 | XLarge | Slow | 80 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.5-122B-A10B-GGUF) |

### Alibaba Qwen 2.6 (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `qwen2.6-coder-14b` | ★ Qwen 2.6 Coder 14B | 14B | 8.8 | Large | Slow | 12 | Coding, Reasoning, Multilingual, Chat | 9/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.6-Coder-14B-Instruct-GGUF) |
| `qwen2.6-coder-32b` | ★ Qwen 2.6 Coder 32B | 32B | 19.0 | XLarge | Slow | 24 | Coding, Reasoning, Multilingual, Chat | 10/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/Qwen/Qwen2.6-Coder-32B-Instruct-GGUF) |

### DeepSeek (9)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `deepseek-coder-6.7b-q4` | DeepSeek Coder 6.7B (Q4) | 6.7B | 3.8 | Medium | Moderate | 5 | Coding | 6/10 | 4/10 | Q4_K_M | DeepSeek License | [HF](https://huggingface.co/TheBloke/deepseek-coder-6.7B-instruct-GGUF) |
| `deepseek-coder-6.7b-q5` | DeepSeek Coder 6.7B (Q5) | 6.7B | 4.5 | Medium | Moderate | 6 | Coding | 7/10 | 4/10 | Q5_K_M | DeepSeek License | [HF](https://huggingface.co/TheBloke/deepseek-coder-6.7B-instruct-GGUF) |
| `deepseek-v4-flash-qwen-9b` | DeepSeek V4 Flash Distill (Qwen3.5 9B) | 9B | 5.24 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Apache 2.0 / DeepSeek License | [HF](https://huggingface.co/Jackrong/Qwen3.5-9B-DeepSeek-V4-Flash-GGUF) |
| `deepseek-r1-8b-distill` | DeepSeek R1 Distill 8B | 8B | 5.3 | Medium | Moderate | 8 | Coding, Reasoning, Multilingual, Chat | 7/10 | 8/10 | Q5_K_M | DeepSeek License | [HF](https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF) |
| `deepseek-r1-8b` | DeepSeek R1 8B | 8B | 5.73 | Medium | Moderate | 8 | Coding, Reasoning, Multilingual, Chat | 7/10 | 8/10 | Q5_K_M | DeepSeek License | [HF](https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF) |
| `deepseek-r1-14b-distill` | ★ DeepSeek R1 Distill 14B (Qwen) | 14B | 9.0 | Large | Slow | 12 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 9/10 | Q4_K_M | DeepSeek License | [HF](https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF) |
| `deepseek-r1-70b` | DeepSeek R1 Distill 70B | 70B | 39.6 | XLarge | Slow | 48 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 10/10 | Q4_K_M | DeepSeek License | [HF](https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF) |
| `deepseek-v4-flash` | ★ DeepSeek V4 Flash (MoE, datacenter) | MoE | 80.8 | XLarge | Slow | 96 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | IQ2_XXS | DeepSeek License | [HF](https://huggingface.co/antirez/deepseek-v4-gguf) |
| `deepseek-v4-pro` | ★ DeepSeek V4 Pro (671B MoE, datacenter) | 671B-A37B | 432.7 | XLarge | Slow | 512 | Coding, Reasoning, Writing, Multilingual, Chat | 10/10 | 10/10 | IQ2_XXS | DeepSeek License | [HF](https://huggingface.co/antirez/deepseek-v4-gguf) |

### Microsoft Phi (5)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `phi-3-mini` | Microsoft Phi-3 Mini 3.8B | 3.8B | 2.2 | Small | Fast | 4 | Coding, Reasoning, Chat | 5/10 | 6/10 | Q4 | MIT | [HF](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf) |
| `phi3.5-mini-f16` | Phi-3.5 Mini (F16 Fine-tune) | 3.8B | 7.1 | Large | Moderate | 8 | Reasoning, Writing, Chat | 5/10 | 6/10 | F16 | MIT | [HF](https://huggingface.co/DavidAU/Phi-3.5-Mini-Sonet-RP-V2-GGUF) |
| `phi-3-medium` | Microsoft Phi-3 Medium 14B | 14B | 8.0 | Large | Slow | 10 | Coding, Reasoning, Chat | 7/10 | 7/10 | Q4_K_M | MIT | [HF](https://huggingface.co/bartowski/Phi-3-medium-4k-instruct-GGUF) |
| `phi-4-14b` | ★ Microsoft Phi-4 14B | 14B | 9.1 | Large | Slow | 12 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | MIT | [HF](https://huggingface.co/bartowski/phi-4-GGUF) |
| `phi-4-reasoning-plus` | ★ Phi-4 Reasoning Plus | 14B | 9.1 | Large | Slow | 12 | Coding, Reasoning, Multilingual, Chat | 8/10 | 9/10 | Q4_K_M | MIT | [HF](https://huggingface.co/bartowski/microsoft_Phi-4-reasoning-plus-GGUF) |

### Mistral (6)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `mistral-7b` | Mistral 7B Instruct v0.2 | 7B | 4.1 | Medium | Moderate | 6 | Coding, Reasoning, Writing, Multilingual, Chat | 6/10 | 6/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF) |
| `codestral-22b` | Mistral Codestral 22B | 22B | 12.4 | XLarge | Slow | 16 | Coding, Multilingual, Chat | 9/10 | 6/10 | Q4_K_M | Mistral Research License | [HF](https://huggingface.co/TheBloke/Codestral-22B-v0.1-GGUF) |
| `devstral-small-24b` | ★ Devstral Small 24B | 24B | 14.0 | XLarge | Slow | 18 | Coding, Reasoning, Multilingual, Chat | 10/10 | 8/10 | Q4_K_M | Mistral Research License | [HF](https://huggingface.co/mistralai/Devstral-Small-2507-GGUF) |
| `mistral-small-3.1-24b` | Mistral Small 3.1 24B | 24B | 14.3 | XLarge | Slow | 18 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/bartowski/mistralai_Mistral-Small-3.1-24B-Instruct-2503-GGUF) |
| `devstral-small-24b-q5` | ★ Devstral Small 24B Q5_K_M | 24B | 16.5 | XLarge | Slow | 20 | Coding, Reasoning, Multilingual, Chat | 10/10 | 8/10 | Q5_K_M | Apache 2.0 | [HF](https://huggingface.co/bartowski/Devstral-Small-2507-GGUF) |
| `devstral-small-24b-q6` | ★ Devstral Small 24B Q6_K | 24B | 19.5 | XLarge | Slow | 24 | Coding, Reasoning, Multilingual, Chat | 10/10 | 8/10 | Q6_K | Apache 2.0 | [HF](https://huggingface.co/bartowski/Devstral-Small-2507-GGUF) |

### GLM (Zhipu AI) (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `glm-4.7-flash-reasoning` | ★ GLM 4.7 Flash Reasoning | 30B | 18.1 | XLarge | Slow | 24 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/TeichAI/GLM-4.7-Flash-Claude-Opus-4.5-High-Reasoning-Distill-GGUF) |

### LG EXAONE (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `exaone-4.0-32b` | ★ EXAONE 4.0 32B | 32B | 19.3 | XLarge | Slow | 24 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | EXAONE AI License | [HF](https://huggingface.co/LGAI-EXAONE/EXAONE-4.0-32B-GGUF) |

### OpenAI Whisper (5)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `whisper-tiny` | Whisper Tiny (Voice) | 39M | 0.075 | Tiny | Instant | 1 | Voice, Multilingual | 0/10 | 0/10 | GGML | MIT | [HF](https://huggingface.co/ggerganov/whisper.cpp) |
| `whisper-base` | Whisper Base (Voice) | 74M | 0.142 | Tiny | Instant | 1 | Voice, Multilingual | 0/10 | 0/10 | GGML | MIT | [HF](https://huggingface.co/ggerganov/whisper.cpp) |
| `whisper-small` | Whisper Small (Voice) | 244M | 0.466 | Tiny | Instant | 2 | Voice, Multilingual | 0/10 | 0/10 | GGML | MIT | [HF](https://huggingface.co/ggerganov/whisper.cpp) |
| `whisper-medium` | Whisper Medium (Voice) | 769M | 1.5 | Small | Fast | 4 | Voice, Multilingual | 0/10 | 0/10 | GGML | MIT | [HF](https://huggingface.co/ggerganov/whisper.cpp) |
| `whisper-large-v3` | Whisper Large V3 (Voice) | 1.55B | 2.9 | Small | Fast | 6 | Voice, Multilingual | 0/10 | 0/10 | GGML | MIT | [HF](https://huggingface.co/ggerganov/whisper.cpp) |

### TinyLlama (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `tinyllama-1.1b` | TinyLlama 1.1B | 1.1B | 0.6 | Tiny | Instant | 1 | Chat | 2/10 | 2/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF) |

### Google Gemma (3)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `codegemma-2b` | CodeGemma 2B (Tiny Coder) | 2B | 0.8 | Tiny | Instant | 2 | Coding | 4/10 | 2/10 | Q8_0 | Gemma License | [HF](https://huggingface.co/google/codegemma-2b-GGUF) |
| `codegemma-7b` | CodeGemma 7B Instruct | 7B | 4.1 | Medium | Moderate | 6 | Coding, Chat | 7/10 | 5/10 | Q4_K_M | Gemma License | [HF](https://huggingface.co/bartowski/codegemma-7b-it-GGUF) |
| `gemma-3-27b` | Google Gemma 3 27B IT | 27B | 16.6 | XLarge | Slow | 20 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | Gemma License | [HF](https://huggingface.co/bartowski/google_gemma-3-27b-it-GGUF) |

### Stability AI (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `stable-code-3b` | Stable Code 3B (Tiny Coder) | 3B | 1.1 | Small | Fast | 2 | Coding | 5/10 | 2/10 | Q5_K_M | Stability AI License | [HF](https://huggingface.co/bartowski/stable-code-instruct-3b-GGUF) |

### IBM Granite (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `granite-code-8b` | IBM Granite Code 8B | 8B | 4.6 | Medium | Moderate | 6 | Coding | 6/10 | 4/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/ibm-granite/granite-8b-code-instruct-4k-GGUF) |
| `granite-code-20b` | IBM Granite Code 20B | 20B | 11.5 | Large | Slow | 14 | Coding | 7/10 | 5/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/bartowski/granite-20b-code-instruct-GGUF) |

### BigCode (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `starcoder2-7b` | StarCoder2 7B | 7B | 4.7 | Medium | Moderate | 6 | Coding | 6/10 | 3/10 | Q5_K_M | BigCode OpenRAIL-M | [HF](https://huggingface.co/second-state/StarCoder2-7B-GGUF) |
| `starcoder2-15b` | StarCoder2 15B | 15B | 8.6 | Large | Slow | 12 | Coding | 7/10 | 4/10 | Q4_K_M | BigCode OpenRAIL-M | [HF](https://huggingface.co/second-state/StarCoder2-15B-GGUF) |

### Meta Llama (5)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `llama3.3-8b-reasoning` | Llama 3.3 8B Reasoning (Uncensored) | 8B | 6.1 | Large | Moderate | 8 | Coding, Reasoning, Writing, Chat | 6/10 | 8/10 | Q6_K | Llama 3 Community License | [HF](https://huggingface.co/mradermacher/Llama3.3-8B-Instruct-Thinking-Heretic-Uncensored-Claude-4.5-Opus-High-Reasoning-i1-GGUF) |
| `codellama-13b` | Meta Code Llama 13B | 13B | 7.3 | Large | Moderate | 10 | Coding | 7/10 | 5/10 | Q4_K_M | Llama 2 Community License | [HF](https://huggingface.co/TheBloke/CodeLlama-13B-Instruct-GGUF) |
| `codellama-34b` | Code Llama 34B | 34B | 19.0 | XLarge | Slow | 24 | Coding | 8/10 | 5/10 | Q4_K_M | Llama 2 Community License | [HF](https://huggingface.co/TheBloke/CodeLlama-34B-Instruct-GGUF) |
| `llama-3.1-70b` | Meta Llama 3.1 70B Instruct | 70B | 42.5 | XLarge | Slow | 48 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | Llama 3.1 Community License | [HF](https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF) |
| `llama4-scout-17b` | Meta Llama 4 Scout 17B (MoE) | 109B (17B active) | 65.3 | XLarge | Slow | 72 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 9/10 | Q4_K_M | Llama 4 Community License | [HF](https://huggingface.co/unsloth/Llama-4-Scout-17B-16E-Instruct-GGUF) |

### Google Gemma 3 (3)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `gemma-3-1b-it` | Gemma 3 1B Instruct | 1B | 0.8 | Tiny | Instant | 2 | Writing, Multilingual, Chat | 3/10 | 4/10 | Q4_K_M | Gemma License | [HF](https://huggingface.co/unsloth/gemma-3-1b-it-GGUF) |
| `gemma-3-4b-it` | ★ Gemma 3 4B Instruct | 4B | 2.5 | Small | Fast | 4 | Coding, Reasoning, Writing, Multilingual, Chat | 6/10 | 7/10 | Q4_K_M | Gemma License | [HF](https://huggingface.co/bartowski/google_gemma-3-4b-it-GGUF) |
| `gemma-3-12b-it` | ★ Gemma 3 12B Instruct | 12B | 7.3 | Large | Moderate | 10 | Coding, Reasoning, Writing, Multilingual, Chat | 7/10 | 8/10 | Q4_K_M | Gemma License | [HF](https://huggingface.co/bartowski/google_gemma-3-12b-it-GGUF) |

### Meta Llama 3.2 (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `llama-3.2-1b-instruct` | Llama 3.2 1B Instruct | 1B | 0.75 | Tiny | Instant | 2 | Writing, Multilingual, Chat | 3/10 | 3/10 | Q4_K_M | Llama 3.2 Community | [HF](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF) |
| `llama-3.2-3b-instruct` | ★ Llama 3.2 3B Instruct | 3B | 1.9 | Small | Fast | 4 | Coding, Reasoning, Writing, Multilingual, Chat | 5/10 | 6/10 | Q4_K_M | Llama 3.2 Community | [HF](https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF) |

### HuggingFace SmolLM2 (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `smollm2-1.7b-instruct` | SmolLM2 1.7B Instruct | 1.7B | 1.0 | Small | Fast | 2 | Coding, Writing, Chat | 5/10 | 4/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF) |

### Microsoft Phi-4 (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `phi-4-mini-3.8b` | ★ Microsoft Phi-4 Mini 3.8B | 3.8B | 2.3 | Small | Fast | 4 | Coding, Reasoning, Writing, Multilingual, Chat | 7/10 | 8/10 | Q4_K_M | MIT | [HF](https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF) |

### IBM Granite 3.1 (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `granite-3.1-2b-instruct` | IBM Granite 3.1 2B Instruct | 2B | 1.3 | Small | Fast | 3 | Coding, Reasoning, Writing, Multilingual, Chat | 5/10 | 5/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/bartowski/granite-3.1-2b-instruct-GGUF) |
| `granite-3.1-8b-instruct` | IBM Granite 3.1 8B Instruct | 8B | 4.9 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 7/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/bartowski/granite-3.1-8b-instruct-GGUF) |

### Alibaba Qwen 3 (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `qwen3-1.7b` | Qwen3 1.7B | 1.7B | 1.1 | Small | Fast | 2 | Coding, Reasoning, Writing, Multilingual, Chat | 5/10 | 6/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF) |

### MeetKai Functionary (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `functionary-small-3.1-8b` | Functionary Small v3.1 8B | 8B | 4.9 | Medium | Moderate | 8 | Coding, Chat | 7/10 | 5/10 | Q4_K_M | Llama 3.1 Community | [HF](https://huggingface.co/bartowski/functionary-small-v3.1-GGUF) |

### Xiaomi MiMo (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `mimo-v2-flash` | ★ Xiaomi MiMo V2 Flash (Leaderboard #1) | 7B | 4.5 | Medium | Moderate | 8 | Coding, Reasoning, Writing, Multilingual, Chat | 8/10 | 8/10 | Q4_K_M | MIT | [HF](https://huggingface.co/unsloth/MiMo-V2-Flash-GGUF) |

### Alibaba Qwen 3.6 (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `qwen3.6-27b` | ★ Qwen 3.6 27B (Leaderboard #2 family) | 27B | 16.5 | XLarge | Slow | 24 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF) |

### DeepSeek V3 (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `deepseek-v3.2` | ★ DeepSeek V3.2 (Leaderboard #3) [XLarge] | 671B (MoE 37B active) | 380.0 | XLarge | Slow | 256 | Coding, Reasoning, Writing, Multilingual, Chat | 10/10 | 10/10 | Q4_K_M | DeepSeek License | [HF](https://huggingface.co/unsloth/DeepSeek-V3.2-GGUF) |

### MiniMax (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `minimax-m2` | ★ MiniMax M2 (Leaderboard #5) [XLarge] | 230B (MoE) | 130.0 | XLarge | Slow | 96 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | MIT | [HF](https://huggingface.co/unsloth/MiniMax-M2-GGUF) |
| `minimax-m2.7` | ★ MiniMax M2.7 (Leaderboard #8 newer) [XLarge] | 230B (MoE) | 135.0 | XLarge | Slow | 96 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 10/10 | Q4_K_M | MIT | [HF](https://huggingface.co/unsloth/MiniMax-M2.7-GGUF) |

### StepFun (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `step-3.5-flash` | ★ StepFun Step 3.5 Flash (Leaderboard #9) | 10B (VL) | 11.0 | Large | Slow | 14 | Coding, Reasoning, Writing, Multilingual, Chat | 7/10 | 8/10 | Q8_0 | Apache 2.0 | [HF](https://huggingface.co/stepfun-ai/Step-3.5-Flash-GGUF-Q8_0) |

### Z.AI GLM (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `glm-5.1` | ★ Z.AI GLM 5.1 (Leaderboard #14/#20) [XLarge] | 355B (MoE) | 200.0 | XLarge | Slow | 128 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 9/10 | Q4_K_M | MIT | [HF](https://huggingface.co/unsloth/GLM-5.1-GGUF) |

### Moonshot Kimi (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `kimi-k2.6` | ★ Moonshot Kimi K2.6 (Leaderboard #15) [XLarge] | 1T (MoE 32B active) | 350.0 | XLarge | Slow | 384 | Coding, Reasoning, Writing, Multilingual, Chat | 10/10 | 10/10 | Q2_K_XL | Modified MIT | [HF](https://huggingface.co/unsloth/Kimi-K2.6-GGUF) |

### OpenAI gpt-oss (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `gpt-oss-120b` | ★ OpenAI gpt-oss-120b (Leaderboard #17) [XLarge] | 120B (MoE) | 65.0 | XLarge | Slow | 80 | Coding, Reasoning, Writing, Multilingual, Chat | 9/10 | 10/10 | MXFP4_MOE | Apache 2.0 | [HF](https://huggingface.co/bartowski/openai_gpt-oss-120b-GGUF) |

### Alibaba Qwen 3 Coder (1)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `qwen3-coder-30b-a3b` | ★ Qwen 3 Coder 30B-A3B Instruct (MoE) | 30B (3B active, MoE) | 17.3 | XLarge | Slow | 20 | Coding, Reasoning, Multilingual, Chat | 10/10 | 8/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF) |

### 01.AI Yi-Coder (2)

| ID | Display | Params | Size (GB) | Tier | Speed | RAM (GB) | Capabilities | Coding | Reasoning | Quant | License | Download |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `yi-coder-1.5b` | Yi-Coder 1.5B Chat (tiny) | 1.5B | 0.9 | Tiny | Instant | 2 | Coding, Multilingual, Chat | 6/10 | 4/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/MaziyarPanahi/Yi-Coder-1.5B-Chat-GGUF) |
| `yi-coder-9b` | Yi-Coder 9B Chat | 9B | 4.96 | Medium | Moderate | 8 | Coding, Reasoning, Multilingual, Chat | 8/10 | 7/10 | Q4_K_M | Apache 2.0 | [HF](https://huggingface.co/MaziyarPanahi/Yi-Coder-9B-Chat-GGUF) |

## Filters (interactive picker)
The picker chains four optional filters; press Enter at any prompt to skip.
1. **RAM** — auto-detects system RAM, presets 4/8/16/32/64 GB, free input.
2. **Size** — Tiny <1, Small <3, Medium <6, Large <12, XLarge 12+ GB.
3. **Speed** — Instant <1, Fast <3, Moderate <8, Slow 8+ GB.
4. **Capability** — Coding / Reasoning / Writing / Chat / Voice / Multilingual.

After filtering, surviving models are re-indexed `1..N` so you can multi-select with `1,3,5` or `1-4`.

## Datacenter-class models (>=64 GB RAM)
11 models require workstation/server hardware:

- `deepseek-v4-pro` — ★ DeepSeek V4 Pro (671B MoE, datacenter) — **432.7 GB file, 512 GB RAM**
- `deepseek-v3.2` — ★ DeepSeek V3.2 (Leaderboard #3) [XLarge] — **380.0 GB file, 256 GB RAM**
- `kimi-k2.6` — ★ Moonshot Kimi K2.6 (Leaderboard #15) [XLarge] — **350.0 GB file, 384 GB RAM**
- `glm-5.1` — ★ Z.AI GLM 5.1 (Leaderboard #14/#20) [XLarge] — **200.0 GB file, 128 GB RAM**
- `minimax-m2.7` — ★ MiniMax M2.7 (Leaderboard #8 newer) [XLarge] — **135.0 GB file, 96 GB RAM**
- `minimax-m2` — ★ MiniMax M2 (Leaderboard #5) [XLarge] — **130.0 GB file, 96 GB RAM**
- `deepseek-v4-flash` — ★ DeepSeek V4 Flash (MoE, datacenter) — **80.8 GB file, 96 GB RAM**
- `qwen3.5-122b-a10b` — Qwen 3.5 122B-A10B (Max MoE) — **76.5 GB file, 80 GB RAM**
- `nemotron-3-super-120b` — ★ NVIDIA Nemotron 3 Super 120B-A12B (Leaderboard #12) [XLarge] — **70.0 GB file, 80 GB RAM**
- `llama4-scout-17b` — Meta Llama 4 Scout 17B (MoE) — **65.3 GB file, 72 GB RAM**
- `gpt-oss-120b` — ★ OpenAI gpt-oss-120b (Leaderboard #17) [XLarge] — **65.0 GB file, 80 GB RAM**

## See also
- [`scripts/43-install-llama-cpp/readme.md`](readme.md) — installer script docs
- [`scripts/models/`](../models/) — unified backend orchestrator (llama.cpp + Ollama)
- [`scripts/42-install-ollama/readme.md`](../42-install-ollama/readme.md) — Ollama daemon backend

---
*Generated from `models-catalog.json` v4.1.2 — 96 models, 35 families*