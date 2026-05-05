<#
.SYNOPSIS
    Shared Chocolatey helpers: ensure installed, install/upgrade packages.
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

function Get-ChocoTimeoutSeconds {
    $defaultTimeout = 1800
    $rawTimeout = $env:CHOCO_TIMEOUT_SECONDS
    $hasOverride = -not [string]::IsNullOrWhiteSpace($rawTimeout)
    if ($hasOverride) {
        $parsedTimeout = 0
        $isValidOverride = [int]::TryParse($rawTimeout, [ref]$parsedTimeout) -and $parsedTimeout -gt 0
        if ($isValidOverride) {
            return $parsedTimeout
        }
    }

    return $defaultTimeout
}

function Resolve-ChocolateyInstallRoot {
    <#
    .SYNOPSIS
        Resolves the Chocolatey install root, falling back to registry / well-known
        locations when $env:ChocolateyInstall is not set in the current session.
    .DESCRIPTION
        Resolution order:
          1. $env:ChocolateyInstall (current session)
          2. Machine env var ChocolateyInstall (registry: HKLM\...\Environment)
          3. User    env var ChocolateyInstall (registry: HKCU\Environment)
          4. HKLM:\SOFTWARE\Chocolatey -> InstallLocation
          5. HKLM:\SOFTWARE\WOW6432Node\Chocolatey -> InstallLocation (32-bit view)
          6. (Get-Command choco.exe).Source -> parent of \bin\choco.exe
          7. $env:ProgramData\chocolatey (default install location)
        Returns the first existing path. Sets $env:ChocolateyInstall in the
        current session as a side-effect so subsequent callers skip the probe.
    .OUTPUTS
        [string] Absolute path to the Chocolatey install root, or $null if
        nothing exists on disk.
    #>
    [CmdletBinding()]
    param(
        [switch]$Quiet
    )

    function Write-ProbeLog {
        param([string]$Message, [string]$Level = "info")
        if ($Quiet) { return }
        $hasWriteLog = [bool](Get-Command Write-Log -ErrorAction SilentlyContinue)
        if ($hasWriteLog) { Write-Log $Message -Level $Level }
    }

    # 1. Current session env var
    $sessionVal = $env:ChocolateyInstall
    $hasSession = -not [string]::IsNullOrWhiteSpace($sessionVal)
    if ($hasSession -and (Test-Path -LiteralPath $sessionVal)) {
        return $sessionVal
    }

    $candidates = New-Object System.Collections.Generic.List[pscustomobject]

    # 2. Machine env var (registry)
    try {
        $machineVal = [Environment]::GetEnvironmentVariable("ChocolateyInstall", "Machine")
        if (-not [string]::IsNullOrWhiteSpace($machineVal)) {
            $candidates.Add([pscustomobject]@{ Path = $machineVal; Source = "env:Machine\ChocolateyInstall" }) | Out-Null
        }
    } catch { }

    # 3. User env var (registry)
    try {
        $userVal = [Environment]::GetEnvironmentVariable("ChocolateyInstall", "User")
        if (-not [string]::IsNullOrWhiteSpace($userVal)) {
            $candidates.Add([pscustomobject]@{ Path = $userVal; Source = "env:User\ChocolateyInstall" }) | Out-Null
        }
    } catch { }

    # 4 & 5. Registry InstallLocation keys (64-bit + WOW6432Node)
    $registryKeys = @(
        "HKLM:\SOFTWARE\Chocolatey",
        "HKLM:\SOFTWARE\WOW6432Node\Chocolatey"
    )
    foreach ($key in $registryKeys) {
        try {
            $isKeyPresent = Test-Path -LiteralPath $key
            if (-not $isKeyPresent) { continue }
            $prop = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            $regVal = if ($prop) { $prop.InstallLocation } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($regVal)) {
                $candidates.Add([pscustomobject]@{ Path = $regVal; Source = "registry:$key\InstallLocation" }) | Out-Null
            }
        } catch {
            Write-ProbeLog "Could not read $key : $($_.Exception.Message)" "warn"
        }
    }

    # 6. choco.exe on PATH -> derive root from \bin\choco.exe
    try {
        $chocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
        if ($chocoCmd) {
            $binDir  = Split-Path -Parent $chocoCmd.Source
            $derived = Split-Path -Parent $binDir
            if (-not [string]::IsNullOrWhiteSpace($derived)) {
                $candidates.Add([pscustomobject]@{ Path = $derived; Source = "PATH:$($chocoCmd.Source)" }) | Out-Null
            }
        }
    } catch { }

    # 7. Default install location
    $defaultPath = Join-Path $env:ProgramData "chocolatey"
    $candidates.Add([pscustomobject]@{ Path = $defaultPath; Source = "default:$env:ProgramData\chocolatey" }) | Out-Null

    # Pick the first candidate whose path actually exists on disk
    foreach ($c in $candidates) {
        try {
            $isPresent = Test-Path -LiteralPath $c.Path
            if ($isPresent) {
                Write-ProbeLog "Resolved ChocolateyInstall root: $($c.Path) (via $($c.Source))" "info"
                # Cache in current session so subsequent callers skip the probe
                $env:ChocolateyInstall = $c.Path
                return $c.Path
            } else {
                Write-ProbeLog "Skipped ChocolateyInstall candidate (missing on disk): $($c.Path) [via $($c.Source)]" "warn"
            }
        } catch {
            Write-ProbeLog "Error testing ChocolateyInstall candidate $($c.Path): $($_.Exception.Message)" "warn"
        }
    }

    # Nothing exists -- log every probed location so the user can see why
    $hasWriteFileError = [bool](Get-Command Write-FileError -ErrorAction SilentlyContinue)
    if ($hasWriteFileError) {
        $probed = ($candidates | ForEach-Object { "$($_.Path) [$($_.Source)]" }) -join "; "
        Write-FileError -FilePath "ChocolateyInstall" -Operation "resolve-root" `
            -Reason "Could not find Chocolatey install root. Probed: $probed" -Module "Resolve-ChocolateyInstallRoot"
    }
    return $null
}

function Get-ChocoDiagnosticsDirectory {
    $logsRoot = $null
    $logsRootVariable = Get-Variable -Name _LogsDir -Scope Script -ErrorAction SilentlyContinue
    if ($logsRootVariable) {
        $logsRoot = $logsRootVariable.Value
    }
    $hasLogsRoot = -not [string]::IsNullOrWhiteSpace($logsRoot)
    if (-not $hasLogsRoot) {
        $scriptsRoot = Split-Path -Parent $PSScriptRoot
        $projectRoot = Split-Path -Parent $scriptsRoot
        $logsRoot = Join-Path $projectRoot ".logs"
    }

    $diagnosticsDir = Join-Path $logsRoot "installers"
    if (-not (Test-Path -LiteralPath $diagnosticsDir)) {
        try {
            New-Item -Path $diagnosticsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-FileError -FilePath $diagnosticsDir -Operation "write" -Reason "Could not create installer diagnostics directory: $_" -Module "Get-ChocoDiagnosticsDirectory"
        }
    }

    return $diagnosticsDir
}

function Save-ChocoDiagnosticLog {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [int]$ExitCode,

        [bool]$TimedOut,

        [int]$TimeoutSeconds,

        [string]$Stdout,

        [string]$Stderr
    )

    $diagnosticsDir = Get-ChocoDiagnosticsDirectory
    $safeLabel = ($Label.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $diagnosticPath = Join-Path $diagnosticsDir "${stamp}-${safeLabel}.log"
    $commandLine = "choco.exe " + (($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $packageHint = ($ArgumentList | Where-Object { $_ -and $_ -notmatch '^-' } | Select-Object -Skip 1 -First 1)
    if ([string]::IsNullOrWhiteSpace($packageHint)) { $packageHint = "<package>" }
    $failureKind = if ($TimedOut) { "Timed out" } else { "Failed" }

    $content = @"
Chocolatey installer diagnostic log
===================================

Status: $failureKind
Label: $Label
Command: $commandLine
Exit code: $ExitCode
Timed out: $TimedOut
Timeout seconds: $TimeoutSeconds
Timestamp: $(Get-Date -Format "o")

Actionable troubleshooting steps
--------------------------------
1. Re-run the command manually in an elevated PowerShell window:
   $commandLine
2. If it pauses for input, re-run with a longer timeout:
   `$env:CHOCO_TIMEOUT_SECONDS=3600
3. Check whether another installer is open or Windows Installer is locked:
   Get-Process msiexec,choco -ErrorAction SilentlyContinue
4. Clear a stale Chocolatey lock if no Chocolatey process is running:
   Remove-Item "$env:ProgramData\chocolatey\lib-bad" -Recurse -Force -ErrorAction SilentlyContinue
5. Check Chocolatey's own logs:
   "$env:ProgramData\chocolatey\logs\chocolatey.log"
6. Verify network/package access:
   choco search $packageHint --exact --verbose

STDOUT
------
$Stdout

STDERR
------
$Stderr
"@

    try {
        Set-Content -Path $diagnosticPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop
        return $diagnosticPath
    } catch {
        Write-FileError -FilePath $diagnosticPath -Operation "write" -Reason "Could not write Chocolatey diagnostic log: $_" -Module "Save-ChocoDiagnosticLog"
        return $null
    }
}

