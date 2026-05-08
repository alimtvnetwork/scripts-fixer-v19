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
$_confirmPath = Join-Path $_sharedDir "confirm-prompt.ps1"
if ((Test-Path $_confirmPath) -and -not (Get-Command Confirm-DestructiveAction -ErrorAction SilentlyContinue)) {
    . $_confirmPath
}

function Test-IsWindowsServer {
    <#
    .SYNOPSIS
        Returns $true when the current OS is a Windows Server SKU.
        Proton VPN's MSI/choco package refuses to install on Server SKUs
        (the installer hard-fails with "not supported on this OS").
        Detection priority: CIM ProductType (3 = DC, 2 = Server) -> registry
        InstallationType ("Server" / "Server Core") -> caption fallback.
    #>
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os.ProductType -eq 2 -or $os.ProductType -eq 3) { return $true }
        if ($os.Caption -and ($os.Caption -match 'Server')) { return $true }
    } catch { }
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $instType = (Get-ItemProperty -Path $key -Name InstallationType -ErrorAction Stop).InstallationType
        if ($instType -and ($instType -match 'Server')) { return $true }
    } catch { }
    return $false
}

function Get-WindowsServerCaption {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os.Caption) { return [string]$os.Caption }
    } catch { }
    return "Windows Server (caption unavailable)"
}

function Invoke-JumpJumpVpnFallback {
    <#
    .SYNOPSIS
        When Proton refuses to install on Windows Server, offer to install
        JumpJump VPN (script 61) instead. Honors -y / --non-interactive via
        env vars: PROTON_AUTOFALLBACK_JUMPJUMP=1, LOVABLE_ASSUME_YES=1.
    #>
    param([Parameter(Mandatory)] $LogMessages)

    $jjScriptDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "61-install-jumpjump-vpn"
    $jjHelper    = Join-Path $jjScriptDir "helpers\jumpjump-vpn.ps1"
    $jjConfigP   = Join-Path $jjScriptDir "config.json"
    $jjLogP      = Join-Path $jjScriptDir "log-messages.json"

    if (-not (Test-Path $jjHelper) -or -not (Test-Path $jjConfigP)) {
        Write-FileError -FilePath $jjHelper -Operation "fallback dispatch" -Reason "JumpJump VPN script (61) not found at expected path -- cannot offer Windows Server fallback" -Module "Install-ProtonVpn"
        return $false
    }

    $isAutoYes = ($env:PROTON_AUTOFALLBACK_JUMPJUMP -eq '1') -or `
                 ($env:LOVABLE_ASSUME_YES -eq '1') -or `
                 ($env:CI_ASSUME_YES -eq '1')

    $confirmed = $false
    if (Get-Command Confirm-DestructiveAction -ErrorAction SilentlyContinue) {
        $confirmed = Confirm-DestructiveAction `
            -Title  "Install JumpJump VPN instead? (Proton VPN does not support Windows Server)" `
            -Detail "JumpJump VPN ships a Server-friendly installer. Type YES to install it now, anything else to skip." `
            -AssumeYes:$isAutoYes `
            -ConfirmWord 'YES'
    } else {
        if ($isAutoYes) {
            Write-Log "[ AUTO-YES ] PROTON_AUTOFALLBACK_JUMPJUMP=1 -- installing JumpJump VPN" -Level "info"
            $confirmed = $true
        } else {
            Write-Host ""
            Write-Host "  [ PROMPT ] " -ForegroundColor Yellow -NoNewline
            Write-Host "Install JumpJump VPN instead? Type YES: " -NoNewline
            try {
                $ans = [string](Read-Host)
                $confirmed = [string]::Equals($ans.Trim(), 'YES', [System.StringComparison]::OrdinalIgnoreCase)
            } catch { $confirmed = $false }
        }
    }

    if (-not $confirmed) {
        Write-Log "User declined JumpJump VPN fallback -- exiting Proton VPN installer without changes." -Level "warn"
        return $false
    }

    . $jjHelper
    $jjConfig = Import-JsonConfig $jjConfigP
    $jjLog    = Import-JsonConfig $jjLogP
    Write-Log "Delegating to JumpJump VPN installer (script 61)..." -Level "info"
    return [bool](Install-JumpJumpVpn -JjConfig $jjConfig.jumpjumpVpn -LogMessages $jjLog)
}


