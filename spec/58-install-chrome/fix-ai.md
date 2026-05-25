# Chrome `fix-ai` — disable built-in AI and reclaim disk space

## Problem

Chrome (M127+) silently downloads the **Optimization Guide On Device Model**
(Gemini Nano) as a Component Updater payload. The model is **2–4 GB** and lives
under the user's profile, even when the user never opens any AI surface
(Help me write, Tab Organizer, Smart Compose, etc.).

Symptom: `%LOCALAPPDATA%\Google\Chrome\User Data\OptimizationGuideOnDeviceModel\`
grows to several GB; component-updater keeps refreshing it after each Chrome
launch, so a one-time delete does not stick.

## Goal

Provide a single command —

```
.\run.ps1 chrome fix-ai
.\run.ps1 install chrome fix-ai     # alias
```

— that:

1. **Disables the on-device model** so Chrome stops downloading and refreshing it.
2. **Preserves existing `chrome://flags`** the user already configured — we only
   touch the AI-related entries, never reset the rest of `enabled_labs_experiments`.
3. **Deletes the cached model files** to reclaim disk space, and reports bytes freed.
4. **Verifies** the state on the next run and prints what is still active.

## Mechanism (Windows)

Three layers — applied together so component-updater cannot resurrect the model:

### 1. Enterprise policies (HKLM, authoritative)

Written under `HKLM:\SOFTWARE\Policies\Google\Chrome` (REG_DWORD = 1 means
"disabled" for these settings; see Chrome Enterprise policy list):

| Policy                                 | Value | Effect                                    |
|----------------------------------------|------:|-------------------------------------------|
| `GenAiDefaultSettings`                 | 1     | Master switch: all Gen-AI features off    |
| `GenAILocalFoundationalModelSettings`  | 1     | Blocks the on-device model download       |
| `HelpMeWriteSettings`                  | 1     | Disables Compose/Help-me-write            |
| `CreateThemesSettings`                 | 1     | Disables AI theme creator                 |
| `TabOrganizerSettings`                 | 1     | Disables AI tab grouping                  |
| `TabCompareSettings`                   | 1     | Disables AI tab compare                   |
| `HistorySearchSettings`                | 1     | Disables AI history search                |
| `AutofillPredictionSettings`           | 1     | Disables AI form-fill predictions         |

HKLM requires admin. If we are not elevated we fall through to layer 2 + 3 and
print a clear notice that the policy half was skipped.

### 2. Local State `enabled_labs_experiments` patch (per-user, no admin)

`%LOCALAPPDATA%\Google\Chrome\User Data\Local State` is JSON. We:

- Read it (UTF-8, BOM-safe).
- Take a `.bak-fixai-<timestamp>` snapshot next to it.
- Merge into `browser.enabled_labs_experiments` (preserving every other entry):
  - `optimization-guide-on-device-model@2` → **Disabled** (slot 2)
  - `prompt-api-for-gemini-nano@2`
  - `summarization-api-for-gemini-nano@2`
  - `writer-api-for-gemini-nano@2`
  - `rewriter-api-for-gemini-nano@2`
- Refuses to run while `chrome.exe` is alive (race-free; Chrome rewrites
  Local State on shutdown and would clobber our patch).

### 3. Model cache sweep

Delete the on-disk artifacts (sizes summed and reported):

- `%LOCALAPPDATA%\Google\Chrome\User Data\OptimizationGuideOnDeviceModel\`
- `%LOCALAPPDATA%\Google\Chrome\User Data\OptGuideOnDeviceModel\`  (legacy)
- `%LOCALAPPDATA%\Google\Chrome\User Data\component_crx_cache\` entries whose
  manifest declares `optimization_guide_on_device_model`.

## Flags / CLI surface

```
.\run.ps1 chrome fix-ai                # apply all three layers
.\run.ps1 chrome fix-ai --dry-run      # report only, change nothing
.\run.ps1 chrome fix-ai --verify       # print current state (policy + flags + cache size)
.\run.ps1 chrome fix-ai --restore      # revert policies + restore last .bak Local State
.\run.ps1 chrome fix-ai -Yes           # skip the "Chrome must be closed" confirm
```

`--dry-run` and `--verify` never require admin.

## Triple-path logging

Per project rule, every run emits the canonical Source / Temp / Target trio:

- **Source**: `HKLM:\SOFTWARE\Policies\Google\Chrome` + Local State path
- **Temp**: `<Local State>.bak-fixai-<timestamp>`
- **Target**: model cache root that was swept

## Output contract

End-of-run colored summary table:

```
  [ OK ] Policies set        : 8/8           (HKLM, admin OK)
  [ OK ] Flags patched       : 5/5           (Local State preserved)
  [ OK ] Cache swept         : 3.42 GB freed (OptimizationGuideOnDeviceModel)
  [ == ] chrome.exe          : not running
```

`status` field in the JSON log: `ok` | `partial` (policy half skipped) | `fail`.

## Failure modes — CODE RED file-path logging

Every miss includes the **exact path** and **reason**:

- `Local State not found at: <path>  (reason: Chrome never launched on this profile)`
- `Cannot write HKLM policy <key>  (reason: not elevated — re-run from admin shell)`
- `Refusing to patch Local State: chrome.exe is alive (PID <n>) — close Chrome and retry`
- `Cache root missing: <path>  (reason: already clean)`

## Restore path

`--restore` reverses everything:

1. Deletes the eight HKLM policy values (best-effort; logs each).
2. Restores the most recent `Local State.bak-fixai-*` over `Local State`.
3. Leaves the cache alone (it will redownload only if the user manually
   re-enables the flag).
