<#
.SYNOPSIS
    os view-key -- View / read / cat SSH key files for the current user.

.DESCRIPTION
    Usage:
      .\run.ps1 os view-key [--dir <path>] [--name <pattern>]
                            [--search <pattern>] [--show-private]
                            [--public-only] [--private-only]
                            [--authorized-keys] [--known-hosts]
                            [--ledger] [--raw] [--json]

    Aliases (root): .\run.ps1 ssh view | ssh read | ssh cat

    Defaults:
      dir            = $HOME\.ssh
      shows          = directory listing + every public key + ledger summary
      private keys   = MASKED (header line + fingerprint only)
                       Pass --show-private to print the private key body.
                       The script REFUSES --show-private without an
                       interactive console to avoid leaking to logs/CI.

    Filters:
      --name <p>     Glob match on file name (e.g. id_ed25519*, *.pub)
      --search <p>   Substring/regex search inside files. Lines that
                     match are highlighted; non-matching files are
                     hidden. Works on public keys, authorized_keys,
                     known_hosts, config, AND ledger entries.
      --public-only  Only render .pub files
      --private-only Only render matching private keys (still masked
                     unless --show-private is also passed)

    Extras:
      --authorized-keys   Print ~/.ssh/authorized_keys (one entry per line,
                          with SHA256 fingerprint when ssh-keygen is on PATH)
      --known-hosts       Print ~/.ssh/known_hosts (hashed lines kept as-is)
      --ledger            Print the cross-OS ledger summary
                          (~/.lovable/ssh-keys-state.json)
      --raw               Disable masking + headers, dump file contents only
      --json              Machine-readable JSON output (suppresses colors)

    CODE RED: every file/path error logs the EXACT path + reason.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"

# ── arg parse ─────────────────────────────────────────────────────────
$sshDir       = Join-Path $HOME ".ssh"
$namePattern  = $null
$searchPattern = $null
$showPrivate  = $false
$publicOnly   = $false
$privateOnly  = $false
$showAuth     = $false
$showKnown    = $false
$showLedger   = $false
$raw          = $false
$asJson       = $false
$showHelp     = $false

$i = 0
$args = @($Rest | Where-Object { $_ })
while ($i -lt $args.Count) {
    $a = "$($args[$i])"
    switch -regex ($a.ToLower()) {
        '^(--help|-h|-help|/\?|help)$'      { $showHelp = $true }
        '^(--dir|-dir|-d)$'                 { $i++; $sshDir = "$($args[$i])" }
        '^(--name|-name|-n)$'               { $i++; $namePattern = "$($args[$i])" }
        '^(--search|-search|-s|--grep|-grep|--filter)$' { $i++; $searchPattern = "$($args[$i])" }
        '^(--show-private|-show-private|--unsafe-show-private)$' { $showPrivate = $true }
        '^(--public-only|-public-only|--pub-only|--pub)$'        { $publicOnly = $true }
        '^(--private-only|-private-only|--priv-only|--priv)$'    { $privateOnly = $true }
        '^(--authorized-keys|-authorized-keys|--authorized|--auth-keys|--auth)$' { $showAuth = $true }
        '^(--known-hosts|-known-hosts|--known)$'  { $showKnown = $true }
        '^(--ledger|-ledger|--state)$'      { $showLedger = $true }
        '^(--raw|-raw)$'                    { $raw = $true }
        '^(--json|-json)$'                  { $asJson = $true }
        default {
            # Bare positional -> treat as search pattern
            if ($null -eq $searchPattern -and -not $a.StartsWith("-")) {
                $searchPattern = $a
            } else {
                Write-Host "  [ WARN ] Unknown view-key arg: $a" -ForegroundColor Yellow
            }
        }
    }
    $i++
}