function ConvertTo-CleanChocoOutput {
    <#
    .SYNOPSIS
        Strips Chocolatey download/progress noise from captured output.
    .DESCRIPTION
        Chocolatey emits CR-separated progress lines like:
            "Progress: 79% - Saving 31.7 MB of 39.86 MB\rProgress: 80% ..."
        which flood logs with hundreds of useless updates. This helper:
          * splits on \r and \n so each progress tick becomes its own line,
          * drops every "Progress: NN%..." / "Saving X MB of Y MB..." line,
          * collapses repeated whitespace and blank lines,
          * keeps the final "Completed download of ..." summary line.
    #>
    param([string]$Text)

    $hasText = -not [string]::IsNullOrWhiteSpace($Text)
    if (-not $hasText) { return "" }

    # Normalize: split on \r OR \n so CR-overwritten progress ticks become lines
    $rawLines = $Text -split "(`r`n|`r|`n)"
    $kept = New-Object System.Collections.Generic.List[string]
    $lastWasBlank = $false

    foreach ($line in $rawLines) {
        $isLineSep = $line -match '^(\r\n|\r|\n)$'
        if ($isLineSep) { continue }

        $trimmed = $line.TrimEnd()

        # Drop pure progress ticks: "Progress: 79% - Saving 31.7 MB of 39.86 MB"
        $isProgress = $trimmed -match '^\s*Progress:\s*\d{1,3}\s*%'
        if ($isProgress) { continue }

        # Drop standalone size/percent lines occasionally emitted on their own
        $isSizeOnly = $trimmed -match '^\s*\d+(\.\d+)?\s*(KB|MB|GB)\s*(of\s+\d+(\.\d+)?\s*(KB|MB|GB))?\s*$'
        if ($isSizeOnly) { continue }

        $isBlank = [string]::IsNullOrWhiteSpace($trimmed)
        if ($isBlank -and $lastWasBlank) { continue }
        $lastWasBlank = $isBlank

        $kept.Add($trimmed) | Out-Null
    }

    return ($kept -join [Environment]::NewLine).Trim()
}

