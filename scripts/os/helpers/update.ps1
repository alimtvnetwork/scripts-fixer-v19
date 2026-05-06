# --------------------------------------------------------------------------
#  os update -- Run Windows Update (scan + download + install)
#  Strategy:
#    1. Try PSWindowsUpdate module (preferred, scriptable, returns results)
#    2. Fall back to UsoClient (built-in Windows 10/11 -- triggers UI flow)
#    3. Fall back to wuauclt (legacy)
#  Flags:
#    --dry-run   : scan only, don't install
#    --reboot    : auto-reboot after install if required
#    --yes       : auto-accept module install prompts
# --------------------------------------------------------------------------
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $scriptDir)) "shared"

# -- Load shared logger (idempotent) ---------------------------------------
$loggingPath = Join-Path $sharedDir "logging.ps1"
if ((Test-Path $loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $loggingPath
}

# -- Parse flags ------------------------------------------------------------
$isDryRun = $false
$isAutoReboot = $false
$isYes = $false
if ($null -ne $Rest) {
    foreach ($arg in $Rest) {
        $low = "$arg".Trim().ToLower()
        if ($low -in @("--dry-run", "-dry-run", "--dryrun")) { $isDryRun = $true }
        elseif ($low -in @("--reboot", "-reboot", "--auto-reboot")) { $isAutoReboot = $true }
        elseif ($low -in @("--yes", "-y", "-yes")) { $isYes = $true }
    }
}

Write-Banner -Title "OS Update"

Write-Log "Starting Windows Update flow (dry-run=$isDryRun, auto-reboot=$isAutoReboot)" -Level "info"

# -- Elevation check --------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-Log "Windows Update requires Administrator. Re-run from an elevated terminal." -Level "error"
    exit 2
}

# -- Strategy 1: PSWindowsUpdate --------------------------------------------
$pswuModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue
if (-not $pswuModule) {
    Write-Log "PSWindowsUpdate module not found -- attempting install from PSGallery..." -Level "info"
    try {
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo -and $repo.InstallationPolicy -ne "Trusted") {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        $pswuModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue
        Write-Log "PSWindowsUpdate installed successfully." -Level "success"
    } catch {
        Write-Log "PSWindowsUpdate install failed: $_" -Level "warn"
    }
}

if ($pswuModule) {
    try {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        Write-Log "Scanning for available updates..." -Level "info"
        $updates = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop

        $count = @($updates).Count
        if ($count -eq 0) {
            Write-Log "No updates available -- system is up to date." -Level "success"
            exit 0
        }

        Write-Log "Found $count update(s):" -Level "info"
        $updates | ForEach-Object {
            Write-Host "    - $($_.KB) $($_.Title) [$([math]::Round($_.Size / 1MB, 2)) MB]" -ForegroundColor Gray
        }

        if ($isDryRun) {
            Write-Log "Dry-run -- skipping install." -Level "info"
            exit 0
        }

        Write-Log "Installing updates..." -Level "info"
        $installArgs = @{ MicrosoftUpdate = $true; AcceptAll = $true; IgnoreReboot = $true }
        if ($isAutoReboot) { $installArgs.Remove("IgnoreReboot"); $installArgs.AutoReboot = $true }
        Install-WindowsUpdate @installArgs

        Write-Log "Windows Update flow complete." -Level "success"
        exit 0
    } catch {
        Write-Log "PSWindowsUpdate flow failed: $_" -Level "warn"
        Write-Log "Falling back to UsoClient..." -Level "info"
    }
}

# -- Strategy 2: UsoClient (Windows 10/11) ----------------------------------
$usoClient = Join-Path $env:WINDIR "System32\UsoClient.exe"
if (Test-Path $usoClient) {
    if ($isDryRun) {
        Write-Log "Dry-run: would invoke UsoClient StartScan." -Level "info"
        & $usoClient StartScan
        exit 0
    }
    Write-Log "Triggering UsoClient: scan + download + install." -Level "info"
    & $usoClient StartScan
    Start-Sleep -Seconds 3
    & $usoClient StartDownload
    Start-Sleep -Seconds 3
    & $usoClient StartInstall
    Write-Log "UsoClient triggered. Check Settings > Windows Update for progress." -Level "success"
    exit 0
}

# -- Strategy 3: wuauclt (legacy) -------------------------------------------
$wuauclt = Join-Path $env:WINDIR "System32\wuauclt.exe"
if (Test-Path $wuauclt) {
    Write-Log "Falling back to legacy wuauclt /detectnow /updatenow" -Level "info"
    & $wuauclt /detectnow /updatenow
    exit 0
}

Write-Log "No Windows Update mechanism available (no PSWindowsUpdate, UsoClient, or wuauclt)." -Level "error"
exit 1
