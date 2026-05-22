<#
.SYNOPSIS
    Shared disk-space pre-check helper. Warns or aborts if the target drive
    does not have enough free space before starting large downloads.
#>

# -- Bootstrap shared helpers --------------------------------------------------
$loggingPath = Join-Path $PSScriptRoot "logging.ps1"
if ((Test-Path $loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $loggingPath
}

function Test-DiskSpace {
    <#
    .SYNOPSIS
        Checks if the target path's drive has enough free space.
        Returns $true if sufficient, $false if below threshold.
    .PARAMETER TargetPath
        Directory where files will be written. Drive letter is extracted automatically.
    .PARAMETER RequiredBytes
        Minimum free bytes needed.
    .PARAMETER RequiredGB
        Minimum free GB needed (alternative to RequiredBytes). If both set, RequiredBytes wins.
    .PARAMETER Label
        Friendly name for log messages (e.g. "llama.cpp executables").
    .PARAMETER WarnOnly
        If set, logs a warning but still returns $true (non-blocking).
        Default is $false (blocking -- returns $false when space is insufficient).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [long]$RequiredBytes = 0,

        [double]$RequiredGB = 0,

        [string]$Label = "download",

        [switch]$WarnOnly
    )

    # Resolve required bytes
    $needed = $RequiredBytes
    $hasGBParam = $RequiredGB -gt 0
    $hasBytesParam = $RequiredBytes -gt 0
    if (-not $hasBytesParam -and $hasGBParam) {
        $needed = [long]($RequiredGB * 1073741824)
    }

    $isNoThreshold = $needed -le 0
    if ($isNoThreshold) {
        Write-Log "No disk space threshold specified for $Label -- skipping check" -Level "info"
        return $true
    }

    # Resolve drive from target path (PS 5.1 compatible -- no ?? operator)
    try {
        $convertedPath = Convert-Path -Path $TargetPath -ErrorAction SilentlyContinue
        $pathForRoot = if ([string]::IsNullOrWhiteSpace($convertedPath)) { $TargetPath } else { $convertedPath }
        $resolvedRoot = [System.IO.Path]::GetPathRoot($pathForRoot)
        if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
            $resolvedRoot = [System.IO.Path]::GetPathRoot($TargetPath)
        }
    } catch {
        $resolvedRoot = [System.IO.Path]::GetPathRoot($TargetPath)
    }

    # Get free space
    $drive = Get-PSDrive -Name ($resolvedRoot.TrimEnd(':\')) -ErrorAction SilentlyContinue
    $hasDrive = $null -ne $drive
    if (-not $hasDrive) {
        # Fallback: use WMI/CIM
        $driveLetter = $resolvedRoot.Substring(0, 1)
        $diskInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${driveLetter}:'" -ErrorAction SilentlyContinue
        $hasDiskInfo = $null -ne $diskInfo
        if (-not $hasDiskInfo) {
            Write-Log "Could not determine free space for drive $resolvedRoot -- proceeding anyway" -Level "warn"
            return $true
        }
        $freeBytes = $diskInfo.FreeSpace
    } else {
        $freeBytes = $drive.Free
    }

    $freeGB = [math]::Round($freeBytes / 1073741824, 2)
    $neededGB = [math]::Round($needed / 1073741824, 2)

    $isSufficient = $freeBytes -ge $needed
    if ($isSufficient) {
        Write-Log "Disk space OK for $Label -- ${freeGB} GB free, ${neededGB} GB needed on $resolvedRoot" -Level "info"
        return $true
    }

    # Insufficient space
    $shortfallGB = [math]::Round(($needed - $freeBytes) / 1073741824, 2)
    $message = "Insufficient disk space for $Label on ${resolvedRoot}: ${freeGB} GB free, ${neededGB} GB needed (short by ${shortfallGB} GB)"

    if ($WarnOnly) {
        Write-Log $message -Level "warn"
        return $true
    }

    Write-Log $message -Level "error"
    return $false
}

function Get-TotalDownloadSize {
    <#
    .SYNOPSIS
        Sums expected download sizes from a list of items with sizeHint or expectedSizeBytes fields.
        Returns total bytes.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Items,

        [string]$SizeBytesField = "expectedSizeBytes",
        [string]$SizeHintField = "sizeHint"
    )

    $totalBytes = [long]0
    foreach ($item in $Items) {
        $hasExactSize = $item.PSObject.Properties[$SizeBytesField] -and $item.$SizeBytesField -gt 0
        if ($hasExactSize) {
            $totalBytes += $item.$SizeBytesField
            continue
        }

        # Parse sizeHint like "~5 GB" or "~4.7 GB"
        $hasHint = $item.PSObject.Properties[$SizeHintField] -and -not [string]::IsNullOrWhiteSpace($item.$SizeHintField)
        if ($hasHint) {
            $hint = $item.$SizeHintField
            $match = [regex]::Match($hint, '~?([\d.]+)\s*(GB|MB)', 'IgnoreCase')
            $isMatch = $match.Success
            if ($isMatch) {
                $value = [double]$match.Groups[1].Value
                $unit = $match.Groups[2].Value.ToUpper()
                if ($unit -eq "GB") {
                    $totalBytes += [long]($value * 1073741824)
                } elseif ($unit -eq "MB") {
                    $totalBytes += [long]($value * 1048576)
                }
            }
        }
    }

    return $totalBytes
}
