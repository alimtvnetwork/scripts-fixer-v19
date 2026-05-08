<#
.SYNOPSIS
    Shared sweep + result primitives for every clean-categories\<name>.ps1 helper.

.DESCRIPTION
    Dot-sourced by every category helper AND by clean.ps1 (orchestrator).
    Provides:
      * New-CleanResult           -- builds the standard result hashtable
      * Get-DirSize / Get-PathSize -- byte counters that swallow access errors
      * Get-LockReason            -- maps Win32 exceptions to short labels
      * Invoke-PathSweep          -- recursive depth-first wipe with locked-file tracking
      * Invoke-FilePatternSweep   -- glob-based wipe (*.chk, *.etl, etc.)
      * Test-DryRunSwitch         -- parses --dry-run / -DryRun consistently
      * Resolve-CleanPath         -- expands %ENV%, ~ and forward-slashes
      * Get-AppDataPath / Get-LocalAppDataPath -- short accessors
      * Read-CleanConsent / Save-CleanConsent / Test-CategoryConsent
      * Confirm-DestructiveCategory -- typed-yes prompt (CODE RED on path errors)

    CODE RED: every file/path error logs the exact failing path + reason.

.NOTES
    Result hashtable shape (every category MUST emit this):
      @{
        Category      = "chrome"
        Label         = "Chrome cache"
        Bucket        = "D"
        Destructive   = $false
        Count         = 0
        WouldCount    = 0
        Bytes         = 0
        WouldBytes    = 0
        Locked        = 0
        LockedDetails = @( @{ Path=...; Reason=... } )
        Status        = "ok"|"warn"|"skip"|"fail"|"dry-run"
        Notes         = @()
      }
#>

# ---------- Result builder -------------------------------------------------
function New-CleanResult {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Bucket,
        [switch]$Destructive
    )
    return [ordered]@{
        Category      = $Category
        Label         = $Label
        Bucket        = $Bucket
        Destructive   = [bool]$Destructive
        Count         = 0
        WouldCount    = 0
        Bytes         = 0
        WouldBytes    = 0
        Locked        = 0
        LockedDetails = @()
        Status        = "ok"
        Notes         = @()
    }
}

# ---------- Byte counters --------------------------------------------------
function Get-DirSize {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return 0 }
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [long]$sum
    } catch { return 0 }
}

function Get-PathSize {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return 0 }
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $i) { return 0 }
        if ($i.PSIsContainer) { return Get-DirSize -Path $Path }
        return [long]$i.Length
    } catch { return 0 }
}

# ---------- Lock reason mapper --------------------------------------------
function Get-LockReason {
    param([System.Exception]$Ex)
    if ($null -eq $Ex) { return "unknown error" }
    $msg = $Ex.Message
    if ($msg -match "being used by another process|in use") { return "in use by another process" }
    if ($msg -match "Access to the path|denied|UnauthorizedAccess") { return "access denied (locked or protected)" }
    if ($msg -match "sharing violation|share")               { return "sharing violation (open handle)" }
    if ($msg -match "Could not find|cannot find")            { return "vanished mid-sweep (already gone)" }
    if ($msg -match "longer than")                            { return "path too long (>260 chars, enable longpath)" }
    return $msg.Split("`n")[0].Trim()
}

# ---------- Path resolution -----------------------------------------------
function Resolve-CleanPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded.StartsWith("~")) {
        $expanded = $expanded -replace "^~", $env:USERPROFILE
    }
    return $expanded
}

function Get-AppDataPath { return [Environment]::GetEnvironmentVariable("APPDATA") }
function Get-LocalAppDataPath { return [Environment]::GetEnvironmentVariable("LOCALAPPDATA") }
function Get-UserProfilePath { return [Environment]::GetEnvironmentVariable("USERPROFILE") }
function Get-ProgramDataPath { return [Environment]::GetEnvironmentVariable("PROGRAMDATA") }

