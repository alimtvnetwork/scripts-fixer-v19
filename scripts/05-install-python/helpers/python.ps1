# --------------------------------------------------------------------------
#  Python helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

$_toolVersionPath = Join-Path $_sharedDir "tool-version.ps1"
$isToolVersionMissing = -not (Test-Path $_toolVersionPath)
if ($isToolVersionMissing) {
    Write-FileError -FilePath $_toolVersionPath -Operation "load" -Reason "Shared helper file does not exist" -Module "05-install-python/helpers/python.ps1"
    throw "Missing shared helper: $_toolVersionPath"
}

$isPythonResolverMissing = -not (Get-Command Resolve-PythonExe -ErrorAction SilentlyContinue)
if ($isPythonResolverMissing) {
    . $_toolVersionPath
}


function Add-DirectoryToProcessPath {
    param(
        [string]$Directory
    )

    $hasDirectory = -not [string]::IsNullOrWhiteSpace($Directory) -and (Test-Path $Directory -PathType Container)
    $isDirectoryMissing = -not $hasDirectory
    if ($isDirectoryMissing) {
        return
    }

    $pathEntries = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $isAlreadyInPath = $false
    foreach ($pathEntry in $pathEntries) {
        $isSameEntry = $pathEntry.TrimEnd('\\') -ieq $Directory.TrimEnd('\\')
        if ($isSameEntry) {
            $isAlreadyInPath = $true
            break
        }
    }

    if ($isAlreadyInPath) {
        return
    }

    $hasExistingPath = -not [string]::IsNullOrWhiteSpace($env:Path)
    if ($hasExistingPath) {
        $env:Path = "$Directory;$env:Path"
    } else {
        $env:Path = $Directory
    }
}

function Set-PythonRuntimeEnvironment {
    param(
        $PythonInfo,

        [ValidateSet("User", "Machine")]
        [string]$EnvironmentScope = "User"
    )

    $hasPythonInfo = $null -ne $PythonInfo -and $PythonInfo.IsValid
    $isPythonInfoMissing = -not $hasPythonInfo
    if ($isPythonInfoMissing) {
        return
    }

    $pythonDir = Split-Path -Parent $PythonInfo.Path
    $env:PYTHON_EXE = $PythonInfo.Path
    $env:PYTHON_HOME = $pythonDir
    [System.Environment]::SetEnvironmentVariable("PYTHON_EXE", $PythonInfo.Path, $EnvironmentScope)
    [System.Environment]::SetEnvironmentVariable("PYTHON_HOME", $pythonDir, $EnvironmentScope)

    Add-DirectoryToProcessPath -Directory $pythonDir

    $pythonScriptsDir = Join-Path $pythonDir "Scripts"
    $hasPythonScriptsDir = Test-Path $pythonScriptsDir -PathType Container
    if ($hasPythonScriptsDir) {
        $env:PYTHON_SCRIPTS = $pythonScriptsDir
        [System.Environment]::SetEnvironmentVariable("PYTHON_SCRIPTS", $pythonScriptsDir, $EnvironmentScope)
        Add-DirectoryToProcessPath -Directory $pythonScriptsDir
    }
}

