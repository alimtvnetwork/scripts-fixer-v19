# --------------------------------------------------------------------------
#  Helper: Install Google Chrome via Chocolatey
#  Falls back to the official Chrome standalone installer when choco fails
#  or the post-install verify cannot find chrome.exe.
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
$_adminCheckPath = Join-Path $_sharedDir "admin-check.ps1"
if ((Test-Path $_adminCheckPath) -and -not (Get-Command Assert-Elevated -ErrorAction SilentlyContinue)) {
    . $_adminCheckPath
}

function Get-ChromePath {
    <#
    .SYNOPSIS
        Searches for chrome.exe in common install locations.
        Returns the path string or $null.
    #>
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Invoke-ChromeOfficialInstaller {
    <#
    .SYNOPSIS
        Downloads the official ChromeStandaloneSetup64.exe and runs it silently.
        Returns @{ ok = $bool; path = "<path or null>"; reason = "<text>" }.
    #>
    param(
        [Parameter(Mandatory)] $Fallback,
        [Parameter(Mandatory)] $LogMessages,
        [Parameter(Mandatory)] [string]$TriggerReason
    )

    $msgs = $LogMessages.messages

    $isFallbackDisabled = -not $Fallback.enabled
    if ($isFallbackDisabled) {
        Write-Log $msgs.fallbackDisabled -Level "error"
        return @{ ok = $false; path = $null; reason = "fallback disabled" }
    }

    $url = [string]$Fallback.url
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-FileError -FilePath "config.json" -Operation "read" -Reason "fallback.url is empty -- cannot download official installer" -Module "Install-Chrome"
        return @{ ok = $false; path = $null; reason = "missing fallback.url" }
    }

    $fileName = [string]$Fallback.fileName
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "ChromeStandaloneSetup64.exe" }

    $downloadDir = [string]$Fallback.downloadDir
    if ([string]::IsNullOrWhiteSpace($downloadDir)) { $downloadDir = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($downloadDir)) { $downloadDir = [System.IO.Path]::GetTempPath() }

    $hasDownloadDir = Test-Path -LiteralPath $downloadDir
    if (-not $hasDownloadDir) {
        try {
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        } catch {
            Write-FileError -FilePath $downloadDir -Operation "mkdir" -Reason "cannot create download dir for fallback installer: $($_.Exception.Message)" -Module "Install-Chrome"
            return @{ ok = $false; path = $null; reason = "mkdir failed" }
        }
    }

    $dest = Join-Path $downloadDir $fileName

    Write-Log ($msgs.fallbackTriggered -replace '\{reason\}', $TriggerReason) -Level "warn"
    Write-Log (($msgs.fallbackDownloading -replace '\{url\}', $url) -replace '\{dest\}', $dest) -Level "info"

    # -- Download ---------------------------------------------------------
    try {
        $previousProgress = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $previousProgress
    } catch {
        Write-FileError -FilePath $dest -Operation "download" -Reason "Invoke-WebRequest from $url failed: $($_.Exception.Message)" -Module "Install-Chrome"
        Write-Log (($msgs.fallbackDownloadFailed -replace '\{url\}', $url) -replace '\{error\}', $_.Exception.Message) -Level "error"
        return @{ ok = $false; path = $null; reason = "download failed" }
    }

    $hasFile = Test-Path -LiteralPath $dest
    if (-not $hasFile) {
        Write-FileError -FilePath $dest -Operation "verify" -Reason "downloaded installer not found on disk after Invoke-WebRequest" -Module "Install-Chrome"
        return @{ ok = $false; path = $null; reason = "downloaded file missing" }
    }

    $fileBytes = 0
    try { $fileBytes = (Get-Item -LiteralPath $dest).Length } catch { }
    $isTooSmall = $fileBytes -lt 1MB
    if ($isTooSmall) {
        Write-FileError -FilePath $dest -Operation "verify" -Reason "downloaded installer is suspiciously small ($fileBytes bytes) -- aborting before execution" -Module "Install-Chrome"
        return @{ ok = $false; path = $null; reason = "installer too small ($fileBytes bytes)" }
    }
    Write-Log (($msgs.fallbackDownloadOk -replace '\{bytes\}', $fileBytes) -replace '\{dest\}', $dest) -Level "success"

    # -- Run silently ------------------------------------------------------
    $silentArgs = [string]$Fallback.silentArgs
    if ([string]::IsNullOrWhiteSpace($silentArgs)) { $silentArgs = "/silent /install" }

    $timeout = [int]$Fallback.timeoutSeconds
    if ($timeout -le 0) { $timeout = 600 }

    Write-Log (($msgs.fallbackRunning -replace '\{path\}', $dest) -replace '\{args\}', $silentArgs) -Level "info"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Start-Process -FilePath $dest -ArgumentList $silentArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
        $hasExited = $proc.WaitForExit($timeout * 1000)
        if (-not $hasExited) {
            try { $proc.Kill() } catch { }
            Write-Log "Official installer timed out after ${timeout}s -- killed" -Level "error"
            return @{ ok = $false; path = $null; reason = "installer timeout" }
        }
        $sw.Stop()
        $exitCode = $proc.ExitCode
        Write-Log (($msgs.fallbackInstallerExited -replace '\{code\}', $exitCode) -replace '\{seconds\}', [int]$sw.Elapsed.TotalSeconds) -Level "info"
        $isExitOk = $exitCode -eq 0
        if (-not $isExitOk) {
            Write-Log ($msgs.fallbackInstallerFailed -replace '\{error\}', "non-zero exit code $exitCode") -Level "error"
            return @{ ok = $false; path = $null; reason = "exit $exitCode" }
        }
    } catch {
        Write-Log ($msgs.fallbackInstallerFailed -replace '\{error\}', $_.Exception.Message) -Level "error"
        return @{ ok = $false; path = $null; reason = "start-process failed" }
    }

    # -- Verify ------------------------------------------------------------
    $installedPath = Get-ChromePath
    if (-not $installedPath) {
        Write-FileError -FilePath $dest -Operation "verify" -Reason "official installer ran (exit 0) but chrome.exe not found in any expected location" -Module "Install-Chrome"
        Write-Log $msgs.fallbackVerifyFailed -Level "error"
        return @{ ok = $false; path = $null; reason = "post-install verify failed" }
    }

    Write-Log ($msgs.fallbackSuccess -replace '\{path\}', $installedPath) -Level "success"
    return @{ ok = $true; path = $installedPath; reason = "ok" }
}

