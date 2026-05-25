<#
.SYNOPSIS
    Disable Chrome's built-in AI (Gemini Nano / Optimization Guide On Device
    Model) and reclaim the 2-4 GB it consumes.

.DESCRIPTION
    Three-layer fix, applied together so component-updater cannot resurrect
    the model after we delete it:

      1. HKLM enterprise policies (requires admin -- gracefully skipped if not)
      2. Per-user Local State JSON patch (preserves every other chrome://flag)
      3. On-disk model cache sweep with bytes-freed report

    See spec/58-install-chrome/fix-ai.md for the full contract.

.PARAMETER DryRun
    Report only -- no registry write, no JSON patch, no file delete.

.PARAMETER Verify
    Print current state (policies + flag values + cache size) and exit.

.PARAMETER Restore
    Remove the policies and restore the most recent Local State backup.

.PARAMETER Yes
    Skip the "Chrome must be closed" interactive confirm.
#>

# Idempotent bootstrap of shared helpers (this file is dot-sourced from run.ps1
# but also callable standalone).
$_helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$_scriptDir  = Split-Path -Parent $_helpersDir
$_sharedDir  = Join-Path (Split-Path -Parent $_scriptDir) "shared"
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . (Join-Path $_sharedDir "logging.ps1")
}
if (-not (Get-Command Test-IsElevated -ErrorAction SilentlyContinue)) {
    $_admin = Join-Path $_sharedDir "admin-check.ps1"
    if (Test-Path $_admin) { . $_admin }
}

# -- Constants ---------------------------------------------------------------

$script:FixAi_PolicyKey = "HKLM:\SOFTWARE\Policies\Google\Chrome"
$script:FixAi_Policies  = @(
    "GenAiDefaultSettings",
    "GenAILocalFoundationalModelSettings",
    "HelpMeWriteSettings",
    "CreateThemesSettings",
    "TabOrganizerSettings",
    "TabCompareSettings",
    "HistorySearchSettings",
    "AutofillPredictionSettings"
)
# Flag-name (without trailing slot) -> slot index meaning "Disabled".
# slot 2 is the conventional "Disabled" position for binary flags in Chrome.
$script:FixAi_Flags = @(
    "optimization-guide-on-device-model",
    "prompt-api-for-gemini-nano",
    "summarization-api-for-gemini-nano",
    "writer-api-for-gemini-nano",
    "rewriter-api-for-gemini-nano"
)
$script:FixAi_DisabledSlot = 2

$script:FixAi_UserData = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
$script:FixAi_LocalState = Join-Path $script:FixAi_UserData "Local State"
$script:FixAi_CacheRoots = @(
    (Join-Path $script:FixAi_UserData "OptimizationGuideOnDeviceModel"),
    (Join-Path $script:FixAi_UserData "OptGuideOnDeviceModel")
)

# -- Small utilities ---------------------------------------------------------

function Get-FixAi-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0L }
        return [int64]$sum
    } catch {
        Write-Log "Could not measure folder: $Path  (reason: $($_.Exception.Message))" -Level "warn"
        return 0L
    }
}

function Format-FixAi-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-FixAi-ChromeProcesses {
    @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue)
}

# -- Layer 1: HKLM policies --------------------------------------------------

function Set-FixAi-Policies {
    param([switch]$DryRun)

    $elevated = $true
    if (Get-Command Test-IsElevated -ErrorAction SilentlyContinue) {
        $elevated = Test-IsElevated
    }
    if (-not $elevated) {
        Write-Log "Skipping HKLM policy half: shell is not elevated. Re-run from an admin PowerShell to apply Chrome enterprise policies." -Level "warn"
        return @{ Set = 0; Total = $script:FixAi_Policies.Count; Skipped = $true }
    }

    if (-not $DryRun -and -not (Test-Path $script:FixAi_PolicyKey)) {
        try {
            New-Item -Path $script:FixAi_PolicyKey -Force | Out-Null
        } catch {
            Write-Log "Cannot create policy key: $script:FixAi_PolicyKey  (reason: $($_.Exception.Message))" -Level "fail"
            return @{ Set = 0; Total = $script:FixAi_Policies.Count; Skipped = $false }
        }
    }

    $set = 0
    foreach ($name in $script:FixAi_Policies) {
        try {
            if ($DryRun) {
                Write-Log "DRY-RUN: would set $script:FixAi_PolicyKey\$name = 1 (REG_DWORD)" -Level "info"
            } else {
                New-ItemProperty -Path $script:FixAi_PolicyKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
                Write-Log "Policy set: $name = 1" -Level "success"
            }
            $set++
        } catch {
            Write-Log "Cannot write HKLM policy $script:FixAi_PolicyKey\$name  (reason: $($_.Exception.Message))" -Level "fail"
        }
    }
    return @{ Set = $set; Total = $script:FixAi_Policies.Count; Skipped = $false }
}

