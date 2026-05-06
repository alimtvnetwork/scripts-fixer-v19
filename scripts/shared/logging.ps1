<#
.SYNOPSIS
    Shared logging helpers used by all scripts in this repo.
    Logs are written to scripts/logs/ as structured JSON files.
#>

# ── Module-scoped log state ──────────────────────────────────────────────────
$script:_LogEvents   = [System.Collections.ArrayList]::new()
$script:_LogErrors   = [System.Collections.ArrayList]::new()
$script:_LogWarnings = [System.Collections.ArrayList]::new()
$script:_LogName     = $null
$script:_LogStart    = $null
$script:_LogsDir     = $null
# Cached identity fields (resolved once per session, stamped into every event
# so log lines stay traceable even after grep / split / concat).
$script:_LogIdentity = $null
# When set to $true (typically by Test-AlreadyInstalled), Save-LogFile promotes
# a successful "ok" status to "already-installed" in the JSON + console summary.
$script:_LogAlreadyInstalled = $false

function Set-LogAlreadyInstalled {
    <#
    .SYNOPSIS
        Marks this script run as a no-op "already installed" rerun. When the
        run finishes successfully, Save-LogFile records status="already-installed"
        instead of "ok" so repeated installs report consistently.
    #>
    param([bool]$Value = $true)
    $script:_LogAlreadyInstalled = $Value
}

function Get-LogAlreadyInstalled {
    <# .SYNOPSIS Returns the current "already installed" flag. #>
    return [bool]$script:_LogAlreadyInstalled
}

