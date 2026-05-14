# --------------------------------------------------------------------------
#  llama.cpp helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

$_hardwareDetectPath = Join-Path $_sharedDir "hardware-detect.ps1"
if ((Test-Path $_hardwareDetectPath) -and -not (Get-Command Get-HardwareProfile -ErrorAction SilentlyContinue)) {
    . $_hardwareDetectPath
}

$_fastDownloadPath = Join-Path $_sharedDir "fast-download.ps1"
if ((Test-Path $_fastDownloadPath) -and -not (Get-Command Invoke-FastDownload -ErrorAction SilentlyContinue)) {
    . $_fastDownloadPath
}


function Get-FileSize {
    <#
    .SYNOPSIS
        Returns file size in MB, or -1 if file doesn't exist.
    #>
    param([string]$FilePath)
    $isFilePresent = Test-Path $FilePath
    if (-not $isFilePresent) { return -1 }
    $info = Get-Item $FilePath
    return [math]::Round($info.Length / (1024 * 1024), 2)
}

function Test-ZipIntegrity {
    <#
    .SYNOPSIS
        Validates a ZIP file by checking the magic header bytes (PK\x03\x04)
        and optionally comparing against an expected file size.
        Returns $true if the file appears valid.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [long]$ExpectedSizeBytes = 0,

        [double]$SizeTolerancePercent = 10
    )

    $isFilePresent = Test-Path $FilePath
    if (-not $isFilePresent) { return $false }

    $fileInfo = Get-Item $FilePath
    $isFileEmpty = $fileInfo.Length -eq 0
    if ($isFileEmpty) { return $false }

    # Check ZIP magic bytes: PK\x03\x04
    try {
        $header = [byte[]]::new(4)
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            $bytesRead = $stream.Read($header, 0, 4)
            $hasEnoughBytes = $bytesRead -eq 4
            if (-not $hasEnoughBytes) { return $false }
        } finally {
            $stream.Close()
        }

        $isValidHeader = ($header[0] -eq 0x50) -and ($header[1] -eq 0x4B) -and ($header[2] -eq 0x03) -and ($header[3] -eq 0x04)
        if (-not $isValidHeader) { return $false }
    } catch {
        return $false
    }

    # Check expected size if provided
    $hasExpectedSize = $ExpectedSizeBytes -gt 0
    if ($hasExpectedSize) {
        $tolerance = $ExpectedSizeBytes * ($SizeTolerancePercent / 100)
        $minSize = $ExpectedSizeBytes - $tolerance
        $isTooSmall = $fileInfo.Length -lt $minSize
        if ($isTooSmall) { return $false }
    }

    return $true
}

