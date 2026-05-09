# --------------------------------------------------------------------------
#  Script 62 -- Pin apps to the Windows taskbar.
#
#  Usage:
#    .\run.ps1 install pin-taskbar all
#    .\run.ps1 install pin-taskbar terminal
#    .\run.ps1 install pin-taskbar vscode,chrome
#    .\run.ps1 install pin-vscode
#    .\run.ps1 -I 62 -- vscode
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "install-paths.ps1")
. (Join-Path $scriptDir "helpers\pin.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Triple-path trio --------------------------------------------------------
Write-InstallPaths `
    -Tool   "Taskbar pin" `
    -Action "Configure" `
    -Source "$scriptDir\helpers\pin.ps1" `
    -Temp   ($env:TEMP + "\scripts-fixer\pin-taskbar") `
    -Target ($env:APPDATA + "\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar")

Initialize-Logging -ScriptName $logMessages.scriptName

try {

    Invoke-GitPull

    $isDisabled = -not $config.enabled
    if ($isDisabled) {
        Write-Log $logMessages.messages.scriptDisabled -Level "warn"
        return
    }

    # -- Collect requested app names from $Command + $Rest -----------------
    $rawArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Command)) { $rawArgs += $Command }
    if ($Rest) { $rawArgs += $Rest }

    # Allow comma-separated single arg ("vscode,chrome")
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($a in $rawArgs) {
        foreach ($t in ($a -split '[,\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($t)) { $names.Add($t.ToLowerInvariant()) }
        }
    }

    if ($names.Count -eq 0) {
        Write-Log $logMessages.messages.noApps -Level "warn"
        return
    }

    $summary = Invoke-PinTaskbarApps -AppsConfig $config -Names @($names) -LogMessages $logMessages

    $hasFailures = ($summary.fail -gt 0) -or ($summary.missing -gt 0)
    if ($hasFailures) {
        Write-Log $logMessages.messages.doneWarn -Level "warn"
    } else {
        Write-Log $logMessages.messages.doneOk -Level "success"
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
