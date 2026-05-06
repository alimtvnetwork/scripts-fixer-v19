# --------------------------------------------------------------------------
#  Script 59 -- ConEmu Context Menu
#  Adds "Open ConEmu Here" (normal + admin) to the right-click menu for
#  folders and folder backgrounds. Mirrors script 31 (PowerShell Here).
#
#  Subcommands:
#    install            (default) Add registry entries for all enabledModes
#    uninstall          Snapshot affected HKCR keys to a .reg file, then
#                       remove the entries. Prints copy-paste rollback hint.
#    dry-run-uninstall  Preview uninstall (no snapshot file kept beyond
#                       enumeration, no registry writes).
#    restore            Re-import the newest .reg snapshot from
#                       .logs/registry-backups/ (use -SnapshotFile to pick
#                       a specific one). Add -DryRun to preview.
#    list-snapshots     List newest-first conemu-context-menu .reg backups.
#    help               Show usage.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "install",

    [Parameter(Position = 1)]
    [string]$Path,

    [string]$SnapshotFile = '',
    [switch]$DryRun,
    [switch]$Help,
    [switch]$NonInteractive,
    [Alias('Yes','y')]
    [switch]$AssumeYes,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

$script:ScriptDir = $scriptDir

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "install-paths.ps1")
. (Join-Path $sharedDir "registry-backup.ps1")
. (Join-Path $sharedDir "interactive-verify.ps1")
. (Join-Path $sharedDir "confirm-prompt.ps1")

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\conemu-menu.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
$normalizedCommand = ''
if (-not [string]::IsNullOrWhiteSpace($Command)) { $normalizedCommand = $Command.Trim().ToLower() }
if ($Help -or $normalizedCommand -in @('--help','-help','-h','/?','help','?')) {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# Pull --dry-run / --snapshot-file out of $Rest so callers can use the
# friendly forms ("uninstall --dry-run", "restore --snapshot-file C:\x.reg")
# instead of named PowerShell parameters.
if ($null -ne $Rest -and $Rest.Count -gt 0) {
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        $tok = "$($Rest[$i])".Trim().ToLower()
        switch -Regex ($tok) {
            '^(--?dry-run|dry-run)$'                  { $DryRun = $true }
            '^(--?non-interactive|non-interactive|--?headless|headless)$' { $NonInteractive = $true }
            '^(--?yes|-y|yes|--?assume-yes|assume-yes|--?force|force)$'   { $AssumeYes = $true }
            '^(--?snapshot-file|snapshot-file|--?file|file)$' {
                $i++
                if ($i -lt $Rest.Count) { $SnapshotFile = "$($Rest[$i])" }
            }
            default { }
        }
    }
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "ConEmu right-click menu" `
    -Action "Configure" `
    -Source "$scriptDir\helpers\conemu-menu.ps1" `
    -Temp   ($env:TEMP + "\scripts-fixer\conemu-ctx") `
    -Target ("HKCR:\Directory\(Background\)shell\ConEmuHere(+Admin)")

# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Disabled check ------------------------------------------------------------
if (-not $config.enabled) {
    Write-Log $logMessages.messages.scriptDisabled -Level "warn"
    return
}

# -- Read-only subcommands skip the admin gate --------------------------------
$readOnlyCommands = @('list-snapshots','dry-run-uninstall')
$isReadOnly = $readOnlyCommands -contains $normalizedCommand
if ($normalizedCommand -eq 'restore' -and $DryRun) { $isReadOnly = $true }

# -- Assert admin --------------------------------------------------------------
if (-not $isReadOnly) {
    $hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $hasAdminRights) {
        Write-Log $logMessages.messages.notAdmin -Level "error"
        return
    }
}

