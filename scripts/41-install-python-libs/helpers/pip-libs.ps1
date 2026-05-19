# --------------------------------------------------------------------------
#  Python Libraries helper functions
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
    Write-FileError -FilePath $_toolVersionPath -Operation "load" -Reason "Shared helper file does not exist" -Module "41-install-python-libs/helpers/pip-libs.ps1"
    throw "Missing shared helper: $_toolVersionPath"
}

$isPythonResolverMissing = -not (Get-Command Resolve-PythonExe -ErrorAction SilentlyContinue)
if ($isPythonResolverMissing) {
    . $_toolVersionPath
}

function Ensure-PythonInstalledForLibraries {
    param($LogMessages)

    $pythonInfo = Resolve-PythonExe -ReturnInfo -RefreshPath
    $hasPython = $null -ne $pythonInfo -and $pythonInfo.IsValid
    if ($hasPython) {
        return $pythonInfo
    }

    $scriptsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $pythonInstallerScript = Join-Path $scriptsRoot "05-install-python\run.ps1"
    $hasInstallerScript = Test-Path $pythonInstallerScript -PathType Leaf
    if (-not $hasInstallerScript) {
        Write-FileError -FilePath $pythonInstallerScript -Operation "load" -Reason "Python installer script was not found for library bootstrap" -Module "Ensure-PythonInstalledForLibraries"
        return $null
    }

    Write-Log "Python not found -- bootstrapping script 05 full install before pip work..." -Level "warn"
    try {
        & $pythonInstallerScript all
    } catch {
        Write-Log "Automatic Python bootstrap failed: $_" -Level "error"
    }

    Set-PythonResolverCache -PythonInfo $null
    return (Resolve-PythonExe -ReturnInfo -RefreshPath)
}


function Assert-PythonAvailable {
    <#
    .SYNOPSIS
        Checks that python and pip are accessible. Returns $true or $false.
    #>
    param($LogMessages)

    $pythonInfo = Ensure-PythonInstalledForLibraries -LogMessages $LogMessages
    $hasPython = $null -ne $pythonInfo -and $pythonInfo.IsValid
    $isPythonMissing = -not $hasPython
    if ($isPythonMissing) {
        Write-Log $LogMessages.messages.pythonNotFound -Level "error"
        return $false
    }

    $env:PYTHON_EXE = $pythonInfo.Path
    Write-Log ("Found Python executable: $($pythonInfo.Path)") -Level "info"
    Write-Log ("Python version: $($pythonInfo.Version)") -Level "info"

    $isPipMissing = -not $pythonInfo.HasPip
    if ($isPipMissing) {
        Write-Log "pip not found for '$($pythonInfo.Path)', attempting ensurepip..." -Level "warn"
        try { & $pythonInfo.Path -m ensurepip --upgrade 2>&1 | Out-Null } catch {}

        $pythonInfo = Resolve-PythonExe -RequirePip -ReturnInfo -RefreshPath
        $hasPython = $null -ne $pythonInfo -and $pythonInfo.IsValid
        $isPythonMissing = -not $hasPython
        if ($isPythonMissing) {
            Write-Log $LogMessages.messages.pipNotFound -Level "error"
            return $false
        }

        $env:PYTHON_EXE = $pythonInfo.Path
        $isPipMissing = -not $pythonInfo.HasPip
        if ($isPipMissing) {
            Write-Log $LogMessages.messages.pipNotFound -Level "error"
            return $false
        }
    }

    Write-Log ("pip version: $($pythonInfo.PipVersion)") -Level "info"
    return $true
}


function Install-PipPackage {
    <#
    .SYNOPSIS
        Installs a single pip package. Returns $true on success.
    #>
    param(
        [string]$Package,
        $LogMessages,
        [switch]$UserSite
    )

    # Check if already installed
    $existingVersion = $null
    try {
        $pyExe = Resolve-PythonExe
        $existingVersion = & $pyExe -m pip show $Package 2>$null |
            Select-String "^Version:" |
            ForEach-Object { ($_ -split ":\s*", 2)[1].Trim() }
    } catch {}

    $isAlreadyInstalled = -not [string]::IsNullOrWhiteSpace($existingVersion)
    if ($isAlreadyInstalled) {
        Write-Log ($LogMessages.messages.packageAlreadyInstalled -replace '\{package\}', $Package -replace '\{version\}', $existingVersion) -Level "info"
        return $true
    }

    Write-Log ($LogMessages.messages.installingSinglePackage -replace '\{package\}', $Package) -Level "info"

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $prevEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $pyExe = Resolve-PythonExe
        $pipArgs = @("-m", "pip", "install", "--no-cache-dir", "--disable-pip-version-check")
        if ($UserSite) { $pipArgs += "--user" }
        $pipArgs += $Package

        $proc = Start-Process -FilePath $pyExe -ArgumentList $pipArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $exit = $proc.ExitCode

        $stdoutLines = if (Test-Path $stdoutPath) { @(Get-Content -Path $stdoutPath -ErrorAction Stop) } else { @() }
        $stderrLines = if (Test-Path $stderrPath) { @(Get-Content -Path $stderrPath -ErrorAction Stop) } else { @() }
        $detailLines = @($stderrLines + $stdoutLines) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }

        if ($exit -eq 0) {
            Write-Log ($LogMessages.messages.packageInstallSuccess -replace '\{package\}', $Package) -Level "success"
            return $true
        }

        $tail = ($detailLines | Select-Object -Last 5) -join " | "
        if ([string]::IsNullOrWhiteSpace($tail)) { $tail = "pip exit code $exit" }
        Write-Log ($LogMessages.messages.packageInstallFailed -replace '\{package\}', $Package -replace '\{error\}', $tail) -Level "error"
        return $false
    } catch {
        $errText = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($errText)) { $errText = "$_" }
        Write-Log ($LogMessages.messages.packageInstallFailed -replace '\{package\}', $Package -replace '\{error\}', $errText) -Level "error"
        return $false
    } finally {
        $ErrorActionPreference = $prevEAP
        foreach ($tempPath in @($stdoutPath, $stderrPath)) {
            $hasTempPath = -not [string]::IsNullOrWhiteSpace($tempPath)
            if (-not $hasTempPath) { continue }
            $hasTempFile = Test-Path $tempPath
            if (-not $hasTempFile) { continue }
            try {
                Remove-Item -Path $tempPath -Force -ErrorAction Stop
            } catch {
                Write-FileError -FilePath $tempPath -Operation "delete" -Reason ("Failed to remove temporary pip capture file: {0}" -f $_.Exception.Message) -Module "Install-PipPackage"
            }
        }
    }
}