function ConvertTo-LogSafeMessage {
    <#
    .SYNOPSIS
        Strips Chocolatey-style carriage-return progress noise from any log
        message before it reaches the console or the JSON event log.
    .DESCRIPTION
        Catches the case where raw choco/installer output is passed straight to
        Write-Log / Write-FileError without going through ConvertTo-CleanChocoOutput.
        Splits on \r and \n, drops every:
          * "Progress: NN% ..." tick (with or without "Saving X MB of Y MB"),
          * "X.YY MB of Z.ZZ MB" standalone size lines,
          * 100%-completion ticks,
        collapses runs of whitespace, and joins the survivors with " | ".
        If the cleaned result is empty (input was 100% noise), returns
        "[chocolatey progress noise suppressed]" so the event still has a body.
    #>
    param([string]$Text)

    $hasText = -not [string]::IsNullOrWhiteSpace($Text)
    if (-not $hasText) { return $Text }

    # Fast path: nothing in the string looks like progress noise
    $hasProgressNoise = ($Text -match 'Progress:\s*\d{1,3}\s*%') -or ($Text -match "`r")
    if (-not $hasProgressNoise) { return $Text }

    $rawLines = $Text -split "(`r`n|`r|`n)"
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in $rawLines) {
        $isLineSep = $line -match '^(\r\n|\r|\n)$'
        if ($isLineSep) { continue }

        $trimmed = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        $isProgress = $trimmed -match '^\s*Progress:\s*\d{1,3}\s*%'
        if ($isProgress) { continue }

        $isSizeOnly = $trimmed -match '^\s*\d+(\.\d+)?\s*(KB|MB|GB)\s*(of\s+\d+(\.\d+)?\s*(KB|MB|GB))?\s*$'
        if ($isSizeOnly) { continue }

        $kept.Add($trimmed) | Out-Null
    }

    $hasKept = $kept.Count -gt 0
    if (-not $hasKept) { return "[chocolatey progress noise suppressed]" }
    return ($kept -join " | ")
}

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [string]$Status = "info",

        [string]$Level
    )

    # ------------------------------------------------------------------
    # CODE RED guarantee: Write-Log is called from EVERY script. If it
    # ever throws, the caller's stack trace points to the Write-Log call
    # site (e.g. "logging.ps1:697 Write-Log $msgLoading") which is highly
    # misleading. The real bug is always inside this function. To prevent
    # that whole class of "Cannot index into a null array" / "property
    # not found" errors that have repeatedly leaked out from internal
    # niceties (badge lookup, version highlighting, identity stamping,
    # event recording), we wrap the entire body in a defensive try/catch.
    # On any internal failure we fall back to a plain Write-Host so the
    # message still reaches the user and the caller is NEVER aborted.
    # ------------------------------------------------------------------
    try {
        # Defensive scrub: drop \r-progress noise even when callers forget to
        # sanitize at the source.
        if ($null -eq $Message) { $Message = '' }
        try { $Message = ConvertTo-LogSafeMessage -Text $Message } catch { }
        if ($null -eq $Message) { $Message = '' }

        # -Level alias: map new-style names to old-style names
        if ($Level) {
            $Status = switch ($Level.ToLower()) {
                "success" { "ok" }
                "error"   { "fail" }
                default   { $Level }
            }
        }

        # Validate
        $validStatuses = @("ok", "fail", "info", "warn", "skip")
        if ($Status -notin $validStatuses) { $Status = "info" }

        # Resolve the colored badge for this $Status. The lookup must survive
        # every shape $script:LogMessages can be in. Any failure -> fallback.
        $badge = $null
        try {
            $varInfo = Get-Variable -Name LogMessages -Scope Script -ErrorAction SilentlyContinue
            if ($varInfo -and $null -ne $varInfo.Value) {
                $lm = $varInfo.Value
                $statusContainer = $null
                try {
                    $statusProp = $lm.PSObject.Properties['status']
                    if ($statusProp) { $statusContainer = $statusProp.Value }
                } catch { $statusContainer = $null }
                if ($null -ne $statusContainer) {
                    try {
                        $badgeProp = $statusContainer.PSObject.Properties[$Status]
                        if ($badgeProp -and -not [string]::IsNullOrWhiteSpace([string]$badgeProp.Value)) {
                            $badge = [string]$badgeProp.Value
                        }
                    } catch { $badge = $null }
                }
            }
        } catch { $badge = $null }
        if ([string]::IsNullOrWhiteSpace($badge)) {
            $fallbackBadges = @{ ok = "[  OK  ]"; fail = "[ FAIL ]"; info = "[ INFO ]"; warn = "[ WARN ]"; skip = "[ SKIP ]" }
            $badge = $fallbackBadges[$Status]
            if ([string]::IsNullOrWhiteSpace($badge)) { $badge = "[ INFO ]" }
        }

        $colors = @{
            ok   = "Green"
            fail = "Red"
            info = "Cyan"
            warn = "Yellow"
            skip = "DarkGray"
        }
        $statusColor = $colors[$Status]
        if ([string]::IsNullOrWhiteSpace($statusColor)) { $statusColor = "Gray" }

        Write-Host "  $badge " -ForegroundColor $statusColor -NoNewline

        # Highlight version numbers in a distinct color. Wrapped in its own
        # try/catch because [regex]::Split / IsMatch on hostile inputs has
        # been the source of past "Cannot index into a null array" reports
        # on Windows PowerShell 5.1 under Set-StrictMode -Version Latest.
        $printedColored = $false
        try {
            $versionPattern = '(v?\d+\.\d+[\.\d]*[a-zA-Z0-9\-\.]*)'
            $parts = $null
            try { $parts = [regex]::Split([string]$Message, $versionPattern) } catch { $parts = $null }
            if ($null -ne $parts -and $parts.Count -gt 0) {
                foreach ($part in $parts) {
                    if ($null -eq $part) { continue }
                    $partStr = [string]$part
                    if ($partStr.Length -eq 0) { continue }
                    $isVersion = $false
                    try { $isVersion = [regex]::IsMatch($partStr, "^$versionPattern$") } catch { $isVersion = $false }
                    if ($isVersion) {
                        Write-Host $partStr -ForegroundColor Yellow -NoNewline
                    } else {
                        Write-Host $partStr -NoNewline
                    }
                }
                $printedColored = $true
            }
        } catch { $printedColored = $false }
        if (-not $printedColored) {
            # Safe fallback: print the message verbatim, no highlighting.
            Write-Host ([string]$Message) -NoNewline
        }
        Write-Host ""

        # Record structured event. Wrapped so identity / list failures
        # never abort the caller.
        try {
            $hasCachedIdentity = $null -ne $script:_LogIdentity
            if (-not $hasCachedIdentity) {
                try { $script:_LogIdentity = Get-LogIdentityFields } catch {
                    $script:_LogIdentity = @{ projectVersion = "unknown"; invokedFrom = "unknown"; gitSha = "unknown"; gitShaFull = "unknown"; gitBranch = "unknown"; gitDirty = $false; gitRemote = "unknown" }
                }
            }
            # Pull identity fields defensively -- $script:_LogIdentity may be a
            # hashtable OR a PSCustomObject depending on which fallback branch
            # populated it.
            $idProjectVersion = "unknown"
            $idInvokedFrom    = "unknown"
            $idGitSha         = "unknown"
            $idGitBranch      = "unknown"
            try {
                if ($null -ne $script:_LogIdentity) {
                    if ($script:_LogIdentity -is [hashtable]) {
                        if ($script:_LogIdentity.ContainsKey('projectVersion')) { $idProjectVersion = [string]$script:_LogIdentity['projectVersion'] }
                        if ($script:_LogIdentity.ContainsKey('invokedFrom'))    { $idInvokedFrom    = [string]$script:_LogIdentity['invokedFrom'] }
                        if ($script:_LogIdentity.ContainsKey('gitSha'))         { $idGitSha         = [string]$script:_LogIdentity['gitSha'] }
                        if ($script:_LogIdentity.ContainsKey('gitBranch'))      { $idGitBranch      = [string]$script:_LogIdentity['gitBranch'] }
                    } else {
                        $idProps = $script:_LogIdentity.PSObject.Properties
                        if ($idProps['projectVersion']) { $idProjectVersion = [string]$idProps['projectVersion'].Value }
                        if ($idProps['invokedFrom'])    { $idInvokedFrom    = [string]$idProps['invokedFrom'].Value }
                        if ($idProps['gitSha'])         { $idGitSha         = [string]$idProps['gitSha'].Value }
                        if ($idProps['gitBranch'])      { $idGitBranch      = [string]$idProps['gitBranch'].Value }
                    }
                }
            } catch { }

            $logName = $null
            try {
                $logNameVar = Get-Variable -Name _LogName -Scope Script -ErrorAction SilentlyContinue
                if ($logNameVar) { $logName = $logNameVar.Value }
            } catch { }

            $event = [ordered]@{
                timestamp      = (Get-Date -Format "o")
                level          = $Status
                message        = $Message
                projectVersion = $idProjectVersion
                invokedFrom    = $idInvokedFrom
                gitSha         = $idGitSha
                gitBranch      = $idGitBranch
                scriptName     = $logName
            }

            # Lazily ensure the event arrays exist (re-sourcing logging.ps1
            # in the same session can leave them in an unexpected state on
            # Windows PowerShell 5.1).
            if ($null -eq $script:_LogEvents)   { $script:_LogEvents   = [System.Collections.ArrayList]::new() }
            if ($null -eq $script:_LogErrors)   { $script:_LogErrors   = [System.Collections.ArrayList]::new() }
            if ($null -eq $script:_LogWarnings) { $script:_LogWarnings = [System.Collections.ArrayList]::new() }

            $null = $script:_LogEvents.Add($event)
            if ($Status -eq "fail") { $null = $script:_LogErrors.Add($event) }
            if ($Status -eq "warn") { $null = $script:_LogWarnings.Add($event) }
        } catch { } # Recording failures must never bubble up.
    } catch {
        # Last-resort fallback: a guaranteed plain print so the caller
        # still sees the message and is never aborted by Write-Log.
        try {
            $safeMsg = if ($null -eq $Message) { '' } else { [string]$Message }
            Write-Host "  [ INFO ] $safeMsg"
        } catch { }
    }
}

