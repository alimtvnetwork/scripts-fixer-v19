<# Bucket G: steam-shader -- <SteamLibrary>\steamapps\shadercache #>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "steam-shader" -Label "Steam shader cache" -Bucket "G"

# Default install + parse libraryfolders.vdf for additional libraries
$candidates = @(
    "C:\Program Files (x86)\Steam",
    "C:\Program Files\Steam",
    (Join-Path (Get-LocalAppDataPath) "Steam")
)
$libraries = @()
foreach ($c in $candidates) {
    if (-not (Test-Path -LiteralPath $c)) { continue }
    $libraries += $c
    $vdf = Join-Path $c "steamapps\libraryfolders.vdf"
    if (Test-Path -LiteralPath $vdf) {
        try {
            $content = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
            $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
            foreach ($m in $matches) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if (Test-Path -LiteralPath $p) { $libraries += $p }
            }
        } catch {
            Write-Log "steam-shader: failed parsing ${vdf}: $($_.Exception.Message)" -Level "warn"
        }
    }
}

$libraries = @($libraries | Select-Object -Unique)
if ($libraries.Count -eq 0) {
    $result.Notes += "Steam not installed"
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
    return $result
}

foreach ($lib in $libraries) {
    $sc = Join-Path $lib "steamapps\shadercache"
    Invoke-PathSweep -Path $sc -Result $result -DryRun:$DryRun -LogPrefix "steam-shader"
}
Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
