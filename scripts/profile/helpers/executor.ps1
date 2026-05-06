<#
.SYNOPSIS
    Profile step executor. Runs each expanded step and records pass/fail/skip + elapsed.
#>

function Invoke-ProfileSteps {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[hashtable]]$Steps,
        [Parameter(Mandatory)][PSObject]$Config,
        [Parameter(Mandatory)][PSObject]$LogMessages,
        [Parameter(Mandatory)][string]$RootDir,
        [bool]$AutoYes = $false
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $total   = $Steps.Count

    for ($i = 0; $i -lt $total; $i++) {
        $step = $Steps[$i]
        $n    = $i + 1
        $kind = "$($step.kind)".ToLower()
        $label = "$($step.label)"

        Write-Host ""
        Write-Host ("  ----- Step {0}/{1} : [{2}] {3} -----" -f $n, $total, $kind, $label) -ForegroundColor Cyan

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $stepStart = Get-Date
        $status = "ok"
        $errorMsg = ""

        try {
            switch ($kind) {
                "script" {
                    $id = [int]$step.id
                    $envName = $null
                    $envWasSet = $false
                    if ($Config.modeEnvVars.PSObject.Properties.Name -contains "$id") {
                        $envName = $Config.modeEnvVars."$id"
                    }
                    $hasMode = -not [string]::IsNullOrWhiteSpace($step.mode)
                    if ($hasMode -and $envName) {
                        Set-Item "Env:\$envName" "$($step.mode)"
                        $envWasSet = $true
                    }
                    $ok = Invoke-ScriptByIdSafe -RootDir $RootDir -ScriptId $id
                    if ($envWasSet) { Remove-Item "Env:\$envName" -ErrorAction SilentlyContinue }
                    if (-not $ok) {
                        $status = "fail"
                        $errorMsg = "script id=$id returned non-success"
                    } else {
                        # Detect "already installed" reruns by sniffing the
                        # freshest .logs/<name>.json the child just wrote.
                        $childStatus = Get-LastChildLogStatus -RootDir $RootDir -SinceUtc $stepStart.ToUniversalTime()
                        if ($childStatus -eq "already-installed") { $status = "already-installed" }
                    }
                }
                "choco" {
                    $pkg = "$($step.package)"
                    $cmd = Get-Command "choco" -ErrorAction SilentlyContinue
                    $hasChoco = $null -ne $cmd
                    if (-not $hasChoco) {
                        $status = "skip"
                        $errorMsg = ($LogMessages.messages.missingChoco -replace '\{package\}', $pkg)
                        Write-Log $errorMsg -Level "warn"
                    } else {
                        $args = @("install", $pkg, "-y", "--no-progress")
                        $proc = Start-Process -FilePath $cmd.Source -ArgumentList $args -Wait -PassThru -NoNewWindow
                        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                            $status = "fail"
                            $errorMsg = "choco install $pkg exited with code $($proc.ExitCode)"
                        }
                    }
                }
                "subcommand" {
                    $path = "$($step.path)".Trim()
                    $rootRun = Join-Path $RootDir "run.ps1"
                    $isRootMissing = -not (Test-Path $rootRun)
                    if ($isRootMissing) {
                        $status = "fail"
                        $errorMsg = "Root run.ps1 not found at $rootRun"
                    } else {
                        $tokens = $path -split '\s+' | Where-Object { $_.Length -gt 0 }
                        # Prevent self-recursion when SCRIPTS_ROOT_RUN is set by us
                        $previousRootEnv = $env:SCRIPTS_ROOT_RUN
                        try {
                            & $rootRun @tokens
                            $code = $LASTEXITCODE
                            if ($code -ne 0 -and $code -ne $null) {
                                $status = "fail"
                                $errorMsg = ($LogMessages.messages.subcommandFailed `
                                    -replace '\{path\}', $path `
                                    -replace '\{code\}', "$code")
                            }
                        } finally {
                            if ($null -ne $previousRootEnv) { $env:SCRIPTS_ROOT_RUN = $previousRootEnv }
                        }
                    }
                }
                "inline" {
                    $fn = "$($step.function)"
                    $cmd = Get-Command $fn -ErrorAction SilentlyContinue
                    $isMissing = $null -eq $cmd
                    if ($isMissing) {
                        $status = "fail"
                        $errorMsg = ($LogMessages.messages.inlineMissing -replace '\{function\}', $fn)
                        Write-Log $errorMsg -Level "fail"
                    } else {
                        try {
                            & $cmd -RootDir $RootDir -AutoYes:$AutoYes -Step $step | Out-Null
                        } catch {
                            $status = "fail"
                            $errorMsg = ($LogMessages.messages.inlineFailed `
                                -replace '\{function\}', $fn `
                                -replace '\{error\}', $_.Exception.Message)
                            Write-Log $errorMsg -Level "fail"
                        }
                    }
                }
                default {
                    $status = "skip"
                    $errorMsg = ($LogMessages.messages.noKindHandler `
                        -replace '\{kind\}', $kind `
                        -replace '\{n\}', "$n" `
                        -replace '\{label\}', $label)
                    Write-Log $errorMsg -Level "warn"
                }
            }
        } catch {
            $status = "fail"
            $errorMsg = $_.Exception.Message
            Write-Log "Step $n unhandled error: $errorMsg" -Level "fail"
        }

        $sw.Stop()
        $elapsed = $sw.Elapsed.TotalSeconds

        $results.Add(@{
            N        = $n
            Kind     = $kind
            Label    = $label
            Status   = $status
            Elapsed  = $elapsed
            Error    = $errorMsg
        }) | Out-Null

        $color = switch ($status) {
            "ok"                { "Green" }
            "already-installed" { "Cyan" }
            "fail"              { "Red" }
            "skip"              { "DarkGray" }
            default             { "Yellow" }
        }
        Write-Host ("  >>> Step {0}/{1} {2} ({3}s)" -f $n, $total, $status.ToUpper(), [Math]::Round($elapsed, 1)) -ForegroundColor $color
        if ($status -eq "fail" -and $errorMsg) {
            Write-Host ("      reason: $errorMsg") -ForegroundColor DarkRed
        }

        # Refresh PATH between steps so newly installed tools become discoverable
        try {
            $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
            $env:Path = "$machinePath;$userPath"
        } catch {}
    }

    return $results
}

function Invoke-ScriptByIdSafe {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][int]$ScriptId
    )
    $prefix = "{0:D2}" -f $ScriptId
    $registryPath = Join-Path $RootDir "scripts\registry.json"
    $scriptDir = $null

    if (Test-Path $registryPath) {
        try {
            $reg = Get-Content $registryPath -Raw | ConvertFrom-Json
            $folder = $reg.scripts.$prefix
            if ($folder) {
                $candidate = Join-Path $RootDir "scripts\$folder"
                if (Test-Path (Join-Path $candidate "run.ps1")) {
                    $scriptDir = $candidate
                }
            }
        } catch {}
    }
    if (-not $scriptDir) {
        $matches = Get-ChildItem (Join-Path $RootDir "scripts") -Directory -Filter "$prefix-*" -ErrorAction SilentlyContinue
        if ($matches) {
            foreach ($m in $matches) {
                if (Test-Path (Join-Path $m.FullName "run.ps1")) { $scriptDir = $m.FullName; break }
            }
        }
    }

    if (-not $scriptDir) {
        Write-Host "  [ FAIL ] Script id=$prefix not found" -ForegroundColor Red
        return $false
    }

    $runFile = Join-Path $scriptDir "run.ps1"
    try {
        & $runFile
        return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
    } catch {
        Write-Host "  [ FAIL ] Script id=$prefix threw: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-LastChildLogStatus {
    <#
    .SYNOPSIS
        Returns the "status" field of the most recently written .logs/*.json
        file (excluding -error.json) modified at or after $SinceUtc.
        Used by the profile executor to detect when a child install script
        recorded status="already-installed" so the profile step can mirror it.
        Returns $null if no fresh log was found or it cannot be parsed.
    #>
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][datetime]$SinceUtc
    )

    $logsDir = Join-Path $RootDir ".logs"
    if (-not (Test-Path $logsDir)) { return $null }

    try {
        $candidate = Get-ChildItem -Path $logsDir -Filter "*.json" -File -ErrorAction Stop |
            Where-Object { $_.Name -notlike "*-error.json" -and $_.LastWriteTimeUtc -ge $SinceUtc } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if (-not $candidate) { return $null }
        $payload = Get-Content $candidate.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($payload.PSObject.Properties.Name -contains 'status') {
            return [string]$payload.status
        }
    } catch {
        return $null
    }
    return $null
}
