# --------------------------------------------------------------------------
#  GitHub Desktop helper functions
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}


function Install-GitHubDesktop {
    param(
        $Config,
        $LogMessages
    )

    $packageName = $Config.chocoPackageName

    # GitHub Desktop installs to AppData -- check common locations
    $ghDesktop = Get-Command "GitHubDesktop" -ErrorAction SilentlyContinue
    $isCommandMissing = -not $ghDesktop
    if ($isCommandMissing) {
        $localAppPath = Join-Path $env:LOCALAPPDATA "GitHubDesktop\GitHubDesktop.exe"
        $isLocalAppFound = Test-Path $localAppPath
        if ($isLocalAppFound) { $ghDesktop = $true }
    }

    if ($ghDesktop) {
        # Get version from choco list
        $chocoVersion = (choco list --local-only --exact $packageName 2>&1 | Select-String $packageName) -replace ".*$packageName\s*", "" | ForEach-Object { $_.Trim() }

        # Check .installed/ tracking
        $isAlreadyTracked = $chocoVersion -and (Test-AlreadyInstalled -Name "github-desktop" -CurrentVersion $chocoVersion)
        if ($isAlreadyTracked) {
            Write-Log $LogMessages.messages.ghDesktopAlreadyInstalled -Level "info"
            return
        }

        Write-Log $LogMessages.messages.ghDesktopAlreadyInstalled -Level "info"

        if ($Config.alwaysUpgradeToLatest) {
            try {
                Write-Log $LogMessages.messages.ghDesktopUpgrading -Level "info"
                Upgrade-ChocoPackage -PackageName $packageName
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                Write-Log $LogMessages.messages.ghDesktopUpgradeSuccess -Level "success"
            } catch {
                Write-Log "GitHub Desktop upgrade failed: $_" -Level "error"
                Save-InstalledError -Name "github-desktop" -ErrorMessage "$_"
            }
        }

        $newVersion = (choco list --local-only --exact $packageName 2>&1 | Select-String $packageName) -replace ".*$packageName\s*", "" | ForEach-Object { $_.Trim() }
        $isVersionEmpty = [string]::IsNullOrWhiteSpace($newVersion)
        if ($isVersionEmpty) { $newVersion = "(version pending)" }
        Save-InstalledRecord -Name "github-desktop" -Version $newVersion
    }
    else {
        Write-Log $LogMessages.messages.ghDesktopNotFound -Level "info"
        try {
            Install-ChocoPackage -PackageName $packageName
            Write-Log $LogMessages.messages.ghDesktopInstallSuccess -Level "success"

            $newVersion = (choco list --local-only --exact $packageName 2>&1 | Select-String $packageName) -replace ".*$packageName\s*", "" | ForEach-Object { $_.Trim() }
            if ($newVersion) { Save-InstalledRecord -Name "github-desktop" -Version $newVersion }
        } catch {
            Write-Log "GitHub Desktop install failed: $_" -Level "error"
            Save-InstalledError -Name "github-desktop" -ErrorMessage "$_"
        }
    }
}

