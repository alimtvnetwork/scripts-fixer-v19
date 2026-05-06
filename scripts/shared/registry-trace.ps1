<#
.SYNOPSIS
    Verbose registry-change trace logger.

.DESCRIPTION
    Dot-source this in any script that mutates the Windows registry so that
    `-Verbose` produces a per-script trace file under `.logs/` recording every
    Set / Get / Remove of a registry value or key, with timestamp, user,
    operation, full HKLM:\... or HKCU:\... path, value name, old value, new
    value, and outcome (OK / FAIL + reason).

    The trace is independent of the structured JSON log produced by
    `logging.ps1`. It is a plain-text sidecar designed to be tailed in a second
    terminal during troubleshooting:

        Get-Content .logs\os-fix-long-path-registry-trace.log -Wait -Tail 20

    Activation:
        Pass -Verbose to the host script (PowerShell CommonParameter). The
        trace file is created on the first call to Write-RegistryTrace; if
        -Verbose was never set, the function is a no-op and no file is
        created.

    Log file naming:
        .logs/<sanitised-script-name>-registry-trace.log

        Example:
          .logs/os-fix-long-path-registry-trace.log
          .logs/os-clean-explorer-mru-registry-trace.log

    End-of-run summary:
        When -Verbose is active, a one-command summary prints automatically at
        script exit (via Close-RegistryTrace). It shows the last N trace lines
        plus OK/FAIL/SKIP totals. Control the tail length with --summary-tail N.

        --summary-tail N formats accepted (case-insensitive):
          --summary-tail 50       # space separator (POSIX style)
          --summary-tail=50       # equals separator
          --summary-tail:50       # colon separator
          -summary-tail 50        # single-dash variant with space
          -summary-tail=50        # single-dash with equals
          -summary-tail:50        # single-dash with colon
          -SummaryTail 50         # PascalCase variant (PowerShell binding)
          /summary-tail 50        # Windows slash style with space
          /summary-tail=50        # Windows slash with equals

        All forms are case-insensitive (--SUMMARY-TAIL, --SummaryTail work).

        Valid vs invalid values:
          VALID:   0, 1, 5, 20, 50, 100  (non-negative integers)
          INVALID: -1, -5                 (negative numbers -> fallback to 20)
          INVALID: abc, 5x, ''            (non-numeric -> fallback to 20)
          INVALID: 3.5, 5.0               (decimals -> fallback to 20)
          INVALID: (missing value)        (--summary-tail at end of args -> 20)

        Special value: N=0 means "totals only" -- no trace lines are printed,
        only the OK/FAIL/SKIP counts. Useful for CI logs where you want
        the summary stats without the clutter.

    Machine-readable output:
        Pass --summary-json to emit a single-line JSON object to stdout:

          REGTRACE_SUMMARY_JSON {"script":"os-flp","counts":{"OK":3,"FAIL":0,"SKIP":0},"tail":[],...}

        This is emitted in addition to the human-readable summary. Useful for
        piping to jq, logging aggregators, or CI artifact capture.

    Parity guarantees (human summary vs --summary-json tail array):
        The human summary's printed line count and the JSON `tail[]` array
        length are ALWAYS equal for the same REGTRACE_SUMMARY_TAIL value.
        Both are computed from the same buffer using the same formula:
            shown = min(REGTRACE_SUMMARY_TAIL, buffer.Count)

        Edge case 1 -- zero recorded operations (buffer empty):
            Human:  prints "no registry operations recorded this run" notice
                    and emits 0 trace lines.
            JSON:   emits payload with `tail: []` (empty array, length 0)
                    and counts {ok:0, fail:0, skip:0, total:0}.
            Parity: both show 0 lines. MATCH.

        Edge case 2 -- REGTRACE_SUMMARY_TAIL greater than buffer size:
            The tail buffer is capped at 20 lines internally
            ($script:_RegTraceTailMax). Requesting --summary-tail 100 when
            only 7 ops ran does NOT magically retain more history -- both
            outputs are clamped to whatever the buffer actually holds.
            Human:  prints all available lines (e.g. "last 7 of 7").
            JSON:   `tail[]` contains the same 7 strings; `tailShown=7`,
                    `tailMax=20` reflects the buffer cap (not the request).
            Parity: both show min(request, buffer). MATCH.

        Edge case 3 -- invalid --summary-tail value (negative or non-numeric):
            Both `--summary-tail -1` and `--summary-tail abc` are treated as
            invalid by Get-SummaryTailArg, which returns $null. The dispatcher
            then SKIPS setting REGTRACE_SUMMARY_TAIL entirely (env var stays
            unset). Close-RegistryTrace's resolution chain falls through:
                explicit -TailLines param  -> not provided
                REGTRACE_SUMMARY_TAIL env  -> empty / unset
                module default             -> $script:_RegTraceTailMax (20)
            Final value: 20 lines for BOTH the human summary and the JSON
            `tail[]` array. By default no warning is printed -- the invalid
            arg is silently ignored to avoid breaking pipelines.

            Opt-in surfacing: pass --summary-tail-warn alongside an invalid
            --summary-tail to print a yellow [ WARN ] line explaining
            EXACTLY why the value was rejected (negative / non-numeric /
            decimal / missing). Helpful for catching typos in CI configs.
            Behavior is unchanged otherwise (still falls back to default 20).

            Example:
                .\run.ps1 os clean --summary-tail abc --summary-tail-warn
                # [ WARN ] --summary-tail ignored: value 'abc' is not numeric.
                #         Falling back to default 20.

            Worked examples:
                --summary-tail -1   -> 20 (default, both outputs)
                --summary-tail abc  -> 20 (default, both outputs)
                --summary-tail 3.5  -> 20 (default; only integers accepted)
                --summary-tail ""   -> 20 (default; empty value)
                --summary-tail      -> 20 (default; missing value at end of args)
                --summary-tail 0    -> 0  (valid; "totals only" mode)
                --summary-tail 50   -> 50 (valid; clamped to buffer if smaller)

    Try it -- copy-pasteable commands:
        # 1) Invalid negative: falls back to 20 lines
        .\run.ps1 os clean-explorer-mru -Verbose --summary-tail -1 --summary-json
        # JSON output: {"tail":[...20 items...],"tailShown":20,...}

        # 2) Invalid text: same fallback to 20
        .\run.ps1 os clean-explorer-mru -Verbose --summary-tail abc --summary-json
        # JSON output: {"tail":[...20 items...],"tailShown":20,...}

        # 3) Zero: totals only, empty tail array
        .\run.ps1 os clean-explorer-mru -Verbose --summary-tail 0 --summary-json
        # JSON output: {"tail":[],"tailShown":0,"counts":{...}}

        # 4) Large number: clamped to buffer size (max 20)
        .\run.ps1 os clean-explorer-mru -Verbose --summary-tail 50 --summary-json
        # JSON output: {"tail":[...up to 20 items...],"tailShown":N,...}
        # (where N = min(50, actual operation count, 20))


    CODE RED: every failure entry includes the exact failing registry path +
    the exception message verbatim. Never swallow a path on failure.
