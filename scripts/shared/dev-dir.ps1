<#
.SYNOPSIS
    Shared dev directory resolution and initialization.

.DESCRIPTION
    Provides functions to resolve the base dev directory using smart drive
    selection. Priority: E:\dev > D:\dev > best non-system drive > prompt.
    Each candidate drive must exist and have at least 10 GB free space.
#>

# -- Bootstrap shared helpers --------------------------------------------------
$loggingPath = Join-Path $PSScriptRoot "logging.ps1"
if ((Test-Path $loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $loggingPath
}

if (-not (Get-Variable -Name SharedLogMessages -Scope Script -ErrorAction SilentlyContinue)) {
    $sharedLogPath = Join-Path $PSScriptRoot "log-messages.json"
    if (Test-Path $sharedLogPath) {
        $script:SharedLogMessages = Get-Content $sharedLogPath -Raw | ConvertFrom-Json
    }
}

# -- Constants -----------------------------------------------------------------
# Default minimum free space (GB) required for the dev directory. Per-tool
# scripts can override this by either:
#   (a) setting $env:SCRIPTS_FIXER_MIN_FREE_GB (numeric, GB) before calling
#       Resolve-SmartDevDir / Resolve-DevDir, or
#   (b) passing -MinFreeGB <N> to those functions explicitly.
# Rationale: large tools (model downloads, Docker, JDK + IDE) need lots of
# free space; lightweight tools (pip, git, sqlite client) need a few hundred MB
# at most -- so demanding 10 GB everywhere makes the script refuse to install
# on perfectly capable boxes.
$script:MinFreeSpaceGB = 10

function Get-EffectiveMinFreeGB {
    param([double]$Override = 0)
    if ($Override -gt 0) { return $Override }
    $envVal = $env:SCRIPTS_FIXER_MIN_FREE_GB
    if (-not [string]::IsNullOrWhiteSpace($envVal)) {
        $parsed = 0.0
        if ([double]::TryParse($envVal, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    }
    return $script:MinFreeSpaceGB
}

function Get-DevPathFile {
    return Join-Path (Split-Path $PSScriptRoot -Parent) "dev-path.json"
}

function Get-SavedDevPath {
    $devPathFile = Get-DevPathFile
    $isFilePresent = Test-Path $devPathFile
    if (-not $isFilePresent) { return $null }
    try {
        $data = Get-Content $devPathFile -Raw | ConvertFrom-Json
        $hasPath = -not [string]::IsNullOrWhiteSpace($data.path)
        if ($hasPath) { return $data.path }
    } catch {}
    return $null
}

function Set-SavedDevPath {
    param([string]$Path)
    $devPathFile = Get-DevPathFile
    @{ path = $Path } | ConvertTo-Json -Depth 1 | Set-Content -Path $devPathFile -Encoding UTF8
}

function Remove-SavedDevPath {
    $devPathFile = Get-DevPathFile
    $isFilePresent = Test-Path $devPathFile
    if ($isFilePresent) { Remove-Item $devPathFile -Force }
}

function Get-SafeDevDirFallback {
    $systemDrive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C:" } else { $env:SystemDrive.TrimEnd('\') }
    return "$systemDrive\dev-tool"
}

function Test-DriveQualified {
    <#
    .SYNOPSIS
        Returns $true if the given drive letter exists and has at least
        $script:MinFreeSpaceGB free space.

        -Speculative indicates this is an auto-detection probe of a *preferred
        default* drive (E:, D:) rather than a user-forced path. When set, a
        not-ready or not-present drive is logged at `info` rather than `warn`,
        because falling back to the next candidate is the intended behavior.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter,
        [switch]$Speculative,
        [double]$MinFreeGB = 0
    )

    $slm = $script:SharedLogMessages
    $effectiveMin = Get-EffectiveMinFreeGB -Override $MinFreeGB
    $notReadyLevel = if ($Speculative) { "info" } else { "warn" }
    $drive = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
    $hasDrive = $null -ne $drive
    if (-not $hasDrive) {
        Write-Log ($slm.messages.driveNotFound -replace '\{drive\}', "${DriveLetter}:") -Level "info"
        return $false
    }

    try {
        $driveInfo = New-Object System.IO.DriveInfo("${DriveLetter}:")
        $isDriveReady = $driveInfo.IsReady
        if (-not $isDriveReady) {
            Write-Log ($slm.messages.driveNotReady -replace '\{drive\}', "${DriveLetter}:") -Level $notReadyLevel
            return $false
        }
    } catch {
        Write-Log ($slm.messages.driveNotReady -replace '\{drive\}', "${DriveLetter}:") -Level $notReadyLevel
        return $false
    }

    # Get free space via WMI (more reliable than PSDrive.Free for fixed disks)
    $freeGB = 0
    try {
        $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" -ErrorAction Stop
        $hasVolume = $null -ne $vol -and $null -ne $vol.FreeSpace
        if ($hasVolume) {
            $freeGB = [math]::Round($vol.FreeSpace / 1GB, 1)
        }
    } catch {
        # Fallback to PSDrive
        $hasPsDriveFree = $null -ne $drive.Free
        if ($hasPsDriveFree) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
        }
    }

    # Drives with 0 GB are likely phantom drives (card readers, empty removable media)
    $isPhantomDrive = $freeGB -eq 0
    if ($isPhantomDrive) {
        Write-Log "Drive ${DriveLetter}: reports 0 GB free (likely phantom/empty removable drive) -- skipping" -Level "info"
        return $false
    }

    $hasEnoughSpace = $freeGB -ge $effectiveMin
    if (-not $hasEnoughSpace) {
        Write-Log ($slm.messages.driveLowSpace -replace '\{drive\}', "${DriveLetter}:" -replace '\{free\}', $freeGB -replace '\{min\}', $effectiveMin) -Level "warn"
        return $false
    }

    Write-Log ($slm.messages.driveQualified -replace '\{drive\}', "${DriveLetter}:" -replace '\{free\}', $freeGB) -Level "info"
    return $true
}

function Find-BestDevDrive {
    <#
    .SYNOPSIS
        Selects the best drive for the dev directory using this priority:
        1. E: drive (preferred)
        2. D: drive (secondary)
        3. Any other non-system fixed drive with the most free space
        Returns the drive letter (e.g. "E") or $null if none qualifies.
    #>
    param([double]$MinFreeGB = 0)

    $slm = $script:SharedLogMessages
    $effectiveMin = Get-EffectiveMinFreeGB -Override $MinFreeGB
    Write-Log "$($slm.messages.driveAutoDetecting) (minFreeGB=$effectiveMin)" -Level "info"

    # Priority 1: E: drive (preferred default -- speculative probe, silent fallback)
    $isEQualified = Test-DriveQualified -DriveLetter "E" -Speculative -MinFreeGB $effectiveMin
    if ($isEQualified) {
        Write-Log ($slm.messages.drivePreferred -replace '\{drive\}', "E:") -Level "success"
        return "E"
    }

    # Priority 2: D: drive (preferred default -- speculative probe, silent fallback)
    $isDQualified = Test-DriveQualified -DriveLetter "D" -Speculative -MinFreeGB $effectiveMin
    if ($isDQualified) {
        Write-Log ($slm.messages.drivePreferred -replace '\{drive\}', "D:") -Level "success"
        return "D"
    }

    # Priority 3: Any other non-system fixed drive with most free space
    Write-Log $slm.messages.driveScanningOthers -Level "info"
    $systemDriveLetter = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { "C" } else { $env:SystemDrive.TrimEnd('\').Substring(0, 1) }

    $fixedDisks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    $candidates = @()
    foreach ($disk in $fixedDisks) {
        $letter = $disk.DeviceID.Substring(0, 1)
        $isSystemDrive = $letter -eq $systemDriveLetter
        $isAlreadyChecked = $letter -eq "E" -or $letter -eq "D"
        if ($isSystemDrive -or $isAlreadyChecked) { continue }

        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        $hasEnoughSpace = $freeGB -ge $effectiveMin
        if ($hasEnoughSpace) {
            $candidates += [PSCustomObject]@{ Letter = $letter; FreeGB = $freeGB }
        }
    }

    $hasCandidates = $candidates.Count -gt 0
    if ($hasCandidates) {
        $best = $candidates | Sort-Object FreeGB -Descending | Select-Object -First 1
        Write-Log ($slm.messages.driveAutoSelected -replace '\{drive\}', "$($best.Letter):" -replace '\{free\}', $best.FreeGB) -Level "success"
        return $best.Letter
    }

    Write-Log $slm.messages.driveNoneQualified -Level "warn"
    return $null
}

function Get-DevDriveCacheFile {
    # Repo root = parent of scripts/ which is parent of scripts/shared/
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $cacheDir = Join-Path $repoRoot ".resolved"
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force -Confirm:$false | Out-Null
    }
    return Join-Path $cacheDir "dev-drive-cache.json"
}

function Get-CachedDevDir {
    <#
    .SYNOPSIS
        Reads the cached smart-detected dev dir from .dev-drive-cache.json.
        Returns the cached path if the drive is still present + ready,
        otherwise $null (cache is treated as stale).
    #>
    $cacheFile = Get-DevDriveCacheFile
    if (-not (Test-Path $cacheFile)) { return $null }

    try {
        $data = Get-Content $cacheFile -Raw | ConvertFrom-Json
        $cachedPath = $data.path
        if ([string]::IsNullOrWhiteSpace($cachedPath)) { return $null }

        # Validate the cached drive is still usable
        $isDriveQualifiedPath = $cachedPath -match '^[A-Za-z]:\\'
        if ($isDriveQualifiedPath) {
            $driveLetter = $cachedPath.Substring(0, 1)
            try {
                $driveInfo = New-Object System.IO.DriveInfo("${driveLetter}:")
                if (-not $driveInfo.IsReady) { return $null }
            } catch { return $null }
        }
        return $cachedPath
    } catch {
        return $null
    }
}

function Save-CachedDevDir {
    param([Parameter(Mandatory)][string]$Path)
    $cacheFile = Get-DevDriveCacheFile
    try {
        @{
            path       = $Path
            cachedAt   = (Get-Date).ToString("o")
            cachedBy   = "Resolve-SmartDevDir"
        } | ConvertTo-Json -Depth 2 | Set-Content -Path $cacheFile -Encoding UTF8
    } catch {
        # Non-fatal: caching is best-effort
    }
}

function Resolve-SmartDevDir {
    <#
    .SYNOPSIS
        Smart dev directory resolution. Finds the best drive automatically,
        falls back to prompting the user if no drive qualifies.
        Result is cached to .dev-drive-cache.json (gitignored) so subsequent
        runs skip drive probing entirely while the cached drive remains ready.
        Returns a path like "E:\dev-tool".

    .PARAMETER MinFreeGB
        Per-tool override for the minimum free space requirement (GB). When
        omitted, falls back to $env:SCRIPTS_FIXER_MIN_FREE_GB and then to
        the global default of 10 GB. Use a low value (e.g. 0.5 for pip,
        2 for git, 4 for JDK) so lightweight tools install on boxes that
        a 10 GB-class tool would correctly reject.
    #>
    param([double]$MinFreeGB = 0)

    $slm = $script:SharedLogMessages
    $effectiveMin = Get-EffectiveMinFreeGB -Override $MinFreeGB

    # Cache hit -- skip detection entirely
    $cached = Get-CachedDevDir
    if ($null -ne $cached) {
        Write-Log "Using cached dev dir: $cached (.dev-drive-cache.json)" -Level "info"
        return $cached
    }

    $bestDrive = Find-BestDevDrive -MinFreeGB $effectiveMin
    $hasBestDrive = $null -ne $bestDrive
    if ($hasBestDrive) {
        $resolved = "${bestDrive}:\dev-tool"
        Save-CachedDevDir -Path $resolved
        return $resolved
    }

    # ── Auto-pick largest-free drive when nothing meets the bar ──────────
    # Previous behaviour was to prompt the user every time. That made small
    # installers (pip, git, sqlite) un-installable on boxes where the only
    # non-system drive had 5-9 GB free even though they need < 1 GB.
    # New behaviour: pick the fixed drive with the MOST free space across
    # ALL fixed drives (including system drive) as long as it has at least
    # the per-tool minimum. Log a clear WARN so users know the fallback ran.
    $fixedDisks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    $allCandidates = @()
    foreach ($disk in $fixedDisks) {
        $letter = $disk.DeviceID.Substring(0, 1)
        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        if ($freeGB -ge $effectiveMin) {
            $allCandidates += [PSCustomObject]@{ Letter = $letter; FreeGB = $freeGB }
        }
    }
    if ($allCandidates.Count -gt 0) {
        $best = $allCandidates | Sort-Object FreeGB -Descending | Select-Object -First 1
        Write-Log "Auto-picked largest-free drive $($best.Letter): ($($best.FreeGB) GB free, minFreeGB=$effectiveMin) -- no preferred drive qualified" -Level "warn"
        $resolved = "$($best.Letter):\dev-tool"
        Save-CachedDevDir -Path $resolved
        return $resolved
    }

    $isAutoYes = $env:SCRIPTS_AUTO_YES -eq '1'
    if ($isAutoYes) {
        $fallbackPath = Get-SafeDevDirFallback
        Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
        Save-CachedDevDir -Path $fallbackPath
        return $fallbackPath
    }

    # No qualified drive found anywhere -- prompt user
    Write-Host ""
    Write-Host "  No drive with $effectiveMin GB free space found (checked E:, D:, others)." -ForegroundColor Yellow
    Write-Host "  Available fixed drives:" -ForegroundColor Cyan

    foreach ($disk in $fixedDisks) {
        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
        Write-Host "    $($disk.DeviceID) -- $freeGB GB free" -ForegroundColor White
    }

    Write-Host ""
    $userInput = Read-Host -Prompt "Enter dev directory path (e.g. C:\dev-tool, F:\dev-tool)"
    $hasUserInput = -not [string]::IsNullOrWhiteSpace($userInput)
    if ($hasUserInput) {
        Write-Log ($slm.messages.devDirUserProvided -replace '\{path\}', $userInput) -Level "info"
        Save-CachedDevDir -Path $userInput
        return $userInput
    }

    # Last resort fallback
    $fallbackPath = Get-SafeDevDirFallback
    Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
    Save-CachedDevDir -Path $fallbackPath
    return $fallbackPath
}

function Resolve-UsableDevDir {
    param(
        [string]$PathValue
    )

    $slm = $script:SharedLogMessages
    $isPathMissing = [string]::IsNullOrWhiteSpace($PathValue)
    if ($isPathMissing) {
        $fallbackPath = Get-SafeDevDirFallback
        Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
        return $fallbackPath
    }

    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($PathValue.Trim())
    Write-Log ($slm.messages.devDirExpanded -replace '\{path\}', $expandedPath) -Level "info"

    try {
        $fullPath = [System.IO.Path]::GetFullPath($expandedPath)
    } catch {
        Write-Log ($slm.messages.devDirInvalid -replace '\{path\}', $expandedPath) -Level "warn"
        $fallbackPath = Get-SafeDevDirFallback
        Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
        return $fallbackPath
    }

    $isDriveQualifiedPath = $fullPath -match '^[A-Za-z]:\\'
    if ($isDriveQualifiedPath) {
        $driveName = $fullPath.Substring(0, 1)
        $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        $hasDrive = $null -ne $drive
        $isDriveMissing = -not $hasDrive
        if ($isDriveMissing) {
            Write-Log ($slm.messages.devDirDriveMissing -replace '\{path\}', $fullPath) -Level "warn"
            $fallbackPath = Get-SafeDevDirFallback
            Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
            return $fallbackPath
        }

        try {
            $driveInfo = New-Object System.IO.DriveInfo("${driveName}:")
            $isDriveReady = $driveInfo.IsReady
            if (-not $isDriveReady) {
                Write-Log ($slm.messages.devDirDriveNotReady -replace '\{path\}', $fullPath) -Level "warn"
                $fallbackPath = Get-SafeDevDirFallback
                Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
                return $fallbackPath
            }
        } catch {
            Write-Log ($slm.messages.devDirDriveNotReady -replace '\{path\}', $fullPath) -Level "warn"
            $fallbackPath = Get-SafeDevDirFallback
            Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
            return $fallbackPath
        }
    }

    return $fullPath
}

function Resolve-DevDir {
    <#
    .SYNOPSIS
        Resolves the dev directory path from (in priority order):
        1. $env:DEV_DIR (set by orchestrator)
        2. Config override value
        3. Smart drive detection (E: > D: > best drive > prompt)
        4. Config default value (legacy fallback)

        Accepts -DevDirConfig or -Config (alias).
    #>
    param(
        [Parameter(Position = 0)]
        [PSCustomObject]$DevDirConfig,

        [PSCustomObject]$Config
    )

    $slm = $script:SharedLogMessages

    # Support -Config alias
    if ($Config -and -not $DevDirConfig) { $DevDirConfig = $Config }

    # Check environment variable first (set by orchestrator)
    $hasDevDirEnv = -not [string]::IsNullOrWhiteSpace($env:DEV_DIR)
    if ($hasDevDirEnv) {
        Write-Log ($slm.messages.devDirFromEnv -replace '\{path\}', $env:DEV_DIR) -Level "success"
        return Resolve-UsableDevDir -PathValue $env:DEV_DIR
    }

    # Check saved dev path (set via .\run.ps1 path <dir>)
    $savedPath = Get-SavedDevPath
    $hasSavedPath = $null -ne $savedPath
    if ($hasSavedPath) {
        Write-Log ($slm.messages.devDirSavedPathLoaded -replace '\{path\}', $savedPath) -Level "success"
        return Resolve-UsableDevDir -PathValue $savedPath
    }

    $hasNoConfig = -not $DevDirConfig
    if ($hasNoConfig) {
        # No config -- use smart drive detection
        return Resolve-SmartDevDir
    }

    $overridePath = if ($DevDirConfig.override) { $DevDirConfig.override } else { "" }

    # Config override takes precedence
    $hasOverride = -not [string]::IsNullOrWhiteSpace($overridePath)
    if ($hasOverride) {
        Write-Log ($slm.messages.devDirOverride -replace '\{path\}', $overridePath) -Level "info"
        return Resolve-UsableDevDir -PathValue $overridePath
    }

    # Smart drive detection (replaces hardcoded default)
    $isSmartMode = $DevDirConfig.mode -eq "json-or-prompt" -or $DevDirConfig.mode -eq "smart"
    if ($isSmartMode) {
        return Resolve-SmartDevDir
    }

    # Legacy fallback: use config default
    $defaultPath = if ($DevDirConfig.default) { $DevDirConfig.default } else { Get-SafeDevDirFallback }
    Write-Log ($slm.messages.devDirDefault -replace '\{path\}', $defaultPath) -Level "info"
    return Resolve-UsableDevDir -PathValue $defaultPath
}

function Initialize-DevDir {
    <#
    .SYNOPSIS
        Creates the dev directory and standard subdirectories if they don't exist.
        Accepts -DevDir or -Path (alias).
    #>
    param(
        [Parameter(Position = 0)]
        [string]$DevDir,

        [string]$Path,

        [string[]]$Subdirectories = @()
    )

    $slm = $script:SharedLogMessages

    # Support -Path alias
    if ($Path -and -not $DevDir) { $DevDir = $Path }

    $DevDir = Resolve-UsableDevDir -PathValue $DevDir
    Write-Log ($slm.messages.devDirInitializing -replace '\{path\}', $DevDir) -Level "info"

    try {
        $isDirMissing = -not (Test-Path $DevDir)
        if ($isDirMissing) {
            New-Item -Path $DevDir -ItemType Directory -Force -Confirm:$false | Out-Null
            Write-Log ($slm.messages.devDirCreated -replace '\{path\}', $DevDir) -Level "success"
        } else {
            Write-Log ($slm.messages.devDirExists -replace '\{path\}', $DevDir) -Level "info"
        }
    } catch {
        Write-Log ($slm.messages.devDirCreateFailed -replace '\{path\}', $DevDir -replace '\{error\}', $_) -Level "warn"
        $fallbackPath = Get-SafeDevDirFallback
        $isSameFallback = $fallbackPath -eq $DevDir
        if ($isSameFallback) {
            throw
        }

        Write-Log ($slm.messages.devDirFallback -replace '\{path\}', $fallbackPath) -Level "warn"
        $isFallbackMissing = -not (Test-Path $fallbackPath)
        if ($isFallbackMissing) {
            New-Item -Path $fallbackPath -ItemType Directory -Force -Confirm:$false | Out-Null
            Write-Log ($slm.messages.devDirCreated -replace '\{path\}', $fallbackPath) -Level "success"
        }
        $DevDir = $fallbackPath
    }

    foreach ($sub in $Subdirectories) {
        $subPath = Join-Path $DevDir $sub
        $isSubMissing = -not (Test-Path $subPath)
        if ($isSubMissing) {
            New-Item -Path $subPath -ItemType Directory -Force -Confirm:$false | Out-Null
            Write-Log ($slm.messages.devDirSubCreated -replace '\{name\}', $sub) -Level "success"
        }
    }

    return $DevDir
}
