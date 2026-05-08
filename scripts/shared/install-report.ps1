# --------------------------------------------------------------------------
#  Install/Uninstall Report Generator
#
#  Reads .logs/*.json (per-script run summaries) and .installed/*.json
#  (current tracking records) and emits a timestamped JSON + HTML report
#  to .reports/ summarising every install/uninstall action and the
#  .installed/ records that were created or updated.
#
#  Usage (from run.ps1 dispatch):
#     Invoke-InstallReport -Args @("--since=24h", "--format=html,json")
#
#  Flags:
#     --since=<n>[m|h|d]   Only include log runs newer than now - <n>.
#                          Default: 7d. Use "all" or "0" for no limit.
#     --format=json,html   Comma-separated outputs. Default: both.
#     --open               Open the HTML report after generation.
#     --quiet              Suppress per-row console table.
# --------------------------------------------------------------------------

function Get-InstallReportSinceCutoff {
    param([string]$Since)

    $value = "$Since".Trim().ToLower()
    if ($value -in @("all", "0", "")) { return [datetime]::MinValue }

    if ($value -match '^(\d+)([mhd])$') {
        $n    = [int]$Matches[1]
        $unit = $Matches[2]
        switch ($unit) {
            'm' { return (Get-Date).AddMinutes(-$n) }
            'h' { return (Get-Date).AddHours(-$n) }
            'd' { return (Get-Date).AddDays(-$n) }
        }
    }

    # Fallback: 7 days
    return (Get-Date).AddDays(-7)
}

function ConvertTo-InstallReportAction {
    <#
    .SYNOPSIS
        Classify a script log entry as install / uninstall / reinstall / other
        based on script name + events list.
    #>
    param($LogObj)

    $name = "$($LogObj.scriptName)".ToLower()

    $isUninstallByName = $name -like "*uninstall*" -or $name -like "*remove*"
    if ($isUninstallByName) { return "uninstall" }

    $isInstallByName = $name -like "install*" -or $name -like "*-install-*"
    if ($isInstallByName) { return "install" }

    # Inspect events for hints (Save-LogFile records hooks like uninstalling/installing)
    $hasEvents = $LogObj.PSObject.Properties.Name -contains 'events' -and $null -ne $LogObj.events
    if ($hasEvents) {
        foreach ($ev in $LogObj.events) {
            $msg = "$($ev.message)".ToLower()
            if ($msg -match 'uninstall(ing|ed|ation)') { return "uninstall" }
            if ($msg -match 'reinstall')               { return "reinstall" }
            if ($msg -match 'install(ing|ed|ation)')   { return "install" }
        }
    }

    return "other"
}

