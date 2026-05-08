<#
    Bucket D: edge -- HTTP cache + GPU/code cache + (closed-only) SW ScriptCache.
    SAFETY: see chrome.ps1 / _sweep.ps1 :: Invoke-ChromiumCacheSweep.
#>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "edge" -Label "Microsoft Edge cache (all profiles, SW data preserved)" -Bucket "D"
$root   = Join-Path (Get-LocalAppDataPath) "Microsoft\Edge\User Data"

Invoke-ChromiumCacheSweep `
    -Result      $result `
    -Root        $root `
    -ProcessName "msedge" `
    -LogLabel    "edge" `
    -DryRun:$DryRun

Set-CleanResultStatus -Result $result -DryRun:$DryRun
return $result
