# --------------------------------------------------------------------------
#  scripts/shared/interactive-verify.ps1
#
#  Shared post-install interactive verification helper. After a context-menu
#  install/repair finishes, walks the user through right-clicking in three
#  Explorer locations and records whether they actually saw the entry. The
#  goal is to catch cases where the registry write reports OK but Explorer
#  still doesn't surface the menu (cache, shell extension order, profile
#  policy, etc.) -- automated checks alone can't detect that.
#
#  Public API:
#    Invoke-RightClickVerification
#       -Tool         <string>            Friendly tool name ('VS Code', 'ConEmu')
#       -EntryLabel   <string>            Exact menu text users should look for
#                                         (e.g. "Open with Code", "ConEmu Here")
#       -Contexts     <string[]>          Optional. Defaults to all three:
#                                         'folder', 'empty-folder', 'background'
#       -RetryCommand <string>            Copy-paste retry hint shown on FAIL
#       -NonInteractive                   Skip prompts entirely (CI mode)
#
#  Returns:
#    [pscustomobject] @{
#       Skipped     = $true|$false        True if NonInteractive / no TTY
#       AllPassed   = $true|$false
#       Results     = @(@{Context;Label;Passed;Note}, ...)
#    }
#
#  Why a separate helper:
#    - Script 52 (VS Code) and 59 (ConEmu) need the same UX
#    - Future context-menu scripts (PowerShell Here, Windows Terminal, ...)
#      can reuse it with a different EntryLabel
#    - Centralises the "is this a CI run?" detection so we never block a
#      pipeline waiting on Read-Host
# --------------------------------------------------------------------------

Set-StrictMode -Version Latest

# CI / non-interactive detection. We treat the helper as skipped if ANY of:
#   - explicit -NonInteractive switch
#   - $env:CI is set (GitHub Actions, GitLab, etc.)
#   - $env:SCRIPTS_FIXER_NONINTERACTIVE=1  (project-specific override)
#   - the host has no UI / stdin is redirected
function Test-IsInteractiveSession {
    if ($env:CI) { return $false }
    if ($env:SCRIPTS_FIXER_NONINTERACTIVE -eq '1') { return $false }
    # -y / --yes auto-skips: user said "assume yes to everything", which for a
    # *manual* right-click verification means "skip it, I trust the registry
    # writes". Treated identically to non-interactive.
    if ($env:SCRIPTS_FIXER_YES -eq '1' -or $env:SCRIPTS_FIXER_ASSUME_YES -eq '1') { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    } catch { } # older hosts may not expose IsInputRedirected -- fall through
    if ($null -eq $Host -or $null -eq $Host.UI -or $null -eq $Host.UI.RawUI) {
        return $false
    }
    return $true
}

function Read-YesNoOrSkip {
    param(
        [Parameter(Mandatory)][string]$Prompt
    )
    while ($true) {
        Write-Host "  ? $Prompt [y/n/s=skip] : " -ForegroundColor Cyan -NoNewline
        $val = Read-Host
        if ([string]::IsNullOrWhiteSpace($val)) { continue }
        switch -Regex ($val.Trim().ToLower()) {
            '^(y|yes)$'   { return 'yes' }
            '^(n|no)$'    { return 'no' }
            '^(s|skip)$'  { return 'skip' }
            default {
                Write-Host "    (please answer y, n, or s)" -ForegroundColor Yellow
            }
        }
    }
}

