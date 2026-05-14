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

function _NormalizeDirList {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value)
    }
    $out = @()
    foreach ($v in @($Value)) {
        if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
            $out += [string]$v
        }
    }
    return ,$out
}

function Read-ModelsPathOverrides {
    <#
    .SYNOPSIS
        Returns persisted overrides, with each scope normalized to an array
        of directories (empty array = no override). Backward-compatible with
        the old single-string format.
    #>
    param([Parameter(Mandatory)] [string]$ScriptsRoot)
    $store = Get-ModelsPathsStore -ScriptsRoot $ScriptsRoot
    if (-not (Test-Path $store)) {
        return [PSCustomObject]@{ shared = @(); llama = @(); ollama = @() }
    }
    try {
        $raw = Get-Content $store -Raw | ConvertFrom-Json
        return [PSCustomObject]@{
            shared = _NormalizeDirList (if ($raw.PSObject.Properties['shared']) { $raw.shared } else { $null })
            llama  = _NormalizeDirList (if ($raw.PSObject.Properties['llama'])  { $raw.llama }  else { $null })
            ollama = _NormalizeDirList (if ($raw.PSObject.Properties['ollama']) { $raw.ollama } else { $null })
        }
    } catch {
        Write-Log ("Failed to read models-paths store '$store' -- $_") -Level "warn"
        return [PSCustomObject]@{ shared = @(); llama = @(); ollama = @() }
    }
}

function _WriteOverridesStore {
    param(
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] $SharedList,
        [Parameter(Mandatory)] $LlamaList,
        [Parameter(Mandatory)] $OllamaList
    )
    $store = Get-ModelsPathsStore -ScriptsRoot $ScriptsRoot
    $obj = @{
        shared = @(_NormalizeDirList $SharedList)
        llama  = @(_NormalizeDirList $LlamaList)
        ollama = @(_NormalizeDirList $OllamaList)
    }
    try {
        ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path $store -Encoding UTF8
        return $store
    } catch {
        Write-Log "Failed to write models-path store '$store' -- $_" -Level "error"
        return $null
    }
}

function Save-ModelsPathOverride {
    <#
    .SYNOPSIS
        REPLACE the override list for a scope. -Path '' / $null clears it.
        -Scope: 'shared' | 'llama' | 'ollama' | 'all' (clears every scope).
    #>
    param(
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] [ValidateSet('shared','llama','ollama','all')] [string]$Scope,
        [string]$Path
    )
    $cur = Read-ModelsPathOverrides -ScriptsRoot $ScriptsRoot
    $shared = @($cur.shared); $llama = @($cur.llama); $ollama = @($cur.ollama)
    if ($Scope -eq 'all') {
        $shared = @(); $llama = @(); $ollama = @()
    } else {
        $newList = if ([string]::IsNullOrWhiteSpace($Path)) { @() } else { @($Path) }
        switch ($Scope) {
            'shared' { $shared = $newList }
            'llama'  { $llama  = $newList }
            'ollama' { $ollama = $newList }
        }
    }
    $store = _WriteOverridesStore -ScriptsRoot $ScriptsRoot -SharedList $shared -LlamaList $llama -OllamaList $ollama
    if ($store) {
        Write-Log "Saved models-path override ($Scope) [$store]" -Level "success"
    }
}

function Add-ModelsPathOverride {
    <#
    .SYNOPSIS
        APPEND a directory to the override list for a scope (no duplicates,
        case-insensitive). Use this to register a *second* model directory.
    #>
    param(
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] [ValidateSet('shared','llama','ollama')] [string]$Scope,
        [Parameter(Mandatory)] [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Log "Add-ModelsPathOverride: empty path supplied for scope '$Scope'" -Level "error"
        return
    }
    $cur = Read-ModelsPathOverrides -ScriptsRoot $ScriptsRoot
    $shared = @($cur.shared); $llama = @($cur.llama); $ollama = @($cur.ollama)
    $list = switch ($Scope) {
        'shared' { ,$shared }
        'llama'  { ,$llama }
        'ollama' { ,$ollama }
    }
    if ($list -and ($list | Where-Object { $_ -and $_.ToLower() -eq $Path.ToLower() })) {
        Write-Log "Path already present for '$Scope': $Path" -Level "info"
        return
    }
    $list += $Path
    switch ($Scope) {
        'shared' { $shared = $list }
        'llama'  { $llama  = $list }
        'ollama' { $ollama = $list }
    }
    $store = _WriteOverridesStore -ScriptsRoot $ScriptsRoot -SharedList $shared -LlamaList $llama -OllamaList $ollama
    if ($store) {
        Write-Log "Added '$Scope' model dir: $Path  (total: $($list.Count)) [$store]" -Level "success"
    }
}