function ConvertFrom-ChocoOutput {
    <#
    .SYNOPSIS
        Parses Chocolatey output into a structured summary so callers can
        distinguish real errors from warnings, info noise, and stderr that
        Chocolatey routinely uses for non-fatal messages.
    .DESCRIPTION
        Chocolatey writes a lot to stderr that is NOT a failure: deprecation
        notices, "WARNING: ...", verbose hints, and even some success summaries
        on certain v2 packages. Counting any stderr text as an error produces
        false [ FAIL ] lines.

        This parser extracts:
          * InstalledCount / UpgradedCount / UninstalledCount / FailedCount
            from Chocolatey's end-of-run summary
            ("Chocolatey installed N/M packages." +
             " M packages failed." line that follows)
          * SuccessfulPackages / FailedPackages name lists from the
            "Failures" / "Warnings" sections
          * Per-line classification of stderr:
              - WarningLines  (start with "WARNING:" or "Warning:")
              - ErrorLines    (start with "ERROR:" / "FATAL:" / contain
                                "Exception calling", "is not recognized",
                                "Access is denied", "The system cannot find")
              - InfoLines     (everything else stderr emitted -- treated as
                                non-fatal noise, not as a failure signal)
          * HasInstallSuccess / HasUninstallSuccess / HasUpgradeSuccess
            textual markers
          * HasRealError     -- ErrorLines.Count -gt 0 OR FailedCount -gt 0
        Returned as a hashtable so existing callers can read whichever keys
        they need without breaking.
    #>
    param(
        [string]$Stdout,
        [string]$Stderr
    )

    $result = @{
        InstalledCount      = 0
        UpgradedCount       = 0
        UninstalledCount    = 0
        FailedCount         = 0
        SuccessfulPackages  = @()
        FailedPackages      = @()
        WarningLines        = @()
        ErrorLines          = @()
        InfoLines           = @()
        HasInstallSuccess   = $false
        HasUninstallSuccess = $false
        HasUpgradeSuccess   = $false
        IsNoOpAlreadyLatest = $false
        IsNoOpAlreadyInstalled = $false
        HasRealError        = $false
    }

    $combined = @()
    if (-not [string]::IsNullOrWhiteSpace($Stdout)) { $combined += $Stdout }
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) { $combined += $Stderr }
    $combinedText = ($combined -join [Environment]::NewLine)

    if (-not [string]::IsNullOrWhiteSpace($combinedText)) {
        # End-of-run summary lines
        $mInstalled = [regex]::Match($combinedText, '(?im)^\s*Chocolatey installed\s+(\d+)\s*/\s*(\d+)\s+packages?')
        if ($mInstalled.Success) {
            $result.InstalledCount = [int]$mInstalled.Groups[1].Value
            $totalInstall          = [int]$mInstalled.Groups[2].Value
            $result.HasInstallSuccess = ($result.InstalledCount -eq $totalInstall) -and ($totalInstall -gt 0)
        }
        $mUpgraded = [regex]::Match($combinedText, '(?im)^\s*Chocolatey upgraded\s+(\d+)\s*/\s*(\d+)\s+packages?')
        if ($mUpgraded.Success) {
            $result.UpgradedCount = [int]$mUpgraded.Groups[1].Value
            $totalUpgrade         = [int]$mUpgraded.Groups[2].Value
            $result.HasUpgradeSuccess = ($result.UpgradedCount -eq $totalUpgrade) -and ($totalUpgrade -gt 0)
        }
        $mUninstall = [regex]::Match($combinedText, '(?im)^\s*Chocolatey uninstalled\s+(\d+)\s*/\s*(\d+)\s+packages?')
        if ($mUninstall.Success) {
            $result.UninstalledCount = [int]$mUninstall.Groups[1].Value
            $totalUninstall          = [int]$mUninstall.Groups[2].Value
            $result.HasUninstallSuccess = ($result.UninstalledCount -eq $totalUninstall) -and ($totalUninstall -gt 0)
        }
        $mFailed = [regex]::Match($combinedText, '(?im)^\s*(\d+)\s+packages?\s+failed\.?')
        if ($mFailed.Success) {
            $result.FailedCount = [int]$mFailed.Groups[1].Value
        }

        # No-op success markers: package is already at latest, or already installed.
        # Chocolatey v2 sometimes reports "upgraded 0/1 packages" + non-zero exit
        # in this case, which is NOT a real failure -- there was simply nothing
        # to do. Capture these as explicit success signals.
        $isAlreadyLatest = $combinedText -match '(?im)is the latest version available based on your source' `
                            -or $combinedText -match '(?im)^\s*[^\r\n]+ v[\d\.]+ is the latest version available'
        if ($isAlreadyLatest -and ($result.UpgradedCount -eq 0) -and ($result.FailedCount -eq 0)) {
            $result.IsNoOpAlreadyLatest = $true
        }
        $isAlreadyInstalled = $combinedText -match '(?im)^\s*[^\r\n]+ v[\d\.]+ already installed\.?\s*$' `
                               -or $combinedText -match '(?im)Use --force to reinstall'
        if ($isAlreadyInstalled -and ($result.FailedCount -eq 0)) {
            $result.IsNoOpAlreadyInstalled = $true
        }

        # Per-package "The install of X was successful" / "Failures: - X"
        $successMatches = [regex]::Matches($combinedText, '(?im)The install of\s+([^\s]+)\s+was successful')
        foreach ($s in $successMatches) {
            if ($s.Groups[1].Success) { $result.SuccessfulPackages += $s.Groups[1].Value }
        }
        $failureSection = [regex]::Match($combinedText, '(?ims)Failures:\s*(.+?)(?:\r?\n\r?\n|\z)')
        if ($failureSection.Success) {
            $itemMatches = [regex]::Matches($failureSection.Groups[1].Value, '(?im)^\s*-\s*([^\s].*?)\s*$')
            foreach ($i in $itemMatches) {
                if ($i.Groups[1].Success) { $result.FailedPackages += $i.Groups[1].Value }
            }
        }
    }

    # Per-line stderr classification: WARNING lines are NOT errors, and most
    # of Chocolatey's stderr output is informational (logger noise).
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
        $lines = $Stderr -split "(`r`n|`r|`n)" | Where-Object { $_ -and ($_ -notmatch '^(\r\n|\r|\n)$') }
        foreach ($ln in $lines) {
            $t = $ln.TrimEnd()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }

            $isWarning = $t -match '^\s*(WARNING|Warning|WARN)\s*:'
            $isError   = ($t -match '^\s*(ERROR|FATAL)\s*:') `
                        -or ($t -match 'Exception calling') `
                        -or ($t -match "is not recognized as (?:an internal|the name)") `
                        -or ($t -match 'Access (?:is|to the path).*denied') `
                        -or ($t -match 'The system cannot find the (?:file|path) specified') `
                        -or ($t -match 'Unable to (?:resolve|find|locate) (?:package|dependency)') `
                        -or ($t -match 'A previous (?:transaction|chocolatey) operation is in progress')

            if ($isWarning -and -not $isError) {
                $result.WarningLines += $t
            } elseif ($isError) {
                $result.ErrorLines += $t
            } else {
                $result.InfoLines += $t
            }
        }
    }

    $result.HasRealError = ($result.ErrorLines.Count -gt 0) -or ($result.FailedCount -gt 0) -or ($result.FailedPackages.Count -gt 0)
    return $result
}

