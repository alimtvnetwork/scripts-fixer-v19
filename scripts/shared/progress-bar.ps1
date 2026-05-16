# --------------------------------------------------------------------------
#  Shared helper: download progress bar (winget-style, truecolor gradient)
#
#  Public functions:
#     Write-DownloadProgressBar   -- redraw a single in-place progress line
#     Complete-DownloadProgressBar -- finalise the line (newline + summary)
#     Invoke-Aria2WithProgressBar -- run aria2c, parse its summary output,
#                                    drive the bar, return the exit code
#
#  Uses ANSI 24-bit truecolor escapes so every cell of the bar carries its
#  own gradient stop (red -> orange -> yellow -> green -> cyan -> blue),
#  with coloured "pill" backgrounds for the phase tag and each metric.
#  Glyphs stay ASCII-only per mem://constraints/terminal-banners.
# --------------------------------------------------------------------------

$_sharedDir = $PSScriptRoot
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# Enable ANSI escape processing on legacy conhost. Modern Windows Terminal,
# ConEmu, and pwsh 7 already have this on; the call is a safe no-op when
# the host does not expose the property.
try {
    if ($Host.UI.RawUI -and $Host.UI.SupportsVirtualTerminal -eq $false) {
        # nothing to do -- escapes will degrade to plain text
    }
} catch {}

$script:_pbarLastLen      = 0
$script:_pbarFirstRender  = $true
$script:_pbarIndent       = '          '
$script:_pbarStartTime    = $null

# ANSI helpers ---------------------------------------------------------------
$ESC = [char]27
function _ansi-fg { param([int]$r,[int]$g,[int]$b) "$ESC[38;2;$r;$g;${b}m" }
function _ansi-bg { param([int]$r,[int]$g,[int]$b) "$ESC[48;2;$r;$g;${b}m" }
$RESET = "$ESC[0m"
$BOLD  = "$ESC[1m"
$DIM   = "$ESC[2m"

function _lerp { param([int]$a,[int]$b,[double]$t) [int]([math]::Round($a + ($b - $a) * $t)) }

function _gradient-color {
    # Map t in [0,1] across a rainbow: red -> orange -> yellow -> green -> cyan -> blue -> magenta.
    param([double]$t)
    if ($t -lt 0) { $t = 0 } elseif ($t -gt 1) { $t = 1 }
    $stops = @(
        @(255, 64,  64),    # red
        @(255, 140, 0),     # orange
        @(255, 215, 0),     # gold
        @(80,  220, 100),   # green
        @(0,   200, 220),   # cyan
        @(80,  140, 255),   # blue
        @(200, 100, 255)    # violet
    )
    $segs = $stops.Count - 1
    $pos  = $t * $segs
    $i    = [int][math]::Floor($pos)
    if ($i -ge $segs) { $i = $segs - 1 }
    $localT = $pos - $i
    $a = $stops[$i]; $b = $stops[$i + 1]
    return ,@( (_lerp $a[0] $b[0] $localT), (_lerp $a[1] $b[1] $localT), (_lerp $a[2] $b[2] $localT) )
}

function Format-DownloadElapsed {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds([math]::Floor($Seconds))
    if ($ts.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
    }
    return ('{0:00}:{1:00}' -f [int]$ts.TotalMinutes, $ts.Seconds)
}

function _pill {
    # Render a coloured pill: " LABEL " with a background colour and white bold text.
    param([string]$Text, [int]$r, [int]$g, [int]$b, [int]$fr = 255, [int]$fg = 255, [int]$fb = 255)
    return (_ansi-bg $r $g $b) + (_ansi-fg $fr $fg $fb) + $BOLD + " $Text " + $RESET
}

