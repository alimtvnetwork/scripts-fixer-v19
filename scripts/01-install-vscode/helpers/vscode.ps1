# --------------------------------------------------------------------------
#  VS Code helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}


function Get-ChocoPackageVersion {
    <#
    .SYNOPSIS
        Robustly extract the installed version of a choco package.
        Handles Choco 1.x (--local-only) and 2.x output, and returns
        empty string when not installed (never the package name itself
        or summary text like "1 packages installed").
    #>
    param([Parameter(Mandatory)][string]$PackageName)

    # Choco 2.x removed --local-only; pass it anyway -- choco emits a
    # deprecation warning to stderr but still works. Capture only stdout.
    $raw = & choco list --exact $PackageName --limit-output 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return "" }

    # --limit-output format is strictly "name|version" per line.
    foreach ($line in @($raw)) {
        $isMatch = $line -match "^$([regex]::Escape($PackageName))\|(.+)$"
        if ($isMatch) { return $Matches[1].Trim() }
    }
    return ""
}

function Install-VsCodeEdition {
    param(
        [string]$ChocoPackageName,
        [string]$Label,
        [string]$TrackingName,
        $LogMessages
    )

    Write-Log ($LogMessages.messages.installingEdition -replace '\{label\}', $Label) -Level "info"

    # Tracking name comes from caller (canonical: 'vscode' / 'vscode-insiders')
    # so we never get doubled names like 'vscode-vs-code-stable'.
    $isTrackingMissing = [string]::IsNullOrWhiteSpace($TrackingName)
    if ($isTrackingMissing) {
        $TrackingName = "vscode-" + ($Label.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    }

    # Check if already installed via robust parser
    $chocoVersion = Get-ChocoPackageVersion -PackageName $ChocoPackageName
    $isInstalled = -not [string]::IsNullOrWhiteSpace($chocoVersion)
    if ($isInstalled) {
        # Check .installed/ tracking
        $isAlreadyTracked = Test-AlreadyInstalled -Name $TrackingName -CurrentVersion $chocoVersion
        if ($isAlreadyTracked) {
            Write-Log "$Label is already installed at version $chocoVersion -- skipping (status=installed in .installed/$TrackingName.json)" -Level "success"
            return $true
        }

        Write-Log ($LogMessages.messages.editionAlreadyInstalled -replace '\{label\}', $Label) -Level "info"
        try {
            Upgrade-ChocoPackage -PackageName $ChocoPackageName
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Log ($LogMessages.messages.editionUpgradeSuccess -replace '\{label\}', $Label) -Level "success"

            $newVersion = Get-ChocoPackageVersion -PackageName $ChocoPackageName
            $isVersionEmpty = [string]::IsNullOrWhiteSpace($newVersion)
            if ($isVersionEmpty) { $newVersion = $chocoVersion }  # fall back to pre-upgrade version
            Save-InstalledRecord -Name $TrackingName -Version $newVersion
        } catch {
            Write-Log "VS Code ($Label) upgrade failed: $_" -Level "error"
            Save-InstalledError -Name $TrackingName -ErrorMessage "$_"
        }
        return $true
    }

    Write-Log ($LogMessages.messages.editionNotFound -replace '\{label\}', $Label) -Level "info"
    try {
        $installResult = Install-ChocoPackage -PackageName $ChocoPackageName
        if ($installResult) {
            Write-Log ($LogMessages.messages.editionInstallSuccess -replace '\{label\}', $Label) -Level "success"
            $newVersion = Get-ChocoPackageVersion -PackageName $ChocoPackageName
            $isVersionEmpty = [string]::IsNullOrWhiteSpace($newVersion)
            if ($isVersionEmpty) { $newVersion = "unknown" }
            Save-InstalledRecord -Name $TrackingName -Version $newVersion
        }
        return $installResult
    } catch {
        Write-Log "VS Code ($Label) install failed: $_" -Level "error"
        Save-InstalledError -Name $TrackingName -ErrorMessage "$_"
        return $false
    }
}

function Invoke-VsCodeSetup {
    param(
        $Config,
        $LogMessages,
        [string]$Command
    )

    $editions = $Config.editions
    $isAutoYes = $env:SCRIPTS_AUTO_YES -eq "1"
    $shouldPrompt = [bool]$Config.promptEdition

    # Local helper: forward to Install-VsCodeEdition with the canonical
    # tracking name so .installed/ files are 'vscode.json' / 'vscode-insiders.json'
    # (not 'vscode-vs-code-stable.json').
    function Install-VsCodeEditionByKey([string]$Key) {
        $ed = $editions.$Key
        $tracking = if ($Key -eq "insiders") { "vscode-insiders" } else { "vscode" }
        Install-VsCodeEdition -ChocoPackageName $ed.chocoPackageName `
                              -Label $ed.label `
                              -TrackingName $tracking `
                              -LogMessages $LogMessages
    }

    switch ($Command) {
        "stable" {
            Install-VsCodeEditionByKey "stable"
        }
        "insiders" {
            Install-VsCodeEditionByKey "insiders"
        }
        "all" {
            # Check env var from orchestrator questionnaire first
            $hasEditionsEnv = -not [string]::IsNullOrWhiteSpace($env:VSCODE_EDITIONS)

            if ($hasEditionsEnv) {
                $editionsEnv = $env:VSCODE_EDITIONS
                Write-Log "Using VS Code editions from questionnaire: $editionsEnv" -Level "info"

                $isStable   = $editionsEnv -match "stable"
                $isInsiders = $editionsEnv -match "insiders"

                if ($isStable)   { Install-VsCodeEditionByKey "stable" }
                if ($isInsiders) { Install-VsCodeEditionByKey "insiders" }
            }
            elseif ($shouldPrompt -and -not $isAutoYes) {
                Write-Host ""
                Write-Host $LogMessages.messages.editionPrompt -ForegroundColor Cyan
                Write-Host $LogMessages.messages.editionOptionStable
                Write-Host $LogMessages.messages.editionOptionInsiders
                Write-Host $LogMessages.messages.editionOptionBoth
                Write-Host ""
                $choice = Read-Host $LogMessages.messages.editionPromptInput

                $isDefaultOrStable = [string]::IsNullOrWhiteSpace($choice) -or $choice -eq "1"
                $isInsiders = $choice -eq "2"
                $isBoth = $choice -eq "3"

                if ($isDefaultOrStable) {
                    Install-VsCodeEditionByKey "stable"
                }
                elseif ($isInsiders) {
                    Install-VsCodeEditionByKey "insiders"
                }
                elseif ($isBoth) {
                    Install-VsCodeEditionByKey "stable"
                    Install-VsCodeEditionByKey "insiders"
                }
                else {
                    Install-VsCodeEditionByKey "stable"
                }
            }
            else {
                # No prompt: install what's enabled in config
                if ($editions.stable.enabled)   { Install-VsCodeEditionByKey "stable" }
                if ($editions.insiders.enabled) { Install-VsCodeEditionByKey "insiders" }
            }
        }
    }
}
}

function Uninstall-VsCode {
    <#
    .SYNOPSIS
        Full VS Code uninstall: choco uninstall both editions, purge tracking.
    #>
    param(
        $Config,
        $LogMessages
    )

    # 1. Uninstall Stable edition
    $stablePackage = $Config.editions.stable.chocoPackageName
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "VS Code Stable") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $stablePackage
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "VS Code Stable") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "VS Code Stable") -Level "warn"
    }

    # 2. Uninstall Insiders edition
    $insidersPackage = $Config.editions.insiders.chocoPackageName
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "VS Code Insiders") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $insidersPackage
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "VS Code Insiders") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "VS Code Insiders") -Level "warn"
    }

    # 3. Remove tracking records
    Remove-InstalledRecord -Name "vscode"
    Remove-InstalledRecord -Name "vscode-insiders"
    Remove-ResolvedData -ScriptFolder "01-install-vscode"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
