# --------------------------------------------------------------------------
#  Helper: Install VLC + repair file associations
#  Fixes the Windows "failed to launch player" error caused by:
#    1. Stale 32-bit pointer (C:\Program Files (x86)\VideoLAN\VLC\vlc.exe)
#       lingering after a 64-bit choco reinstall.
#    2. The --one-instance flag choking on UNC / mapped network paths
#       (e.g. Z:\DownloadRelated\...) when no first instance is running.
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

function Get-VlcPath {
    param([Parameter(Mandatory)] $VlcConfig)

    $candidates = @($VlcConfig.associationRepair.candidatePaths)
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }

    $cmd = Get-Command vlc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-Vlc {
    param(
        [Parameter(Mandatory)] $VlcConfig,
        [Parameter(Mandatory)] $LogMessages
    )

    $msgs = $LogMessages.messages

    Write-Log $msgs.checking -Level "info"
    $existing = Get-VlcPath -VlcConfig $VlcConfig
    if ($existing) {
        Write-Log ($msgs.alreadyInstalled -replace '\{path\}', $existing) -Level "info"
    } else {
        Write-Log $msgs.notFound -Level "info"
        Write-Log $msgs.installing -Level "info"
        try {
            Install-ChocoPackage -PackageName $VlcConfig.chocoPackage | Out-Null
        } catch {
            Write-Log ($msgs.installFailed -replace '\{error\}', $_.Exception.Message) -Level "error"
            return $false
        }
        $existing = Get-VlcPath -VlcConfig $VlcConfig
        if (-not $existing) {
            Write-Log $msgs.verifyFailed -Level "error"
            return $false
        }
        Write-Log ($msgs.installSuccess -replace '\{path\}', $existing) -Level "success"
    }

    Repair-VlcAssociations -VlcConfig $VlcConfig -LogMessages $LogMessages -ResolvedExe $existing | Out-Null
    Set-VlcPreferences      -VlcConfig $VlcConfig -LogMessages $LogMessages | Out-Null
    return $true
}

function Get-VlcUserProfilePaths {
    param([switch]$AllUsers)

    $paths = @()
    if ($AllUsers) {
        $usersRoot = Join-Path $env:SystemDrive "Users"
        if (Test-Path -LiteralPath $usersRoot) {
            Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $name = $_.Name
                if ($name -in @('Public','Default','Default User','All Users','WDAGUtilityAccount')) { return }
                $appData = Join-Path $_.FullName 'AppData\Roaming'
                if (Test-Path -LiteralPath $appData) {
                    $paths += [pscustomobject]@{ User = $name; VlcDir = (Join-Path $appData 'vlc') }
                }
            }
        }
    }
    if ($paths.Count -eq 0 -and $env:APPDATA) {
        $paths += [pscustomobject]@{ User = $env:USERNAME; VlcDir = (Join-Path $env:APPDATA 'vlc') }
    }
    return ,$paths
}

function Set-VlcrcSetting {
    param(
        [Parameter(Mandatory)] [string]$VlcrcPath,
        [Parameter(Mandatory)] [string]$Key,
        [Parameter(Mandatory)] [string]$Value
    )
    $line = "$Key=$Value"
    if (-not (Test-Path -LiteralPath $VlcrcPath)) {
        $dir = Split-Path -Parent $VlcrcPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $VlcrcPath -Value $line -Encoding UTF8
        return 'created'
    }
    $content = Get-Content -LiteralPath $VlcrcPath -ErrorAction Stop
    $pattern = '^\s*#?\s*' + [regex]::Escape($Key) + '\s*='
    $matched = $false
    $changed = $false
    $newContent = foreach ($l in $content) {
        if (-not $matched -and $l -match $pattern) {
            $matched = $true
            if ($l -ne $line) { $changed = $true; $line } else { $l }
        } else { $l }
    }
    if (-not $matched) {
        $newContent = @($content) + $line
        $changed = $true
    }
    if ($changed) {
        Set-Content -LiteralPath $VlcrcPath -Value $newContent -Encoding UTF8
        return 'updated'
    }
    return 'unchanged'
}