# ---------- Recursive sweep (the workhorse) -------------------------------
function Invoke-PathSweep {
    <#
    .SYNOPSIS
        Recursively wipes the contents of $Path. Returns count + bytes + locked
        list. Honors -DryRun (no writes, populates WouldCount/WouldBytes).

    .PARAMETER Path
        Folder whose CONTENTS get wiped (the folder itself stays).

    .PARAMETER Result
        The category result hashtable; gets Count/Bytes/Locked/LockedDetails
        accumulated into it.

    .PARAMETER DryRun
        Report-only mode. No deletions.

    .PARAMETER Filter
        Optional wildcard (e.g. "*.chk", "thumbcache_*.db"). When set, only
        matching FILES are removed (no directory recursion).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Result,
        [switch]$DryRun,
        [string]$Filter,
        [string]$LogPrefix = "sweep"
    )

    $resolved = Resolve-CleanPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($resolved) -or -not (Test-Path -LiteralPath $resolved)) {
        $Result.Notes += "Path not present: $resolved"
        return
    }

    $sizeBefore = Get-DirSize -Path $resolved

    $items = @()
    try {
        if ($Filter) {
            $items = Get-ChildItem -LiteralPath $resolved -Recurse -Force -Filter $Filter -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.PSIsContainer }
        } else {
            $items = Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "${LogPrefix} enumerate failed at ${resolved}: $($_.Exception.Message)" -Level "warn"
    }

    if ($DryRun) {
        $files = @($items | Where-Object { -not $_.PSIsContainer })
        $bytes = ($files | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $bytes) { $bytes = 0 }
        $Result.WouldCount += $files.Count
        $Result.WouldBytes += [long]$bytes
        $Result.Notes += "DRY-RUN: would remove $($files.Count) file(s) from $resolved"
        return
    }

    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $dirs  = @($items | Where-Object {  $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)

    foreach ($f in $files) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $Result.Count++
        } catch {
            $reason = Get-LockReason -Ex $_.Exception
            $Result.Locked++
            $Result.LockedDetails += @{ Path = $f.FullName; Reason = $reason }
            Write-Log "${LogPrefix} locked at $($f.FullName): ${reason}" -Level "warn"
        }
    }
    if (-not $Filter) {
        foreach ($d in $dirs) {
            try {
                if (Test-Path -LiteralPath $d.FullName) {
                    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
                    $Result.Count++
                }
            } catch {
                $reason = Get-LockReason -Ex $_.Exception
                $Result.Locked++
                $Result.LockedDetails += @{ Path = $d.FullName; Reason = $reason }
                Write-Log "${LogPrefix} locked dir at $($d.FullName): ${reason}" -Level "warn"
            }
        }
    }

    $sizeAfter = Get-DirSize -Path $resolved
    $Result.Bytes += [long]([Math]::Max(0, $sizeBefore - $sizeAfter))
}

# ---------- Switch parsing -------------------------------------------------
function Test-DryRunSwitch {
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $false }
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--dry-run", "-dryrun", "--dryrun", "-d")) { return $true }
    }
    return $false
}

function Test-YesSwitch {
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $false }
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--yes", "-yes", "-y", "--force", "-force")) { return $true }
    }
    return $false
}

function Get-DaysArg {
    param([string[]]$Argv, [int]$Default = 30)
    if ($null -eq $Argv) { return $Default }
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $t = "$($Argv[$i])".ToLower()
        if ($t -eq "--days" -and ($i + 1) -lt $Argv.Count) {
            $val = 0
            if ([int]::TryParse($Argv[$i + 1], [ref]$val)) { return $val }
        }
        if ($t -match '^--days=(\d+)$') { return [int]$Matches[1] }
    }
    return $Default
}

# ---------- Consent persistence (.resolved/os-clean-consent.json) ---------
function Get-ConsentFilePath {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
    $resolvedDir = Join-Path $repoRoot ".resolved"
    if (-not (Test-Path -LiteralPath $resolvedDir)) {
        try {
            New-Item -ItemType Directory -Path $resolvedDir -Force | Out-Null
        } catch {
            Write-Log "Failed to create .resolved/ at $resolvedDir : $($_.Exception.Message)" -Level "warn"
        }
    }
    return (Join-Path $resolvedDir "os-clean-consent.json")
}

