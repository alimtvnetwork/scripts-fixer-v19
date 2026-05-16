# --------------------------------------------------------------------------
#  Shared helper: fast-download (aria2c-first, sane defaults)
#
#  Public function: Invoke-FastDownload
#  Defaults:        Splits = 16, PieceSize = 1M (aria2c minimum)
#  Spec:            spec/shared/fast-download.md
#
#  Resolution order:
#     1. aria2c (auto-installed via Chocolatey if missing)
#     2. Invoke-DownloadWithRetry (BITS / Invoke-WebRequest)
#
#  All failure paths emit CODE-RED file errors via Write-FileError.
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = $PSScriptRoot

$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

$_aria2Path = Join-Path $_sharedDir "aria2c-download.ps1"
if ((Test-Path $_aria2Path) -and -not (Get-Command Assert-Aria2c -ErrorAction SilentlyContinue)) {
    . $_aria2Path
}

$_retryPath = Join-Path $_sharedDir "download-retry.ps1"
if ((Test-Path $_retryPath) -and -not (Get-Command Invoke-DownloadWithRetry -ErrorAction SilentlyContinue)) {
    . $_retryPath
}

$_pbarPath = Join-Path $_sharedDir "progress-bar.ps1"
if ((Test-Path $_pbarPath) -and -not (Get-Command Invoke-Aria2WithProgressBar -ErrorAction SilentlyContinue)) {
    . $_pbarPath
}

function ConvertTo-Aria2PieceSize {
    <#
        aria2c's --min-split-size / -k must be >= 1M. Accept human strings
        like "1M", "2M", "512K" -- clamp the MB value to 1 if the caller
        asked for less.
    #>
    param([string]$PieceSize)

    $isEmpty = [string]::IsNullOrWhiteSpace($PieceSize)
    if ($isEmpty) { return "1M" }

    $trim = $PieceSize.Trim().ToUpperInvariant()
    $isMb = $trim -match '^([0-9]+)M$'
    if ($isMb) {
        $mb = [int]$Matches[1]
        if ($mb -lt 1) { $mb = 1 }
        return "${mb}M"
    }
    $isKb = $trim -match '^([0-9]+)K$'
    if ($isKb) {
        # aria2c minimum is 1M -- clamp.
        Write-Log "[fast-download] piece size '$PieceSize' below aria2c minimum, clamped to 1M." -Level "warn"
        return "1M"
    }
    $isGb = $trim -match '^([0-9]+)G$'
    if ($isGb) { return $trim }

    Write-Log "[fast-download] unrecognised piece size '$PieceSize', using 1M." -Level "warn"
    return "1M"
}

