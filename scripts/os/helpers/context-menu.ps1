<#
.SYNOPSIS
    os context-menu -- read-only stub (P2). Lists the cross-OS action
    catalog and validates it against the schema. Install / uninstall /
    restore are NOT wired yet; they ship in P3+P6 (separate commit).

.DESCRIPTION
    Subcommands:
        list                Print the catalog in a colored table.
        validate            Re-parse the catalog + check shape (no writes).
        install|uninstall|restore   Print "not yet implemented" + exit 64.

    CODE RED: any file/path failure logs the exact path + reason via
    Write-FileError when available.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Action = "list",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$helpersDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$osDir      = Split-Path -Parent $helpersDir
$scriptsDir = Split-Path -Parent $osDir
$sharedDir  = Join-Path $scriptsDir "shared"

. (Join-Path $sharedDir "logging.ps1")

$catalogPath = Join-Path $sharedDir "context-menu-actions.json"
$schemaPath  = Join-Path $sharedDir "context-menu-actions.schema.json"

function Show-CatalogLoadError {
    param([string]$Path, [string]$Reason)
    if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
        Write-FileError -FilePath $Path -Operation "load" -Reason $Reason -Module "os context-menu"
    } else {
        Write-Host ""
        Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
        Write-Host "Cannot load context-menu catalog."
        Write-Host ("          Path   : " + $Path)   -ForegroundColor Gray
        Write-Host ("          Reason : " + $Reason) -ForegroundColor Gray
    }
}

function Get-Catalog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Show-CatalogLoadError -Path $Path -Reason "file does not exist on disk"
        return $null
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        Show-CatalogLoadError -Path $Path -Reason ("invalid JSON: " + $_.Exception.Message)
        return $null
    }
}

Write-Host ""
Write-Host "  os context-menu" -ForegroundColor Cyan
Write-Host "  ===============" -ForegroundColor DarkGray

$catalog = Get-Catalog -Path $catalogPath
if ($null -eq $catalog) { exit 2 }

