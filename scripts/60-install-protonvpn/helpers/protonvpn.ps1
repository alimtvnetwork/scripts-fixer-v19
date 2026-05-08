# --------------------------------------------------------------------------
#  Helper: Install / Uninstall Proton VPN via Chocolatey
#  Mirrors the structure of helpers/chrome.ps1 (registry + shortcut sweep,
#  AppData opt-in purge, .installed/ tracking via shared installed.ps1).
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers (idempotent) ------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}
$_chocoUtilsPath = Join-Path $_sharedDir "choco-utils.ps1"
if ((Test-Path $_chocoUtilsPath) -and -not (Get-Command Install-ChocoPackage -ErrorAction SilentlyContinue)) {
    . $_chocoUtilsPath
}
$_installedPath = Join-Path $_sharedDir "installed.ps1"
if ((Test-Path $_installedPath) -and -not (Get-Command Save-InstalledRecord -ErrorAction SilentlyContinue)) {
    . $_installedPath
}
$_resolvedPath = Join-Path $_sharedDir "resolved.ps1"
if ((Test-Path $_resolvedPath) -and -not (Get-Command Remove-ResolvedData -ErrorAction SilentlyContinue)) {
    . $_resolvedPath
}

function Get-ProtonVpnPath {
    <#
    .SYNOPSIS
        Searches for ProtonVPN.exe in common install locations.
        Returns the path string or $null.
    #>
    $candidates = @(
        "$env:ProgramFiles\Proton\VPN\ProtonVPN.exe",
        "${env:ProgramFiles(x86)}\Proton\VPN\ProtonVPN.exe",
        "$env:ProgramFiles\Proton VPN\ProtonVPN.exe",
        "${env:ProgramFiles(x86)}\Proton VPN\ProtonVPN.exe",
        "$env:ProgramFiles\Proton Technologies\ProtonVPN\ProtonVPN.exe",
        "${env:ProgramFiles(x86)}\Proton Technologies\ProtonVPN\ProtonVPN.exe",
        "$env:LOCALAPPDATA\Programs\Proton\VPN\ProtonVPN.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Install-ProtonVpn {
    <#
    .SYNOPSIS
        Installs Proton VPN via Chocolatey. Records state in .installed/protonvpn.json.
    #>
    param(
        [Parameter(Mandatory)] $ProtonConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages

    $isDisabled = -not $ProtonConfig.enabled
    if ($isDisabled) {
        Write-Log "Proton VPN install disabled in config -- skipping" -Level "info"
        return $true
    }

    Write-Log $msgs.checking -Level "info"

    $existing = Get-ProtonVpnPath
    if ($existing) {
        $version = "unknown"
        try { $version = (Get-Item $existing).VersionInfo.ProductVersion } catch { }
        $isAlreadyInstalled = Test-AlreadyInstalled -Name "protonvpn" -CurrentVersion $version
        if ($isAlreadyInstalled) {
            Write-Log ($msgs.alreadyInstalled -replace '\{path\}', $existing) -Level "success"
            return $true
        }
        Write-Log "ProtonVPN.exe found at $existing but no tracking record -- recording" -Level "info"
        Save-InstalledRecord -Name "protonvpn" -Version $version -Method "chocolatey"
        return $true
    }

    Write-Log $msgs.notFound -Level "info"
    Write-Log $msgs.installing -Level "info"

    $hasFallbackConfig = $null -ne $ProtonConfig.PSObject.Properties['fallback']
    $fallback = if ($hasFallbackConfig) { $ProtonConfig.fallback } else { $null }
    $isFallbackEnabled = $fallback -and $fallback.enabled -and -not [string]::IsNullOrWhiteSpace([string]$fallback.url)

    $isInstalled = Install-ChocoPackage -PackageName $ProtonConfig.chocoPackage
    if (-not $isInstalled) {
        Write-Log ($msgs.installFailed -replace '\{error\}', "choco install $($ProtonConfig.chocoPackage) returned failure") -Level "warn"
        if (-not $isFallbackEnabled) {
            Write-Log $msgs.fallbackDisabled -Level "error"
            Save-InstalledError -Name "protonvpn" -ErrorMessage "choco install protonvpn failed and fallback disabled"
            return $false
        }
        # Fallback path -- delegated to the shared download/run pattern when enabled.
        Write-Log "Fallback URL configured: $($fallback.url) -- attempting download" -Level "info"
        $dest = Join-Path $env:TEMP $fallback.fileName
        try {
            Invoke-WebRequest -Uri $fallback.url -OutFile $dest -UseBasicParsing -ErrorAction Stop
            Start-Process -FilePath $dest -ArgumentList $fallback.silentArgs -Wait -WindowStyle Hidden -ErrorAction Stop
        } catch {
            Write-FileError -FilePath $dest -Operation "fallback install" -Reason "fallback installer failed: $($_.Exception.Message)" -Module "Install-ProtonVpn"
            Save-InstalledError -Name "protonvpn" -ErrorMessage "choco failed; fallback failed: $($_.Exception.Message)"
            return $false
        }
        $found = Get-ProtonVpnPath
        if (-not $found) {
            Save-InstalledError -Name "protonvpn" -ErrorMessage "fallback ran but ProtonVPN.exe not found"
            return $false
        }
        $version = "unknown"
        try { $version = (Get-Item $found).VersionInfo.ProductVersion } catch { }
        Save-InstalledRecord -Name "protonvpn" -Version $version -Method "official-installer"
        return $true
    }

    $installedPath = Get-ProtonVpnPath
    if (-not $installedPath) {
        Write-FileError -FilePath "ProtonVPN.exe" -Operation "verify" -Reason "ProtonVPN.exe not found after choco install -- checked common Proton install dirs under Program Files and LocalAppData" -Module "Install-ProtonVpn"
        Write-Log $msgs.verifyFailed -Level "warn"
        Save-InstalledError -Name "protonvpn" -ErrorMessage "Verify failed: ProtonVPN.exe not in expected locations after install"
        return $false
    }

    $version = "unknown"
    try { $version = (Get-Item $installedPath).VersionInfo.ProductVersion } catch { }

    Write-Log ($msgs.installSuccess -replace '\{path\}', $installedPath) -Level "success"
    Save-InstalledRecord -Name "protonvpn" -Version $version -Method "chocolatey"
    return $true
}

function Expand-ProtonPath {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return [Environment]::ExpandEnvironmentVariables($Raw) } catch { return $Raw }
}

function Remove-ProtonRegistryKeys {
    param(
        [Parameter(Mandatory)] [string[]]$Keys,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    $counter = @{ removed = 0; missing = 0; failed = 0 }

    foreach ($key in $Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $hasKey = Test-Path -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $hasKey) {
            Write-Log ($msgs.cleanupRegKeyMissing -replace '\{path\}', $key) -Level "info"
            $counter.missing++
            continue
        }
        try {
            Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
            Write-Log ($msgs.cleanupRegKeyRemoved -replace '\{path\}', $key) -Level "success"
            $counter.removed++
        } catch {
            Write-FileError -FilePath $key -Operation "registry delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-ProtonVpn"
            Write-Log (($msgs.cleanupRegKeyFailed -replace '\{path\}', $key) -replace '\{error\}', $_.Exception.Message) -Level "error"
            $counter.failed++
        }
    }
    return $counter
}

function Remove-ProtonShortcuts {
    param(
        [Parameter(Mandatory)] [string[]]$Paths,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    $counter = @{ removed = 0; missing = 0; failed = 0 }

    foreach ($raw in $Paths) {
        $p = Expand-ProtonPath -Raw $raw
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $hasPath = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $hasPath) {
            Write-Log ($msgs.cleanupShortcutMissing -replace '\{path\}', $p) -Level "info"
            $counter.missing++
            continue
        }
        try {
            $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
            if ($item.PSIsContainer) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            }
            Write-Log ($msgs.cleanupShortcutRemoved -replace '\{path\}', $p) -Level "success"
            $counter.removed++
        } catch {
            Write-FileError -FilePath $p -Operation "shortcut delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-ProtonVpn"
            Write-Log (($msgs.cleanupShortcutFailed -replace '\{path\}', $p) -replace '\{error\}', $_.Exception.Message) -Level "error"
            $counter.failed++
        }
    }
    return $counter
}