function Install-Chrome {
    <#
    .SYNOPSIS
        Installs Google Chrome via Chocolatey, falling back to the official
        ChromeStandaloneSetup64.exe download when Chocolatey fails or
        verification cannot locate chrome.exe.
        Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)] $ChromeConfig,
        [Parameter(Mandatory)] $LogMessages
    )

    $msgs = $LogMessages.messages

    $isDisabled = -not $ChromeConfig.enabled
    if ($isDisabled) {
        Write-Log "Chrome install disabled in config -- skipping" -Level "info"
        return $true
    }

    Write-Log $msgs.checking -Level "info"

    $existing = Get-ChromePath
    if ($existing) {
        $version = "unknown"
        try { $version = (Get-Item $existing).VersionInfo.ProductVersion } catch { }
        $isAlreadyInstalled = Test-AlreadyInstalled -Name "googlechrome" -CurrentVersion $version
        if ($isAlreadyInstalled) {
            Write-Log ($msgs.alreadyInstalled -replace '\{path\}', $existing) -Level "success"
            return $true
        }
        Write-Log "chrome.exe found at $existing but no tracking record -- recording" -Level "info"
        Save-InstalledRecord -Name "googlechrome" -Version $version -Method "chocolatey"
        return $true
    }

    Write-Log $msgs.notFound -Level "info"
    Write-Log $msgs.installing -Level "info"

    $hasFallbackConfig = $null -ne $ChromeConfig.PSObject.Properties['fallback']
    $fallback = if ($hasFallbackConfig) { $ChromeConfig.fallback } else { $null }

    $isInstalled = Install-ChocoPackage -PackageName $ChromeConfig.chocoPackage
    if (-not $isInstalled) {
        Write-Log ($msgs.installFailed -replace '\{error\}', "choco install googlechrome returned failure") -Level "warn"
        if ($null -eq $fallback) {
            Save-InstalledError -Name "googlechrome" -ErrorMessage "choco install googlechrome failed and no fallback configured"
            return $false
        }
        $result = Invoke-ChromeOfficialInstaller -Fallback $fallback -LogMessages $LogMessages -TriggerReason "choco install returned failure"
        if (-not $result.ok) {
            Save-InstalledError -Name "googlechrome" -ErrorMessage "choco failed; fallback failed: $($result.reason)"
            return $false
        }
        $version = "unknown"
        try { $version = (Get-Item $result.path).VersionInfo.ProductVersion } catch { }
        Save-InstalledRecord -Name "googlechrome" -Version $version -Method "official-installer"
        return $true
    }

    # -- Verify Chocolatey install ---------------------------------------------
    $installedPath = Get-ChromePath
    if (-not $installedPath) {
        $checked = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        ) -join ", "
        Write-FileError -FilePath $checked -Operation "verify" -Reason "chrome.exe not found after choco install -- checked: $checked" -Module "Install-Chrome"
        Write-Log $msgs.verifyFailed -Level "warn"

        if ($null -eq $fallback) {
            Save-InstalledError -Name "googlechrome" -ErrorMessage "Verify failed: chrome.exe not in expected locations after install"
            return $false
        }
        $result = Invoke-ChromeOfficialInstaller -Fallback $fallback -LogMessages $LogMessages -TriggerReason "choco install verify failed"
        if (-not $result.ok) {
            Save-InstalledError -Name "googlechrome" -ErrorMessage "choco verify failed; fallback failed: $($result.reason)"
            return $false
        }
        $version = "unknown"
        try { $version = (Get-Item $result.path).VersionInfo.ProductVersion } catch { }
        Save-InstalledRecord -Name "googlechrome" -Version $version -Method "official-installer"
        return $true
    }

    $version = "unknown"
    try { $version = (Get-Item $installedPath).VersionInfo.ProductVersion } catch { }

    Write-Log ($msgs.installSuccess -replace '\{path\}', $installedPath) -Level "success"
    Save-InstalledRecord -Name "googlechrome" -Version $version -Method "chocolatey"
    return $true
}

