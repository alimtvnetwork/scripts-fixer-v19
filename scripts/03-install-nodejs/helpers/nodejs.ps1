# --------------------------------------------------------------------------
#  Node.js helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}
$_npmUtilsPath = Join-Path $_sharedDir "npm-utils.ps1"
if ((Test-Path $_npmUtilsPath) -and -not (Get-Command Invoke-NpmGlobalInstall -ErrorAction SilentlyContinue)) {
    . $_npmUtilsPath
}
$_devDirPath = Join-Path $_sharedDir "dev-dir.ps1"
if ((Test-Path $_devDirPath) -and -not (Get-Command Resolve-SmartDevDir -ErrorAction SilentlyContinue)) {
    . $_devDirPath
}


function Install-NodeJs {
    param(
        $Config,
        $LogMessages
    )

    $packageName = $Config.chocoPackageName

    # Check if Node.js is already installed
    $existing = Get-Command node -ErrorAction SilentlyContinue
    if ($existing) {
        $currentVersion = try { & node --version 2>$null } catch { $null }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($currentVersion)

        # Check .installed/ tracking -- skip if version matches
        if ($hasVersion) {
            $isAlreadyTracked = Test-AlreadyInstalled -Name "nodejs" -CurrentVersion $currentVersion
            if ($isAlreadyTracked) {
                Write-Log ($LogMessages.messages.nodeAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"
                return
            }
        }

        Write-Log ($LogMessages.messages.nodeAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"

        if ($Config.alwaysUpgradeToLatest) {
            try {
                Upgrade-ChocoPackage -PackageName $packageName
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                $newVersion = try { & node --version 2>$null } catch { $null }
                $isVersionEmpty = [string]::IsNullOrWhiteSpace($newVersion)
                if ($isVersionEmpty) { $newVersion = "(version pending)" }
                Write-Log ($LogMessages.messages.nodeUpgradeSuccess -replace '\{version\}', $newVersion) -Level "success"
                Save-InstalledRecord -Name "nodejs" -Version "$newVersion".Trim()
            } catch {
                Write-Log "Node.js upgrade failed: $_" -Level "error"
                Save-InstalledError -Name "nodejs" -ErrorMessage "$_"
            }
        }
    }
    else {
        Write-Log $LogMessages.messages.nodeNotFound -Level "info"
        try {
            Install-ChocoPackage -PackageName $packageName
            
            # Refresh PATH so node is discoverable
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            
            $installedVersion = & node --version 2>$null
            Write-Log ($LogMessages.messages.nodeInstallSuccess -replace '\{version\}', $installedVersion) -Level "success"
            Save-InstalledRecord -Name "nodejs" -Version $installedVersion
        } catch {
            Write-Log "Node.js install failed: $_" -Level "error"
            Save-InstalledError -Name "nodejs" -ErrorMessage "$_"
        }
    }
}

function Test-NpmPrefixWritable {
    <#
    .SYNOPSIS
        Verifies that the requested npm global prefix path:
          1) lives on a drive that exists,
          2) can be created (or already exists), and
          3) accepts a probe file write (catches AV/file-system filter
             blocks that otherwise surface as 'errno -4094 UNKNOWN' from
             npm's bundled libuv mkdir).

        Returns a hashtable: Ok (bool), Reason (string), ProbeFile (string).

        SEVERITY:
          By default a probe failure is logged as CODE RED Write-FileError
          (the user explicitly asked for that path). Pass -Speculative when
          probing a *candidate* prefix during auto-resolution -- a missing
          drive then logs as 'info' (expected fallback signal), not as a
          fail. This mirrors Test-DriveQualified -Speculative in dev-dir.ps1.
    #>
    param(
        [Parameter(Mandatory)] [string]$PrefixPath,
        [switch]$Speculative
    )

    $result = @{ Ok = $false; Reason = $null; ProbeFile = $null }

    # Drive existence check
    try {
        $driveQualifier = [System.IO.Path]::GetPathRoot($PrefixPath)
        $hasDrive = -not [string]::IsNullOrWhiteSpace($driveQualifier)
        if ($hasDrive -and -not (Test-Path -LiteralPath $driveQualifier)) {
            $result.Reason = "Drive '$driveQualifier' does not exist or is not mounted in this session."
            if ($Speculative) {
                Write-Log "Speculative npm prefix '$PrefixPath' skipped: $($result.Reason)" -Level "info"
            } else {
                Write-FileError -FilePath $PrefixPath -Operation "probe-prefix-drive" -Reason $result.Reason -Module "Test-NpmPrefixWritable"
            }
            return $result
        }
    } catch {
        $result.Reason = "Could not parse drive root: $_"
        if ($Speculative) {
            Write-Log "Speculative npm prefix '$PrefixPath' skipped: $($result.Reason)" -Level "info"
        } else {
            Write-FileError -FilePath $PrefixPath -Operation "probe-prefix-drive" -Reason $result.Reason -Module "Test-NpmPrefixWritable"
        }
        return $result
    }

    # Create directory (idempotent)
    if (-not (Test-Path -LiteralPath $PrefixPath)) {
        try {
            New-Item -Path $PrefixPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            $result.Reason = "Cannot create directory: $_"
            if ($Speculative) {
                Write-Log "Speculative npm prefix '$PrefixPath' skipped: $($result.Reason)" -Level "info"
            } else {
                Write-FileError -FilePath $PrefixPath -Operation "create-prefix-dir" -Reason $result.Reason -Module "Test-NpmPrefixWritable"
            }
            return $result
        }
    }

    # Write probe -- catches AV / filter / permission blocks that npm hits as errno -4094
    $probe = Join-Path $PrefixPath (".scripts-fixer-probe-{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
    try {
        Set-Content -LiteralPath $probe -Value "probe" -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $result.Ok = $true
        $result.ProbeFile = $probe
        return $result
    } catch {
        $result.Reason = "Directory exists but is not writable (probe failed: $_). This usually means antivirus, a file-system filter, or a different identity owns the folder."
        if ($Speculative) {
            Write-Log "Speculative npm prefix '$PrefixPath' skipped: $($result.Reason)" -Level "info"
        } else {
            Write-FileError -FilePath $probe -Operation "probe-prefix-write" -Reason $result.Reason -Module "Test-NpmPrefixWritable"
        }
        return $result
    }
}

function Get-NpmDefaultPrefix {
    <#
    .SYNOPSIS
        npm's documented Windows default global prefix when no override is set:
        %APPDATA%\npm. Used as a fallback when the configured prefix is not
        usable so global installs (yarn, pnpm) can still succeed.
    #>
    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path $env:USERPROFILE "AppData\Roaming"
    }
    return (Join-Path $appData "npm")
}

