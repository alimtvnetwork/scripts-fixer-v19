# --------------------------------------------------------------------------
#  Script 59 -- ConEmu Context Menu
#  Adds "Open ConEmu Here" (normal + admin) to the right-click menu for
#  folders and folder backgrounds. Mirrors script 31 (PowerShell Here).
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Help
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

# -- Dot-source script helpers ------------------------------------------------
. (Join-Path $scriptDir "helpers\conemu-menu.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help" -or $Command -eq "-h" -or $Command -eq "-help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
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

# -- Assert admin --------------------------------------------------------------
$hasAdminRights = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $hasAdminRights) {
    Write-Log $logMessages.messages.notAdmin -Level "error"
    return
}

# -- Uninstall path ------------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-ConEmuContextMenu -Config $config -LogMessages $logMessages
    return
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
