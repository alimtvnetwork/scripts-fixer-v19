<#
.SYNOPSIS
    Emits "Universal Actions" leaves (catalog A1..B5) into the cascading
    Script Fixer menu (script 53). Reads the shared cross-OS catalog at
    scripts/shared/context-menu-actions.json.

.DESCRIPTION
    For each enabled catalog action whose scopes intersect the current
    Explorer scope (file / directory / background / desktop), this helper
    writes a leaf registry key with a command that substitutes Explorer's
    path placeholder (%V for background/directory, %1 for file).

    CODE RED: every load failure logs the exact JSON path + reason.
#>

$_helpersDir = $PSScriptRoot
$_scriptDir  = Split-Path -Parent $_helpersDir
$_scriptsDir = Split-Path -Parent $_scriptDir
$_sharedDir  = Join-Path $_scriptsDir "shared"

$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

function Get-CatalogActions {
    <#
    .SYNOPSIS
        Loads scripts/shared/context-menu-actions.json. Returns $null on any
        failure (caller logs/skips).
    #>
    param([string]$RepoRoot)
    $path = Join-Path $RepoRoot "scripts\shared\context-menu-actions.json"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log ("Catalog missing -- expected at: {0}" -f $path) -Level "warn"
        return $null
    }
    try {
        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return $json
    } catch {
        Write-Log ("FAILED to parse {0} -- {1}" -f $path, $_.Exception.Message) -Level "error"
        return $null
    }
}

function Test-CatalogScopeMatch {
    <#
    .SYNOPSIS
        Maps Explorer scope name (file/directory/background/desktop) to the
        catalog scope vocabulary (file/folder/background) and tests
        membership.
    #>
    param(
        [string]$ExplorerScope,
        [string[]]$CatalogScopes
    )
    $needles = switch ($ExplorerScope) {
        'file'       { ,'file' }
        'directory'  { ,'folder' }
        'background' { ,'background' }
        'desktop'    { ,'background' }
        default      { @() }
    }
    foreach ($n in $needles) {
        if ($CatalogScopes -contains $n) { return $true }
    }
    return $false
}

function Get-PathPlaceholder {
    <#
    .SYNOPSIS
        Returns the Explorer-side path token for the given scope. %V works
        for Directory + Background; %1 is needed for the * (file) scope.
    #>
    param([string]$ExplorerScope)
    if ($ExplorerScope -eq 'file') { return '%1' }
    return '%V'
}

function ConvertTo-LeafCommandLine {
    <#
    .SYNOPSIS
        Builds the registry command-line for one catalog action. Returns
        $null when the action's verb is unsupported on Windows (e.g. raw
        ConEmu launches that need runtime exe resolution).
    #>
    param(
        $Action,
        [string]$ExplorerScope,
        [string]$ShellExe,
        [string]$RepoRoot
    )

    $verb = $Action.command.verb
    $args = @($Action.command.args)
    $pathToken = Get-PathPlaceholder -ExplorerScope $ExplorerScope

    # Substitute {path} -> Explorer placeholder. Drop {conemuExe}/{cmd} actions.
    $resolved = @()
    $hasUnresolved = $false
    foreach ($a in $args) {
        $s = [string]$a
        if ($s -match '\{conemuExe\}|\{cmd\}') { $hasUnresolved = $true; break }
        $s = $s -replace '\{path\}', $pathToken
        $resolved += $s
    }
    if ($hasUnresolved) { return $null }

    # Quote args defensively (Explorer expands %V/%1 unquoted; we wrap).
    $quoted = $resolved | ForEach-Object {
        if ($_ -eq '%V' -or $_ -eq '%1') { "`"$_`"" }
        elseif ($_ -match '\s') { "`"$_`"" }
        else { $_ }
    }
    $argString = ($quoted -join ' ')

    switch ($verb) {
        'os' {
            $inner = "Set-Location -LiteralPath '$RepoRoot'; & '.\scripts\os\run.ps1' $argString"
            return "`"$ShellExe`" -NoExit -ExecutionPolicy Bypass -Command `"$inner`""
        }
        'run' {
            $inner = "Set-Location -LiteralPath '$RepoRoot'; & '.\run.ps1' $argString"
            return "`"$ShellExe`" -NoExit -ExecutionPolicy Bypass -Command `"$inner`""
        }
        'models' {
            $inner = "Set-Location -LiteralPath '$RepoRoot'; & '.\scripts\models\run.ps1' $argString"
            return "`"$ShellExe`" -NoExit -ExecutionPolicy Bypass -Command `"$inner`""
        }
        'raw' {
            return $null   # needs runtime exe resolution; out of scope for P3
        }
        default {
            return $null
        }
    }
}

