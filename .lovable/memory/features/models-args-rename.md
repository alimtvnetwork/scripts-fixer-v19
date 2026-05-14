---
name: Models dispatcher $Args→$Rest rename
description: Why scripts/models/run.ps1 must NEVER use $Args as a script-param name. Splatted positional tokens collapsed under StrictMode + advanced param block, breaking `models-download <n>`.
type: feature
---

# Models dispatcher: `$Args` is reserved — use `$Rest`

## Symptom

`.\run.ps1 models-download 93` printed the **full catalog list** instead of
downloading model #93. Same for any `models download <n|csv>` call routed
through the top-level `models-download` alias.

## Root cause

`scripts/models/run.ps1` declared its remaining-args param as
`[string[]]$Args` with `[Parameter(Position=0, ValueFromRemainingArguments=$true)]`
and `Set-StrictMode -Version Latest`.

`$Args` is a PowerShell **automatic variable**. With an
`[Parameter()]`-attributed (advanced) param block + StrictMode, splatted
positional tokens from `& $modelsScript @mdArgs` (where
`@mdArgs = @("download","93")`) bound only the FIRST token to the declared
`$Args` param reliably. The second token ("93") collapsed, so:

- `$secondArg` → `""`
- `$isDownloadMode` → `$false` (because `$firstArg.ToLower() -eq "download"` was still true,
  but `$csv = $secondArg` was empty AND `$flagsActive = $false`, so the
  warning path triggered… and worse, in some shells the binder dropped
  *both* tokens and the script fell straight through to the default
  "show full catalog" branch at line ~463.)

Either way: list shown, no download.

## Fix

Renamed the script param `$Args` → `$Rest` in
`scripts/models/run.ps1`. Renamed all body references. Also renamed
`Read-ModelFlagOptions`'s `$Args` → `$Argv` in
`scripts/models/helpers/filters.ps1` for the same reason (and updated the
call site to `-Argv $Rest`).

## Rule (CODE RED)

**Never** name a script/function param `$Args`, `$Input`, `$PSItem`,
`$_`, `$Error`, `$Host`, `$MyInvocation`, `$PSScriptRoot`, `$PSCommandPath`,
`$PWD`, `$LASTEXITCODE`, `$true`, `$false`, `$null` — they are automatic /
reserved. Use `$Rest`, `$Argv`, `$Items`, `$Tokens`, `$Payload`, etc.

## Verification

After fix, `.\run.ps1 models-download 93` should:

1. Print the triple-path block (Source / Temp / Target).
2. Print `[ MODEL DOWNLOAD PATHS ]`.
3. Resolve index 93 against the combined catalog and dispatch to
   `Invoke-BackendInstall` for the matching model.

Bumped patch: `version.json` → `1.5.9`.