#>

# ── Module-scoped state ─────────────────────────────────────────────────────
$script:_RegTraceEnabled = $false
$script:_RegTracePath    = $null
$script:_RegTraceScript  = $null
# Counters + tail buffer for the end-of-run summary
$script:_RegTraceCounts  = @{ OK = 0; FAIL = 0; SKIP = 0 }
$script:_RegTraceTail    = New-Object System.Collections.Generic.Queue[string]
$script:_RegTraceTailMax = 20
# When $true, Close-RegistryTrace also emits a single-line JSON object to
# stdout (machine-readable summary). Set via Set-RegistryTraceSummaryJson or
# the env var REGTRACE_SUMMARY_JSON=1 (honoured at print time so a parent
# dispatcher can flip it on for child invocations).
$script:_RegTraceSummaryJson = $false

function Initialize-RegistryTrace {
    <#
    .SYNOPSIS
        Wire the trace logger to a host script. Call once near the top of
        run.ps1 / longpath.ps1 / explorer-mru.ps1 after Initialize-Logging.

    .PARAMETER ScriptName
        Human-readable script name; sanitised into the log filename. Should
        match the value passed to Initialize-Logging so both files share a
        prefix.

    .PARAMETER VerboseEnabled
        Pass `$PSBoundParameters.ContainsKey('Verbose')` from the host script
        (StrictMode-safe; $VerbosePreference inheritance can be unreliable
        across `&` invocations).
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][bool]$VerboseEnabled
    )

    $script:_RegTraceEnabled = $VerboseEnabled
    $script:_RegTraceScript  = $ScriptName
    # Reset counters + tail buffer for this run
    $script:_RegTraceCounts  = @{ OK = 0; FAIL = 0; SKIP = 0 }
    $script:_RegTraceTail    = New-Object System.Collections.Generic.Queue[string]

    if (-not $VerboseEnabled) { return }

    # .logs/ at repo root (parent of scripts/) -- matches logging.ps1 layout
    $here = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $repoRoot = (Resolve-Path (Join-Path $here "..\..")).Path
    $logsDir = Join-Path $repoRoot ".logs"

    if (-not (Test-Path -LiteralPath $logsDir)) {
        try {
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
        } catch {
            Write-Host "  [ WARN ] Failed to create .logs/ at ${logsDir}: $($_.Exception.Message)" -ForegroundColor Yellow
            $script:_RegTraceEnabled = $false
            return
        }
    }

    $sanitised = ($ScriptName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($sanitised)) { $sanitised = "registry" }
    $script:_RegTracePath = Join-Path $logsDir "$sanitised-registry-trace.log"

    $header = @(
        "================================================================================",
        "  Registry trace -- $ScriptName",
        "  Started:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
        "  User:     $env:USERDOMAIN\$env:USERNAME    (PID $PID)",
        "  Host:     $env:COMPUTERNAME",
        "  PSVer:    $($PSVersionTable.PSVersion)",
        "  Logfile:  $($script:_RegTracePath)",
        "================================================================================",
        ""
    ) -join [Environment]::NewLine

    try {
        Add-Content -LiteralPath $script:_RegTracePath -Value $header -Encoding UTF8
    } catch {
        Write-Host "  [ WARN ] Registry trace disabled -- cannot write $($script:_RegTracePath): $($_.Exception.Message)" -ForegroundColor Yellow
        $script:_RegTraceEnabled = $false
        return
    }

    Write-Host "  [ INFO ] Verbose registry trace enabled -> $($script:_RegTracePath)" -ForegroundColor Cyan
}

