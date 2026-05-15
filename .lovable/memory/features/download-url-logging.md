---
name: Download failure URL logging (CODE RED extension)
description: Every model-download failure path logs the upstream URL + target on console and in .logs/*-error.json
type: feature
---

# Download failure URL logging

Extension of the CODE RED file-error rule. Any failed download (per-attempt, post-verify, checksum mismatch, retries-exhausted) MUST surface the source URL so the user can curl it manually.

## Locations

### Windows — `scripts/43-install-llama-cpp/helpers/model-picker.ps1`

Lines 831–836, 923–991. All failure branches now emit:
- A console `URL: <model.downloadUrl>` line via `Write-Log`
- The URL inside the `Write-FileError` Reason field

Branches covered: batch post-verify fail, per-attempt post-check fail, per-attempt downloader rc=fail, final "FAILED after retries", checksum mismatch, no-checksum-required-fail, final FAILED-checksum.

### Linux — `scripts-linux/43-install-llama-cpp/model-pull.sh`

Lines 440–462. Mirrors the Windows behaviour: `log_warn "          URL: $url"` plus url in `log_file_error` Reason for post-check fail, download fail, and end-of-retries block.

## Range / catalog miss messages

`scripts/models/run.ps1` and `scripts/models/helpers/picker.ps1` were also fixed in the same cycle:
- `Count` property crash at picker line 302 → guarded for non-array results
- "None of the requested model ids matched any catalog" → now reports `Catalog has N model(s) -- valid index range is 1..N`

## Versions

Introduced v1.5.26 (URL logging) and v1.5.25 (Count + range message fix).

Always include URL on download failures. Never silently fail.
