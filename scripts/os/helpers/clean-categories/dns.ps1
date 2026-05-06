<# Bucket A: dns -- ipconfig /flushdns #>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "dns" -Label "DNS resolver cache (flushdns)" -Bucket "A"

if ($DryRun) {
    $result.Notes += "DRY-RUN: would run 'ipconfig /flushdns'"
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
    return $result
}

try {
    $output = & ipconfig.exe /flushdns 2>&1
    if ($LASTEXITCODE -eq 0) {
        $result.Count = 1
        $result.Notes += "ipconfig /flushdns succeeded"
    } else {
        $result.Status = "warn"
        $result.Notes += "ipconfig exited ${LASTEXITCODE}: $output"
    }
} catch {
    $result.Status = "fail"
    $result.Notes += "ipconfig /flushdns failed: $($_.Exception.Message)"
    Write-Log "DNS flush failed: $($_.Exception.Message)" -Level "fail"
}

Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