function Get-InstallReportData {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [datetime]$Since = [datetime]::MinValue
    )

    $logsDir       = Join-Path $ProjectRoot ".logs"
    $installedDir  = Join-Path $ProjectRoot ".installed"

    $logEntries     = @()
    $isLogsDirHere  = Test-Path $logsDir
    if ($isLogsDirHere) {
        $logFiles = Get-ChildItem -Path $logsDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike "*-error.json" } |
                    Sort-Object LastWriteTime -Descending

        foreach ($lf in $logFiles) {
            try { $obj = Get-Content $lf.FullName -Raw | ConvertFrom-Json } catch { continue }

            $startVal = if ($obj.PSObject.Properties.Name -contains 'startTime') { $obj.startTime } else { $null }
            $endVal   = if ($obj.PSObject.Properties.Name -contains 'endTime')   { $obj.endTime }   else { $null }

            $startDt = $null; $endDt = $null
            if ($startVal) { try { $startDt = [datetime]::Parse($startVal) } catch {} }
            if ($endVal)   { try { $endDt   = [datetime]::Parse($endVal)   } catch {} }
            if (-not $startDt) { $startDt = $lf.LastWriteTime }
            if (-not $endDt)   { $endDt   = $lf.LastWriteTime }

            $isWithinWindow = $startDt -ge $Since
            if (-not $isWithinWindow) { continue }

            $logEntries += [pscustomobject]@{
                file       = $lf.Name
                scriptName = "$($obj.scriptName)"
                action     = ConvertTo-InstallReportAction -LogObj $obj
                status     = "$($obj.status)"
                startTime  = $startDt
                endTime    = $endDt
                duration   = if ($obj.PSObject.Properties.Name -contains 'duration') { $obj.duration } else { $null }
                errorCount = if ($obj.PSObject.Properties.Name -contains 'errorCount') { $obj.errorCount } else { 0 }
                warnCount  = if ($obj.PSObject.Properties.Name -contains 'warnCount')  { $obj.warnCount }  else { 0 }
                gitSha     = if ($obj.PSObject.Properties.Name -contains 'gitSha')     { $obj.gitSha }     else { "" }
            }
        }
    }

    $installedRecords = @()
    $isInstalledDirHere = Test-Path $installedDir
    if ($isInstalledDirHere) {
        $recFiles = Get-ChildItem -Path $installedDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                    Sort-Object Name
        foreach ($rf in $recFiles) {
            try { $rec = Get-Content $rf.FullName -Raw | ConvertFrom-Json } catch { continue }

            $installedAt = $null; $lastChecked = $null
            try { if ($rec.installedAt) { $installedAt = [datetime]::Parse($rec.installedAt) } } catch {}
            try { if ($rec.lastChecked) { $lastChecked = [datetime]::Parse($rec.lastChecked) } } catch {}

            $hasError = $false
            if ($rec.PSObject.Properties.Name -contains 'lastError') {
                $hasError = $rec.lastError -and ($rec.lastError -ne "")
            }

            $installedRecords += [pscustomobject]@{
                file        = $rf.Name
                name        = if ($rec.name)    { $rec.name }    else { $rf.BaseName }
                version     = if ($rec.version) { $rec.version } else { "unknown" }
                method      = if ($rec.method)  { $rec.method }  else { "" }
                installedAt = $installedAt
                lastChecked = $lastChecked
                lastError   = if ($hasError) { $rec.lastError } else { "" }
                fileWritten = $rf.LastWriteTime
                isModel     = $rf.BaseName -like "model-*"
            }
        }
    }

    # Cross-reference: for each log run, find .installed records that were
    # created or updated within the run's [startTime - 30s, endTime + 5m] window.
    foreach ($le in $logEntries) {
        $windowStart = $le.startTime.AddSeconds(-30)
        $windowEnd   = $le.endTime.AddMinutes(5)
        $touched = @()
        foreach ($rec in $installedRecords) {
            $isInWindow = $rec.fileWritten -ge $windowStart -and $rec.fileWritten -le $windowEnd
            if ($isInWindow) {
                $touched += [pscustomobject]@{
                    name        = $rec.name
                    version     = $rec.version
                    method      = $rec.method
                    file        = $rec.file
                    fileWritten = $rec.fileWritten
                    hasError    = ($rec.lastError -ne "")
                }
            }
        }
        Add-Member -InputObject $le -MemberType NoteProperty -Name 'touchedRecords' -Value $touched -Force
    }

    return [pscustomobject]@{
        generatedAt      = (Get-Date)
        projectRoot      = $ProjectRoot
        sinceCutoff      = if ($Since -eq [datetime]::MinValue) { "all" } else { $Since.ToString("o") }
        logEntryCount    = $logEntries.Count
        installedCount   = $installedRecords.Count
        logEntries       = @($logEntries)
        installedRecords = @($installedRecords)
    }
}