function Test-RegistryTraceEnabled {
    return [bool]$script:_RegTraceEnabled
}

function Write-RegistryTrace {
    <#
    .SYNOPSIS
        Append one trace line. No-op when -Verbose was not set.

    .PARAMETER Op
        One of: SET, GET, REMOVE-VALUE, REMOVE-KEY, READ-ONLY.

    .PARAMETER Path
        Full registry path (e.g. HKLM:\SYSTEM\CurrentControlSet\...).

    .PARAMETER Name
        Value name (omit for whole-key operations).

    .PARAMETER OldValue / NewValue
        Stringified old/new values for SET; either may be $null.

    .PARAMETER Status
        OK | FAIL | SKIP. Defaults to OK.

    .PARAMETER Reason
        Free-text reason; for FAIL this MUST contain the exception message.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet("SET","GET","REMOVE-VALUE","REMOVE-KEY","READ-ONLY")][string]$Op,
        [Parameter(Mandatory)][string]$Path,
        [string]$Name,
        $OldValue,
        $NewValue,
        [ValidateSet("OK","FAIL","SKIP")][string]$Status = "OK",
        [string]$Reason
    )

    $hasTrace = $script:_RegTraceEnabled -and $script:_RegTracePath
    if (-not $hasTrace) { return }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    $oldStr = if ($null -eq $OldValue) { "<null>" } else { "$OldValue" }
    $newStr = if ($null -eq $NewValue) { "<null>" } else { "$NewValue" }
    $nameStr = if ([string]::IsNullOrEmpty($Name)) { "<key>" } else { $Name }

    $line = "[{0}] [{1,-12}] [{2,-4}] {3} :: {4}" -f $ts, $Op, $Status, $Path, $nameStr
    if ($Op -eq "SET") {
        $line += "  old=$oldStr  new=$newStr"
    } elseif ($Op -eq "GET" -or $Op -eq "READ-ONLY") {
        $line += "  value=$newStr"
    }
    $hasReason = -not [string]::IsNullOrWhiteSpace($Reason)
    if ($hasReason) {
        $line += "  reason=$Reason"
    }

    # Tally + remember tail (always, even if disk write fails afterwards)
    if ($script:_RegTraceCounts.ContainsKey($Status)) {
        $script:_RegTraceCounts[$Status]++
    }
    [void]$script:_RegTraceTail.Enqueue($line)
    while ($script:_RegTraceTail.Count -gt $script:_RegTraceTailMax) {
        [void]$script:_RegTraceTail.Dequeue()
    }

    try {
        Add-Content -LiteralPath $script:_RegTracePath -Value $line -Encoding UTF8
    } catch {
        # Last-ditch: complain to host once, then disable to avoid spam
        Write-Host "  [ WARN ] Registry trace write failed at $($script:_RegTracePath): $($_.Exception.Message)" -ForegroundColor Yellow
        $script:_RegTraceEnabled = $false
    }
}

function Get-RegistryTraceCounts {
    <#
    .SYNOPSIS
        Returns a hashtable @{ OK = N; FAIL = N; SKIP = N; Total = N } for the
        current run. Available even when -Verbose was not set (all zeros).
    #>
    $c = $script:_RegTraceCounts
    return @{
        OK    = [int]$c.OK
        FAIL  = [int]$c.FAIL
        SKIP  = [int]$c.SKIP
        Total = [int]($c.OK + $c.FAIL + $c.SKIP)
    }
}

