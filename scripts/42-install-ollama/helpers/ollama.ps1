# --------------------------------------------------------------------------
#  Ollama helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

$_fastDownloadPath = Join-Path $_sharedDir "fast-download.ps1"
if ((Test-Path $_fastDownloadPath) -and -not (Get-Command Invoke-FastDownload -ErrorAction SilentlyContinue)) {
    . $_fastDownloadPath
}


function Install-Ollama {
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    # Check if already installed
    $existing = Get-Command ollama -ErrorAction SilentlyContinue
    if ($existing) {
        $currentVersion = try { & ollama --version 2>$null } catch { $null }
        $hasVersion = -not [string]::IsNullOrWhiteSpace($currentVersion)

        if ($hasVersion) {
            $isAlreadyTracked = Test-AlreadyInstalled -Name "ollama" -CurrentVersion $currentVersion
            if ($isAlreadyTracked) {
                Write-Log ($LogMessages.messages.ollamaAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"
                return
            }
        }

        Write-Log ($LogMessages.messages.ollamaAlreadyInstalled -replace '\{version\}', $currentVersion) -Level "info"
        Save-InstalledRecord -Name "ollama" -Version "$currentVersion".Trim()
        return
    }

    # Download installer
    Write-Log $LogMessages.messages.ollamaNotFound -Level "info"

    $downloadDir = if ($DevDir) { Join-Path $DevDir $Config.devDirSubfolder } else { Join-Path $env:TEMP "ollama-install" }
    $isDirMissing = -not (Test-Path $downloadDir)
    if ($isDirMissing) {
        New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null
    }

    $installerPath = Join-Path $downloadDir $Config.installerFileName
    Write-Log ($LogMessages.messages.ollamaDownloading -replace '\{path\}', $installerPath) -Level "info"

    $isDownloadOk = Invoke-DownloadWithRetry -Uri $Config.downloadUrl -OutFile $installerPath -Label "OllamaSetup.exe"
    if (-not $isDownloadOk) {
        Write-Log ($LogMessages.messages.ollamaDownloadFailed -replace '\{error\}', "All download attempts failed") -Level "error"
        Save-InstalledError -Name "ollama" -ErrorMessage "Download failed after retries"
        return
    }

    # Run installer silently
    Write-Log $LogMessages.messages.ollamaInstalling -Level "info"
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList "/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES" -Wait -PassThru
        $isExitCodeBad = $process.ExitCode -ne 0
        if ($isExitCodeBad) {
            throw "Installer exited with code $($process.ExitCode)"
        }

        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        $installedVersion = try { & ollama --version 2>$null } catch { "installed" }
        Write-Log ($LogMessages.messages.ollamaInstallSuccess -replace '\{version\}', $installedVersion) -Level "success"
        Save-InstalledRecord -Name "ollama" -Version "$installedVersion".Trim()
    } catch {
        Write-Log ($LogMessages.messages.ollamaInstallFailed -replace '\{error\}', $_) -Level "error"
        Save-InstalledError -Name "ollama" -ErrorMessage "$_"
    }
}

function Configure-OllamaModels {
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    $modelsCfg = $Config.models

    # Resolve models directory
    $defaultModelsDir = if ($DevDir) {
        Join-Path $DevDir $modelsCfg.devDirSubfolder
    } else {
        Join-Path (Get-SafeDevDirFallback) $modelsCfg.devDirSubfolder
    }

    $modelsDir = $defaultModelsDir

    # Prompt user if configured (skip under orchestrator)
    $isOrchestratorRun = $env:SCRIPTS_ROOT_RUN -eq "1"
    $isAutoYes = $env:SCRIPTS_AUTO_YES -eq "1"
    $isPromptEnabled = $modelsCfg.promptForDirectory
    if ($isPromptEnabled -and -not $isOrchestratorRun -and -not $isAutoYes) {
        Write-Host ""
        Write-Host "  Default models directory: $defaultModelsDir" -ForegroundColor Cyan
        $userInput = Read-Host -Prompt "  $($LogMessages.messages.modelsDirPrompt) [$defaultModelsDir]"
        $hasUserInput = -not [string]::IsNullOrWhiteSpace($userInput)
        if ($hasUserInput) {
            $modelsDir = $userInput.Trim()
        }
    } elseif ($isOrchestratorRun -or $isAutoYes) {
        Write-Log "Orchestrator mode: using default models directory: $defaultModelsDir" -Level "info"
    }

    # Create directory
    $isDirMissing = -not (Test-Path $modelsDir)
    if ($isDirMissing) {
        New-Item -Path $modelsDir -ItemType Directory -Force | Out-Null
    }

    # Set OLLAMA_MODELS environment variable
    $envVarName = $modelsCfg.envVarName
    $currentEnvVal = [System.Environment]::GetEnvironmentVariable($envVarName, "User")
    $isEnvAlreadySet = $currentEnvVal -eq $modelsDir
    if ($isEnvAlreadySet) {
        Write-Log ($LogMessages.messages.modelsEnvAlreadySet -replace '\{path\}', $modelsDir) -Level "info"
    } else {
        [System.Environment]::SetEnvironmentVariable($envVarName, $modelsDir, "User")
        $env:OLLAMA_MODELS = $modelsDir
        Write-Log ($LogMessages.messages.modelsEnvSet -replace '\{path\}', $modelsDir) -Level "success"
    }

    Write-Log ($LogMessages.messages.modelsConfiguring -replace '\{path\}', $modelsDir) -Level "info"
    return $modelsDir
}