function Write-DownloadProgressBar {
    <#
    .SYNOPSIS
        Render a colourful single-line download progress bar in place.
        Uses ANSI 24-bit truecolor gradient across the filled cells and
        coloured background pills for each metric.
    #>
    param(
        [Parameter(Mandatory)] [int]    $Percent,
        [string] $Sizes = "",
        [string] $Speed = "",
        [string] $Eta   = "",
        [string] $Label = "",
        [int]    $Width = 42
    )

    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    if ($script:_pbarFirstRender) {
        $script:_pbarStartTime = Get-Date
    }

    $filled = [int]([math]::Floor($Width * $Percent / 100.0))
    if ($filled -gt $Width) { $filled = $Width }
    $empty  = $Width - $filled

    # Phase tag + colour palette per phase.
    if     ($Percent -ge 100) { $phaseLabel = 'DONE ';  $phaseRgb = @(80, 220, 100) }
    elseif ($Percent -ge 70)  { $phaseLabel = 'FINAL';  $phaseRgb = @(0,  200, 220) }
    elseif ($Percent -ge 1)   { $phaseLabel = ' DL  ';  $phaseRgb = @(255, 140, 0)  }
    else                      { $phaseLabel = 'WAIT ';  $phaseRgb = @(180, 180, 180) }

    # Elapsed seconds for this download
    $elapsedStr = ''
    if ($script:_pbarStartTime) {
        $elapsed = (Get-Date) - $script:_pbarStartTime
        $elapsedStr = Format-DownloadElapsed -Seconds $elapsed.TotalSeconds
    }

    # Truncate label so the whole line still fits on one row.
    $shortLabel = $Label
    $maxLabel = 28
    if ($shortLabel.Length -gt $maxLabel) {
        $shortLabel = $shortLabel.Substring(0, $maxLabel - 1) + '~'
    }

    if ($script:_pbarFirstRender) {
        Write-Host ""
        $script:_pbarFirstRender = $false
    }

    $indent = $script:_pbarIndent

    # ---- Build the rendered string with ANSI escapes ------------------------
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.Append("`r")
    [void]$sb.Append($indent)

    # Phase pill
    [void]$sb.Append((_pill $phaseLabel $phaseRgb[0] $phaseRgb[1] $phaseRgb[2]))
    [void]$sb.Append('  ')

    # Percent (coloured by gradient position)
    $pctRgb = _gradient-color ($Percent / 100.0)
    [void]$sb.Append((_ansi-fg $pctRgb[0] $pctRgb[1] $pctRgb[2]))
    [void]$sb.Append($BOLD)
    [void]$sb.Append(('{0,3}%' -f $Percent))
    [void]$sb.Append($RESET)
    [void]$sb.Append('  ')

    # Bar: each filled cell carries its own gradient colour;
    # empty cells are dim grey on slightly lighter grey background.
    [void]$sb.Append((_ansi-fg 90 90 90))
    [void]$sb.Append('[')
    [void]$sb.Append($RESET)

    for ($i = 0; $i -lt $Width; $i++) {
        $t = if ($Width -gt 1) { $i / ($Width - 1.0) } else { 0 }
        if ($i -lt $filled) {
            $c = _gradient-color $t
            # filled = solid block on coloured background for vivid look
            [void]$sb.Append((_ansi-bg $c[0] $c[1] $c[2]))
            [void]$sb.Append((_ansi-fg $c[0] $c[1] $c[2]))
            [void]$sb.Append('#')
            [void]$sb.Append($RESET)
        } else {
            [void]$sb.Append((_ansi-fg 70 70 70))
            [void]$sb.Append('-')
            [void]$sb.Append($RESET)
        }
    }

    [void]$sb.Append((_ansi-fg 90 90 90))
    [void]$sb.Append(']')
    [void]$sb.Append($RESET)
    [void]$sb.Append('  ')

    # Sizes pill (slate blue)
    if ($Sizes) {
        [void]$sb.Append((_pill $Sizes 60 90 140))
    }
    # Speed pill (green)
    if ($Speed) {
        [void]$sb.Append((_pill ("spd " + $Speed) 40 140 70))
    }
    # ETA pill (gold)
    if ($Eta) {
        [void]$sb.Append((_pill ("eta " + $Eta) 180 130 20) )
    }
    # Elapsed pill (violet)
    if ($elapsedStr) {
        [void]$sb.Append((_pill ("up " + $elapsedStr) 130 70 170))
    }
    # Label (cyan italic, no pill)
    if ($shortLabel) {
        [void]$sb.Append((_ansi-fg 90 220 230))
        [void]$sb.Append("  $shortLabel")
        [void]$sb.Append($RESET)
    }

    # Compute plain length for residue padding (strip ANSI for measurement).
    $rendered = $sb.ToString()
    $plain = [regex]::Replace($rendered, "$ESC\[[0-9;]*m", '')
    $padNeeded = [math]::Max(0, $script:_pbarLastLen - $plain.Length)
    $script:_pbarLastLen = $plain.Length

    if ($padNeeded -gt 0) {
        $rendered += (' ' * $padNeeded)
    }

    [Console]::Write($rendered)
}

function Complete-DownloadProgressBar {
    <#
    .SYNOPSIS
        Move to a new line after a Write-DownloadProgressBar sequence so the
        next log lines do not overwrite the bar.
    #>
    param([switch]$Success, [string]$Label = "")

    if ($script:_pbarLastLen -gt 0) {
        Write-Host ""
        Write-Host ""
        Write-Host ""
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
    #>
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $Label = ""
    )

    $progressRx      = [regex]'\[#\w+\s+([^/]+)/([^()]+)\((\d+)%\)[^\]]*DL:(\S+?)\s+ETA:(\S+?)\]'
    $progressRxNoEta = [regex]'\[#\w+\s+([^/]+)/([^()]+)\((\d+)%\)[^\]]*DL:(\S+?)\]'

    $script:_pbarLastLen = 0
    $exitCode = -1

    try {
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

            if ($line -match '^\s*$')                      { return }
            if ($line -match '^=+$')                       { return }
            if ($line -match '^-+$')                       { return }
            if ($line -match 'Download Progress Summary')  { return }
            if ($line -match '^FILE:')                     { return }
            if ($line -match '^\s*Status Legend')          { return }
            if ($line -match '^\(OK\):')                   { return }
            if ($line -match 'gid\|stat\|avg speed')        { return }

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

    if ($exitCode -eq 0) {
        Write-DownloadProgressBar -Percent 100 -Sizes "done" -Speed "" -Eta "0s" -Label $Label
    }
    Complete-DownloadProgressBar

    return $exitCode
}