function Show-RegistryTraceSummary {
    <#
    .SYNOPSIS
        Print the last <=20 trace lines and the OK/FAIL/SKIP totals to the
        host. Also appended to the trace logfile (when enabled). Safe to call
        when -Verbose was not set: prints a one-line "no operations" notice
        and returns.

    .PARAMETER TailLines
        How many recent lines to show. Defaults to 20.

    .PARAMETER Source
        Origin of the resolved tail value: "param" | "env" | "default".
        Used to print "effective tail = N (from <source>)" in the header
        so users can confirm which fallback won.
    #>
    param(
        [int]$TailLines = 20,
        [string]$Source = "default"
    )

    $counts = Get-RegistryTraceCounts
    $hasTrace = $script:_RegTraceEnabled -and $script:_RegTracePath
    $hasOps   = $counts.Total -gt 0

    Write-Host ""
    Write-Host "  Registry trace summary" -ForegroundColor Cyan
    Write-Host "  ----------------------" -ForegroundColor DarkGray
    Write-Host ("    effective tail = {0} (from {1})" -f $TailLines, $Source) -ForegroundColor DarkGray

    if (-not $hasOps) {
        if ($hasTrace) {
            Write-Host "    no registry operations recorded this run" -ForegroundColor DarkGray
        } else {
            Write-Host "    -Verbose not set; no trace collected (pass -Verbose to enable)" -ForegroundColor DarkGray
        }
        Write-Host ""
        return
    }

    # Print tail (most-recent-last)
    $maxShow = [Math]::Min($TailLines, $script:_RegTraceTail.Count)
    Write-Host "    last $maxShow of $($counts.Total) trace line(s):" -ForegroundColor DarkGray
    $tailArr = @($script:_RegTraceTail.ToArray())
    $start = [Math]::Max(0, $tailArr.Count - $TailLines)
    for ($i = $start; $i -lt $tailArr.Count; $i++) {
        $ln = $tailArr[$i]
        $color = "Gray"
        if     ($ln -match '\[FAIL\]') { $color = "Red" }
        elseif ($ln -match '\[SKIP\]') { $color = "Yellow" }
        elseif ($ln -match '\[OK\s*\]') { $color = "Green" }
        Write-Host "      $ln" -ForegroundColor $color
    }

    Write-Host ""
    Write-Host ("    totals: OK={0}  FAIL={1}  SKIP={2}  (total {3})" -f `
        $counts.OK, $counts.FAIL, $counts.SKIP, $counts.Total) -ForegroundColor Cyan
    if ($hasTrace) {
        Write-Host "    full log: $($script:_RegTracePath)" -ForegroundColor DarkGray
    }
    Write-Host ""

    # Mirror the summary into the trace logfile so it stays self-describing
    if ($hasTrace) {
        $block = @()
        $block += ""
        $block += ("  effective tail = {0} (from {1})" -f $TailLines, $Source)
        $block += "  --- summary (last $maxShow of $($counts.Total)) ---"
        for ($i = $start; $i -lt $tailArr.Count; $i++) {
            $block += "    " + $tailArr[$i]
        }
        $block += ("  totals: OK={0}  FAIL={1}  SKIP={2}  (total {3})" -f `
            $counts.OK, $counts.FAIL, $counts.SKIP, $counts.Total)
        $block += ""
        try {
            Add-Content -LiteralPath $script:_RegTracePath -Value ($block -join [Environment]::NewLine) -Encoding UTF8
        } catch {
            Write-Host "  [ WARN ] Could not append summary to $($script:_RegTracePath): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Set-RegistryTraceSummaryJson {
    <#
    .SYNOPSIS
        Toggle machine-readable JSON summary emission to stdout at Close time.

    .DESCRIPTION
        When enabled, Close-RegistryTrace prints a single-line JSON object
        with OK/FAIL/SKIP counts and the same summary lines that the
        human-readable Show-RegistryTraceSummary block prints. Useful for
        wrapping the script in CI or piping into jq.

    .PARAMETER Enabled
        $true to enable, $false to disable. Defaults to $true.
    #>
    param([bool]$Enabled = $true)
    $script:_RegTraceSummaryJson = $Enabled
}

function Test-SummaryJsonSwitch {
    <#
    .SYNOPSIS
        Same shape as Test-VerboseSwitch. Recognises --summary-json,
        -summary-json, /summary-json in $Argv.
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $false }
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--summary-json","-summary-json","/summary-json")) { return $true }
    }
    return $false
}

function Remove-SummaryJsonSwitch {
    <#
    .SYNOPSIS
        Returns a copy of $Argv with any --summary-json / -summary-json /
        /summary-json tokens stripped. Use in dispatchers that splat $Argv
        into child scripts which would otherwise reject the unknown flag.
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--summary-json","-summary-json","/summary-json")) { continue }
        [void]$out.Add($a)
    }
    return ,$out.ToArray()
}