$cmd = ($Action ?? "list").ToLower()
switch ($cmd) {
    'list' {
        Write-Host ("  Catalog : " + $catalogPath) -ForegroundColor DarkGray
        Write-Host ("  Schema  : " + $schemaPath)  -ForegroundColor DarkGray
        Write-Host ("  Version : " + $catalog.version) -ForegroundColor DarkGray
        Write-Host ""
        $fmt = "  {0,-4} {1,-12} {2,-22} {3,-40}"
        Write-Host ($fmt -f "ID", "OS", "Scopes", "Label") -ForegroundColor Yellow
        Write-Host ($fmt -f "----", "------------", "----------------------", "----------------------------------------") -ForegroundColor DarkGray
        foreach ($a in $catalog.actions) {
            $osStr    = ($a.os    -join ',')
            $scopeStr = ($a.scopes -join ',')
            $colour   = if ($a.PSObject.Properties['enabled'] -and -not $a.enabled) { "DarkGray" } else { "White" }
            Write-Host ($fmt -f $a.id, $osStr, $scopeStr, $a.label) -ForegroundColor $colour
        }
        Write-Host ""
        Write-Host "  Note: install/uninstall/restore land in the next commit (spec 55, P3+P6)." -ForegroundColor DarkGray
        exit 0
    }
    'validate' {
        $errors = @()
        if ($null -eq $catalog.actions) { $errors += "missing 'actions' array" }
        $ids = @{}
        foreach ($a in $catalog.actions) {
            if (-not $a.id)    { $errors += "action missing id" ; continue }
            if ($ids.ContainsKey($a.id)) { $errors += "duplicate id: $($a.id)" } else { $ids[$a.id] = $true }
            if (-not $a.label) { $errors += "$($a.id): missing label" }
            if (-not $a.scopes -or $a.scopes.Count -eq 0) { $errors += "$($a.id): empty scopes" }
            if (-not $a.os     -or $a.os.Count    -eq 0) { $errors += "$($a.id): empty os" }
        }
        if ($errors.Count -eq 0) {
            Write-Host "  [  OK  ] Catalog valid: $($catalog.actions.Count) actions, schema=$schemaPath" -ForegroundColor Green
            exit 0
        }
        foreach ($e in $errors) { Write-Host "  [ FAIL ] $e" -ForegroundColor Red }
        exit 1
    }
    { $_ -in 'install','uninstall','restore' } {
        $repoRoot = Split-Path -Parent $scriptsDir
        $confirmHelper = Join-Path $sharedDir "confirm-prompt.ps1"
        if (Test-Path -LiteralPath $confirmHelper) { . $confirmHelper }

        $isYes  = ($Rest -contains '--yes') -or ($Rest -contains '-y')
        $isNonI = ($Rest -contains '--non-interactive')

        $passthrough = @()
        foreach ($r in $Rest) {
            if ($r -in '--yes','-y','--non-interactive','--all') { continue }
            $passthrough += $r
        }

        switch ($cmd) {
            'install' {
                $action = "INSTALL Scripts Fixer right-click menu (catalog A1..B5 + script cascade) AND repair VS Code folder/empty-folder right-click."
                if (Get-Command Confirm-DestructiveAction -ErrorAction SilentlyContinue) {
                    $proceed = Confirm-DestructiveAction -ActionDescription $action -Yes:$isYes -NonInteractive:$isNonI
                    if (-not $proceed) { Write-Host "  [ INFO ] Cancelled." -ForegroundColor Yellow; exit 5 }
                }

                Write-Host ""
                Write-Host "  [ STEP 1/2 ] Repairing VS Code folder + empty-folder right-click (script 52)..." -ForegroundColor Cyan
                $rc52 = 0
                try {
                    & (Join-Path $repoRoot "run.ps1") -I 52 repair @passthrough
                    $rc52 = $LASTEXITCODE
                } catch {
                    Write-Host ("  [ FAIL ] script 52 threw: " + $_.Exception.Message) -ForegroundColor Red
                    $rc52 = 1
                }
                if ($rc52 -ne 0) { Write-Host "  [ WARN ] script 52 reported non-zero ($rc52). Continuing to script 53." -ForegroundColor Yellow }

                Write-Host ""
                Write-Host "  [ STEP 2/2 ] Installing Scripts Fixer cascading menu + Universal Actions (script 53)..." -ForegroundColor Cyan
                & (Join-Path $repoRoot "run.ps1") -I 53 install @passthrough
                $rc53 = $LASTEXITCODE

                $exitCode = if ($rc53 -ne 0) { $rc53 } elseif ($rc52 -ne 0) { $rc52 } else { 0 }
                Write-Host ""
                if ($exitCode -eq 0) {
                    Write-Host "  [  OK  ] Context menu install complete (52 + 53)." -ForegroundColor Green
                } else {
                    Write-Host "  [ FAIL ] Context menu install finished with errors (exit $exitCode)." -ForegroundColor Red
                }
                exit $exitCode
            }
            'uninstall' {
                $action = "UNINSTALL Scripts Fixer right-click menu from all scopes (script 53). VS Code keys are not touched here -- use 'restore' for that."
                if (Get-Command Confirm-DestructiveAction -ErrorAction SilentlyContinue) {
                    $proceed = Confirm-DestructiveAction -ActionDescription $action -Yes:$isYes -NonInteractive:$isNonI
                    if (-not $proceed) { Write-Host "  [ INFO ] Cancelled." -ForegroundColor Yellow; exit 5 }
                }
                & (Join-Path $repoRoot "run.ps1") -I 53 uninstall @passthrough
                exit $LASTEXITCODE
            }
            'restore' {
                $action = "RESTORE VS Code folder/empty-folder right-click from the newest registry snapshot (script 52 rollback)."
                if (Get-Command Confirm-DestructiveAction -ErrorAction SilentlyContinue) {
                    $proceed = Confirm-DestructiveAction -ActionDescription $action -Yes:$isYes -NonInteractive:$isNonI
                    if (-not $proceed) { Write-Host "  [ INFO ] Cancelled." -ForegroundColor Yellow; exit 5 }
                }
                & (Join-Path $repoRoot "run.ps1") -I 52 restore @passthrough
                exit $LASTEXITCODE
            }
        }
    }
    'list-snapshots' {
        Write-Host ""
        Write-Host "  [ INFO ] 'list-snapshots' is not implemented yet." -ForegroundColor Yellow
        Write-Host "          Browse: scripts\\52-vscode-folder-repair\\.installed\\snapshots\\" -ForegroundColor Gray
        exit 64
    }
    default {
        Write-Host "  [ FAIL ] Unknown subcommand: $cmd" -ForegroundColor Red
        Write-Host "          Try: list | validate | install | uninstall | restore" -ForegroundColor Gray
        exit 64
    }
}
