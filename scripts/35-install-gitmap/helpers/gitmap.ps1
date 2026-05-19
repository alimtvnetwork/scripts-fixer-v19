# --------------------------------------------------------------------------
#  Helper -- GitMap CLI installer
#  Uses the remote install.ps1 from GitHub to install gitmap.
#  Integrates with devDir resolution for folder-specific installs.
# --------------------------------------------------------------------------

# -- Bootstrap shared helpers --------------------------------------------------
$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

$_devDirPath = Join-Path $_sharedDir "dev-dir.ps1"
if ((Test-Path $_devDirPath) -and -not (Get-Command Resolve-DevDir -ErrorAction SilentlyContinue)) {
    . $_devDirPath
}

$_diskPath = Join-Path $_sharedDir "disk-space.ps1"
if ((Test-Path $_diskPath) -and -not (Get-Command Test-DiskSpace -ErrorAction SilentlyContinue)) {
    . $_diskPath
}

function Test-GitmapInstalled {
    $cmd = Get-Command "gitmap" -ErrorAction SilentlyContinue
    $isInPath = $null -ne $cmd
    if ($isInPath) { return $true }

    # Check default install location
    $defaultPaths = @(
        "$env:LOCALAPPDATA\gitmap\gitmap.exe",
        "C:\dev-tool\GitMap\gitmap.exe"
    )

    # Also check devDir-resolved path if DEV_DIR is set
    $hasDevDir = -not [string]::IsNullOrWhiteSpace($env:DEV_DIR)
    if ($hasDevDir) {
        $devDirGitmap = Join-Path $env:DEV_DIR "GitMap\gitmap.exe"
        $defaultPaths += $devDirGitmap
    }

    foreach ($p in $defaultPaths) {
        $isPresent = Test-Path $p
        if ($isPresent) { return $true }
    }

    return $false
}

function Save-GitmapResolvedState {
    param(
        [string]$InstallDir = ""
    )
    Save-ResolvedData -ScriptFolder "35-install-gitmap" -Data @{
        resolvedAt  = (Get-Date -Format "o")
        resolvedBy  = $env:USERNAME
        installDir  = $InstallDir
    }
}

function Resolve-GitmapInstallDir {
    <#
    .SYNOPSIS
        Resolves the GitMap install directory using devDir config.
        Priority: gitmap.installDir override > devDir resolution > config default.
    #>
    param(
        [PSCustomObject]$GitmapConfig,
        [PSCustomObject]$DevDirConfig
    )

    # 1. Explicit installDir override in gitmap config
    $hasInstallDir = -not [string]::IsNullOrWhiteSpace($GitmapConfig.installDir)
    if ($hasInstallDir) {
        return $GitmapConfig.installDir
    }

    # 2. Resolve via devDir system (env var, smart detection, etc.)
    $devDir = Resolve-DevDir -DevDirConfig $DevDirConfig
    $hasDevDir = -not [string]::IsNullOrWhiteSpace($devDir)
    if ($hasDevDir) {
        return Join-Path $devDir "GitMap"
    }

    # 3. Fallback to config default
    $hasDefault = -not [string]::IsNullOrWhiteSpace($DevDirConfig.default)
    if ($hasDefault) {
        return $DevDirConfig.default
    }

    return "C:\dev-tool\GitMap"
}

function Get-GitmapVersion {
    <#
    .SYNOPSIS
        Returns the installed gitmap version string, or $null if not found.
    #>
    try {
        $raw = & gitmap --version 2>&1
        $isValid = -not [string]::IsNullOrWhiteSpace($raw)
        if ($isValid) { return ($raw -replace '^\s*gitmap\s*', '').Trim() }
    } catch { }
    return $null
}