function Get-SummaryTailArg {
    <#
    .SYNOPSIS
        Parse --summary-tail N (or --summary-tail=N, -summary-tail N,
        /summary-tail N) from $Argv. Returns the requested int or $null
        if the flag is absent or its value is invalid.

    .DESCRIPTION
        Accepted forms:
            --summary-tail 50
            -summary-tail 50
            /summary-tail 50
            --summary-tail=50
            -summary-tail=50
            /summary-tail=50

        Validation: the value must parse as a non-negative integer
        (>= 0). Negative values, non-numeric values, and a trailing flag
        with no value all return $null so the caller can fall back to the
        default of 20. Zero is honoured -- it means "totals only, no tail
        lines" which is a legitimate request for noisy CI logs.
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $null }

    $names = @("--summary-tail","-summary-tail","/summary-tail")
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $raw = "$($Argv[$i])"
        $t   = $raw.Trim()
        $low = $t.ToLower()

        # Form 1: --summary-tail=N or --summary-tail:N (inline separator)
        foreach ($n in $names) {
            foreach ($sep in @("=", ":")) {
                if ($low.StartsWith("$n$sep")) {
                    $val = $t.Substring($n.Length + $sep.Length)
                    $parsed = 0
                    $ok = [int]::TryParse($val, [ref]$parsed)
                    if ($ok -and $parsed -ge 0) { return $parsed }
                    return $null
                }
            }
        }

        # Form 2: --summary-tail N  (value in the next slot)
        if ($low -in $names) {
            if (($i + 1) -lt $Argv.Count) {
                $parsed = 0
                $ok = [int]::TryParse("$($Argv[$i + 1])", [ref]$parsed)
                if ($ok -and $parsed -ge 0) { return $parsed }
            }
            return $null
        }
    }
    return $null
}

function Remove-SummaryTailArg {
    <#
    .SYNOPSIS
        Returns a copy of $Argv with the --summary-tail flag (and its
        value, when supplied as the next arg) stripped. Mirrors
        Remove-SummaryJsonSwitch. Handles --summary-tail=N, --summary-tail:N,
        and --summary-tail N forms.
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return @() }
    $names = @("--summary-tail","-summary-tail","/summary-tail")
    $out = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Argv.Count) {
        $raw = "$($Argv[$i])"
        $low = $raw.Trim().ToLower()

        $isInlineForm = $false
        foreach ($n in $names) {
            if ($low.StartsWith("${n}=") -or $low.StartsWith("${n}:")) {
                $isInlineForm = $true; break
            }
        }
        if ($isInlineForm) { $i++; continue }

        if ($low -in $names) {
            # Skip the flag AND the following value token if present and
            # numeric; if the next token is missing or non-numeric, only
            # skip the flag (defensive: don't eat an unrelated arg).
            $i++
            if ($i -lt $Argv.Count) {
                $parsed = 0
                if ([int]::TryParse("$($Argv[$i])", [ref]$parsed)) { $i++ }
            }
            continue
        }

        [void]$out.Add($Argv[$i])
        $i++
    }
    return ,$out.ToArray()
}

function Get-SummaryTailRaw {
    <#
    .SYNOPSIS
        Inspect $Argv for --summary-tail and return the RAW value the user
        typed (or $null if the flag is absent). Unlike Get-SummaryTailArg
        this does NOT validate -- it lets the caller distinguish "flag not
        present" from "flag present with bad value" so warnings can fire.

    .OUTPUTS
        Hashtable with keys:
          Present   [bool]   : true if --summary-tail (any form) was found
          RawValue  [string] : the literal value token (or "" if missing)
          Form      [string] : "equals" | "colon" | "space" | "missing"
          Token     [string] : the EXACT verbatim flag token the user typed,
                               preserving original casing/prefix/separator
                               (e.g. "--summary-tail=", "/summary-tail:",
                               "--Summary-Tail" for space form). Used in the
                               warning message so the user immediately knows
                               which arg position to fix.
        Returns $null if Argv is null/empty.
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv -or $Argv.Count -eq 0) { return $null }

    $names = @("--summary-tail","-summary-tail","/summary-tail")
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $raw = "$($Argv[$i])"
        $t   = $raw.Trim()
        $low = $t.ToLower()

        # Inline forms: --summary-tail=N or --summary-tail:N
        foreach ($n in $names) {
            foreach ($sep in @("=", ":")) {
                if ($low.StartsWith("$n$sep")) {
                    $prefix = $t.Substring(0, $n.Length + $sep.Length)  # verbatim w/ user's casing
                    return @{
                        Present  = $true
                        RawValue = $t.Substring($n.Length + $sep.Length)
                        Form     = if ($sep -eq "=") { "equals" } else { "colon" }
                        Token    = $prefix
                    }
                }
            }
        }
        # Space form: --summary-tail N (value in next slot, may be missing)
        if ($low -in $names) {
            $val = ""
            if (($i + 1) -lt $Argv.Count) { $val = "$($Argv[$i + 1])" }
            $form = if ($val -eq "") { "missing" } else { "space" }
            return @{
                Present  = $true
                RawValue = $val
                Form     = $form
                Token    = $t  # verbatim flag token, casing preserved
            }
        }
    }
    return $null
}

