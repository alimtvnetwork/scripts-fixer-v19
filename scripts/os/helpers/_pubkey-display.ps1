# Shared helper: render a prominent boxed display of an SSH public key,
# and copy the raw key text to the clipboard.
#
# All output is ASCII only (per project terminal-banner rules: no em-dash,
# no wide Unicode box-drawing glyphs).

function Copy-PubKeyToClipboard {
    param([Parameter(Mandatory)] [string] $Text)

    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text -ErrorAction Stop
            return $true
        }
    } catch { }

    try {
        if (Get-Command clip.exe -ErrorAction SilentlyContinue) {
            $Text | clip.exe
            if ($LASTEXITCODE -eq 0) { return $true }
        }
    } catch { }

    return $false
}

function Show-PublicKeyBox {
    <#
        Renders a single public key in a large, copy-friendly ASCII box and
        copies its raw text to the clipboard.

        -Label       Optional title (default: "PUBLIC SSH KEY").
        -KeyText     The raw "ssh-ed25519 AAAA... comment" line.
        -Path        Source .pub path (shown in footer).
        -Fingerprint Optional fingerprint string (shown in footer).
        -NoCopy      Skip clipboard copy (still renders the box).
    #>
    param(
        [Parameter(Mandatory)] [string] $KeyText,
        [string] $Label = "PUBLIC SSH KEY",
        [string] $Path,
        [string] $Fingerprint,
        [switch] $NoCopy
    )

    $key = ($KeyText -replace "`r", "").Trim()
    if ([string]::IsNullOrWhiteSpace($key)) { return $false }

    # Decide visual width. Long ssh keys are ~100+ chars; we wrap them.
    $innerWidth = 76
    $border     = "+" + ("-" * ($innerWidth + 2)) + "+"

    # Wrap the key into lines of $innerWidth chars.
    $wrapped = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $key.Length; $i += $innerWidth) {
        $len = [Math]::Min($innerWidth, $key.Length - $i)
        $wrapped.Add($key.Substring($i, $len))
    }

    Write-Host ""
    Write-Host "  $border" -ForegroundColor DarkGray
    $title = $Label.ToUpper()
    $titlePad = $innerWidth - $title.Length
    if ($titlePad -lt 0) { $titlePad = 0 }
    Write-Host "  | " -ForegroundColor DarkGray -NoNewline
    Write-Host $title -ForegroundColor Cyan -NoNewline
    Write-Host ((" " * $titlePad) + " |") -ForegroundColor DarkGray
    Write-Host "  $border" -ForegroundColor DarkGray

    # Blank padding row
    Write-Host ("  | " + (" " * $innerWidth) + " |") -ForegroundColor DarkGray

    foreach ($line in $wrapped) {
        $pad = $innerWidth - $line.Length
        if ($pad -lt 0) { $pad = 0 }
        Write-Host "  | " -ForegroundColor DarkGray -NoNewline
        Write-Host $line -ForegroundColor Green -NoNewline
        Write-Host ((" " * $pad) + " |") -ForegroundColor DarkGray
    }

    Write-Host ("  | " + (" " * $innerWidth) + " |") -ForegroundColor DarkGray
    Write-Host "  $border" -ForegroundColor DarkGray

    if ($Fingerprint) {
        Write-Host "    Fingerprint : " -ForegroundColor DarkGray -NoNewline
        Write-Host $Fingerprint -ForegroundColor White
    }
    if ($Path) {
        Write-Host "    Public key  : " -ForegroundColor DarkGray -NoNewline
        Write-Host $Path -ForegroundColor White
    }

    if (-not $NoCopy) {
        if (Copy-PubKeyToClipboard -Text $key) {
            Write-Host "    [ COPY ] " -ForegroundColor Green -NoNewline
            Write-Host "Public key copied to clipboard -- paste with Ctrl+V." -ForegroundColor White
        } else {
            Write-Host "    [ WARN ] " -ForegroundColor Yellow -NoNewline
            Write-Host "Clipboard copy failed -- select the key above and copy manually." -ForegroundColor White
        }
    }
    Write-Host ""
    return $true
}
