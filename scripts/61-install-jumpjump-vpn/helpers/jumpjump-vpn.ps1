# --------------------------------------------------------------------------
#  Helper: Install / Uninstall JumpJump VPN
#  Primary mechanism: official direct-download installer.
#  Optional: Chocolatey attempt if config.chocoPackage is non-empty.
#  Mirrors helpers/protonvpn.ps1 (registry + shortcut sweep, AppData opt-in
#  purge, .installed/ tracking via shared installed.ps1).
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
$_downloadRetryPath = Join-Path $_sharedDir "download-retry.ps1"
if ((Test-Path $_downloadRetryPath) -and -not (Get-Command Invoke-DownloadWithRetry -ErrorAction SilentlyContinue)) {
    . $_downloadRetryPath
}

function Expand-JjPath {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return [Environment]::ExpandEnvironmentVariables($Raw) } catch { return $Raw }
}

function Get-JumpJumpDownloadDirs {
    param($DirectConfig)

    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $dirs = New-Object System.Collections.Generic.List[string]

    if ($DirectConfig -and -not [string]::IsNullOrWhiteSpace([string]$DirectConfig.downloadDir)) {
        $configuredDir = Expand-JjPath -Raw $DirectConfig.downloadDir
        if (-not [string]::IsNullOrWhiteSpace($configuredDir)) { [void]$dirs.Add($configuredDir) }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        [void]$dirs.Add((Join-Path $env:TEMP "jumpjump-vpn"))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        [void]$dirs.Add((Join-Path $env:LOCALAPPDATA "scripts-fixer\jumpjump-vpn"))
    }
    if (-not [string]::IsNullOrWhiteSpace($repoRoot)) {
        [void]$dirs.Add((Join-Path $repoRoot ".tmp\jumpjump-vpn"))
    }

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $dirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $normalized = $dir.TrimEnd('\\')
        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            [void]$unique.Add($normalized)
        }
    }

    return $unique.ToArray()
}

function Test-JumpJumpExecutablePayload {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [ref]$FailureReason
    )

    $FailureReason.Value = $null

    if (-not (Test-Path -LiteralPath $Path)) {
        $FailureReason.Value = "installer file not found after download"
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -le 0) {
            $FailureReason.Value = "downloaded installer is empty (0 bytes)"
            return $false
        }

        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $header = New-Object byte[] 2
            $bytesRead = $stream.Read($header, 0, 2)
        } finally {
            $stream.Dispose()
        }

        if ($bytesRead -lt 2) {
            $FailureReason.Value = "downloaded installer is smaller than a valid executable header"
            return $false
        }

        $isMzHeader = ($header[0] -eq 0x4D) -and ($header[1] -eq 0x5A)
        if (-not $isMzHeader) {
            $FailureReason.Value = "downloaded file is not a Windows executable (missing MZ header) -- URL may have returned HTML or an error page"
            return $false
        }

        return $true
    } catch {
        $FailureReason.Value = "could not inspect downloaded installer: $($_.Exception.Message)"
        return $false
    }
}

