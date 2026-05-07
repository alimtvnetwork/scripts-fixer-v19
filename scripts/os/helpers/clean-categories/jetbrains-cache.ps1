<# Bucket F: jetbrains-cache -- IDE caches/logs under %LOCALAPPDATA%\JetBrains\<Product><Ver>\
   Cleans: caches\, log\, tmp\, system caches under \JetBrains\Toolbox\.cache (if any).
   Settings (config\), key maps, indexes (will rebuild), and project files SAFE.
   Targets: IntelliJ IDEA, PyCharm, WebStorm, Rider, GoLand, CLion, PhpStorm,
            RubyMine, AndroidStudio (handled separately), DataGrip, etc.
#>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "jetbrains-cache" -Label "JetBrains IDE caches + logs (settings + projects SAFE)" -Bucket "F"

$jbRoot = Join-Path (Get-LocalAppDataPath) "JetBrains"
$hasJb = Test-Path -LiteralPath $jbRoot
if (-not $hasJb) {
    $result.Notes += "JetBrains IDEs not installed (no $jbRoot)"
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
    return $result
}

try {
    $products = @(Get-ChildItem -LiteralPath $jbRoot -Directory -Force -ErrorAction SilentlyContinue)
} catch {
    Write-Log "jetbrains-cache enumerate failed at ${jbRoot}: $($_.Exception.Message)" -Level "warn"
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
    return $result
}

$skipNames = @("Toolbox", "Shared", "consentOptions")
$cacheSubs = @("caches", "log", "tmp")

foreach ($p in $products) {
    if ($p.Name -in $skipNames) { continue }
    # Android Studio is handled by clean-android-studio-cache.ps1
    if ($p.Name -like "AndroidStudio*") { continue }
    foreach ($sub in $cacheSubs) {
        $target = Join-Path $p.FullName $sub
        $isPresent = Test-Path -LiteralPath $target
        if (-not $isPresent) { continue }
        Invoke-PathSweep -Path $target -Result $result -DryRun:$DryRun -LogPrefix "jetbrains/$($p.Name)/$sub"
    }
}

# Optional Toolbox caches (settings SAFE)
$toolboxCache = Join-Path $jbRoot "Toolbox\cache"
if (Test-Path -LiteralPath $toolboxCache) {
    Invoke-PathSweep -Path $toolboxCache -Result $result -DryRun:$DryRun -LogPrefix "jetbrains/Toolbox/cache"
}

Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
