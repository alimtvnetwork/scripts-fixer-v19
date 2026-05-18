# --------------------------------------------------------------------------
#  Helper: Install ConEmu via Chocolatey + sync ConEmu.xml settings
#  Supports 3 modes: install+settings (default), settings-only, install-only
#  Settings live in repo at: settings/06 - conemu/ConEmu.xml
#  Target on Windows:        %APPDATA%\ConEmu\ConEmu.xml
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

function Get-RepoRoot {
    # helpers/conemu.ps1 -> scripts/48-install-conemu/helpers -> scripts/48-install-conemu -> scripts -> repo
    return Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-ConEmuSettingsTarget {
    return Join-Path $env:APPDATA "ConEmu"
}

function Install-ConEmu {
    <#
    .SYNOPSIS
        Installs ConEmu via Chocolatey and (optionally) syncs ConEmu.xml.
        Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)] $ConEmuConfig,
        [Parameter(Mandatory)] $LogMessages,
        [ValidateSet("install+settings", "settings-only", "install-only")]
        [string]$Mode = "install+settings"
    )

    $msgs = $LogMessages.messages

    $modeLabel = switch ($Mode) {
        "install+settings" { "ConEmu + Settings (install ConEmu and sync ConEmu.xml)" }
        "settings-only"    { "Settings only (sync ConEmu.xml, no install)" }
        "install-only"     { "Install only (install ConEmu, no settings sync)" }
    }
    Write-Log "Mode: $modeLabel" -Level "info"
    Write-Host ""

    # -- Settings-only path -------------------------------------------------
    if ($Mode -eq "settings-only") {
        Write-Log "Skipping ConEmu installation (settings-only mode)" -Level "info"
        return (Sync-ConEmuSettings -ConEmuConfig $ConEmuConfig -LogMessages $LogMessages)
    }

    # -- Detect existing install --------------------------------------------
    $cmd = Get-Command $ConEmuConfig.verifyCommand -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $commonPaths = @(
            "$env:ProgramFiles\ConEmu\ConEmu64.exe",
            "${env:ProgramFiles(x86)}\ConEmu\ConEmu64.exe",
            "${env:ProgramFiles(x86)}\ConEmu\ConEmu.exe"
        )
        foreach ($p in $commonPaths) {
            if (Test-Path $p) {
                $cmd = Get-Item $p
                break
            }
        }
    }

    if ($cmd) {
        $version = "unknown"
        try {
            $exePath = if ($cmd -is [System.Management.Automation.ApplicationInfo]) { $cmd.Source } else { $cmd.FullName }
            $version = (Get-Item $exePath).VersionInfo.ProductVersion
        } catch { }

        $isAlreadyInstalled = Test-AlreadyInstalled -Name "conemu" -CurrentVersion $version
        if ($isAlreadyInstalled) {
            Write-Log ($msgs.alreadyInstalled -replace '\{version\}', $version) -Level "success"
            # Always sync settings on rerun unless caller explicitly asked for install-only
            if ($Mode -ne "install-only") {
                Sync-ConEmuSettings -ConEmuConfig $ConEmuConfig -LogMessages $LogMessages | Out-Null
            } else {
                Write-Log "Settings sync skipped (install-only mode)" -Level "info"
            }
            return $true
        }
    }

    # -- Install via Chocolatey ---------------------------------------------
    Write-Log $msgs.notFound -Level "info"
    Write-Log $msgs.installing -Level "info"

    $isInstalled = Install-ChocoPackage -PackageName $ConEmuConfig.chocoPackage
    if (-not $isInstalled) {
        Write-Log ($msgs.installFailed -replace '\{error\}', "choco install conemu returned failure") -Level "error"
        Save-InstalledError -Name "conemu" -ErrorMessage "choco install conemu failed"
        return $false
    }

    # -- Verify install ------------------------------------------------------
    $verifyPaths = @(
        "$env:ProgramFiles\ConEmu\ConEmu64.exe",
        "${env:ProgramFiles(x86)}\ConEmu\ConEmu64.exe",
        "${env:ProgramFiles(x86)}\ConEmu\ConEmu.exe"
    )
    $installedPath = $null
    foreach ($p in $verifyPaths) {
        if (Test-Path $p) { $installedPath = $p; break }
    }

    if (-not $installedPath) {
        $checkedPaths = $verifyPaths -join ", "
        Write-FileError -FilePath $checkedPaths -Operation "resolve" -Reason "ConEmu64.exe not found after Chocolatey install -- checked: $checkedPaths" -Module "Install-ConEmu"
        Write-Log ($msgs.installFailed -replace '\{error\}', "ConEmu64.exe not found after install") -Level "error"
        return $false
    }

    $version = (Get-Item $installedPath).VersionInfo.ProductVersion
    Write-Log $msgs.installSuccess -Level "success"
    Write-Log ($msgs.installDir -replace '\{path\}', $installedPath) -Level "success"
    Write-Host ""
    Save-InstalledRecord -Name "conemu" -Version $version -Method "chocolatey"

    # -- Sync settings ------------------------------------------------------
    if ($Mode -eq "install+settings") {
        Sync-ConEmuSettings -ConEmuConfig $ConEmuConfig -LogMessages $LogMessages | Out-Null
    } else {
        Write-Log "Settings sync skipped (install-only mode)" -Level "info"
    }

    return $true
}