if ($showHelp) {
    Write-Host ""
    Write-Host "  os view-key -- view / read / cat SSH key files" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  USAGE:" -ForegroundColor Yellow
    Write-Host "    .\run.ps1 os view-key [flags]" -ForegroundColor White
    Write-Host "    .\run.ps1 ssh view   [flags]    (alias)" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 ssh read   [flags]    (alias)" -ForegroundColor DarkGray
    Write-Host "    .\run.ps1 ssh cat    [flags]    (alias)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  FLAGS:" -ForegroundColor Yellow
    Write-Host "    --dir <path>           Override SSH directory (default $HOME\.ssh)" -ForegroundColor DarkGray
    Write-Host "    --name <pattern>       Glob filter on file name (e.g. id_ed25519*, *.pub)" -ForegroundColor DarkGray
    Write-Host "    --search <pattern>     Substring/regex search across files + ledger" -ForegroundColor DarkGray
    Write-Host "    --show-private         Print private key bodies (requires interactive)" -ForegroundColor DarkGray
    Write-Host "    --public-only          Only show .pub files" -ForegroundColor DarkGray
    Write-Host "    --private-only         Only show matching private keys (masked)" -ForegroundColor DarkGray
    Write-Host "    --authorized-keys      Also print ~/.ssh/authorized_keys" -ForegroundColor DarkGray
    Write-Host "    --known-hosts          Also print ~/.ssh/known_hosts" -ForegroundColor DarkGray
    Write-Host "    --ledger               Also print cross-OS ledger summary" -ForegroundColor DarkGray
    Write-Host "    --raw                  Dump file contents only (no masking, no headers)" -ForegroundColor DarkGray
    Write-Host "    --json                 Machine-readable JSON output" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  EXAMPLES:" -ForegroundColor Yellow
    Write-Host "    .\run.ps1 ssh view" -ForegroundColor Green
    Write-Host "    .\run.ps1 ssh cat --name id_ed25519.pub" -ForegroundColor Green
    Write-Host "    .\run.ps1 ssh read --authorized-keys --known-hosts" -ForegroundColor Green
    Write-Host "    .\run.ps1 ssh view --show-private --name id_rsa" -ForegroundColor Green
    Write-Host "    .\run.ps1 ssh search alice@laptop          # bare positional = --search" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ── helpers ───────────────────────────────────────────────────────────
function Write-FileError {
    param([string]$Path, [string]$Reason)
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host "FILE-ERROR path='$Path' reason='$Reason'"
}

function Test-IsInteractive {
    try {
        return ($Host.Name -ne 'Default Host') -and `
               (-not [Console]::IsInputRedirected) -and `
               (-not [Console]::IsOutputRedirected)
    } catch { return $false }
}

function Copy-TextToClipboard {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    try {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value $Text -ErrorAction Stop
            return $true
        }
    } catch { }

    try {
        if (Get-Command clip.exe -ErrorAction SilentlyContinue) {
            $Text | & clip.exe
            if ($LASTEXITCODE -eq 0) {
                return $true
            }
        }
    } catch { }

    return $false
}

function Show-AndCopyPublicKeys {
    param([string[]]$Paths)

    $uniquePaths = @($Paths | Where-Object { $_ } | Select-Object -Unique)
    if ($uniquePaths.Count -eq 0) { return }

    $pubKeys = New-Object System.Collections.Generic.List[string]
    foreach ($path in $uniquePaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-FileError -Path $path -Reason "public key file not found during clipboard copy"
            continue
        }

        try {
            $text = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $pubKeys.Add($text)
            }
        } catch {
            Write-FileError -Path $path -Reason "public key read failed during clipboard copy: $($_.Exception.Message)"
        }
    }

    $uniqueKeys = @($pubKeys | Select-Object -Unique)
    if ($uniqueKeys.Count -eq 0) { return }

    Write-Host ""
    Write-Host "  [ COPY ] " -ForegroundColor Green -NoNewline
    Write-Host "Public key text" -ForegroundColor White
    Write-Host "  " ("-" * 70) -ForegroundColor DarkGray
    foreach ($key in $uniqueKeys) {
        Write-Host "  $key" -ForegroundColor Green
    }
    Write-Host "  " ("-" * 70) -ForegroundColor DarkGray

    $joined = ($uniqueKeys -join "`r`n")
    if (Copy-TextToClipboard -Text $joined) {
        Write-Host "  [OK] Public key copied to clipboard memory." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Clipboard copy failed -- copy the public key text shown above." -ForegroundColor Yellow
    }
}

function Get-KeyFingerprint {
    param([string]$Path)
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if (-not $sshKeygen) { return $null }
    try {
        $out = & $sshKeygen.Source -lf $Path 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            return ($out -join " ").Trim()
        }
    } catch { }
    return $null
}

function Test-IsPrivateKeyFile {
    param([string]$Path)
    if ($Path -match '\.pub$|^known_hosts$|^authorized_keys$|^config$') { return $false }
    try {
        $head = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
        return $head -match 'PRIVATE KEY'
    } catch { return $false }
}