function Configure-NpmPrefix {
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $npmConfig = $Config.npm
    $isSetPrefixDisabled = -not $npmConfig.setGlobalPrefix
    if ($isSetPrefixDisabled) { return }

    # ----------------------------------------------------------------------
    # Resolve the prefix using the same priority the smart dev-dir uses:
    #   1. Caller-provided -DevDir            (explicit override -- CODE RED on fail)
    #   2. Config-pinned npm.globalPrefix     (only if its drive is currently mounted)
    #   3. Resolve-SmartDevDir + subfolder    (auto -- silent fallback if drive gone)
    #   4. npm default (%APPDATA%\npm)        (last-resort guaranteed-writable path)
    # The pinned config value is treated as a *preference*, not a force, so a
    # missing E:\ on a fresh machine no longer triggers a CODE RED file error.
    # ----------------------------------------------------------------------
    $isUserForced = [bool]$DevDir
    $configuredPrefix = $npmConfig.globalPrefix
    $hasConfiguredPrefix = -not [string]::IsNullOrWhiteSpace("$configuredPrefix")

    if ($isUserForced) {
        $requestedPrefix = Join-Path $DevDir $Config.devDirSubfolder
        $probe = Test-NpmPrefixWritable -PrefixPath $requestedPrefix   # CODE RED on fail (user forced it)
    }
    else {
        $requestedPrefix = $null
        $probe = @{ Ok = $false; Reason = "no candidate yet" }

        # Try the pinned config prefix only if its drive is currently mounted.
        if ($hasConfiguredPrefix) {
            $cfgRoot = try { [System.IO.Path]::GetPathRoot($configuredPrefix) } catch { $null }
            $cfgDriveReady = -not [string]::IsNullOrWhiteSpace($cfgRoot) -and (Test-Path -LiteralPath $cfgRoot)
            if ($cfgDriveReady) {
                $requestedPrefix = $configuredPrefix
                $probe = Test-NpmPrefixWritable -PrefixPath $requestedPrefix -Speculative
            } else {
                Write-Log "Configured npm prefix '$configuredPrefix' lives on '$cfgRoot' which is not mounted -- using smart auto-resolve instead." -Level "info"
            }
        }

        # Smart dev-dir auto-resolution
        if (-not $probe.Ok) {
            $smartDir = $null
            try {
                if (Get-Command Resolve-SmartDevDir -ErrorAction SilentlyContinue) {
                    $smartDir = Resolve-SmartDevDir
                }
            } catch {
                Write-Log "Resolve-SmartDevDir threw: $_ -- continuing to npm default fallback." -Level "info"
            }
            if ($smartDir) {
                $requestedPrefix = Join-Path $smartDir $Config.devDirSubfolder
                $probe = Test-NpmPrefixWritable -PrefixPath $requestedPrefix -Speculative
            }
        }
    }

    if ($probe.Ok) {
        $prefixPath = $requestedPrefix
    } else {
        $fallback = Get-NpmDefaultPrefix
        $reasonText = if ($probe.Reason) { $probe.Reason } else { "no usable candidate found" }
        Write-Log "Auto-selecting npm default prefix '$fallback' (reason: $reasonText)." -Level "info"
        $probe2 = Test-NpmPrefixWritable -PrefixPath $fallback
        if (-not $probe2.Ok) {
            Write-FileError -FilePath $fallback -Operation "fallback-prefix" `
                -Reason "npm default fallback prefix is unwritable. $($probe2.Reason)" `
                -Module "Configure-NpmPrefix"
            return $null
        }
        $prefixPath = $fallback
    }

    # Check current prefix
    $currentPrefix = & npm config get prefix 2>$null
    if ($currentPrefix -eq $prefixPath) {
        Write-Log ($LogMessages.messages.npmPrefixAlreadySet -replace '\{path\}', $prefixPath) -Level "info"
    }
    else {
        Write-Log ($LogMessages.messages.configuringNpmPrefix -replace '\{path\}', $prefixPath) -Level "info"
        & npm config set prefix $prefixPath
        Write-Log ($LogMessages.messages.npmPrefixSet -replace '\{path\}', $prefixPath) -Level "success"
    }

    return $prefixPath
}

