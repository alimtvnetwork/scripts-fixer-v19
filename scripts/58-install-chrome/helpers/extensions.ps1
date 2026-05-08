# --------------------------------------------------------------------------
#  Helper: Install Chrome extensions
#
#  Two methods (Chrome blocks silent .crx installs from outside the Web Store):
#    1. registry  -- write HKLM\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist
#                    Auto-installs on next Chrome launch. SILENT. Requires admin.
#    2. webstore  -- launch each extension's Chrome Web Store URL.
#                    User clicks "Add to Chrome". No admin needed.
#    auto         -- registry if elevated, else webstore.
# --------------------------------------------------------------------------

$_extSharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
if ((Test-Path (Join-Path $_extSharedDir "logging.ps1")) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . (Join-Path $_extSharedDir "logging.ps1")
}
if (Test-Path (Join-Path $_extSharedDir "admin-check.ps1")) {
    . (Join-Path $_extSharedDir "admin-check.ps1")
}

function Resolve-ChromeExtensions {
    <#
    .SYNOPSIS
        Resolves a CSV/array of extension names to catalog entries.
        Pass "all" to return every extension. Unknown names are reported
        and skipped.
    #>
    param(
        [Parameter(Mandatory)] [PSObject]$ExtConfig,
        [Parameter()] [string[]]$Names
    )

    $catalog = $ExtConfig.list
    if (-not $Names -or $Names.Count -eq 0 -or ($Names -contains "all") -or ($Names -contains "*")) {
        return $catalog
    }

    $matched = @()
    foreach ($n in $Names) {
        $needle = $n.Trim().ToLower()
        if (-not $needle) { continue }
        $hit = $catalog | Where-Object {
            $_.name.ToLower() -eq $needle -or
            $_.id.ToLower() -eq $needle -or
            $_.displayName.ToLower() -like "*$needle*"
        } | Select-Object -First 1
        if ($hit) {
            $matched += $hit
        } else {
            Write-Log "Unknown Chrome extension: '$n'  (use 'ext list' to see catalog)" -Level "warn"
        }
    }
    return $matched
}

function Resolve-ChromeExtensionsFromUrls {
    <#
    .SYNOPSIS
        Parses one or many Chrome Web Store URLs and returns synthetic catalog
        entries (name/displayName/id/url) suitable for the registry/web-store
        installers. Accepts either:
          * .../detail/<slug>/<id>           (modern URL)
          * .../detail/<id>                  (id-only URL)
          * a bare 32-char extension id      (no URL)
        Invalid entries are logged and skipped. Duplicates (by id) are de-duped.
    #>
    param([Parameter(Mandatory)] [string[]]$Urls)

    $idPattern = '([a-p]{32})'
    $seen = @{}
    $result = @()

    foreach ($raw in $Urls) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $u = $raw.Trim().Trim('"').Trim("'")

        # Strip query/fragment
        $clean = ($u -split '[?#]')[0].TrimEnd('/')

        $id = $null
        $slug = $null

        if ($clean -match "/detail/([^/]+)/$idPattern$") {
            $slug = $Matches[1]
            $id   = $Matches[2]
        } elseif ($clean -match "/detail/$idPattern$") {
            $id = $Matches[1]
        } elseif ($clean -match "^$idPattern$") {
            $id = $Matches[1]
        }

        if (-not $id) {
            Write-Log "Could not extract Chrome extension id from URL: '$raw'  (expected .../detail/<slug>/<32-char-id> or a bare id)" -Level "warn"
            continue
        }

        if ($seen.ContainsKey($id)) {
            Write-Log "Duplicate extension id skipped: $id" -Level "info"
            continue
        }
        $seen[$id] = $true

        $name = if ($slug) { ($slug -replace '[^a-z0-9]+','-').Trim('-').ToLower() } else { $id.Substring(0,8) }
        $display = if ($slug) { (Get-Culture).TextInfo.ToTitleCase(($slug -replace '-',' ').ToLower()) } else { "Chrome extension $id" }
        $canonicalUrl = "https://chromewebstore.google.com/detail/$id"

        $result += [PSCustomObject]@{
            name        = $name
            displayName = $display
            id          = $id
            url         = $canonicalUrl
        }
    }
    return $result
}

