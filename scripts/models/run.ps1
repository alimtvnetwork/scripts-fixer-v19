# --------------------------------------------------------------------------
#  Scripts Fixer -- Models Orchestrator
#  Pick a backend (llama.cpp / Ollama), then browse and install models.
#  Spec: spec/models/readme.md
# --------------------------------------------------------------------------
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Args,

    [string]$Backend,
    [string]$Install,
    [switch]$List,
    [switch]$Force,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sharedDir   = Join-Path (Split-Path -Parent $scriptDir) "shared"
$scriptsRoot = Split-Path -Parent $scriptDir

# -- Dot-source shared helpers ------------------------------------------------
. (Join-Path $sharedDir "logging.ps1")
. (Join-Path $sharedDir "help.ps1")
. (Join-Path $sharedDir "install-paths.ps1")
. (Join-Path $sharedDir "dev-dir.ps1")

# -- Dot-source orchestrator helpers -----------------------------------------
. (Join-Path $scriptDir "helpers\picker.ps1")
. (Join-Path $scriptDir "helpers\ollama-search.ps1")
. (Join-Path $scriptDir "helpers\uninstall.ps1")

# -- Load config & log messages ----------------------------------------------
$config      = Import-JsonConfig (Join-Path $scriptDir "config.json")
$logMessages = Import-JsonConfig (Join-Path $scriptDir "log-messages.json")

# -- Help ---------------------------------------------------------------------
if ($Help) {
    Show-ScriptHelp -LogMessages $logMessages
    $paths = Get-ModelDownloadPaths -Config $config -ScriptsRoot $scriptsRoot
    Show-ModelDownloadPaths -Paths $paths
    return
}

Write-Banner -Title $logMessages.scriptName

# -- Resolve current model download locations (shown on every run) -----------
$downloadPaths = Get-ModelDownloadPaths -Config $config -ScriptsRoot $scriptsRoot

