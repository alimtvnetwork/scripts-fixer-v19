<#
    Bucket D: chrome -- HTTP cache + GPU/code cache + (closed-only) Service Worker ScriptCache.

    SAFETY: never wipes 'Service Worker\CacheStorage' (persistent caches.open()
    store used by adblockers / VPN extensions / tab managers). Refuses to run
    while chrome.exe is alive -- sweeping a live cache desyncs Cache\index +
    Service Worker\Database and triggers "this extension may be corrupted".
    See _sweep.ps1 :: Invoke-ChromiumCacheSweep for the full safety contract.
#>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "chrome" -Label "Chrome cache (all profiles, SW data preserved)" -Bucket "D"
$root   = Join-Path (Get-LocalAppDataPath) "Google\Chrome\User Data"

Invoke-ChromiumCacheSweep `
    -Result      $result `
    -Root        $root `
    -ProcessName "chrome" `
    -LogLabel    "chrome" `
    -DryRun:$DryRun

Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
