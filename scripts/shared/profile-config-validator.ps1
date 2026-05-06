<#
.SYNOPSIS
    Schema validators for scripts/profile/config.json and
    scripts/profile/profile-aliases.json.

    Each function returns a hashtable:
        @{
            IsValid    = [bool]   # true when zero errors
            FilePath   = [string] # absolute path of the validated file
            Errors     = @()      # blocking issues (file missing, JSON parse fail,
                                  #   missing required field, wrong type, ...)
            Warnings   = @()      # non-blocking issues (unknown alias target,
                                  #   empty description, duplicate ids, ...)
            ProfileNames = @()    # parsed profile names (config validator only)
        }

    The helper Format-ProfileConfigIssues prints a human-friendly,
    color-coded report suitable for embedding inside --help / 'profile list'.
    Every error line includes the exact file path + reason (CODE RED rule).
#>

function Test-ProfileConfig {
    <#
    .SYNOPSIS
        Validates scripts/profile/config.json. Schema:
          {
            "profiles": {
              "<name>": {
                 "label":       "string (recommended)",
                 "description": "string (recommended)",
                 "steps": [
                   { "kind": "script|choco|subcommand|inline|profile", ... }
                 ]
              }, ...
            },
            "modeEnvVars": { "<scriptId>": "ENV_VAR_NAME", ... }   // optional
          }
    #>
    param([Parameter(Mandatory)][string]$FilePath)

    $result = @{
        IsValid      = $false
        FilePath     = $FilePath
        Errors       = @()
        Warnings     = @()
        ProfileNames = @()
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        $result.Errors += "Profile config not found at: $FilePath -- expected file does not exist on disk."
        return $result
    }

    $cfg = $null
    try {
        $raw = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $result.Errors += "Profile config is empty: $FilePath -- file has zero bytes of content."
            return $result
        }
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.Errors += "Failed to parse profile config: $FilePath -- $($_.Exception.Message)"
        return $result
    }

    if (-not $cfg.PSObject.Properties.Name -contains 'profiles' -or $null -eq $cfg.profiles) {
        $result.Errors += "Profile config missing required 'profiles' object: $FilePath -- top-level 'profiles' key is absent or null."
        return $result
    }

    $validKinds   = @('script', 'choco', 'subcommand', 'inline', 'profile')
    $profileNames = @($cfg.profiles.PSObject.Properties.Name)
    $result.ProfileNames = $profileNames

    if ($profileNames.Count -eq 0) {
        $result.Errors += "Profile config has empty 'profiles' object: $FilePath -- no profile recipes defined."
        return $result
    }

    foreach ($pname in $profileNames) {
        $pdef = $cfg.profiles.$pname

        if ($null -eq $pdef) {
            $result.Errors += "Profile '$pname' is null in: $FilePath -- entry has no body."
            continue
        }

        $hasLabel = $pdef.PSObject.Properties.Name -contains 'label' -and -not [string]::IsNullOrWhiteSpace([string]$pdef.label)
        $hasDesc  = $pdef.PSObject.Properties.Name -contains 'description' -and -not [string]::IsNullOrWhiteSpace([string]$pdef.description)
        if (-not $hasLabel) { $result.Warnings += "Profile '$pname' has no 'label' (used as fallback description) in: $FilePath" }
        if (-not $hasDesc)  { $result.Warnings += "Profile '$pname' has no 'description' (--help will fall back to label) in: $FilePath" }

        $hasStepsKey = $pdef.PSObject.Properties.Name -contains 'steps'
        if (-not $hasStepsKey) {
            $result.Errors += "Profile '$pname' missing required 'steps' array in: $FilePath -- key not present."
            continue
        }
        $steps = @($pdef.steps)
        if ($steps.Count -eq 0) {
            $result.Errors += "Profile '$pname' has empty 'steps' array in: $FilePath -- profile would do nothing if executed."
            continue
        }

        for ($i = 0; $i -lt $steps.Count; $i++) {
            $s = $steps[$i]
            $idx = $i + 1
            if ($null -eq $s) {
                $result.Errors += "Profile '$pname' step #$idx is null in: $FilePath"
                continue
            }
            $kind = "$($s.kind)".ToLower()
            if ([string]::IsNullOrWhiteSpace($kind)) {
                $result.Errors += "Profile '$pname' step #$idx missing 'kind' in: $FilePath"
                continue
            }
            if ($kind -notin $validKinds) {
                $result.Errors += "Profile '$pname' step #$idx has unknown kind '$kind' in: $FilePath -- valid: $($validKinds -join ', ')"
                continue
            }
            switch ($kind) {
                'script' {
                    $hasId = $s.PSObject.Properties.Name -contains 'id'
                    if (-not $hasId) {
                        $result.Errors += "Profile '$pname' step #$idx (script) missing 'id' in: $FilePath"
                    } else {
                        $idVal = 0
                        $isNumeric = [int]::TryParse("$($s.id)", [ref]$idVal)
                        if (-not $isNumeric -or $idVal -lt 1) {
                            $result.Errors += "Profile '$pname' step #$idx (script) has invalid id '$($s.id)' in: $FilePath -- must be a positive integer."
                        }
                    }
                }
                'choco' {
                    if ([string]::IsNullOrWhiteSpace([string]$s.package)) {
                        $result.Errors += "Profile '$pname' step #$idx (choco) missing 'package' in: $FilePath"
                    }
                }
                'subcommand' {
                    if ([string]::IsNullOrWhiteSpace([string]$s.path)) {
                        $result.Errors += "Profile '$pname' step #$idx (subcommand) missing 'path' (e.g. 'os hib-off') in: $FilePath"
                    }
                }
                'inline' {
                    if ([string]::IsNullOrWhiteSpace([string]$s.function)) {
                        $result.Errors += "Profile '$pname' step #$idx (inline) missing 'function' name in: $FilePath"
                    }
                }
                'profile' {
                    $tgt = "$($s.name)"
                    if ([string]::IsNullOrWhiteSpace($tgt)) {
                        $result.Errors += "Profile '$pname' step #$idx (profile) missing 'name' (target profile) in: $FilePath"
                    } elseif ($tgt -notin $profileNames) {
                        $result.Errors += "Profile '$pname' step #$idx references unknown profile '$tgt' in: $FilePath -- not defined under 'profiles'."
                    } elseif ($tgt -eq $pname) {
                        $result.Errors += "Profile '$pname' step #$idx references itself in: $FilePath -- direct self-recursion is not allowed."
                    }
                }
            }
        }
    }

    # Optional modeEnvVars sanity check
    if ($cfg.PSObject.Properties.Name -contains 'modeEnvVars' -and $null -ne $cfg.modeEnvVars) {
        foreach ($k in $cfg.modeEnvVars.PSObject.Properties.Name) {
            $idVal = 0
            if (-not [int]::TryParse($k, [ref]$idVal)) {
                $result.Warnings += "modeEnvVars key '$k' is not a numeric script id in: $FilePath"
            }
            if ([string]::IsNullOrWhiteSpace([string]$cfg.modeEnvVars.$k)) {
                $result.Warnings += "modeEnvVars['$k'] has empty env-var name in: $FilePath"
            }
        }
    }

    $result.IsValid = ($result.Errors.Count -eq 0)
    return $result
}