function Read-CleanConsent {
    $path = Get-ConsentFilePath
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ version = 1; consentedFor = @(); consentedAt = $null; machineName = $env:COMPUTERNAME }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $list = @()
        if ($obj.consentedFor) { $list = @($obj.consentedFor) }
        return @{
            version      = if ($obj.version) { $obj.version } else { 1 }
            consentedFor = $list
            consentedAt  = $obj.consentedAt
            machineName  = if ($obj.machineName) { $obj.machineName } else { $env:COMPUTERNAME }
        }
    } catch {
        Write-Log "Failed to read consent file at ${path}: $($_.Exception.Message)" -Level "warn"
        return @{ version = 1; consentedFor = @(); consentedAt = $null; machineName = $env:COMPUTERNAME }
    }
}

function Save-CleanConsent {
    param([string[]]$Categories)
    $path = Get-ConsentFilePath
    $existing = Read-CleanConsent
    $merged = @($existing.consentedFor + $Categories | Select-Object -Unique)
    $obj = @{
        version      = 1
        consentedAt  = (Get-Date -Format "o")
        consentedFor = $merged
        machineName  = $env:COMPUTERNAME
    }
    try {
        $obj | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $path -Encoding UTF8 -Force
    } catch {
        Write-Log "Failed to write consent file at ${path}: $($_.Exception.Message)" -Level "fail"
    }
}

function Test-CategoryConsent {
    param([string]$Category)
    $consent = Read-CleanConsent
    return ($consent.consentedFor -contains $Category)
}

function Confirm-DestructiveCategory {
    param(
        [string]$Category,
        [string]$Warning,
        [switch]$AutoYes,
        [switch]$DryRun
    )
    if ($DryRun) { return $true }
    if (Test-CategoryConsent -Category $Category) { return $true }
    if ($AutoYes) {
        Save-CleanConsent -Categories @($Category)
        return $true
    }
    Write-Host ""
    Write-Host "  [ CONSENT ] " -ForegroundColor Yellow -NoNewline
    Write-Host "Destructive category: $Category" -ForegroundColor White
    Write-Host "             $Warning" -ForegroundColor DarkYellow
    Write-Host "             Type 'yes' (lowercase, no quotes) to confirm: " -ForegroundColor Yellow -NoNewline
    $reply = Read-Host
    if ($reply -ceq "yes") {
        Save-CleanConsent -Categories @($Category)
        return $true
    }
    Write-Host "  [ SKIP ] " -ForegroundColor DarkGray -NoNewline
    Write-Host "Consent declined for $Category"
    return $false
}

# ---------- Service stop/start helper -------------------------------------
function Stop-WindowsService {
    param([string]$Name, [hashtable]$Result)
    try {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            $Result.Notes += "Service '$Name' not present"
            return $false
        }
        if ($svc.Status -eq "Running") {
            Stop-Service -Name $Name -Force -ErrorAction Stop
            $Result.Notes += "Stopped service '$Name'"
            return $true
        }
        return $false
    } catch {
        Write-Log "Failed to stop service '$Name': $($_.Exception.Message)" -Level "warn"
        $Result.Notes += "Could not stop service '$Name': $($_.Exception.Message)"
        return $false
    }
}

function Start-WindowsService {
    param([string]$Name, [hashtable]$Result)
    try {
        Start-Service -Name $Name -ErrorAction Stop
        $Result.Notes += "Restarted service '$Name'"
    } catch {
        Write-Log "Failed to start service '$Name': $($_.Exception.Message)" -Level "warn"
        $Result.Notes += "Could not restart service '$Name': $($_.Exception.Message)"
    }
}

