# ============================================================================
#  scripts/shared/confirm-prompt.ps1
#  Shared interactive confirmation for destructive operations (uninstalls,
#  registry rollback, key removal). Honors --non-interactive / -y.
#
#  Usage:
#    if (-not (Confirm-DestructiveAction `
#                 -Title  "Uninstall ConEmu context menu" `
#                 -Detail "Removes 4 HKCR keys (snapshot is taken first)." `
#                 -NonInteractive:$NonInteractive `
#                 -AssumeYes:$AssumeYes)) {
#        Write-Log "Aborted by user." -Level "warn"
#        return
#    }
#
#  Behavior:
#    - $AssumeYes   -> auto-approve, log a clear "[ AUTO-YES ]" line.
#    - $NonInteractive without -AssumeYes -> auto-DENY with a clear log line
#      so we never silently destroy data in a CI/headless context.
#    - Otherwise prompt: "Type YES to continue (anything else aborts):"
# ============================================================================

function Confirm-DestructiveAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [string]$Detail = '',

        # Reuse switches from caller; pass with -NonInteractive:$switchVar
        [switch]$NonInteractive,
        [switch]$AssumeYes,

        # Word the user must type (case-insensitive). Default 'YES'.
        [string]$ConfirmWord = 'YES'
    )

    Write-Host ""
    Write-Host "  [ CONFIRM ] " -ForegroundColor Yellow -NoNewline
    Write-Host $Title -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host ("             " + $Detail) -ForegroundColor Gray
    }

    if ($AssumeYes) {
        Write-Host "  [ AUTO-YES ] " -ForegroundColor DarkGreen -NoNewline
        Write-Host "--yes / -y supplied -- proceeding without prompt." -ForegroundColor Gray
        return $true
    }

    if ($NonInteractive) {
        Write-Host "  [ ABORT ] " -ForegroundColor Red -NoNewline
        Write-Host "--non-interactive set without --yes/-y. Refusing destructive action." -ForegroundColor Gray
        Write-Host "             Re-run with --yes (or -y) to confirm in headless mode." -ForegroundColor DarkGray
        return $false
    }

    Write-Host ("  Type '{0}' to continue (anything else aborts): " -f $ConfirmWord) -ForegroundColor Yellow -NoNewline
    $answer = ''
    try {
        $answer = [string](Read-Host)
    } catch {
        Write-Host ""
        Write-Host "  [ ABORT ] " -ForegroundColor Red -NoNewline
        Write-Host "No interactive console available -- aborting." -ForegroundColor Gray
        return $false
    }

    if ($null -eq $answer) { $answer = '' }
    $answer = $answer.Trim()
    $isMatch = [string]::Equals($answer, $ConfirmWord, [System.StringComparison]::OrdinalIgnoreCase)

    if ($isMatch) {
        Write-Host "  [  OK   ] " -ForegroundColor Green -NoNewline
        Write-Host "Confirmed -- proceeding." -ForegroundColor Gray
        return $true
    }

    Write-Host "  [ ABORT ] " -ForegroundColor Red -NoNewline
    Write-Host ("Got '{0}' -- expected '{1}'. Aborting." -f $answer, $ConfirmWord) -ForegroundColor Gray
    return $false
}
