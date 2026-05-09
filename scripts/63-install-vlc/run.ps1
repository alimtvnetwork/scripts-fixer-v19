# --------------------------------------------------------------------------
#  Script 63 -- Install VLC media player + repair file associations
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "install",

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

. (Join-Path $scriptDir "helpers\vlc.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptTitle

Write-InstallPaths `
    -Tool   "VLC media player" `
    -Source "https://chocolatey.org/install (pkg: vlc)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target "C:\Program Files\VideoLAN\VLC"

Initialize-Logging -ScriptName $logMessages.scriptName

try {
    Invoke-GitPull

    $cmd = $Command.ToLower()
    switch ($cmd) {
        "uninstall" {
            Uninstall-Vlc -VlcConfig $config.vlc -LogMessages $logMessages | Out-Null
        }
        "repair" {
            Repair-VlcAssociations -VlcConfig $config.vlc -LogMessages $logMessages
            Write-Log $logMessages.messages.setupComplete -Level "success"
        }
        default {
            $ok = Install-Vlc -VlcConfig $config.vlc -LogMessages $logMessages
            if ($ok) {
                Write-Log $logMessages.messages.setupComplete -Level "success"
            } else {
                Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
            }
        }
    }
} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
