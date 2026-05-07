<# Bucket A: wu-download -- $env:WINDIR\SoftwareDistribution\Download\*
   Windows Update payload cache. Safe to wipe -- WU re-downloads as needed.
   We resolve %WINDIR% dynamically (don't hard-code C:\Windows): on systems
   where Windows is installed on D:\ or another volume, hard-coding would
   silently miss the cache. CODE RED: every path failure logs path + reason.
#>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "wu-download" -Label "Windows Update download cache (\$WINDIR\SoftwareDistribution\Download)" -Bucket "A"

# Resolve %WINDIR% from the environment, with a defensive fallback chain.
# Use [Environment]::GetEnvironmentVariable rather than $env:WINDIR -- under
# Set-StrictMode -Version Latest, $env:* drive lookups can throw
# "The variable 'X' cannot be retrieved because it has not been set" when the
# named env var is absent (PowerShell treats them as strict variables).
$windir = [Environment]::GetEnvironmentVariable("WINDIR")
if ([string]::IsNullOrWhiteSpace($windir)) {
    $windir = [Environment]::GetEnvironmentVariable("SystemRoot")
}
if ([string]::IsNullOrWhiteSpace($windir)) { $windir = "C:\Windows" }

if (-not (Test-Path -LiteralPath $windir)) {
    $msg = "Cannot resolve Windows directory: $windir does not exist"
    Write-Log "wu-download FAIL path=$windir reason=$msg" -Level "fail"
    $result.Status = "fail"
    $result.Notes += $msg
    return $result
}

$target = Join-Path $windir "SoftwareDistribution\Download"
$result.Notes += "WINDIR resolved to: $windir"
$result.Notes += "Target: $target"

if (-not (Test-Path -LiteralPath $target)) {
    $result.Notes += "Path not present: $target (no WU download cache)"
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
    return $result
}

# Stop wuauserv to release file handles -- WU re-creates the folder + restarts on next check.
# In dry-run we skip the service stop; we only enumerate.
$wuStopped = $false
if (-not $DryRun) {
    try {
        $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq "Running") {
            Stop-Service -Name wuauserv -Force -ErrorAction Stop
            $wuStopped = $true
            $result.Notes += "Stopped wuauserv to release file handles"
        }
    } catch {
        Write-Log "wu-download could not stop wuauserv: $($_.Exception.Message)" -Level "warn"
        $result.Notes += "wuauserv stop failed: $($_.Exception.Message) (continuing)"
    }
}

try {
    Invoke-PathSweep -Path $target -Result $result -DryRun:$DryRun -LogPrefix "wu-download"
} catch {
    Write-Log "wu-download FAIL path=$target reason=$($_.Exception.Message)" -Level "fail"
    $result.Status = "fail"
    $result.Notes += "Sweep failed at ${target}: $($_.Exception.Message)"
}

if ($wuStopped) {
    try {
        Start-Service -Name wuauserv -ErrorAction Stop
        $result.Notes += "Restarted wuauserv"
    } catch {
        Write-Log "wu-download could not restart wuauserv: $($_.Exception.Message)" -Level "warn"
        $result.Notes += "wuauserv restart failed: $($_.Exception.Message) (will start on next WU check)"
    }
}

Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
