<#
.SYNOPSIS
    os clean -- SIMPLE cleaner. Five quick wins, no consent prompts.

.DESCRIPTION
    Runs the safe, fast subset most people actually want when they say
    "clean my Windows":

      1. Windows Update payload cache (%WINDIR%\SoftwareDistribution\Download)
      2. User + system temp dirs (%TEMP%, %LOCALAPPDATA%\Temp, C:\Windows\Temp)
      3. Windows event logs (Application/System/Security via wevtutil cl)
      4. PSReadLine console history file

    For the full 59-category sweep (browsers, dev caches, OBS, recycle bin,
    DISM ResetBase, etc.) use:

        .\run.ps1 os advance-clean

    Flags:
      --dry-run    Report only. No deletions, no log clears.
      --yes        Skip the "are you sure" prompt.

    CODE RED: every file/path failure logs the exact path + reason.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Argv = @()
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")

Initialize-Logging -ScriptName "OS Clean (simple)"

# ---------- Parse flags ----------
$dryRun = $false
# Honor the global yes-flag env var set by run.ps1 / yes-flag.ps1 so that
# `.\run.ps1 os clean -y` (and any other dispatcher path that swallows -y
# via PowerShell's parameter binder) always skips the confirmation prompt.
$autoYes = ($env:SCRIPTS_FIXER_YES -eq '1')
foreach ($a in $Argv) {
    $low = "$a".Trim().ToLower()
    if ($low -in @("--dry-run","-dry-run","dry-run","--dryrun","-n")) { $dryRun = $true }
    elseif ($low -in @("--yes","-yes","-y","yes","/y","/yes","--non-interactive","--noninteractive","--headless","--assume-yes","-assumeyes","--auto-yes","-autoyes")) { $autoYes = $true }
}

Write-Host ""
Write-Host "  OS Clean (simple)" -ForegroundColor Cyan
Write-Host "  =================" -ForegroundColor DarkGray
Write-Host "    1. Windows Update download cache  (%WINDIR%\SoftwareDistribution\Download)" -ForegroundColor DarkGray
Write-Host "    2. Temp dirs                      (%TEMP%, %LOCALAPPDATA%\Temp, C:\Windows\Temp)" -ForegroundColor DarkGray
Write-Host "    3. Windows event logs             (wevtutil cl Application/System/...)" -ForegroundColor DarkGray
Write-Host "    4. PSReadLine console history" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  For the full 59-category sweep run: " -NoNewline -ForegroundColor DarkGray
Write-Host ".\run.ps1 os advance-clean" -ForegroundColor Yellow
Write-Host ""

if ($dryRun) {
    Write-Host "  [DRY-RUN] No deletions will occur." -ForegroundColor Yellow
}

if (-not $dryRun -and -not $autoYes) {
    Write-Host "  Proceed? Type 'yes' to continue: " -NoNewline -ForegroundColor Yellow
    $reply = Read-Host
    if ($reply.Trim().ToLower() -ne "yes") {
        Write-Host "  Aborted by operator." -ForegroundColor Red
        Save-LogFile -Status "fail"
        exit 1
    }
}

$runner   = Join-Path $helpersDir "clean-runner.ps1"
$tempBin  = Join-Path $helpersDir "temp-clean.ps1"
$failures = 0

function Invoke-Step {
    param([string]$Label, [scriptblock]$Body)
    Write-Host ""
    Write-Host "  ---- $Label ----" -ForegroundColor Cyan
    try {
        & $Body
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Host "  [ WARN ] step '$Label' returned exit code $LASTEXITCODE" -ForegroundColor Yellow
            $script:failures++
        }
    } catch {
        Write-Host "  [ FAIL ] step '$Label' threw: $($_.Exception.Message)" -ForegroundColor Red
        $script:failures++
    }
}

# Step 1: WU download cache (existing single-category runner)
Invoke-Step "Windows Update download cache" {
    # NOTE: never use $args here -- it is a PowerShell automatic variable
    # inside scriptblocks and splatting it can mis-bind -Category to the
    # literal string '-Category'. Use a distinct name.
    $runnerArgs = @("-Category","wu-download")
    if ($dryRun)  { $runnerArgs += "--dry-run" }
    if ($autoYes) { $runnerArgs += "--yes" }
    & $runner @runnerArgs
}

# Step 2: Temp dirs
Invoke-Step "Temp directories" {
    $tempArgs = @("-NoConfirm")
    if ($autoYes) { $tempArgs += "-Yes" }
    if ($dryRun) {
        # temp-clean has no native dry-run; emulate by reporting sizes only.
        Write-Host "  [DRY-RUN] Sizes only (no deletions):" -ForegroundColor Yellow
        foreach ($p in @($env:TEMP, (Join-Path $env:LOCALAPPDATA "Temp"), "C:\Windows\Temp")) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-Path -LiteralPath $p) {
                try {
                    $size = (Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue |
                             Measure-Object -Property Length -Sum).Sum
                    $mb = if ($size) { "{0:N1} MB" -f ($size/1MB) } else { "0 MB" }
                    Write-Host ("    {0,-50} {1}" -f $p, $mb) -ForegroundColor DarkGray
                } catch {
                    Write-Host ("  [FILE-ERROR] path={0} reason={1}" -f $p, $_.Exception.Message) -ForegroundColor Red
                }
            } else {
                Write-Host ("    {0,-50} (missing)" -f $p) -ForegroundColor DarkGray
            }
        }
    } else {
        & $tempBin @tempArgs
    }
}

# Step 3: Event logs
Invoke-Step "Windows event logs" {
    $runnerArgs = @("-Category","event-logs")
    if ($dryRun)  { $runnerArgs += "--dry-run" }
    if ($autoYes) { $runnerArgs += "--yes" }
    & $runner @runnerArgs
}

# Step 4: PSReadLine history (inline -- no helper needed)
Invoke-Step "PSReadLine history" {
    $histPath = $null
    try {
        $opt = Get-PSReadLineOption -ErrorAction SilentlyContinue
        if ($opt) { $histPath = $opt.HistorySavePath }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($histPath)) {
        $histPath = Join-Path $env:APPDATA "Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    }
    if (Test-Path -LiteralPath $histPath) {
        if ($dryRun) {
            Write-Host ("    [DRY-RUN] Would remove: {0}" -f $histPath) -ForegroundColor Yellow
        } else {
            try {
                Remove-Item -LiteralPath $histPath -Force -ErrorAction Stop
                try { Clear-History -ErrorAction SilentlyContinue } catch {}
                Write-Host ("    [  OK  ] Removed: {0}" -f $histPath) -ForegroundColor Green
            } catch {
                Write-Host ("  [FILE-ERROR] path={0} reason={1}" -f $histPath, $_.Exception.Message) -ForegroundColor Red
                $script:failures++
            }
        }
    } else {
        Write-Host ("    (no history file at {0})" -f $histPath) -ForegroundColor DarkGray
    }
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "  [  OK  ] os clean (simple) finished cleanly." -ForegroundColor Green
    Save-LogFile -Status "ok"
    exit 0
} else {
    Write-Host "  [ WARN ] os clean (simple) finished with $failures step(s) reporting issues." -ForegroundColor Yellow
    Save-LogFile -Status "partial"
    exit 0
}