function Add-CatalogLeaves {
    <#
    .SYNOPSIS
        Emits the "Universal Actions" sub-cascade (catalog A1..B5) under the
        given scope's top key. Returns @{Ok=<bool>; LeafCount=<int>} so the
        caller can fold into its install summary.
    #>
    param(
        [string]$TopKey,
        [string]$ExplorerScope,
        [string]$ShellExe,
        [string]$RepoRoot,
        [string]$IconPath,
        [int]$MaxLen,
        $LogMsgs
    )

    $result = @{ Ok = $true; LeafCount = 0 }

    $catalog = Get-CatalogActions -RepoRoot $RepoRoot
    if ($null -eq $catalog) {
        Write-Log "Catalog unavailable -- skipping universal actions for scope '$ExplorerScope'." -Level "warn"
        return $result
    }

    $applicable = @()
    foreach ($a in $catalog.actions) {
        $isEnabled = -not ($a.PSObject.Properties['enabled']) -or [bool]$a.enabled
        if (-not $isEnabled) { continue }
        if (-not ($a.os -contains 'windows')) { continue }
        if (-not (Test-CatalogScopeMatch -ExplorerScope $ExplorerScope -CatalogScopes $a.scopes)) { continue }
        $applicable += $a
    }
    if ($applicable.Count -eq 0) {
        Write-Log "  No catalog actions apply to scope '$ExplorerScope'." -Level "info"
        return $result
    }

    $catLabel = "Universal Actions"
    $catSafe  = ConvertTo-SafeSubkey -Name $catLabel -MaxLen $MaxLen
    $catKey   = "$TopKey\shell\$catSafe"

    Write-Log ("  Writing category 'Universal Actions' ({0} actions): {1}" -f $applicable.Count, (ConvertTo-RegExePath $catKey)) -Level "info"
    $okCat = New-CascadingParent `
        -PsPath        $catKey `
        -Label         $catLabel `
        -IconPath      $IconPath `
        -WithLuaShield $false `
        -LogMsgs       $LogMsgs
    if (-not $okCat) {
        $result.Ok = $false
        return $result
    }

    foreach ($a in $applicable) {
        $cmdLine = ConvertTo-LeafCommandLine -Action $a -ExplorerScope $ExplorerScope -ShellExe $ShellExe -RepoRoot $RepoRoot
        if ($null -eq $cmdLine) {
            Write-Log ("    [skip] {0} '{1}' -- verb '{2}' not supported via static registry on Windows." -f $a.id, $a.label, $a.command.verb) -Level "warn"
            continue
        }
        $leafSub = ConvertTo-SafeSubkey -Name ("U-" + $a.id) -MaxLen $MaxLen
        Write-Log ("    Writing universal leaf [{0}] {1}: {2}" -f $a.id, $a.label, (ConvertTo-RegExePath "$catKey\shell\$leafSub")) -Level "info"
        Write-Log ("      Command: {0}" -f $cmdLine) -Level "info"
        $okLeaf = New-LeafEntry `
            -ParentPsPath "$catKey\shell" `
            -LeafSubkey   $leafSub `
            -Label        $a.label `
            -IconPath     $ShellExe `
            -CommandLine  $cmdLine `
            -Extended     $false `
            -LogMsgs      $LogMsgs
        if (-not $okLeaf) {
            $result.Ok = $false
        } else {
            $result.LeafCount++
        }
    }

    return $result
}