function Install-LlamaCppExecutables {
    <#
    .SYNOPSIS
        Downloads all llama.cpp executable variants, extracts ZIPs, and adds bin
        folders to user PATH.
    #>
    param(
        $Config,
        $LogMessages,
        [string]$BaseDir
    )

    $executables = $Config.executables
    $pathConfig = $Config.path

    # Detect hardware capabilities
    Write-Log $LogMessages.messages.hardwareDetecting -Level "info"
    $hwProfile = Get-HardwareProfile

    $skippedHwCount = 0

    foreach ($item in $executables) {
        # Check hardware compatibility
        $hwRequires = if ($item.PSObject.Properties['requires']) { $item.requires } else { "" }
        $isCompatible = Test-ExecutableCompatible -Requires $hwRequires -HardwareProfile $hwProfile
        if (-not $isCompatible) {
            Write-Log ($LogMessages.messages.hwSkipped -replace '\{slug\}', $item.slug -replace '\{requires\}', $hwRequires) -Level "info"
            $skippedHwCount++
            continue
        }

        Write-Log ($LogMessages.messages.processingExecutable -replace '\{slug\}', $item.slug -replace '\{displayName\}', $item.displayName) -Level "info"
        Write-Log ($LogMessages.messages.downloading -replace '\{url\}', $item.downloadUrl) -Level "info"

        # Resolve target folder
        $targetFolder = Join-Path $BaseDir $item.targetFolderName
        $isDirMissing = -not (Test-Path $targetFolder)
        if ($isDirMissing) {
            New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
        }

        # Determine output path
        $outputPath = Join-Path $BaseDir $item.outputFileName
        Write-Log ($LogMessages.messages.downloadingTo -replace '\{path\}', $outputPath) -Level "info"

        # Check if already downloaded
        $fileSize = Get-FileSize -FilePath $outputPath
        $isAlreadyDownloaded = $fileSize -gt 0
        if ($isAlreadyDownloaded) {
            $isZip = $item.isZip
            if ($isZip) {
                # Validate ZIP integrity before skipping
                $expectedSize = if ($item.PSObject.Properties['expectedSizeBytes']) { $item.expectedSizeBytes } else { 0 }
                $isZipValid = Test-ZipIntegrity -FilePath $outputPath -ExpectedSizeBytes $expectedSize
                if (-not $isZipValid) {
                    Write-Log "Corrupt or partial ZIP detected, re-downloading: $outputPath" -Level "warn"
                    Remove-Item -Path $outputPath -Force -ErrorAction SilentlyContinue
                    # Fall through to download
                } else {
                    $binSubfolder = $item.relativeBinSubfolder
                    $binPath = if ($binSubfolder) { Join-Path $targetFolder $binSubfolder } else { $targetFolder }
                    $isBinPresent = Test-Path $binPath
                    if ($isBinPresent) {
                        Write-Log ($LogMessages.messages.downloadSkipped -replace '\{path\}', $outputPath -replace '\{size\}', $fileSize) -Level "info"
                        Ensure-BinInPath -Config $pathConfig -LogMessages $LogMessages -BinPath $binPath
                        continue
                    }
                    # ZIP valid but not extracted yet -- fall through to extraction
                }
            } else {
                Write-Log ($LogMessages.messages.downloadSkipped -replace '\{path\}', $outputPath -replace '\{size\}', $fileSize) -Level "info"
                Ensure-BinInPath -Config $pathConfig -LogMessages $LogMessages -BinPath $targetFolder
                continue
            }
        }

        # Download
        $isDownloadOk = Invoke-FastDownload -Uri $item.downloadUrl -OutFile $outputPath -Label $item.displayName
        if (-not $isDownloadOk) {
            Write-Log ($LogMessages.messages.downloadFailed -replace '\{slug\}', $item.slug -replace '\{error\}', "All download attempts failed") -Level "error"
            Write-FileError -FilePath $outputPath -Operation "download" -Reason "Download failed after retries" -Module "Install-LlamaCppExecutables"
            continue
        }
        Write-Log ($LogMessages.messages.downloadSuccess -replace '\{fileName\}', $item.outputFileName) -Level "success"

        # Extract if ZIP
        $isZip = $item.isZip
        if ($isZip) {
            Write-Log ($LogMessages.messages.extracting -replace '\{path\}', $targetFolder) -Level "info"
            try {
                Expand-Archive -Path $outputPath -DestinationPath $targetFolder -Force
                Write-Log ($LogMessages.messages.extractSuccess -replace '\{path\}', $targetFolder) -Level "success"
            } catch {
                Write-Log ($LogMessages.messages.extractFailed -replace '\{slug\}', $item.slug -replace '\{error\}', $_) -Level "error"
                Write-FileError -FilePath $outputPath -Operation "extract" -Reason "$_" -Module "Install-LlamaCppExecutables"
                continue
            }
        }

        # Verify executable exists
        $binSubfolder = $item.relativeBinSubfolder
        $binPath = if ($binSubfolder) { Join-Path $targetFolder $binSubfolder } else { $targetFolder }
        $verifyExePath = Join-Path $binPath $item.verifyExe
        $isExePresent = Test-Path $verifyExePath
        if ($isExePresent) {
            Write-Log ($LogMessages.messages.verifyExeFound -replace '\{exe\}', $verifyExePath) -Level "success"
        } else {
            # For ZIPs that extract with a nested folder, search for the exe
            $foundExe = Get-ChildItem -Path $targetFolder -Recurse -Filter $item.verifyExe -ErrorAction SilentlyContinue | Select-Object -First 1
            $hasFoundExe = $null -ne $foundExe
            if ($hasFoundExe) {
                $binPath = $foundExe.DirectoryName
                Write-Log ($LogMessages.messages.verifyExeFound -replace '\{exe\}', $foundExe.FullName) -Level "success"
            } else {
                Write-Log ($LogMessages.messages.verifyExeMissing -replace '\{exe\}', $item.verifyExe) -Level "warn"
            }
        }

        # Add to PATH
        $isAddToPath = $item.addToPath
        if ($isAddToPath) {
            Ensure-BinInPath -Config $pathConfig -LogMessages $LogMessages -BinPath $binPath
        }

        # Track install
        Save-InstalledRecord -Name "llama-cpp-$($item.slug)" -Version $item.slug
    }

    if ($skippedHwCount -gt 0) {
        Write-Log ($LogMessages.messages.hwSkippedSummary -replace '\{count\}', $skippedHwCount) -Level "info"
    }

    # Refresh PATH for current session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Log $LogMessages.messages.sessionRefreshed -Level "success"
    Write-Log $LogMessages.messages.allExecutablesComplete -Level "success"
}