function Invoke-FastDownload {
    <#
    .SYNOPSIS
        Download a single file using aria2c with 16 splits / 1M pieces by
        default. Auto-installs aria2c when missing. Falls back to
        Invoke-DownloadWithRetry only if aria2c install + run both fail.

    .PARAMETER Uri
        Source URL.

    .PARAMETER OutFile
        Absolute target path.

    .PARAMETER Splits
        Number of parallel splits (also used as -x connections-per-server).
        Default 16.

    .PARAMETER PieceSize
        aria2c -k value. Default "1M". Values < 1M are clamped to 1M.

    .PARAMETER Label
        Friendly name for logs. Defaults to the file basename.

    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $OutFile,
        [int]    $Splits     = 16,
        [string] $PieceSize  = "1M",
        [string] $Label      = ""
    )

    $displayLabel = if ($Label) { $Label } else { [System.IO.Path]::GetFileName($OutFile) }

    if ($Splits -lt 1) { $Splits = 1 }
    $pieceArg = ConvertTo-Aria2PieceSize -PieceSize $PieceSize

    # Ensure output directory exists.
    $outDir = Split-Path -Parent $OutFile
    $isDirMissing = -not (Test-Path -LiteralPath $outDir)
    if ($isDirMissing) {
        try {
            New-Item -Path $outDir -ItemType Directory -Force | Out-Null
        } catch {
            Write-FileError -FilePath $outDir -Operation "mkdir" -Reason $_.Exception.Message -Module "Invoke-FastDownload"
            return $false
        }
    }

    # Short-circuit: file already present and non-empty -- skip the download.
    # This matches the "already-installed" status convention; partial
    # (*.aria2 control file present) downloads still resume normally.
    $isForceRedownload = $env:MODELS_FORCE_REDOWNLOAD -eq "1"
    $hasFile = Test-Path -LiteralPath $OutFile -PathType Leaf
    if ($hasFile -and $isForceRedownload) {
        Write-Log "[fast-download] -Force: removing existing file before re-download. Path: $OutFile" -Level "warn"
        try { Remove-Item -LiteralPath $OutFile -Force -ErrorAction Stop } catch {}
        try { Remove-Item -LiteralPath ($OutFile + '.aria2') -Force -ErrorAction SilentlyContinue } catch {}
        $hasFile = $false
    }
    if ($hasFile) {
        $existingSize = (Get-Item -LiteralPath $OutFile).Length
        $hasAriaControl = Test-Path -LiteralPath ($OutFile + '.aria2') -PathType Leaf
        if ($existingSize -gt 0 -and -not $hasAriaControl) {
            $sizeMb = [math]::Round($existingSize / 1MB, 2)
            Write-Log "[fast-download] already-downloaded: $displayLabel ($sizeMb MB) -- skipping. Path: $OutFile" -Level "success"
            return $true
        }
    }

    # Pre-flight: make sure aria2c is on PATH (auto-install via Chocolatey).
    $isAria2Ready = Assert-Aria2c
    if (-not $isAria2Ready) {
        Write-Log "[fast-download] aria2c unavailable -- falling back for: $displayLabel" -Level "warn"
        $isFallbackOk = Invoke-DownloadWithRetry -Uri $Uri -OutFile $OutFile -Label $displayLabel
        if (-not $isFallbackOk) {
            Write-FileError -FilePath $OutFile -Operation "fallback-download" -Reason "Both aria2c install and Invoke-DownloadWithRetry failed for $Uri" -Module "Invoke-FastDownload"
        }
        return $isFallbackOk
    }

    Write-Log "[fast-download] aria2c $Splits splits, $pieceArg pieces -- $displayLabel" -Level "info"

    $outFileName = [System.IO.Path]::GetFileName($OutFile)
    $arguments = @(
        "-x$Splits",
        "-s$Splits",
        "-k$pieceArg",
        "--min-split-size=$pieceArg",
        "--file-allocation=none",
        "--max-tries=3",
        "--retry-wait=5",
        "--timeout=60",
        "--continue=true",
        "--auto-file-renaming=false",
        "--console-log-level=error",
        "--show-console-readout=false",
        "--summary-interval=1",
        "-d", $outDir,
        "-o", $outFileName,
        $Uri
    )

    $exitCode = Invoke-Aria2WithProgressBar -Arguments $arguments -Label $displayLabel

    $isExitOk = $exitCode -eq 0
    if (-not $isExitOk) {
        Write-Log "[fast-download] aria2c exit=$exitCode for $displayLabel -- attempting fallback" -Level "warn"
        $isFallbackOk = Invoke-DownloadWithRetry -Uri $Uri -OutFile $OutFile -Label $displayLabel
        if (-not $isFallbackOk) {
            Write-FileError -FilePath $OutFile -Operation "download" -Reason "aria2c exit=$exitCode and fallback also failed for $Uri" -Module "Invoke-FastDownload"
        }
        return $isFallbackOk
    }

    $isPresent = Test-Path -LiteralPath $OutFile
    if (-not $isPresent) {
        Write-FileError -FilePath $OutFile -Operation "verify" -Reason "file missing after aria2c reported success" -Module "Invoke-FastDownload"
        return $false
    }
    $size = (Get-Item -LiteralPath $OutFile).Length
    if ($size -le 0) {
        Write-FileError -FilePath $OutFile -Operation "verify" -Reason "file empty (0 bytes) after aria2c reported success" -Module "Invoke-FastDownload"
        return $false
    }

    Write-Log "[fast-download] OK $displayLabel ($size bytes) -> $OutFile" -Level "success"
    return $true
}