function Assert-GitmapInstalled {
    <#
    .SYNOPSIS
        Post-install verifier. Runs `gitmap --version`, captures the resolved
        binary path, and -- if not on PATH -- refreshes from registry and
        probes well-known install locations before retrying.
    .OUTPUTS
        Hashtable: Success (bool), Version (string), BinaryPath (string),
                   ExitCode (int), Output (string).
    #>
    param(
        [string]$InstallDir,
        $LogMessages
    )

    $msgs = $LogMessages.messages
    Write-Log $msgs.verifyStart -Level "info"

    function Test-GitmapVersion {
        $cmd = Get-Command "gitmap" -ErrorAction SilentlyContinue
        if (-not $cmd) { return $null }
        try {
            $out = & $cmd.Source --version 2>&1
            $code = $LASTEXITCODE
            $text = ("$out").Trim()
            if ($code -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) {
                return @{
                    Version    = ($text -replace '^\s*gitmap\s*', '').Trim()
                    BinaryPath = $cmd.Source
                    ExitCode   = $code
                    Output     = $text
                }
            }
            # Non-zero exit -- still report it for the caller's audit log
            Write-Log (($msgs.verifyExitCode -replace '\{code\}', "$code") -replace '\{output\}', $text) -Level "warn"
        } catch { }
        return $null
    }

    # Attempt 1: as-is
    $r = Test-GitmapVersion
    if ($r) {
        Write-Log ($msgs.verifyOk         -replace '\{version\}', $r.Version) -Level "success"
        Write-Log ($msgs.verifyBinaryAt   -replace '\{path\}',    $r.BinaryPath) -Level "info"
        return @{ Success = $true; Version = $r.Version; BinaryPath = $r.BinaryPath; ExitCode = $r.ExitCode; Output = $r.Output }
    }

    # Attempt 2: refresh PATH from registry
    Write-Log $msgs.verifyMissing -Level "warn"
    $oldEntries = @($env:Path -split ';' | Where-Object { $_ })
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [Environment]::GetEnvironmentVariable("Path", "User")
    $combined = @()
    if ($machine) { $combined += ($machine -split ';' | Where-Object { $_ }) }
    if ($user)    { $combined += ($user    -split ';' | Where-Object { $_ }) }
    $seen = @{}
    $deduped = foreach ($e in $combined) {
        $k = $e.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $e }
    }
    $env:Path = ($deduped -join ';')
    $added = @($deduped | Where-Object { $_ -notin $oldEntries }).Count
    Write-Log ($msgs.verifyRefreshed -replace '\{count\}', "$added") -Level "info"

    $r = Test-GitmapVersion
    if ($r) {
        Write-Log ($msgs.verifyOk       -replace '\{version\}', $r.Version) -Level "success"
        Write-Log ($msgs.verifyBinaryAt -replace '\{path\}',    $r.BinaryPath) -Level "info"
        return @{ Success = $true; Version = $r.Version; BinaryPath = $r.BinaryPath; ExitCode = $r.ExitCode; Output = $r.Output }
    }

    # Attempt 3: probe well-known locations
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $candidates.Add((Join-Path $InstallDir "gitmap.exe")) | Out-Null
    }
    $candidates.Add("$env:LOCALAPPDATA\gitmap\gitmap.exe") | Out-Null
    $candidates.Add("$env:LOCALAPPDATA\Programs\gitmap\gitmap.exe") | Out-Null
    $candidates.Add("C:\dev-tool\GitMap\gitmap.exe") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($env:DEV_DIR)) {
        $candidates.Add((Join-Path $env:DEV_DIR "GitMap\gitmap.exe")) | Out-Null
    }
    $candList = @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    Write-Log ($msgs.verifyProbe -replace '\{paths\}', ($candList -join '; ')) -Level "info"

    foreach ($candidate in $candList) {
        if (Test-Path -LiteralPath $candidate) {
            $binDir = Split-Path -Parent $candidate
            Write-Log ($msgs.verifyFoundAt -replace '\{path\}', $candidate) -Level "warn"
            $env:Path = "$binDir;$env:Path"
            $r = Test-GitmapVersion
            if ($r) {
                Write-Log ($msgs.verifyOk       -replace '\{version\}', $r.Version) -Level "success"
                Write-Log ($msgs.verifyBinaryAt -replace '\{path\}',    $r.BinaryPath) -Level "info"
                return @{ Success = $true; Version = $r.Version; BinaryPath = $r.BinaryPath; ExitCode = $r.ExitCode; Output = $r.Output }
            }
        } else {
            Write-FileError -FilePath $candidate -Operation "probe-gitmap-binary" `
                -Reason "Candidate gitmap.exe path does not exist on disk." -Module "Assert-GitmapInstalled"
        }
    }

    Write-FileError -FilePath "gitmap" -Operation "verify" -Reason $msgs.verifyFinalFail -Module "Assert-GitmapInstalled"
    return @{ Success = $false; Version = $null; BinaryPath = $null; ExitCode = $null; Output = $null }
}

function Install-GitmapViaZip {
    <#
    .SYNOPSIS
        Fallback installer: downloads a tagged release ZIP from GitHub,
        extracts the binary to the install directory, and adds it to PATH.
        Returns $true on success, $false on failure.
    #>
    param(
        [string]$InstallDir,
        [PSCustomObject]$GitmapConfig,
        $LogMessages
    )

    # Build ZIP URL from config template
    $tag = $GitmapConfig.fallbackTag
    $hasTag = -not [string]::IsNullOrWhiteSpace($tag)
    if (-not $hasTag) { $tag = "latest" }

    $zipUrlTemplate = $GitmapConfig.releaseZipUrl
    $hasTemplate = -not [string]::IsNullOrWhiteSpace($zipUrlTemplate)
    if (-not $hasTemplate) {
        $zipUrlTemplate = "https://github.com/$($GitmapConfig.repo)/releases/download/{tag}/gitmap-windows-amd64.zip"
    }

    # For "latest", resolve the redirect to get the actual tag
    $isLatest = $tag -eq "latest"
    if ($isLatest) {
        $apiUrl = "https://api.github.com/repos/$($GitmapConfig.repo)/releases/latest"
        try {
            $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -Headers @{ "User-Agent" = "gitmap-installer" }
            $tag = $release.tag_name
        } catch {
            # If API fails, try direct download URL pattern
            $zipUrl = "https://github.com/$($GitmapConfig.repo)/releases/latest/download/gitmap-windows-amd64.zip"
            Write-Log "Could not resolve latest tag, trying direct URL: $zipUrl" -Level "warn"
        }
    }

    # Build final URL if not already set by latest-fallback
    $hasZipUrl = -not [string]::IsNullOrWhiteSpace($zipUrl)
    if (-not $hasZipUrl) {
        $zipUrl = $zipUrlTemplate -replace '\{tag\}', $tag
    }

    Write-Log ($LogMessages.messages.downloadingZip -replace '\{url\}', $zipUrl) -Level "info"

    $tempZip  = Join-Path $env:TEMP "gitmap-release.zip"
    $tempDir  = Join-Path $env:TEMP "gitmap-extract"

    try {
        # Download ZIP
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing

        # Clean previous extract
        $hasTempDir = Test-Path $tempDir
        if ($hasTempDir) { Remove-Item $tempDir -Recurse -Force }

        # Extract
        Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
        Write-Log ($LogMessages.messages.zipExtracted -replace '\{path\}', $tempDir) -Level "info"

        # Ensure install directory exists
        $hasInstallDir = Test-Path $InstallDir
        if (-not $hasInstallDir) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        # Copy binary -- handle nested folder structure
        $exeFiles = Get-ChildItem -Path $tempDir -Recurse -Filter "gitmap.exe"
        $hasExe = $exeFiles.Count -gt 0
        if ($hasExe) {
            Copy-Item -Path $exeFiles[0].FullName -Destination (Join-Path $InstallDir "gitmap.exe") -Force
        } else {
            # Copy everything if no specific exe found
            Copy-Item -Path "$tempDir\*" -Destination $InstallDir -Recurse -Force
        }

        # Add to user PATH if not already there
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $isInPath = $userPath -split ";" | Where-Object { $_ -eq $InstallDir }
        $isAlreadyInPath = $null -ne $isInPath -and @($isInPath).Count -gt 0
        if (-not $isAlreadyInPath) {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallDir", "User")
        }

        return $true

    } catch {
        $errMsg   = $_.Exception.Message
        $errStack = $_.ScriptStackTrace
        Write-FileError -FilePath $zipUrl -Operation "zip-fallback" -Reason "ZIP download/extract failed: $errMsg" -Module "Install-GitmapViaZip"
        Write-Log ($LogMessages.messages.zipFallbackFailed -replace '\{error\}', $errMsg) -Level "error"
        Write-Log "Stack trace: $errStack" -Level "error"
        return $false
    } finally {
        # Cleanup temp files
        $hasTempZip = Test-Path $tempZip
        if ($hasTempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        $hasTempDir = Test-Path $tempDir
        if ($hasTempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-Gitmap {
    <#
    .SYNOPSIS
        Installs gitmap CLI via the remote install.ps1 from GitHub.
        Uses devDir resolution for the install directory.
        Returns $true on success, $false on failure.
    #>
    param(
        [PSCustomObject]$GitmapConfig,
        [PSCustomObject]$DevDirConfig,
        $LogMessages
    )

    $isDisabled = -not $GitmapConfig.enabled
    if ($isDisabled) {
        Write-Log $LogMessages.messages.disabled -Level "info"
        return $true
    }

    Write-Log $LogMessages.messages.checking -Level "info"

    $isGitmapReady = Test-GitmapInstalled
    if ($isGitmapReady) {
        $ver = Get-GitmapVersion
        $hasVersion = -not [string]::IsNullOrWhiteSpace($ver)
        if ($hasVersion) {
            Write-Log ($LogMessages.messages.foundVersion -replace '\{version\}', $ver) -Level "success"
        } else {
            Write-Log $LogMessages.messages.found -Level "success"
        }
        Save-GitmapResolvedState
        return $true
    }

    Write-Log $LogMessages.messages.notFound -Level "info"

    # Resolve install directory FIRST -- log it prominently before anything else
    $installDir = Resolve-GitmapInstallDir -GitmapConfig $GitmapConfig -DevDirConfig $DevDirConfig
    Write-Host ""
    Write-Log ($LogMessages.messages.installDir -replace '\{path\}', $installDir) -Level "success"
    Write-Host ""

    # ---- Preflight: required commands + reachable install URL --------------
    $requiredCmds = @(
        @{ Name = "Invoke-RestMethod"; Hint = "Built-in cmdlet (alias 'irm'). Requires PowerShell 3.0 or later." },
        @{ Name = "Invoke-Expression"; Hint = "Built-in cmdlet (alias 'iex'). Disabled by Constrained Language Mode or some AppLocker policies." },
        @{ Name = "Invoke-WebRequest"; Hint = "Built-in cmdlet. Needed for ZIP fallback download." },
        @{ Name = "Expand-Archive";    Hint = "Microsoft.PowerShell.Archive module. Needed for ZIP fallback extraction." }
    )
    $missingCmds = @()
    foreach ($rc in $requiredCmds) {
        $isPresent = [bool](Get-Command $rc.Name -ErrorAction SilentlyContinue)
        if (-not $isPresent) {
            $missingCmds += $rc
            Write-FileError -FilePath $rc.Name -Operation "preflight-command-check" `
                -Reason "Required command '$($rc.Name)' is not available. $($rc.Hint)" -Module "Install-Gitmap"
        }
    }
    $hasMissingCmds = $missingCmds.Count -gt 0
    if ($hasMissingCmds) {
        $names = ($missingCmds | ForEach-Object { $_.Name }) -join ", "
        Write-Log "Preflight failed: missing required commands -> $names" -Level "error"
        Write-Log "Cannot run 'irm | iex' one-liner without these. Aborting before remote download." -Level "error"
        Write-Log "PowerShell version: $($PSVersionTable.PSVersion); LanguageMode: $($ExecutionContext.SessionState.LanguageMode)" -Level "info"
        return $false
    }

    # Validate install URL is well-formed and uses https before fetching it
    $installUrl = $GitmapConfig.installUrl
    $hasInstallUrl = -not [string]::IsNullOrWhiteSpace($installUrl)
    if (-not $hasInstallUrl) {
        Write-FileError -FilePath "config.json::installUrl" -Operation "preflight-url-check" `
            -Reason "GitmapConfig.installUrl is empty. Set 'installUrl' in scripts/35-install-gitmap/config.json." -Module "Install-Gitmap"
        return $false
    }
    $parsedUri = $null
    $isValidUri = [System.Uri]::TryCreate($installUrl, [System.UriKind]::Absolute, [ref]$parsedUri)
    if (-not $isValidUri) {
        Write-FileError -FilePath $installUrl -Operation "preflight-url-check" `
            -Reason "installUrl is not a valid absolute URI." -Module "Install-Gitmap"
        return $false
    }
    $isHttps = $parsedUri.Scheme -eq "https"
    if (-not $isHttps) {
        Write-FileError -FilePath $installUrl -Operation "preflight-url-check" `
            -Reason "installUrl scheme is '$($parsedUri.Scheme)', expected 'https'. Refusing to pipe insecure content into iex." -Module "Install-Gitmap"
        return $false
    }
    Write-Log "Preflight OK -- required commands present, installUrl validated ($($parsedUri.Host))." -Level "success"

    Write-Log $LogMessages.messages.downloadingInstaller -Level "info"

    # Resolve repo-root .logs directory and prepare a timestamped transcript file
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $logsDir  = Join-Path $repoRoot ".logs"
    try {
        if (-not (Test-Path -LiteralPath $logsDir)) {
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
        }
    } catch {
        Write-FileError -FilePath $logsDir -Operation "create-logs-dir" `
            -Reason "Could not create .logs directory: $($_.Exception.Message)" -Module "Install-Gitmap"
    }
    $stamp        = Get-Date -Format "yyyyMMdd-HHmmss"
    $installerLog = Join-Path $logsDir "gitmap-install-$stamp.log"
    Write-Log ($LogMessages.messages.installerLogFile -replace '\{path\}', $installerLog) -Level "info"

    $isRemoteSuccess = $true
    try {
        Write-Log $LogMessages.messages.runningInstaller -Level "info"

        # Canonical one-liner: irm <gitmap/scripts/install.ps1> | iex
        # We invoke the same way the README documents it so behaviour matches
        # what users see when they run the bare one-liner. install.ps1
        # honours $env:GITMAP_INSTALL_DIR for non-default targets.
        Write-Log "Invoking: irm $($GitmapConfig.installUrl) | iex" -Level "info"
        $env:GITMAP_INSTALL_DIR = $installDir
        $installerScript = Invoke-RestMethod -Uri $GitmapConfig.installUrl -UseBasicParsing

        # Write a header to the transcript, then run iex with merged streams (2>&1)
        # tee'd into the log file. This captures stdout AND stderr from the
        # one-liner for offline troubleshooting.
        try {
            $header = @(
                "===== gitmap installer transcript ====="
                "timestamp:    $(Get-Date -Format 'o')"
                "installUrl:   $($GitmapConfig.installUrl)"
                "installDir:   $installDir"
                "user:         $env:USERNAME"
                "host:         $env:COMPUTERNAME"
                "pwsh:         $($PSVersionTable.PSVersion)"
                "======================================="
                ""
            )
            Set-Content -LiteralPath $installerLog -Value $header -Encoding UTF8
        } catch {
            Write-Log ($LogMessages.messages.installerLogFailed `
                -replace '\{path\}',  $installerLog `
                -replace '\{error\}', $_.Exception.Message) -Level "warn"
        }

        # Merge stderr into stdout, stream every line to console AND append to file
        & {
            Invoke-Expression $installerScript
        } 2>&1 | ForEach-Object {
            $line = "$_"
            try { Add-Content -LiteralPath $installerLog -Value $line -Encoding UTF8 } catch { }
            $line
        }

        # Report final transcript size for the audit trail
        try {
            if (Test-Path -LiteralPath $installerLog) {
                $sz = (Get-Item -LiteralPath $installerLog).Length
                Write-Log (($LogMessages.messages.installerLogSaved `
                    -replace '\{bytes\}', "$sz") `
                    -replace '\{path\}',  $installerLog) -Level "info"
            }
        } catch { }

    } catch {
        $errMsg   = $_.Exception.Message
        $errStack = $_.ScriptStackTrace
        $errType  = $_.Exception.GetType().FullName
        $inner    = $_.Exception.InnerException
        $innerMsg = if ($inner) { $inner.Message } else { "" }

        # Classify common failure modes into actionable hints
        $hint = "Unknown failure. See transcript for full output."
        $isWebEx     = $errType -like "*WebException*" -or $errType -like "*HttpRequestException*"
        $is404       = $errMsg -match "(?i)404|not\s*found"
        $isDns       = $errMsg -match "(?i)remote name|could not resolve|no such host"
        $isTls       = $errMsg -match "(?i)SSL|TLS|secure channel|certificate"
        $isTimeout   = $errMsg -match "(?i)timed?\s*out|timeout"
        $isIexBlock  = $errMsg -match "(?i)is not recognized|cannot be loaded|ConstrainedLanguage|disabled"
        if     ($is404)      { $hint = "HTTP 404 -- installUrl points to a missing release/script. Check 'installUrl' and 'releaseTag' in config.json." }
        elseif ($isDns)      { $hint = "DNS resolution failed -- check network/proxy settings and that '$($parsedUri.Host)' is reachable." }
        elseif ($isTls)      { $hint = "TLS/SSL handshake failed -- run: [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, then retry." }
        elseif ($isTimeout)  { $hint = "Network timeout -- the host may be slow or blocked by a firewall/proxy." }
        elseif ($isIexBlock) { $hint = "Script execution blocked -- check ExecutionPolicy ('Get-ExecutionPolicy -List') and LanguageMode ('$($ExecutionContext.SessionState.LanguageMode)')." }
        elseif ($isWebEx)    { $hint = "Network/HTTP error from '$($parsedUri.Host)'. Verify connectivity and that the URL returns 200 OK." }

        # Capture the exception into the transcript too
        try {
            Add-Content -LiteralPath $installerLog -Value @(
                "",
                "===== EXCEPTION =====",
                "type:        $errType",
                "message:     $errMsg",
                "innerMessage: $innerMsg",
                "hint:        $hint",
                "",
                "----- stack trace -----",
                $errStack
            ) -Encoding UTF8
        } catch { }

        Write-FileError -FilePath $GitmapConfig.installUrl -Operation "remote-install" `
            -Reason "Remote installer failed: $errMsg | hint: $hint | transcript: $installerLog" -Module "Install-Gitmap"
        Write-Log ($LogMessages.messages.installFailed -replace '\{error\}', $errMsg) -Level "error"
        Write-Log "Exception type: $errType" -Level "error"
        if ($innerMsg) { Write-Log "Inner exception: $innerMsg" -Level "error" }
        Write-Log "Hint: $hint" -Level "warn"
        Write-Log "Stack trace: $errStack" -Level "error"
        Write-Log "Full installer transcript: $installerLog" -Level "warn"
        $isRemoteSuccess = $false
    }

    # If remote installer failed or gitmap still not found, try ZIP fallback
    if (-not $isRemoteSuccess) {
        Write-Log $LogMessages.messages.remoteInstallerFailed -Level "warn"
        $isZipSuccess = Install-GitmapViaZip -InstallDir $installDir -GitmapConfig $GitmapConfig -LogMessages $LogMessages
        if (-not $isZipSuccess) {
            return $false
        }
    }

    # Refresh PATH
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

    # Authoritative post-install check: actually run `gitmap --version` and
    # report the resolved binary path. Falls back to PATH refresh + probing.
    $verify = Assert-GitmapInstalled -InstallDir $installDir -LogMessages $LogMessages

    if ($verify.Success) {
        Write-Log ($LogMessages.messages.installSuccessVersion -replace '\{version\}', $verify.Version) -Level "success"
        Save-GitmapResolvedState -InstallDir $installDir
        return $true
    }

    # Verification failed -- keep going (installer may still have placed files)
    # but make the failure loud and explicit.
    Write-Log $LogMessages.messages.notInPath -Level "warn"
    Save-GitmapResolvedState -InstallDir $installDir
    return $false
}

function Uninstall-Gitmap {
    <#
    .SYNOPSIS
        Full GitMap uninstall: remove install directory, purge tracking.
    #>
    param(
        $GitmapConfig,
        $DevDirConfig,
        $LogMessages
    )

    Write-Log ($LogMessages.messages.uninstalling -replace '\{name\}', "GitMap") -Level "info"

    # 1. Remove from PATH and delete install directory
    $installDir = $GitmapConfig.installDir
    $hasInstallDir = -not [string]::IsNullOrWhiteSpace($installDir)
    if ($hasInstallDir -and (Test-Path $installDir)) {
        Remove-FromUserPath -Directory $installDir
        Write-Log "Removing install directory: $installDir" -Level "info"
        Remove-Item -Path $installDir -Recurse -Force
        Write-Log "Install directory removed: $installDir" -Level "success"
    }

    # 2. Remove tracking records
    Remove-InstalledRecord -Name "gitmap"
    Remove-ResolvedData -ScriptFolder "35-install-gitmap"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