function Write-InstallReportJson {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$OutPath
    )

    $serialisable = [pscustomobject]@{
        generatedAt      = $Report.generatedAt.ToString("o")
        projectRoot      = $Report.projectRoot
        sinceCutoff      = $Report.sinceCutoff
        logEntryCount    = $Report.logEntryCount
        installedCount   = $Report.installedCount
        logEntries       = @($Report.logEntries | ForEach-Object {
            [pscustomobject]@{
                file        = $_.file
                scriptName  = $_.scriptName
                action      = $_.action
                status      = $_.status
                startTime   = $_.startTime.ToString("o")
                endTime     = $_.endTime.ToString("o")
                duration    = $_.duration
                errorCount  = $_.errorCount
                warnCount   = $_.warnCount
                gitSha      = $_.gitSha
                touchedRecords = @($_.touchedRecords | ForEach-Object {
                    [pscustomobject]@{
                        name        = $_.name
                        version     = $_.version
                        method      = $_.method
                        file        = $_.file
                        fileWritten = $_.fileWritten.ToString("o")
                        hasError    = $_.hasError
                    }
                })
            }
        })
        installedRecords = @($Report.installedRecords | ForEach-Object {
            [pscustomobject]@{
                file        = $_.file
                name        = $_.name
                version     = $_.version
                method      = $_.method
                installedAt = if ($_.installedAt) { $_.installedAt.ToString("o") } else { $null }
                lastChecked = if ($_.lastChecked) { $_.lastChecked.ToString("o") } else { $null }
                lastError   = $_.lastError
                fileWritten = $_.fileWritten.ToString("o")
                isModel     = $_.isModel
            }
        })
    }

    $serialisable | ConvertTo-Json -Depth 8 | Set-Content -Path $OutPath -Encoding UTF8
}

function ConvertTo-InstallReportHtmlEscape {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value `
        -replace '&', '&amp;' `
        -replace '<', '&lt;' `
        -replace '>', '&gt;' `
        -replace '"', '&quot;')
}