function Update-NodePath {
    param(
        $Config,
        $LogMessages,
        [string]$PrefixPath
    )

    $isPathUpdateDisabled = -not $Config.path.updateUserPath
    if ($isPathUpdateDisabled) { return }

    $hasNoPrefixPath = -not $PrefixPath
    if ($hasNoPrefixPath) { return }

    # npm installs global bins directly into the prefix on Windows
    $isAlreadyInPath = Test-InPath -Directory $PrefixPath
    if ($isAlreadyInPath) {
        Write-Log ($LogMessages.messages.pathAlreadyContains -replace '\{path\}', $PrefixPath) -Level "info"
    }
    else {
        Write-Log ($LogMessages.messages.addingToPath -replace '\{path\}', $PrefixPath) -Level "info"
        Add-ToUserPath -Directory $PrefixPath
    }

    # Also ensure node_modules/.bin if needed
    if ($Config.path.ensureNpmBinInPath) {
        $nodeModulesBin = Join-Path $PrefixPath "node_modules\.bin"
        $isNpmBinPresent = Test-Path $nodeModulesBin
        $isNpmBinInPath = Test-InPath -Directory $nodeModulesBin
        if ($isNpmBinPresent -and -not $isNpmBinInPath) {
            Add-ToUserPath -Directory $nodeModulesBin
        }
    }
}

