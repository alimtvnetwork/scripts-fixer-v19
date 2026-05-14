# --------------------------------------------------------------------------
#  Models orchestrator -- catalog filter / sort helpers
#
#  Kept as a small, focused module so picker.ps1 stays readable.
#
#  Public surface:
#    Get-ModelTagSet       -- derive boolean tag map for one catalog entry
#    Resolve-FilterTags    -- parse "coding" or "coding,speed" CSV into tags
#    Invoke-ModelFilter    -- apply primary tag as filter, rest as sort priority
#    Show-FilterTagsHelp   -- list every supported tag + alias for help screens
#
#  Tag groups
#    capability tags (used as PRIMARY filter -- model must have them):
#      coding (alias: code, dev, programming)
#      reasoning (alias: reason, think, thinking)
#      writing (alias: write, prose, creative)
#      voice (alias: speech, audio, transcribe)
#      multilingual (alias: multi, translate, translation)
#      chat (alias: assistant, conversation)
#    quality / size tags (used as SORT keys, also valid as filters):
#      speed (alias: fast, quick)            -- highest rating.speed first
#      best  (alias: top, quality, overall)  -- highest rating.overall first
#      small (alias: tiny, light, low-ram)   -- lowest fileSizeGB first
#      large (alias: big, heavy)             -- highest fileSizeGB first
#
#  Filter spec examples (`models list <spec>`):
#    coding              -> all coding models, default order (catalog order)
#    coding,speed        -> coding models, fastest first
#    code,speed,small    -> coding models, fastest first then smallest first
#    reasoning,best      -> reasoning models, highest overall rating first
#    voice               -> all voice/audio models
# --------------------------------------------------------------------------

# Internal: alias -> canonical tag.  Order: capability first, then sort tags.
$script:_ModelsTagAliases = @{
    # capability
    "coding"        = "coding"
    "code"          = "coding"
    "dev"           = "coding"
    "programming"   = "coding"
    "developer"     = "coding"
    "reasoning"     = "reasoning"
    "reason"        = "reasoning"
    "think"         = "reasoning"
    "thinking"      = "reasoning"
    "logic"         = "reasoning"
    "writing"       = "writing"
    "write"         = "writing"
    "prose"         = "writing"
    "creative"      = "writing"
    "voice"         = "voice"
    "speech"        = "voice"
    "audio"         = "voice"
    "transcribe"    = "voice"
    "transcription" = "voice"
    "multilingual"  = "multilingual"
    "multi"         = "multilingual"
    "translate"     = "multilingual"
    "translation"   = "multilingual"
    "chat"          = "chat"
    "assistant"     = "chat"
    "conversation"  = "chat"
    # quality / size (sortable + filterable)
    "speed"         = "speed"
    "fast"          = "speed"
    "quick"         = "speed"
    "best"          = "best"
    "top"           = "best"
    "quality"       = "best"
    "overall"       = "best"
    "small"         = "small"
    "tiny"          = "small"
    "light"         = "small"
    "low-ram"       = "small"
    "lowram"        = "small"
    "large"         = "large"
    "big"           = "large"
    "heavy"         = "large"
}

function _GetProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    try {
        if ($Obj.PSObject.Properties.Name -contains $Name) {
            $v = $Obj.$Name
            if ($null -eq $v) { return $Default }
            return $v
        }
    } catch { }
    return $Default
}