function Test-ChromeExtensionUrls {
    <#
    .SYNOPSIS
        Pre-flight check on user-supplied extension URLs. Catches duplicates
        and copy-paste mistakes BEFORE anything is installed.

        Returns a PSCustomObject:
          {
            Issues       = @( @{ Severity='warn'|'error'; Code='...'; Message='...'; Url='...' } )
            HasErrors    = $true/$false   # at least one URL cannot be installed
            HasWarnings  = $true/$false   # something looks fishy but installable
            ParsedCount  = <int>          # unique installable extensions
            InputCount   = <int>          # raw URLs received
          }

        Detected problems:
          E1  invalid-url          - URL/string did not contain a 32-char id
          E2  not-webstore         - URL host is not chrome(webstore).google.com
          W1  duplicate-url        - same raw URL string appears more than once
          W2  duplicate-id         - same extension id appears under different
                                     URLs (catches "I copy-pasted the wrong slug")
          W3  slug-mismatch        - slug in URL does not match the canonical
                                     id-only Web Store path (possible typo)
          W4  query-or-fragment    - URL had ?utm_... / #section that we stripped
    #>
    param([Parameter(Mandatory)] [string[]]$Urls)

    $idPattern = '([a-p]{32})'
    $issues    = New-Object System.Collections.Generic.List[object]
    $byUrl     = @{}
    $byId      = @{}
    $unique    = @{}

    foreach ($raw in $Urls) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $u = $raw.Trim().Trim('"').Trim("'")

        # W1 -- exact duplicate URL string
        $keyUrl = $u.ToLower()
        if ($byUrl.ContainsKey($keyUrl)) {
            $issues.Add([pscustomobject]@{ Severity='warn'; Code='duplicate-url'; Url=$u; Message="Duplicate URL (already in list)" })
            continue
        }
        $byUrl[$keyUrl] = $true

        # W4 -- query/fragment present (often a paste from sidebar)
        if ($u -match '[?#]') {
            $issues.Add([pscustomobject]@{ Severity='warn'; Code='query-or-fragment'; Url=$u; Message="URL had ?query or #fragment (stripped before install)" })
        }

        $clean = ($u -split '[?#]')[0].TrimEnd('/')

        # E2 -- host check (skip for bare ids)
        $isBareId = $clean -match "^$idPattern$"
        if (-not $isBareId -and $clean -match '^https?://([^/]+)') {
            $urlHost = $Matches[1].ToLower()
            $isWebStore = $urlHost -in @("chromewebstore.google.com","chrome.google.com")
            if (-not $isWebStore) {
                $issues.Add([pscustomobject]@{ Severity='error'; Code='not-webstore'; Url=$u; Message="Host '$urlHost' is not a Chrome Web Store domain" })
                continue
            }
        }

        $id = $null; $slug = $null
        if ($clean -match "/detail/([^/]+)/$idPattern$") {
            $slug = $Matches[1]; $id = $Matches[2]
        } elseif ($clean -match "/detail/$idPattern$") {
            $id = $Matches[1]
        } elseif ($isBareId) {
            $id = $Matches[1]
        }

        # E1 -- could not extract a valid id
        if (-not $id) {
            $issues.Add([pscustomobject]@{ Severity='error'; Code='invalid-url'; Url=$u; Message="No 32-char extension id found" })
            continue
        }

        # W2 -- same id, different URL (very common copy-paste mistake)
        if ($byId.ContainsKey($id)) {
            $prev = $byId[$id]
            $issues.Add([pscustomobject]@{
                Severity='warn'; Code='duplicate-id'; Url=$u;
                Message="Same extension id as earlier URL  (id=$id, also at: $prev)"
            })
            continue
        }
        $byId[$id] = $u

        # W3 -- slug looks wrong (contains "vpn" but id maps to a different ext, etc.)
        # Heuristic: slug should be lowercase letters/digits/dashes only.
        if ($slug -and $slug -notmatch '^[a-z0-9][a-z0-9\-]*$') {
            $issues.Add([pscustomobject]@{
                Severity='warn'; Code='slug-mismatch'; Url=$u;
                Message="Slug '$slug' has unexpected characters -- check for typos"
            })
        }

        $unique[$id] = $true
    }

    $hasErrors   = @($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0
    $hasWarnings = @($issues | Where-Object { $_.Severity -eq 'warn'  }).Count -gt 0

    return [pscustomobject]@{
        Issues       = $issues
        HasErrors    = $hasErrors
        HasWarnings  = $hasWarnings
        ParsedCount  = $unique.Count
        InputCount   = @($Urls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    }
}

function Show-ChromeExtensionUrlReport {
    param([Parameter(Mandatory)] [PSObject]$Report)

    Write-Host ""
    Write-Host "  Chrome extension URL pre-flight check" -ForegroundColor Yellow
    Write-Host ("    Input URLs   : {0}" -f $Report.InputCount)   -ForegroundColor White
    Write-Host ("    Will install : {0}" -f $Report.ParsedCount)  -ForegroundColor White
    Write-Host ("    Warnings     : {0}" -f @($Report.Issues | Where-Object { $_.Severity -eq 'warn'  }).Count) -ForegroundColor Yellow
    Write-Host ("    Errors       : {0}" -f @($Report.Issues | Where-Object { $_.Severity -eq 'error' }).Count) -ForegroundColor Red

    if ($Report.Issues.Count -gt 0) {
        Write-Host ""
        foreach ($i in $Report.Issues) {
            $tag    = if ($i.Severity -eq 'error') { "[XX]" } else { "[!!]" }
            $color  = if ($i.Severity -eq 'error') { "Red" } else { "Yellow" }
            Write-Host ("    {0} {1,-18} {2}" -f $tag, $i.Code, $i.Message) -ForegroundColor $color
            Write-Host ("         url: {0}" -f $i.Url) -ForegroundColor DarkGray
        }
    } else {
        Write-Host "    [OK] No issues detected." -ForegroundColor Green
    }
    Write-Host ""
}
function Show-ChromeExtensionCatalog {
    param([Parameter(Mandatory)] [PSObject]$ExtConfig)
    Write-Host ""
    Write-Host "  Chrome extension catalog:" -ForegroundColor Yellow
    Write-Host ""
    $i = 0
    foreach ($e in $ExtConfig.list) {
        $i++
        Write-Host ("    [{0}] {1,-12} {2}" -f $i, $e.name, $e.displayName) -ForegroundColor White
        Write-Host ("         id: {0}" -f $e.id) -ForegroundColor DarkGray
        Write-Host ("         {0}" -f $e.url) -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Install all:    .\run.ps1 install chrome ext-all" -ForegroundColor DarkGray
    Write-Host "  Install one:    .\run.ps1 install chrome ext vpn" -ForegroundColor DarkGray
    Write-Host "  Chrome+all ext: .\run.ps1 install chrome with-ext" -ForegroundColor DarkGray
    Write-Host ""
}

function Install-ChromeExtensionsByRegistry {
    <#
    .SYNOPSIS
        Writes HKLM ExtensionInstallForcelist entries for each extension.
        Returns count of entries written.
    #>
    param(
        [Parameter(Mandatory)] [array]$Extensions,
        [Parameter(Mandatory)] [PSObject]$ExtConfig
    )

    $regRoot   = $ExtConfig.registryRoot
    $updateUrl = $ExtConfig.updateUrl

    if (-not (Test-Path $regRoot)) {
        try {
            New-Item -Path $regRoot -Force | Out-Null
            Write-Log "Created policy key: $regRoot" -Level "info"
        } catch {
            Write-Log "Failed to create registry key '$regRoot' -- $_" -Level "error"
            return 0
        }
    }

    # Find next free slot to avoid overwriting other policies
    $existingValues = @()
    try {
        $existingValues = (Get-Item $regRoot -ErrorAction Stop).Property
    } catch {}

    $nextSlot = 1
    while ($existingValues -contains "$nextSlot") { $nextSlot++ }

    $written = 0
    foreach ($e in $Extensions) {
        $value = "{0};{1}" -f $e.id, $updateUrl

        # If this extension is already in the forcelist, skip
        $alreadyPresent = $false
        foreach ($p in $existingValues) {
            try {
                $cur = (Get-ItemProperty -Path $regRoot -Name $p -ErrorAction Stop).$p
                if ($cur -like "$($e.id);*") { $alreadyPresent = $true; break }
            } catch {}
        }
        if ($alreadyPresent) {
            Write-Log "Already force-listed: $($e.displayName) [$($e.id)]" -Level "info"
            continue
        }

        try {
            New-ItemProperty -Path $regRoot -Name "$nextSlot" -Value $value -PropertyType String -Force | Out-Null
            Write-Log "Force-listed: $($e.displayName) [$($e.id)]  slot=$nextSlot" -Level "success"
            $written++
            $nextSlot++
        } catch {
            Write-Log "Failed to write registry slot $nextSlot for '$($e.displayName)': $_" -Level "error"
        }
    }

    if ($written -gt 0) {
        Write-Host ""
        Write-Host "  $written extension(s) force-listed via Chrome policy." -ForegroundColor Green
        Write-Host "  They will auto-install the next time Chrome starts." -ForegroundColor DarkGray
        Write-Host "  Verify in Chrome:  chrome://policy   then  chrome://extensions" -ForegroundColor DarkGray
        Write-Host ""
    }

    return $written
}

function Install-ChromeExtensionsByWebStore {
    param([Parameter(Mandatory)] [array]$Extensions)

    foreach ($e in $Extensions) {
        Write-Log "Opening Web Store page for '$($e.displayName)'..." -Level "info"
        try {
            Start-Process $e.url | Out-Null
        } catch {
            Write-Log "Failed to open URL '$($e.url)' -- $_" -Level "error"
        }
    }
    Write-Host ""
    Write-Host "  Opened $($Extensions.Count) Web Store page(s)." -ForegroundColor Yellow
    Write-Host "  Click 'Add to Chrome' on each tab to complete installation." -ForegroundColor DarkGray
    Write-Host ""
    return $Extensions.Count
}

function Install-ChromeExtensions {
    <#
    .SYNOPSIS
        High-level entry point. -Method 'auto' picks registry when elevated,
        Web Store otherwise.
    #>
    param(
        [Parameter(Mandatory)] [PSObject]$ExtConfig,
        [Parameter()] [string[]]$Names = @("all"),
        [ValidateSet("auto","registry","webstore")] [string]$Method = "auto"
    )

    $picked = Resolve-ChromeExtensions -ExtConfig $ExtConfig -Names $Names
    if (-not $picked -or $picked.Count -eq 0) {
        Write-Log "No matching Chrome extensions to install." -Level "warn"
        return 0
    }

    Write-Log "Selected extensions: $((($picked | ForEach-Object { $_.name }) -join ', '))" -Level "info"

    $effective = $Method
    if ($effective -eq "auto") {
        $isElevated = $false
        if (Get-Command Test-IsElevated -ErrorAction SilentlyContinue) {
            try { $isElevated = Test-IsElevated } catch {}
        }
        $effective = if ($isElevated) { "registry" } else { "webstore" }
        Write-Log "Auto-selected install method: $effective (elevated=$isElevated)" -Level "info"
    }

    if ($effective -eq "registry") {
        return Install-ChromeExtensionsByRegistry -Extensions $picked -ExtConfig $ExtConfig
    } else {
        return Install-ChromeExtensionsByWebStore -Extensions $picked
    }
}