function Pull-OllamaModels {
    param(
        $Config,
        $LogMessages
    )

    $models = $Config.defaultModels
    $isOrchestratorRun = $env:SCRIPTS_ROOT_RUN -eq "1" -or $env:SCRIPTS_AUTO_YES -eq "1"

    # -- Honor OLLAMA_PULL_MODELS env var (set by scripts/models orchestrator) --
    # When present, restrict the pull list to the given CSV slugs and run
    # non-interactively. Unknown slugs become ad-hoc pulls so users can
    # request models that aren't in defaultModels (e.g. "phi3:mini").
    $csv = $env:OLLAMA_PULL_MODELS
    $hasCsvOverride = -not [string]::IsNullOrWhiteSpace($csv)
    if ($hasCsvOverride) {
        Write-Log "OLLAMA_PULL_MODELS detected: $csv -- non-interactive mode" -Level "info"
        $requestedSlugs = @($csv -split '[,\s]+' | Where-Object { $_.Length -gt 0 } | ForEach-Object { $_.Trim() })

        $resolved = @()
        foreach ($slug in $requestedSlugs) {
            $needle = $slug.ToLower()
            $hit = $models | Where-Object { $_.slug.ToLower() -eq $needle -or $_.pullCommand.ToLower() -eq $needle } | Select-Object -First 1
            if ($hit) {
                $resolved += $hit
            } else {
                # Ad-hoc pull -- synthesize a minimal model object
                Write-Log "Slug '$slug' not in defaults, treating as ad-hoc Ollama pull." -Level "info"
                $resolved += [PSCustomObject]@{
                    slug        = $slug
                    displayName = $slug
                    pullCommand = $slug
                    sizeHint    = "unknown"
                    purpose     = "ad-hoc"
                }
            }
        }
        $models = $resolved
        $isOrchestratorRun = $true  # Force non-interactive
    }

    foreach ($model in $models) {
        # Under orchestrator, auto-accept all model pulls
        if (-not $isOrchestratorRun) {
            Write-Host ""
            Write-Host "  Model: $($model.displayName) ($($model.sizeHint))" -ForegroundColor Cyan
            $userConfirm = Read-Host -Prompt "  Pull this model? (yes/no) [yes]"
            $isDeclined = $userConfirm -eq "no" -or $userConfirm -eq "n"
            if ($isDeclined) {
                Write-Log ($LogMessages.messages.modelPullSkipped -replace '\{name\}', $model.displayName) -Level "info"
                continue
            }
        }

        Write-Log ($LogMessages.messages.modelPulling -replace '\{name\}', $model.displayName -replace '\{size\}', $model.sizeHint) -Level "info"
        $trackingName = "model-$($model.slug)"
        $pullTag      = if ($model.pullCommand) { [string]$model.pullCommand } else { [string]$model.slug }
        try {
            & ollama pull $model.pullCommand 2>&1
            $exit = $LASTEXITCODE
            if ($exit -ne 0) { throw "ollama pull exited with code $exit" }
            Write-Log ($LogMessages.messages.modelPullSuccess -replace '\{name\}', $model.displayName) -Level "success"
            # Persist to .installed/<trackingName>.json so `models list` /
            # uninstall.ps1 (which scans .installed/model-*.json) can see it.
            if (Get-Command Save-InstalledRecord -ErrorAction SilentlyContinue) {
                Save-InstalledRecord -Name $trackingName -Version $pullTag -Method "ollama-pull"
            }
        } catch {
            Write-Log ($LogMessages.messages.modelPullFailed -replace '\{name\}', $model.displayName -replace '\{error\}', $_) -Level "error"
            if (Get-Command Save-InstalledError -ErrorAction SilentlyContinue) {
                Save-InstalledError -Name $trackingName -ErrorMessage "ollama pull '$pullTag' failed: $_" -Version $pullTag -Method "ollama-pull"
            }
        }
    }
}

function Uninstall-Ollama {
    param(
        $Config,
        $LogMessages,
        [string]$DevDir
    )

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "Ollama") -Level "info"

    # Try to find and run uninstaller
    $uninstallPaths = @(
        "$env:LOCALAPPDATA\Programs\Ollama\unins000.exe",
        "C:\Program Files\Ollama\unins000.exe"
    )
    $isUninstalled = $false
    foreach ($path in $uninstallPaths) {
        $isPathValid = Test-Path $path
        if ($isPathValid) {
            try {
                Start-Process -FilePath $path -ArgumentList "/VERYSILENT", "/NORESTART" -Wait
                $isUninstalled = $true
                break
            } catch {
                Write-Log "Uninstaller failed at $path : $_" -Level "error"
            }
        }
    }

    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "Ollama") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "Ollama") -Level "error"
    }

    # Remove OLLAMA_MODELS env var
    $currentModelsEnv = [System.Environment]::GetEnvironmentVariable("OLLAMA_MODELS", "User")
    $hasModelsEnv = -not [string]::IsNullOrWhiteSpace($currentModelsEnv)
    if ($hasModelsEnv) {
        Write-Log "Removing OLLAMA_MODELS env var: $currentModelsEnv" -Level "info"
        [System.Environment]::SetEnvironmentVariable("OLLAMA_MODELS", $null, "User")
        $env:OLLAMA_MODELS = $null
    }

    # Remove tracking
    Remove-InstalledRecord -Name "ollama"
    Remove-ResolvedData -ScriptFolder "42-install-ollama"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