function Add-ReposToGitHubDesktop {
    <#
    .SYNOPSIS
        Scans configured folders for Git repositories and adds them
        to GitHub Desktop's internal repo list.
        GitHub Desktop stores repos in a JSON file under %APPDATA%.
    #>
    param(
        [PSCustomObject]$ScanConfig,
        $LogMessages
    )

    $isDisabled = -not $ScanConfig.enabled
    if ($isDisabled) {
        Write-Log $LogMessages.messages.scanDisabled -Level "info"
        return
    }

    Write-Log $LogMessages.messages.scanStarting -Level "info"
    Write-Host ""

    # Build exclusion list
    $excludePatterns = @()
    $hasExclusions = $null -ne $ScanConfig.excludePatterns -and $ScanConfig.excludePatterns.Count -gt 0
    if ($hasExclusions) {
        $excludePatterns = @($ScanConfig.excludePatterns)
    }

    $maxDepth = 2
    $hasMaxDepth = $null -ne $ScanConfig.maxDepth
    if ($hasMaxDepth) { $maxDepth = $ScanConfig.maxDepth }

    # Discover all Git repos across configured folders
    $discoveredRepos = New-Object System.Collections.ArrayList

    foreach ($folder in $ScanConfig.paths) {
        $isFolderMissing = -not (Test-Path $folder)
        if ($isFolderMissing) {
            Write-Log ($LogMessages.messages.scanFolderMissing -replace '\{path\}', $folder) -Level "warn"
            continue
        }

        Write-Log ($LogMessages.messages.scanFolder -replace '\{path\}', $folder -replace '\{depth\}', $maxDepth) -Level "info"

        # Recursive scan for .git folders up to maxDepth
        $gitDirs = Find-GitRepos -RootPath $folder -MaxDepth $maxDepth -ExcludePatterns $excludePatterns
        foreach ($gitDir in $gitDirs) {
            $repoPath = Split-Path -Parent $gitDir
            [void]$discoveredRepos.Add($repoPath)
            Write-Log ($LogMessages.messages.scanFoundRepo -replace '\{path\}', $repoPath) -Level "info"
        }
    }

    $hasNoRepos = $discoveredRepos.Count -eq 0
    if ($hasNoRepos) {
        Write-Log $LogMessages.messages.scanNoRepos -Level "info"
        return
    }

    # Load existing GitHub Desktop repo list
    $ghDesktopDataDir = Join-Path $env:APPDATA "GitHub Desktop"
    $repoListPath = Join-Path $ghDesktopDataDir "repositories.json"

    $existingRepos = @()
    $isRepoListPresent = Test-Path $repoListPath
    if ($isRepoListPresent) {
        try {
            $raw = Get-Content $repoListPath -Raw -ErrorAction Stop
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            $isArray = $parsed -is [System.Array]
            if ($isArray) {
                $existingRepos = @($parsed)
            }
        } catch {
            Write-Log "Could not parse existing repositories.json, will create fresh: $_" -Level "warn"
            $existingRepos = @()
        }
    }

    # Normalise existing paths for comparison
    $existingPaths = @()
    foreach ($entry in $existingRepos) {
        $hasPath = $null -ne $entry.path
        if ($hasPath) {
            $existingPaths += $entry.path.Replace("/", "\").TrimEnd("\").ToLower()
        }
    }

    # Add new repos
    $addedCount = 0
    $skippedCount = 0

    foreach ($repoPath in $discoveredRepos) {
        $normPath = $repoPath.Replace("/", "\").TrimEnd("\").ToLower()
        $isAlreadyTracked = $existingPaths -contains $normPath
        if ($isAlreadyTracked) {
            Write-Log ($LogMessages.messages.scanRepoAlreadyAdded -replace '\{path\}', $repoPath) -Level "info"
            $skippedCount++
            continue
        }

        # GitHub Desktop repo entry format
        $newEntry = @{
            path = $repoPath.Replace("\", "/")
        }
        $existingRepos += $newEntry
        $addedCount++
        Write-Log ($LogMessages.messages.scanRepoAdded -replace '\{path\}', $repoPath) -Level "success"
    }

    # Write updated repo list
    if ($addedCount -gt 0) {
        try {
            $isDataDirMissing = -not (Test-Path $ghDesktopDataDir)
            if ($isDataDirMissing) {
                New-Item -Path $ghDesktopDataDir -ItemType Directory -Force | Out-Null
            }
            $jsonOutput = $existingRepos | ConvertTo-Json -Depth 4
            # Ensure array wrapper for single item
            $isSingleItem = $existingRepos.Count -eq 1
            if ($isSingleItem) {
                $jsonOutput = "[$jsonOutput]"
            }
            Set-Content -Path $repoListPath -Value $jsonOutput -Encoding UTF8
        } catch {
            Write-FileError -FilePath $repoListPath -Operation "write" -Reason "$_" -Module "Add-ReposToGitHubDesktop"
            Write-Log ($LogMessages.messages.scanWriteError -replace '\{error\}', "$_") -Level "error"
            return
        }
    }

    Write-Host ""
    $summary = $LogMessages.messages.scanSummary -replace '\{found\}', $discoveredRepos.Count -replace '\{added\}', $addedCount -replace '\{skipped\}', $skippedCount
    Write-Log $summary -Level "success"
}

function Find-GitRepos {
    <#
    .SYNOPSIS
        Recursively finds .git directories up to a specified depth,
        skipping excluded folder names.
    #>
    param(
        [string]$RootPath,
        [int]$MaxDepth = 2,
        [string[]]$ExcludePatterns = @()
    )

    $results = New-Object System.Collections.ArrayList

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@{ Path = $RootPath; Depth = 0 })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $currentPath = $current.Path
        $currentDepth = $current.Depth

        $isTooDeep = $currentDepth -gt $MaxDepth
        if ($isTooDeep) { continue }

        # Check if this folder has .git
        $gitPath = Join-Path $currentPath ".git"
        $hasGit = Test-Path $gitPath
        if ($hasGit) {
            [void]$results.Add($gitPath)
            continue  # Don't recurse into repos (nested repos are unusual)
        }

        # Recurse into subdirectories
        $isAtMaxDepth = $currentDepth -eq $MaxDepth
        if ($isAtMaxDepth) { continue }

        try {
            $subdirs = Get-ChildItem -Path $currentPath -Directory -ErrorAction SilentlyContinue
        } catch {
            continue
        }

        foreach ($sub in $subdirs) {
            $folderName = $sub.Name
            $isExcluded = $false
            foreach ($pattern in $ExcludePatterns) {
                $isMatch = $folderName -like $pattern
                if ($isMatch) { $isExcluded = $true; break }
            }
            $shouldSkip = $isExcluded -or $folderName.StartsWith(".")
            if ($shouldSkip) { continue }

            $queue.Enqueue(@{ Path = $sub.FullName; Depth = $currentDepth + 1 })
        }
    }

    return $results
}

function Uninstall-GitHubDesktop {
    <#
    .SYNOPSIS
        Full GitHub Desktop uninstall: choco uninstall, purge tracking.
    #>
    param(
        $Config,
        $LogMessages
    )

    $packageName = $Config.chocoPackageName

    # 1. Uninstall via Chocolatey
    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "GitHub Desktop") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $packageName
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "GitHub Desktop") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "GitHub Desktop") -Level "error"
    }

    # 2. Remove tracking records
    Remove-InstalledRecord -Name "github-desktop"
    Remove-ResolvedData -ScriptFolder "08-install-github-desktop"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
