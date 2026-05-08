# --------------------------------------------------------------------------
#  Script 61 -- Install JumpJump VPN
#  Mechanism: Official direct-download installer (no choco package available).
#             Optional Chocolatey attempt if config.chocoPackage is set.
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

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

. (Join-Path $scriptDir "helpers\jumpjump-vpn.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

Write-InstallPaths `
    -Tool   "JumpJump VPN" `
    -Source ($config.jumpjumpVpn.directInstall.url) `
    -Temp   ($env:TEMP + "\jumpjump-vpn") `
    -Target ($env:ProgramFiles + "\JumpJump VPN")
Initialize-Logging -ScriptName $logMessages.scriptName

try {
    Invoke-GitPull
    $cmd = $Command.ToLower().Trim()

    if ($cmd -eq "uninstall") {
        Uninstall-JumpJumpVpn -JjConfig $config.jumpjumpVpn -LogMessages $logMessages
        return
    }

    $ok = Install-JumpJumpVpn -JjConfig $config.jumpjumpVpn -LogMessages $logMessages
    if ($ok -eq $true) {
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