# -- Subcommand dispatcher ----------------------------------------------------
switch ($normalizedCommand) {
    'list-snapshots' {
        $snaps = Get-ConEmuContextMenuSnapshots
        if ($snaps.Count -eq 0) {
            $backupRoot = Join-Path $script:ScriptDir ".logs\registry-backups"
            Write-Log ("No snapshots found under: " + $backupRoot) -Level "warn"
            Write-Log "Run '.\\run.ps1 -I 59 uninstall' to create one." -Level "info"
            return
        }
        Write-Host ""
        Write-Host "  ConEmu context menu :: snapshots (newest first)" -ForegroundColor Cyan
        Write-Host  "  -------------------------------------------------" -ForegroundColor DarkGray
        $i = 0
        foreach ($s in $snaps) {
            $i++
            $marker = if ($i -eq 1) { "*" } else { " " }
            Write-Host ("  {0} [{1,2}]  {2}  {3,8} bytes  {4}" -f $marker, $i, ($s.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')), $s.Length, $s.FullName) -ForegroundColor White
        }
        Write-Host ""
        Write-Host "  Restore newest:  .\run.ps1 -I 59 restore" -ForegroundColor DarkGray
        Write-Host "  Restore picked:  .\run.ps1 -I 59 restore --snapshot-file <path>" -ForegroundColor DarkGray
        return
    }
    { $_ -in @('uninstall','remove','rollback') } {
        $confirmed = Confirm-DestructiveAction `
            -Title  "Uninstall ConEmu context menu (registry rollback)" `
            -Detail "Snapshots affected HKCR keys to a .reg file, then DELETES the right-click entries. Restore via '.\run.ps1 -I 59 restore'." `
            -NonInteractive:$NonInteractive `
            -AssumeYes:$AssumeYes
        if (-not $confirmed) { Write-Log "Uninstall aborted by user." -Level "warn"; return }
        Uninstall-ConEmuContextMenu -Config $config -LogMessages $logMessages
        return
    }
    { $_ -in @('dry-run-uninstall','uninstall-dry-run','preview-uninstall') } {
        Uninstall-ConEmuContextMenu -Config $config -LogMessages $logMessages -DryRun
        return
    }
    { $_ -in @('restore','restore-snapshot') } {
        if (-not $DryRun) {
            $snapLabel = if ([string]::IsNullOrWhiteSpace($SnapshotFile)) { '<newest snapshot>' } else { $SnapshotFile }
            $confirmed = Confirm-DestructiveAction `
                -Title  "Restore ConEmu context menu from .reg snapshot" `
                -Detail ("Re-imports registry entries from: " + $snapLabel + ". This OVERWRITES current HKCR keys.") `
                -NonInteractive:$NonInteractive `
                -AssumeYes:$AssumeYes
            if (-not $confirmed) { Write-Log "Restore aborted by user." -Level "warn"; return }
        }
        $ok = Restore-ConEmuContextMenuSnapshot -SnapshotFile $SnapshotFile -DryRun:$DryRun -LogMessages $logMessages
        if (-not $ok) { exit 1 }
        return
    }
    default { } # 'install' / '' / 'all' -> fall through to legacy install path
}

# -- Detect ConEmu64.exe ------------------------------------------------------
$conemuExe = Resolve-ConEmuPath `
    -ConEmuPaths     $config.conemuPaths `
    -VerifyCommand   $config.verifyCommand `
    -FallbackTo32Bit $config.fallbackTo32Bit `
    -LogMessages     $logMessages

if (-not $conemuExe) {
    return
}

# -- Process modes (normal + admin) -------------------------------------------
$enabledModes    = $config.enabledModes
$isAllSuccessful = $true

foreach ($modeName in $enabledModes) {
    $mode = $config.modes.$modeName
    if (-not $mode) {
        Write-Log "Unknown mode '$modeName' in enabledModes -- skipping" -Level "warn"
        $isAllSuccessful = $false
        continue
    }

    $result = Invoke-ConEmuMode `
        -Mode        $mode `
        -ModeName    $modeName `
        -ConEmuExe   $conemuExe `
        -LogMessages $logMessages

    if (-not $result) { $isAllSuccessful = $false }
}

# -- Summary -------------------------------------------------------------------
if ($isAllSuccessful) {
    Write-Log $logMessages.messages.done -Level "success"
} else {
    Write-Log $logMessages.messages.completedWithWarnings -Level "warn"
}

# -- Interactive right-click verification (install path only) -----------------
# Folder right-click + folder-background right-click. (Empty-folder background
# uses the same Directory\Background handler as 'background', so we map the
# 'empty-folder' test to that registry path too.)
$null = Invoke-RightClickVerification `
    -Tool         'ConEmu' `
    -EntryLabel   'ConEmu Here' `
    -RetryCommand ".\run.ps1 -I 59 install"

# -- Save resolved state -------------------------------------------------------
Save-ResolvedData -ScriptFolder "59-conemu-context-menu" -Data @{
    conemuExe = $conemuExe
    modes     = ($enabledModes -join ',')
    timestamp = (Get-Date -Format "o")
}

Write-Log $logMessages.messages.setupComplete -Level "success"

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
