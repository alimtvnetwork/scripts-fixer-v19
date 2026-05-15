<#
.SYNOPSIS
    Single-category runner. Invoked by scripts/os/run.ps1 for any
    `os clean-<name>` subcommand. Loads the matching helper, runs it once,
    prints a single-row summary block, exits 0/1.
#>
param(
    [Parameter(Mandatory)][string]$Category,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Argv = @()
)

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

$helpersDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptDir     = Split-Path -Parent $helpersDir
$sharedDir     = Join-Path (Split-Path -Parent $scriptDir) "shared"
$categoriesDir = Join-Path $helpersDir "clean-categories"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "json-utils.ps1")
. (Join-Path $helpersDir "_common.ps1")
. (Join-Path $categoriesDir "_sweep.ps1")

$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")
$script:LogMessages = $logMessages

Initialize-Logging -ScriptName "OS Clean: $Category"

# Defensive guard: if the caller mis-splatted args (e.g. used the
# automatic $args variable inside a scriptblock), $Category may end up
# bound to a literal flag like '-Category'. Refuse early with a clear
# diagnostic that prints the full argv we actually received, so the
# real call site can be located.
if ($Category -match '^-' -or [string]::IsNullOrWhiteSpace($Category) -or $Category -match '^\s') {
    $argvDump = if ($Argv) { ($Argv | ForEach-Object { "'$_'" }) -join ' ' } else { '<empty>' }
    Write-Log "Invalid -Category value '$Category' passed to clean-runner.ps1. Remaining argv: $argvDump. Likely a caller used `$args inside a scriptblock and splatted it (rename to e.g. `$runnerArgs)." -Level "fail"
    Save-LogFile -Status "fail"
    exit 1
}

$dryRun = Test-DryRunSwitch -Argv $Argv
$autoYes = Test-YesSwitch -Argv $Argv
$days = Get-DaysArg -Argv $Argv -Default 30

# -Verbose: forward to category helpers that opt into registry-trace.
# Recognised tokens (parsed by Test-VerboseSwitch in registry-trace.ps1):
#   --verbose | -verbose | /verbose
$verboseTracePath = Join-Path $sharedDir "registry-trace.ps1"
$isVerbose = $false
if (Test-Path -LiteralPath $verboseTracePath) {
    . $verboseTracePath
    $isVerbose = Test-VerboseSwitch -Argv $Argv

    # --summary-json: strip from $Argv (the category helper uses
    # [CmdletBinding()] and would reject the unknown switch) and propagate
    # via env so its Close-RegistryTrace call emits a JSON summary line.
    if (Test-SummaryJsonSwitch -Argv $Argv) {
        $Argv = Remove-SummaryJsonSwitch -Argv $Argv
        $env:REGTRACE_SUMMARY_JSON = "1"
        Set-RegistryTraceSummaryJson -Enabled $true
    }

    # --summary-tail N: control how many recent trace lines the end-of-run
    # summary prints (default 20, 0 = totals only). Strip both the flag and
    # its value from $Argv before forwarding; propagate via env so the
    # spawned category helper's Close-RegistryTrace honours it.
    # --summary-tail-warn (opt-in): emit a [ WARN ] when an invalid value
    # is dropped, instead of silently falling back to default 20.
    # --summary-tail-quiet (override): suppress that warning while keeping
    # the silent fallback. No-op without --summary-tail-warn.
    $wantsTailWarn  = Test-SummaryTailWarnSwitch  -Argv $Argv
    $wantsTailQuiet = Test-SummaryTailQuietSwitch -Argv $Argv
    if ($wantsTailWarn)  { $Argv = Remove-SummaryTailWarnSwitch  -Argv $Argv }
    if ($wantsTailQuiet) { $Argv = Remove-SummaryTailQuietSwitch -Argv $Argv }
    $emitTailWarn = $wantsTailWarn -and -not $wantsTailQuiet
    $summaryTailArg = Get-SummaryTailArg -Argv $Argv
    if ($null -ne $summaryTailArg) {
        $Argv = Remove-SummaryTailArg -Argv $Argv
        $env:REGTRACE_SUMMARY_TAIL = "$summaryTailArg"
    } elseif ($emitTailWarn) {
        $tailRaw = Get-SummaryTailRaw -Argv $Argv
        if ($null -ne $tailRaw -and $tailRaw.Present) {
            Write-SummaryTailWarning -RawInfo $tailRaw
            $Argv = Remove-SummaryTailArg -Argv $Argv
        }
    }
}

