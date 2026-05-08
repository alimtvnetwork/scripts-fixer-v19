# --------------------------------------------------------------------------
#  Models orchestrator -- backend picker, catalog loading, CSV resolution
# --------------------------------------------------------------------------

function Get-ModelsPathsStore {
    <#
    .SYNOPSIS
        Returns absolute path to .resolved/models-paths.json (persistent overrides
        for shared/llama/ollama model directories, set via `models path ...`).
    #>
    param([Parameter(Mandatory)] [string]$ScriptsRoot)
    $projectRoot = Split-Path -Parent $ScriptsRoot
    $resolvedDir = Join-Path $projectRoot ".resolved"
    if (-not (Test-Path $resolvedDir)) {
        New-Item -ItemType Directory -Path $resolvedDir -Force | Out-Null
    }
    return (Join-Path $resolvedDir "models-paths.json")
}

function Read-ModelsPathOverrides {
    param([Parameter(Mandatory)] [string]$ScriptsRoot)
    $store = Get-ModelsPathsStore -ScriptsRoot $ScriptsRoot
    if (-not (Test-Path $store)) {
        return [PSCustomObject]@{ shared = $null; llama = $null; ollama = $null }
    }
    try {
        $raw = Get-Content $store -Raw | ConvertFrom-Json
        return [PSCustomObject]@{
            shared = if ($raw.PSObject.Properties['shared']) { $raw.shared } else { $null }
            llama  = if ($raw.PSObject.Properties['llama'])  { $raw.llama }  else { $null }
            ollama = if ($raw.PSObject.Properties['ollama']) { $raw.ollama } else { $null }
        }
    } catch {
        Write-Log ("Failed to read models-paths store '$store' -- $_") -Level "warn"
        return [PSCustomObject]@{ shared = $null; llama = $null; ollama = $null }
    }
}

function Save-ModelsPathOverride {
    <#
    .SYNOPSIS
        Persist a model-dir override. -Scope: 'shared' | 'llama' | 'ollama'.
        -Path '' / $null clears the entry.
    #>
    param(
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] [ValidateSet('shared','llama','ollama','all')] [string]$Scope,
        [string]$Path
    )
    $store = Get-ModelsPathsStore -ScriptsRoot $ScriptsRoot
    $cur   = Read-ModelsPathOverrides -ScriptsRoot $ScriptsRoot
    $obj = @{
        shared = $cur.shared
        llama  = $cur.llama
        ollama = $cur.ollama
    }
    if ($Scope -eq 'all') {
        $obj.shared = $null; $obj.llama = $null; $obj.ollama = $null
    } else {
        $obj[$Scope] = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
    }
    try {
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $store -Encoding UTF8
        Write-Log "Saved models-path override ($Scope) -> '$($obj[$Scope])' [$store]" -Level "success"
    } catch {
        Write-Log "Failed to write models-path store '$store' -- $_" -Level "error"
    }
}

function Resolve-EffectiveDevDir {
    <#
    .SYNOPSIS
        Resolves DEV_DIR with this priority:
        1. $env:DEV_DIR
        2. saved dev path (from `.\run.ps1 path <dir>`, .resolved/dev-dir.json)
    #>
    $envDir = $env:DEV_DIR
    if (-not [string]::IsNullOrWhiteSpace($envDir)) { return $envDir }
    if (Get-Command Get-SavedDevPath -ErrorAction SilentlyContinue) {
        try {
            $saved = Get-SavedDevPath
            if ($saved) { return $saved }
        } catch {}
    }
    return $null
}

