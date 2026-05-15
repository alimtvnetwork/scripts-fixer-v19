<#
.SYNOPSIS
    os temp-clean -- wipe Windows temp directories with locked-file resilience.

.DESCRIPTION
    Targets every standard Windows temp location:
      * $env:TEMP                       (current user)
      * C:\Windows\Temp                 (system)
      * $env:LOCALAPPDATA\Temp          (current user, alternative)
      * C:\Users\<each>\AppData\Local\Temp  (all profiles, when admin)
      * $env:TEMP\chocolatey            (choco extraction temp, optional)

    Files locked by running processes are CAUGHT (not crashed on), accumulated,
    and reported in a dedicated [LOCKED FILES] section at the end with the OS
    error reason (in-use / sharing violation / access denied).

    This helper is invoked standalone via `.\run.ps1 os temp-clean`, or
    cascaded internally by `os clean` (see scripts/os/helpers/clean.ps1).

    CODE RED: every file/path failure logs the exact path + reason.
#>
param(
    [switch]$Yes,
    [switch]$Force,
    [switch]$NoChoco,
    [switch]$ReturnResults,   # internal: when set, returns a hashtable instead of exiting
    [switch]$NoConfirm        # internal: when cascaded from os clean
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir  = Split-Path -Parent $helpersDir
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $helpersDir "_common.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages

if (-not $ReturnResults) {
    Initialize-Logging -ScriptName "OS Temp-Clean"
}

# ---------- Admin check (skipped when cascaded -- parent already checked) ----------
if (-not $NoConfirm) {
    $forwardArgs = @()
    if ($Yes)     { $forwardArgs += "-Yes" }
    if ($Force)   { $forwardArgs += "-Force" }
    if ($NoChoco) { $forwardArgs += "-NoChoco" }

    $isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition `
                              -ForwardArgs $forwardArgs `
                              -LogMessages $logMessages
    if (-not $isAdminOk) {
        Save-LogFile -Status "fail"
        exit 1
    }

    $autoYes = $Yes -or $Force
    $confirmed = Confirm-Action -Prompt "This will wipe %TEMP%, C:\Windows\Temp, per-user Temp folders, and choco temp. Continue? [y/N]: " -AutoYes:$autoYes
    if (-not $confirmed) {
        Write-Log $logMessages.messages.userCancelled -Level "warn"
        Save-LogFile -Status "skip"
        exit 0
    }
}

# ---------- Core sweep with locked-file accumulation ----------
function Get-DirSize {
    param([string]$Path)
    try {
        if (-not (Test-Path $Path)) { return 0 }
        $sum = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [long]$sum
    } catch { return 0 }
}

function Get-LockReason {
    param([System.Exception]$Ex)
    if ($null -eq $Ex) { return "unknown error" }
    $msg = $Ex.Message
    if ($msg -match "being used by another process|in use") { return "in use by another process" }
    if ($msg -match "Access to the path|denied|UnauthorizedAccess")     { return "access denied (locked or protected)" }
    if ($msg -match "sharing violation|share")                          { return "sharing violation (open handle)" }
    if ($msg -match "Could not find")                                   { return "vanished mid-sweep (already gone)" }
    return $msg.Split("`n")[0].Trim()
}

function Invoke-TempSweep {
    param(
        [string]$Path,
        [string]$Label,
        [int]$StepNum
    )

    # NOTE: use [pscustomobject], NOT [ordered]@{} -- ordered dictionaries
    # expose a read-only .Count property that shadows our key, causing
    # "The property 'Count' cannot be found on this object" under StrictMode.
    $result = [pscustomobject]@{
        Step          = $StepNum
        Label         = $Label
        Path          = $Path
        Count         = 0
        Bytes         = [long]0
        Locked        = 0
        LockedDetails = @()
        Status        = "ok"
    }

    if (-not (Test-Path $Path)) {
        Write-Log "Step ${StepNum}: ${Label} -- path not present: ${Path}" -Level "skip"
        $result.Status = "skip"
        return $result
    }

    $sizeBefore = Get-DirSize -Path $Path

    # Recurse depth-first so we delete leaf files before their parent dirs.
    $allItems = @()
    try {
        $allItems = Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Step ${StepNum} enumerate failed at ${Path}: $($_.Exception.Message)" -Level "warn"
    }

    # Files first, then directories (deepest first)
    $files = $allItems | Where-Object { -not $_.PSIsContainer }
    $dirs  = $allItems | Where-Object {  $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending

    $removedFiles = 0
    foreach ($f in $files) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $removedFiles++
        } catch {
            $reason = Get-LockReason -Ex $_.Exception
            $result.Locked++
            $result.LockedDetails += @{ Path = $f.FullName; Reason = $reason }
            # CODE RED: log exact path + reason
            Write-Log "Step ${StepNum} locked at $($f.FullName): ${reason}" -Level "warn"
        }
    }

    $removedDirs = 0
    foreach ($d in $dirs) {
        try {
            if (Test-Path $d.FullName) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
                $removedDirs++
            }
        } catch {
            $reason = Get-LockReason -Ex $_.Exception
            $result.Locked++
            $result.LockedDetails += @{ Path = $d.FullName; Reason = $reason }
            Write-Log "Step ${StepNum} locked dir at $($d.FullName): ${reason}" -Level "warn"
        }
    }

    $sizeAfter = Get-DirSize -Path $Path
    $result.Bytes = [long]([Math]::Max(0, $sizeBefore - $sizeAfter))
    $result.Count = $removedFiles + $removedDirs

    $mb = Format-Bytes -Bytes $result.Bytes
    if ($result.Locked -eq 0) {
        $result.Status = "ok"
        Write-Log "Step ${StepNum} done: ${Label} -- removed $($result.Count) item(s), freed ${mb} MB" -Level "success"
    } else {
        $result.Status = "warn"
        Write-Log "Step ${StepNum} done with locks: ${Label} -- removed $($result.Count) item(s), freed ${mb} MB, locked $($result.Locked)" -Level "warn"
    }

    return $result
}