function Test-SummaryTailWarnSwitch {
    <#
    .SYNOPSIS
        Recognise --summary-tail-warn / -summary-tail-warn / /summary-tail-warn
        in $Argv. When set, dispatchers should emit a [ WARN ] line when the
        --summary-tail value is invalid (instead of silently using default 20).
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $false }
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--summary-tail-warn","-summary-tail-warn","/summary-tail-warn")) { return $true }
    }
    return $false
}

function Remove-SummaryTailWarnSwitch {
    <#
    .SYNOPSIS
        Strip --summary-tail-warn tokens from $Argv before forwarding to
        child scripts that would reject the unknown switch.
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--summary-tail-warn","-summary-tail-warn","/summary-tail-warn")) { continue }
        [void]$out.Add($a)
    }
    return ,$out.ToArray()
}

function Test-SummaryTailQuietSwitch {
    <#
    .SYNOPSIS
        Recognise --summary-tail-quiet / -summary-tail-quiet /
        /summary-tail-quiet in $Argv. When BOTH --summary-tail-warn and
        --summary-tail-quiet are passed, quiet wins -- the [ WARN ] line is
        suppressed but the silent fallback to default 20 still happens.

    .DESCRIPTION
        Use case: a CI workflow has --summary-tail-warn baked in globally,
        but one specific job legitimately passes a placeholder/computed
        value that may be empty. Adding --summary-tail-quiet to that one job
        keeps the global warn behavior elsewhere while silencing the
        expected noise locally. Acts as a no-op when --summary-tail-warn is
        not set (the default behavior is already silent).
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $false }
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--summary-tail-quiet","-summary-tail-quiet","/summary-tail-quiet")) { return $true }
    }
    return $false
}

function Remove-SummaryTailQuietSwitch {
    <#
    .SYNOPSIS
        Strip --summary-tail-quiet tokens from $Argv before forwarding to
        child scripts that would reject the unknown switch.
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--summary-tail-quiet","-summary-tail-quiet","/summary-tail-quiet")) { continue }
        [void]$out.Add($a)
    }
    return ,$out.ToArray()
}

function Test-DecimalLikeString {
    <#
    .SYNOPSIS
        Detect whether a string LOOKS LIKE a decimal/float that a user might
        have meant as a tail count, even if it's not parseable as a clean
        Double. Used to give a consistent "decimals are not allowed" warning
        instead of a generic "not numeric" message.

    .DESCRIPTION
        Recognised shapes (all return $true):
            "3.5"      classic decimal
            "3."       trailing-dot integer (common typo)
            ".5"       leading-dot fraction
            "0.5"      zero-prefixed
            "-3.5"     signed decimal
            "1e2"      scientific notation (no dot but float-shaped)
            "1.5e2"    full scientific
            "3,5"      comma decimal (locale slip / EU style)

        Returns $false for plain integers, empty/null, things like "abc",
        "5O", "x3" (those go through the generic "not numeric" branch), AND
        thousand-separator-shaped values like "1,000" or "1.000.000" -- those
        are caught earlier by Test-ThousandSeparatorString and get their own
        dedicated warning.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    # Plain integers (incl. signed) are NOT decimal-like.
    if ($v -match '^-?\d+$') { return $false }
    # Thousand-separator shapes are handled by their own detector; don't
    # double-classify them as decimals.
    if (Test-ThousandSeparatorString -Value $v) { return $false }
    # Any of: digits with a dot anywhere, leading/trailing dot, comma
    # decimal, or scientific notation.
    if ($v -match '^-?(\d+\.\d*|\d*\.\d+|\d+,\d+|\d+(\.\d+)?[eE]-?\d+)$') { return $true }
    return $false
}

function Test-ThousandSeparatorString {
    <#
    .SYNOPSIS
        Detect whether a string looks like an integer written with thousand
        separators (US "1,000" / "1,000,000" or EU "1.000" / "1.000.000"),
        so we can warn with a consistent, dedicated message instead of
        misclassifying it as a locale decimal.

    .DESCRIPTION
        Recognised shapes (all return $true):
            "1,000"           US thousands
            "1,000,000"       US thousands, multi-group
            "10,000"          4-digit head, US
            "999,999,999"     max US-style
            "1.000"           EU thousands (single group)
            "1.000.000"       EU thousands, multi-group
            "-1,000"          signed
            "-1.000.000"      signed EU

        Rules:
          - 1 to 3 digit head, then one OR MORE groups of exactly 3 digits
            separated by the SAME separator (all commas OR all dots).
          - Mixed separators ("1,000.50") are NOT thousand-sep -- they're
            a number with both grouping AND a decimal, which is ambiguous
            and falls through to decimal-like / not-numeric.
          - Single-group EU "1.000" is intentionally treated as thousands,
            NOT as the decimal 1.000 -- it's almost always a typo/locale
            slip when used as a tail count, and the warning tells the user
            exactly that so they can fix it.
          - "1,00" or "1.00" (2-digit trailing group) is NOT thousands;
            it's decimal-like and handled by Test-DecimalLikeString.

        Returns $false for plain integers, empty/null, and anything else.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim()
    # All-comma grouping: 1[,000]+
    if ($v -match '^-?\d{1,3}(,\d{3})+$') { return $true }
    # All-dot grouping: 1[.000]+
    if ($v -match '^-?\d{1,3}(\.\d{3})+$') { return $true }
    return $false
}