function Write-FileError {
    <#
    .SYNOPSIS
        CODE RED: Logs a file/path error with exact path, operation, and failure reason.
        All file-related errors in the project MUST use this helper.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$Reason,

        [string]$Module,

        [string]$Fallback
    )

    # Defensive scrub: drop \r-progress noise from Reason/Fallback before they
    # land in the [CODE RED] line and the structured error JSON.
    $Reason = ConvertTo-LogSafeMessage -Text $Reason
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) {
        $Fallback = ConvertTo-LogSafeMessage -Text $Fallback
    }

    # Soft-validate Operation: never crash the caller for an unknown verb.
    # Older callers (or new verbs added in newer scripts running against an
    # older shared logger) MUST NOT bring the whole script down. Unknown verbs
    # are accepted as-is and the original CODE RED log line is still emitted
    # with the exact path + reason, which is the contract that matters.
    $knownOperations = @(
        "read", "write", "copy", "move", "inject", "load", "extract", "resolve",
        "install", "delete", "execute", "download", "parse",
        "backup", "checksum", "create", "fetch", "mkdir", "symlink", "verify",
        "configure-pnpm-store", "create-pnpm-store-dir", "probe-prefix-drive",
        "probe-prefix-write", "create-prefix-dir", "resolve-npm", "npm-mkdir-prefix",
        "resolve-root", "validate", "validate-goroot-layout", "set-goroot",
        "invoke-child", "batch-prepare", "batch-verify"
    )
    $isUnknownOperation = $Operation -notin $knownOperations
    if ($isUnknownOperation) {
        Write-Log ("[CODE RED] Unknown Write-FileError Operation '{0}' -- accepting as-is so logging cannot mask the real error" -f $Operation) -Level "warn"
    }

    # Auto-detect module from call stack if not provided
    $isModuleMissing = [string]::IsNullOrWhiteSpace($Module)
    if ($isModuleMissing) {
        $caller = (Get-PSCallStack)[1]
        $Module = if ($caller.ScriptName) { Split-Path -Leaf $caller.ScriptName } else { "unknown" }
    }

    $msg = "[CODE RED] File error during ${Operation}: ${FilePath} -- Reason: ${Reason} [Module: ${Module}]"
    $hasFallback = -not [string]::IsNullOrWhiteSpace($Fallback)
    if ($hasFallback) {
        $msg += " -- Fallback: ${Fallback}"
    }

    Write-Log $msg -Level "error"

    # Record structured file-error event (also stamped with identity)
    $hasCachedIdentity = $null -ne $script:_LogIdentity
    if (-not $hasCachedIdentity) {
        try { $script:_LogIdentity = Get-LogIdentityFields } catch {
            $script:_LogIdentity = @{ projectVersion = "unknown"; invokedFrom = "unknown"; gitSha = "unknown"; gitShaFull = "unknown"; gitBranch = "unknown"; gitDirty = $false; gitRemote = "unknown" }
        }
    }
    $fileErrorEvent = [ordered]@{
        timestamp      = (Get-Date -Format "o")
        level          = "fail"
        type           = "file-error"
        filePath       = $FilePath
        operation      = $Operation
        reason         = $Reason
        module         = $Module
        fallback       = if ($hasFallback) { $Fallback } else { $null }
        message        = $msg
        projectVersion = $script:_LogIdentity.projectVersion
        invokedFrom    = $script:_LogIdentity.invokedFrom
        gitSha         = $script:_LogIdentity.gitSha
        gitBranch      = $script:_LogIdentity.gitBranch
        scriptName     = $script:_LogName
    }
    $script:_LogEvents.Add($fileErrorEvent) | Out-Null
    $script:_LogErrors.Add($fileErrorEvent) | Out-Null
}

