# --------------------------------------------------------------------------
#  Shared helper: download progress bar (winget-style, colour-graduated)
#
#  Public functions:
#     Write-DownloadProgressBar   -- redraw a single in-place progress line
#     Complete-DownloadProgressBar -- finalise the line (newline + summary)
#     Invoke-Aria2WithProgressBar -- run aria2c, parse its summary output,
#                                    drive the bar, return the exit code
#
#  Reusable from any caller that streams aria2c (or any other downloader
#  that yields "<percent>%, <size>, <speed>, <eta>") output.
#
#  Memory: scripts/shared/progress-bar.ps1 -- console-safe ASCII glyphs only
#  (no wide Unicode, no em dash) per terminal-banners constraint.
# --------------------------------------------------------------------------

$_sharedDir = $PSScriptRoot
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# Track last rendered width so we can pad subsequent shorter lines and
# fully overwrite the previous render.
$script:_pbarLastLen = 0
$script:_pbarFirstRender = $true
$script:_pbarIndent = '          '   # left padding (indent) so the bar sits inset from the edge
$script:_pbarStartTime = $null       # tracks elapsed seconds for current download

function Format-DownloadElapsed {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds([math]::Floor($Seconds))
    if ($ts.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
    }
    return ('{0:00}:{1:00}' -f [int]$ts.TotalMinutes, $ts.Seconds)
}

function Get-DownloadBarColor {
    param([int]$Percent)
    if     ($Percent -lt 25)  { return 'Red' }
    elseif ($Percent -lt 50)  { return 'Yellow' }
    elseif ($Percent -lt 75)  { return 'Cyan' }
    elseif ($Percent -lt 100) { return 'Green' }
    else                      { return 'Green' }
}

function Write-DownloadProgressBar {
    <#
    .SYNOPSIS
        Render a colourful single-line download progress bar in place.
        Uses carriage-return repaint, ASCII glyphs only.
    #>
    param(
        [Parameter(Mandatory)] [int]    $Percent,
        [string] $Sizes = "",
        [string] $Speed = "",
        [string] $Eta   = "",
        [string] $Label = "",
        [int]    $Width = 36
    )

    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    if ($script:_pbarFirstRender) {
        $script:_pbarStartTime = Get-Date
    }

    $filled = [int]([math]::Floor($Width * $Percent / 100.0))
    if ($filled -gt $Width) { $filled = $Width }
    $empty  = $Width - $filled

    $color  = Get-DownloadBarColor -Percent $Percent
    # ASCII-only bar: '=' filled, '>' moving head, ' ' empty, '|' bookends.
    # Per mem://constraints/terminal-banners -- avoid wide Unicode / emoji
    # that legacy conhost or non-UTF-8 sessions render as '?'.
    if ($Percent -ge 100 -or $filled -le 0) {
        $barFilled = ('=' * $filled)
    } else {
        $barFilled = ('=' * [math]::Max(0, $filled - 1)) + '>'
    }
    $barEmpty = (' ' * $empty)
    $pctStr   = ('{0,3}%' -f $Percent)

    # Phase tag (bracketed ASCII, console-safe per project rule).
    $phaseTag =
        if     ($Percent -ge 100) { '[DONE]' }
        elseif ($Percent -ge 75)  { '[ >>> ]' }
        elseif ($Percent -ge 25)  { '[ DL  ]' }
        else                      { '[WAIT ]' }

    # Elapsed seconds for this download
    $elapsedStr = ''
    if ($script:_pbarStartTime) {
        $elapsed = (Get-Date) - $script:_pbarStartTime
        $elapsedStr = Format-DownloadElapsed -Seconds $elapsed.TotalSeconds
    }

    # Compose label (truncate to keep one line)
    $shortLabel = $Label
    $maxLabel = 28
    if ($shortLabel.Length -gt $maxLabel) {
        $shortLabel = $shortLabel.Substring(0, $maxLabel - 1) + "~"
    }

    # Top padding: blank line on first render for breathing room.
    if ($script:_pbarFirstRender) {
        Write-Host ""
        $script:_pbarFirstRender = $false
    }

    $indent = $script:_pbarIndent

    # Pad / clear residue from any prior longer render.
    $plain = "$indent$phaseTag  $pctStr  |$barFilled$barEmpty|  $Sizes  spd $Speed  eta $Eta  up $elapsedStr  $shortLabel"
    $padNeeded = [math]::Max(0, $script:_pbarLastLen - $plain.Length)
    $script:_pbarLastLen = $plain.Length

    # Render -- carriage return then segmented colour writes.
    [Console]::Write("`r")
    Write-Host -NoNewline $indent
    Write-Host -NoNewline $phaseTag -ForegroundColor $color
    Write-Host -NoNewline "  "
    Write-Host -NoNewline $pctStr -ForegroundColor $color
    Write-Host -NoNewline "  |"
    Write-Host -NoNewline $barFilled -ForegroundColor $color
    if ($empty -gt 0) {
        Write-Host -NoNewline $barEmpty -ForegroundColor DarkGray
    }
    Write-Host -NoNewline "|  "
    if ($Sizes) { Write-Host -NoNewline $Sizes -ForegroundColor White }
    if ($Speed) {
        Write-Host -NoNewline "  spd " -ForegroundColor DarkGray
        Write-Host -NoNewline $Speed   -ForegroundColor Green
    }
    if ($Eta)   {
        Write-Host -NoNewline "  eta " -ForegroundColor DarkGray
        Write-Host -NoNewline $Eta      -ForegroundColor Yellow
    }
    if ($elapsedStr) {
        Write-Host -NoNewline "  up "  -ForegroundColor DarkGray
        Write-Host -NoNewline $elapsedStr -ForegroundColor Magenta
    }
    if ($shortLabel) {
        Write-Host -NoNewline "  "
        Write-Host -NoNewline $shortLabel -ForegroundColor Cyan
    }
    if ($padNeeded -gt 0) {
        Write-Host -NoNewline (' ' * $padNeeded)
    }
}

