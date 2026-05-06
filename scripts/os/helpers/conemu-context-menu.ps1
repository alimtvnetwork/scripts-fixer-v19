<#
.SYNOPSIS
    os conemu-context-menu -- Manage the "Open ConEmu Here" Windows
    folder right-click entries (install / uninstall / restore).

.DESCRIPTION
    Thin convenience wrapper that delegates to script
    `scripts/59-conemu-context-menu/run.ps1`. Mirrors the shape of
    `os fix-vscode-context-menu` so users get one consistent surface for
    every right-click integration: snapshots before delete, dry-run
    previews, and a copy-paste rollback path.

    Subcommand aliases exposed via flags so users don't need to know
    script 59 exists:

        (no arg)              -> install (add registry entries)
        install               -> install (explicit)
        --uninstall           -> uninstall (snapshots + removes entries)
        --dry-run-uninstall   -> preview uninstall (no writes)
        --restore             -> re-import the newest .reg snapshot
        --restore --dry-run   -> preview restore (no writes)
        --list-snapshots      -> list newest-first .reg backups
        --snapshot-file <p>   -> explicit snapshot for --restore

    Refuses cleanly on non-Windows so cross-OS callers see actionable text
    instead of a cryptic registry error (CODE RED rule).

.NOTES
    Per project rule: every file/path error must include exact path and
    failure reason (uses Write-FileError when available).
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$osDir      = Split-Path -Parent $helpersDir
$scriptsDir = Split-Path -Parent $osDir
$sharedDir  = Join-Path $scriptsDir "shared"

. (Join-Path $sharedDir "logging.ps1")

# -- OS gate ----------------------------------------------------------------
$isWindowsHost = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $isWindowsHost = $IsWindows }
if (-not $isWindowsHost) {
    Write-Host ""
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host "'os conemu-context-menu' is Windows-only (failure: current OS is not Windows)."
    Write-Host "          Reason: it writes to HKEY_CLASSES_ROOT registry keys that exist only on Windows." -ForegroundColor Gray
    exit 2
}

# -- Locate script 59 -------------------------------------------------------
$script59Dir = Join-Path $scriptsDir "59-conemu-context-menu"
$script59Run = Join-Path $script59Dir "run.ps1"
if (-not (Test-Path -LiteralPath $script59Run)) {
    if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
        Write-FileError `
            -FilePath  $script59Run `
            -Operation "load" `
            -Reason    "script 59 entry script is missing from the repository" `
            -Module    "os conemu-context-menu"
    } else {
        Write-Host ""
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "Cannot find script 59 entry: $script59Run"
        Write-Host "          Reason: file does not exist (failure: missing repo asset)." -ForegroundColor Gray
    }
    exit 2
}

# -- Argument parser --------------------------------------------------------
$subCommand   = $null
$snapshotFile = ''
$wantsDryRun  = $false
$passthrough  = @()

if ($null -ne $Rest -and $Rest.Count -gt 0) {
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        $raw = $Rest[$i]
        if ($null -eq $raw) { continue }
        $tok = "$raw".Trim()
        $low = $tok.ToLower()
        switch -Regex ($low) {
            '^(--?help|/\?|-h|help|\?)$'                      { $subCommand = 'help'; break }
            '^(install|--?install)$'                          { if ($null -eq $subCommand) { $subCommand = 'install' } ; break }
            '^(uninstall|--?uninstall|remove|--?remove|rollback|--?rollback)$' {
                if ($null -eq $subCommand) { $subCommand = 'uninstall' }
                break
            }
            '^(--?dry-run-uninstall|dry-run-uninstall|--?preview-uninstall|preview-uninstall)$' {
                if ($null -eq $subCommand) { $subCommand = 'dry-run-uninstall' }
                break
            }
            '^(restore|--?restore|restore-snapshot)$' {
                if ($null -eq $subCommand) { $subCommand = 'restore' }
                break
            }
            '^(--?list-snapshots|list-snapshots|--?snapshots|snapshots)$' {
                if ($null -eq $subCommand) { $subCommand = 'list-snapshots' }
                break
            }
            '^(--?dry-run|dry-run|--?whatif|whatif)$'         { $wantsDryRun = $true; break }
            '^(--?snapshot-file|snapshot-file|--?file|file)$' {
                $i++
                if ($i -lt $Rest.Count) { $snapshotFile = "$($Rest[$i])" }
                break
            }
            default {
                # Pass unknown tokens through so future script-59 flags work.
                $passthrough += $tok
            }
        }
    }
}

if ($null -eq $subCommand) { $subCommand = 'install' }

# Friendly banner
Write-Host ""
Write-Host "  os conemu-context-menu" -ForegroundColor Cyan
Write-Host "  ======================" -ForegroundColor DarkGray
Write-Host ("  Mode      : " + $subCommand) -ForegroundColor Yellow
Write-Host ("  Delegates : " + $script59Run) -ForegroundColor DarkGray
if ($wantsDryRun)                              { Write-Host  "  Dry-run   : on" -ForegroundColor DarkGray }
if (-not [string]::IsNullOrWhiteSpace($snapshotFile)) {
    Write-Host ("  Snapshot  : " + $snapshotFile) -ForegroundColor DarkGray
}
if ($passthrough.Count -gt 0) {
    Write-Host ("  Forward   : " + ($passthrough -join ' ')) -ForegroundColor DarkGray
}
Write-Host ""

# Build the argv for script 59. It accepts:
#   <Command> [<Path>] [-SnapshotFile <p>] [-DryRun] [-Help] [Rest...]
# We always keep the second positional ($Path) empty and push everything
# else through named parameters so script 59 can opt into them cleanly.
try {
    if ($subCommand -eq 'help') {
        & $script59Run -Help
        exit $LASTEXITCODE
    }

    $named = @{}
    if ($wantsDryRun)                                      { $named['DryRun']       = $true }
    if (-not [string]::IsNullOrWhiteSpace($snapshotFile))  { $named['SnapshotFile'] = $snapshotFile }

    if ($passthrough.Count -gt 0) {
        & $script59Run $subCommand @named @passthrough
    } else {
        & $script59Run $subCommand @named
    }
    exit $LASTEXITCODE
} catch {
    Write-Host ""
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host "os conemu-context-menu failed while invoking script 59."
    Write-Host ("          Script : " + $script59Run) -ForegroundColor Gray
    Write-Host ("          Reason : " + $_.Exception.Message) -ForegroundColor Gray
    exit 1
}