function Write-Banner {
    param(
        [Parameter(Position = 0)]
        [string[]]$Lines,

        [Parameter(Position = 1)]
        [string]$Color = "Magenta",

        [string]$Title,
        [string]$Version
    )

    # New-style: -Title and -Version params
    if ($Title) {
        # Always read version from the central scripts/version.json
        $versionFilePath = Join-Path (Split-Path -Parent $PSScriptRoot) "version.json"
        $isShared = (Split-Path -Leaf $PSScriptRoot) -eq "shared"
        if ($isShared) {
            $versionFilePath = Join-Path (Split-Path -Parent $PSScriptRoot) "version.json"
        }
        $hasVersionFile = Test-Path $versionFilePath
        if ($hasVersionFile) {
            $versionData = Get-Content $versionFilePath -Raw | ConvertFrom-Json
            $Version = $versionData.version
        }

        $header = if ($Version) { "$Title -- v$Version" } else { $Title }
        $border = "-" * ([Math]::Max($header.Length + 6, 60))
        $Lines = @($border, "  $header", $border)
    }

    Write-Host ""
    foreach ($line in $Lines) { Write-Host $line -ForegroundColor $Color }
    Write-Host ""
}

function Initialize-Logging {
    param(
        [Parameter(Position = 0)]
        [string]$ScriptName
    )

    # Resolve .logs/ directory at project root (parent of scripts/)
    $scriptsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $isSharedDir = (Split-Path -Leaf $PSScriptRoot) -eq "shared"
    if ($isSharedDir) {
        $scriptsRoot = Split-Path -Parent $PSScriptRoot
    }
    $projectRoot = Split-Path -Parent $scriptsRoot
    $logsDir = Join-Path $projectRoot ".logs"

    # Create .logs dir if missing
    $isLogsDirMissing = -not (Test-Path $logsDir)
    if ($isLogsDirMissing) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }

    # Sanitise script name for filename (e.g. "Install Golang" -> "golang")
    $safeName = $ScriptName.ToLower() -replace '[^a-z0-9]+', '-'
    $safeName = $safeName.Trim('-')

    # Store state
    $script:_LogsDir   = $logsDir
    $script:_LogName   = $safeName
    $script:_LogStart  = Get-Date
    $script:_LogEvents   = [System.Collections.ArrayList]::new()
    $script:_LogErrors   = [System.Collections.ArrayList]::new()
    $script:_LogWarnings = [System.Collections.ArrayList]::new()
    $script:_LogAlreadyInstalled = $false

    # Resolve identity ONCE per session and cache it. Every event written via
    # Write-Log / Write-FileError will copy these two fields onto its own
    # record so individual log lines stay traceable after grep / split / merge.
    try { $script:_LogIdentity = Get-LogIdentityFields } catch {
        $script:_LogIdentity = @{ projectVersion = "unknown"; invokedFrom = "unknown"; gitSha = "unknown"; gitShaFull = "unknown"; gitBranch = "unknown"; gitDirty = $false; gitRemote = "unknown" }
    }

    Write-Log "Logging initialised -- events will be saved to: $logsDir\$safeName.json" -Level "info"
}