function Sync-ConEmuSettings {
    <#
    .SYNOPSIS
        Copies repo/settings/06 - conemu/ConEmu.xml to %APPDATA%\ConEmu\ConEmu.xml.
        Backs up any existing ConEmu.xml to ConEmu.xml.bak.<timestamp> first.
    #>
    param(
        [Parameter(Mandatory)] $ConEmuConfig,
        [Parameter(Mandatory)] $LogMessages
    )

    $msgs = $LogMessages.messages
    $repoRoot = Get-RepoRoot
    $sourceDir = Join-Path $repoRoot $ConEmuConfig.settings.sourceFolder
    $sourceFile = Join-Path $sourceDir $ConEmuConfig.settings.fileName

    $isSourceMissing = -not (Test-Path $sourceFile)
    if ($isSourceMissing) {
        Write-FileError -FilePath $sourceFile -Operation "read" -Reason "ConEmu.xml not present in repo -- cannot sync" -Module "Sync-ConEmuSettings"
        Write-Log ($msgs.settingsSourceMissing -replace '\{path\}', $sourceFile) -Level "warn"
        return $false
    }

    $targetDir = Get-ConEmuSettingsTarget
    $targetFile = Join-Path $targetDir $ConEmuConfig.settings.fileName

    if (-not (Test-Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        Write-Log "Created ConEmu AppData folder: $targetDir" -Level "info"
    }

    # -- Back up existing ConEmu.xml if present -----------------------------
    if ((Test-Path $targetFile) -and $ConEmuConfig.settings.backupExisting) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupPath = "$targetFile.bak.$stamp"
        try {
            Copy-Item -Path $targetFile -Destination $backupPath -Force
            Write-Log ($msgs.settingsBackedUp -replace '\{path\}', $backupPath) -Level "info"
        } catch {
            Write-FileError -FilePath $targetFile -Operation "backup" -Reason "Could not back up existing ConEmu.xml to '$backupPath': $_" -Module "Sync-ConEmuSettings"
        }
    }

    Write-Log $msgs.syncingSettings -Level "info"
    try {
        Copy-Item -Path $sourceFile -Destination $targetFile -Force
        Write-Log ($msgs.settingsSynced -replace '\{path\}', $targetFile) -Level "success"
    } catch {
        Write-FileError -FilePath $sourceFile -Operation "copy" -Reason "Failed to copy ConEmu.xml to '$targetFile': $_" -Module "Sync-ConEmuSettings"
        Write-Log "Failed to copy ConEmu.xml: $_" -Level "error"
        return $false
    }

    # -- Post-install validation -------------------------------------------
    return (Test-ConEmuSettingsApplied -TargetFile $targetFile -LogMessages $LogMessages)
}