function Expand-ChromePath {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return [Environment]::ExpandEnvironmentVariables($Raw) } catch { return $Raw }
}

function Test-ChromeIsElevated {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return ([System.Security.Principal.WindowsPrincipal]$id).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Reset-ChromeRegistryAcl {
    <#
    .SYNOPSIS
        Grants the current user FullControl on a registry key (and recurses into
        every subkey). Used to neutralise restrictive DACLs Chrome occasionally
        leaves behind on its own HKCU\Software\Google\Chrome subtree (e.g.
        per-profile crash-reporter keys), which break Remove-Item with
        "Attempted to perform an unauthorized operation".
        Best-effort: swallows individual subkey failures so we still attempt
        deletion afterwards.
    #>
    param([Parameter(Mandatory)] [string]$Key)

    try {
        $sid     = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule    = New-Object System.Security.AccessControl.RegistryAccessRule(
                       $sid, "FullControl", "ContainerInherit", "None", "Allow")

        $stack = New-Object System.Collections.Stack
        $stack.Push($Key)
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            $hasCur = Test-Path -LiteralPath $cur -ErrorAction SilentlyContinue
            if (-not $hasCur) { continue }
            try {
                $acl = Get-Acl -LiteralPath $cur -ErrorAction Stop
                $acl.SetAccessRule($rule)
                Set-Acl -LiteralPath $cur -AclObject $acl -ErrorAction Stop
            } catch { }
            try {
                $children = Get-ChildItem -LiteralPath $cur -Force -ErrorAction Stop
                foreach ($c in $children) { $stack.Push($c.PSPath) }
            } catch { }
        }
    } catch { }
}