function Remove-ModelsPathOverride {
    <#
    .SYNOPSIS
        Remove a single directory from the override list for a scope
        (case-insensitive match).
    #>
    param(
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] [ValidateSet('shared','llama','ollama')] [string]$Scope,
        [Parameter(Mandatory)] [string]$Path
    )
    $cur = Read-ModelsPathOverrides -ScriptsRoot $ScriptsRoot
    $shared = @($cur.shared); $llama = @($cur.llama); $ollama = @($cur.ollama)
    $list = switch ($Scope) {
        'shared' { ,$shared }
        'llama'  { ,$llama }
        'ollama' { ,$ollama }
    }
    $before = @($list).Count
    $list = @($list | Where-Object { $_ -and $_.ToLower() -ne $Path.ToLower() })
    if ($list.Count -eq $before) {
        Write-Log "No matching path to remove for '$Scope': $Path" -Level "warn"
        return
    }
    switch ($Scope) {
        'shared' { $shared = $list }
        'llama'  { $llama  = $list }
        'ollama' { $ollama = $list }
    }
    $store = _WriteOverridesStore -ScriptsRoot $ScriptsRoot -SharedList $shared -LlamaList $llama -OllamaList $ollama
    if ($store) {
        Write-Log "Removed '$Scope' model dir: $Path  (remaining: $($list.Count)) [$store]" -Level "success"
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
          5. <DEV_DIR>\<configured subfolder, default 'models'>
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

    # Per-backend default subfolders -- now both default to 'models'
    $llamaSub  = "models"
    $ollamaSub = "models"
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
            $extras = @($overrides.$BackendKey)
            $all = @($envVal) + @($extras | Where-Object { $_ -and $_.ToLower() -ne $envVal.ToLower() })
            return @{ Path = $envVal; All = $all; Source = "env:$EnvName" }
        }

        $savedBackend = @($overrides.$BackendKey)
        if ($savedBackend.Count -gt 0) {
            return @{ Path = $savedBackend[0]; All = $savedBackend; Source = "saved:$BackendKey ($($savedBackend.Count) dir$(if ($savedBackend.Count -ne 1) {'s'}))" }
        }

        $envShared = $env:MODELS_DIR
        if (-not [string]::IsNullOrWhiteSpace($envShared)) {
            $p = (Join-Path $envShared $Sub)
            return @{ Path = $p; All = @($p); Source = "env:MODELS_DIR/$Sub" }
        }

        $sharedSaved = @($overrides.shared)
        if ($sharedSaved.Count -gt 0) {
            $all = @($sharedSaved | ForEach-Object { Join-Path $_ $Sub })
            return @{ Path = $all[0]; All = $all; Source = "saved:shared/$Sub ($($sharedSaved.Count) dir$(if ($sharedSaved.Count -ne 1) {'s'}))" }
        }

        if ($hasDevDir) {
            $p = (Join-Path $devDir $Sub)
            return @{ Path = $p; All = @($p); Source = "DEV_DIR/$Sub" }
        }
        return @{ Path = "<DEV_DIR not set>\$Sub"; All = @(); Source = "unresolved" }
    }

    $llama  = _ResolveOne -BackendKey 'llama'  -EnvName 'LLAMA_MODELS_DIR' -Sub $llamaSub
    $ollama = _ResolveOne -BackendKey 'ollama' -EnvName 'OLLAMA_MODELS'    -Sub $ollamaSub

    return [PSCustomObject]@{
        DevDir       = if ($hasDevDir) { $devDir } else { "(not set)" }
        DevDirSource = $devDirSource
        Llama        = $llama.Path
        LlamaAll     = @($llama.All)
        LlamaSource  = $llama.Source
        Ollama       = $ollama.Path
        OllamaAll    = @($ollama.All)
        OllamaSource = $ollama.Source
        SharedEnv    = $env:MODELS_DIR
        SharedSaved  = @($overrides.shared)
        IsResolved   = $hasDevDir -or (-not [string]::IsNullOrWhiteSpace($env:MODELS_DIR)) -or (@($overrides.shared).Count -gt 0)
    }
}

