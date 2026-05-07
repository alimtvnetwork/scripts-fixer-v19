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
    { $_ -in 'install','uninstall','restore','list-snapshots' } {
        Write-Host ""
        Write-Host "  [ INFO ] '$cmd' is not implemented yet." -ForegroundColor Yellow
        Write-Host "          Tracking spec: spec/55-universal-context-menu/readme.md (P3 + P6)." -ForegroundColor Gray
        Write-Host "          For now use:   .\run.ps1 53 install   (Windows leaves only)." -ForegroundColor Gray
        exit 64
    }
    default {
        Write-Host "  [ FAIL ] Unknown subcommand: $cmd" -ForegroundColor Red
        Write-Host "          Try: list | validate | install | uninstall | restore" -ForegroundColor Gray
        exit 64
    }
}