function Invoke-ChromeRegDeleteFallback {
    <#
    .SYNOPSIS
        Last-ditch registry delete: resets DACL to grant the current user
        FullControl recursively, then tries Remove-Item again, and finally
        falls back to `reg.exe delete /f` against the 64-bit and 32-bit views.
        Returns $true on success.
    #>
    param([Parameter(Mandatory)] [string]$Key)

    # Step 1: try to neutralise restrictive DACLs in the subtree.
    Reset-ChromeRegistryAcl -Key $Key

    # Step 2: retry the native PS provider now that we own the keys.
    try {
        Remove-Item -LiteralPath $Key -Recurse -Force -ErrorAction Stop
        $isGone = -not (Test-Path -LiteralPath $Key -ErrorAction SilentlyContinue)
        if ($isGone) { return $true }
    } catch { }

    # Step 3: fall through to reg.exe (handles a few cases the provider refuses).
    $regForm = $Key -replace '^HKCU:\\?', 'HKCU\' `
                    -replace '^HKLM:\\?', 'HKLM\' `
                    -replace '^HKCR:\\?', 'HKCR\' `
                    -replace '^HKU:\\?',  'HKU\'

    foreach ($view in @("/reg:64", "/reg:32")) {
        try {
            $null = & reg.exe delete $regForm /f $view 2>&1
            $okView = ($LASTEXITCODE -eq 0)
            if ($okView) {
                $isGone = -not (Test-Path -LiteralPath $Key -ErrorAction SilentlyContinue)
                if ($isGone) { return $true }
            }
        } catch { }
    }
    return (-not (Test-Path -LiteralPath $Key -ErrorAction SilentlyContinue))
}