function Invoke-ProtonPostUninstallCleanup {
    param(
        [Parameter(Mandatory)] $ProtonConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages

    $hasCleanupConfig = $null -ne $ProtonConfig.PSObject.Properties['uninstallCleanup']
    if (-not $hasCleanupConfig) {
        Write-Log "uninstallCleanup block missing from config -- skipping sweep" -Level "warn"
        return
    }
    $cleanup = $ProtonConfig.uninstallCleanup

    if (-not $cleanup.enabled) {
        Write-Log $msgs.cleanupSkipped -Level "info"
        return
    }

    Write-Log $msgs.cleanupStart -Level "info"

    $regCounter = @{ removed = 0; missing = 0; failed = 0 }
    if ($cleanup.removeRegistryKeys) {
        $regCounter = Remove-ProtonRegistryKeys -Keys $cleanup.registryKeys -LogMessages $LogMessages
    }

    $scCounter = @{ removed = 0; missing = 0; failed = 0 }
    if ($cleanup.removeShortcuts) {
        $scCounter = Remove-ProtonShortcuts -Paths $cleanup.shortcutPaths -LogMessages $LogMessages
    }

    $hasAppDataList = $null -ne $cleanup.PSObject.Properties['appDataPaths'] -and $cleanup.appDataPaths
    if ($hasAppDataList) {
        $isPurge = $cleanup.purgeAppData
        foreach ($raw in $cleanup.appDataPaths) {
            $p = Expand-ProtonPath -Raw $raw
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $hasFolder = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue
            if (-not $hasFolder) { continue }
            if (-not $isPurge) {
                Write-Log ($msgs.cleanupAppDataKept -replace '\{path\}', $p) -Level "info"
                continue
            }
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                Write-Log ($msgs.cleanupAppDataPurged -replace '\{path\}', $p) -Level "success"
            } catch {
                Write-FileError -FilePath $p -Operation "appdata delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-ProtonVpn"
            }
        }
    }

    $summary = $msgs.cleanupSummary
    $summary = $summary -replace '\{regRemoved\}', $regCounter.removed
    $summary = $summary -replace '\{regMissing\}', $regCounter.missing
    $summary = $summary -replace '\{regFailed\}', $regCounter.failed
    $summary = $summary -replace '\{scRemoved\}', $scCounter.removed
    $summary = $summary -replace '\{scMissing\}', $scCounter.missing
    $summary = $summary -replace '\{scFailed\}', $scCounter.failed
    $hasAnyFailure = ($regCounter.failed + $scCounter.failed) -gt 0
    Write-Log $summary -Level $(if ($hasAnyFailure) { "warn" } else { "success" })
}

function Uninstall-ProtonVpn {
    param($ProtonConfig, $LogMessages)

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "Proton VPN") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $ProtonConfig.chocoPackage
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "Proton VPN") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "Proton VPN") -Level "warn"
    }

    Invoke-ProtonPostUninstallCleanup -ProtonConfig $ProtonConfig -LogMessages $LogMessages

    Remove-InstalledRecord -Name "protonvpn"
    Remove-ResolvedData -ScriptFolder "60-install-protonvpn"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