function Install-NodeExtras {
    param(
        $Config,
        $LogMessages
    )

    # Refresh PATH so the new npm prefix is visible in this session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    $extras = $Config.extras

    # -- Yarn (via npm) --------------------------------------------------------
    $isYarnEnabled = $extras.yarn.enabled
    if ($isYarnEnabled) {
        $yarnCmd = Get-Command yarn -ErrorAction SilentlyContinue
        if ($yarnCmd) {
            $yarnVersion = try { & yarn --version 2>$null } catch { $null }
            $hasYarnVersion = -not [string]::IsNullOrWhiteSpace($yarnVersion)

            if ($hasYarnVersion) {
                $isYarnTracked = Test-AlreadyInstalled -Name "yarn" -CurrentVersion $yarnVersion
                if ($isYarnTracked) {
                    Write-Log ($LogMessages.messages.yarnAlreadyInstalled -replace '\{version\}', $yarnVersion) -Level "info"
                }
                else {
                    Write-Log ($LogMessages.messages.yarnAlreadyInstalled -replace '\{version\}', $yarnVersion) -Level "info"
                    Save-InstalledRecord -Name "yarn" -Version $yarnVersion -Method "npm"
                }
            }
        }
        else {
            Write-Log $LogMessages.messages.yarnInstalling -Level "info"
            try {
                # Use the shared helper -- handles npm stderr noise AND auto-falls back
                # from a broken globalPrefix (e.g. errno -4094 / UNKNOWN: mkdir on E:\)
                # to %APPDATA%\npm so the install can still succeed.
                $npmResult = Invoke-NpmGlobalInstall -PackageSpec "yarn"
                if (-not $npmResult.Success) {
                    throw $npmResult.Error
                }
                if ($npmResult.Recovered) {
                    Write-Log "Yarn was installed under fallback npm prefix '$($npmResult.PrefixUsed)'." -Level "warn"
                }

                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                # Make sure the (possibly new) prefix is on PATH so `yarn` resolves now.
                if ($npmResult.PrefixUsed -and -not (Test-InPath -Directory $npmResult.PrefixUsed)) {
                    Add-ToUserPath -Directory $npmResult.PrefixUsed
                    $env:Path = "$env:Path;$($npmResult.PrefixUsed)"
                }
                $yarnVersion = & yarn --version 2>$null
                $hasYarnVersion = -not [string]::IsNullOrWhiteSpace($yarnVersion)
                if (-not $hasYarnVersion) {
                    throw "Yarn binary not found on PATH after npm install -g yarn (npm exit was 0). Check npm prefix: $(& npm config get prefix 2>$null)"
                }
                Write-Log ($LogMessages.messages.yarnInstallSuccess -replace '\{version\}', $yarnVersion) -Level "success"
                Save-InstalledRecord -Name "yarn" -Version $yarnVersion -Method "npm"
            }
            catch {
                Write-Log ($LogMessages.messages.yarnInstallFailed -replace '\{error\}', $_) -Level "error"
                Save-InstalledError -Name "yarn" -ErrorMessage "$_" -Method "npm"
            }
        }
    }

    # -- Bun (via Chocolatey) --------------------------------------------------
    $isBunEnabled = $extras.bun.enabled
    if ($isBunEnabled) {
        $bunCmd = Get-Command bun -ErrorAction SilentlyContinue
        if ($bunCmd) {
            $bunVersion = try { & bun --version 2>$null } catch { $null }
            $hasBunVersion = -not [string]::IsNullOrWhiteSpace($bunVersion)

            if ($hasBunVersion) {
                $isBunTracked = Test-AlreadyInstalled -Name "bun" -CurrentVersion $bunVersion
                if ($isBunTracked) {
                    Write-Log ($LogMessages.messages.bunAlreadyInstalled -replace '\{version\}', $bunVersion) -Level "info"
                }
                else {
                    Write-Log ($LogMessages.messages.bunAlreadyInstalled -replace '\{version\}', $bunVersion) -Level "info"
                    Save-InstalledRecord -Name "bun" -Version $bunVersion
                }
            }
        }
        else {
            Write-Log $LogMessages.messages.bunInstalling -Level "info"
            Install-ChocoPackage -PackageName $extras.bun.chocoPackageName
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            $bunVersion = & bun --version 2>$null
            Write-Log ($LogMessages.messages.bunInstallSuccess -replace '\{version\}', $bunVersion) -Level "success"
            Save-InstalledRecord -Name "bun" -Version $bunVersion
        }
    }

    # -- npx (verify) ----------------------------------------------------------
    $isNpxVerify = $extras.npx.verify
    if ($isNpxVerify) {
        Write-Log $LogMessages.messages.npxVerifying -Level "info"
        $npxCmd = Get-Command npx -ErrorAction SilentlyContinue
        if ($npxCmd) {
            $npxVersion = & npx --version 2>$null
            Write-Log ($LogMessages.messages.npxAvailable -replace '\{version\}', $npxVersion) -Level "success"
        }
        else {
            Write-Log $LogMessages.messages.npxMissing -Level "warn"
        }
    }
}