# -- Triple-path trio (Source / Temp / Target) -----------------------
Write-InstallPaths `
    -Tool   "AI model dispatcher" `
    -Action "Dispatch" `
    -Source "$scriptDir\config.json (model catalog)" `
    -Temp   ($env:TEMP + "\scripts-fixer\models") `
    -Target ("llama: {0} | ollama: {1}" -f $downloadPaths.Llama, $downloadPaths.Ollama)
Initialize-Logging -ScriptName $logMessages.scriptName

try {
    # ── Parse positional args ────────────────────────────────────────────
    # First positional may be: "list", a CSV of model ids, or empty (interactive)
    $firstArg = if ($Args -and $Args.Count -gt 0) { $Args[0].Trim() } else { "" }
    $secondArg = if ($Args -and $Args.Count -gt 1) { $Args[1].Trim() } else { "" }

    $isHelpMode      = $firstArg.ToLower() -in @("help", "--help", "-h", "/?")
    if ($isHelpMode) {
        Show-ScriptHelp -LogMessages $logMessages
        Show-ModelDownloadPaths -Paths $downloadPaths
        return
    }

    $isListMode      = $List -or $firstArg.ToLower() -eq "list"
    $isDownloadMode  = $firstArg.ToLower() -eq "download" -or $firstArg.ToLower() -eq "dl" -or $firstArg.ToLower() -eq "install"
    $isSearchMode    = $firstArg.ToLower() -eq "search"
    $isUninstallMode = $firstArg.ToLower() -eq "uninstall" -or $firstArg.ToLower() -eq "remove" -or $firstArg.ToLower() -eq "rm"
    $isPathMode      = $firstArg.ToLower() -eq "path" -or $firstArg.ToLower() -eq "paths" -or $firstArg.ToLower() -eq "dir"
    $hasInstallParam = -not [string]::IsNullOrWhiteSpace($Install)
    $reservedFirstArgs = @("list", "search", "uninstall", "remove", "rm", "download", "dl", "install", "path", "paths", "dir", "help", "--help", "-h", "/?")
    $hasCsvFirstArg  = $firstArg -and ($reservedFirstArgs -notcontains $firstArg.ToLower()) -and $firstArg -match '[a-z0-9]'

    # ── Path mode: show / set / add / remove model-dir overrides ────────
    if ($isPathMode) {
        $sub  = if ($secondArg) { $secondArg.ToLower() } else { "" }
        $arg2 = if ($Args.Count -gt 2) { "$($Args[2])".Trim() } else { "" }
        $arg3 = if ($Args.Count -gt 3) { "$($Args[3])".Trim() } else { "" }

        # `models path`  -- show current resolution
        if (-not $sub) {
            Show-ModelDownloadPaths -Paths $downloadPaths
            return
        }

        # `models path --reset [scope]`
        if ($sub -in @("--reset", "-reset", "reset", "clear")) {
            $resetScope = if ($arg2) { $arg2.ToLower() } else { "all" }
            if ($resetScope -notin @("all","shared","llama","ollama")) {
                Write-Log "Invalid reset scope '$resetScope'. Use: all | shared | llama | ollama" -Level "error"
                return
            }
            Save-ModelsPathOverride -ScriptsRoot $scriptsRoot -Scope $resetScope -Path $null
            Show-ModelDownloadPaths -Paths (Get-ModelDownloadPaths -Config $config -ScriptsRoot $scriptsRoot)
            return
        }

        # `models path <action> ...`  where the first word is shared-action
        # ( add / rm / remove / set )  -- treats target as SHARED
        $sharedActions = @("add","rm","remove","del","delete","set")
        if ($sub -in $sharedActions) {
            $action = $sub
            $val    = $arg2
            if (-not $val) {
                Write-Log "Usage: .\run.ps1 models path $action <directory>" -Level "warn"
                return
            }
            switch ($action) {
                "add"    { Add-ModelsPathOverride    -ScriptsRoot $scriptsRoot -Scope "shared" -Path $val }
                "set"    { Save-ModelsPathOverride   -ScriptsRoot $scriptsRoot -Scope "shared" -Path $val }
                default  { Remove-ModelsPathOverride -ScriptsRoot $scriptsRoot -Scope "shared" -Path $val }
            }
            Show-ModelDownloadPaths -Paths (Get-ModelDownloadPaths -Config $config -ScriptsRoot $scriptsRoot)
            return
        }

        # `models path llama|ollama ...`
        if ($sub -in @("llama","llama-cpp","ollama")) {
            $scope = if ($sub -eq "ollama") { "ollama" } else { "llama" }

            # `models path <backend>`  -- list current dirs for that backend
            if (-not $arg2) {
                $cur = Read-ModelsPathOverrides -ScriptsRoot $scriptsRoot
                $list = @($cur.$scope)
                Write-Log "Configured override dirs for '$scope': $($list.Count)" -Level "info"
                $i = 0
                foreach ($p in $list) { $i++; Write-Host ("    [{0}] {1}" -f $i, $p) -ForegroundColor White }
                Show-ModelDownloadPaths -Paths (Get-ModelDownloadPaths -Config $config -ScriptsRoot $scriptsRoot)
                return
            }

            # action keyword?  add / rm / set
            if ($arg2.ToLower() -in @("add","rm","remove","del","delete","set")) {
                if (-not $arg3) {
                    Write-Log "Usage: .\run.ps1 models path $sub $($arg2.ToLower()) <directory>" -Level "warn"
                    return
                }
                switch ($arg2.ToLower()) {
                    "add"   { Add-ModelsPathOverride    -ScriptsRoot $scriptsRoot -Scope $scope -Path $arg3 }
                    "set"   { Save-ModelsPathOverride   -ScriptsRoot $scriptsRoot -Scope $scope -Path $arg3 }
                    default { Remove-ModelsPathOverride -ScriptsRoot $scriptsRoot -Scope $scope -Path $arg3 }
                }
            } else {
                # `models path llama D:\gguf` -- replace (legacy single-set)
                Save-ModelsPathOverride -ScriptsRoot $scriptsRoot -Scope $scope -Path $arg2
            }
            Show-ModelDownloadPaths -Paths (Get-ModelDownloadPaths -Config $config -ScriptsRoot $scriptsRoot)
            return
        }

        # Fallback: `models path <dir>`  -- shared SET (back-compat)
        Save-ModelsPathOverride -ScriptsRoot $scriptsRoot -Scope "shared" -Path $secondArg
        Show-ModelDownloadPaths -Paths (Get-ModelDownloadPaths -Config $config -ScriptsRoot $scriptsRoot)
        return
    }

    # ── List mode ────────────────────────────────────────────────────────
    if ($isListMode) {
        $filter = if ($firstArg.ToLower() -eq "list") { $secondArg.ToLower() } else { "" }

        $all = @()
        if (-not $filter -or $filter -eq "llama" -or $filter -eq "llama-cpp") {
            $all += Get-BackendCatalog -Backend "llama-cpp" -Config $config -ScriptsRoot $scriptsRoot
        }
        if (-not $filter -or $filter -eq "ollama") {
            $all += Get-BackendCatalog -Backend "ollama" -Config $config -ScriptsRoot $scriptsRoot
        }
        $label = if ($filter) { $filter } else { "all backends" }
        Show-ModelList -Models $all -BackendLabel $label -DownloadPaths $downloadPaths
        return
    }

    # ── Download by index ─────────────────────────────────────────────────
    # Usage: .\run.ps1 models download 5,6,10   (numbers from `models list`)
    if ($isDownloadMode) {
        $csv = if ($secondArg) { $secondArg } elseif ($hasInstallParam) { $Install } else { "" }
        if ([string]::IsNullOrWhiteSpace($csv)) {
            Write-Log "  Usage: .\run.ps1 models download <numbers-or-ids>  e.g. download 5,6,10  or  download qwen2.5-coder-3b" -Level "warn"
            return
        }

        # Build the same combined catalog that `list` shows so numbers line up
        $all = @()
        $all += Get-BackendCatalog -Backend "llama-cpp" -Config $config -ScriptsRoot $scriptsRoot
        $all += Get-BackendCatalog -Backend "ollama"    -Config $config -ScriptsRoot $scriptsRoot

        $isNumeric = $csv -match '^[\d,\s\-]+$'
        $matched = if ($isNumeric) {
            Resolve-NumericPicks -Csv $csv -AllModels $all
        } else {
            Resolve-CsvIds -Csv $csv -AllModels $all -LogMessages $logMessages
        }

        if ($matched.Count -eq 0) {
            Write-Log $logMessages.messages.csvNoneFound -Level "error"
            return
        }
        Show-ModelDownloadPaths -Paths $downloadPaths
        Invoke-BackendInstall -Models $matched -Config $config -ScriptsRoot $scriptsRoot -LogMessages $logMessages
        Show-ModelDownloadPaths -Paths $downloadPaths
        Write-Log $logMessages.messages.complete -Level "success"
        return
    }

    # ── Search mode (Ollama Hub) ─────────────────────────────────────────
    # Usage: .\run.ps1 models search <query>  -- scrapes ollama.com/library
    # for any pullable model, not just the static defaults in script 42's config.
    if ($isSearchMode) {
        $query = $secondArg
        if ([string]::IsNullOrWhiteSpace($query)) {
            $query = Read-Host -Prompt "  Search Ollama Hub for"
        }

        $results = Invoke-OllamaHubSearch -Query $query
        $hasResults = $results.Count -gt 0
        if (-not $hasResults) {
            Write-Log $logMessages.messages.searchNoResults -Level "warn"
            return
        }

        Show-OllamaHubResults -Results $results -Query $query

        $picks = Read-OllamaHubSelection -MaxIndex $results.Count
        if ($null -eq $picks) {
            Write-Log $logMessages.messages.searchAborted -Level "info"
            return
        }
        if ($picks.Count -eq 0) {
            Write-Log $logMessages.messages.searchSkipped -Level "info"
            return
        }

        # Build CSV of slugs (with optional :tag) and dispatch to script 42 via env var.
        $slugs = @()
        foreach ($p in $picks) {
            $r = $results[$p.Index - 1]
            $slug = if ($p.Tag) { "$($r.slug):$($p.Tag)" } else { $r.slug }
            $slugs += $slug
        }
        $csvSlugs = $slugs -join ","
        $line = $logMessages.messages.searchDispatching -replace '\{slugs\}', $csvSlugs
        Write-Log $line -Level "info"

        $folder = $config.backends.ollama.scriptFolder
        $target = Join-Path (Join-Path $scriptsRoot $folder) "run.ps1"
        $env:OLLAMA_PULL_MODELS = $csvSlugs
        try {
            & $target pull
        } finally {
            Remove-Item Env:\OLLAMA_PULL_MODELS -ErrorAction SilentlyContinue
        }

        Write-Log $logMessages.messages.complete -Level "success"
        return
    }

    # ── Uninstall mode ───────────────────────────────────────────────────
    # Lists everything currently on this machine across both backends, lets
    # the user multi-select with the same syntax (1,3 | 1-5 | all), then
    # deletes via each backend's natural removal path.
    if ($isUninstallMode) {
        $projectRoot = Split-Path -Parent $scriptsRoot

        Write-Log $logMessages.messages.uninstallScanning -Level "info"
        $llamaModels  = Get-InstalledLlamaCppModels -ScriptsRoot $scriptsRoot -ProjectRoot $projectRoot
        $ollamaModels = Get-InstalledOllamaModels

        # Optional backend filter from secondArg or -Backend param
        $uninstFilter = if ($Backend) { $Backend.ToLower() } elseif ($secondArg) { $secondArg.ToLower() } else { "" }
        $combined = @()
        if (-not $uninstFilter -or $uninstFilter -eq "llama" -or $uninstFilter -eq "llama-cpp") {
            $combined += $llamaModels
        }
        if (-not $uninstFilter -or $uninstFilter -eq "ollama") {
            $combined += $ollamaModels
        }

        if ($combined.Count -eq 0) {
            Write-Log $logMessages.messages.uninstallNothing -Level "info"
            return
        }

        Show-UninstallList -All $combined
        $picks = Read-UninstallSelection -MaxIndex $combined.Count
        if ($null -eq $picks) {
            Write-Log $logMessages.messages.uninstallAborted -Level "info"
            return
        }
        if ($picks.Count -eq 0) {
            Write-Log $logMessages.messages.uninstallSkipped -Level "info"
            return
        }

        $targets = @()
        foreach ($i in $picks) { $targets += $combined[$i - 1] }

        if ($Force) {
            Write-Log $logMessages.messages.uninstallForceSkip -Level "warn"
        } else {
            $isConfirmed = Confirm-Uninstall -Targets $targets
            if (-not $isConfirmed) {
                Write-Log $logMessages.messages.uninstallAborted -Level "info"
                return
            }
        }

        $summary = Invoke-ModelUninstall -Targets $targets
        $hasFailures = $summary.Fail -gt 0
        if ($hasFailures) {
            Write-Log $logMessages.messages.uninstallPartial -Level "warn"
        } else {
            Write-Log $logMessages.messages.uninstallComplete -Level "success"
        }
        return
    }

    # ── CSV install mode (positional or -Install) ────────────────────────
    $csv = if ($hasInstallParam) { $Install } elseif ($hasCsvFirstArg) { $firstArg } else { "" }
    $hasCsv = -not [string]::IsNullOrWhiteSpace($csv)

    if ($hasCsv) {
        # Build catalog from selected backend or both
        $backends = if ($Backend) { @($Backend.ToLower()) } else { @("llama-cpp", "ollama") }
        $allModels = @()
        foreach ($b in $backends) {
            $allModels += Get-BackendCatalog -Backend $b -Config $config -ScriptsRoot $scriptsRoot
        }

        $matched = Resolve-CsvIds -Csv $csv -AllModels $allModels -LogMessages $logMessages
        if ($matched.Count -eq 0) {
            Write-Log $logMessages.messages.csvNoneFound -Level "error"
            return
        }
        Show-ModelDownloadPaths -Paths $downloadPaths
        Invoke-BackendInstall -Models $matched -Config $config -ScriptsRoot $scriptsRoot -LogMessages $logMessages
        Show-ModelDownloadPaths -Paths $downloadPaths
        Write-Log $logMessages.messages.complete -Level "success"
        return
    }

    # ── Default mode ─────────────────────────────────────────────────────
    # `.\run.ps1 models` (no args) now prints the FULL catalog so users can
    # browse first and then run `models download <numbers>` to install.
    # Pass -Backend to scope to one backend; pass an id/CSV to install directly.
    if ($Backend) {
        $chosen = $Backend.ToLower()
        if ($chosen -eq "both") {
            $all  = @()
            $all += Get-BackendCatalog -Backend "llama-cpp" -Config $config -ScriptsRoot $scriptsRoot
            $all += Get-BackendCatalog -Backend "ollama"    -Config $config -ScriptsRoot $scriptsRoot
            Show-ModelList -Models $all -BackendLabel "both" -DownloadPaths $downloadPaths
            return
        }
        # Single backend: dispatch to its own interactive picker
        $folder = $config.backends.$chosen.scriptFolder
        $target = Join-Path (Join-Path $scriptsRoot $folder) "run.ps1"
        $line = $logMessages.messages.dispatching -replace '\{backend\}', $chosen
        Write-Log $line -Level "info"
        & $target
        Show-ModelDownloadPaths -Paths $downloadPaths
        Write-Log $logMessages.messages.complete -Level "success"
        return
    }

    # No backend specified -- show the full combined catalog
    $all  = @()
    $all += Get-BackendCatalog -Backend "llama-cpp" -Config $config -ScriptsRoot $scriptsRoot
    $all += Get-BackendCatalog -Backend "ollama"    -Config $config -ScriptsRoot $scriptsRoot
    Show-ModelList -Models $all -BackendLabel "all backends" -DownloadPaths $downloadPaths
    Write-Host "  Run  .\run.ps1 models help   to see every available command." -ForegroundColor DarkGray
    Write-Host ""

} catch {
    Write-Log "Unhandled error: $_" -Level "error"
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level "error"
} finally {
    $hasAnyErrors = $script:_LogErrors.Count -gt 0
    Save-LogFile -Status $(if ($hasAnyErrors) { "fail" } else { "ok" })
}