function Get-PythonInstallerConfig {
    param(
        $Config,
        [string]$DevDir
    )

    $configFilePath = Join-Path (Split-Path -Parent $PSScriptRoot) "config.json"
    $installerConfig = $Config.installer
    $hasInstallerConfig = $null -ne $installerConfig
    if (-not $hasInstallerConfig) {
        $reason = "Missing 'installer' section required for official Python downloads"
        Write-FileError -FilePath $configFilePath -Operation "load" -Reason $reason -Module "Get-PythonInstallerConfig"
        throw $reason
    }

    $version = "$($installerConfig.version)".Trim()
    $downloadUrl = "$($installerConfig.downloadUrl)".Trim()
    $fileName = "$($installerConfig.fileName)".Trim()
    $installDirSubfolder = "$($installerConfig.installDirSubfolder)".Trim()

    foreach ($field in @(
        @{ Name = "version"; Value = $version },
        @{ Name = "downloadUrl"; Value = $downloadUrl },
        @{ Name = "fileName"; Value = $fileName },
        @{ Name = "installDirSubfolder"; Value = $installDirSubfolder }
    )) {
        $hasValue = -not [string]::IsNullOrWhiteSpace($field.Value)
        if (-not $hasValue) {
            $reason = "Missing installer.$($field.Name) value"
            Write-FileError -FilePath $configFilePath -Operation "load" -Reason $reason -Module "Get-PythonInstallerConfig"
            throw $reason
        }
    }

    # Resolve installDir dynamically: DevDir\python\Python313
    $hasDevDir = -not [string]::IsNullOrWhiteSpace($DevDir)
    if (-not $hasDevDir) {
        # Use smart drive detection -- honour Python's lightweight minFreeGB
        $pyMin = 0.5
        if ($null -ne $Config.minFreeGB) {
            try { $pyMin = [double]$Config.minFreeGB } catch { $pyMin = 0.5 }
        }
        $DevDir = Resolve-SmartDevDir -MinFreeGB $pyMin
    }

    $devDirSubfolder = if ($Config.devDirSubfolder) { $Config.devDirSubfolder } else { "python" }
    $installDir = Join-Path (Join-Path $DevDir $devDirSubfolder) $installDirSubfolder

    return @{
        Version        = $version
        DownloadUrl    = $downloadUrl
        FileName       = $fileName
        InstallDir     = $installDir
        InstallAllUsers = [bool]$installerConfig.allUsers
        IncludePip     = [bool]$installerConfig.includePip
    }
}

function Get-PythonEnvironmentScope {
    param(
        $InstallerConfig
    )

    $isMachineInstall = $null -ne $InstallerConfig -and $InstallerConfig.InstallAllUsers
    if ($isMachineInstall) {
        return "Machine"
    }

    return "User"
}

function Persist-PythonEnvironmentHints {
    param(
        [string]$PythonExe,
        [string]$PythonDir,
        [string]$PythonScriptsDir,

        [ValidateSet("User", "Machine")]
        [string]$EnvironmentScope = "User"
    )

    $hasPythonExe = -not [string]::IsNullOrWhiteSpace($PythonExe)
    if ($hasPythonExe) {
        $env:PYTHON_EXE = $PythonExe
        [System.Environment]::SetEnvironmentVariable("PYTHON_EXE", $PythonExe, $EnvironmentScope)
    }

    $hasPythonDir = -not [string]::IsNullOrWhiteSpace($PythonDir)
    if ($hasPythonDir) {
        $env:PYTHON_HOME = $PythonDir
        [System.Environment]::SetEnvironmentVariable("PYTHON_HOME", $PythonDir, $EnvironmentScope)
    }

    $hasPythonScriptsDir = -not [string]::IsNullOrWhiteSpace($PythonScriptsDir)
    if ($hasPythonScriptsDir) {
        $env:PYTHON_SCRIPTS = $PythonScriptsDir
        [System.Environment]::SetEnvironmentVariable("PYTHON_SCRIPTS", $PythonScriptsDir, $EnvironmentScope)
    }
}

function Download-PythonInstaller {
    param(
        $InstallerConfig
    )

    $installerPath = Join-Path ([System.IO.Path]::GetTempPath()) $InstallerConfig.FileName
    Write-Log "Downloading Python $($InstallerConfig.Version) installer from $($InstallerConfig.DownloadUrl)" -Level "info"

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $InstallerConfig.DownloadUrl -OutFile $installerPath -UseBasicParsing
    } catch {
        $reason = "Failed to download Python installer from $($InstallerConfig.DownloadUrl): $_"
        Write-FileError -FilePath $installerPath -Operation "write" -Reason $reason -Module "Download-PythonInstaller"
        throw "Failed to download Python installer: $installerPath"
    }

    $hasInstallerPath = Test-Path $installerPath -PathType Leaf
    if (-not $hasInstallerPath) {
        $reason = "Python installer download completed but the installer file was not created"
        Write-FileError -FilePath $installerPath -Operation "write" -Reason $reason -Module "Download-PythonInstaller"
        throw "Failed to download Python installer: $installerPath"
    }

    return $installerPath
}