function Get-JumpJumpVpnPath {
    param([Parameter(Mandatory)] $JjConfig)

    $exeNames = @($JjConfig.executableNames)
    if (-not $exeNames -or $exeNames.Count -eq 0) {
        $exeNames = @('JumpJumpVPN.exe', 'JumpJump VPN.exe', 'jumpjump-vpn.exe', 'JumpJump.exe')
    }

    $dirs = @()
    if ($JjConfig.PSObject.Properties['installDirs'] -and $JjConfig.installDirs) {
        foreach ($d in $JjConfig.installDirs) {
            $expanded = Expand-JjPath -Raw $d
            if ($expanded) { $dirs += $expanded }
        }
    }

    foreach ($d in $dirs) {
        foreach ($n in $exeNames) {
            $p = Join-Path $d $n
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }

    # Registry uninstall lookup
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
                $dn -and ($dn -match 'JumpJump')
            }
            foreach ($k in $keys) {
                $loc = $k.GetValue('InstallLocation')
                if ($loc -and (Test-Path $loc)) {
                    foreach ($n in $exeNames) {
                        $p = Join-Path $loc $n
                        if (Test-Path -LiteralPath $p) { return $p }
                    }
                    $found = Get-ChildItem -LiteralPath $loc -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match 'JumpJump' } |
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
    return $null
}

function Invoke-JumpJumpDirectInstall {
    <#
    .SYNOPSIS
        Downloads the official JumpJump VPN installer and runs it silently.
    #>
    param(
        [Parameter(Mandatory)] $JjConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    $direct = $JjConfig.directInstall

    if (-not $direct -or -not $direct.enabled) {
        Write-Log $msgs.directDisabled -Level "error"
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$direct.url)) {
        Write-FileError -FilePath "config.json" -Operation "direct install" -Reason "directInstall.url is empty -- set the latest JumpJump VPN setup .exe URL" -Module "Install-JumpJumpVpn"
        return $false
    }

    $fileName = if ([string]::IsNullOrWhiteSpace([string]$direct.fileName)) { "jumpjump-vpn-setup.exe" } else { $direct.fileName }
    $silentArgs = if ([string]::IsNullOrWhiteSpace([string]$direct.silentArgs)) { "/S" } else { $direct.silentArgs }

    $attemptDirs = Get-JumpJumpDownloadDirs -DirectConfig $direct
    foreach ($downloadDir in $attemptDirs) {
        try {
            if (-not (Test-Path -LiteralPath $downloadDir)) {
                New-Item -ItemType Directory -Force -Path $downloadDir -ErrorAction Stop | Out-Null
            }
        } catch {
            Write-FileError -FilePath $downloadDir -Operation "prepare download dir" -Reason "Could not create or access download directory: $($_.Exception.Message)" -Module "Install-JumpJumpVpn"
            continue
        }

        $dest = Join-Path $downloadDir $fileName

        if (Test-Path -LiteralPath $dest) {
            try {
                Remove-Item -LiteralPath $dest -Force -ErrorAction Stop
            } catch {
                Write-FileError -FilePath $dest -Operation "cleanup stale installer" -Reason "Could not remove previous installer before re-download: $($_.Exception.Message)" -Module "Install-JumpJumpVpn"
                continue
            }
        }

        Write-Log ((($msgs.directDownloading -replace '\{url\}', $direct.url) + " -- target: ") + $dest) -Level "info"

        $isDownloadOk = $false
        if (Get-Command Invoke-DownloadWithRetry -ErrorAction SilentlyContinue) {
            $isDownloadOk = Invoke-DownloadWithRetry -Uri $direct.url -OutFile $dest -Label $fileName
        } else {
            try {
                $oldProgress = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $direct.url -OutFile $dest -UseBasicParsing -ErrorAction Stop
                $ProgressPreference = $oldProgress
                $isDownloadOk = $true
            } catch {
                $ProgressPreference = $oldProgress
                Write-FileError -FilePath $dest -Operation "download" -Reason "Invoke-WebRequest failed: $($_.Exception.Message) -- check directInstall.url in config.json (vendor rotates filenames)" -Module "Install-JumpJumpVpn"
                $isDownloadOk = $false
            }
        }

        if (-not $isDownloadOk) {
            Write-FileError -FilePath $dest -Operation "download" -Reason "direct installer download failed for this location" -Module "Install-JumpJumpVpn"
            continue
        }

        $validationReason = $null
        $isPayloadValid = Test-JumpJumpExecutablePayload -Path $dest -FailureReason ([ref]$validationReason)
        if (-not $isPayloadValid) {
            Write-FileError -FilePath $dest -Operation "download validation" -Reason $validationReason -Module "Install-JumpJumpVpn"
            try { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue } catch { }
            continue
        }

        Write-Log (($msgs.directRunning -replace '\{path\}', $dest) -replace '\{args\}', $silentArgs) -Level "info"
        try {
            $proc = Start-Process -FilePath $dest -ArgumentList $silentArgs -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -ne 0) {
                Write-Log "Installer exited with code $($proc.ExitCode) -- continuing to verify" -Level "warn"
            }
            return $true
        } catch {
            Write-FileError -FilePath $dest -Operation "silent install" -Reason "Start-Process failed: $($_.Exception.Message)" -Module "Install-JumpJumpVpn"
            Write-Log "Retrying JumpJump VPN installer from a different download location..." -Level "warn"
        }
    }

    Write-Log "JumpJump VPN direct installer failed across all download locations." -Level "error"
    return $false
}

