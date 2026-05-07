<# Bucket A: wu-download -- %WINDIR%\SoftwareDistribution\Download\*
   Windows Update payload cache. Safe to wipe -- WU re-downloads as needed.
   We resolve %WINDIR% dynamically (don't hard-code C:\Windows): on systems
   where Windows is installed on D:\ or another volume, hard-coding would
   silently miss the cache. CODE RED: every path failure logs path + reason.

   IMPORTANT: do NOT put a literal "$WINDIR" token inside any double-quoted
   or single-quoted string that flows into Write-Log / Notes / Label. Under
   Set-StrictMode -Version Latest, several downstream consumers (regex
   highlighter, ExecutionContext.InvokeCommand.ExpandString) can re-evaluate
   the string and treat "$WINDIR" as a PS variable reference, throwing
   "The variable '$WINDIR' cannot be retrieved because it has not been set."
   Always say %WINDIR% in user-facing strings.
#>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "wu-download" -Label 'Windows Update download cache (%WINDIR%\SoftwareDistribution\Download)' -Bucket "A"

# Resolve %WINDIR% from the environment, with a defensive fallback chain.
# Use [Environment]::GetEnvironmentVariable rather than $env:WINDIR -- under
# Set-StrictMode -Version Latest, $env:* drive lookups can throw
# "The variable 'X' cannot be retrieved because it has not been set" when the
# named env var is absent. We also intentionally name the local $winDirPath
# (not $windir) to avoid any case-insensitive collision with the env: drive.
$winDirPath = [Environment]::GetEnvironmentVariable("WINDIR")
if ([string]::IsNullOrWhiteSpace($winDirPath)) {
    $winDirPath = [Environment]::GetEnvironmentVariable("SystemRoot")
}
if ([string]::IsNullOrWhiteSpace($winDirPath)) { $winDirPath = "C:\Windows" }

if (-not (Test-Path -LiteralPath $winDirPath)) {
    $msg = "Cannot resolve Windows directory: {0} does not exist" -f $winDirPath
    Write-Log ("wu-download FAIL path={0} reason={1}" -f $winDirPath, $msg) -Level "fail"
    $result.Status = "fail"
    $result.Notes += $msg
    return $result
}

$target = Join-Path $winDirPath "SoftwareDistribution\Download"
$result.Notes += ("WINDIR resolved to: {0}" -f $winDirPath)
$result.Notes += ("Target: {0}" -f $target)

if (-not (Test-Path -LiteralPath $target)) {
    $result.Notes += ("Path not present: {0} (no WU download cache)" -f $target)
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
        Write-Log ("wu-download could not stop wuauserv: {0}" -f $_.Exception.Message) -Level "warn"
        $result.Notes += ("wuauserv stop failed: {0} (continuing)" -f $_.Exception.Message)
    }
}

try {
    Invoke-PathSweep -Path $target -Result $result -DryRun:$DryRun -LogPrefix "wu-download"
} catch {
    Write-Log ("wu-download FAIL path={0} reason={1}" -f $target, $_.Exception.Message) -Level "fail"
    $result.Status = "fail"
    $result.Notes += ("Sweep failed at {0}: {1}" -f $target, $_.Exception.Message)
}

if ($wuStopped) {
    try {
        Start-Service -Name wuauserv -ErrorAction Stop
        $result.Notes += "Restarted wuauserv"
    } catch {
        Write-Log ("wu-download could not restart wuauserv: {0}" -f $_.Exception.Message) -Level "warn"
        $result.Notes += ("wuauserv restart failed: {0} (will start on next WU check)" -f $_.Exception.Message)
    }
}

Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