function Sync-PythonRuntimePath {
    param(
        [string]$PythonDir,
        [string]$PythonScriptsDir,

        [ValidateSet("User", "Machine")]
        [string]$EnvironmentScope = "User"
    )

    foreach ($pathEntry in @($PythonDir, $PythonScriptsDir)) {
        $hasPathEntry = -not [string]::IsNullOrWhiteSpace($pathEntry) -and (Test-Path $pathEntry -PathType Container)
        if (-not $hasPathEntry) {
            continue
        }

        Add-DirectoryToProcessPath -Directory $pathEntry

        $isAlreadyInSelectedPath = Test-InPath -Directory $pathEntry -Scope $EnvironmentScope
        if ($isAlreadyInSelectedPath) {
            Write-Log "PATH already contains Python runtime: $pathEntry" -Level "info"
            continue
        }

        Write-Log "Adding Python runtime to $EnvironmentScope PATH: $pathEntry" -Level "info"
        if ($EnvironmentScope -eq "Machine") {
            Add-ToMachinePath -Directory $pathEntry | Out-Null
        } else {
            Add-ToUserPath -Directory $pathEntry | Out-Null
        }
    }

    Refresh-EnvPath
    Add-DirectoryToProcessPath -Directory $PythonDir
    Add-DirectoryToProcessPath -Directory $PythonScriptsDir
}

function Resolve-InstalledPython {
    param(
        $LogMessages,
        [switch]$RequirePip,

        [ValidateSet("User", "Machine")]
        [string]$EnvironmentScope = "User"
    )

    $pythonInfo = Resolve-PythonExe -ReturnInfo -RefreshPath
    $hasPythonInfo = $null -ne $pythonInfo -and $pythonInfo.IsValid
    $isPythonInfoMissing = -not $hasPythonInfo
    if ($isPythonInfoMissing) {
        return $null
    }

    $isPipRequiredButMissing = $RequirePip -and -not $pythonInfo.HasPip
    if ($isPipRequiredButMissing) {
        Write-Log "pip not detected for '$($pythonInfo.Path)'. Running ensurepip..." -Level "warn"
        try {
            & $pythonInfo.Path -m ensurepip --upgrade 2>&1 | Out-Null
        } catch {
        }

        $pythonInfo = Resolve-PythonExe -RequirePip -ReturnInfo -RefreshPath
        $hasPythonInfo = $null -ne $pythonInfo -and $pythonInfo.IsValid
        $isPythonInfoMissing = -not $hasPythonInfo
        if ($isPythonInfoMissing) {
            return $null
        }
    }

    Set-PythonRuntimeEnvironment -PythonInfo $pythonInfo -EnvironmentScope $EnvironmentScope
    return $pythonInfo
}