function Install-JumpJumpVpn {
    <#
    .SYNOPSIS
        Installs JumpJump VPN. Tries Chocolatey first if chocoPackage is set,
        otherwise (and on choco failure) runs the official direct-download
        installer. Records state in .installed/jumpjump-vpn.json.
    #>
    param(
        [Parameter(Mandatory)] $JjConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages

    $isDisabled = -not $JjConfig.enabled
    if ($isDisabled) {
        Write-Log "JumpJump VPN install disabled in config -- skipping" -Level "info"
        return $true
    }

    Write-Log $msgs.checking -Level "info"

    $existing = Get-JumpJumpVpnPath -JjConfig $JjConfig
    if ($existing) {
        $version = "unknown"
        try { $version = (Get-Item $existing).VersionInfo.ProductVersion } catch { }
        $isAlreadyInstalled = Test-AlreadyInstalled -Name "jumpjump-vpn" -CurrentVersion $version
        if ($isAlreadyInstalled) {
            Write-Log ($msgs.alreadyInstalled -replace '\{path\}', $existing) -Level "success"
            return $true
        }
        Write-Log "JumpJump VPN found at $existing but no tracking record -- recording" -Level "info"
        Save-InstalledRecord -Name "jumpjump-vpn" -Version $version -Method "manual"
        return $true
    }

    Write-Log $msgs.notFound -Level "info"

    # 1) Optional Chocolatey attempt
    $chocoPkg = [string]$JjConfig.chocoPackage
    $hasChoco = -not [string]::IsNullOrWhiteSpace($chocoPkg)
    $chocoInstallMethod = $null
    if ($hasChoco) {
        Write-Log ($msgs.chocoAttempt -replace '\{pkg\}', $chocoPkg) -Level "info"
        $isChocoOk = Install-ChocoPackage -PackageName $chocoPkg
        if ($isChocoOk) {
            $chocoInstallMethod = "chocolatey"
            $found = Get-JumpJumpVpnPath -JjConfig $JjConfig
            if ($found) {
                $version = "unknown"
                try { $version = (Get-Item $found).VersionInfo.ProductVersion } catch { }
                Write-Log ($msgs.installSuccess -replace '\{path\}', $found) -Level "success"
                Save-InstalledRecord -Name "jumpjump-vpn" -Version $version -Method $chocoInstallMethod
                return $true
            }
            Write-Log "Choco reports success but JumpJumpVPN.exe not located -- falling through to direct download" -Level "warn"
        } else {
            Write-Log $msgs.chocoFailedFallback -Level "warn"
        }
    } else {
        Write-Log $msgs.chocoSkipped -Level "info"
    }

    # 2) Direct download installer
    $isDirectOk = Invoke-JumpJumpDirectInstall -JjConfig $JjConfig -LogMessages $LogMessages
    if (-not $isDirectOk) {
        Save-InstalledError -Name "jumpjump-vpn" -ErrorMessage "Direct-download installer failed -- see error logs"
        return $false
    }

    $installedPath = Get-JumpJumpVpnPath -JjConfig $JjConfig
    if (-not $installedPath) {
        Write-FileError -FilePath "JumpJumpVPN.exe" -Operation "verify" -Reason "JumpJumpVPN.exe not found after direct-download installer ran -- vendor may have changed install path or executable name. Update jumpjumpVpn.installDirs / executableNames in config.json." -Module "Install-JumpJumpVpn"
        Write-Log $msgs.verifyFailed -Level "error"
        Save-InstalledError -Name "jumpjump-vpn" -ErrorMessage "Verify failed: JumpJumpVPN.exe not in expected locations after direct install"
        return $false
    }

    $version = "unknown"
    try { $version = (Get-Item $installedPath).VersionInfo.ProductVersion } catch { }

    Write-Log ($msgs.installSuccess -replace '\{path\}', $installedPath) -Level "success"
    Save-InstalledRecord -Name "jumpjump-vpn" -Version $version -Method "direct-installer"
    return $true
}

function Remove-JjRegistryKeys {
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
            Write-FileError -FilePath $key -Operation "registry delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-JumpJumpVpn"
            Write-Log (($msgs.cleanupRegKeyFailed -replace '\{path\}', $key) -replace '\{error\}', $_.Exception.Message) -Level "error"
            $counter.failed++
        }
    }
    return $counter
}