function Get-ModelDownloadPaths {
    <#
    .SYNOPSIS
        Returns the on-disk folders where each backend stores model weights.

        Resolution priority per backend:
          1. $env:LLAMA_MODELS_DIR  /  $env:OLLAMA_MODELS
          2. saved per-backend override (.resolved/models-paths.json -> llama|ollama)
          3. $env:MODELS_DIR  (shared)
          4. saved shared override  (.resolved/models-paths.json -> shared)
          5. <DEV_DIR>\<configured subfolder, default 'ai-models'>
    #>
    param(
        [Parameter(Mandatory)] [PSObject]$Config,
        [Parameter(Mandatory)] [string]$ScriptsRoot
    )

    $devDir = Resolve-EffectiveDevDir
    $hasDevDir = -not [string]::IsNullOrWhiteSpace($devDir)
    $devDirSource = if (-not [string]::IsNullOrWhiteSpace($env:DEV_DIR)) { "env" }
                    elseif ($hasDevDir) { "saved" }
                    else { "unset" }

    # Per-backend default subfolders -- now both default to 'ai-models'
    $llamaSub  = "ai-models"
    $ollamaSub = "ai-models"
    try {
        $llamaCfg = Get-Content (Join-Path $ScriptsRoot "43-install-llama-cpp\config.json") -Raw | ConvertFrom-Json
        if ($llamaCfg.modelsConfig.devDirSubfolder) { $llamaSub = $llamaCfg.modelsConfig.devDirSubfolder }
    } catch {}
    try {
        $ollamaCfg = Get-Content (Join-Path $ScriptsRoot "42-install-ollama\config.json") -Raw | ConvertFrom-Json
        if ($ollamaCfg.models.devDirSubfolder) { $ollamaSub = $ollamaCfg.models.devDirSubfolder }
    } catch {}

    $overrides = Read-ModelsPathOverrides -ScriptsRoot $ScriptsRoot

    function _ResolveOne {
        param([string]$BackendKey, [string]$EnvName, [string]$Sub)
        $envVal = [Environment]::GetEnvironmentVariable($EnvName)
        if (-not [string]::IsNullOrWhiteSpace($envVal)) {
            return @{ Path = $envVal; Source = "env:$EnvName" }
        }
        $savedBackend = $overrides.$BackendKey
        if (-not [string]::IsNullOrWhiteSpace($savedBackend)) {
            return @{ Path = $savedBackend; Source = "saved:$BackendKey" }
        }
        $envShared = $env:MODELS_DIR
        if (-not [string]::IsNullOrWhiteSpace($envShared)) {
            return @{ Path = (Join-Path $envShared $Sub); Source = "env:MODELS_DIR/$Sub" }
        }
        if (-not [string]::IsNullOrWhiteSpace($overrides.shared)) {
            return @{ Path = (Join-Path $overrides.shared $Sub); Source = "saved:shared/$Sub" }
        }
        if ($hasDevDir) {
            return @{ Path = (Join-Path $devDir $Sub); Source = "DEV_DIR/$Sub" }
        }
        return @{ Path = "<DEV_DIR not set>\$Sub"; Source = "unresolved" }
    }

    $llama  = _ResolveOne -BackendKey 'llama'  -EnvName 'LLAMA_MODELS_DIR' -Sub $llamaSub
    $ollama = _ResolveOne -BackendKey 'ollama' -EnvName 'OLLAMA_MODELS'    -Sub $ollamaSub

    return [PSCustomObject]@{
        DevDir       = if ($hasDevDir) { $devDir } else { "(not set)" }
        DevDirSource = $devDirSource
        Llama        = $llama.Path
        LlamaSource  = $llama.Source
        Ollama       = $ollama.Path
        OllamaSource = $ollama.Source
        SharedEnv    = $env:MODELS_DIR
        SharedSaved  = $overrides.shared
        IsResolved   = $hasDevDir -or (-not [string]::IsNullOrWhiteSpace($env:MODELS_DIR)) -or (-not [string]::IsNullOrWhiteSpace($overrides.shared))
    }
}