function Install-Python {
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $installerConfig = Get-PythonInstallerConfig -Config $Config -DevDir $DevDir
    $environmentScope = Get-PythonEnvironmentScope -InstallerConfig $installerConfig
    $desiredVersion = "Python $($installerConfig.Version)"

    $existingPython = Resolve-InstalledPython -LogMessages $LogMessages -RequirePip -EnvironmentScope $environmentScope
    $hasExistingPython = $null -ne $existingPython
    if ($hasExistingPython) {
        $currentVersion = $existingPython.Version
        Write-Log ($LogMessages.messages.pythonAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"

        $isDesiredVersionInstalled = $currentVersion -like "$desiredVersion*"
        $isUpgradeDisabled = -not $Config.alwaysUpgradeToLatest
        if ($isDesiredVersionInstalled -or $isUpgradeDisabled) {
            Save-InstalledRecord -Name "python" -Version $currentVersion -Method "python.org"
            return $existingPython
        }
    } else {
        Write-Log $LogMessages.messages.pythonNotFound -Level "info"
    }

    $isUpgrade = $hasExistingPython
    $expectedPythonExe = Join-Path $installerConfig.InstallDir "python.exe"
    $expectedScriptsDir = Join-Path $installerConfig.InstallDir "Scripts"

    try {
        $installerPath = Download-PythonInstaller -InstallerConfig $installerConfig
        $installArgs = @(
            "/quiet",
            "InstallAllUsers=$(if ($installerConfig.InstallAllUsers) { 1 } else { 0 })",
            "Include_pip=$(if ($installerConfig.IncludePip) { 1 } else { 0 })",
            "Include_launcher=1",
            "InstallLauncherAllUsers=1",
            "AssociateFiles=0",
            "Shortcuts=0",
            "Include_test=0",
            "PrependPath=1",
            ('TargetDir="{0}"' -f $installerConfig.InstallDir)
        )

        Write-Log "Installing Python $($installerConfig.Version) to $($installerConfig.InstallDir)" -Level "info"

        try {
            $installProcess = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
        } catch {
            $reason = "Failed to launch Python installer: $_"
            Write-FileError -FilePath $installerPath -Operation "load" -Reason $reason -Module "Install-Python"
            throw "Failed to launch Python installer: $installerPath"
        }

        $hasInstallerFailed = $installProcess.ExitCode -ne 0 -and $installProcess.ExitCode -ne 3010
        if ($hasInstallerFailed) {
            throw "Python installer exited with code $($installProcess.ExitCode)."
        }

        $isRestartRequested = $installProcess.ExitCode -eq 3010
        if ($isRestartRequested) {
            Write-Log "Python installer requested restart (3010) -- continuing after PATH/env refresh." -Level "warn"
        }

        Persist-PythonEnvironmentHints -PythonExe $expectedPythonExe -PythonDir $installerConfig.InstallDir -PythonScriptsDir $expectedScriptsDir -EnvironmentScope $environmentScope
        Add-DirectoryToProcessPath -Directory $installerConfig.InstallDir
        Add-DirectoryToProcessPath -Directory $expectedScriptsDir
        Sync-PythonRuntimePath -PythonDir $installerConfig.InstallDir -PythonScriptsDir $expectedScriptsDir -EnvironmentScope $environmentScope

        # Retry resolution with explicit env + PATH sync so chained installs see python immediately
        $resolvedPython = $null
        $maxRetries = 5
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            Set-PythonResolverCache -PythonInfo $null
            Refresh-EnvPath
            Add-DirectoryToProcessPath -Directory $installerConfig.InstallDir
            Add-DirectoryToProcessPath -Directory $expectedScriptsDir

            $resolvedPython = Resolve-InstalledPython -LogMessages $LogMessages -RequirePip -EnvironmentScope $environmentScope
            $hasResolvedPython = $null -ne $resolvedPython
            if ($hasResolvedPython) { break }

            $isLastAttempt = $attempt -eq $maxRetries
            if (-not $isLastAttempt) {
                Write-Log "Python not found on attempt $attempt/$maxRetries, retrying in 2s after PATH refresh..." -Level "warn"
                Start-Sleep -Seconds 2
            }
        }

        $isResolvedPythonMissing = $null -eq $resolvedPython
        if ($isResolvedPythonMissing) {
            $failureMessage = "Official installer completed, but no working python executable could be resolved at $expectedPythonExe after $maxRetries attempts."
            Write-FileError -FilePath $expectedPythonExe -Operation "resolve" -Reason $failureMessage -Module "Install-Python" -Fallback "Verify the installer completed and rerun script 05."
            throw $failureMessage
        }

        $resolvedVersion = $resolvedPython.Version
        if ($isUpgrade) {
            Write-Log ($LogMessages.messages.pythonUpgradeSuccess -replace '\{version\}', $resolvedVersion) -Level "success"
        } else {
            Write-Log ($LogMessages.messages.pythonInstallSuccess -replace '\{version\}', $resolvedVersion) -Level "success"
        }

        Save-InstalledRecord -Name "python" -Version $resolvedVersion -Method "python.org"
        return $resolvedPython
    } catch {
        $failureMessage = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($failureMessage)) {
            $failureMessage = "$_"
        }

        if ($isUpgrade) {
            Write-Log "Python upgrade failed: $failureMessage" -Level "error"
        } else {
            Write-Log "Python install failed: $failureMessage" -Level "error"
        }

        Save-InstalledError -Name "python" -ErrorMessage $failureMessage -Method "python.org"
        throw
    }
}