function Test-ConEmuSettingsApplied {
    <#
    .SYNOPSIS
        Verifies that ConEmu.xml exists at %APPDATA%\ConEmu\ConEmu.xml, is non-empty,
        parses as valid XML, and contains the expected <key name="Software"> root.
        Emits a clear pass/fail summary line. Returns $true on full pass.
    #>
    param(
        [Parameter(Mandatory)] [string]$TargetFile,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    Write-Log ($msgs.validateStart -replace '\{path\}', $TargetFile) -Level "info"

    $fileOk = $false; $xmlOk = $false; $bytes = 0; $keys = 0

    if (-not (Test-Path -LiteralPath $TargetFile)) {
        Write-FileError -FilePath $TargetFile -Operation "validate" -Reason "ConEmu.xml not present after sync" -Module "Test-ConEmuSettingsApplied"
        Write-Log ($msgs.validateMissing -replace '\{path\}', $TargetFile) -Level "error"
    } else {
        $fileOk = $true
        try { $bytes = (Get-Item -LiteralPath $TargetFile).Length } catch { $bytes = 0 }
        if ($bytes -le 0) {
            Write-FileError -FilePath $TargetFile -Operation "validate" -Reason "ConEmu.xml is 0 bytes" -Module "Test-ConEmuSettingsApplied"
            Write-Log ($msgs.validateEmpty -replace '\{path\}', $TargetFile) -Level "error"
        } else {
            try {
                [xml]$xml = Get-Content -LiteralPath $TargetFile -Raw -ErrorAction Stop
                $xmlOk = $true
                $rootKey = $xml.SelectSingleNode("//key[@name='Software']")
                if ($null -eq $rootKey) {
                    Write-FileError -FilePath $TargetFile -Operation "validate" -Reason "missing expected <key name='Software'> root element" -Module "Test-ConEmuSettingsApplied"
                    Write-Log ($msgs.validateNoRoot -replace '\{path\}', $TargetFile) -Level "error"
                    $xmlOk = $false
                } else {
                    $keys = @($xml.SelectNodes("//key")).Count
                    $okMsg = $msgs.validateOk
                    $okMsg = $okMsg -replace '\{bytes\}', $bytes
                    $okMsg = $okMsg -replace '\{keys\}', $keys
                    $okMsg = $okMsg -replace '\{path\}', $TargetFile
                    Write-Log $okMsg -Level "success"
                }
            } catch {
                Write-FileError -FilePath $TargetFile -Operation "validate" -Reason "XML parse failed: $($_.Exception.Message)" -Module "Test-ConEmuSettingsApplied"
                $errMsg = $msgs.validateBadXml -replace '\{path\}', $TargetFile
                $errMsg = $errMsg -replace '\{error\}', $_.Exception.Message
                Write-Log $errMsg -Level "error"
            }
        }
    }

    $summary = $msgs.validateSummary
    $summary = $summary -replace '\{fileOk\}', $(if ($fileOk) { "PASS" } else { "FAIL" })
    $summary = $summary -replace '\{xmlOk\}',  $(if ($xmlOk)  { "PASS" } else { "FAIL" })
    $summary = $summary -replace '\{bytes\}',  $bytes
    $summary = $summary -replace '\{keys\}',   $keys
    $summary = $summary -replace '\{path\}',   $TargetFile
    Write-Log $summary -Level $(if ($fileOk -and $xmlOk) { "success" } else { "error" })

    return ($fileOk -and $xmlOk)
}

function Export-ConEmuSettings {
    <#
    .SYNOPSIS
        Reverse direction -- copies %APPDATA%\ConEmu\ConEmu.xml back into the
        repo at settings/06 - conemu/ConEmu.xml for backup / version control.
    #>
    param(
        [Parameter(Mandatory)] $ConEmuConfig,
        [Parameter(Mandatory)] $LogMessages
    )

    $msgs = $LogMessages.messages
    $sourceDir = Get-ConEmuSettingsTarget
    $sourceFile = Join-Path $sourceDir $ConEmuConfig.settings.fileName

    Write-Log ($msgs.exportStarting -replace '\{source\}', $sourceDir) -Level "info"

    if (-not (Test-Path $sourceFile)) {
        Write-FileError -FilePath $sourceFile -Operation "read" -Reason "ConEmu.xml not present in %APPDATA%\ConEmu. Has ConEmu been launched at least once?" -Module "Export-ConEmuSettings"
        Write-Log $msgs.exportNoSource -Level "error"
        return $false
    }

    $sizeKB = [math]::Round((Get-Item $sourceFile).Length / 1024, 1)
    $maxBytes = $ConEmuConfig.settings.maxFileSizeBytes
    if ((Get-Item $sourceFile).Length -gt $maxBytes) {
        Write-Log "Skipped export: ConEmu.xml is ${sizeKB} KB which exceeds limit (${maxBytes} bytes)" -Level "warn"
        return $false
    }

    $repoRoot = Get-RepoRoot
    $targetDir = Join-Path $repoRoot $ConEmuConfig.settings.sourceFolder
    if (-not (Test-Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        Write-Log "Created repo settings folder: $targetDir" -Level "info"
    }
    $targetFile = Join-Path $targetDir $ConEmuConfig.settings.fileName

    try {
        Copy-Item -Path $sourceFile -Destination $targetFile -Force
        Write-Log ($msgs.exportComplete -replace '\{path\}', $targetFile) -Level "success"
        return $true
    } catch {
        Write-FileError -FilePath $sourceFile -Operation "copy" -Reason "Failed to export ConEmu.xml to '$targetFile': $_" -Module "Export-ConEmuSettings"
        return $false
    }
}

function Uninstall-ConEmu {
    param(
        $ConEmuConfig,
        $LogMessages
    )

    $packageName = $ConEmuConfig.chocoPackage
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "ConEmu") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $packageName
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "ConEmu") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "ConEmu") -Level "error"
    }

    Remove-InstalledRecord -Name "conemu"
    Remove-ResolvedData -ScriptFolder "48-install-conemu"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
