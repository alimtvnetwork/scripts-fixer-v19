<#
.SYNOPSIS
    Global -y / --yes argument parser + propagator.

.DESCRIPTION
    Single source of truth for "auto-confirm" intent across every dispatcher
    and child script in this repo. Solves the long-standing problem where
    `-y` was honoured by some scripts, dropped by others, and silently swallowed
    by PowerShell's parameter binder before reaching the install/profile
    dispatchers.

    Recognised tokens (case-insensitive, anywhere in the arg list):
        -y      -Y      /y
        --yes   -yes    /yes
        --non-interactive   --noninteractive
        --headless
        -AssumeYes          --assume-yes
        -AutoYes            --auto-yes

    What it does:
      1. Scans the supplied raw arg array for any of the tokens above.
      2. Optionally honours an already-bound -Y / -Yes switch from a parent
         param block (PowerShell's binder swallows `-y` BEFORE
         ValueFromRemainingArguments fires, so that path is critical for the
         root run.ps1).
      3. If yes-intent is detected:
           - sets $env:SCRIPTS_FIXER_YES = '1' (process-scoped; inherited by
             every child process / dot-sourced script automatically).
           - returns IsYes=$true and a FilteredArgs array with the yes tokens
             stripped (so callers can forward the rest to scripts that don't
             recognise them).
      4. If not detected, leaves the env var untouched (does NOT clear it --
         the caller may have inherited it from a parent dispatcher).

    Helpers exported:
        Get-YesFlagTokens       -- canonical token list
        Test-YesFlagInArgs      -- pure check, no side-effects
        Initialize-YesFlag      -- parse + set env + return {IsYes,FilteredArgs}
        Test-YesActive          -- read env var, returns [bool]
        Add-YesFlagToArgs       -- ensure '-y' is present in a forwarded arg
                                   array (used by routers like
                                   `install <profile>` -> profile dispatcher)

.NOTES
    Helper version: 1.0.0
    Env contract  : $env:SCRIPTS_FIXER_YES = '1' means "auto-confirm everything".
                    Read by scripts/shared/interactive-verify.ps1 and any other
                    helper that needs to skip an interactive prompt in CI /
                    `-y` mode.
#>

# Dot-source logging helper if available (for debug breadcrumbs).
$_yesLoggingPath = Join-Path $PSScriptRoot "logging.ps1"
if ((Test-Path $_yesLoggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_yesLoggingPath
}

function Get-YesFlagTokens {
    <#
    .SYNOPSIS
        Canonical list of tokens that mean "auto-confirm".
    #>
    return @(
        '-y', '/y',
        '--yes', '-yes', '/yes',
        '--non-interactive', '--noninteractive',
        '--headless',
        '-assumeyes', '--assume-yes',
        '-autoyes', '--auto-yes'
    )
}

function Test-YesFlagInArgs {
    <#
    .SYNOPSIS
        Pure check: does the arg array contain any yes-token?
    .OUTPUTS
        [bool]
    #>
    param([string[]]$Args)

    if (-not $Args -or $Args.Count -eq 0) { return $false }
    $tokens = Get-YesFlagTokens
    foreach ($a in $Args) {
        if ($null -eq $a) { continue }
        $low = "$a".Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($low)) { continue }
        if ($tokens -contains $low) { return $true }
    }
    return $false
}

function Initialize-YesFlag {
    <#
    .SYNOPSIS
        Detect yes-intent and propagate it via env var.
    .PARAMETER Args
        Raw arg array to scan (typically $Install, $Rest, or $args).
    .PARAMETER Bound
        Optional already-bound switch value (e.g. $Y from the root param
        block). PowerShell binds `-y`/`-Y` to a [switch] BEFORE the args
        array is built, so this is the only way to recover that intent at
        the root dispatcher level.
    .PARAMETER Source
        Free-form label written to the JSON log when yes-intent is detected.
    .OUTPUTS
        Hashtable: @{ IsYes = [bool]; FilteredArgs = [string[]]; Source = [string] }
    #>
    [CmdletBinding()]
    param(
        [string[]]$Args,
        [bool]$Bound = $false,
        [string]$Source = "dispatcher"
    )

    $tokens   = Get-YesFlagTokens
    $filtered = New-Object System.Collections.Generic.List[string]
    $hasToken = $false

    if ($Args) {
        foreach ($a in $Args) {
            if ($null -eq $a) { continue }
            $low = "$a".Trim().ToLower()
            $isYesToken = $tokens -contains $low
            if ($isYesToken) {
                $hasToken = $true
                continue
            }
            $filtered.Add($a) | Out-Null
        }
    }

    $isFromEnv = $env:SCRIPTS_FIXER_YES -eq '1'
    $isYes     = $hasToken -or $Bound -or $isFromEnv

    if ($isYes -and -not $isFromEnv) {
        # Set the env var so every spawned child process sees it. Process
        # scope is correct: -Scope Process is the default for $env:VAR=...
        # and is inherited by child processes.
        $env:SCRIPTS_FIXER_YES = '1'
        $hasWriteLog = $null -ne (Get-Command Write-Log -ErrorAction SilentlyContinue)
        if ($hasWriteLog) {
            $reason = if ($Bound) { 'bound -Y switch' } elseif ($hasToken) { 'token in args' } else { 'env inherited' }
            Write-Log ("[yes-flag] auto-confirm enabled by {0} (source={1})" -f $reason, $Source) -Level "info"
        }
    }

    return @{
        IsYes        = [bool]$isYes
        FilteredArgs = @($filtered)
        Source       = $Source
        FromEnv      = [bool]$isFromEnv
        FromBound    = [bool]$Bound
        FromToken    = [bool]$hasToken
    }
}

function Test-YesActive {
    <#
    .SYNOPSIS
        Returns $true if auto-confirm is currently active for this process.
        Reads $env:SCRIPTS_FIXER_YES -- the canonical signal set by
        Initialize-YesFlag.
    #>
    return ($env:SCRIPTS_FIXER_YES -eq '1')
}

function Add-YesFlagToArgs {
    <#
    .SYNOPSIS
        Ensure '-y' is present in an arg array that's about to be forwarded
        to a child dispatcher. No-op if any yes-token is already present.
    .PARAMETER Args
        The arg array.
    .PARAMETER Token
        Which token to append (default '-y').
    .OUTPUTS
        [string[]] -- possibly extended copy of $Args.
    #>
    param(
        [string[]]$Args,
        [string]$Token = '-y'
    )

    $existing = @()
    if ($Args) { $existing = @($Args) }
    if (Test-YesFlagInArgs -Args $existing) {
        return $existing
    }
    return $existing + $Token
}