function Remove-FixAi-Policies {
    if (-not (Test-Path $script:FixAi_PolicyKey)) {
        Write-Log "Policy key not present (already clean): $script:FixAi_PolicyKey" -Level "info"
        return
    }
    foreach ($name in $script:FixAi_Policies) {
        try {
            Remove-ItemProperty -Path $script:FixAi_PolicyKey -Name $name -ErrorAction Stop
            Write-Log "Policy removed: $name" -Level "success"
        } catch {
            Write-Log "Policy not present (clean) or unremovable: $name  (reason: $($_.Exception.Message))" -Level "info"
        }
    }
}

# -- Layer 2: Local State JSON patch ----------------------------------------

function Set-FixAi-LocalStateFlags {
    param([switch]$DryRun, [switch]$Yes)

    if (-not (Test-Path -LiteralPath $script:FixAi_LocalState)) {
        Write-Log "Local State not found at: $script:FixAi_LocalState  (reason: Chrome never launched on this profile or user-data dir differs)" -Level "warn"
        return @{ Patched = 0; Total = $script:FixAi_Flags.Count; Skipped = $true; BackupPath = $null }
    }

    $alive = Get-FixAi-ChromeProcesses
    if ($alive.Count -gt 0) {
        $pids = ($alive | Select-Object -ExpandProperty Id) -join ','
        if (-not $Yes -or -not $DryRun) {
            Write-Log "Refusing to patch Local State: chrome.exe is alive (PIDs $pids). Close Chrome and retry, or pass -Yes to proceed (Chrome may overwrite the patch on exit)." -Level "fail"
            return @{ Patched = 0; Total = $script:FixAi_Flags.Count; Skipped = $true; BackupPath = $null }
        }
    }

    try {
        $raw  = Get-Content -LiteralPath $script:FixAi_LocalState -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    } catch {
        Write-Log "Cannot parse Local State JSON: $script:FixAi_LocalState  (reason: $($_.Exception.Message))" -Level "fail"
        return @{ Patched = 0; Total = $script:FixAi_Flags.Count; Skipped = $true; BackupPath = $null }
    }

    if (-not $json.PSObject.Properties.Match('browser')) {
        $json | Add-Member -NotePropertyName 'browser' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if (-not $json.browser.PSObject.Properties.Match('enabled_labs_experiments')) {
        $json.browser | Add-Member -NotePropertyName 'enabled_labs_experiments' -NotePropertyValue @() -Force
    }

    $existing = @($json.browser.enabled_labs_experiments)
    # Drop any prior slots for our flags so we don't accumulate dupes,
    # then append the disabled slot. All OTHER experiments are preserved.
    $kept = @($existing | Where-Object {
        $entry = $_
        -not ($script:FixAi_Flags | Where-Object { $entry -like "$_@*" })
    })
    $additions = $script:FixAi_Flags | ForEach-Object { "$_@$($script:FixAi_DisabledSlot)" }
    $merged = @($kept) + @($additions)
    $json.browser.enabled_labs_experiments = $merged

    if ($DryRun) {
        Write-Log "DRY-RUN: would write $($additions.Count) flag entries into $script:FixAi_LocalState (preserving $($kept.Count) existing)" -Level "info"
        foreach ($a in $additions) { Write-Log "  + $a" -Level "info" }
        return @{ Patched = $additions.Count; Total = $script:FixAi_Flags.Count; Skipped = $false; BackupPath = $null }
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backup = "$script:FixAi_LocalState.bak-fixai-$stamp"
    try {
        Copy-Item -LiteralPath $script:FixAi_LocalState -Destination $backup -Force
        Write-Log "Backup written: $backup" -Level "info"
    } catch {
        Write-Log "Could not write backup to $backup  (reason: $($_.Exception.Message))" -Level "fail"
        return @{ Patched = 0; Total = $script:FixAi_Flags.Count; Skipped = $true; BackupPath = $null }
    }

    try {
        $out = $json | ConvertTo-Json -Depth 100 -Compress
        # Local State is written without BOM by Chrome; match that.
        [System.IO.File]::WriteAllText($script:FixAi_LocalState, $out, (New-Object System.Text.UTF8Encoding $false))
        Write-Log "Local State patched: $($additions.Count) AI flag(s) disabled, $($kept.Count) other flag(s) preserved" -Level "success"
        return @{ Patched = $additions.Count; Total = $script:FixAi_Flags.Count; Skipped = $false; BackupPath = $backup }
    } catch {
        Write-Log "Cannot write Local State $script:FixAi_LocalState  (reason: $($_.Exception.Message))" -Level "fail"
        return @{ Patched = 0; Total = $script:FixAi_Flags.Count; Skipped = $true; BackupPath = $backup }
    }
}

function Restore-FixAi-LocalState {
    if (-not (Test-Path -LiteralPath $script:FixAi_UserData)) {
        Write-Log "User-Data folder missing: $script:FixAi_UserData  (reason: nothing to restore)" -Level "warn"
        return
    }
    $backups = @(Get-ChildItem -LiteralPath $script:FixAi_UserData -Filter "Local State.bak-fixai-*" -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) {
        Write-Log "No fix-ai backup found in: $script:FixAi_UserData  (reason: nothing to restore)" -Level "warn"
        return
    }
    $newest = $backups[0]
    try {
        Copy-Item -LiteralPath $newest.FullName -Destination $script:FixAi_LocalState -Force
        Write-Log "Restored Local State from: $($newest.FullName)" -Level "success"
    } catch {
        Write-Log "Cannot restore Local State from $($newest.FullName)  (reason: $($_.Exception.Message))" -Level "fail"
    }
}

# -- Layer 3: cache sweep ----------------------------------------------------

function Clear-FixAi-ModelCache {
    param([switch]$DryRun)
    $totalFreed = 0L
    $sweptCount = 0
    foreach ($root in $script:FixAi_CacheRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            Write-Log "Cache root missing: $root  (reason: already clean)" -Level "info"
            continue
        }
        $size = Get-FixAi-FolderSize -Path $root
        if ($DryRun) {
            Write-Log "DRY-RUN: would delete $root ($(Format-FixAi-Bytes $size))" -Level "info"
            $totalFreed += $size
            $sweptCount++
            continue
        }
        try {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            Write-Log "Cache swept: $root ($(Format-FixAi-Bytes $size) freed)" -Level "success"
            $totalFreed += $size
            $sweptCount++
        } catch {
            Write-Log "Cannot delete cache root $root  (reason: $($_.Exception.Message))" -Level "fail"
        }
    }
    return @{ BytesFreed = $totalFreed; Roots = $sweptCount }
}

# -- Verify ------------------------------------------------------------------

function Show-FixAi-Status {
    Write-Log "Verifying Chrome AI state..." -Level "info"

    # Policies
    $policySet = 0
    if (Test-Path $script:FixAi_PolicyKey) {
        $props = Get-ItemProperty -Path $script:FixAi_PolicyKey -ErrorAction SilentlyContinue
        foreach ($name in $script:FixAi_Policies) {
            if ($props -and $props.PSObject.Properties.Match($name) -and [int]$props.$name -eq 1) {
                $policySet++
            }
        }
    }
    Write-Log ("Policies set        : {0}/{1}" -f $policySet, $script:FixAi_Policies.Count) -Level $(if ($policySet -eq $script:FixAi_Policies.Count) {'success'} else {'warn'})

    # Flags
    $flagSet = 0
    if (Test-Path -LiteralPath $script:FixAi_LocalState) {
        try {
            $j = (Get-Content -LiteralPath $script:FixAi_LocalState -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($j.PSObject.Properties.Match('browser') -and $j.browser.PSObject.Properties.Match('enabled_labs_experiments')) {
                $entries = @($j.browser.enabled_labs_experiments)
                foreach ($f in $script:FixAi_Flags) {
                    if ($entries -contains "$f@$($script:FixAi_DisabledSlot)") { $flagSet++ }
                }
            }
        } catch {
            Write-Log "Cannot read Local State to verify flags: $script:FixAi_LocalState  (reason: $($_.Exception.Message))" -Level "warn"
        }
    } else {
        Write-Log "Local State not found at: $script:FixAi_LocalState  (reason: Chrome never launched)" -Level "warn"
    }
    Write-Log ("Flags disabled      : {0}/{1}" -f $flagSet, $script:FixAi_Flags.Count) -Level $(if ($flagSet -eq $script:FixAi_Flags.Count) {'success'} else {'warn'})

    # Cache
    $cacheTotal = 0L
    foreach ($root in $script:FixAi_CacheRoots) {
        $cacheTotal += Get-FixAi-FolderSize -Path $root
    }
    Write-Log ("Model cache on disk : {0}" -f (Format-FixAi-Bytes $cacheTotal)) -Level $(if ($cacheTotal -eq 0) {'success'} else {'warn'})

    # Chrome alive?
    $alive = Get-FixAi-ChromeProcesses
    Write-Log ("chrome.exe          : {0}" -f $(if ($alive.Count -gt 0) { "running (PIDs $((@($alive | Select-Object -ExpandProperty Id)) -join ','))" } else { "not running" })) -Level "info"
}

# -- Public entry point ------------------------------------------------------

function Invoke-ChromeFixAi {
    param(
        [switch]$DryRun,
        [switch]$Verify,
        [switch]$Restore,
        [switch]$Yes
    )

    if ($Verify) { Show-FixAi-Status; return $true }

    if ($Restore) {
        Write-Log "Restoring previous Chrome AI configuration..." -Level "info"
        Remove-FixAi-Policies
        Restore-FixAi-LocalState
        Show-FixAi-Status
        return $true
    }

    $mode = if ($DryRun) { "DRY-RUN" } else { "APPLY" }
    Write-Log "Chrome fix-ai: disabling Gemini Nano / on-device model ($mode)" -Level "info"

    $polRes  = Set-FixAi-Policies          -DryRun:$DryRun
    $flagRes = Set-FixAi-LocalStateFlags   -DryRun:$DryRun -Yes:$Yes
    $cacheRes = Clear-FixAi-ModelCache     -DryRun:$DryRun

    Write-Host ""
    Write-Log "Summary:" -Level "info"
    $polLabel = if ($polRes.Skipped) { "skipped (not elevated)" } else { "$($polRes.Set)/$($polRes.Total)" }
    Write-Log ("  Policies set        : {0}" -f $polLabel) -Level $(if ($polRes.Skipped) {'warn'} elseif ($polRes.Set -eq $polRes.Total) {'success'} else {'warn'})
    $flagLabel = if ($flagRes.Skipped) { "skipped" } else { "$($flagRes.Patched)/$($flagRes.Total)  (other flags preserved)" }
    Write-Log ("  Flags patched       : {0}" -f $flagLabel) -Level $(if ($flagRes.Skipped) {'warn'} elseif ($flagRes.Patched -eq $flagRes.Total) {'success'} else {'warn'})
    Write-Log ("  Cache swept         : {0} freed across {1} root(s)" -f (Format-FixAi-Bytes $cacheRes.BytesFreed), $cacheRes.Roots) -Level "success"

    $isOk = (-not $flagRes.Skipped) -and ($cacheRes.Roots -ge 0)
    return $isOk
}