function Uninstall-NodeJs {
    <#
    .SYNOPSIS
        Full Node.js uninstall: choco uninstall, remove npm prefix env var,
        remove from PATH, clean dev dir subfolder, purge tracking.
    #>
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $packageName = $Config.chocoPackageName

    # 1. Uninstall via Chocolatey
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "Node.js") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $packageName
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "Node.js") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "Node.js") -Level "error"
    }

    # 2. Also uninstall extras (bun)
    $hasBun = $Config.extras.bun.enabled
    if ($hasBun) {
        Uninstall-ChocoPackage -PackageName $Config.extras.bun.chocoPackageName
    }

    # 3. Remove NPM_CONFIG_PREFIX environment variable
    $currentPrefix = [System.Environment]::GetEnvironmentVariable("NPM_CONFIG_PREFIX", "User")
    $hasPrefix = -not [string]::IsNullOrWhiteSpace($currentPrefix)
    if ($hasPrefix) {
        Write-Log "Removing NPM_CONFIG_PREFIX env var: $currentPrefix" -Level "info"
        [System.Environment]::SetEnvironmentVariable("NPM_CONFIG_PREFIX", $null, "User")
        $env:NPM_CONFIG_PREFIX = $null
    }

    # 4. Remove from PATH
    $devDirSub = if ($DevDir) { Join-Path $DevDir $Config.devDirSubfolder } else { $Config.npm.globalPrefix }
    $hasValidPath = -not [string]::IsNullOrWhiteSpace($devDirSub)
    if ($hasValidPath) {
        Remove-FromUserPath -Directory $devDirSub

        # 5. Clean dev directory subfolder
        $isDirPresent = Test-Path $devDirSub
        if ($isDirPresent) {
            Write-Log "Removing dev directory subfolder: $devDirSub" -Level "info"
            Remove-Item -Path $devDirSub -Recurse -Force
            Write-Log "Dev directory subfolder removed: $devDirSub" -Level "success"
        }
    }

    # 6. Remove tracking records
    Remove-InstalledRecord -Name "nodejs"
    Remove-InstalledRecord -Name "yarn"
    Remove-InstalledRecord -Name "bun"
    Remove-ResolvedData -ScriptFolder "03-install-nodejs"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
