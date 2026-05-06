# --------------------------------------------------------------------------
#  Installation tracking helpers
#  Tracks installed tool versions in .installed/ at project root.
#  Auto-loaded by logging.ps1 -- no manual sourcing needed.
# --------------------------------------------------------------------------

function Get-InstalledDir {
    <#
    .SYNOPSIS
        Returns the path to the .installed/ directory at the project root.
        Creates it if it does not exist. Works regardless of sourcing context.
    #>
    # $PSScriptRoot inside this file is always scripts/shared/
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $dir = Join-Path $projectRoot ".installed"

    $isDirMissing = -not (Test-Path $dir)
    if ($isDirMissing) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    return $dir
}

function Get-InstalledRecord {
    <#
    .SYNOPSIS
        Reads the .installed/<name>.json tracking file for a tool.
        Returns $null if no record exists.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $installedDir = Get-InstalledDir
    $filePath = Join-Path $installedDir "$Name.json"
    $isFileMissing = -not (Test-Path $filePath)
    if ($isFileMissing) { return $null }

    return Get-Content $filePath -Raw | ConvertFrom-Json
}

function Test-AlreadyInstalled {
    <#
    .SYNOPSIS
        Returns $true if the tool was previously installed at exactly this version
        and had no errors. If the previous attempt had an error, logs a friendly
        message about the prior failure and returns $false so it retries.

        On a positive match this also bumps 'lastChecked' in the record so the
        JSON reflects the most recent verification time without rewriting the
        installedAt timestamp.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$CurrentVersion
    )

    $record = Get-InstalledRecord -Name $Name
    $hasNoRecord = -not $record
    if ($hasNoRecord) { return $false }

    # If previous run had an error, show friendly message and retry
    $hasPreviousError = $record.lastError -and ($record.lastError -ne "")
    if ($hasPreviousError) {
        Write-Log "Previous install of '$Name' had an error: $($record.lastError)" -Level "warn"
        Write-Log "Let's try again..." -Level "info"
        return $false
    }

    $isVersionMatch = $record.version -eq $CurrentVersion
    if ($isVersionMatch) {
        Update-InstalledLastChecked -Name $Name
    }
    return $isVersionMatch
}

function Update-InstalledLastChecked {
    <#
    .SYNOPSIS
        Bumps 'lastChecked' (and ensures status='installed') in an existing
        .installed/<name>.json record. Silent if the record is missing.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $record = Get-InstalledRecord -Name $Name
    if (-not $record) { return }

    $data = @{
        name         = $record.name
        version      = $record.version
        status       = "installed"
        method       = if ($record.PSObject.Properties.Name -contains 'method')      { $record.method }      else { "chocolatey" }
        installedAt  = if ($record.PSObject.Properties.Name -contains 'installedAt') { $record.installedAt } else { (Get-Date -Format "o") }
        lastChecked  = (Get-Date -Format "o")
        installedBy  = if ($record.PSObject.Properties.Name -contains 'installedBy') { $record.installedBy } else { $env:USERNAME }
        lastError    = ""
        errorAt      = ""
    }

    $installedDir = Get-InstalledDir
    $filePath = Join-Path $installedDir "$Name.json"
    $data | ConvertTo-Json -Depth 3 | Set-Content -Path $filePath -Encoding UTF8
}

function Save-InstalledRecord {
    <#
    .SYNOPSIS
        Writes a tracking file to .installed/<name>.json after successful installation.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Version,

        [string]$Method = "chocolatey"
    )

    # Guard against empty version
    $isVersionEmpty = [string]::IsNullOrWhiteSpace($Version)
    if ($isVersionEmpty) {
        Write-Log "Warning: empty version for '$Name' -- recording as 'unknown'" -Level "warn"
        $Version = "unknown"
    }

    $installedDir = Get-InstalledDir

    $data = @{
        name         = $Name
        version      = $Version
        status       = "installed"
        method       = $Method
        installedAt  = (Get-Date -Format "o")
        lastChecked  = (Get-Date -Format "o")
        installedBy  = $env:USERNAME
        lastError    = ""
        errorAt      = ""
    }

    $filePath = Join-Path $installedDir "$Name.json"
    $data | ConvertTo-Json -Depth 3 | Set-Content -Path $filePath -Encoding UTF8

    Write-Log "Saved install record: .installed/$Name.json (status=installed, version=$Version)" -Level "info"
}

function Save-InstalledError {
    <#
    .SYNOPSIS
        Records an error in .installed/<name>.json so the next run knows
        what went wrong and can retry with a friendly message.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ErrorMessage,

        [string]$Version = "unknown",

        [string]$Method = "chocolatey"
    )

    $installedDir = Get-InstalledDir

    # Merge with existing record if present
    $existing = Get-InstalledRecord -Name $Name
    $hasExisting = $null -ne $existing

    $data = @{
        name        = $Name
        version     = if ($hasExisting -and $existing.version) { $existing.version } else { $Version }
        method      = if ($hasExisting -and $existing.method)  { $existing.method }  else { $Method }
        installedAt = if ($hasExisting -and $existing.installedAt) { $existing.installedAt } else { (Get-Date -Format "o") }
        installedBy = if ($hasExisting -and $existing.installedBy) { $existing.installedBy } else { $env:USERNAME }
        lastError   = $ErrorMessage
        errorAt     = (Get-Date -Format "o")
    }

    $filePath = Join-Path $installedDir "$Name.json"
    $data | ConvertTo-Json -Depth 3 | Set-Content -Path $filePath -Encoding UTF8

    Write-Log "Recorded error for '$Name': $ErrorMessage" -Level "warn"
}

function Remove-InstalledRecord {
    <#
    .SYNOPSIS
        Deletes the .installed/<name>.json tracking file for a tool.
        Returns $true if removed, $false if file did not exist.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $installedDir = Get-InstalledDir
    $filePath = Join-Path $installedDir "$Name.json"
    $isFilePresent = Test-Path $filePath
    if ($isFilePresent) {
        Remove-Item -Path $filePath -Force
        Write-Log "Removed install record: .installed/$Name.json" -Level "info"
        return $true
    }

    Write-Log "No install record found for '$Name' -- nothing to remove" -Level "info"
    return $false
}
