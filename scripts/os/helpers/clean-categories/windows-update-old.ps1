<# Bucket G: windows-update-old -- DISM ResetBase (DESTRUCTIVE, consent-gated) #>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "windows-update-old" -Label "Old Windows Update components (DISM)" -Bucket "G" -Destructive

$consented = Confirm-DestructiveCategory -Category "windows-update-old" `
    -Warning "Removes ability to UNINSTALL past Windows updates. Operation can take 10-30 minutes." `
    -AutoYes:$Yes -DryRun:$DryRun
if (-not $consented) {
    $result.Status = "skip"
    $result.Notes += "Consent declined"
    return $result
}

if ($DryRun) {
    $result.WouldCount = 1
    $result.Notes += "DRY-RUN: would run 'dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase'"
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
    return $result
}

try {
    $output = & dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
    if ($LASTEXITCODE -eq 0) {
        $result.Count = 1
        $result.Notes += "DISM ResetBase succeeded"
    } else {
        $result.Status = "warn"
        $result.Notes += "DISM exited ${LASTEXITCODE}: $($output | Select-Object -Last 5)"
    }
} catch {
    $result.Status = "fail"
    $result.Notes += "DISM ResetBase failed: $($_.Exception.Message)"
    Write-Log "windows-update-old DISM failed: $($_.Exception.Message)" -Level "fail"
}
Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
