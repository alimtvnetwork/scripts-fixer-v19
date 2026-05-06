<#
.SYNOPSIS
    os power -- configure Windows display & sleep timeouts via powercfg.exe.

.DESCRIPTION
    Sets monitor (display), standby (sleep), disk, and hibernate timeouts
    on the ACTIVE power scheme. Defaults come from config.json -> "power"
    (all zeroes = Never). Flags can override per-invocation.

    Timeouts are minutes. 0 = Never (Windows convention for powercfg).

.EXAMPLES
    # Apply config.json defaults (Never for display + sleep)
    .\run.ps1 os power

    # Override: 15 min display, never sleep, AC only
    .\run.ps1 os power --display 15 --sleep 0 --ac-only

    # Reset everything to Never on AC and DC
    .\run.ps1 os power --never

    # Preview without applying
    .\run.ps1 os power --dry-run
#>
param(
    [int]$Display    = -1,
    [int]$Sleep      = -1,
    [int]$Disk       = -1,
    [int]$Hibernate  = -1,
    [switch]$Never,
    [switch]$AcOnly,
    [switch]$DcOnly,
    [switch]$DryRun,
    [switch]$Help
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

Initialize-Logging -ScriptName "OS Power Settings"

if ($Help) {
    Write-Host ""
    Write-Host "  os power -- set display/sleep/disk/hibernate timeouts" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Flags (minutes; 0 = Never):" -ForegroundColor Yellow
    Write-Host "    --display <N>      Monitor (display) timeout"
    Write-Host "    --sleep <N>        Standby (sleep) timeout"
    Write-Host "    --disk <N>         Disk spin-down timeout"
    Write-Host "    --hibernate <N>    Hibernate-after timeout"
    Write-Host "    --never            Set ALL four timeouts to 0 (Never) on AC + DC"
    Write-Host "    --ac-only          Apply only to AC (plugged in)"
    Write-Host "    --dc-only          Apply only to DC (battery)"
    Write-Host "    --dry-run          Preview without applying"
    Write-Host ""
    Write-Host "  Defaults (config.json -> power):" -ForegroundColor Yellow
    Write-Host "    monitorTimeoutMinutes   = $($config.power.monitorTimeoutMinutes)"
    Write-Host "    standbyTimeoutMinutes   = $($config.power.standbyTimeoutMinutes)"
    Write-Host "    diskTimeoutMinutes      = $($config.power.diskTimeoutMinutes)"
    Write-Host "    hibernateTimeoutMinutes = $($config.power.hibernateTimeoutMinutes)"
    Save-LogFile -Status "ok"
    exit 0
}

# -- Resolve effective values --------------------------------------------------
function Resolve-Value([int]$flag, [int]$default) {
    if ($Never)        { return 0 }
    if ($flag -ge 0)   { return $flag }
    return $default
}

$dispMin = Resolve-Value $Display   ([int]$config.power.monitorTimeoutMinutes)
$sleepMin= Resolve-Value $Sleep     ([int]$config.power.standbyTimeoutMinutes)
$diskMin = Resolve-Value $Disk      ([int]$config.power.diskTimeoutMinutes)
$hibMin  = Resolve-Value $Hibernate ([int]$config.power.hibernateTimeoutMinutes)

$applyAc = -not $DcOnly -and ($AcOnly -or [bool]$config.power.applyToAc)
$applyDc = -not $AcOnly -and ($DcOnly -or [bool]$config.power.applyToDc)
if ($AcOnly) { $applyDc = $false }
if ($DcOnly) { $applyAc = $false }

# -- Admin gate ---------------------------------------------------------------
$forwardArgs = @()
if ($Display   -ge 0) { $forwardArgs += @("-Display",   "$Display") }
if ($Sleep     -ge 0) { $forwardArgs += @("-Sleep",     "$Sleep") }
if ($Disk      -ge 0) { $forwardArgs += @("-Disk",      "$Disk") }
if ($Hibernate -ge 0) { $forwardArgs += @("-Hibernate", "$Hibernate") }
if ($Never)  { $forwardArgs += "-Never" }
if ($AcOnly) { $forwardArgs += "-AcOnly" }
if ($DcOnly) { $forwardArgs += "-DcOnly" }
if ($DryRun) { $forwardArgs += "-DryRun" }

if (-not $DryRun) {
    $isAdminOk = Assert-Admin -ScriptPath $MyInvocation.MyCommand.Definition -ForwardArgs $forwardArgs -LogMessages $logMessages
    if (-not $isAdminOk) {
        Save-LogFile -Status "fail"
        exit 1
    }
}

Write-Log $logMessages.power.header -Level "info"

# -- Show active scheme -------------------------------------------------------
try {
    $activeRaw = & powercfg.exe /GETACTIVESCHEME 2>&1
    if ($LASTEXITCODE -eq 0 -and $activeRaw) {
        $line = ($activeRaw | Out-String).Trim()
        if ($line -match 'GUID:\s*([0-9a-fA-F-]+)\s*\(([^)]+)\)') {
            $msg = $logMessages.power.schemeActivated `
                -replace '\{guid\}', $Matches[1] `
                -replace '\{name\}', $Matches[2]
            Write-Log $msg -Level "info"
        }
    }
} catch {
    $msg = $logMessages.power.schemeQueryFailed -replace '\{error\}', "$_"
    Write-Log $msg -Level "warn"
}

# -- Apply helper -------------------------------------------------------------
function Format-Minutes([int]$m) {
    if ($m -le 0) { return $logMessages.power.neverLabel }
    return "$m min"
}

function Invoke-Powercfg {
    param(
        [string]$Kind,           # display | sleep | disk | hibernate
        [string]$Scope,          # AC | DC
        [int]$Minutes
    )

    $verbMap = @{
        "AC" = @{ display="/CHANGE monitor-timeout-ac"; sleep="/CHANGE standby-timeout-ac"; disk="/CHANGE disk-timeout-ac"; hibernate="/CHANGE hibernate-timeout-ac" }
        "DC" = @{ display="/CHANGE monitor-timeout-dc"; sleep="/CHANGE standby-timeout-dc"; disk="/CHANGE disk-timeout-dc"; hibernate="/CHANGE hibernate-timeout-dc" }
    }
    $verb = $verbMap[$Scope][$Kind]
    $argList = "$verb $Minutes"

    $applyMsg = $logMessages.power.applying `
        -replace '\{kind\}',  $Kind `
        -replace '\{value\}', (Format-Minutes $Minutes) `
        -replace '\{scope\}', $Scope
    Write-Log $applyMsg -Level "info"

    if ($DryRun) { return $true }

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "powercfg.exe" `
            -ArgumentList ($verb.Split(' ') + @("$Minutes")) `
            -Wait -PassThru -NoNewWindow -RedirectStandardError $stderrFile
        $code = $proc.ExitCode
        if ($code -ne 0) {
            $err = ""
            if (Test-Path $stderrFile) { $err = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) }
            $msg = $logMessages.power.powercfgFailed `
                -replace '\{args\}',   $argList `
                -replace '\{code\}',   "$code" `
                -replace '\{stderr\}', ($err.Trim())
            Write-Log $msg -Level "fail"
            return $false
        }
        $okMsg = $logMessages.power.applied `
            -replace '\{kind\}',  $Kind `
            -replace '\{value\}', (Format-Minutes $Minutes) `
            -replace '\{scope\}', $Scope
        Write-Log $okMsg -Level "success"
        return $true
    } finally {
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

$results = @()
$kinds = @(
    @{ Name="display";   Value=$dispMin },
    @{ Name="sleep";     Value=$sleepMin },
    @{ Name="disk";      Value=$diskMin },
    @{ Name="hibernate"; Value=$hibMin }
)

$anyFail = $false
foreach ($k in $kinds) {
    $acOk = $true; $dcOk = $true
    if ($applyAc) { $acOk = Invoke-Powercfg -Kind $k.Name -Scope "AC" -Minutes $k.Value }
    if ($applyDc) { $dcOk = Invoke-Powercfg -Kind $k.Name -Scope "DC" -Minutes $k.Value }
    $status = if ($acOk -and $dcOk) { "ok" } else { "fail"; $anyFail = $true }
    $results += [pscustomobject]@{
        Kind   = $k.Name
        Ac     = if ($applyAc) { Format-Minutes $k.Value } else { "(skip)" }
        Dc     = if ($applyDc) { Format-Minutes $k.Value } else { "(skip)" }
        Status = $status
    }
}

# -- Summary ------------------------------------------------------------------
Write-Log $logMessages.power.summaryHeader -Level "info"
foreach ($r in $results) {
    $row = $logMessages.power.summaryRow `
        -replace '\{kind\}',   $r.Kind `
        -replace '\{ac\}',     $r.Ac `
        -replace '\{dc\}',     $r.Dc `
        -replace '\{status\}', $r.Status
    Write-Log $row -Level "info"
}

if ($DryRun) {
    Write-Log "Dry-run mode -- no changes applied." -Level "warn"
    Save-LogFile -Status "ok"
    exit 0
}

if ($anyFail) {
    Save-LogFile -Status "fail"
    exit 1
}

Write-Log $logMessages.power.allDone -Level "success"
Save-LogFile -Status "ok"
exit 0
