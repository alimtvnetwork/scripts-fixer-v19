<#
.SYNOPSIS
    Top-level path-quoting validator for the run.ps1 dispatcher.

.DESCRIPTION
    PowerShell silently splits a bareword argument that contains spaces into
    multiple positional arguments. That has bitten us repeatedly when users
    type things like:

        .\run install vscode C:\Program Files\My Stuff

    PowerShell hands the script: ["vscode", "C:\Program", "Files\My", "Stuff"]
    -- and the install logic happily marches on with garbage paths.

    Test-DispatcherArgs runs BEFORE any child run.ps1 is invoked. It looks for
    the fingerprints of a split path and prints a friendly, copy-pasteable
    fix using a single Write-Host block (no Write-Error stack trace noise).

    Returns $true if args look fine, $false if a problem was reported.
    Callers decide whether to abort (recommended) or continue.

.NOTES
    Helper version: 1.0.0
#>

# Dot-source logging helper if available so we also persist the warning.
$_loggingPath = Join-Path $PSScriptRoot "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

function Test-DispatcherArgs {
    <#
    .SYNOPSIS
        Validate the raw argv-style args the dispatcher received.

    .PARAMETER Args
        The remaining-arguments array (typically $Install or a copy of $args).

    .PARAMETER Command
        The positional Command value, if any.

    .PARAMETER Context
        Free-form label used in the friendly error message
        (e.g. "install keyword", "run.ps1").

    .OUTPUTS
        Hashtable: @{ Ok = [bool]; Issues = [string[]]; FixHint = [string] }
    #>
    [CmdletBinding()]
    param(
        [Alias('Args')]
        [string[]]$Argv,
        [string]$Command,
        [string]$Context = "run.ps1"
    )

    $issues = New-Object System.Collections.Generic.List[string]

    # 1. Path-fragment detection across consecutive args.
    #    A bareword like "C:\Program" followed by "Files\foo" is the classic
    #    "user forgot to quote a path" pattern.
    $allTokens = @()
    if (-not [string]::IsNullOrWhiteSpace($Command)) { $allTokens += $Command }
    if ($Argv) { $allTokens += $Argv }


    $isDriveStart   = { param($s) $s -match '^[A-Za-z]:[\\/]' }
    $isPathFragment = { param($s) $s -match '[\\/]' -and $s -notmatch '^-' }

    for ($i = 0; $i -lt $allTokens.Count - 1; $i++) {
        $cur  = "$($allTokens[$i])"
        $next = "$($allTokens[$i + 1])"
        $hasDrive    = & $isDriveStart $cur
        $hasFragment = & $isPathFragment $next
        if ($hasDrive -and $hasFragment) {
            $reconstructed = ($allTokens[$i..($allTokens.Count - 1)] -join ' ')
            $issues.Add("Looks like a path was split across multiple arguments: '$cur' '$next' ... -- did you mean: ""$reconstructed"" ?") | Out-Null
            break
        }
    }

    # 2. UNC-share fragment split: "\\server" + "share\foo"
    for ($i = 0; $i -lt $allTokens.Count - 1; $i++) {
        $cur  = "$($allTokens[$i])"
        $next = "$($allTokens[$i + 1])"
        if ($cur -match '^\\\\[^\\]+$' -and $next -match '^[^\-/][^/]*') {
            $reconstructed = ($allTokens[$i..($allTokens.Count - 1)] -join ' ')
            $issues.Add("Looks like a UNC path was split: '$cur' '$next' -- did you mean: ""$reconstructed"" ?") | Out-Null
            break
        }
    }

    # 3. Per-arg fingerprints.
    foreach ($tok in $allTokens) {
        $s = "$tok"
        if ([string]::IsNullOrWhiteSpace($s)) { continue }

        if ($s.StartsWith('(') -and $s.EndsWith(')')) {
            $issues.Add("Argument '$s' looks paren-wrapped -- in PowerShell that runs the contents as code. Quote it instead: ""$($s.Trim('(', ')'))""") | Out-Null
        }

        $quoteCount = ($s.ToCharArray() | Where-Object { $_ -eq '"' }).Count
        if (($quoteCount % 2) -ne 0) {
            $issues.Add("Argument '$s' has an unbalanced double-quote. Wrap the whole path in matching quotes.") | Out-Null
        }

        if ($s.Contains("`n") -or $s.Contains("`r")) {
            $issues.Add("Argument '$s' contains a newline -- usually means args got concatenated. Re-run with each argument on one line.") | Out-Null
        }
    }

    $hasIssues = $issues.Count -gt 0
    $fixHint = if ($hasIssues) {
        "Always wrap any path with spaces in double quotes, e.g.  .\run.ps1 install vscode `"C:\Program Files\My Stuff`""
    } else { "" }

    if ($hasIssues) {
        Show-DispatcherArgError -Issues $issues -Context $Context -FixHint $fixHint -Args $allTokens
    }

    return @{
        Ok      = (-not $hasIssues)
        Issues  = @($issues)
        FixHint = $fixHint
    }
}

function Show-DispatcherArgError {
    <#
    .SYNOPSIS
        Pretty multi-line error block for malformed dispatcher args.
    #>
    param(
        [System.Collections.Generic.List[string]]$Issues,
        [string]$Context,
        [string]$FixHint,
        [string[]]$Args
    )

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Red
    Write-Host "  [ ARGS ] " -ForegroundColor Red -NoNewline
    Write-Host "Suspicious arguments passed to $Context" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor Red
    Write-Host ""

    Write-Host "  Received:" -ForegroundColor DarkGray
    if ($Args -and $Args.Count -gt 0) {
        for ($i = 0; $i -lt $Args.Count; $i++) {
            Write-Host ("    [{0}] " -f $i) -ForegroundColor DarkGray -NoNewline
            Write-Host "$($Args[$i])" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    (none)" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host "  Issues:" -ForegroundColor DarkGray
    foreach ($issue in $Issues) {
        Write-Host "    - " -ForegroundColor Red -NoNewline
        Write-Host $issue -ForegroundColor White
    }
    Write-Host ""

    if (-not [string]::IsNullOrWhiteSpace($FixHint)) {
        Write-Host "  Fix:" -ForegroundColor Cyan
        Write-Host "    $FixHint" -ForegroundColor White
        Write-Host ""
    }

    # Persist the warning to the JSON log if logging is initialised.
    $hasWriteLog = $null -ne (Get-Command Write-Log -ErrorAction SilentlyContinue)
    if ($hasWriteLog) {
        $summary = "dispatcherArgs context=$Context issues=$($Issues.Count)"
        Write-Log $summary -Level "warn"
        foreach ($issue in $Issues) { Write-Log "  -> $issue" -Level "warn" }
    }
}

function Test-ChildScriptArgs {
    <#
    .SYNOPSIS
        Lightweight sanity check on the hashtable about to be splatted into
        a child run.ps1. Catches the case where a value bound to a known
        path-typed parameter looks malformed.

    .PARAMETER ExtraArgs
        The hashtable to be splatted (`& $childRun @ExtraArgs`).

    .PARAMETER ScriptId
        Numeric script id (used in the friendly error block).

    .OUTPUTS
        [bool] $true if the args look safe, $false if any issue was reported.
    #>
    param(
        [hashtable]$ExtraArgs = @{},
        [int]$ScriptId = 0
    )

    if (-not $ExtraArgs -or $ExtraArgs.Count -eq 0) { return $true }

    # Parameter names that almost always carry filesystem paths.
    $pathParams = @(
        "Path", "Target", "Temp", "Source", "Destination", "Folder", "Dir",
        "InstallDir", "InstallPath", "OutFile", "LiteralPath", "FilePath",
        "WorkingDirectory", "RootDir", "ScriptDir", "DevDir"
    )

    $issues = New-Object System.Collections.Generic.List[string]

    foreach ($key in @($ExtraArgs.Keys)) {
        $value = $ExtraArgs[$key]
        $isPathParam = $pathParams -contains $key
        if (-not $isPathParam) { continue }
        if ($null -eq $value) { continue }
        $sval = "$value"
        if ([string]::IsNullOrWhiteSpace($sval)) { continue }

        if ($sval.StartsWith('(') -and $sval.EndsWith(')')) {
            $issues.Add("-$key was passed as '$sval' (looks paren-wrapped). Use double quotes around the path.") | Out-Null
        }
        if ((($sval.ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2) -ne 0) {
            $issues.Add("-$key was passed as '$sval' (unbalanced quote). Wrap the whole path in matching quotes.") | Out-Null
        }
        if ($sval.Contains("`n") -or $sval.Contains("`r")) {
            $issues.Add("-$key was passed as '$sval' (contains newline). Args got concatenated -- re-quote the path.") | Out-Null
        }
    }

    $hasIssues = $issues.Count -gt 0
    if ($hasIssues) {
        $context = "child script id=$('{0:D2}' -f $ScriptId)"
        $fix     = "Quote any path argument, e.g. -Path `"C:\Program Files\My Stuff`""
        Show-DispatcherArgError -Issues $issues -Context $context -FixHint $fix -Args (@($ExtraArgs.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }))
    }

    return (-not $hasIssues)
}