function Test-ProfileAliasesConfig {
    <#
    .SYNOPSIS
        Validates scripts/profile/profile-aliases.json. Schema:
          {
            "aliases": {
              "<aliasName>": {
                "kind":   "exact" | "fallback",
                "target": "<existingProfileName>",
                "reason": "string (required for kind=fallback)"
              }, ...
            }
          }
        $KnownProfileNames is used to flag aliases that point at non-existent
        profiles. Pass an empty array to skip that check.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$KnownProfileNames = @()
    )

    $result = @{
        IsValid     = $false
        FilePath    = $FilePath
        Errors      = @()
        Warnings    = @()
        AliasNames  = @()
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        # Aliases file is optional -- treat missing as a soft warning, not an error.
        $result.Warnings += "Profile aliases file not present at: $FilePath -- alias resolution will be skipped (this is OK if you don't use aliases)."
        $result.IsValid = $true
        return $result
    }

    $cfg = $null
    try {
        $raw = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $result.Errors += "Profile aliases file is empty: $FilePath -- file has zero bytes of content."
            return $result
        }
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.Errors += "Failed to parse profile aliases: $FilePath -- $($_.Exception.Message)"
        return $result
    }

    if (-not ($cfg.PSObject.Properties.Name -contains 'aliases') -or $null -eq $cfg.aliases) {
        $result.Errors += "Aliases file missing required 'aliases' object: $FilePath -- top-level 'aliases' key is absent or null."
        return $result
    }

    $validKinds = @('exact', 'fallback')
    $aliasNames = @($cfg.aliases.PSObject.Properties.Name)
    $result.AliasNames = $aliasNames
    $hasKnownProfiles = $KnownProfileNames -and $KnownProfileNames.Count -gt 0

    foreach ($aname in $aliasNames) {
        $adef = $cfg.aliases.$aname
        if ($null -eq $adef) {
            $result.Errors += "Alias '$aname' is null in: $FilePath -- entry has no body."
            continue
        }
        $kind = "$($adef.kind)".ToLower()
        $tgt  = "$($adef.target)"
        if ([string]::IsNullOrWhiteSpace($kind)) {
            $result.Errors += "Alias '$aname' missing 'kind' in: $FilePath -- expected one of: $($validKinds -join ', ')"
        } elseif ($kind -notin $validKinds) {
            $result.Errors += "Alias '$aname' has unknown kind '$kind' in: $FilePath -- valid: $($validKinds -join ', ')"
        }
        if ([string]::IsNullOrWhiteSpace($tgt)) {
            $result.Errors += "Alias '$aname' missing 'target' profile name in: $FilePath"
        } elseif ($hasKnownProfiles -and ($tgt -notin $KnownProfileNames)) {
            $result.Errors += "Alias '$aname' -> target '$tgt' does not exist in profile config: $FilePath -- known profiles: $($KnownProfileNames -join ', ')"
        }
        if ($kind -eq 'fallback') {
            $hasReason = $adef.PSObject.Properties.Name -contains 'reason' -and -not [string]::IsNullOrWhiteSpace([string]$adef.reason)
            if (-not $hasReason) {
                $result.Warnings += "Alias '$aname' (kind=fallback) has no 'reason' explaining the soft mapping in: $FilePath"
            }
        }
        if ($aname -eq $tgt) {
            $result.Warnings += "Alias '$aname' resolves to itself in: $FilePath -- redundant entry."
        }
    }

    $result.IsValid = ($result.Errors.Count -eq 0)
    return $result
}