function Set-VlcPreferences {
    param(
        [Parameter(Mandatory)] $VlcConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages

    $prefs = $null
    if ($VlcConfig.PSObject.Properties.Name -contains 'preferences') {
        $prefs = $VlcConfig.preferences
    }
    if (-not $prefs -or -not $prefs.enabled) {
        Write-Log $msgs.prefsDisabled -Level "warn"
        return
    }

    $allUsers = [bool]$prefs.applyToAllUsers
    $scope = if ($allUsers) { "all users" } else { "current user" }
    Write-Log ($msgs.prefsStart -replace '\{scope\}', $scope) -Level "info"

    $targets = Get-VlcUserProfilePaths -AllUsers:$allUsers
    $settings = @{}
    foreach ($p in $prefs.settings.PSObject.Properties) { $settings[$p.Name] = [string]$p.Value }

    $updated = 0; $unchanged = 0; $failed = 0
    foreach ($t in $targets) {
        $vlcrc = Join-Path $t.VlcDir 'vlcrc'
        Write-Log ($msgs.prefsScopeUser -replace '\{user\}', $t.User -replace '\{path\}', $vlcrc) -Level "info"
        foreach ($kv in $settings.GetEnumerator()) {
            try {
                $result = Set-VlcrcSetting -VlcrcPath $vlcrc -Key $kv.Key -Value $kv.Value
                switch ($result) {
                    'created'   { Write-Log ($msgs.prefsCreated -replace '\{path\}', $vlcrc) -Level "success"; $updated++ }
                    'updated'   { Write-Log (($msgs.prefsUpdated -replace '\{key\}', $kv.Key) -replace '\{value\}', $kv.Value -replace '\{path\}', $vlcrc) -Level "success"; $updated++ }
                    'unchanged' { Write-Log (($msgs.prefsAlreadySet -replace '\{key\}', $kv.Key) -replace '\{value\}', $kv.Value -replace '\{path\}', $vlcrc) -Level "info"; $unchanged++ }
                }
            } catch {
                Write-Log (($msgs.prefsFailed -replace '\{path\}', $vlcrc) -replace '\{error\}', $_.Exception.Message) -Level "warn"
                $failed++
            }
        }
    }

    $summary = $msgs.prefsSummary `
        -replace '\{updated\}', $updated `
        -replace '\{unchanged\}', $unchanged `
        -replace '\{failed\}', $failed
    Write-Log $summary -Level "info"
}

function Repair-VlcAssociations {
    param(
        [Parameter(Mandatory)] $VlcConfig,
        [Parameter(Mandatory)] $LogMessages,
        [string]$ResolvedExe
    )

    $msgs = $LogMessages.messages
    $repair = $VlcConfig.associationRepair

    if (-not $repair.enabled) {
        Write-Log $msgs.repairDisabled -Level "warn"
        return
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedExe)) {
        $ResolvedExe = Get-VlcPath -VlcConfig $VlcConfig
    }

    # Prefer 64-bit if both exist
    $preferred = [string]$repair.preferred64BitPath
    if ($preferred -and (Test-Path -LiteralPath $preferred)) {
        $ResolvedExe = $preferred
    }

    if (-not $ResolvedExe -or -not (Test-Path -LiteralPath $ResolvedExe)) {
        Write-FileError -FilePath ($ResolvedExe ? $ResolvedExe : "<vlc.exe>") -Operation "verify" -Reason "vlc.exe not found on disk -- cannot repair associations" -Module "Install-VLC"
        return
    }

    $newCommand = '"{0}" "%1"' -f $ResolvedExe
    Write-Log ($msgs.repairStart -replace '\{path\}', $ResolvedExe) -Level "info"

    $rewritten = 0; $clean = 0; $failed = 0
    foreach ($key in $repair.registryTargets) {
        if (-not (Test-Path -LiteralPath $key)) {
            Write-Log ($msgs.repairKeyMissing -replace '\{key\}', $key) -Level "info"
            $clean++
            continue
        }
        try {
            $current = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)'
            $needsRewrite = $true
            if ($current) {
                $hasOneInstance = $current -match '--one-instance'
                $hasStalePath   = $current -match [regex]::Escape('Program Files (x86)\VideoLAN')
                $needsRewrite = $hasOneInstance -or $hasStalePath -or ($current -notmatch [regex]::Escape($ResolvedExe))
            }

            if ($needsRewrite) {
                Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $newCommand -ErrorAction Stop
                Write-Log (($msgs.repairKeyRewritten -replace '\{key\}', $key) -replace '\{value\}', $newCommand) -Level "success"
                $rewritten++
            } else {
                $clean++
            }
        } catch {
            Write-Log (($msgs.repairKeyFailed -replace '\{key\}', $key) -replace '\{error\}', $_.Exception.Message) -Level "warn"
            $failed++
        }
    }

    $summary = $msgs.repairSummary `
        -replace '\{rewritten\}', $rewritten `
        -replace '\{clean\}', $clean `
        -replace '\{failed\}', $failed
    Write-Log $summary -Level "info"
}

function Uninstall-Vlc {
    param(
        [Parameter(Mandatory)] $VlcConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    Write-Log $msgs.uninstalling -Level "info"
    try {
        & choco uninstall $VlcConfig.chocoPackage -y --no-progress 2>&1 | ForEach-Object { Write-Log $_ -Level "info" }
        Write-Log $msgs.uninstallSuccess -Level "success"
        return $true
    } catch {
        Write-Log ($msgs.uninstallFailed -replace '\{error\}', $_.Exception.Message) -Level "error"
        return $false
    }
}