function Test-ChocoSuccessMarker {
    <#
    .SYNOPSIS
        Returns $true if Chocolatey output contains an unambiguous success marker.
    .DESCRIPTION
        Some Chocolatey package installers exit non-zero even when the package
        was installed/upgraded/uninstalled cleanly (e.g. nodejs-lts, bun in
        v2.7.x). Trust the textual success marker as a fallback.
    #>
    param([string]$Text)

    $hasText = -not [string]::IsNullOrWhiteSpace($Text)
    if (-not $hasText) { return $false }

    $isInstallSuccess     = $Text -match '(?im)^\s*The install of [^\r\n]+ was successful\.'
    $isUninstallSuccess   = $Text -match '(?im)^\s*The uninstall of [^\r\n]+ was successful\.'
    $isPackagesInstalled  = $Text -match '(?im)^\s*Chocolatey installed\s+(\d+)\s*/\s*\1\s+packages?'
    $isPackagesUpgraded   = $Text -match '(?im)^\s*Chocolatey upgraded\s+(\d+)\s*/\s*\1\s+packages?'
    $isPackagesUninstall  = $Text -match '(?im)^\s*Chocolatey uninstalled\s+(\d+)\s*/\s*\1\s+packages?'
    # No-op success markers (already at latest, already installed)
    $isAlreadyLatest      = $Text -match '(?im)is the latest version available based on your source'
    $isAlreadyInstalled   = $Text -match '(?im)^\s*[^\r\n]+ v[\d\.]+ already installed\.?\s*$'
    return ($isInstallSuccess -or $isUninstallSuccess -or $isPackagesInstalled -or $isPackagesUpgraded -or $isPackagesUninstall -or $isAlreadyLatest -or $isAlreadyInstalled)
}