function Write-InstallReportHtml {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$OutPath
    )

    $esc = { param($v) ConvertTo-InstallReportHtmlEscape -Value "$v" }

    $rowsHtml = New-Object System.Text.StringBuilder
    foreach ($le in $Report.logEntries) {
        $actionClass = "action-" + ($le.action)
        $statusClass = "status-" + ($le.status)

        $touchedHtml = ""
        $hasTouched = @($le.touchedRecords).Count -gt 0
        if ($hasTouched) {
            $items = foreach ($t in $le.touchedRecords) {
                $errBadge = if ($t.hasError) { " <span class='badge badge-err'>error</span>" } else { "" }
                "<li><code>$(& $esc $t.name)</code> <span class='ver'>$(& $esc $t.version)</span> <span class='meta'>($(& $esc $t.method))</span>$errBadge</li>"
            }
            $touchedHtml = "<ul class='touched'>$($items -join '')</ul>"
        } else {
            $touchedHtml = "<span class='muted'>(none)</span>"
        }

        [void]$rowsHtml.Append(@"
<tr>
  <td class='ts'>$(& $esc $le.startTime.ToString('yyyy-MM-dd HH:mm:ss'))</td>
  <td><span class='pill $actionClass'>$(& $esc $le.action)</span></td>
  <td><code>$(& $esc $le.scriptName)</code></td>
  <td><span class='pill $statusClass'>$(& $esc $le.status)</span></td>
  <td class='num'>$(& $esc $le.duration)s</td>
  <td class='num'>$(& $esc $le.errorCount)</td>
  <td>$touchedHtml</td>
</tr>
"@)
    }

    $installedRowsHtml = New-Object System.Text.StringBuilder
    foreach ($r in $Report.installedRecords) {
        $kind = if ($r.isModel) { "model" } else { "tool" }
        $errCell = if ($r.lastError) { "<span class='badge badge-err'>$(& $esc $r.lastError)</span>" } else { "<span class='muted'>ok</span>" }
        [void]$installedRowsHtml.Append(@"
<tr>
  <td><code>$(& $esc $r.name)</code></td>
  <td>$(& $esc $r.version)</td>
  <td>$(& $esc $r.method)</td>
  <td><span class='pill kind-$kind'>$kind</span></td>
  <td class='ts'>$(& $esc (if ($r.installedAt) { $r.installedAt.ToString('yyyy-MM-dd HH:mm') } else { '' }))</td>
  <td>$errCell</td>
</tr>
"@)
    }

    $generated = $Report.generatedAt.ToString("yyyy-MM-dd HH:mm:ss zzz")
    $since     = $Report.sinceCutoff

    $html = @"
<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<title>Install Report - $generated</title>
<style>
  :root { color-scheme: dark light; }
  body { font: 14px/1.5 -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; padding: 24px; background: #0f172a; color: #e2e8f0; }
  h1 { margin: 0 0 4px; font-size: 22px; }
  .sub { color: #94a3b8; margin-bottom: 24px; font-size: 13px; }
  .summary { display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap; }
  .card { background: #1e293b; padding: 12px 18px; border-radius: 8px; border: 1px solid #334155; }
  .card .n { font-size: 24px; font-weight: 600; }
  .card .l { color: #94a3b8; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 32px; background: #1e293b; border-radius: 8px; overflow: hidden; }
  th, td { padding: 8px 12px; text-align: left; border-bottom: 1px solid #334155; vertical-align: top; }
  th { background: #0f172a; font-size: 12px; text-transform: uppercase; color: #94a3b8; letter-spacing: 0.05em; }
  tr:last-child td { border-bottom: none; }
  td.ts, td.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
  td.num { text-align: right; }
  code { background: rgba(148,163,184,0.15); padding: 1px 6px; border-radius: 4px; font-size: 12.5px; }
  .pill { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; }
  .action-install   { background: #064e3b; color: #6ee7b7; }
  .action-uninstall { background: #7f1d1d; color: #fca5a5; }
  .action-reinstall { background: #78350f; color: #fcd34d; }
  .action-other     { background: #334155; color: #cbd5e1; }
  .status-ok                { background: #065f46; color: #a7f3d0; }
  .status-already-installed { background: #1e3a8a; color: #93c5fd; }
  .status-fail              { background: #7f1d1d; color: #fecaca; }
  .kind-tool  { background: #1e3a8a; color: #93c5fd; }
  .kind-model { background: #581c87; color: #d8b4fe; }
  .badge { display: inline-block; padding: 1px 6px; border-radius: 4px; font-size: 11px; }
  .badge-err { background: #7f1d1d; color: #fecaca; }
  ul.touched { margin: 0; padding-left: 18px; }
  ul.touched li { margin: 2px 0; }
  ul.touched .ver { color: #fcd34d; font-family: ui-monospace, monospace; font-size: 12px; }
  ul.touched .meta { color: #94a3b8; font-size: 11px; }
  .muted { color: #64748b; font-style: italic; }
  @media (prefers-color-scheme: light) {
    body { background: #f8fafc; color: #0f172a; }
    .card, table { background: #fff; border-color: #e2e8f0; }
    th { background: #f1f5f9; }
    code { background: rgba(15,23,42,0.07); }
  }
</style>
</head>
<body>
  <h1>Install / Uninstall Report</h1>
  <div class='sub'>Generated $generated &middot; window: <code>$since</code> &middot; project: <code>$($Report.projectRoot)</code></div>
  <div class='summary'>
    <div class='card'><div class='n'>$($Report.logEntryCount)</div><div class='l'>Run entries</div></div>
    <div class='card'><div class='n'>$($Report.installedCount)</div><div class='l'>Tracked records</div></div>
  </div>

  <h2>Actions performed</h2>
  <table>
    <thead><tr>
      <th>Started</th><th>Action</th><th>Script</th><th>Status</th>
      <th>Dur.</th><th>Err</th><th>.installed/ records touched</th>
    </tr></thead>
    <tbody>
$($rowsHtml.ToString())
    </tbody>
  </table>

  <h2>Current .installed/ snapshot</h2>
  <table>
    <thead><tr>
      <th>Name</th><th>Version</th><th>Method</th><th>Kind</th><th>Installed at</th><th>Last error</th>
    </tr></thead>
    <tbody>
$($installedRowsHtml.ToString())
    </tbody>
  </table>
</body>
</html>
"@

    $html | Set-Content -Path $OutPath -Encoding UTF8
}

function Invoke-InstallReport {
    param(
        [string[]]$Args,
        [string]$ProjectRoot
    )

    $isProjectRootEmpty = [string]::IsNullOrWhiteSpace($ProjectRoot)
    if ($isProjectRootEmpty) {
        # scripts/shared/install-report.ps1 -> project root is two levels up
        $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        # If sourced from run.ps1 directly, fall back to PWD
        $isProjectRootBad = -not (Test-Path (Join-Path $ProjectRoot "run.ps1"))
        if ($isProjectRootBad) { $ProjectRoot = (Get-Location).Path }
    }

    # Parse flags
    $sinceArg   = "7d"
    $formatArg  = "json,html"
    $isOpenHtml = $false
    $isQuiet    = $false
    if ($null -ne $Args) {
        foreach ($a in $Args) {
            $av = "$a".Trim()
            if ($av -match '^--since=(.+)$')  { $sinceArg  = $Matches[1] }
            elseif ($av -match '^--format=(.+)$') { $formatArg = $Matches[1] }
            elseif ($av -in @("--open", "-o"))    { $isOpenHtml = $true }
            elseif ($av -in @("--quiet", "-q"))   { $isQuiet = $true }
            elseif ($av -in @("-h", "--help", "help")) {
                Write-Host ""
                Write-Host "  report  --  generate install/uninstall JSON + HTML report" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Usage: .\run.ps1 report [--since=<n>m|h|d|all] [--format=json,html] [--open] [--quiet]"
                Write-Host ""
                Write-Host "  Examples:"
                Write-Host "    .\run.ps1 report                       # last 7 days, both formats"
                Write-Host "    .\run.ps1 report --since=24h --open    # last 24h, open HTML"
                Write-Host "    .\run.ps1 report --since=all --format=json"
                Write-Host ""
                return
            }
        }
    }

    $since = Get-InstallReportSinceCutoff -Since $sinceArg
    Write-Host ""
    Write-Host "  Generating install report..." -ForegroundColor Cyan
    Write-Host "    Project   : $ProjectRoot"
    Write-Host "    Window    : $sinceArg (cutoff = $($since))"
    Write-Host "    Format    : $formatArg"
    Write-Host ""

    $report = Get-InstallReportData -ProjectRoot $ProjectRoot -Since $since

    $reportsDir = Join-Path $ProjectRoot ".reports"
    $isReportsDirMissing = -not (Test-Path $reportsDir)
    if ($isReportsDirMissing) { New-Item -Path $reportsDir -ItemType Directory -Force | Out-Null }

    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $base  = Join-Path $reportsDir "install-report-$stamp"

    $formats = ($formatArg -split '[,;\s]+') | Where-Object { $_ -ne "" } | ForEach-Object { $_.ToLower() }
    $writeJson = $formats -contains "json"
    $writeHtml = $formats -contains "html"

    $jsonPath = "$base.json"
    $htmlPath = "$base.html"

    if ($writeJson) {
        try {
            Write-InstallReportJson -Report $report -OutPath $jsonPath
            Write-Host "  [  OK  ] JSON: $jsonPath" -ForegroundColor Green
        } catch {
            Write-Host "  [ FAIL ] JSON write failed for path '$jsonPath' -- $_" -ForegroundColor Red
        }
    }
    if ($writeHtml) {
        try {
            Write-InstallReportHtml -Report $report -OutPath $htmlPath
            Write-Host "  [  OK  ] HTML: $htmlPath" -ForegroundColor Green
        } catch {
            Write-Host "  [ FAIL ] HTML write failed for path '$htmlPath' -- $_" -ForegroundColor Red
        }
    }

    if (-not $isQuiet) {
        Write-Host ""
        Write-Host "  Summary: $($report.logEntryCount) run(s), $($report.installedCount) tracked record(s)" -ForegroundColor DarkGray
        $byAction = $report.logEntries | Group-Object action | Sort-Object Name
        foreach ($g in $byAction) {
            Write-Host ("    {0,-10} {1}" -f $g.Name, $g.Count) -ForegroundColor DarkGray
        }
    }

    $shouldOpen = $isOpenHtml -and $writeHtml -and (Test-Path $htmlPath)
    if ($shouldOpen) {
        try { Start-Process $htmlPath } catch { Write-Host "  [ WARN ] Could not open '$htmlPath' -- $_" -ForegroundColor Yellow }
    }

    Write-Host ""
}