function Complete-DownloadProgressBar {
    <#
    .SYNOPSIS
        Move to a new line after a Write-DownloadProgressBar sequence so the
        next log lines do not overwrite the bar.
    #>
    param([switch]$Success, [string]$Label = "")

    if ($script:_pbarLastLen -gt 0) {
        Write-Host ""    # newline after the in-place bar
        Write-Host ""    # blank line below for bottom padding
        Write-Host ""    # extra breathing room before next log section
        $script:_pbarLastLen = 0
    }
    $script:_pbarFirstRender = $true
    $script:_pbarStartTime = $null
}

function Invoke-Aria2WithProgressBar {
    <#
    .SYNOPSIS
        Spawn aria2c with the given argument array, suppress aria2c's noisy
        summary blocks, and render a single colourful in-place progress bar
        instead. Returns the aria2c exit code (or -1 on spawn failure).

    .PARAMETER Arguments
        Pre-built aria2c argument array. The caller MUST include
        --summary-interval=1 (or similar) so aria2c emits parseable status.

    .PARAMETER Label
        Friendly label to show on the right side of the bar.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $Label = ""
    )

    # Regex matches the line aria2c prints inside its summary block, e.g.
    #   [#921456 142MiB/5.3GiB(2%) CN:16 DL:34MiB ETA:2m35s]
    $progressRx = [regex]'\[#\w+\s+([^/]+)/([^()]+)\((\d+)%\)[^\]]*DL:(\S+?)\s+ETA:(\S+?)\]'
    # Also handle no-ETA variant (very small / very early downloads).
    $progressRxNoEta = [regex]'\[#\w+\s+([^/]+)/([^()]+)\((\d+)%\)[^\]]*DL:(\S+?)\]'

    $script:_pbarLastLen = 0
    $exitCode = -1

    try {
        # Use call-operator + pipeline so we get streaming output. Merge
        # stderr into stdout so aria2c warnings still surface.
        $global:LASTEXITCODE = 0
        & aria2c.exe @Arguments 2>&1 | ForEach-Object {
            $line = [string]$_

            $m = $progressRx.Match($line)
            if (-not $m.Success) {
                $m = $progressRxNoEta.Match($line)
            }
            if ($m.Success) {
                $sizes = '{0}/{1}' -f $m.Groups[1].Value.Trim(), $m.Groups[2].Value.Trim()
                $pct   = [int]$m.Groups[3].Value
                $speed = $m.Groups[4].Value
                $eta   = if ($m.Groups.Count -ge 6) { $m.Groups[5].Value } else { '--' }
                Write-DownloadProgressBar -Percent $pct -Sizes $sizes -Speed $speed -Eta $eta -Label $Label
                return
            }

            # Suppress aria2c's noisy summary chrome.
            if ($line -match '^\s*$')                      { return }
            if ($line -match '^=+$')                       { return }
            if ($line -match '^-+$')                       { return }
            if ($line -match 'Download Progress Summary')  { return }
            if ($line -match '^FILE:')                     { return }
            if ($line -match '^\s*Status Legend')          { return }
            if ($line -match '^\(OK\):')                   { return }
            if ($line -match 'gid\|stat\|avg speed')        { return }

            # Anything else (warnings/errors) is worth seeing -- newline first
            # so we don't smear over the in-place bar.
            if ($script:_pbarLastLen -gt 0) {
                Write-Host ""
                $script:_pbarLastLen = 0
            }
            Write-Host $line
        }
        $exitCode = $LASTEXITCODE
    } catch {
        if ($script:_pbarLastLen -gt 0) { Write-Host ""; $script:_pbarLastLen = 0 }
        Write-Log "[progress-bar] aria2c spawn failed: $($_.Exception.Message)" -Level "warn"
        $exitCode = -1
    }

    # Final 100% repaint + newline so the user sees a completed bar.
    if ($exitCode -eq 0) {
        Write-DownloadProgressBar -Percent 100 -Sizes "done" -Speed "" -Eta "0s" -Label $Label
    }
    Complete-DownloadProgressBar

    return $exitCode
}
