# --------------------------------------------------------------------------
#  Models orchestrator -- backend picker, catalog loading, CSV resolution
# --------------------------------------------------------------------------

function Get-ModelDownloadPaths {
    <#
    .SYNOPSIS
        Returns the on-disk folders where each backend stores model weights.
        Honors $env:DEV_DIR when set; otherwise reports the configured subfolder
        and a hint about how to set the dev directory.
    #>
    param(
        [Parameter(Mandatory)] [PSObject]$Config,
        [Parameter(Mandatory)] [string]$ScriptsRoot
    )

    $devDir = $env:DEV_DIR
    $hasDevDir = -not [string]::IsNullOrWhiteSpace($devDir)

    # Resolve sub-folder names from the per-backend config files
    $llamaSub  = "llama-models"
    $ollamaSub = "ollama-models"
    try {
        $llamaCfg = Get-Content (Join-Path $ScriptsRoot "43-install-llama-cpp\config.json") -Raw | ConvertFrom-Json
        if ($llamaCfg.modelsConfig.devDirSubfolder) { $llamaSub = $llamaCfg.modelsConfig.devDirSubfolder }
    } catch {}
    try {
        $ollamaCfg = Get-Content (Join-Path $ScriptsRoot "42-install-ollama\config.json") -Raw | ConvertFrom-Json
        if ($ollamaCfg.models.devDirSubfolder) { $ollamaSub = $ollamaCfg.models.devDirSubfolder }
    } catch {}

    $llamaPath  = if ($hasDevDir) { Join-Path $devDir $llamaSub }  else { "<DEV_DIR not set>\$llamaSub" }
    $ollamaPath = if ($hasDevDir) { Join-Path $devDir $ollamaSub } else { "<DEV_DIR not set>\$ollamaSub  (Ollama also honors `$env:OLLAMA_MODELS)" }

    return [PSCustomObject]@{
        DevDir     = if ($hasDevDir) { $devDir } else { "(not set)" }
        Llama      = $llamaPath
        Ollama     = $ollamaPath
        IsResolved = $hasDevDir
    }
}

function Show-ModelDownloadPaths {
    param(
        [Parameter(Mandatory)] [PSObject]$Paths
    )
    Write-Host ""
    Write-Host "  Model download locations" -ForegroundColor Yellow
    Write-Host ("    DEV_DIR             : {0}" -f $Paths.DevDir)        -ForegroundColor Gray
    Write-Host ("    llama.cpp (GGUF)    : {0}" -f $Paths.Llama)         -ForegroundColor White
    Write-Host ("    Ollama daemon store : {0}" -f $Paths.Ollama)        -ForegroundColor Cyan
    if (-not $Paths.IsResolved) {
        Write-Host "    Tip: set the dev dir with  `$env:DEV_DIR='D:\dev'  or  .\run.ps1 path D:\dev" -ForegroundColor DarkGray
    } else {
        Write-Host "    Change with: `$env:DEV_DIR='X:\new-dev'  (Ollama: `$env:OLLAMA_MODELS='X:\ollama-models')" -ForegroundColor DarkGray
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
    Write-Host ("  Available models ({0}): {1}" -f $BackendLabel, $Models.Count) -ForegroundColor Cyan
    Write-Host "  Legend:  [C]oding  [R]easoning  [W]riting  [V]oice  [M]ultilingual    Ratings 1-10 (Code/Reason/Speed)" -ForegroundColor DarkGray
    Write-Host ""

    $hdr = "  {0,-4} {1,-9} {2,-34} {3,-8} {4,-7} {5,-6} {6,-12} {7}" -f `
        "#", "Backend", "Model (id)", "Size", "RAM", "Caps", "C / R / S", "Best for"
    Write-Host $hdr -ForegroundColor Yellow
    Write-Host ("  " + ("-" * 140)) -ForegroundColor DarkGray

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
        $ratingStr = "{0,2}/{1,2}/{2,2}" -f $rCode, $rReason, $rSpeed

        $purposeRaw = _GetRawProp $raw 'bestFor'
        if (-not $purposeRaw) { $purposeRaw = _GetRawProp $raw 'purpose' '' }
        $purpose = "$purposeRaw"
        if ($purpose.Length -gt 60) { $purpose = $purpose.Substring(0, 57) + "..." }

        $idLabel = "$($m.id)"
        if ($idLabel.Length -gt 33) { $idLabel = $idLabel.Substring(0, 30) + "..." }

        # Highlight coding models in green, reasoning in magenta
        $rowColor =
            if ($isCoding) { "Green" }
            elseif ($isReason) { "Magenta" }
            elseif ($m.backend -eq "ollama") { "Cyan" }
            else { "White" }

        $line = "  {0,-4} {1,-9} {2,-34} {3,-8} {4,-7} {5,-6} {6,-12} {7}" -f `
            $idx, $m.backend, $idLabel, $sizeStr, $ramStr, $caps, $ratingStr, $purpose

        Write-Host $line -ForegroundColor $rowColor
    }
    Write-Host ""
    Write-Host "  Install by number: .\run.ps1 models download 5,6,10" -ForegroundColor DarkGray
    Write-Host "  Install by id    : .\run.ps1 models qwen2.5-coder-3b,llama3.2" -ForegroundColor DarkGray

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