function Get-LogIdentityFields {
    <#
    .SYNOPSIS
        Returns @{ projectVersion = "X.Y.Z"; invokedFrom = "scripts/.../run.ps1" }
        for stamping into every .logs/*.json payload so log files are
        self-identifying without reading the surrounding repo state.
        Both fields are best-effort -- never throw.
    #>
    $projectVersion = "unknown"
    $invokedFrom    = "unknown"
    $gitSha         = "unknown"
    $gitShaFull     = "unknown"
    $gitBranch      = "unknown"
    $gitDirty       = $false
    $gitRemote      = "unknown"

    try {
        # Resolve project root the same way Initialize-Logging does.
        $scriptsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $isSharedDir = (Split-Path -Leaf $PSScriptRoot) -eq "shared"
        if ($isSharedDir) {
            $scriptsRoot = Split-Path -Parent $PSScriptRoot
        }
        $projectRoot = Split-Path -Parent $scriptsRoot

        # ----- git identity (best-effort, never throws) -----
        try {
            $gitDir = Join-Path $projectRoot ".git"
            if (Test-Path -LiteralPath $gitDir) {
                Push-Location -LiteralPath $projectRoot
                try {
                    $sha = (& git rev-parse --short=12 HEAD 2>$null) | Select-Object -First 1
                    if ($sha) { $gitSha = "$sha".Trim() }
                    $shaFull = (& git rev-parse HEAD 2>$null) | Select-Object -First 1
                    if ($shaFull) { $gitShaFull = "$shaFull".Trim() }
                    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null) | Select-Object -First 1
                    if ($branch) { $gitBranch = "$branch".Trim() }
                    $remote = (& git config --get remote.origin.url 2>$null) | Select-Object -First 1
                    if ($remote) { $gitRemote = "$remote".Trim() }
                    $status = (& git status --porcelain 2>$null)
                    if ($status) { $gitDirty = $true }
                } finally { Pop-Location }
            }
        } catch { }

        # ----- projectVersion : read scripts/version.json -----
        $versionFile = Join-Path $scriptsRoot "version.json"
        $hasVersionFile = Test-Path -LiteralPath $versionFile
        if ($hasVersionFile) {
            try {
                $vd = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
                if ($vd.version) { $projectVersion = "$($vd.version)" }
            } catch {
                Write-Log "logging: failed to read version.json at ${versionFile}: $($_.Exception.Message)" -Level "warn"
            }
        } else {
            Write-Log "logging: version.json missing at ${versionFile} -- projectVersion=unknown" -Level "warn"
        }

        # ----- invokedFrom : top-of-callstack script, relative to project root -----
        try {
            $stack = Get-PSCallStack
            $thisFile = $PSCommandPath
            $candidate = $null
            # Walk from the bottom (oldest frame) and pick the first frame whose
            # ScriptName lives under the project root and is NOT this logging file.
            for ($i = $stack.Count - 1; $i -ge 0; $i--) {
                $sn = $stack[$i].ScriptName
                if ([string]::IsNullOrWhiteSpace($sn)) { continue }
                if ($sn -eq $thisFile) { continue }
                if ($sn.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $candidate = $sn
                    break
                }
            }
            if (-not $candidate) {
                # Fall back to the very last non-logging frame, even if outside the repo.
                for ($i = $stack.Count - 1; $i -ge 0; $i--) {
                    $sn = $stack[$i].ScriptName
                    if (-not [string]::IsNullOrWhiteSpace($sn) -and $sn -ne $thisFile) {
                        $candidate = $sn
                        break
                    }
                }
            }
            if ($candidate) {
                if ($candidate.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $candidate.Substring($projectRoot.Length).TrimStart('\','/')
                    $invokedFrom = ($rel -replace '\\','/')
                } else {
                    # Outside the repo -- store the absolute path so the log is still useful.
                    $invokedFrom = $candidate
                }
            }
        } catch {
            Write-Log "logging: callstack resolution failed: $($_.Exception.Message)" -Level "warn"
        }
    } catch {
        # Total fallback -- both fields stay "unknown".
    }

    return @{
        projectVersion = $projectVersion
        invokedFrom    = $invokedFrom
        gitSha         = $gitSha
        gitShaFull     = $gitShaFull
        gitBranch      = $gitBranch
        gitDirty       = $gitDirty
        gitRemote      = $gitRemote
    }
}

function Save-LogFile {
    <#
    .SYNOPSIS
        Flush collected log events to scripts/logs/<name>.json
        and scripts/logs/<name>-error.json (if errors exist).
    #>
    param(
        [string]$Status = "ok"
    )

    $isNotInitialised = -not $script:_LogsDir
    if ($isNotInitialised) { return }

    $endTime  = Get-Date
    $duration = ($endTime - $script:_LogStart).TotalSeconds

    # Promote "ok" -> "already-installed" when the run was a verified no-op.
    # We only promote on a clean success; any errors/warnings keep their status.
    $isCleanOk = ($Status -eq "ok") -and ($script:_LogErrors.Count -eq 0)
    if ($isCleanOk -and $script:_LogAlreadyInstalled) {
        $Status = "already-installed"
    }

    # Identity fields stamped into every log payload (v0.42.2+) AND into
    # every event entry (v0.43.1+). Reuse the cached value from
    # Initialize-Logging so we don't walk the call stack twice.
    $hasCachedIdentity = $null -ne $script:_LogIdentity
    if ($hasCachedIdentity) {
        $identity = $script:_LogIdentity
    } else {
        $identity = Get-LogIdentityFields
    }

    # Main log file
    $logData = [ordered]@{
        projectVersion = $identity.projectVersion
        invokedFrom    = $identity.invokedFrom
        gitSha         = $identity.gitSha
        gitShaFull     = $identity.gitShaFull
        gitBranch      = $identity.gitBranch
        gitDirty       = $identity.gitDirty
        gitRemote      = $identity.gitRemote
        scriptName     = $script:_LogName
        status         = $Status
        startTime      = $script:_LogStart.ToString("o")
        endTime        = $endTime.ToString("o")
        duration       = [math]::Round($duration, 2)
        eventCount     = $script:_LogEvents.Count
        errorCount     = $script:_LogErrors.Count
        warnCount      = $script:_LogWarnings.Count
        events         = @($script:_LogEvents)
    }

    $logPath = Join-Path $script:_LogsDir "$($script:_LogName).json"
    $logData | ConvertTo-Json -Depth 5 | Set-Content -Path $logPath -Encoding UTF8
    Write-Host "  [  OK  ] Log saved: $logPath" -ForegroundColor Green

    # Error/warning log file -- written when there are errors, warnings, or overall failure
    $hasErrors = $script:_LogErrors.Count -gt 0
    $hasWarnings = $script:_LogWarnings.Count -gt 0
    $isOverallFailure = $Status -eq "fail"
    $shouldWriteErrorLog = $hasErrors -or $hasWarnings -or $isOverallFailure
    if ($shouldWriteErrorLog) {
        $errorData = [ordered]@{
            projectVersion = $identity.projectVersion
            invokedFrom    = $identity.invokedFrom
            gitSha         = $identity.gitSha
            gitShaFull     = $identity.gitShaFull
            gitBranch      = $identity.gitBranch
            gitDirty       = $identity.gitDirty
            gitRemote      = $identity.gitRemote
            scriptName     = $script:_LogName
            overallStatus  = $Status
            startTime      = $script:_LogStart.ToString("o")
            endTime        = $endTime.ToString("o")
            duration       = [math]::Round($duration, 2)
            errorCount     = $script:_LogErrors.Count
            warnCount      = $script:_LogWarnings.Count
            errors         = @($script:_LogErrors)
            warnings       = @($script:_LogWarnings)
        }

        $errorPath = Join-Path $script:_LogsDir "$($script:_LogName)-error.json"
        $errorJson = $errorData | ConvertTo-Json -Depth 5
        $errorJson | Set-Content -Path $errorPath -Encoding UTF8
        Write-Host "  [ WARN ] Error log saved: $errorPath" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  ---- Error log contents ----" -ForegroundColor Red
        $errorJson -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkRed }
        Write-Host "  ----------------------------" -ForegroundColor Red
    }

    # Print one-line summary for easy copy-paste
    $summaryParts = @("[$($script:_LogName)] Status: $Status | Duration: $([math]::Round($duration, 1))s")
    if ($hasErrors) { $summaryParts += "Errors: $($script:_LogErrors.Count)" }
    if ($hasWarnings) { $summaryParts += "Warnings: $($script:_LogWarnings.Count)" }
    $summaryLine = $summaryParts -join " | "
    $summaryColor = if ($isOverallFailure) { "Red" } elseif ($hasWarnings) { "Yellow" } elseif ($Status -eq "already-installed") { "Cyan" } else { "Green" }
    Write-Host ""
    Write-Host "  $summaryLine" -ForegroundColor $summaryColor

    # If there are errors, print each on its own line for quick scanning
    if ($hasErrors) {
        foreach ($err in $script:_LogErrors) {
            Write-Host "    >> $($err.message)" -ForegroundColor Red
        }
    }

}

function Import-JsonConfig {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FilePath,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Label
    )

    # ----------------------------------------------------------------------
    # CODE RED parameter validation. Fail FAST with a clear error that
    # includes the exact missing/invalid input + reason, instead of letting
    # a $null path crash deep inside Test-Path / Get-Content with cryptic
    # ".NET" errors. We accept null/empty at the parameter binder level
    # (via [AllowNull]/[AllowEmptyString]) so we can produce our own
    # standardized message via Write-FileError when available.
    # ----------------------------------------------------------------------
    $callerInfo = (Get-PSCallStack | Select-Object -Skip 1 -First 1)
    $callerName = if ($null -ne $callerInfo) { $callerInfo.Command } else { '<unknown>' }

    $rawForReport     = if ($null -eq $FilePath) { '<null>' } else { "'$FilePath'" }
    $trimmedCandidate = if ($null -eq $FilePath) { '' } else { $FilePath.Trim() }
    $isFilePathMissing = [string]::IsNullOrWhiteSpace($FilePath)
    if ($isFilePathMissing) {
        $reason = "Import-JsonConfig was called with a null or empty -FilePath (caller: $callerName, raw value: $rawForReport, trimmed: '$trimmedCandidate'). Pass an absolute or repo-relative path to a .json file."
        if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
            Write-FileError `
                -FilePath '<null-or-empty>' `
                -Operation 'load' `
                -Reason    $reason `
                -Module    'Import-JsonConfig'
        } else {
            Write-Host ""
            Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host "Import-JsonConfig: -FilePath is null or empty."
            Write-Host ("          Reason : " + $reason) -ForegroundColor Gray
        }
        $ex = [System.ArgumentException]::new(
            "Import-JsonConfig: -FilePath is required and cannot be null or empty (caller: $callerName, raw value: $rawForReport, trimmed: '$trimmedCandidate').",
            'FilePath'
        )
        $ex.Data['TrimmedFilePath'] = $trimmedCandidate
        $ex.Data['RawFilePath']     = $FilePath
        $ex.Data['Caller']          = $callerName
        throw $ex
    }

    # Trim and normalize so accidental trailing whitespace from JSON-driven
    # callers doesn't trip Test-Path on Windows.
    $FilePath = $FilePath.Trim()

    # Reject obviously-bogus paths (control chars, wildcards) before we
    # touch the filesystem -- gives the caller a useful message instead of
    # a generic "Cannot find path" further down. We collect the EXACT
    # offending characters (with codepoints + index) so the error tells the
    # caller what to fix instead of just "invalid path".
    $hasInvalidChars = $false
    $badCharDetails  = @()
    try {
        $invalid = [System.IO.Path]::GetInvalidPathChars()
        $seen    = @{}
        for ($i = 0; $i -lt $FilePath.Length; $i++) {
            $ch = $FilePath[$i]
            if ($invalid -contains $ch) {
                $hasInvalidChars = $true
                $code = [int][char]$ch
                $key  = "U+{0:X4}" -f $code
                if (-not $seen.ContainsKey($key)) {
                    $seen[$key] = $true
                    $display = if ($code -lt 0x20 -or $code -eq 0x7F) {
                        "<ctrl $key>"
                    } else {
                        "'$ch' ($key)"
                    }
                    $badCharDetails += "$display at index $i"
                }
            }
        }
    } catch { $hasInvalidChars = $false }
    if ($hasInvalidChars) {
        $badList = if ($badCharDetails.Count -gt 0) { ($badCharDetails -join ', ') } else { '<unknown>' }
        $reason  = "Path contains characters that are illegal on this filesystem (caller: $callerName). Trimmed FilePath: '$FilePath'. Invalid character(s): $badList."
        if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
            Write-FileError `
                -FilePath $FilePath `
                -Operation 'load' `
                -Reason    $reason `
                -Module    'Import-JsonConfig'
        }
        $ex = [System.ArgumentException]::new(
            "Import-JsonConfig: -FilePath '$FilePath' contains invalid path characters: $badList (caller: $callerName). Trimmed FilePath: '$FilePath'.",
            'FilePath'
        )
        $ex.Data['TrimmedFilePath']   = $FilePath
        $ex.Data['InvalidCharacters'] = $badCharDetails
        $ex.Data['Caller']            = $callerName
        throw $ex
    }

    # Resolve $script:SharedLogMessages defensively. Under StrictMode Latest,
    # reading an unset script-scope variable throws -- so callers that dot-
    # source logging.ps1 and immediately call Import-JsonConfig (before any
    # other shared loader populates SharedLogMessages) would die here.
    $slm = $null
    try {
        $slmVar = Get-Variable -Name SharedLogMessages -Scope Script -ErrorAction SilentlyContinue
        if ($slmVar) { $slm = $slmVar.Value }
    } catch { $slm = $null }

    $isLabelMissing = [string]::IsNullOrWhiteSpace($Label)
    if ($isLabelMissing) { $Label = Split-Path -Leaf $FilePath }
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = 'config' }

    # ----------------------------------------------------------------------
    # Defensive template lookup. The shared log-messages.json may be
    # missing entirely, missing the .messages container, or missing one of
    # the import* keys (e.g. when an out-of-date copy is on disk after a
    # partial git pull, or when a caller hand-rolled $script:SharedLogMessages).
    # In every case we fall back to a literal template so the dispatcher
    # doesn't crash with "Cannot index into a null array" at line 590.
    # ----------------------------------------------------------------------
    # Inline defensive template lookup (avoid nested-function scoping pitfalls
    # that can leave $tpl* as $null and trip "Cannot index into a null array"
    # on the subsequent -replace chain).
    $tplLoading  = 'Loading {label} from: {path}'
    $tplNotFound = '{label} not found at path: {path}'
    $tplSize     = '{label} file size: {size} chars'
    $tplLoaded   = '{label} loaded successfully'

    if ($null -ne $slm -and
        $null -ne $slm.PSObject.Properties['messages'] -and
        $null -ne $slm.messages) {
        $msgs = $slm.messages
        if ($null -ne $msgs.PSObject.Properties['importLoading']) {
            $v = [string]$msgs.importLoading
            if (-not [string]::IsNullOrWhiteSpace($v))  { $tplLoading = $v }
        }
        if ($null -ne $msgs.PSObject.Properties['importNotFound']) {
            $v = [string]$msgs.importNotFound
            if (-not [string]::IsNullOrWhiteSpace($v))  { $tplNotFound = $v }
        }
        if ($null -ne $msgs.PSObject.Properties['importFileSize']) {
            $v = [string]$msgs.importFileSize
            if (-not [string]::IsNullOrWhiteSpace($v))  { $tplSize = $v }
        }
        if ($null -ne $msgs.PSObject.Properties['importLoaded']) {
            $v = [string]$msgs.importLoaded
            if (-not [string]::IsNullOrWhiteSpace($v))  { $tplLoaded = $v }
        }
    }

    # Coerce to string and guarantee non-null operands for -replace chains.
    $safeLabel = if ($null -eq $Label)    { '' } else { [string]$Label }
    $safePath  = if ($null -eq $FilePath) { '' } else { [string]$FilePath }

    $msgLoading = ([string]$tplLoading).Replace('{label}', $safeLabel).Replace('{path}', $safePath)
    Write-Log $msgLoading -Level "info"

    $isFileMissing = -not (Test-Path $FilePath)
    if ($isFileMissing) {
        if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
            Write-FileError -FilePath $FilePath -Operation "load" -Reason "File does not exist" -Module "Import-JsonConfig"
        }
        $msgNotFound = ([string]$tplNotFound).Replace('{label}', $safeLabel).Replace('{path}', $safePath)
        Write-Log $msgNotFound -Level "error"
        return $null
    }

    $content = Get-Content $FilePath -Raw
    $safeSize = if ($null -eq $content) { '0' } else { [string]$content.Length }
    $msgSize = ([string]$tplSize).Replace('{label}', $safeLabel).Replace('{size}', $safeSize)
    Write-Log $msgSize -Level "info"

    $parsed = $content | ConvertFrom-Json
    $msgLoaded = ([string]$tplLoaded).Replace('{label}', $safeLabel)
    Write-Log $msgLoaded -Level "success"
    return $parsed
}

# -- Auto-load installation tracking helper ------------------------------------
$_installedPath = Join-Path $PSScriptRoot "installed.ps1"
if ((Test-Path $_installedPath) -and -not (Get-Command Test-AlreadyInstalled -ErrorAction SilentlyContinue)) {
    . $_installedPath
}

# -- Auto-load tool version helper ---------------------------------------------
$_toolVersionPath = Join-Path $PSScriptRoot "tool-version.ps1"
if ((Test-Path $_toolVersionPath) -and -not (Get-Command Assert-ToolVersion -ErrorAction SilentlyContinue)) {
    . $_toolVersionPath
}
