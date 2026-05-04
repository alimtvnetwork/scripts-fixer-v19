# --------------------------------------------------------------------------
#  pnpm helper functions
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


function Install-Pnpm {
    param(
        $Config,
        $LogMessages
    )

    # Ensure npm is available
    $hasNpm = Get-Command npm -ErrorAction SilentlyContinue
    $isNpmMissing = -not $hasNpm
    if ($isNpmMissing) {
        Write-Log $LogMessages.messages.nodeRequired -Level "error"
        throw "npm is not available. Install Node.js first (script 06)."
    }

    $existing = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($existing) {
        $currentVersion = try { & pnpm --version 2>$null } catch { $null }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($currentVersion)

        # Check .installed/ tracking -- skip if version matches
        if ($hasVersion) {
            $isAlreadyTracked = Test-AlreadyInstalled -Name "pnpm" -CurrentVersion $currentVersion
            if ($isAlreadyTracked) {
                Write-Log ($LogMessages.messages.pnpmAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"
                return
            }
        }

        Write-Log ($LogMessages.messages.pnpmAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"

        # Upgrade to latest
        Write-Log $LogMessages.messages.pnpmUpgrading -Level "info"
        try {
            $r = Invoke-NpmGlobalInstall -PackageSpec "pnpm@latest"
            if (-not $r.Success) { throw $r.Error }
            if ($r.Recovered) {
                Write-Log "pnpm upgraded under fallback npm prefix '$($r.PrefixUsed)'." -Level "warn"
                if (-not (Test-InPath -Directory $r.PrefixUsed)) {
                    Add-ToUserPath -Directory $r.PrefixUsed
                    $env:Path = "$env:Path;$($r.PrefixUsed)"
                }
            }
            $newVersion = & pnpm --version 2>$null
            Write-Log ($LogMessages.messages.pnpmUpgradeSuccess -replace '\{version\}', $newVersion) -Level "success"
            Save-InstalledRecord -Name "pnpm" -Version $newVersion -Method "npm"
            return $true
        } catch {
            Write-Log "pnpm upgrade failed: $_" -Level "error"
            Save-InstalledError -Name "pnpm" -ErrorMessage "$_" -Method "npm"
            return $false
        }
    }
    else {
        Write-Log $LogMessages.messages.pnpmNotFound -Level "info"
        try {
            # Refresh PATH so the updated npm prefix from script 03 is visible
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            $r = Invoke-NpmGlobalInstall -PackageSpec "pnpm"
            if (-not $r.Success) { throw $r.Error }
            if ($r.Recovered) {
                Write-Log "pnpm installed under fallback npm prefix '$($r.PrefixUsed)'." -Level "warn"
            }

            # Refresh PATH and ensure the (possibly new) prefix is on it
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            if ($r.PrefixUsed -and -not (Test-InPath -Directory $r.PrefixUsed)) {
                Add-ToUserPath -Directory $r.PrefixUsed
                $env:Path = "$env:Path;$($r.PrefixUsed)"
            }

            $installedVersion = & pnpm --version 2>$null
            $hasInstalledVersion = -not [string]::IsNullOrWhiteSpace($installedVersion)
            if (-not $hasInstalledVersion) {
                throw "npm install -g pnpm reported success (under prefix '$($r.PrefixUsed)') but 'pnpm --version' did not run. PATH may need a fresh shell."
            }
            Write-Log ($LogMessages.messages.pnpmInstallSuccess -replace '\{version\}', $installedVersion) -Level "success"
            Save-InstalledRecord -Name "pnpm" -Version $installedVersion -Method "npm"
            return $true
        } catch {
            Write-Log "pnpm install failed: $_" -Level "error"
            Save-InstalledError -Name "pnpm" -ErrorMessage "$_" -Method "npm"
            return $false
        }
    }
}

function Configure-PnpmStore {
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $storeConfig = $Config.store
    $isStorePathDisabled = -not $storeConfig.setStorePath
    if ($isStorePathDisabled) { return }

    # Guard: if pnpm itself never installed (e.g. npm prefix mkdir errno -4094),
    # skip configuration with a clear log instead of crashing on
    # "'pnpm' is not recognized as the name of a cmdlet".
    $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
    if (-not $pnpmCmd) {
        Write-Log "Skipping pnpm store configuration: 'pnpm' is not on PATH (install step did not succeed). See earlier errors for the npm prefix / install failure." -Level "warn"
        Write-FileError -FilePath "pnpm" -Operation "configure-pnpm-store" `
            -Reason "Cannot configure pnpm store-dir because the pnpm command is not available. Most likely 'npm install -g pnpm' failed (often errno -4094 on a misconfigured global prefix)." `
            -Module "Configure-PnpmStore"
        return $null
    }

    # Resolve store path
    $storePath = if ($DevDir) {
        Join-Path (Join-Path $DevDir $Config.devDirSubfolder) "store"
    } else {
        $storeConfig.storePath
    }

    # Ensure directory exists
    $isDirMissing = -not (Test-Path $storePath)
    if ($isDirMissing) {
        New-Item -Path $storePath -ItemType Directory -Force | Out-Null
    }

    # Check current store dir
    $currentStore = & pnpm config get store-dir 2>$null
    if ($currentStore -eq $storePath) {
        Write-Log ($LogMessages.messages.storeAlreadySet -replace '\{path\}', $storePath) -Level "info"
    }
    else {
        Write-Log ($LogMessages.messages.configuringStore -replace '\{path\}', $storePath) -Level "info"
        & pnpm config set store-dir $storePath
        Write-Log ($LogMessages.messages.storeSet -replace '\{path\}', $storePath) -Level "success"
    }

    return $storePath
}

function Update-PnpmPath {
    param(
        $Config,
        $LogMessages
    )

    $isPathUpdateDisabled = -not $Config.path.updateUserPath
    if ($isPathUpdateDisabled) { return }

    # Guard: same protection as Configure-PnpmStore -- skip cleanly if pnpm
    # is missing rather than throwing "not recognized".
    $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
    $hasPnpm = [bool]$pnpmCmd

    # pnpm global bin directory
    $pnpmHome = if ($hasPnpm) { & pnpm config get global-bin-dir 2>$null } else { $null }
    $hasPnpmHome = -not [string]::IsNullOrWhiteSpace("$pnpmHome")
    $isPnpmHomeMissing = -not $hasPnpmHome
    if ($isPnpmHomeMissing) {
        # Fallback: use PNPM_HOME or default location
        $pnpmHome = if ($env:PNPM_HOME) { $env:PNPM_HOME }
                    else { Join-Path $env:LOCALAPPDATA "pnpm" }
    }

    $isAlreadyInPath = Test-InPath -Directory $pnpmHome
    if ($isAlreadyInPath) {
        Write-Log ($LogMessages.messages.pathAlreadyContains -replace '\{path\}', $pnpmHome) -Level "info"
    }
    else {
        Write-Log ($LogMessages.messages.addingToPath -replace '\{path\}', $pnpmHome) -Level "info"
        Add-ToUserPath -Directory $pnpmHome

        # Also set PNPM_HOME env var
        [System.Environment]::SetEnvironmentVariable("PNPM_HOME", $pnpmHome, "User")
        $env:PNPM_HOME = $pnpmHome
    }
}

function Uninstall-Pnpm {
    <#
    .SYNOPSIS
        Full pnpm uninstall: npm uninstall, remove PNPM_HOME env var,
        remove from PATH, clean dev dir subfolder, purge tracking.
    #>
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    # 1. Uninstall via npm
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "pnpm") -Level "info"
    try {
        $output = & npm uninstall -g pnpm 2>&1
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "pnpm") -Level "success"
    } catch {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "pnpm") -Level "error"
    }

    # 2. Remove PNPM_HOME environment variable
    $currentHome = [System.Environment]::GetEnvironmentVariable("PNPM_HOME", "User")
    $hasHome = -not [string]::IsNullOrWhiteSpace($currentHome)
    if ($hasHome) {
        Write-Log "Removing PNPM_HOME env var: $currentHome" -Level "info"
        [System.Environment]::SetEnvironmentVariable("PNPM_HOME", $null, "User")
        $env:PNPM_HOME = $null
        Remove-FromUserPath -Directory $currentHome
    }

    # 3. Clean dev directory subfolder
    $storePath = if ($DevDir) { Join-Path $DevDir $Config.devDirSubfolder } else { $Config.store.storePath }
    $hasValidPath = -not [string]::IsNullOrWhiteSpace($storePath)
    if ($hasValidPath) {
        $parentDir = Split-Path -Parent $storePath
        $isDirPresent = Test-Path $parentDir
        if ($isDirPresent) {
            Write-Log "Removing dev directory subfolder: $parentDir" -Level "info"
            Remove-Item -Path $parentDir -Recurse -Force
            Write-Log "Dev directory subfolder removed: $parentDir" -Level "success"
        }
    }

    # 4. Remove tracking records
    Remove-InstalledRecord -Name "pnpm"
    Remove-ResolvedData -ScriptFolder "04-install-pnpm"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
