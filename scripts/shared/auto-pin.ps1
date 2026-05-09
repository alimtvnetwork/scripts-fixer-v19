# --------------------------------------------------------------------------
#  Shared helper: best-effort auto-pin to taskbar after an install.
#  Usage:
#     Invoke-AutoPin -App "vscode"
#  Loads scripts/62-pin-taskbar/helpers/pin.ps1 + config and calls
#  Invoke-PinTaskbarApps for the requested app key. Never throws -- any
#  failure is logged at warn level so the parent install still finishes ok.
# --------------------------------------------------------------------------

function Invoke-AutoPin {
    param(
        [Parameter(Mandatory)][string]$App
    )

    try {
        $repoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        # $PSScriptRoot here = scripts/shared, so repoRoot = repo root
        $pinDir     = Join-Path $repoRoot "scripts\62-pin-taskbar"
        $helperPath = Join-Path $pinDir "helpers\pin.ps1"
        $configPath = Join-Path $pinDir "config.json"
        $logMsgPath = Join-Path $pinDir "log-messages.json"

        $isHelperMissing = -not (Test-Path $helperPath)
        $isConfigMissing = -not (Test-Path $configPath)
        $isLogMsgMissing = -not (Test-Path $logMsgPath)
        if ($isHelperMissing -or $isConfigMissing -or $isLogMsgMissing) {
            Write-Log "Auto-pin: pin-taskbar assets missing -- skipping pin for '$App'." -Level "warn"
            return
        }

        . $helperPath
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $msg = Get-Content $logMsgPath -Raw | ConvertFrom-Json

        Write-Log "Auto-pin: requesting taskbar pin for '$App'..." -Level "info"
        $null = Invoke-PinTaskbarApps -AppsConfig $cfg -Names @($App) -LogMessages $msg
    } catch {
        Write-Log "Auto-pin failed for '$App': $_" -Level "warn"
    }
}