function Format-ProfileConfigIssues {
    <#
    .SYNOPSIS
        Pretty-prints validator results from Test-ProfileConfig /
        Test-ProfileAliasesConfig. Returns nothing (writes to host directly).
        $Title is shown as the section header (e.g. "Profile config issues").
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Result,
        [Parameter(Mandatory)][string]$Title
    )

    $errCount  = $Result.Errors.Count
    $warnCount = $Result.Warnings.Count
    if ($errCount -eq 0 -and $warnCount -eq 0) { return }

    $headerColor = if ($errCount -gt 0) { "Red" } else { "Yellow" }
    Write-Host ""
    Write-Host ("  {0} ({1} error(s), {2} warning(s)):" -f $Title, $errCount, $warnCount) -ForegroundColor $headerColor
    Write-Host ("  source: {0}" -f $Result.FilePath) -ForegroundColor DarkGray
    Write-Host ""

    if ($errCount -gt 0) {
        foreach ($e in $Result.Errors) {
            Write-Host "    [ FAIL ] " -ForegroundColor Red -NoNewline
            Write-Host $e -ForegroundColor Red
        }
    }
    if ($warnCount -gt 0) {
        foreach ($w in $Result.Warnings) {
            Write-Host "    [ WARN ] " -ForegroundColor Yellow -NoNewline
            Write-Host $w -ForegroundColor DarkYellow
        }
    }
    Write-Host ""
}