function Get-ModelTagSet {
    <#
    .SYNOPSIS
        Returns a hashtable of canonical tag -> $true for every capability /
        size bucket the catalog entry belongs to.
    #>
    param([Parameter(Mandatory)] $Raw)

    $tags = @{}

    if ([bool](_GetProp $Raw 'isCoding'       $false)) { $tags['coding']       = $true }
    if ([bool](_GetProp $Raw 'isReasoning'    $false)) { $tags['reasoning']    = $true }
    if ([bool](_GetProp $Raw 'isWriting'      $false)) { $tags['writing']      = $true }
    if ([bool](_GetProp $Raw 'isVoice'        $false)) { $tags['voice']        = $true }
    if ([bool](_GetProp $Raw 'isMultilingual' $false)) { $tags['multilingual'] = $true }
    if ([bool](_GetProp $Raw 'isChat'         $false)) { $tags['chat']         = $true }

    # Fallback: infer capability from `purpose` field (used by the lighter
    # Ollama defaults config, which does not carry the full is* flags).
    $purpose = "$(_GetProp $Raw 'purpose' '')".ToLower()
    if ($purpose) {
        if ($purpose -match 'cod')                       { $tags['coding']       = $true }
        if ($purpose -match 'reason|think|logic')        { $tags['reasoning']    = $true }
        if ($purpose -match 'writ|prose|creative')       { $tags['writing']      = $true }
        if ($purpose -match 'voice|speech|audio')        { $tags['voice']        = $true }
        if ($purpose -match 'translat|multilingual')     { $tags['multilingual'] = $true }
        if ($purpose -match 'chat|assistant|general')    { $tags['chat']         = $true }
    }

    # Size buckets derived from fileSizeGB / sizeHint.
    # small  : <= 3 GB    large : >= 12 GB
    $sizeGB = [double](_GetProp $Raw 'fileSizeGB' 0)
    if ($sizeGB -le 0) {
        $hint = "$(_GetProp $Raw 'sizeHint' '')"
        if ($hint -match '([\d\.]+)\s*GB') { $sizeGB = [double]$Matches[1] }
    }
    if ($sizeGB -gt 0 -and $sizeGB -le 3)  { $tags['small'] = $true }
    if ($sizeGB -ge 12)                     { $tags['large'] = $true }

    # speed / best are flags only when ratings are very high; mostly used as sort keys.
    $rating = _GetProp $Raw 'rating'
    $speed  = [int](_GetProp $rating 'speed' 0)
    $best   = [int](_GetProp $rating 'overall' 0)
    if ($speed -ge 9) { $tags['speed'] = $true }
    if ($best  -ge 8) { $tags['best']  = $true }

    return $tags
}

function Resolve-FilterTags {
    <#
    .SYNOPSIS
        Parses "coding" or "coding,speed" or "code, fast , small" into an
        ordered list of canonical tags. Unknown tokens are returned in
        $UnknownOut so the caller can warn the user.
    #>
    param(
        [string]$Spec,
        [ref]$UnknownOut
    )
    if ($null -ne $UnknownOut) { $UnknownOut.Value = @() }
    if ([string]::IsNullOrWhiteSpace($Spec)) { return @() }

    $resolved = @()
    $unknown  = @()
    foreach ($raw in ($Spec -split '[,\s]+')) {
        $t = $raw.Trim().ToLower()
        if (-not $t) { continue }
        if ($script:_ModelsTagAliases.ContainsKey($t)) {
            $canon = $script:_ModelsTagAliases[$t]
            if ($resolved -notcontains $canon) { $resolved += $canon }
        } else {
            $unknown += $t
        }
    }
    if ($null -ne $UnknownOut) { $UnknownOut.Value = $unknown }
    return $resolved
}

function _GetSortKey {
    param($Model, [string]$Tag)
    $raw    = $Model.raw
    $rating = _GetProp $raw 'rating'
    switch ($Tag) {
        "speed"     { return -([int](_GetProp $rating 'speed'     0)) }   # negative = desc
        "best"      { return -([int](_GetProp $rating 'overall'   0)) }
        "coding"    { return -([int](_GetProp $rating 'coding'    0)) }
        "reasoning" { return -([int](_GetProp $rating 'reasoning' 0)) }
        "small"     {
            $sz = [double](_GetProp $raw 'fileSizeGB' 0)
            if ($sz -le 0) { $sz = 999 }
            return $sz                                                       # asc
        }
        "large"     { return -([double](_GetProp $raw 'fileSizeGB' 0)) }     # desc
        default     { return 0 }
    }
}

function Invoke-ModelFilter {
    <#
    .SYNOPSIS
        Filters $Models by the FIRST tag (model must have it), then sorts by
        the remaining tags in priority order. If no tags are given returns
        $Models unchanged.

    .PARAMETER Models
        Array of {id; displayName; backend; raw} produced by Get-BackendCatalog.

    .PARAMETER Tags
        Ordered list of canonical tags from Resolve-FilterTags.
    #>
    param(
        [Parameter(Mandatory)] [array]$Models,
        [array]$Tags = @()
    )

    if (-not $Tags -or $Tags.Count -eq 0) { return $Models }

    $primary = $Tags[0]
    $sortKeys = if ($Tags.Count -gt 1) { @($Tags[1..($Tags.Count-1)]) } else { @() }

    # If only one tag was supplied, treat it as both filter AND sort key when
    # it is a quality/size tag. e.g. `list speed` -> all models, fastest first.
    $isQualityOnly = $sortKeys.Count -eq 0 -and $primary -in @("speed","best","small","large")
    if ($isQualityOnly) {
        $sortKeys = @($primary)
        $filtered = $Models
    } else {
        $filtered = @()
        foreach ($m in $Models) {
            $tagSet = Get-ModelTagSet -Raw $m.raw
            if ($tagSet.ContainsKey($primary)) { $filtered += $m }
        }
    }

    if ($sortKeys.Count -eq 0) { return $filtered }

    # Stable, multi-key sort by computing a tuple of keys per model.
    $withKeys = @()
    foreach ($m in $filtered) {
        $keys = @()
        foreach ($k in $sortKeys) { $keys += (_GetSortKey -Model $m -Tag $k) }
        $withKeys += [PSCustomObject]@{ Model = $m; Keys = $keys }
    }
    $sorted = $withKeys | Sort-Object -Property `
        @{ Expression = { $_.Keys[0] } }, `
        @{ Expression = { if ($_.Keys.Count -gt 1) { $_.Keys[1] } else { 0 } } }, `
        @{ Expression = { if ($_.Keys.Count -gt 2) { $_.Keys[2] } else { 0 } } }, `
        @{ Expression = { if ($_.Keys.Count -gt 3) { $_.Keys[3] } else { 0 } } }
    return ,@($sorted | ForEach-Object { $_.Model })
}