function Invoke-RightClickVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$EntryLabel,
        [string[]]$Contexts = @('folder','empty-folder','background'),
        [string]$RetryCommand = '',
        [switch]$NonInteractive,
        [Alias('Yes','y')]
        [switch]$AssumeYes
    )

    $result = [pscustomobject]@{
        Skipped   = $false
        AllPassed = $true
        Results   = @()
    }

    $isInteractive = Test-IsInteractiveSession
    if ($NonInteractive -or $AssumeYes -or -not $isInteractive) {
        $reason = if ($AssumeYes) { '-y / --yes flag' }
                  elseif ($NonInteractive) { '-NonInteractive flag' }
                  else { 'non-interactive shell / CI' }
        Write-Host ""
        Write-Host "  [skip] Right-click verification skipped ($reason)." -ForegroundColor DarkGray
        $result.Skipped = $true
        return $result
    }

    # ---- Context catalog ---------------------------------------------------
    # Each entry: short id, header, step-by-step instructions tailored to the
    # Explorer surface we want the user to test.
    $catalog = @{
        'folder' = @{
            Header = 'TEST 1/3 -- right-click on a FOLDER'
            Steps  = @(
                'Open File Explorer (Win+E).',
                'Navigate to any folder that contains other folders (e.g. C:\Users\<you>).',
                "Right-click ONE of the child folders (do NOT open it first).",
                'On Windows 11 click "Show more options" to see the classic menu.',
                "Look for the entry labelled: '$EntryLabel'."
            )
        }
        'empty-folder' = @{
            Header = 'TEST 2/3 -- right-click INSIDE an EMPTY folder'
            Steps  = @(
                'Create or open an empty folder (e.g. C:\Temp\rcm-test).',
                'Right-click on the empty white area inside the folder.',
                'On Windows 11 click "Show more options" to reveal the classic menu.',
                "Look for the entry labelled: '$EntryLabel'."
            )
        }
        'background' = @{
            Header = 'TEST 3/3 -- right-click on a folder BACKGROUND'
            Steps  = @(
                'Open any non-empty folder in File Explorer.',
                'Right-click on empty space BETWEEN files (the folder background).',
                'On Windows 11 click "Show more options" to reveal the classic menu.',
                "Look for the entry labelled: '$EntryLabel'."
            )
        }
    }

    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |  Quick verification for $Tool right-click entries" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  Walk through 3 short tests. Answer y / n, or s to skip one." -ForegroundColor DarkGray
    Write-Host ""

    foreach ($ctx in $Contexts) {
        if (-not $catalog.ContainsKey($ctx)) {
            Write-Host "  [warn] Unknown verification context '$ctx' -- skipping." -ForegroundColor Yellow
            continue
        }
        $entry = $catalog[$ctx]
        Write-Host "  $($entry.Header)" -ForegroundColor White
        Write-Host "  $('-' * [Math]::Min(60, $entry.Header.Length))" -ForegroundColor DarkGray
        $stepNum = 0
        foreach ($step in $entry.Steps) {
            $stepNum++
            Write-Host ("    {0}. {1}" -f $stepNum, $step) -ForegroundColor Gray
        }
        $answer = Read-YesNoOrSkip -Prompt "Did you see '$EntryLabel'?"
        $passed = $false
        $note   = ''
        switch ($answer) {
            'yes'  { $passed = $true;  $note = 'user confirmed' }
            'no'   { $passed = $false; $note = 'user reported missing' }
            'skip' { $passed = $true;  $note = 'skipped by user'; }
        }
        if ($answer -eq 'no') { $result.AllPassed = $false }
        $result.Results += @{
            Context = $ctx
            Label   = $entry.Header
            Passed  = $passed
            Note    = $note
            Answer  = $answer
        }
        Write-Host ""
    }

    # ---- Summary table -----------------------------------------------------
    Write-Host "  $Tool right-click verification :: summary" -ForegroundColor Cyan
    Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
    foreach ($r in $result.Results) {
        $marker = switch ($r.Answer) {
            'yes'  { '[OK]' }
            'no'   { '[XX]' }
            'skip' { '[--]' }
            default { '[??]' }
        }
        $color = switch ($r.Answer) {
            'yes'  { 'Green' }
            'no'   { 'Red' }
            'skip' { 'DarkGray' }
            default { 'Yellow' }
        }
        Write-Host ("  {0}  {1,-14}  {2}" -f $marker, $r.Context, $r.Note) -ForegroundColor $color
    }
    Write-Host ""

    if (-not $result.AllPassed) {
        Write-Host "  [!!] One or more right-click contexts did not show '$EntryLabel'." -ForegroundColor Yellow
        if ($RetryCommand) {
            Write-Host "       Retry with:  $RetryCommand" -ForegroundColor Yellow
        }
        Write-Host "       Tip: sign out / sign back in (or restart explorer.exe) and re-test." -ForegroundColor DarkGray
    } else {
        Write-Host "  [OK] All confirmed right-click contexts show '$EntryLabel'." -ForegroundColor Green
    }

    return $result
}