# ---------- Build target list ----------
$results = @()
$step = 1

# 1. $env:TEMP
$tempPath = [Environment]::GetEnvironmentVariable($config.tempClean.tempEnvVar)
if ([string]::IsNullOrWhiteSpace($tempPath)) { $tempPath = $env:TEMP }
$results += Invoke-TempSweep -Path $tempPath -Label "User TEMP ($tempPath)" -StepNum $step
$step++

# 2. C:\Windows\Temp
$results += Invoke-TempSweep -Path $config.tempClean.windowsTemp -Label "Windows TEMP" -StepNum $step
$step++

# 3. $env:LOCALAPPDATA\Temp (often identical to $env:TEMP, but not always)
$localTemp = $null
$lad = [Environment]::GetEnvironmentVariable($config.tempClean.localAppDataTempVar)
if (-not [string]::IsNullOrWhiteSpace($lad)) {
    $localTemp = Join-Path $lad "Temp"
}
if ($localTemp -and ($localTemp.ToLower() -ne $tempPath.ToLower())) {
    $results += Invoke-TempSweep -Path $localTemp -Label "LocalAppData\Temp" -StepNum $step
    $step++
} else {
    Write-Log "Step ${step}: LocalAppData\Temp -- same path as user TEMP, skipped to avoid double-sweep" -Level "skip"
    $step++
}

# 4. Per-user Temp sweep (admin only -- enumerate C:\Users\*\AppData\Local\Temp)
$perUserRoot = $config.tempClean.perUserTempRoot
if (Test-Path $perUserRoot) {
    $userDirs = @()
    try {
        $userDirs = Get-ChildItem -Path $perUserRoot -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users", "WDAGUtilityAccount") }
    } catch {}

    Write-Log ($logMessages.tempClean.perUserSweep -replace '\{root\}', $perUserRoot -replace '\{count\}', $userDirs.Count) -Level "info"

    $currentUserName = $env:USERNAME
    foreach ($u in $userDirs) {
        $perTemp = Join-Path $u.FullName "AppData\Local\Temp"
        if (-not (Test-Path $perTemp)) { continue }
        # Skip current user -- already swept above
        if ($u.Name -ieq $currentUserName) { continue }
        $results += Invoke-TempSweep -Path $perTemp -Label "Per-user Temp: $($u.Name)" -StepNum $step
        $step++
    }
}

# 5. choco temp (unless suppressed)
if ($config.tempClean.clearChocoTemp -and -not $NoChoco) {
    $chocoTemp = Join-Path $tempPath "chocolatey"
    if (Test-Path $chocoTemp) {
        $results += Invoke-TempSweep -Path $chocoTemp -Label "Chocolatey TEMP cache" -StepNum $step
        $step++
    }
}

# ---------- Aggregate locked files (deduped, capped) ----------
$allLocked = @()
foreach ($r in $results) {
    if ($r.LockedDetails -and $r.LockedDetails.Count -gt 0) {
        $allLocked += $r.LockedDetails
    }
}

# ---------- Print summary table ----------
if (-not $ReturnResults) {
    Write-Host ""
    Write-Host "  $($logMessages.tempClean.summaryHeader)" -ForegroundColor Cyan
    Write-Host "  ===================" -ForegroundColor DarkGray
    $totalBytes  = 0
    $totalCount  = 0
    $totalLocked = 0
    foreach ($r in $results) {
        $mb = Format-Bytes -Bytes $r.Bytes
        $statusColor = switch ($r.Status) {
            "ok"   { "Green" }
            "warn" { "Yellow" }
            "skip" { "DarkGray" }
            "fail" { "Red" }
            default { "Gray" }
        }
        Write-Host ("    Step {0,-2} {1,-38} items: {2,5}  freed: {3,8} MB  locked: {4,4}  [{5}]" `
            -f $r.Step, $r.Label, $r.Count, $mb, $r.Locked, $r.Status.ToUpper()) -ForegroundColor $statusColor
        $totalBytes  += $r.Bytes
        $totalCount  += $r.Count
        $totalLocked += $r.Locked
    }
    Write-Host ""
    Write-Host ("    TOTAL: {0} item(s), freed {1} MB ({2} GB), locked {3}" `
        -f $totalCount, (Format-Bytes $totalBytes), (Format-Gb $totalBytes), $totalLocked) -ForegroundColor Cyan

    # Locked-files report
    if ($allLocked.Count -gt 0) {
        Write-Host ""
        Write-Host "  [ LOCKED FILES ] $($logMessages.clean.lockedHeader)" -ForegroundColor Yellow
        Write-Host "  --------------------------------------------------------------------" -ForegroundColor DarkGray
        $limit = [int]$config.tempClean.lockedFilesMaxReport
        $shown = 0
        foreach ($lk in $allLocked) {
            if ($shown -ge $limit) { break }
            Write-Host ("    {0}  --  {1}" -f $lk.Path, $lk.Reason) -ForegroundColor DarkYellow
            $shown++
        }
        if ($allLocked.Count -gt $limit) {
            $more = $allLocked.Count - $limit
            Write-Host ("    ... and {0} more locked file(s) not shown (limit: {1}). See log file for full list." -f $more, $limit) -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    $finalStatus = if ($totalLocked -eq 0) { "ok" } else { "partial" }
    Save-LogFile -Status $finalStatus
    exit 0
}

# Cascaded mode: return aggregated result so os clean can fold it into its own summary
return @{
    Results    = $results
    AllLocked  = $allLocked
}