# --------------------------------------------------------------------------
#  First-class flag surface (mirrors the Linux model-pull.sh contract).
#
#  Read-ModelFlagOptions parses an args array and returns:
#    @{
#      Options    = @{ Family; MaxRam; MinRam; MaxSize; MinSize; Exclude;
#                      Capabilities; All; DryRun }
#      Positional = @(...)   # non-flag tokens, in original order
#    }
#
#  Invoke-ModelFlagFilter applies those options to a model array (the same
#  {id; displayName; backend; raw} shape Get-BackendCatalog produces).
# --------------------------------------------------------------------------

function Read-ModelFlagOptions {
    param([array]$Argv = @())

    $opts = @{
        Family       = @()
        MaxRam       = $null
        MinRam       = $null
        MaxSize      = $null
        MinSize      = $null
        Exclude      = @()
        Capabilities = @()
        All          = $false
        DryRun       = $false
    }
    $positional = @()
    $capFlags   = @{
        "--coding"       = "coding"
        "--reasoning"    = "reasoning"
        "--writing"      = "writing"
        "--voice"        = "voice"
        "--multilingual" = "multilingual"
        "--chat"         = "chat"
    }
    $i = 0
    while ($i -lt $Argv.Count) {
        $a = "$($Argv[$i])"
        $low = $a.ToLower()
        switch -Regex ($low) {
            '^--family$'   { $i++; if ($i -lt $Argv.Count) { $opts.Family  += ("$($Argv[$i])" -split '[,\s]+' | Where-Object { $_ }) }; break }
            '^--max-ram$'  { $i++; if ($i -lt $Argv.Count) { $opts.MaxRam   = [double]"$($Argv[$i])" }; break }
            '^--min-ram$'  { $i++; if ($i -lt $Argv.Count) { $opts.MinRam   = [double]"$($Argv[$i])" }; break }
            '^--max-size$' { $i++; if ($i -lt $Argv.Count) { $opts.MaxSize  = [double]"$($Argv[$i])" }; break }
            '^--min-size$' { $i++; if ($i -lt $Argv.Count) { $opts.MinSize  = [double]"$($Argv[$i])" }; break }
            '^--exclude$'  { $i++; if ($i -lt $Argv.Count) { $opts.Exclude += ("$($Argv[$i])" -split '[,\s]+' | Where-Object { $_ }) }; break }
            '^--all$'      { $opts.All    = $true; break }
            '^--dry-run$'  { $opts.DryRun = $true; break }
            default {
                if ($capFlags.ContainsKey($low)) {
                    $opts.Capabilities += $capFlags[$low]
                } else {
                    $positional += $a
                }
            }
        }
        $i++
    }
    return @{ Options = $opts; Positional = @($positional) }
}

