# PowerShell Error Management — Specification

> **Status:** Authoritative. Supersedes any `readme.md` previously in this folder.
> **Audience:** Any author (human or AI, including low-context agents) writing,
> reviewing, or auto-generating a PowerShell script in this repository.
> **Companion document:** `spec/error-management/gap-audit.md` (audit + score).
>
> **CODE RED — the one rule that overrides everything else.**
> Every file/path failure MUST log:
> 1. the **exact resolved path** that was attempted, and
> 2. the **exact reason** it failed (the underlying exception text, not a paraphrase),
> 3. via the dedicated helper `Write-FileError` (never via `Write-Log` alone,
>    never via `Write-Host`, never via `throw`).
>
> A script that violates CODE RED is **non-conformant** and must be rejected
> at review even if all other tests pass.

---

## 0. Glossary (read first)

| Term                   | Meaning                                                                                       |
|------------------------|-----------------------------------------------------------------------------------------------|
| **Script**             | An entry-point under `scripts/<NN>-<name>/run.ps1` or `scripts/os/run.ps1`.                   |
| **Helper / category**  | A dot-sourced `.ps1` invoked by a script (e.g. `clean-categories/wu-download.ps1`).           |
| **Logger**             | `scripts/shared/logging.ps1`. The ONLY sanctioned source of `Write-Log` / `Write-FileError`.  |
| **Identity block**     | The 8 fields (`projectVersion`, `gitSha`, ...) auto-stamped on every JSON log.                |
| **Sidecar**            | `.logs/<NN>/<script>-error.json` — written ONLY when `overallStatus != "ok"`.                 |
| **Step ledger**        | A list of `{ Step; Path; Reason }` entries collected by multi-step scripts (e.g. `os clean`). |
| **CODE RED**           | Tag applied to file/path failures. They MUST go through `Write-FileError`.                    |

---

## 1. Folder structure for a new script

```
scripts/
  NN-my-script/
    run.ps1                  # entry point. param([string[]]$Argv = @())
    config.json              # static config (paths, version pins, flags)
    log-messages.json        # all human-facing strings, keyed by message id
    readme.md                # what the script does, flags, examples
    helpers/                 # category/sub-step helpers (optional)
      <name>.ps1
  shared/                    # repo-wide reusable helpers (DO NOT duplicate)
    logging.ps1              # Initialize-Logging / Write-Log / Write-FileError / Save-LogFile
    json-utils.ps1           # Import-JsonConfig (validates + reports trimmed FilePath)
    confirm-prompt.ps1       # Confirm-DestructiveAction (--yes / --non-interactive)
    admin-check.ps1          # Test-IsElevated / Assert-Elevated
    install-paths.ps1        # Write-InstallPaths (triple-path stamp)
.logs/                       # output directory for JSON logs (auto-created)
  <NN>/
    <scriptname>.json        # always present
    <scriptname>-error.json  # only present when overallStatus != "ok"
spec/
  <NN>-my-script/readme.md   # design spec (this folder is the contract)
```

**Rules:**

1. **No string literals in `run.ps1` for human output.** Every user-visible
   message lives in `log-messages.json` and is loaded via `Import-JsonConfig`.
2. **No business logic in `log-messages.json`.** It is a flat string table.
3. **Always dot-source `scripts/shared/logging.ps1` first**, then call
   `Initialize-Logging -ScriptName "<name>"` exactly once near the top.
4. **Always end with `Save-LogFile -Status <ok|warn|fail|partial|skip>`**,
   even on the failure path. Without it the JSON log is never written.
5. **One logger per process.** Helpers MUST NOT call `Initialize-Logging`
   themselves — they piggyback on the parent script's logger.

---

## 2. The mandatory script envelope

Every entry-point script must contain these calls in this order:

```powershell
$ErrorActionPreference = "Continue"          # never "Stop" at top level
Set-StrictMode -Version Latest               # non-negotiable

$here   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$shared = Join-Path (Split-Path -Parent $here) "shared"
. (Join-Path $shared "logging.ps1")
. (Join-Path $shared "json-utils.ps1")

$msgs = Import-JsonConfig (Join-Path $here "log-messages.json")
Initialize-Logging -ScriptName "my-script"

try {
    # ... work ...
    Save-LogFile -Status "ok"
    exit 0
} catch {
    # Top-level catch is the safety net. Per-file errors must already have
    # been routed through Write-FileError (see section 4) BEFORE we get here.
    Write-Log ("Top-level failure: {0}" -f $_.Exception.Message) -Level "fail"
    Save-LogFile -Status "fail"
    exit 1
}
```

