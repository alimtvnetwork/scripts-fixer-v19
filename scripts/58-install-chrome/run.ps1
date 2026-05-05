# --------------------------------------------------------------------------
#  Script 58 -- Install Google Chrome
#  Mechanism: Chocolatey (googlechrome) with official standalone installer fallback
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

. (Join-Path $scriptDir "helpers\chrome.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "Google Chrome" `
    -Source "https://chocolatey.org/install (pkg: googlechrome)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target ($env:ProgramFiles + "\Google\Chrome\Application")
Initialize-Logging -ScriptName $logMessages.scriptName

try {

    Invoke-GitPull

    $isUninstall = $Command.ToLower() -eq "uninstall"
    if ($isUninstall) {
        Uninstall-Chrome -ChromeConfig $config.chrome -LogMessages $logMessages
        return
    }

    $ok = Install-Chrome -ChromeConfig $config.chrome -LogMessages $logMessages

    $isSuccess = $ok -eq $true
    if ($isSuccess) {
        Write-Log $logMessages.messages.setupComplete -Level "success"
    } else {
        Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