function Remove-ChromeRegistryKeys {
    param(
        [Parameter(Mandatory)] [string[]]$Keys,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    $counter   = @{ removed = 0; missing = 0; failed = 0; skippedNoElevation = 0 }
    $isElev    = Test-ChromeIsElevated

    foreach ($key in $Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $hasKey = Test-Path -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $hasKey) {
            Write-Log ($msgs.cleanupRegKeyMissing -replace '\{path\}', $key) -Level "info"
            $counter.missing++
            continue
        }

        $removed = $false
        $firstErr = $null
        try {
            Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
            $removed = $true
        } catch {
            $firstErr = $_.Exception.Message
        }

        # Fallback path: reg.exe handles a few ACL edge cases Remove-Item won't.
        if (-not $removed) {
            $removed = Invoke-ChromeRegDeleteFallback -Key $key
        }

        if ($removed) {
            Write-Log ($msgs.cleanupRegKeyRemoved -replace '\{path\}', $key) -Level "success"
            $counter.removed++
            continue
        }

        # Protected / locked registry leftovers are common after uninstall.
        # Treat authorization-style failures as actionable warnings so a
        # mostly-successful uninstall does not stay red just because cleanup
        # could not remove a leftover key.
        $isAuthzFailure = -not [string]::IsNullOrWhiteSpace($firstErr) -and ($firstErr -match '(?i)unauthorized|denied|access')
        $isHkml = $key -match '^HKLM[:\\]'
        if ($isAuthzFailure -or (-not $isElev -and $isHkml)) {
            Write-Log ("Skipped registry key (needs Administrator): $key -- relaunch with elevated PowerShell to remove.") -Level "warn"
            $counter.skippedNoElevation++
            continue
        }

        Write-FileError -FilePath $key -Operation "registry delete" `
            -Reason "Remove-Item + reg.exe both failed: $firstErr" `
            -Module "Uninstall-Chrome" `
            -Fallback "Run PowerShell as Administrator and re-run: .\run.ps1 uninstall chrome"
        Write-Log (($msgs.cleanupRegKeyFailed -replace '\{path\}', $key) -replace '\{error\}', $firstErr) -Level "error"
        $counter.failed++
    }
    return $counter
}

function Remove-ChromeShortcuts {
    param(
        [Parameter(Mandatory)] [string[]]$Paths,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages
    $counter = @{ removed = 0; missing = 0; failed = 0 }

    foreach ($raw in $Paths) {
        $p = Expand-ChromePath -Raw $raw
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $hasPath = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $hasPath) {
            Write-Log ($msgs.cleanupShortcutMissing -replace '\{path\}', $p) -Level "info"
            $counter.missing++
            continue
        }
        try {
            $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
            $isContainer = $item.PSIsContainer
            if ($isContainer) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
            }
            Write-Log ($msgs.cleanupShortcutRemoved -replace '\{path\}', $p) -Level "success"
            $counter.removed++
        } catch {
            Write-FileError -FilePath $p -Operation "shortcut delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-Chrome"
            Write-Log (($msgs.cleanupShortcutFailed -replace '\{path\}', $p) -replace '\{error\}', $_.Exception.Message) -Level "error"
            $counter.failed++
        }
    }
    return $counter
}

function Invoke-ChromePostUninstallCleanup {
    param(
        [Parameter(Mandatory)] $ChromeConfig,
        [Parameter(Mandatory)] $LogMessages
    )
    $msgs = $LogMessages.messages

    $hasCleanupConfig = $null -ne $ChromeConfig.PSObject.Properties['uninstallCleanup']
    if (-not $hasCleanupConfig) {
        Write-Log "uninstallCleanup block missing from config -- skipping sweep" -Level "warn"
        return
    }
    $cleanup = $ChromeConfig.uninstallCleanup

    $isCleanupDisabled = -not $cleanup.enabled
    if ($isCleanupDisabled) {
        Write-Log $msgs.cleanupSkipped -Level "info"
        return
    }

    Write-Log $msgs.cleanupStart -Level "info"

    $regCounter = @{ removed = 0; missing = 0; failed = 0 }
    $isRegEnabled = $cleanup.removeRegistryKeys
    if ($isRegEnabled) {
        $regCounter = Remove-ChromeRegistryKeys -Keys $cleanup.registryKeys -LogMessages $LogMessages
    }

    $scCounter = @{ removed = 0; missing = 0; failed = 0 }
    $isShortcutEnabled = $cleanup.removeShortcuts
    if ($isShortcutEnabled) {
        $scCounter = Remove-ChromeShortcuts -Paths $cleanup.shortcutPaths -LogMessages $LogMessages
    }

    # -- AppData folder (opt-in only) --------------------------------------
    $hasAppDataList = $null -ne $cleanup.PSObject.Properties['appDataPaths'] -and $cleanup.appDataPaths
    if ($hasAppDataList) {
        $isPurge = $cleanup.purgeAppData
        foreach ($raw in $cleanup.appDataPaths) {
            $p = Expand-ChromePath -Raw $raw
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $hasFolder = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue
            if (-not $hasFolder) { continue }
            if (-not $isPurge) {
                Write-Log ($msgs.cleanupAppDataKept -replace '\{path\}', $p) -Level "info"
                continue
            }
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                Write-Log ($msgs.cleanupAppDataPurged -replace '\{path\}', $p) -Level "success"
            } catch {
                Write-FileError -FilePath $p -Operation "appdata delete" -Reason "Remove-Item failed: $($_.Exception.Message)" -Module "Uninstall-Chrome"
            }
        }
    }

    $summary = $msgs.cleanupSummary
    $summary = $summary -replace '\{regRemoved\}', $regCounter.removed
    $summary = $summary -replace '\{regMissing\}', $regCounter.missing
    $summary = $summary -replace '\{regFailed\}', $regCounter.failed
    $summary = $summary -replace '\{scRemoved\}', $scCounter.removed
    $summary = $summary -replace '\{scMissing\}', $scCounter.missing
    $summary = $summary -replace '\{scFailed\}', $scCounter.failed
    $hasAnyFailure = ($regCounter.failed + $scCounter.failed) -gt 0
    $skippedElev   = 0
    if ($regCounter.ContainsKey('skippedNoElevation')) { $skippedElev = $regCounter.skippedNoElevation }
    if ($skippedElev -gt 0) {
        $summary += " | $skippedElev registry key(s) skipped (need Administrator)"
    }
    Write-Log $summary -Level $(if ($hasAnyFailure) { "warn" } else { "success" })
}

function Uninstall-Chrome {
    param($ChromeConfig, $LogMessages)

    Assert-Elevated `
        -ScriptPath $(if ($PSCommandPath) { $PSCommandPath } else { (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'run.ps1') }) `
        -ScriptArgs 'uninstall chrome' `
        -Reason 'Chrome uninstall removes protected registry keys and requires Administrator privileges.'

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "Google Chrome") -Level "info"
    $isUninstalled = Uninstall-ChocoPackage -PackageName $ChromeConfig.chocoPackage
    if ($isUninstalled) {
        Write-Log ($LogMessages.messages.uninstallSuccess -replace '\{name\}', "Google Chrome") -Level "success"
    } else {
        Write-Log ($LogMessages.messages.uninstallFailed -replace '\{name\}', "Google Chrome") -Level "warn"
    }

    Invoke-ChromePostUninstallCleanup -ChromeConfig $ChromeConfig -LogMessages $LogMessages

    Remove-InstalledRecord -Name "googlechrome"
    Remove-ResolvedData -ScriptFolder "58-install-chrome"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