If you forget the `try / Save-LogFile / exit` envelope, the run will look
"successful" to the orchestrator even on a crash, and the sidecar will
never be written.

---

## 3. Log levels and what they mean

| Level    | When to use                                                      | Promoted to sidecar? |
|----------|------------------------------------------------------------------|----------------------|
| `info`   | Normal progress narration. The default.                          | No                   |
| `ok`     | A discrete unit of work succeeded (`Installed git 2.45.1`).      | No                   |
| `warn`   | Recoverable problem; the script continued.                       | Yes (in `warnings`)  |
| `fail`   | Unrecoverable problem in this category/step. Caller continues.   | Yes (in `errors`)    |
| `error`  | Synonym for `fail`. Prefer `fail` for new code.                  | Yes (in `errors`)    |

Pick exactly one. A failure logged at `warn` will NOT be promoted into the
`-error.json` sidecar and CI will miss it.

---

## 4. CODE RED — every file/path error MUST use `Write-FileError`

If your script touches a file, opens a stream, copies, moves, deletes,
extracts, parses JSON, resolves a path, reads the registry, or runs an
external tool that writes a file — and that operation can fail — you MUST
report the failure through `Write-FileError`.

### Signature

```powershell
Write-FileError `
    -FilePath  <string>  `   # exact resolved path that was attempted
    -Operation <string>  `   # see allow-list below
    -Reason    <string>  `   # human-readable explanation (usually $_.Exception.Message)
   [-Module    <string>] `   # auto-detected from call stack if omitted
   [-Fallback  <string>]     # what we did to recover (if anything)
```

### `Operation` allow-list (from `scripts/shared/logging.ps1`)

```
read, write, copy, move, inject, load, extract, resolve,
install, delete, execute, download, parse,
backup, checksum, create, fetch, mkdir, symlink, verify,
configure-pnpm-store, create-pnpm-store-dir,
probe-prefix-drive, probe-prefix-write, create-prefix-dir,
resolve-npm, npm-mkdir-prefix, resolve-root,
validate, validate-goroot-layout, set-goroot,
invoke-child, batch-prepare, batch-verify
```

Unknown verbs are accepted (the call still emits the CODE RED line) but a
`[ WARN ]` is logged. Add your verb to the allow-list in `logging.ps1`
when you introduce a new one.

### Mandatory JSON shape of a file-error event

Every entry written to `.logs/<NN>/<script>-error.json` MUST carry:

```json
{
  "timestamp":      "2026-05-07T11:50:01.5508095+08:00",
  "level":          "fail",
  "type":           "file-error",
  "filePath":       "C:\\Windows\\SoftwareDistribution\\Download",
  "operation":      "delete",
  "reason":         "Access denied (locked or protected)",
  "module":         "wu-download.ps1",
  "fallback":       "wuauserv stopped, retried -- see warn line above",
  "message":        "[CODE RED] File error during delete: ...",
  "projectVersion": "1.1.1",
  "invokedFrom":    "run.ps1",
  "gitSha":         "d9d3ee90c118",
  "gitBranch":      "main",
  "scriptName":     "os-clean"
}
```

If any of `filePath`, `operation`, `reason`, or `module` is missing, the
log is **non-conformant**.

### Forbidden patterns

```powershell
# BAD: loses the path. The user cannot tell which file failed.
Write-Log "Could not read config" -Level "fail"

# BAD: loses the structured fields. The CI dashboard will not see this
#      as a file error.
Write-Log ("Failed: {0}" -f $_.Exception.Message) -Level "fail"

# BAD: no JSON at all.
Write-Host "Could not write $path" -ForegroundColor Red