function Invoke-ModelFlagFilter {
    param(
        [Parameter(Mandatory)] [array]$Models,
        [Parameter(Mandatory)] [hashtable]$Options
    )

    $out = @()
    foreach ($m in $Models) {
        $raw     = $m.raw
        $family  = "$(_GetProp $raw 'family' '')"
        $idLow   = "$($m.id)".ToLower()
        $famLow  = $family.ToLower()
        $sizeGB  = [double](_GetProp $raw 'fileSizeGB' 0)
        $ramGB   = [double](_GetProp $raw 'ramRequiredGB' 0)

        if ($Options.Family.Count -gt 0) {
            $hit = $false
            foreach ($f in $Options.Family) {
                $fl = "$f".ToLower()
                if ($famLow -like "*$fl*" -or $idLow -like "*$fl*") { $hit = $true; break }
            }
            if (-not $hit) { continue }
        }

        if ($Options.Exclude.Count -gt 0) {
            $skip = $false
            foreach ($x in $Options.Exclude) {
                $xl = "$x".ToLower()
                if (-not $xl) { continue }
                if ($idLow -like "*$xl*" -or $famLow -like "*$xl*") { $skip = $true; break }
            }
            if ($skip) { continue }
        }

        if ($null -ne $Options.MaxRam  -and $ramGB  -gt 0 -and $ramGB  -gt $Options.MaxRam)  { continue }
        if ($null -ne $Options.MinRam  -and $ramGB  -gt 0 -and $ramGB  -lt $Options.MinRam)  { continue }
        if ($null -ne $Options.MaxSize -and $sizeGB -gt 0 -and $sizeGB -gt $Options.MaxSize) { continue }
        if ($null -ne $Options.MinSize -and $sizeGB -gt 0 -and $sizeGB -lt $Options.MinSize) { continue }

        if ($Options.Capabilities.Count -gt 0) {
            $tagSet = Get-ModelTagSet -Raw $raw
            $hasAll = $true
            foreach ($c in $Options.Capabilities) {
                if (-not $tagSet.ContainsKey($c)) { $hasAll = $false; break }
            }
            if (-not $hasAll) { continue }
        }

        $out += $m
    }
    return ,@($out)
}

function Test-ModelFlagOptionsActive {
    param([hashtable]$Options)
    if (-not $Options) { return $false }
    if ($Options.Family.Count       -gt 0) { return $true }
    if ($Options.Exclude.Count      -gt 0) { return $true }
    if ($Options.Capabilities.Count -gt 0) { return $true }
    foreach ($k in @('MaxRam','MinRam','MaxSize','MinSize')) {
        if ($null -ne $Options[$k]) { return $true }
    }
    return $false
}

function Show-FilterTagsHelp {
    <#
    .SYNOPSIS
        Prints the list of every supported filter tag and its aliases.
        Used by `models list --tags` and the help screen.
    #>
    Write-Host ""
    Write-Host "  Filter tags (use as 'models list <tag>' or 'models list <tag>,<sort>,<sort>')" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Capability tags (filter):" -ForegroundColor Cyan
    Write-Host "    coding       (aliases: code, dev, programming, developer)"
    Write-Host "    reasoning    (aliases: reason, think, thinking, logic)"
    Write-Host "    writing      (aliases: write, prose, creative)"
    Write-Host "    voice        (aliases: speech, audio, transcribe)"
    Write-Host "    multilingual (aliases: multi, translate, translation)"
    Write-Host "    chat         (aliases: assistant, conversation)"
    Write-Host ""
    Write-Host "  Sort / size tags (filter or order):" -ForegroundColor Cyan
    Write-Host "    speed        (aliases: fast, quick)        -- highest rating.speed first"
    Write-Host "    best         (aliases: top, quality)       -- highest rating.overall first"
    Write-Host "    small        (aliases: tiny, light)        -- smallest fileSizeGB first"
    Write-Host "    large        (aliases: big, heavy)         -- largest fileSizeGB first"
    Write-Host ""
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list coding              # all coding models"
    Write-Host "    .\run.ps1 models list coding,speed        # coding, fastest first"
    Write-Host "    .\run.ps1 models list code,speed,small    # coding, fast, then smallest"
    Write-Host "    .\run.ps1 models list reasoning,best      # reasoning, top quality first"
    Write-Host "    .\run.ps1 models list voice               # all voice models"
    Write-Host ""
    Write-Host "  First-class flags (combine with any list/download command):" -ForegroundColor Cyan
    Write-Host "    --family <name[,name]>   match family or id substring (e.g. qwen3.7, gemma)"
    Write-Host "    --max-ram <GB>           keep models with ramRequiredGB <= GB"
    Write-Host "    --min-ram <GB>           keep models with ramRequiredGB >= GB"
    Write-Host "    --max-size <GB>          keep models with fileSizeGB     <= GB"
    Write-Host "    --min-size <GB>          keep models with fileSizeGB     >= GB"
    Write-Host "    --exclude <token[,...]>  drop models whose id/family contains any token (e.g. 32b)"
    Write-Host "    --coding | --reasoning | --writing | --voice | --multilingual | --chat"
    Write-Host "    --all                    auto-select every match for download (no prompt)"
    Write-Host "    --dry-run                with download: print matches, do not pull"
    Write-Host ""
    Write-Host "  Flag examples:" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 models list --family qwen3.7"
    Write-Host "    .\run.ps1 models list --family qwen3.7 --max-ram 16 --exclude 32b"
    Write-Host "    .\run.ps1 models list --coding --max-ram 12"
    Write-Host "    .\run.ps1 models download --family qwen3.7 --max-ram 16 --all"
    Write-Host "    .\run.ps1 models download --coding --max-size 8 --all --dry-run"
    Write-Host ""
}
