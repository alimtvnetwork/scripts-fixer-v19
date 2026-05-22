# --------------------------------------------------------------------------
#  Script 35 -- Install GitMap
#  Git repository navigator CLI tool
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1)]
    [string]$Path,

    # Pin a specific gitmap release tag (e.g. v3.180, v3.181, v4.0.0).
    # -Tag is the canonical flag; -Version is kept as a back-compat alias.
    [Alias("Version")]
    [string]$Tag,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "dev-dir.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "path-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

# -- Dot-source script helper -------------------------------------------------
. (Join-Path $scriptDir "helpers\gitmap.ps1")

# -- Load config & log messages -----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

# -- Banner --------------------------------------------------------------------
Write-Banner -Title $logMessages.scriptName

# -- Resolve effective git ref (branch / tag / commit) ------------------------
# Precedence:  -Tag/-Version flag  >  config.gitmap.releaseTag  >
#              config.gitmap.fallbackTag  >  hard default "main".
# The ref is substituted into both the raw install.ps1 URL and the
# release ZIP URL. Default points at the gitmap-v23 main branch.
$effectiveTag = $null
if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $effectiveTag = $Tag.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($config.gitmap.releaseTag)) {
    $effectiveTag = "$($config.gitmap.releaseTag)".Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($config.gitmap.fallbackTag)) {
    $effectiveTag = "$($config.gitmap.fallbackTag)".Trim()
} else {
    $effectiveTag = "main"
}

# Normalise: numeric versions like "3.181" -> "v3.181"; branch names
# (main, master, dev, ...) and explicit tags pass through untouched.
if ($effectiveTag -match '^\d') { $effectiveTag = "v$effectiveTag" }

# Substitute {tag} placeholders in install + zip URLs.
$config.gitmap.releaseTag    = $effectiveTag
$config.gitmap.fallbackTag   = $effectiveTag
if ($config.gitmap.installUrl) {
    $config.gitmap.installUrl    = $config.gitmap.installUrl    -replace '\{tag\}', $effectiveTag
}
if ($config.gitmap.releaseZipUrl) {
    $config.gitmap.releaseZipUrl = $config.gitmap.releaseZipUrl -replace '\{tag\}', $effectiveTag
}

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "GitMap" `
    -Action "Install" `
    -Source "$($config.gitmap.installUrl) (irm | iex)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target ("C:\Program Files\GitExtensions")

# -- Initialize logging --------------------------------------------------------
Initialize-Logging -ScriptName $logMessages.scriptName

try {

# -- Git pull ------------------------------------------------------------------
Invoke-GitPull

# -- Uninstall check -----------------------------------------------------------
$isUninstall = $Command.ToLower() -eq "uninstall"
if ($isUninstall) {
    Uninstall-Gitmap -GitmapConfig $config.gitmap -DevDirConfig $config.devDir -LogMessages $logMessages
    return
}

# -- Install -------------------------------------------------------------------
Write-Log "Using gitmap release tag: $effectiveTag" -Level "info"
Write-Log "Resolved install URL: $($config.gitmap.installUrl)" -Level "info"

$ok = Install-Gitmap -GitmapConfig $config.gitmap -DevDirConfig $config.devDir -LogMessages $logMessages

$isSuccess = $ok -eq $true
if ($isSuccess) {
    # -- Post-install verification: re-run `gitmap --version` and print a
    # clearly-formatted summary so the user sees the final binary + version.
    $finalVerify = Assert-GitmapInstalled -InstallDir $config.gitmap.installDir -LogMessages $logMessages
    if ($finalVerify.Success) {
        Write-Host ""
        Write-Host "================ gitmap post-install verification ================" -ForegroundColor Cyan
        Write-Host ("  gitmap --version : {0}" -f $finalVerify.Version)    -ForegroundColor Green
        Write-Host ("  resolved binary  : {0}" -f $finalVerify.BinaryPath) -ForegroundColor Green
        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Log $logMessages.messages.setupComplete -Level "success"
    } else {
        Write-Log "Post-install verification failed: 'gitmap --version' did not run cleanly. Open a NEW terminal and re-run." -Level "error"
        $isSuccess = $false
    }
}
if (-not $isSuccess) {
    Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
}

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    # -- Save log (always runs, even on crash) --
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