function Show-ModelDownloadPaths {
    param(
        [Parameter(Mandatory)] [PSObject]$Paths
    )
    Write-Host ""
    Write-Host "  Model download locations" -ForegroundColor Yellow
    Write-Host ("    DEV_DIR             : {0}  [{1}]" -f $Paths.DevDir, $Paths.DevDirSource) -ForegroundColor Gray
    Write-Host ("    llama.cpp (GGUF)    : {0}" -f $Paths.Llama)  -ForegroundColor White
    Write-Host ("                          source: {0}" -f $Paths.LlamaSource) -ForegroundColor DarkGray
    Write-Host ("    Ollama daemon store : {0}" -f $Paths.Ollama) -ForegroundColor Cyan
    Write-Host ("                          source: {0}" -f $Paths.OllamaSource) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Override syntax" -ForegroundColor Yellow
    Write-Host "    Shared (both)      : `$env:MODELS_DIR='X:\ai'         OR  .\run.ps1 models path X:\ai" -ForegroundColor DarkGray
    Write-Host "    llama.cpp only     : `$env:LLAMA_MODELS_DIR='X:\gguf'  OR  .\run.ps1 models path llama X:\gguf" -ForegroundColor DarkGray
    Write-Host "    Ollama only        : `$env:OLLAMA_MODELS='X:\ollama'   OR  .\run.ps1 models path ollama X:\ollama" -ForegroundColor DarkGray
    Write-Host "    Show / reset       : .\run.ps1 models path            |   .\run.ps1 models path --reset [llama|ollama|all]" -ForegroundColor DarkGray
    if (-not $Paths.IsResolved) {
        Write-Host "    Tip: set DEV_DIR via  `$env:DEV_DIR='D:\dev'   or   .\run.ps1 path D:\dev" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Get-BackendCatalog {
    <#
    .SYNOPSIS
        Loads the model catalog for a backend ("llama-cpp" or "ollama").
        Returns array of {id, displayName, backend} objects.
    #>
    param(
        [Parameter(Mandatory)] [string]$Backend,
        [Parameter(Mandatory)] [PSObject]$Config,
        [Parameter(Mandatory)] [string]$ScriptsRoot
    )

    $backendCfg = $Config.backends.$Backend
    if (-not $backendCfg) { return @() }

    $catalogPath = Join-Path $ScriptsRoot $backendCfg.scriptFolder $backendCfg.catalogFile
    $hasCatalog = Test-Path $catalogPath
    if (-not $hasCatalog) {
        Write-Log "Catalog not found: $catalogPath" -Level "warn"
        return @()
    }

    $raw = Get-Content $catalogPath -Raw | ConvertFrom-Json

    # Drill into nested path if specified (e.g. ollama config has "defaultModels")
    $catalogPathProp = $backendCfg.PSObject.Properties['catalogPath']
    $catalogPathValue = if ($catalogPathProp) { $catalogPathProp.Value } else { $null }
    $items = if ($catalogPathValue) { $raw.$catalogPathValue } else { $raw.models }

    $idField   = $backendCfg.idField
    $nameField = $backendCfg.displayField

    $result = @()
    foreach ($item in $items) {
        $result += [PSCustomObject]@{
            id          = $item.$idField
            displayName = $item.$nameField
            backend     = $Backend
            raw         = $item
        }
    }
    return $result
}

function Show-BackendPicker {
    <#
    .SYNOPSIS
        Interactive backend chooser. Returns "llama-cpp", "ollama", "both", or $null.
    #>
    param([Parameter(Mandatory)] [PSObject]$LogMessages)

    Write-Host ""
    Write-Host $LogMessages.messages.pickBackend -ForegroundColor Cyan
    Write-Host ""
    Write-Host $LogMessages.messages.backendLlama  -ForegroundColor White
    Write-Host $LogMessages.messages.backendOllama -ForegroundColor White
    Write-Host $LogMessages.messages.backendBoth   -ForegroundColor White
    Write-Host ""
    Write-Host $LogMessages.messages.backendQuit   -ForegroundColor DarkGray
    Write-Host ""

    $input = Read-Host -Prompt $LogMessages.messages.backendPrompt
    $trimmed = $input.Trim().ToLower()

    switch ($trimmed) {
        "1"        { return "llama-cpp" }
        "llama"    { return "llama-cpp" }
        "llama-cpp"{ return "llama-cpp" }
        "2"        { return "ollama" }
        "ollama"   { return "ollama" }
        "3"        { return "both" }
        "both"     { return "both" }
        default    { return $null }
    }
}

function _GetRawProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    try {
        if ($Obj.PSObject.Properties.Name -contains $Name) {
            $v = $Obj.$Name
            if ($null -eq $v) { return $Default }
            return $v
        }
    } catch {}
    return $Default
}

function Show-ModelList {
    <#
    .SYNOPSIS
        Prints a rich, color-highlighted catalog table with index numbers,
        size, RAM, capability flags, and 1-10 ratings. The printed index
        can be passed back as: .\run.ps1 models download 5,6,10
    #>
    param(
        [Parameter(Mandatory)] [array]$Models,
        [string]$BackendLabel = "all backends",
        [PSObject]$DownloadPaths
    )

    Write-Host ""
    Write-Host ("  Available models ({0}): {1}" -f $BackendLabel, $Models.Count) -ForegroundColor Yellow
    Write-Host "  Caps legend: [C]oding [R]easoning [W]riting [V]oice [M]ultilingual    Ratings 1-10 (Code / Reason / Speed)" -ForegroundColor DarkGray
    Write-Host "  * = recommended for coding" -ForegroundColor DarkGray
    Write-Host ""

    $idx = 0
    foreach ($m in $Models) {
        $idx++
        $raw = $m.raw

        $sizeGB  = _GetRawProp $raw 'fileSizeGB'
        $sizeStr = if ($sizeGB) { ("{0:N1} GB" -f [double]$sizeGB) } else { "$(_GetRawProp $raw 'sizeHint' '-')" }

        $ramGB   = _GetRawProp $raw 'ramRequiredGB'
        $ramStr  = if ($ramGB) { ("{0} GB" -f $ramGB) } else { '-' }

        $isCoding   = [bool](_GetRawProp $raw 'isCoding'  $false)
        $isReason   = [bool](_GetRawProp $raw 'isReasoning' $false)
        $isWriting  = [bool](_GetRawProp $raw 'isWriting' $false)
        $isVoice    = [bool](_GetRawProp $raw 'isVoice'   $false)
        $isMulti    = [bool](_GetRawProp $raw 'isMultilingual' $false)

        $caps  = ""
        $caps += if ($isCoding)  { "C" } else { "." }
        $caps += if ($isReason)  { "R" } else { "." }
        $caps += if ($isWriting) { "W" } else { "." }
        $caps += if ($isVoice)   { "V" } else { "." }
        $caps += if ($isMulti)   { "M" } else { "." }

        $rating  = _GetRawProp $raw 'rating'
        $rCode   = _GetRawProp $rating 'coding'    '-'
        $rReason = _GetRawProp $rating 'reasoning' '-'
        $rSpeed  = _GetRawProp $rating 'speed'     '-'
        $ratingStr = "{0}/{1}/{2}" -f $rCode, $rReason, $rSpeed

        $purposeRaw = _GetRawProp $raw 'bestFor'
        if (-not $purposeRaw) { $purposeRaw = _GetRawProp $raw 'purpose' '' }
        $purpose = "$purposeRaw"

        $marker     = if ($isCoding) { "*" } else { " " }
        $headColor  = if ($isCoding) { "Yellow" } else { "White" }
        $bodyColor  = "White"
        $dimColor   = "DarkGray"

        # Header line: "  12 * model-id-here"
        Write-Host ""
        Write-Host ("  {0,3} {1} {2}" -f $idx, $marker, $m.id) -ForegroundColor $headColor
        Write-Host ("        Size  : {0}     RAM : {1}     Caps: {2}     Score (C/R/S): {3}" -f $sizeStr, $ramStr, $caps, $ratingStr) -ForegroundColor $bodyColor
        if ($purpose) {
            Write-Host ("        Best  : {0}" -f $purpose) -ForegroundColor $bodyColor
        }
    }
    Write-Host ""
    Write-Host "  Install by number : .\run.ps1 models download 5,6,10" -ForegroundColor DarkGray
    Write-Host "  Install by id     : .\run.ps1 models download qwen2.5-coder-3b,llama3.2" -ForegroundColor DarkGray

    if ($DownloadPaths) { Show-ModelDownloadPaths -Paths $DownloadPaths }
}

function Resolve-NumericPicks {
    <#
    .SYNOPSIS
        Given a CSV like "1,3,5-7" and the ordered model array previously shown
        by Show-ModelList, returns the matching model objects.
    #>
    param(
        [Parameter(Mandatory)] [string]$Csv,
        [Parameter(Mandatory)] [array]$AllModels
    )
    $picks = @()
    $tokens = $Csv -split '[,\s]+' | Where-Object { $_.Length -gt 0 }
    foreach ($t in $tokens) {
        if ($t -match '^(\d+)-(\d+)$') {
            $a = [int]$matches[1]; $b = [int]$matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($i = $a; $i -le $b; $i++) {
                if ($i -ge 1 -and $i -le $AllModels.Count) { $picks += $AllModels[$i - 1] }
            }
        } elseif ($t -match '^\d+$') {
            $i = [int]$t
            if ($i -ge 1 -and $i -le $AllModels.Count) { $picks += $AllModels[$i - 1] }
            else { Write-Log "  [MISS] #$i out of range (1..$($AllModels.Count))" -Level "warn" }
        }
    }
    return $picks
}

function Resolve-CsvIds {
    <#
    .SYNOPSIS
        Given a CSV string of model ids, returns matching catalog entries
        (case-insensitive, partial-match-friendly via -like).
    #>
    param(
        [Parameter(Mandatory)] [string]$Csv,
        [Parameter(Mandatory)] [array]$AllModels,
        [Parameter(Mandatory)] [PSObject]$LogMessages
    )

    $ids = $Csv -split '[,\s]+' | Where-Object { $_.Length -gt 0 }
    Write-Log ($LogMessages.messages.csvResolveStart -replace '\{count\}', $ids.Count) -Level "info"

    $matched = @()
    foreach ($id in $ids) {
        $needle = $id.Trim().ToLower()
        $hit = $AllModels | Where-Object { $_.id.ToLower() -eq $needle } | Select-Object -First 1
        if (-not $hit) {
            # Try partial match (e.g. "qwen2.5-coder" matches "qwen2.5-coder-3b")
            $hit = $AllModels | Where-Object { $_.id.ToLower() -like "*$needle*" } | Select-Object -First 1
        }
        if ($hit) {
            $line = $LogMessages.messages.csvResolved -replace '\{id\}', $id -replace '\{backend\}', $hit.backend
            Write-Log $line -Level "success"
            $matched += $hit
        } else {
            $line = $LogMessages.messages.csvUnknown -replace '\{id\}', $id
            Write-Log $line -Level "warn"
        }
    }
    return $matched
}

function Invoke-BackendInstall {
    <#
    .SYNOPSIS
        Dispatches install of one or more models to the appropriate backend script.
        Models param: array of {id, backend, raw} entries.
    #>
    param(
        [Parameter(Mandatory)] [array]$Models,
        [Parameter(Mandatory)] [PSObject]$Config,
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] [PSObject]$LogMessages
    )

    $byBackend = $Models | Group-Object backend
    foreach ($group in $byBackend) {
        $backend = $group.Name
        $ids     = ($group.Group | ForEach-Object { $_.id }) -join ","
        $folder  = $Config.backends.$backend.scriptFolder
        $script  = Join-Path (Join-Path $ScriptsRoot $folder) "run.ps1"

        $line = $LogMessages.messages.dispatching -replace '\{backend\}', $backend
        Write-Log $line -Level "info"

        if ($backend -eq "ollama") {
            # Pass model slugs via env var; script 42 reads OLLAMA_PULL_MODELS
            $env:OLLAMA_PULL_MODELS = $ids
            & $script pull
            Remove-Item Env:\OLLAMA_PULL_MODELS -ErrorAction SilentlyContinue
        } else {
            # llama.cpp: pass via env var read by helpers/model-picker.ps1
            $env:LLAMA_CPP_INSTALL_IDS = $ids
            & $script all
            Remove-Item Env:\LLAMA_CPP_INSTALL_IDS -ErrorAction SilentlyContinue
        }
    }
}