function Ensure-BinInPath {
    param(
        $Config,
        $LogMessages,
        [string]$BinPath
    )

    $isUpdateDisabled = -not $Config.updateUserPath
    if ($isUpdateDisabled) { return }

    $isAlreadyInPath = Test-InPath -Directory $BinPath
    if ($isAlreadyInPath) {
        Write-Log ($LogMessages.messages.pathAlreadySet -replace '\{path\}', $BinPath) -Level "info"
    } else {
        Write-Log ($LogMessages.messages.pathAdding -replace '\{path\}', $BinPath) -Level "info"
        Add-ToUserPath -Directory $BinPath
    }
}

function Uninstall-LlamaCpp {
    <#
    .SYNOPSIS
        Removes all llama.cpp binaries, cleans PATH entries, purges tracking.
        Also removes all model tracking records from .installed/.
    #>
    param(
        $Config,
        $LogMessages,
        [string]$BaseDir
    )

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "llama.cpp") -Level "info"

    foreach ($item in $Config.executables) {
        $targetFolder = Join-Path $BaseDir $item.targetFolderName
        $binSubfolder = $item.relativeBinSubfolder
        $binPath = if ($binSubfolder) { Join-Path $targetFolder $binSubfolder } else { $targetFolder }

        Remove-FromUserPath -Directory $binPath

        $isFolderPresent = Test-Path $targetFolder
        if ($isFolderPresent) {
            Write-Log "Removing: $targetFolder" -Level "info"
            Remove-Item -Path $targetFolder -Recurse -Force
        }

        $outputPath = Join-Path $BaseDir $item.outputFileName
        $isFilePresent = Test-Path $outputPath
        if ($isFilePresent) {
            Remove-Item -Path $outputPath -Force
        }

        Remove-InstalledRecord -Name "llama-cpp-$($item.slug)"
    }

    # Remove model tracking records (scan .installed/ for model-* files)
    $installedDir = Get-InstalledDir
    $modelRecords = Get-ChildItem -Path $installedDir -Filter "model-*.json" -ErrorAction SilentlyContinue
    foreach ($record in $modelRecords) {
        $recordName = [System.IO.Path]::GetFileNameWithoutExtension($record.Name)
        Write-Log "Removing model tracking: $recordName" -Level "info"
        Remove-InstalledRecord -Name $recordName
    }

    Remove-ResolvedData -ScriptFolder "43-install-llama-cpp"

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}