function Install-PipPackages {
    <#
    .SYNOPSIS
        Installs a list of pip packages. Returns count of successes.
    #>
    param(
        [string[]]$Packages,
        $LogMessages,
        [switch]$UserSite
    )

    $successCount = 0
    $totalCount = $Packages.Count

    foreach ($pkg in $Packages) {
        $isOk = Install-PipPackage -Package $pkg -LogMessages $LogMessages -UserSite:$UserSite
        if ($isOk) { $successCount++ }
    }

    Write-Log ($LogMessages.messages.setupComplete -replace '\{success\}', $successCount -replace '\{total\}', $totalCount) -Level "success"
    return $successCount
}


function Install-AllLibraries {
    param(
        $Config,
        $LogMessages,
        [switch]$UserSite
    )

    $packages = $Config.allPackages
    $count = $packages.Count
    Write-Log ($LogMessages.messages.installingAll -replace '\{count\}', $count) -Level "info"

    return (Install-PipPackages -Packages $packages -LogMessages $LogMessages -UserSite:$UserSite)
}


function Install-LibraryGroup {
    param(
        [string]$GroupName,
        $Config,
        $LogMessages,
        [switch]$UserSite
    )

    $group = $Config.groups.$GroupName
    $hasGroup = $null -ne $group
    if (-not $hasGroup) {
        Write-Log "Unknown group: $GroupName. Use 'list' to see available groups." -Level "error"
        return 0
    }

    $pkgList = $group.packages -join ", "
    Write-Log ($LogMessages.messages.installingGroup -replace '\{group\}', $group.label -replace '\{packages\}', $pkgList) -Level "info"

    return (Install-PipPackages -Packages $group.packages -LogMessages $LogMessages -UserSite:$UserSite)
}


function Show-LibraryGroups {
    param($Config, $LogMessages)

    Write-Log $LogMessages.messages.listingGroups -Level "info"
    foreach ($key in $Config.groups.PSObject.Properties.Name) {
        $g = $Config.groups.$key
        $pkgList = $g.packages -join ", "
        Write-Log ($LogMessages.messages.groupEntry -replace '\{name\}', $key -replace '\{label\}', $g.label -replace '\{packages\}', $pkgList) -Level "info"
    }
}


function Show-InstalledPipPackages {
    param($LogMessages)

    Write-Log $LogMessages.messages.listingInstalled -Level "info"
    $pyExe = Resolve-PythonExe
    & $pyExe -m pip list --format=columns 2>$null
}


function Uninstall-PipPackages {
    <#
    .SYNOPSIS
        Uninstalls pip packages by name, or all tracked packages if none specified.
    #>
    param(
        [string[]]$Packages,
        $Config,
        $LogMessages
    )

    $targetPackages = if ($Packages -and $Packages.Count -gt 0) {
        $Packages
    } else {
        Write-Log $LogMessages.messages.uninstallingAll -Level "info"
        $Config.allPackages
    }

    foreach ($pkg in $targetPackages) {
        Write-Log ($LogMessages.messages.uninstallingPackage -replace '\{package\}', $pkg) -Level "info"
        try {
            $pyExe = Resolve-PythonExe
            & $pyExe -m pip uninstall -y $pkg 2>&1 | Out-Null
            $isOk = $LASTEXITCODE -eq 0
            if ($isOk) {
                Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{package\}', $pkg) -Level "success"
            } else {
                Write-Log ($LogMessages.messages.uninstallFailed -replace '\{package\}', $pkg -replace '\{error\}', "exit code $LASTEXITCODE") -Level "warn"
            }
        } catch {
            Write-Log ($LogMessages.messages.uninstallFailed -replace '\{package\}', $pkg -replace '\{error\}', "$_") -Level "warn"
        }
    }

    # Remove tracking
    Remove-InstalledRecord -Name "python-libs"
    Remove-ResolvedData -ScriptFolder "41-install-python-libs"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