function Show-ModelDownloadPaths {
    param(
        [Parameter(Mandatory)] [PSObject]$Paths
    )
    Write-Host ""
    Write-Host "  Model download locations" -ForegroundColor Yellow
    Write-Host ("    DEV_DIR             : {0}  [{1}]" -f $Paths.DevDir, $Paths.DevDirSource) -ForegroundColor Gray

    Write-Host ("    llama.cpp (GGUF)    : {0}" -f $Paths.Llama) -ForegroundColor White
    Write-Host ("                          source: {0}" -f $Paths.LlamaSource) -ForegroundColor DarkGray
    if (@($Paths.LlamaAll).Count -gt 1) {
        for ($i = 1; $i -lt @($Paths.LlamaAll).Count; $i++) {
            Write-Host ("                          + extra [{0}]: {1}" -f ($i+1), $Paths.LlamaAll[$i]) -ForegroundColor White
        }
    }

    Write-Host ("    Ollama daemon store : {0}" -f $Paths.Ollama) -ForegroundColor White
    Write-Host ("                          source: {0}" -f $Paths.OllamaSource) -ForegroundColor DarkGray
    if (@($Paths.OllamaAll).Count -gt 1) {
        for ($i = 1; $i -lt @($Paths.OllamaAll).Count; $i++) {
            Write-Host ("                          + extra [{0}]: {1}" -f ($i+1), $Paths.OllamaAll[$i]) -ForegroundColor White
        }
    }

    if (@($Paths.SharedSaved).Count -gt 0) {
        Write-Host ""
        Write-Host "    Shared roots (apply to both backends):" -ForegroundColor Yellow
        $i = 0
        foreach ($s in @($Paths.SharedSaved)) {
            $i++
            Write-Host ("      [{0}] {1}" -f $i, $s) -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Host "  Override syntax" -ForegroundColor Yellow
    Write-Host "    Set (replace)      : .\run.ps1 models path llama   D:\gguf      |   .\run.ps1 models path ollama D:\ollama" -ForegroundColor DarkGray
    Write-Host "    Add another dir    : .\run.ps1 models path llama   add D:\gguf2 |   .\run.ps1 models path ollama add E:\models" -ForegroundColor DarkGray
    Write-Host "    Remove a dir       : .\run.ps1 models path llama   rm  D:\gguf2 |   .\run.ps1 models path ollama rm  E:\models" -ForegroundColor DarkGray
    Write-Host "    Shared (both)      : .\run.ps1 models path D:\ai   |   add D:\ai2  |   rm D:\ai2" -ForegroundColor DarkGray
    Write-Host "    Env vars           : `$env:LLAMA_MODELS_DIR  |  `$env:OLLAMA_MODELS  |  `$env:MODELS_DIR" -ForegroundColor DarkGray
    Write-Host "    Show / reset       : .\run.ps1 models path  |  .\run.ps1 models path --reset [llama|ollama|shared|all]" -ForegroundColor DarkGray
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
        Prints a rich, line-by-line catalog so long descriptions never
        wrap awkwardly across columns. The printed index can be passed
        back as: .\run.ps1 models download 5,6,10
    #>
    param(
        [Parameter(Mandatory)] [array]$Models,
        [string]$BackendLabel = "all backends",
        [PSObject]$DownloadPaths,
        [string]$FilterLabel = ""
    )

    Write-Host ""
    $headerLabel = if ($FilterLabel) { "{0} | filter: {1}" -f $BackendLabel, $FilterLabel } else { $BackendLabel }
    Write-Host ("  Available models ({0}): {1}" -f $headerLabel, $Models.Count) -ForegroundColor Yellow
    Write-Host "  Caps legend: [C]oding [R]easoning [W]riting [V]oice [M]ultilingual    Line 1: size | RAM | caps | (coding, reasoning, speed, overall) : numbers   9-10 = yellow" -ForegroundColor DarkGray
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
        $rOver   = _GetRawProp $rating 'overall'   '-'

        $purposeRaw = _GetRawProp $raw 'bestFor'
        if (-not $purposeRaw) { $purposeRaw = _GetRawProp $raw 'purpose' '' }
        $purpose = "$purposeRaw"

        $family   = "$(_GetRawProp $raw 'family' '')"
        $params   = "$(_GetRawProp $raw 'parameters' '')"
        $quant    = "$(_GetRawProp $raw 'quantization' '')"
        $license  = "$(_GetRawProp $raw 'license' '')"
        $notes    = "$(_GetRawProp $raw 'notes' '')"

        $marker     = if ($isCoding) { "*" } else { " " }
        $headColor  = if ($isCoding) { "Yellow" } else { "White" }
        $bodyColor  = "White"
        $dimColor   = "DarkGray"

        Write-Host ""
        Write-Host ("  {0,3} {1} {2}" -f $idx, $marker, $m.id) -ForegroundColor $headColor
        $detailParts = @()
        if ($family)  { $detailParts += $family }
        if ($params)  { $detailParts += $params }
        if ($quant)   { $detailParts += $quant }
        $detailParts += ("backend: {0}" -f $m.backend)
        Write-Host ("        {0}" -f ($detailParts -join " | ")) -ForegroundColor $dimColor

        # Line 1: size | RAM | caps | (coding, reasoning, speed, overall) : 7/8/9/9
        Write-Host ("        {0} | RAM {1} | {2}" -f $sizeStr, $ramStr, $caps) -ForegroundColor $bodyColor -NoNewline
        $ratings = @($rCode, $rReason, $rSpeed, $rOver)
        $ratingLabels = @("coding", "reasoning", "speed", "overall")
        $hasAnyRating = ($ratings | Where-Object { $_ -ne '-' -and $_ -ne '' }) -gt 0
        if ($hasAnyRating) {
            Write-Host "  (" -ForegroundColor $dimColor -NoNewline
            for ($i = 0; $i -lt $ratings.Count; $i++) {
                Write-Host ($ratingLabels[$i]) -ForegroundColor $dimColor -NoNewline
                if ($i -lt $ratings.Count - 1) {
                    Write-Host ", " -ForegroundColor $dimColor -NoNewline
                }
            }
            Write-Host ") : " -ForegroundColor $dimColor -NoNewline
            for ($i = 0; $i -lt $ratings.Count; $i++) {
                $val = $ratings[$i]
                $num = 0
                $color = $dimColor
                if ([int]::TryParse([string]$val, [ref]$num)) {
                    if ($num -ge 9)     { $color = "Yellow" }
                    elseif ($num -ge 7) { $color = "Green" }
                    elseif ($num -ge 5) { $color = "White" }
                    else                { $color = "DarkGray" }
                }
                Write-Host ($val) -ForegroundColor $color -NoNewline
                if ($i -lt $ratings.Count - 1) {
                    Write-Host "/" -ForegroundColor $dimColor -NoNewline
                }
            }
        }
        Write-Host ""

        # Line 2: Best for
        if ($purpose) {
            Write-Host ("        Best for: {0}" -f $purpose) -ForegroundColor $bodyColor
        }
        if ($notes) {
            Write-Host ("        Notes:    {0}" -f $notes) -ForegroundColor $dimColor
        }
        if ($license) {
            Write-Host ("        License:  {0}" -f $license) -ForegroundColor $dimColor
        }
    }
    Write-Host ""
    Write-Host "  ========================================================================" -ForegroundColor Cyan
    Write-Host "    How to download models -- syntax & examples" -ForegroundColor Cyan
    Write-Host "  ========================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Output directory" -ForegroundColor White
    Write-Host "    default                       per-backend (run 'models path' to inspect)" -ForegroundColor DarkGray
    Write-Host "    custom (shared override)      .\run.ps1 models path C:\ai\models" -ForegroundColor DarkGray
    Write-Host "    custom (backend-only)         .\run.ps1 models path llama  C:\ai\gguf" -ForegroundColor DarkGray
    Write-Host "                                  .\run.ps1 models path ollama C:\ai\ollama" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Single / multiple downloads  (use 'models-download' as a one-word shortcut)" -ForegroundColor White
    Write-Host "    .\run.ps1 models-download 93                              # by number from this list" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models-download 5,6,10                          # multiple by number" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models-download qwen2.5-coder-3b                # by id" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models-download qwen2.5-coder-3b,llama3.2       # multiple by id (CSV)" -ForegroundColor DarkGray
    Write-Host "    Equivalent two-word form:  .\run.ps1 models download 93" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Filter / sort by capability tag (use 'models list --tags' for the full set)" -ForegroundColor White
    Write-Host "    .\run.ps1 models list coding                              # only coding models" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list reasoning,speed                     # filter by reasoning, then sort by speed" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list voice,multilingual                  # multi-tag filter" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list llama coding                        # backend + capability filter" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Filter by family / RAM / size / capability (first-class flags)" -ForegroundColor White
    Write-Host "    .\run.ps1 models list --family qwen3.7                                # every Qwen 3.7 family member" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list --family qwen3.7 --max-ram 16                   # Qwen 3.7 that fits in 16 GB RAM" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list --family qwen3.7 --max-ram 16 --exclude 32b     # ...but skip 32B variants" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list --coding --max-size 8                           # coding models <= 8 GB on disk" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models-download --family qwen3.7 --max-ram 16 --all         # bulk download every match" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models-download --coding --max-ram 12 --all --dry-run       # preview without pulling" -ForegroundColor DarkGray
    Write-Host "    Tag-based shortcut (legacy):  .\run.ps1 models list coding | Select-String -NotMatch '32B'" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Ratings legend" -ForegroundColor White -NoNewline
    Write-Host "  (per-model line shows: code/reason/speed/overall, 0-10 scale)" -ForegroundColor DarkGray
    Write-Host "    " -NoNewline
    Write-Host "9-10 exceptional " -ForegroundColor Yellow -NoNewline
    Write-Host "| " -ForegroundColor DarkGray -NoNewline
    Write-Host "7-8 strong " -ForegroundColor Green -NoNewline
    Write-Host "| " -ForegroundColor DarkGray -NoNewline
    Write-Host "5-6 competent " -ForegroundColor White -NoNewline
    Write-Host "| " -ForegroundColor DarkGray -NoNewline
    Write-Host "<5 weak" -ForegroundColor DarkGray
    Write-Host ""

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
            # GUARD: do NOT auto-install Ollama. If the binary isn't on PATH,
            # tell the user to install it explicitly via script 42 and skip.
            $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
            if (-not $ollamaCmd) {
                Write-Log "Ollama is not installed. 'models download' will not auto-install backends." -Level "error"
                Write-Log "  Install it explicitly first:  .\run.ps1 -I 42        (or:  .\run.ps1 install ollama)" -Level "info"
                Write-Log "  Then re-run:                  .\run.ps1 models-download $ids" -Level "info"
                continue
            }
            # Pass model slugs via env var; script 42 reads OLLAMA_PULL_MODELS.
            # Use 'pull' (model-only) — never 'all', which would (re)install Ollama.
            $env:OLLAMA_PULL_MODELS = $ids
            & $script pull
            Remove-Item Env:\OLLAMA_PULL_MODELS -ErrorAction SilentlyContinue
        } else {
            # GUARD: do NOT auto-install llama.cpp binaries. Detect llama-cli /
            # llama-server / main on PATH or under the configured base dir.
            $llamaPresent = $false
            foreach ($exe in @("llama-cli","llama-server","main","llama")) {
                if (Get-Command $exe -ErrorAction SilentlyContinue) { $llamaPresent = $true; break }
            }
            if (-not $llamaPresent) {
                # Fallback: look under <DEV_DIR>\<devDirSubfolder> for any llama-*.exe
                try {
                    $llamaCfgPath = Join-Path (Join-Path $ScriptsRoot $folder) "config.json"
                    $llamaCfg     = Get-Content $llamaCfgPath -Raw | ConvertFrom-Json
                    $devDir       = if ($env:DEV_DIR) { $env:DEV_DIR } else { "$env:USERPROFILE\dev" }
                    $baseDir      = Join-Path $devDir $llamaCfg.devDirSubfolder
                    if (Test-Path $baseDir) {
                        $found = Get-ChildItem -LiteralPath $baseDir -Recurse -Filter "llama-*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($found) { $llamaPresent = $true }
                    }
                } catch {}
            }
            if (-not $llamaPresent) {
                Write-Log "llama.cpp is not installed. 'models download' will not auto-install backends." -Level "error"
                Write-Log "  Install it explicitly first:  .\run.ps1 -I 43        (or:  .\run.ps1 install llama-cpp)" -Level "info"
                Write-Log "  Then re-run:                  .\run.ps1 models-download $ids" -Level "info"
                continue
            }
            # llama.cpp: pass via env var read by helpers/model-picker.ps1.
            # Use 'models' (model-only) — never 'all', which would re-download
            # the llama.cpp binaries.
            $env:LLAMA_CPP_INSTALL_IDS = $ids
            & $script models
            Remove-Item Env:\LLAMA_CPP_INSTALL_IDS -ErrorAction SilentlyContinue
        }
    }
}