function Configure-PipSite {
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $pipConfig = $Config.pip
    $isSetSiteDisabled = -not $pipConfig.setUserSite
    if ($isSetSiteDisabled) { return }

    # Resolve site path
    $sitePath = if ($DevDir) {
        Join-Path $DevDir $Config.devDirSubfolder
    } else {
        $pipConfig.userSitePath
    }

    # Ensure directory exists
    $isDirMissing = -not (Test-Path $sitePath)
    if ($isDirMissing) {
        New-Item -Path $sitePath -ItemType Directory -Force | Out-Null
    }

    # Set PYTHONUSERBASE environment variable (controls pip install --user target)
    $currentBase = [System.Environment]::GetEnvironmentVariable("PYTHONUSERBASE", "User")
    if ($currentBase -eq $sitePath) {
        Write-Log ($LogMessages.messages.pipSiteAlreadySet -replace '\{path\}', $sitePath) -Level "info"
        $env:PYTHONUSERBASE = $sitePath
    }
    else {
        Write-Log ($LogMessages.messages.configuringPipSite -replace '\{path\}', $sitePath) -Level "info"
        [System.Environment]::SetEnvironmentVariable("PYTHONUSERBASE", $sitePath, "User")
        $env:PYTHONUSERBASE = $sitePath
        Write-Log ($LogMessages.messages.pipSiteSet -replace '\{path\}', $sitePath) -Level "success"
    }

    return $sitePath
}

function Update-PythonPath {
    param(
        $Config,
        $LogMessages,
        [string]$SitePath,
        [string]$DevDir
    )

    $isPathUpdateDisabled = -not $Config.path.updateUserPath
    if ($isPathUpdateDisabled) { return }

    $hasNoSitePath = -not $SitePath
    if ($hasNoSitePath) { return }

    # Python user Scripts directory
    $scriptsDir = Join-Path $SitePath "Scripts"

    $isDirMissing = -not (Test-Path $scriptsDir)
    if ($isDirMissing) {
        New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null
    }

    $isAlreadyInPath = Test-InPath -Directory $scriptsDir
    Add-DirectoryToProcessPath -Directory $scriptsDir
    if ($isAlreadyInPath) {
        Write-Log ($LogMessages.messages.pathAlreadyContains -replace '\{path\}', $scriptsDir) -Level "info"
    }
    else {
        Write-Log ($LogMessages.messages.addingToPath -replace '\{path\}', $scriptsDir) -Level "info"
        Add-ToUserPath -Directory $scriptsDir
    }

    $pythonInfo = Resolve-PythonExe -ReturnInfo -RefreshPath
    $hasPythonInfo = $null -ne $pythonInfo -and $pythonInfo.IsValid
    if ($hasPythonInfo) {
        $installerConfig = Get-PythonInstallerConfig -Config $Config -DevDir $DevDir
        $environmentScope = Get-PythonEnvironmentScope -InstallerConfig $installerConfig
        $pythonDir = Split-Path -Parent $pythonInfo.Path
        $pythonScriptsDir = Join-Path $pythonDir "Scripts"
        Sync-PythonRuntimePath -PythonDir $pythonDir -PythonScriptsDir $pythonScriptsDir -EnvironmentScope $environmentScope
        Set-PythonRuntimeEnvironment -PythonInfo $pythonInfo -EnvironmentScope $environmentScope
    }
}