function Show-FileBlock {
    param(
        [string]$Path,
        [string]$Search,
        [switch]$Mask,
        [switch]$Raw
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-FileError -Path $Path -Reason "file not found"
        return $false
    }

    $content = $null
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        Write-FileError -Path $Path -Reason "read failed: $($_.Exception.Message)"
        return $false
    }

    $lines = $content -split "`r?`n"

    # search filter
    if ($Search) {
        $matched = $lines | Where-Object { $_ -match [regex]::Escape($Search) -or $_ -match $Search }
        if (-not $matched -or $matched.Count -eq 0) { return $false }
    }

    if ($Raw) {
        Write-Output $content
        return $true
    }

    $name  = Split-Path -Leaf $Path
    $size  = (Get-Item -LiteralPath $Path).Length
    $isPriv = Test-IsPrivateKeyFile -Path $Path

    Write-Host ""
    $tag = if ($isPriv) { "[PRIVATE]" } elseif ($name -match '\.pub$') { "[PUBLIC ]" } elseif ($name -eq 'authorized_keys') { "[AUTHKEY]" } elseif ($name -eq 'known_hosts') { "[ KNOWN ]" } elseif ($name -eq 'config') { "[CONFIG ]" } else { "[ FILE  ]" }
    $tagColor = if ($isPriv) { "Red" } elseif ($name -match '\.pub$') { "Green" } else { "Cyan" }
    Write-Host "  $tag " -ForegroundColor $tagColor -NoNewline
    Write-Host "$Path " -ForegroundColor White -NoNewline
    Write-Host "($size bytes)" -ForegroundColor DarkGray

    $fp = Get-KeyFingerprint -Path $Path
    if ($fp) {
        Write-Host "          fingerprint: " -ForegroundColor DarkGray -NoNewline
        Write-Host $fp -ForegroundColor Yellow
    }

    Write-Host "  " ("-" * 70) -ForegroundColor DarkGray

    if ($isPriv -and $Mask) {
        Write-Host "  $($lines[0])" -ForegroundColor DarkYellow
        Write-Host "  *** body masked -- pass --show-private to reveal (interactive only) ***" -ForegroundColor DarkGray
        if ($lines.Count -gt 1 -and $lines[-1] -match 'PRIVATE KEY') {
            Write-Host "  $($lines[-1])" -ForegroundColor DarkYellow
        } elseif ($lines.Count -gt 2 -and $lines[-2] -match 'PRIVATE KEY') {
            Write-Host "  $($lines[-2])" -ForegroundColor DarkYellow
        }
        return $true
    }

    foreach ($ln in $lines) {
        if ($Search -and ($ln -match [regex]::Escape($Search) -or $ln -match $Search)) {
            Write-Host "  > $ln" -ForegroundColor Yellow
        } else {
            $color = if ($isPriv) { "DarkYellow" } elseif ($name -match '\.pub$') { "Green" } else { "Gray" }
            Write-Host "  $ln" -ForegroundColor $color
        }
    }
    return $true
}

function Show-LedgerBlock {
    param([string]$Search)
    $ledger = Join-Path $env:USERPROFILE ".lovable\ssh-keys-state.json"
    if (-not (Test-Path -LiteralPath $ledger)) {
        Write-Host ""
        Write-Host "  [LEDGER ] " -ForegroundColor Magenta -NoNewline
        Write-Host "$ledger (no ledger yet -- run 'ssh gen' or 'ssh install' first)" -ForegroundColor DarkGray
        return
    }
    try {
        $obj = Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-FileError -Path $ledger -Reason "ledger read/parse failed: $($_.Exception.Message)"
        return
    }
    Write-Host ""
    Write-Host "  [LEDGER ] " -ForegroundColor Magenta -NoNewline
    Write-Host "$ledger " -ForegroundColor White -NoNewline
    Write-Host "(host=$($obj.host) user=$($obj.user) entries=$($obj.entries.Count))" -ForegroundColor DarkGray
    Write-Host "  " ("-" * 70) -ForegroundColor DarkGray

    $entries = @($obj.entries)
    if ($Search) {
        $entries = $entries | Where-Object {
            "$($_.fingerprint) $($_.keyPath) $($_.comment) $($_.action) $($_.source)" -match [regex]::Escape($Search)
        }
    }
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host "  (no matching entries)" -ForegroundColor DarkGray
        return
    }
    foreach ($e in $entries) {
        $color = switch ("$($e.action)".ToLower()) {
            'generate' { 'Green' }
            'install'  { 'Cyan' }
            'revoke'   { 'Red' }
            default    { 'Gray' }
        }
        Write-Host ("  {0,-20} {1,-9} " -f $e.ts, $e.action) -ForegroundColor $color -NoNewline
        Write-Host "$($e.fingerprint)" -ForegroundColor Yellow
        if ($e.keyPath)  { Write-Host "                       path: $($e.keyPath)" -ForegroundColor DarkGray }
        if ($e.comment)  { Write-Host "                       comment: $($e.comment)" -ForegroundColor DarkGray }
    }
}

# ── main ──────────────────────────────────────────────────────────────
if ($showPrivate -and -not (Test-IsInteractive)) {
    Write-Host "  [ FAIL ] " -ForegroundColor Red -NoNewline
    Write-Host "--show-private refused: non-interactive session (stdout/stdin redirected)."
    Write-Host "          Run again from a real terminal, or remove --show-private." -ForegroundColor DarkGray
    exit 2
}

if (-not (Test-Path -LiteralPath $sshDir)) {
    Write-FileError -Path $sshDir -Reason "SSH directory does not exist (run 'ssh gen' to create your first key)"
    exit 1
}

