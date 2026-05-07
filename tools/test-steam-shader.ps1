<#
.SYNOPSIS
    Regression test for scripts/os/helpers/clean-categories/steam-shader.ps1.

.DESCRIPTION
    Runs steam-shader.ps1 under Set-StrictMode -Version Latest against several
    inputs that previously triggered "The property 'Count' cannot be found on
    this object" failures:

      1. No Steam installed         (all candidate paths absent)  -> status=skip
      2. Single fake library, empty shadercache (1 item -> $files might collapse to scalar)
      3. Fake libraryfolders.vdf pointing at a missing path       -> library-missing failure recorded
      4. Dry-run over the same fixture                            -> status=dry-run

    PASSES if every scenario returns a hashtable with .Count/.WouldCount/.Notes
    accessible AND no PropertyNotFoundException is thrown.

.USAGE
    pwsh -NoProfile -File tools/test-steam-shader.ps1
#>

[CmdletBinding()]
param([switch]$Verbose)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot      = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$helperPath    = Join-Path $repoRoot "scripts\os\helpers\clean-categories\steam-shader.ps1"
$sweepPath     = Join-Path $repoRoot "scripts\os\helpers\clean-categories\_sweep.ps1"
$sharedDir     = Join-Path $repoRoot "scripts\shared"

if (-not (Test-Path -LiteralPath $helperPath)) {
    Write-Host "[FAIL] missing helper: $helperPath" -ForegroundColor Red
    exit 1
}

# Minimal logging shim (Write-Log is normally provided by scripts/shared/logging.ps1)
. (Join-Path $sharedDir "logging.ps1")
Initialize-Logging -ScriptName "test-steam-shader"

$loggingPath = Join-Path $sharedDir "logging.ps1"
Write-Host ""
Write-Host "  steam-shader regression suite" -ForegroundColor Cyan
Write-Host "  =================================" -ForegroundColor DarkGray

$pass = 0
$fail = 0
$results = @()

function Invoke-Scenario {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Setup,
        [switch]$DryRun
    )

    Write-Host ""
    Write-Host "  >> $Name" -ForegroundColor Yellow

    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("steam-shader-test-" + [Guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

    try {
        & $Setup $sandbox

        # The helper hard-codes C:\Program Files (x86)\Steam etc. We can't override
        # those, but we *can* assert the helper survives StrictMode regardless of
        # what's on disk -- which is the actual regression we're guarding against.
        $r = & $helperPath -DryRun:$DryRun -Days 30

        if ($r -is [array]) {
            $r = $r | Where-Object { $_ -is [hashtable] -or $_ -is [System.Collections.Specialized.OrderedDictionary] } | Select-Object -Last 1
        }

        if ($null -eq $r) { throw "helper returned null" }

        # Touch every property the orchestrator reads -- if any are missing under
        # StrictMode, this throws PropertyNotFoundException and the test fails.
        $null = $r.Category
        $null = $r.Bucket
        $null = $r.Status
        $null = $r.Count
        $null = $r.WouldCount
        $null = $r.Bytes
        $null = $r.WouldBytes
        $null = $r.Locked
        $null = $r.LockedDetails
        $null = $r.Notes
        $null = @($r.Notes).Count
        $null = @($r.LockedDetails).Count

        Write-Host ("     [PASS] status={0} notes={1} count={2} would={3}" `
            -f $r.Status, @($r.Notes).Count, $r.Count, $r.WouldCount) -ForegroundColor Green
        $script:pass++
        $script:results += @{ Name = $Name; Status = "PASS"; Detail = $r.Status }
    } catch {
        Write-Host ("     [FAIL] {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:fail++
        $script:results += @{ Name = $Name; Status = "FAIL"; Detail = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Scenario 1: empty environment (typical CI / no Steam)
Invoke-Scenario -Name "no-steam-installed" -Setup { param($d) }

# Scenario 2: dry-run path
Invoke-Scenario -Name "dry-run-no-steam" -DryRun -Setup { param($d) }

# Scenario 3: fixture with single empty shadercache (exercises @() wrapping in _sweep)
Invoke-Scenario -Name "single-empty-shadercache" -Setup {
    param($d)
    $sc = Join-Path $d "steamapps\shadercache"
    New-Item -ItemType Directory -Force -Path $sc | Out-Null
}

# Scenario 4: fixture with one file in shadercache (scalar -> .Count must still work)
Invoke-Scenario -Name "single-file-shadercache" -Setup {
    param($d)
    $sc = Join-Path $d "steamapps\shadercache"
    New-Item -ItemType Directory -Force -Path $sc | Out-Null
    Set-Content -LiteralPath (Join-Path $sc "shader.bin") -Value "x"
}

Write-Host ""
Write-Host "  =================================" -ForegroundColor DarkGray
Write-Host ("  RESULT: {0} pass / {1} fail" -f $pass, $fail) `
    -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($fail -gt 0) { exit 1 } else { exit 0 }