function Uninstall-Python {
    <#
    .SYNOPSIS
        Full Python uninstall: choco uninstall, remove PYTHONUSERBASE env var,
        remove Scripts dir from PATH, clean dev dir subfolder, purge tracking.
    #>
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $packageName = $Config.chocoPackageName
    $installerConfig = Get-PythonInstallerConfig -Config $Config -DevDir $DevDir
    $installDir = $installerConfig.InstallDir
    $installScriptsDir = Join-Path $installDir "Scripts"

    # 1. Remove legacy Chocolatey package if present
    Write-Log ($LogMessages.messages.uninstallingPython) -Level "info"
    $chocoCommand = Get-Command choco.exe -ErrorAction SilentlyContinue
    $hasChocoCommand = $null -ne $chocoCommand
    if ($hasChocoCommand) {
        $isUninstalled = Uninstall-ChocoPackage -PackageName $packageName
        if ($isUninstalled) {
            Write-Log ($LogMessages.messages.pythonUninstallSuccess) -Level "success"
        }
    }

    # 2. Remove Python-related environment variables
    foreach ($variableName in @("PYTHONUSERBASE", "PYTHON_EXE", "PYTHON_HOME", "PYTHON_SCRIPTS")) {
        foreach ($environmentScope in @("User", "Machine")) {
            $currentValue = [System.Environment]::GetEnvironmentVariable($variableName, $environmentScope)
            $hasCurrentValue = -not [string]::IsNullOrWhiteSpace($currentValue)
            if ($hasCurrentValue) {
                Write-Log "Removing $variableName env var from $environmentScope scope: $currentValue" -Level "info"
                [System.Environment]::SetEnvironmentVariable($variableName, $null, $environmentScope)
            }
        }

        Remove-Item "Env:$variableName" -ErrorAction SilentlyContinue
    }

    # 3. Remove install/runtime paths from PATH
    Remove-FromUserPath -Directory $installScriptsDir
    Remove-FromUserPath -Directory $installDir
    Remove-FromMachinePath -Directory $installScriptsDir
    Remove-FromMachinePath -Directory $installDir

    # 4. Remove PYTHONUSERBASE Scripts dir from PATH
    $sitePath = if ($DevDir) {
        Join-Path $DevDir $Config.devDirSubfolder
    } else {
        $Config.pip.userSitePath
    }

    $hasValidSitePath = -not [string]::IsNullOrWhiteSpace($sitePath)
    if ($hasValidSitePath) {
        $scriptsDir = Join-Path $sitePath "Scripts"
        Remove-FromUserPath -Directory $scriptsDir
        Remove-FromMachinePath -Directory $scriptsDir
    }

    # 5. Remove direct-install folder
    $isInstallDirPresent = Test-Path $installDir -PathType Container
    if ($isInstallDirPresent) {
        try {
            Write-Log "Removing Python install directory: $installDir" -Level "info"
            Remove-Item -Path $installDir -Recurse -Force
            Write-Log "Python install directory removed: $installDir" -Level "success"
        } catch {
            Write-FileError -FilePath $installDir -Operation "write" -Reason "Failed to remove Python install directory: $_" -Module "Uninstall-Python"
            Write-Log ($LogMessages.messages.pythonUninstallFailed) -Level "error"
        }
    }

    # 6. Clean dev directory subfolder
    if ($hasValidSitePath -and (Test-Path $sitePath)) {
        Write-Log "Removing dev directory subfolder: $sitePath" -Level "info"
        Remove-Item -Path $sitePath -Recurse -Force
        Write-Log "Dev directory subfolder removed: $sitePath" -Level "success"
    }

    # 7. Remove tracking records
    Set-PythonResolverCache -PythonInfo $null
    Refresh-EnvPath
    Remove-InstalledRecord -Name "python"
    Remove-ResolvedData -ScriptFolder "05-install-python"

    Write-Log ($LogMessages.messages.pythonUninstallComplete) -Level "success"
}