function Get-ProtonVpnPath {
    <#
    .SYNOPSIS
        Searches for the Proton VPN executable in common install locations,
        the Windows Uninstall registry, and (as a last resort) by recursive
        scan of likely root folders. Returns the path string or $null.
        Proton has shipped the binary under several names across versions:
        ProtonVPN.exe, Proton VPN.exe, ProtonVPN.Launcher.exe.
    #>
    $exeNames = @('ProtonVPN.exe', 'Proton VPN.exe', 'ProtonVPN.Launcher.exe')
    $dirs = @(
        "$env:ProgramFiles\Proton\VPN",
        "${env:ProgramFiles(x86)}\Proton\VPN",
        "$env:ProgramFiles\Proton VPN",
        "${env:ProgramFiles(x86)}\Proton VPN",
        "$env:ProgramFiles\Proton AG\Proton VPN",
        "${env:ProgramFiles(x86)}\Proton AG\Proton VPN",
        "$env:ProgramFiles\Proton Technologies\ProtonVPN",
        "${env:ProgramFiles(x86)}\Proton Technologies\ProtonVPN",
        "$env:LOCALAPPDATA\Programs\Proton\VPN",
        "$env:LOCALAPPDATA\Programs\Proton VPN"
    )
    foreach ($d in $dirs) {
        foreach ($n in $exeNames) {
            $p = Join-Path $d $n
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }

    # Registry uninstall lookup -- Proton writes InstallLocation / DisplayIcon
    $regRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        try {
            $keys = Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object {
                $dn = $_.GetValue('DisplayName')
                $dn -and ($dn -match 'Proton\s*VPN')
            }
            foreach ($k in $keys) {
                $loc = $k.GetValue('InstallLocation')
                if ($loc -and (Test-Path $loc)) {
                    foreach ($n in $exeNames) {
                        $p = Join-Path $loc $n
                        if (Test-Path -LiteralPath $p) { return $p }
                    }
                    $found = Get-ChildItem -LiteralPath $loc -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^Proton.*VPN.*\.exe$' -or $_.Name -eq 'ProtonVPN.exe' } |
                        Select-Object -First 1
                    if ($found) { return $found.FullName }
                }
                $icon = $k.GetValue('DisplayIcon')
                if ($icon) {
                    $iconPath = $icon -replace ',.*$', ''
                    if ((Test-Path -LiteralPath $iconPath) -and ($iconPath -match '\.exe$')) {
                        return $iconPath
                    }
                }
            }
        } catch { }
    }

    # Last-resort recursive scan of likely roots
    $scanRoots = @("$env:ProgramFiles\Proton", "${env:ProgramFiles(x86)}\Proton",
                   "$env:ProgramFiles\Proton AG", "${env:ProgramFiles(x86)}\Proton AG",
                   "$env:LOCALAPPDATA\Programs\Proton") | Where-Object { Test-Path $_ }
    foreach ($r in $scanRoots) {
        $found = Get-ChildItem -LiteralPath $r -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in $exeNames -or $_.Name -match '^Proton.*VPN.*\.exe$' } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
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

    # ---- Windows Server gate -------------------------------------------------
    # Proton VPN's Windows installer (both choco and the official .exe) refuses
    # to run on Server SKUs. Detect early and offer the JumpJump VPN fallback
    # instead of letting the installer hard-fail with a confusing error.
    $isServer = Test-IsWindowsServer
    if ($isServer) {
        $serverCaption = Get-WindowsServerCaption
        Write-Host ""
        Write-Host "  [ SKIP ] " -ForegroundColor Yellow -NoNewline
        Write-Host "Proton VPN does NOT support Windows Server SKUs." -ForegroundColor White
        Write-Host "          Detected OS: $serverCaption" -ForegroundColor Gray
        Write-Host "          Proton's installer will refuse to run -- not even attempting choco install." -ForegroundColor Gray
        Write-Log "Detected Windows Server ('$serverCaption') -- skipping Proton VPN install (not supported by vendor)." -Level "warn"
        Save-InstalledError -Name "protonvpn" -ErrorMessage "Skipped: Proton VPN does not support Windows Server ($serverCaption). Use JumpJump VPN (script 61) instead."

        $jjOk = Invoke-JumpJumpVpnFallback -LogMessages $LogMessages
        if ($jjOk) {
            Write-Log "JumpJump VPN installed as the Server-friendly alternative to Proton VPN." -Level "success"
            return $true
        }
        Write-Log "No VPN was installed. Re-run with: .\\run.ps1 install jumpjump-vpn  (or set PROTON_AUTOFALLBACK_JUMPJUMP=1 to auto-accept the prompt)." -Level "info"
        return $false
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
        # CODE RED: Proton's choco package has historically failed silently on
        # certain Windows builds (exit 0 but nothing actually installed). Keep
        # this as a hard failure so the run is flagged and the user knows to
        # try the official-installer fallback. Do NOT downgrade to a warning.
        Write-FileError -FilePath "ProtonVPN.exe" -Operation "verify" -Reason "ProtonVPN.exe not found after choco install -- checked common Proton install dirs under Program Files and LocalAppData, registry uninstall keys, and recursive Proton folders. Choco may have reported success but the package did not actually install on this Windows build." -Module "Install-ProtonVpn"
        Write-Log $msgs.verifyFailed -Level "error"
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