function Write-SummaryTailWarning {
    <#
    .SYNOPSIS
        Print a yellow [ WARN ] line explaining why an invalid --summary-tail
        value was ignored. Called by dispatchers ONLY when both:
          1) --summary-tail-warn was passed, AND
          2) --summary-tail was present but Get-SummaryTailArg returned $null

    .PARAMETER RawInfo
        The hashtable from Get-SummaryTailRaw (Present/RawValue/Form/Token).
        The Token field is the verbatim flag token the user typed (e.g.
        "--summary-tail=", "/summary-tail:", "--Summary-Tail") so the warning
        can echo it back exactly, helping users grep their own command line.
    #>
    param([Parameter(Mandatory)][hashtable]$RawInfo)
    $val   = $RawInfo.RawValue
    $form  = $RawInfo.Form
    $token = if ($RawInfo.ContainsKey("Token") -and -not [string]::IsNullOrEmpty($RawInfo.Token)) {
                 $RawInfo.Token
             } else {
                 "--summary-tail"  # fallback for older callers
             }

    # Build a form-specific reason that names the EXACT token the user typed.
    # This matters most for empty/missing cases where there's no value to echo.
    # Decimal-like detection runs BEFORE the generic "not numeric" branch so
    # "3.", ".5", "1e2", "3,5" all get the same consistent decimal message.
    $reason = switch ($true) {
        ($form -eq "missing") {
            "flag '$token' supplied with no value after it"; break
        }
        ($form -eq "equals" -and [string]::IsNullOrEmpty($val)) {
            "flag '$token' has an empty value (nothing after the '=')"; break
        }
        ($form -eq "colon" -and [string]::IsNullOrEmpty($val)) {
            "flag '$token' has an empty value (nothing after the ':')"; break
        }
        ([string]::IsNullOrEmpty($val)) {
            "flag '$token' has an empty value"; break
        }
        default {
            $parsed = 0
            if ([int]::TryParse($val, [ref]$parsed)) {
                if ($parsed -lt 0) { "'$token$val' rejected -- negative integers are not allowed" }
                else               { "'$token$val' rejected -- value '$val' is not a non-negative integer" }
            } elseif (Test-ThousandSeparatorString -Value $val) {
                # Detected BEFORE decimal-like so "1,000" / "1.000" don't get
                # mis-warned as "comma decimal" or "trailing-dot decimal".
                $sep      = if ($val -like '*,*') { "','" } else { "'.'" }
                $stripped = $val -replace '[,.]',''
                "'$token$val' rejected -- thousand separators ($sep) are not allowed (got '$val'); use a plain integer like '$stripped'"
            } elseif (Test-DecimalLikeString -Value $val) {
                "'$token$val' rejected -- decimals are not allowed (got '$val'); use a non-negative integer"
            } else {
                "'$token$val' rejected -- value '$val' is not numeric"
            }
        }
    }

    Write-Host "  [ WARN ] " -ForegroundColor Yellow -NoNewline
    Write-Host "--summary-tail ignored: $reason. Falling back to default 20."
    Write-Host "          Accepted forms: --summary-tail 50  |  --summary-tail=50  |  --summary-tail:50" -ForegroundColor DarkGray
    Write-Host "                          (case-insensitive; -summary-tail and /summary-tail also work)" -ForegroundColor DarkGray
}