function Invoke-ChocoProcess {
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$Label,

        [int]$TimeoutSeconds = (Get-ChocoTimeoutSeconds)
    )

    # Suppress Chocolatey's CR-progress firehose at the source. Safe for all
    # subcommands (install/upgrade/list/uninstall) and dramatically shrinks
    # captured stdout. Skip if the caller already passed --no-progress.
    $hasNoProgress = $ArgumentList -contains '--no-progress'
    if (-not $hasNoProgress) {
        $ArgumentList = @($ArgumentList) + '--no-progress'
    }

    $tempRoot = [System.IO.Path]::GetTempPath()
    $runId = [System.Guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $tempRoot "choco-$runId.out.log"
    $stderrPath = Join-Path $tempRoot "choco-$runId.err.log"

    try {
        Write-Log "[$Label] Timeout guard: ${TimeoutSeconds}s" -Level "info"
        $process = Start-Process -FilePath "choco.exe" -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        $hasExited = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $hasExited) {
            try {
                & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            } catch {
                try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
            }

            $rawStdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
            $rawStderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }
            $stdout = ConvertTo-CleanChocoOutput -Text $rawStdout
            $stderr = ConvertTo-CleanChocoOutput -Text $rawStderr
            $diagnosticPath = Save-ChocoDiagnosticLog -Label $Label -ArgumentList $ArgumentList -ExitCode -1 -TimedOut $true -TimeoutSeconds $TimeoutSeconds -Stdout $stdout -Stderr $stderr

            Write-Log "[$Label] TIMED OUT after ${TimeoutSeconds}s -- Chocolatey process tree killed" -Level "error"
            if (-not [string]::IsNullOrWhiteSpace($diagnosticPath)) {
                Write-Log "[$Label] Detailed installer log: $diagnosticPath" -Level "error"
                Write-Log "[$Label] Next: open that log, then retry the printed command in elevated PowerShell or raise CHOCO_TIMEOUT_SECONDS" -Level "info"
            }
            return @{ Success = $false; TimedOut = $true; ExitCode = -1; Output = "Timed out after ${TimeoutSeconds}s. Detailed installer log: $diagnosticPath"; DiagnosticPath = $diagnosticPath }
        }

        $rawStdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $rawStderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { "" }
        $stdout = ConvertTo-CleanChocoOutput -Text $rawStdout
        $stderr = ConvertTo-CleanChocoOutput -Text $rawStderr
        $outputParts = @($stdout, $stderr)
        $output = (($outputParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()

        # Structured parse: distinguish real errors from warnings / info noise.
        $parsed = ConvertFrom-ChocoOutput -Stdout $stdout -Stderr $stderr

        # Success rules (refined):
        #   * list/search        -> always success (read-only; "no match" is fine)
        #   * Exit 0 / 3010 / 1641 + no real error in parsed output -> success
        #   * Exit non-0 BUT parsed output shows a successful operation
        #     (HasInstallSuccess / HasUpgradeSuccess / HasUninstallSuccess)
        #     AND no real error / FailedCount=0 -> success (Chocolatey v2
        #     occasionally exits non-zero on clean ops; trust the structured
        #     summary over the exit code)
        #   * Otherwise -> failure
        $isExitSuccess     = ($process.ExitCode -eq 0) -or ($process.ExitCode -eq 3010) -or ($process.ExitCode -eq 1641)
        $isNoOpSuccess     = $parsed.IsNoOpAlreadyLatest -or $parsed.IsNoOpAlreadyInstalled
        $hasSuccessMarker  = $parsed.HasInstallSuccess -or $parsed.HasUpgradeSuccess -or $parsed.HasUninstallSuccess `
                              -or $isNoOpSuccess `
                              -or (Test-ChocoSuccessMarker -Text $output)
        $isSubcommandWrite = ($ArgumentList -contains 'install') -or `
                             ($ArgumentList -contains 'upgrade') -or `
                             ($ArgumentList -contains 'uninstall')
        $isSubcommandRead  = ($ArgumentList -contains 'list') -or ($ArgumentList -contains 'search')

        if ($isSubcommandRead) {
            $isSuccess = $true
        } elseif ($isExitSuccess) {
            # Trust exit 0 unless the parser found real errors AND no success marker
            $isSuccess = -not ($parsed.HasRealError -and -not $hasSuccessMarker)
        } elseif ($isSubcommandWrite -and $hasSuccessMarker -and -not $parsed.HasRealError) {
            # Includes no-op success (already at latest / already installed)
            # even when Chocolatey v2 returns a non-zero exit code.
            $isSuccess = $true
        } else {
            $isSuccess = $false
        }

        # Surface a single clear OK/WARN/FAIL line per choco call so the run
        # trace is unambiguous (previously success was silent while failure
        # was loud, which made false failures very confusing in the log).
        if ($isSuccess) {
            $warningCount = $parsed.WarningLines.Count
            $warningSuffix = if ($warningCount -gt 0) { " ($warningCount warning$(if ($warningCount -ne 1) { 's' })" + " ignored)" } else { "" }
            $noOpSuffix = ""
            if ($parsed.IsNoOpAlreadyLatest)    { $noOpSuffix = " (already at latest version -- nothing to upgrade)" }
            elseif ($parsed.IsNoOpAlreadyInstalled) { $noOpSuffix = " (already installed -- nothing to do)" }
            if ($isExitSuccess) {
                if (-not $isSubcommandRead) {
                    Write-Log "[$Label] Completed successfully (exit $($process.ExitCode))$noOpSuffix$warningSuffix." -Level "success"
                }
            } elseif ($isSubcommandWrite) {
                if ($isNoOpSuccess) {
                    Write-Log "[$Label] Exit code $($process.ExitCode) but Chocolatey reported nothing to do$noOpSuffix -- treating as success$warningSuffix." -Level "info"
                } else {
                    Write-Log "[$Label] Exit code $($process.ExitCode) but Chocolatey reported a successful operation -- treating as success$warningSuffix." -Level "info"
                }
            }
        }

        $diagnosticPath = $null
        if (-not $isSuccess) {
            $diagnosticPath = Save-ChocoDiagnosticLog -Label $Label -ArgumentList $ArgumentList -ExitCode $process.ExitCode -TimedOut $false -TimeoutSeconds $TimeoutSeconds -Stdout $stdout -Stderr $stderr
            $errSummary = if ($parsed.ErrorLines.Count -gt 0) { " -- " + ($parsed.ErrorLines | Select-Object -First 1) } `
                          elseif ($parsed.FailedPackages.Count -gt 0) { " -- failed package(s): " + (($parsed.FailedPackages | Select-Object -First 3) -join ', ') } `
                          else { "" }
            Write-Log "[$Label] FAILED (exit $($process.ExitCode))$errSummary." -Level "error"
            if (-not [string]::IsNullOrWhiteSpace($diagnosticPath)) {
                Write-Log "[$Label] Detailed installer log: $diagnosticPath" -Level "error"
                Write-Log "[$Label] Next: open that log, then retry the printed command in elevated PowerShell" -Level "info"
            }
        }

        return @{ Success = $isSuccess; TimedOut = $false; ExitCode = $process.ExitCode; Output = $output; Stdout = $stdout; Stderr = $stderr; Parsed = $parsed; DiagnosticPath = $diagnosticPath }
    } catch {
        Write-FileError -FilePath "choco.exe" -Operation "resolve" -Reason "Failed to start Chocolatey command '$Label': $_" -Module "Invoke-ChocoProcess"
        return @{ Success = $false; TimedOut = $false; ExitCode = -1; Output = $_.Exception.Message; DiagnosticPath = $null }
    } finally {
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path $path) {
                Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Assert-Choco {
    <#
    .SYNOPSIS
        Ensures Chocolatey is installed. Installs it if missing.
        Returns $true if available after the check.
    #>

    $slm = $script:SharedLogMessages

    Write-Log $slm.messages.chocoChecking -Level "info"
    $chocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue

    if ($chocoCmd) {
        $version = & choco.exe --version 2>&1
        Write-Log ($slm.messages.chocoFound -replace '\{version\}', $version) -Level "success"
        return $true
    }

    Write-Log $slm.messages.chocoNotFound -Level "warn"
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

        # Refresh PATH for current session
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

        $chocoCmd = Get-Command choco.exe -ErrorAction SilentlyContinue
        $isChocoAvailable = $null -ne $chocoCmd
        if ($isChocoAvailable) {
            Write-Log $slm.messages.chocoInstalled -Level "success"
            return $true
        }

        Write-Log $slm.messages.chocoNotInPath -Level "error"
        return $false
    } catch {
        Write-Log ($slm.messages.chocoInstallFailed -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Install-ChocoPackage {
    <#
    .SYNOPSIS
        Installs a Chocolatey package if not already installed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageName,

        [string]$Version,

        [string[]]$ExtraArgs = @()
    )

    $slm = $script:SharedLogMessages

    $isChocoReady = Assert-Choco
    $hasNoChoco = -not $isChocoReady
    if ($hasNoChoco) {
        return $false
    }

    Write-Log ($slm.messages.chocoCheckingPackage -replace '\{package\}', $PackageName) -Level "info"

    # NOTE: Chocolatey v2 removed --local-only (list is local by default).
    # `choco list` may exit non-zero in v2 when nothing matches -- we ONLY
    # care about its stdout, so don't treat list-itself failure as fatal.
    $installedResult = Invoke-ChocoProcess -ArgumentList @("list", "--exact", $PackageName) -Label "choco list $PackageName" -TimeoutSeconds 120
    $installed = $installedResult.Output
    # Match "<package> <version>" line; "0 packages installed" means not installed.
    $isAlreadyInstalled = ($installed -match "(?im)^\s*$([regex]::Escape($PackageName))\s+\d") `
        -and ($installed -notmatch "0 packages installed")
    if ($isAlreadyInstalled) {
        Write-Log ($slm.messages.chocoPackageInstalled -replace '\{package\}', $PackageName) -Level "success"
        return $true
    }

    Write-Log ($slm.messages.chocoInstallingPackage -replace '\{package\}', $PackageName) -Level "info"
    try {
        $args = @("install", $PackageName, "-y")
        $hasVersion = -not [string]::IsNullOrWhiteSpace($Version)
        if ($hasVersion) {
            $args += @("--version", $Version)
        }

        $hasExtraArgs = $null -ne $ExtraArgs -and $ExtraArgs.Count -gt 0
        if ($hasExtraArgs) {
            $args += $ExtraArgs
        }

        $result = Invoke-ChocoProcess -ArgumentList $args -Label "choco install $PackageName"
        $output = $result.Output

        # Safety net: if the wrapper marked failure but Chocolatey clearly
        # reported "The install of <pkg> was successful." or
        # "Chocolatey installed N/N packages." for THIS package -- and there
        # are no real errors in the parsed output -- promote to success.
        # Prevents false [ FAIL ] on packages that exit non-zero on clean
        # installs (golang msi, nodejs-lts, bun, etc).
        $hasInstallFailed = -not $result.Success
        if ($hasInstallFailed) {
            $hasMarker = Test-ChocoSuccessMarker -Text $output
            $parsedHasError = $false
            if ($result.ContainsKey('Parsed') -and $null -ne $result.Parsed) {
                $parsedHasError = [bool]$result.Parsed.HasRealError
            }
            if ($hasMarker -and -not $parsedHasError) {
                Write-Log "[choco install $PackageName] Promoting to success: textual success marker found and no real errors parsed (exit code $($result.ExitCode) ignored)." -Level "warn"
                $hasInstallFailed = $false
            }
        }

        if ($hasInstallFailed) {
            Write-Log ($slm.messages.chocoPackageInstallFailed -replace '\{package\}', $PackageName -replace '\{output\}', $output) -Level "error"
            return $false
        }

        Write-Log ($slm.messages.chocoPackageInstallSuccess -replace '\{package\}', $PackageName) -Level "success"
        return $true
    } catch {
        Write-Log ($slm.messages.chocoPackageInstallError -replace '\{package\}', $PackageName -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Upgrade-ChocoPackage {
    <#
    .SYNOPSIS
        Upgrades a Chocolatey package to the latest version.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageName
    )

    $slm = $script:SharedLogMessages

    $isChocoReady = Assert-Choco
    $hasNoChoco = -not $isChocoReady
    if ($hasNoChoco) {
        return $false
    }

    Write-Log ($slm.messages.chocoUpgradingPackage -replace '\{package\}', $PackageName) -Level "info"
    try {
        $result = Invoke-ChocoProcess -ArgumentList @("upgrade", $PackageName, "-y") -Label "choco upgrade $PackageName"
        $output = $result.Output
        $hasUpgradeFailed = -not $result.Success
        if ($hasUpgradeFailed) {
            Write-Log ($slm.messages.chocoUpgradeFailed -replace '\{package\}', $PackageName -replace '\{output\}', $output) -Level "warn"
            return $false
        }

        Write-Log ($slm.messages.chocoUpgradeSuccess -replace '\{package\}', $PackageName) -Level "success"
        return $true
    } catch {
        Write-Log ($slm.messages.chocoUpgradeError -replace '\{package\}', $PackageName -replace '\{error\}', $_) -Level "error"
        return $false
    }
}

function Uninstall-ChocoPackage {
    <#
    .SYNOPSIS
        Uninstalls a Chocolatey package.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PackageName
    )

    $slm = $script:SharedLogMessages

    $isChocoReady = Assert-Choco
    $hasNoChoco = -not $isChocoReady
    if ($hasNoChoco) {
        return $false
    }

    Write-Log "Uninstalling Chocolatey package: $PackageName" -Level "info"
    try {
        $result = Invoke-ChocoProcess -ArgumentList @("uninstall", $PackageName, "-y", "--remove-dependencies") -Label "choco uninstall $PackageName"
        $output = $result.Output
        $hasUninstallFailed = -not $result.Success
        if ($hasUninstallFailed) {
            Write-Log "Chocolatey uninstall failed for $PackageName : $output" -Level "error"
            return $false
        }

        Write-Log "Chocolatey package uninstalled: $PackageName" -Level "success"
        return $true
    } catch {
        Write-Log "Chocolatey uninstall error for $PackageName : $_" -Level "error"
        return $false
    }
}