$helperPath = Join-Path $categoriesDir "$Category.ps1"
if (-not (Test-Path -LiteralPath $helperPath)) {
    Write-Log "Unknown clean category '$Category'. Helper missing at: ${helperPath}" -Level "fail"
    Save-LogFile -Status "fail"
    exit 1
}

# Admin re-launch
$forwardArgs = @("clean-$Category") + $Argv
$isAdminOk = Assert-Admin -ScriptPath (Join-Path $scriptDir "run.ps1") `
                          -ForwardArgs $forwardArgs -LogMessages $logMessages
if (-not $isAdminOk) {
    Save-LogFile -Status "fail"
    exit 1
}

$mode = if ($dryRun) { "DRY-RUN" } else { "LIVE" }
Write-Host ""
Write-Host "  os clean-$Category -- $mode" -ForegroundColor Cyan
Write-Host "  =========================================" -ForegroundColor DarkGray
Write-Host ""

$r = $null
try {
    # Only forward -Verbose to helpers that declare [CmdletBinding()] (currently
    # explorer-mru). Splatting an empty hashtable is a no-op for non-cmdlet
    # helpers, so this is the safest universal forwarding pattern.
    $verboseSplat = @{}
    if ($isVerbose) {
        $firstLine = Get-Content -LiteralPath $helperPath -TotalCount 12 -ErrorAction SilentlyContinue
        $hasCmdletBinding = ($firstLine -join "`n") -match '\[CmdletBinding\(\)\]'
        if ($hasCmdletBinding) { $verboseSplat['Verbose'] = $true }
    }
    $r = & $helperPath -DryRun:$dryRun -Yes:$autoYes -Days $days @verboseSplat
    if ($r -is [array]) {
        $r = $r | Where-Object { $_ -is [hashtable] -or $_ -is [System.Collections.Specialized.OrderedDictionary] } | Select-Object -Last 1
    }
} catch {
    Write-Log "Category '$Category' threw at ${helperPath}: $($_.Exception.Message)" -Level "fail"
    Save-LogFile -Status "fail"
    exit 1
}

if ($null -eq $r) {
    Write-Log "Category '$Category' returned null" -Level "fail"
    Save-LogFile -Status "fail"
    exit 1
}

# Single-row summary
Write-Host ""
$statusColor = switch ($r.Status) {
    "ok"      { "Green" }
    "warn"    { "Yellow" }
    "skip"    { "DarkGray" }
    "fail"    { "Red" }
    "dry-run" { "Cyan" }
    default   { "Gray" }
}
if ($dryRun) {
    Write-Host ("    [{0}] {1,-22} would-items: {2,5}  would-free: {3,8} MB  [{4}]" `
        -f $r.Bucket, $r.Category, $r.WouldCount, ([Math]::Round($r.WouldBytes/1MB,2)), $r.Status.ToUpper()) -ForegroundColor $statusColor
} else {
    Write-Host ("    [{0}] {1,-22} items: {2,5}  freed: {3,8} MB  locked: {4,4}  [{5}]" `
        -f $r.Bucket, $r.Category, $r.Count, ([Math]::Round($r.Bytes/1MB,2)), $r.Locked, $r.Status.ToUpper()) -ForegroundColor $statusColor
}

if ($r.Notes -and $r.Notes.Count -gt 0) {
    foreach ($n in $r.Notes) {
        Write-Host ("        - {0}" -f $n) -ForegroundColor DarkGray
    }
}

if ($r.LockedDetails -and $r.LockedDetails.Count -gt 0) {
    Write-Host ""
    Write-Host "  [ LOCKED FILES ]" -ForegroundColor Yellow
    foreach ($lk in $r.LockedDetails | Select-Object -First 50) {
        Write-Host ("    {0}" -f $lk.Path) -ForegroundColor DarkYellow
        Write-Host ("        reason: {0}" -f $lk.Reason) -ForegroundColor DarkGray
    }
}

Write-Host ""
Save-LogFile -Status $r.Status
exit 0