# Resolve file list
$allFiles = @()
try {
    $allFiles = Get-ChildItem -LiteralPath $sshDir -File -Force -ErrorAction Stop
} catch {
    Write-FileError -Path $sshDir -Reason "directory listing failed: $($_.Exception.Message)"
    exit 1
}

$candidates = $allFiles
if ($namePattern) {
    $candidates = $candidates | Where-Object { $_.Name -like $namePattern }
}
if ($publicOnly)  { $candidates = $candidates | Where-Object { $_.Name -like '*.pub' } }
if ($privateOnly) { $candidates = $candidates | Where-Object { $_.Name -notlike '*.pub' -and $_.Name -ne 'authorized_keys' -and $_.Name -ne 'known_hosts' -and $_.Name -ne 'config' } }

# JSON mode
if ($asJson) {
    $result = [ordered]@{
        sshDir   = $sshDir
        files    = @()
        ledger   = $null
    }
    foreach ($f in $candidates) {
        $fp = Get-KeyFingerprint -Path $f.FullName
        $isPriv = Test-IsPrivateKeyFile -Path $f.FullName
        $entry = [ordered]@{
            name        = $f.Name
            path        = $f.FullName
            size        = $f.Length
            type        = if ($isPriv) { 'private' } elseif ($f.Name -like '*.pub') { 'public' } else { $f.Name }
            fingerprint = $fp
        }
        $result.files += $entry
    }
    $ledgerPath = Join-Path $env:USERPROFILE ".lovable\ssh-keys-state.json"
    if (Test-Path -LiteralPath $ledgerPath) {
        try { $result.ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json } catch { }
    }
    $result | ConvertTo-Json -Depth 8
    exit 0
}

# Header + directory summary
Write-Host ""
Write-Host "  SSH KEY VIEWER" -ForegroundColor Cyan
Write-Host "  ==============" -ForegroundColor DarkGray
Write-Host "  Directory : " -ForegroundColor DarkGray -NoNewline; Write-Host $sshDir -ForegroundColor White
Write-Host "  Files     : " -ForegroundColor DarkGray -NoNewline; Write-Host "$($candidates.Count) of $($allFiles.Count) (after filters)" -ForegroundColor White
if ($namePattern)   { Write-Host "  --name    : " -ForegroundColor DarkGray -NoNewline; Write-Host $namePattern -ForegroundColor Yellow }
if ($searchPattern) { Write-Host "  --search  : " -ForegroundColor DarkGray -NoNewline; Write-Host $searchPattern -ForegroundColor Yellow }
if ($showPrivate)   { Write-Host "  --show-private : " -ForegroundColor DarkGray -NoNewline; Write-Host "ENABLED (private bodies will be printed)" -ForegroundColor Red }

# Sort: public first, then private, then auth/known/config
$ordered = @()
$ordered += $candidates | Where-Object { $_.Name -like '*.pub' } | Sort-Object Name
$ordered += $candidates | Where-Object { $_.Name -notlike '*.pub' -and $_.Name -notin @('authorized_keys','known_hosts','config') } | Sort-Object Name
$ordered += $candidates | Where-Object { $_.Name -in @('authorized_keys','known_hosts','config') } | Sort-Object Name

$shown = 0
foreach ($f in $ordered) {
    if (Show-FileBlock -Path $f.FullName -Search $searchPattern -Mask:(-not $showPrivate) -Raw:$raw) {
        $shown++
    }
}

# Optional extras (idempotent: skip if already in the listing above)
if ($showAuth) {
    $p = Join-Path $sshDir "authorized_keys"
    if ($ordered.FullName -notcontains $p) {
        if (Show-FileBlock -Path $p -Search $searchPattern -Mask:(-not $showPrivate) -Raw:$raw) { $shown++ }
    }
}
if ($showKnown) {
    $p = Join-Path $sshDir "known_hosts"
    if ($ordered.FullName -notcontains $p) {
        if (Show-FileBlock -Path $p -Search $searchPattern -Mask:(-not $showPrivate) -Raw:$raw) { $shown++ }
    }
}
if ($showLedger -or $searchPattern) {
    Show-LedgerBlock -Search $searchPattern
}

Write-Host ""
if ($shown -eq 0 -and $searchPattern) {
    Write-Host "  [ INFO ] " -ForegroundColor Cyan -NoNewline
    Write-Host "No file matched search '$searchPattern' in $sshDir" -ForegroundColor DarkGray
    Write-Host "          Try --ledger to also search the cross-OS ledger." -ForegroundColor DarkGray
} else {
    Write-Host "  [ DONE ] " -ForegroundColor Green -NoNewline
    Write-Host "$shown file(s) shown from $sshDir" -ForegroundColor White
}
exit 0