# ---------- Browser running detector --------------------------------------
function Test-BrowserRunning {
    <#
    .SYNOPSIS
        Returns $true when at least one process for a chromium-family browser
        (chrome / brave / msedge) is alive on the local machine.

    .PARAMETER ProcessName
        Bare process name without .exe (e.g. "chrome", "brave", "msedge").

    .NOTES
        Sweeping cache/SW folders while the browser is RUNNING is the #1 way
        to soft-corrupt the profile (orphan entries in Cache\index, desynced
        Service Worker\Database -> "extension may be corrupted" errors).
        Every chromium-family cleaner MUST gate its sweep behind this check.
    #>
    param([Parameter(Mandatory)] [string]$ProcessName)
    try {
        $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        return ($procs.Count -gt 0)
    } catch { return $false }
}

# ---------- Chromium cache sweep (chrome/brave/edge share this) -----------
function Invoke-ChromiumCacheSweep {
    <#
    .SYNOPSIS
        Safe sweep for chromium-family browsers (Chrome / Brave / Edge).

        SAFE TO SWEEP:
          Cache, Code Cache, GPUCache  -- pure HTTP caches, regenerated on demand.
          Service Worker\ScriptCache    -- compiled SW bytecode, regenerated.

        NEVER SWEPT:
          Service Worker\CacheStorage   -- this is the persistent caches.open()
            store used by extensions and PWAs (adblock filter lists, VPN session,
            tab-manager state). Despite the name, this is DATA not cache.
          IndexedDB, Local Storage, Login Data, Cookies, History, Preferences,
          Extension State, Local Extension Settings -- all extension data lives
          here and must remain untouched.

        SAFETY GATES:
          1. If the browser process is running, skip the entire sweep with a
             "close the browser first" note (sweeping live cache corrupts
             Cache\index AND Service Worker\Database -> "this extension may be
             corrupted" errors and silent extension disablement).
          2. ScriptCache is only swept when the browser is NOT running.

    .PARAMETER Result
        The category result hashtable; gets Count/Bytes/Locked accumulated.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$Result,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$ProcessName,
        [Parameter(Mandatory)] [string]$LogLabel,
        [string[]]$ProfilePatterns = @("Default", "Guest Profile"),
        [string]$ProfileRegex = '^Profile \d+$',
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        $Result.Notes += "$LogLabel not installed (no $Root)"
        return
    }

    # ── SAFETY GATE: refuse to sweep a running browser ──────────────────
    if (Test-BrowserRunning -ProcessName $ProcessName) {
        $msg = "$LogLabel ($ProcessName.exe) is RUNNING -- skipping cache sweep to avoid profile corruption. Close $LogLabel and re-run 'os clean'."
        $Result.Notes += $msg
        Write-Log $msg -Level "warn"
        return
    }

    $profiles = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
                  Where-Object { ($ProfilePatterns -contains $_.Name) -or ($_.Name -match $ProfileRegex) })

    # CacheStorage is INTENTIONALLY excluded -- see function header.
    $safeSubs = @(
        "Cache",
        "Code Cache",
        "GPUCache",
        "Service Worker\ScriptCache"
    )

    foreach ($p in $profiles) {
        foreach ($sub in $safeSubs) {
            $target = Join-Path $p.FullName $sub
            Invoke-PathSweep -Path $target -Result $Result -DryRun:$DryRun -LogPrefix "$LogLabel/$($p.Name)/$sub"
        }
    }
    $Result.Notes += "Skipped (preserved by design): Service Worker\CacheStorage, IndexedDB, Local Storage, Cookies, Extension State, Local Extension Settings"
}

# ---------- Status finalizer ----------------------------------------------
function Set-CleanResultStatus {
    param([hashtable]$Result, [switch]$DryRun)
    if ($DryRun) {
        $Result.Status = "dry-run"
        return
    }
    if ($Result.Locked -gt 0) {
        $Result.Status = "warn"
    } elseif ($Result.Count -eq 0 -and $Result.Notes.Count -gt 0 -and ($Result.Notes -join " ") -match "not present") {
        $Result.Status = "skip"
    } else {
        $Result.Status = "ok"
    }
}