function Remove-JjShortcuts {
    param(
        [Parameter(Mandatory)] [string[]]$Paths,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    $counter = @{ removed = 0; missing = 0; failed = 0 }

    foreach ($raw in $Paths) {
        $p = Expand-JjPath -Raw $raw
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
            Write-FileError -FilePath $p -Operation "shortcut delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-JumpJumpVpn"
            Write-Log (($msgs.cleanupShortcutFailed -replace '\{path\}', $p) -replace '\{error\}', $_.Exception.Message) -Level "error"
            $counter.failed++
        }
    }
    return $counter
}

function Invoke-JjPostUninstallCleanup {
    param(
        [Parameter(Mandatory)] $JjConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages

    $hasCleanupConfig = $null -ne $JjConfig.PSObject.Properties['uninstallCleanup']
    if (-not $hasCleanupConfig) {
        Write-Log "uninstallCleanup block missing from config -- skipping sweep" -Level "warn"
        return
    }
    $cleanup = $JjConfig.uninstallCleanup
    if (-not $cleanup.enabled) {
        Write-Log $msgs.cleanupSkipped -Level "info"
        return
    }

    Write-Log $msgs.cleanupStart -Level "info"

    $regCounter = @{ removed = 0; missing = 0; failed = 0 }
    if ($cleanup.removeRegistryKeys) {
        $regCounter = Remove-JjRegistryKeys -Keys $cleanup.registryKeys -LogMessages $LogMessages
    }

    $scCounter = @{ removed = 0; missing = 0; failed = 0 }
    if ($cleanup.removeShortcuts) {
        $scCounter = Remove-JjShortcuts -Paths $cleanup.shortcutPaths -LogMessages $LogMessages
    }

    $hasAppDataList = $null -ne $cleanup.PSObject.Properties['appDataPaths'] -and $cleanup.appDataPaths
    if ($hasAppDataList) {
        $isPurge = $cleanup.purgeAppData
        foreach ($raw in $cleanup.appDataPaths) {
            $p = Expand-JjPath -Raw $raw
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
                Write-FileError -FilePath $p -Operation "appdata delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-JumpJumpVpn"
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

function Uninstall-JumpJumpVpn {
    param($JjConfig, $LogMessages)

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "JumpJump VPN") -Level "info"

    # Try choco first if a package name is configured
    $chocoPkg = [string]$JjConfig.chocoPackage
    $chocoTried = $false
    if (-not [string]::IsNullOrWhiteSpace($chocoPkg)) {
        $chocoTried = $true
        $isUninstalled = Uninstall-ChocoPackage -PackageName $chocoPkg
        if ($isUninstalled) {
            Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "JumpJump VPN (choco)") -Level "success"
        } else {
            Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "JumpJump VPN (choco)") -Level "warn"
        }
    }

    # Look up the installer's recorded uninstall string from the registry as a fallback
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
                $dn -and ($dn -match 'JumpJump')
            }
            foreach ($k in $keys) {
                $u = $k.GetValue('QuietUninstallString')
                if ([string]::IsNullOrWhiteSpace($u)) { $u = $k.GetValue('UninstallString') }
                if ([string]::IsNullOrWhiteSpace($u)) { continue }
                Write-Log "Running registry uninstall string: $u" -Level "info"
                try {
                    Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $u, "/S" -Wait -WindowStyle Hidden -ErrorAction Stop
                } catch {
                    Write-FileError -FilePath ($k.PSPath) -Operation "registry uninstall" -Reason "Start-Process failed: $($_.Exception.Message)" -Module "Uninstall-JumpJumpVpn"
                }
            }
        } catch { }
    }

    Invoke-JjPostUninstallCleanup -JjConfig $JjConfig -LogMessages $LogMessages

    Remove-InstalledRecord -Name "jumpjump-vpn"
    Remove-ResolvedData -ScriptFolder "61-install-jumpjump-vpn"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