function Show-RegistryTraceSummaryJsonOutput {
    <#
    .SYNOPSIS
        Emit a single-line JSON object describing the run to stdout.

    .DESCRIPTION
        Shape:
          {
            "script":   "<script-name>",
            "logfile":  "<path or null>",
            "verbose":  true|false,
            "counts":   { "ok": N, "fail": N, "skip": N, "total": N },
            "tail":     [ "<line>", ... up to 20 ],
            "tailShown":N,
            "tailMax":  20,
            "timestamp":"<iso8601>"
          }
        Always written, even when no operations were recorded (counts all 0,
        tail empty), so callers can rely on a single line of JSON per run.

    .PARAMETER TailLines
        How many recent lines to include. Defaults to 20.

    .PARAMETER Source
        Origin of the resolved tail value: "param" | "env" | "default".
        Echoed in the JSON as `tailSource` so machine consumers can
        distinguish a default from an explicit user choice.
    #>
    param(
        [int]$TailLines = 20,
        [string]$Source = "default"
    )

    $counts = Get-RegistryTraceCounts
    $hasTrace = $script:_RegTraceEnabled -and $script:_RegTracePath

    $tailArr = @()
    if ($null -ne $script:_RegTraceTail) {
        $tailArr = @($script:_RegTraceTail.ToArray())
    }
    $start = [Math]::Max(0, $tailArr.Count - $TailLines)
    $shown = New-Object System.Collections.ArrayList
    for ($i = $start; $i -lt $tailArr.Count; $i++) {
        [void]$shown.Add($tailArr[$i])
    }

    $payload = [ordered]@{
        script     = $script:_RegTraceScript
        logfile    = if ($hasTrace) { $script:_RegTracePath } else { $null }
        verbose    = [bool]$script:_RegTraceEnabled
        counts     = [ordered]@{
            ok    = [int]$counts.OK
            fail  = [int]$counts.FAIL
            skip  = [int]$counts.SKIP
            total = [int]$counts.Total
        }
        tail       = @($shown.ToArray())
        tailShown  = [int]$shown.Count
        tailMax    = [int]$TailLines
        tailSource = "$Source"
        timestamp  = (Get-Date).ToString("o")
    }

    # -Compress = single line; safer for line-oriented consumers (jq -c, grep)
    $json = $payload | ConvertTo-Json -Compress -Depth 5
    # Marker prefix lets callers grep one line out of mixed stdout if needed.
    Write-Output "REGTRACE_SUMMARY_JSON $json"
}

function Close-RegistryTrace {
    <#
    .SYNOPSIS
        Append a footer with a one-line summary. Optional; safe if no trace.

    .PARAMETER TailLines
        Override how many trailing trace lines the human + JSON summaries
        include. When omitted, the env-var REGTRACE_SUMMARY_TAIL is read
        (set by --summary-tail N at the dispatcher), and finally the
        module default $script:_RegTraceTailMax (20) is used. Negative
        values are clamped to 0; non-numeric env values are ignored.
    #>
    param(
        [string]$Status = "ok",
        [switch]$NoSummary,
        [Nullable[int]]$TailLines = $null
    )

    # Resolve effective tail count: explicit param > env var > default.
    # Track which source won so the human + JSON summaries can echo it.
    $effectiveTail = $script:_RegTraceTailMax
    $tailSource    = "default"
    if ($null -ne $TailLines) {
        $effectiveTail = [int]$TailLines
        $tailSource    = "param"
    } else {
        try {
            $envTail = [Environment]::GetEnvironmentVariable("REGTRACE_SUMMARY_TAIL")
            if (-not [string]::IsNullOrWhiteSpace($envTail)) {
                $parsed = 0
                if ([int]::TryParse($envTail, [ref]$parsed) -and $parsed -ge 0) {
                    $effectiveTail = $parsed
                    $tailSource    = "env"
                }
            }
        } catch { } # leave default on any read failure
    }
    if ($effectiveTail -lt 0) { $effectiveTail = 0 }

    # Always print the one-command summary (last N + totals) unless suppressed.
    # Safe when -Verbose was not set: prints a one-line "no trace" notice.
    if (-not $NoSummary) {
        Show-RegistryTraceSummary -TailLines $effectiveTail -Source $tailSource
    }

    # Machine-readable JSON summary (--summary-json). Honour either the
    # explicit module flag or the env-var fallback so a parent dispatcher can
    # flip it on without modifying every helper.
    $envOn = $false
    try {
        $envVal = [Environment]::GetEnvironmentVariable("REGTRACE_SUMMARY_JSON")
        if (-not [string]::IsNullOrWhiteSpace($envVal)) {
            $envOn = ($envVal -in @("1","true","yes","on"))
        }
    } catch { $envOn = $false }
    $emitJson = $script:_RegTraceSummaryJson -or $envOn
    if ($emitJson -and -not $NoSummary) {
        try { Show-RegistryTraceSummaryJsonOutput -TailLines $effectiveTail -Source $tailSource }
        catch { Write-Host "  [ WARN ] summary-json emit failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    $hasTrace = $script:_RegTraceEnabled -and $script:_RegTracePath
    if (-not $hasTrace) { return }
    $footer = @(
        "",
        "  Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')   Status: $Status",
        "================================================================================",
        ""
    ) -join [Environment]::NewLine
    try { Add-Content -LiteralPath $script:_RegTracePath -Value $footer -Encoding UTF8 } catch {}
}

# ── Sweep-helper parser: detect -Verbose / --verbose in $Argv ───────────────
function Test-VerboseSwitch {
    <#
    .SYNOPSIS
        Same shape as Test-DryRunSwitch / Test-YesSwitch in _sweep.ps1.
        Recognises -Verbose, --verbose, -v (long form only -- we do NOT
        accept bare `-v` because cleaner CLIs already use `-y`).
    #>
    param([string[]]$Argv)
    if ($null -eq $Argv) { return $false }
    foreach ($a in $Argv) {
        $t = "$a".Trim().ToLower()
        if ($t -in @("--verbose","-verbose","/verbose")) { return $true }
    }
    return $false
}
