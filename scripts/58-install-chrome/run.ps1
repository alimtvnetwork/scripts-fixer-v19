# --------------------------------------------------------------------------
#  Script 58 -- Install Google Chrome
#  Mechanism: Chocolatey (googlechrome) with official standalone installer fallback
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0)]
    [string]$Command = "all",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [string]$Method = "auto",
    [switch]$WithExt,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir  = Join-Path (Split-Path -Parent $scriptDir) "shared"

. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "resolved.ps1")
. (Join-Path $sharedDir "git-pull.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "installed.ps1")
. (Join-Path $sharedDir "choco-utils.ps1")
. (Join-Path $sharedDir "install-paths.ps1")

. (Join-Path $scriptDir "helpers\chrome.ps1")
. (Join-Path $scriptDir "helpers\extensions.ps1")

$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

if ($Help -or $Command -eq "--help") {
    Show-ScriptHelp -LogMessages $logMessages
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Triple-path install trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "Google Chrome" `
    -Source "https://chocolatey.org/install (pkg: googlechrome)" `
    -Temp   ($env:TEMP + "\chocolatey") `
    -Target ($env:ProgramFiles + "\Google\Chrome\Application")
Initialize-Logging -ScriptName $logMessages.scriptName

try {

    Invoke-GitPull

    $cmd = $Command.ToLower().Trim()

    # ── Extension subcommands ────────────────────────────────────────────
    $isExtMode    = $cmd -in @("ext","extension","extensions")
    $isExtAllMode = $cmd -in @("ext-all","extall","ext_all","all-ext","extensions-all")
    $isExtUrlMode = $cmd -in @("ext-url","exturl","ext-urls","exturls","ext-from-url")
    $isExtUrlAllMode = $cmd -in @("ext-url-all","exturlall","ext-urls-all","ext-from-urls-all","all-ext-url")
    $isWithExt    = $cmd -in @("with-ext","withext","plus-ext","chrome+ext","chrome-with-ext") -or $WithExt

    if ($isExtMode) {
        $sub = if ($Rest -and $Rest.Count -gt 0) { $Rest[0].ToLower() } else { "" }
        if (-not $sub -or $sub -eq "list") {
            Show-ChromeExtensionCatalog -ExtConfig $config.extensions
            return
        }
        # `ext <name1,name2,...>`  or  `ext name1 name2 name3`
        $names = @()
        foreach ($r in $Rest) {
            foreach ($t in ($r -split ',')) {
                $tt = $t.Trim()
                if ($tt) { $names += $tt }
            }
        }
        if ($names.Count -eq 0) { $names = @("all") }
        Install-ChromeExtensions -ExtConfig $config.extensions -Names $names -Method $Method | Out-Null
        Write-Log $logMessages.messages.setupComplete -Level "success"
        return
    }

    if ($isExtAllMode) {
        Install-ChromeExtensions -ExtConfig $config.extensions -Names @("all") -Method $Method | Out-Null
        Write-Log $logMessages.messages.setupComplete -Level "success"
        return
    }

    # ── Install one or many extensions from raw Chrome Web Store URLs ───
    # Usage:
    #   .\run.ps1 -I 58 ext-url     <url> [<url> ...]   # install N URLs
    #   .\run.ps1 -I 58 ext-url-all <url1,url2,url3>     # explicit batch alias
    if ($isExtUrlMode -or $isExtUrlAllMode) {
        $urls = @()
        foreach ($r in $Rest) {
            foreach ($t in ($r -split '[,\s]+')) {
                $tt = $t.Trim()
                if ($tt) { $urls += $tt }
            }
        }
        if ($urls.Count -eq 0) {
            Write-Log "No URLs provided. Usage: .\run.ps1 -I 58 ext-url <url> [<url> ...]" -Level "error"
            return
        }

        $picked = Resolve-ChromeExtensionsFromUrls -Urls $urls
        if (-not $picked -or $picked.Count -eq 0) {
            Write-Log "No valid Chrome Web Store URLs to install." -Level "warn"
            return
        }

        # Build a thin ExtConfig that re-uses the global registryRoot/updateUrl
        # but swaps in the URL-derived list -- so the existing registry/webstore
        # paths can install them unchanged.
        $synthetic = [PSCustomObject]@{
            defaultMethod = $config.extensions.defaultMethod
            registryRoot  = $config.extensions.registryRoot
            updateUrl     = $config.extensions.updateUrl
            list          = $picked
        }
        Write-Log ("Installing {0} extension(s) from URL(s)..." -f $picked.Count) -Level "info"
        Install-ChromeExtensions -ExtConfig $synthetic -Names @("all") -Method $Method | Out-Null
        Write-Log $logMessages.messages.setupComplete -Level "success"
        return
    }

    # ── Uninstall ────────────────────────────────────────────────────────
    if ($cmd -eq "uninstall") {
        Uninstall-Chrome -ChromeConfig $config.chrome -LogMessages $logMessages
        return
    }

    # ── Install (default) -- optionally followed by extensions ──────────
    $ok = Install-Chrome -ChromeConfig $config.chrome -LogMessages $logMessages
    $isSuccess = $ok -eq $true
    if ($isSuccess) {
        Write-Log $logMessages.messages.setupComplete -Level "success"

        if ($isWithExt) {
            Write-Log "with-ext flag set -- installing all configured extensions..." -Level "info"
            Install-ChromeExtensions -ExtConfig $config.extensions -Names @("all") -Method $Method | Out-Null
        }
    } else {
        Write-Log ($logMessages.messages.installFailed -replace '\{error\}', "See errors above") -Level "error"
    }

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