# BAD: bubbles strict-mode crashes to the top.
$content = Get-Content $path                       # no -ErrorAction, no try/catch
```

### Required pattern

```powershell
try {
    Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
} catch {
    Write-FileError `
        -FilePath  $dst `
        -Operation "copy" `
        -Reason    $_.Exception.Message `
        -Fallback  "left $src in place; user can re-run with --force"
    # Decide locally: continue, return a failed result, or exit 1.
    return
}
```

### When you are inside a category helper that returns a result hashtable

Many sub-step helpers (e.g. `clean-categories/*.ps1`) build a `$result`
hashtable and return it to the orchestrator. In that case:

1. Call `Write-FileError` so the JSON sidecar gets the structured event.
2. Set `$result.Status = "fail"`.
3. Append a single human-readable line to `$result.Notes` so the
   orchestrator's per-row summary still shows the failure.

```powershell
try {
    Invoke-PathSweep -Path $target -Result $result -DryRun:$DryRun
} catch {
    Write-FileError `
        -FilePath  $target `
        -Operation "delete" `
        -Reason    $_.Exception.Message
    $result.Status = "fail"
    $result.Notes += ("Sweep failed at {0}: {1}" -f $target, $_.Exception.Message)
}
```

---

## 5. Per-step failure ledgers (multi-step scripts)

When a script runs many sub-steps in a loop (e.g. `os clean` walks ~60
clean categories), **collect per-step failures into a ledger** so the
final summary shows which step failed, on which path, with which reason.

```powershell
$stepFailures = New-Object System.Collections.Generic.List[hashtable]

function Add-StepFailure {
    param([string]$Step, [string]$Path, [string]$Reason)
    $stepFailures.Add(@{ Step = $Step; Path = $Path; Reason = $Reason }) | Out-Null
    Write-FileError -FilePath $Path -Operation "execute" -Reason $Reason -Module $Step
}

# ... at end of run ...
if ($stepFailures.Count -gt 0) {
    $result.Notes += ("----- failure summary ({0} item(s)) -----" -f $stepFailures.Count)
    foreach ($f in $stepFailures) {
        $result.Notes += ("  [{0}] path={1}" -f $f.Step, $f.Path)
        $result.Notes += ("        reason: {0}" -f $f.Reason)
    }
}
```

This is how the user tells "vdf parse failed on G:" apart from
"shadercache vanished".

---

## 6. StrictMode survival kit (the gotchas that bite every author)

We always run with `Set-StrictMode -Version Latest`. The seven rules below
prevent ~95 % of the `property 'Count' cannot be found` and
`variable cannot be retrieved` runtime crashes we have hit historically.

1. **Always wrap pipeline assignments in `@(...)`.** Otherwise `$x.Count`
   throws when the pipeline returns `$null` or a single scalar.
   ```powershell
   $files = @(Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue)
   if ($files.Count -eq 0) { return }
   ```
2. **Never read `$env:VAR` for a variable that may be unset.** Use
   `[Environment]::GetEnvironmentVariable("VAR")` instead — `$env:` throws
   under StrictMode when the env var doesn't exist.
   ```powershell
   $windir = [Environment]::GetEnvironmentVariable("WINDIR")
   if ([string]::IsNullOrWhiteSpace($windir)) { $windir = "C:\Windows" }
   ```
3. **Never put `\$VAR` inside a double-quoted string.** PowerShell's escape
   character is backtick, not backslash. `"$WINDIR\foo"` actually expands
   `$WINDIR` and crashes if it is unset. Use single quotes (`'...'`) or
   backtick-escape (``"`$WINDIR\foo"``).
4. **Test for hashtable keys before reading them.**
   ```powershell
   if ($hash.ContainsKey('foo')) { $x = $hash['foo'] }
   ```
5. **Wrap risky external work in `try/catch` that calls `Write-FileError`,
   then continues** — never let a single bad path abort the whole run.
6. **Use `-LiteralPath` for any path that may contain `[`, `]`, `*`, `?`.**
   Wildcard expansion silently swallows real paths.
7. **Disambiguate variable expansion in error messages.** Use `${path}`,
   not `$path:`, when the next character could be parsed as a drive
   qualifier (`$path:foo` becomes a PSDrive lookup and crashes).

---

## 7. `log-messages.json` schema

```jsonc
{
  "scriptName": "OS Clean",                    // appears in console banner + JSON
  "scriptId":   "65",                          // matches scripts/65-os-clean
  "synopsis":   "One-line summary",            // shown in --help
  "usage": [                                   // shown in --help
    ".\\run.ps1 -I 65",
    ".\\run.ps1 -I 65 -- --dry-run"
  ],
  "messages": {
    "PlanStart":  "Building plan...",          // referenced as $msgs.messages.PlanStart
    "PlanEmpty":  "Plan is empty.",
    "FileError":  "[FILE-ERROR] path={0} reason={1}"   // {0}, {1} are -f placeholders
  }
}
```

**Rules:**

- Keys are PascalCase, stable, never reordered.
- Use `{0}`, `{1}` placeholders, never inline interpolation.
- Never put a real path or version number in here — those come from
  `config.json` or runtime.

---

## 8. Bash sibling contract (Linux/macOS)

When the same script needs a Bash sibling under
`scripts-linux/<NN>-<name>/run.sh`, mirror the same JSON contract:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shared="$(cd "$here/../_shared" && pwd)"
. "$shared/logging.sh"           # log_info / log_warn / log_fail / file_error
. "$shared/json-utils.sh"        # import_json_config
. "$shared/install-paths.sh"     # write_install_paths

init_logging "my-script"

trap 'file_error "$LAST_PATH" "$LAST_OP" "$?" "$BASH_COMMAND"; save_log_file fail; exit 1' ERR

LAST_PATH="/etc/foo.conf"; LAST_OP="read"
content="$(cat "$LAST_PATH")"

save_log_file ok
```

The Bash `file_error` helper writes the **same JSON shape** as
`Write-FileError` (`filePath`, `operation`, `reason`, `module`,
`scriptName`, etc.) so a single dashboard can ingest both.

---

## 9. Console output rules

- **Use bracketed ASCII status glyphs**, never wide Unicode emoji:
  `[ OK ]`, `[FAIL]`, `[WARN]`, `[INFO]`, `[ == ]`, `[SKIP]`, `[ -- ]`.
- **No em-dashes** (`—`), no curly quotes, no box-drawing in banners —
  these break Windows ConHost in legacy code pages.
- Color via `Write-Host -ForegroundColor`, never raw ANSI escapes.
- The logger already prints colored prefixes; do not duplicate them.

---

## 10. Output artifacts — where logs land

After `Save-LogFile`:

```
.logs/
  <NN>/
    <scriptname>.json          # always present; contains every event
    <scriptname>-error.json    # written ONLY when overallStatus != "ok"
                               #   contains identity fields + full
                               #   errors[] / warnings[] arrays
    <scriptname>-summary.txt   # optional human-readable digest
```

Both JSON files include the canonical identity block at the top:

```json
{
  "projectVersion": "1.1.1",
  "invokedFrom":    "run.ps1",
  "gitSha":         "d9d3ee90c118",
  "gitShaFull":     "d9d3ee90c118b0af7a4e06b9bec72bdef32333b9",
  "gitBranch":      "main",
  "gitDirty":       false,
  "gitRemote":      "https://github.com/.../scripts-fixer-v18.git",
  "scriptName":     "os-clean",
  "overallStatus":  "partial",
  "startTime":      "2026-05-07T12:52:45.4351913+08:00",
  "endTime":        "2026-05-07T12:53:11.1641024+08:00",
  "duration":       25.73,
  "errorCount":     1,
  "warnCount":      0,
  "errors":         [ ... ],
  "warnings":       [ ... ]
}
```

If `errorCount > 0` and the `-error.json` sidecar is missing, the run is
**non-conformant**. The most common cause is forgetting `Save-LogFile` on
the failure path.

---

## 11. Decision tree — "do I call Write-Log or Write-FileError?"

```
Did the failure involve a path, file, directory, registry key, stream,
download URL, archive, JSON config, or external command that writes/reads a file?
                            │
            ┌───────────────┴───────────────┐
           YES                              NO
            │                                │
   Write-FileError                    Write-Log -Level <level>
   -FilePath <exact path>             (info / ok / warn / fail)
   -Operation <verb from allow-list>
   -Reason <exception text>
   [-Fallback <recovery action>]
```

When in doubt, use `Write-FileError`. It is never wrong to over-report a
file error; it is **always wrong** to under-report one.

---

## 12. Pre-commit checklist (pin this above your editor)

- [ ] `Set-StrictMode -Version Latest` at the top.
- [ ] Dot-sources `scripts/shared/logging.ps1`.
- [ ] Calls `Initialize-Logging -ScriptName "..."` exactly once
      (entry script only, NOT helpers).
- [ ] All user-visible strings come from `log-messages.json`.
- [ ] Every file/path failure goes through `Write-FileError` with
      `-FilePath`, `-Operation`, `-Reason`, optional `-Fallback`.
- [ ] Every pipeline assignment is wrapped in `@(...)`.
- [ ] No `$env:VAR` reads for variables that may be unset
      (use `[Environment]::GetEnvironmentVariable`).
- [ ] No `\$VAR` inside double-quoted strings.
- [ ] All path arguments use `-LiteralPath` (not `-Path`) where wildcards
      could appear.
- [ ] Multi-step loops collect per-step failures into a ledger and append
      it to `$result.Notes` (or print it before exit).
- [ ] Every exit path calls `Save-LogFile -Status <...>`.
- [ ] `.logs/<NN>/<script>-error.json` is produced whenever
      `overallStatus != "ok"`.
- [ ] Console output uses ASCII status glyphs (`[ OK ]`, `[FAIL]`, ...).
- [ ] If destructive: gated by `Confirm-DestructiveAction` from
      `scripts/shared/confirm-prompt.ps1` honouring `--yes / --non-interactive`.

If any box is unchecked, the script is **not ready for review**.
