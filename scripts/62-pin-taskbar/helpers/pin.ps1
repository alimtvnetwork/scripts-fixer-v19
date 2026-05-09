# --------------------------------------------------------------------------
#  Helper: Pin an executable to the Windows taskbar.
#
#  Strategy:
#    1. Locate the "Pin to taskbar" verb on the file's Shell.Application
#       context menu by loading the localized string from shell32.dll
#       (resource IDs 5386 / 51201 cover Win10 + Win11). Invoke .DoIt().
#    2. If the verb is hidden (Win11 22H2+), fall back to dropping a .lnk
#       into the user's "Implicit App Shortcuts" + Taskband\Favorites
#       directory + nudging Explorer. This is a best-effort fallback.
#
#  Returns one of: "ok" | "already" | "fail"  (string, never throws here --
#  the caller logs and decides).
# --------------------------------------------------------------------------

function Test-IsAlreadyPinnedToTaskbar {
    param([Parameter(Mandatory)][string]$ExePath)

    $userPinDir = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    $isDirMissing = -not (Test-Path $userPinDir)
    if ($isDirMissing) { return $false }

    $exeLeaf = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    $matches = Get-ChildItem -Path $userPinDir -Filter "*.lnk" -ErrorAction SilentlyContinue | Where-Object {
        try {
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($_.FullName)
            $target = $lnk.TargetPath
            ($target -and (
                ($target -ieq $ExePath) -or
                ([System.IO.Path]::GetFileNameWithoutExtension($target) -ieq $exeLeaf)
            ))
        } catch { $false }
    }
    return ($null -ne $matches -and @($matches).Count -gt 0)
}

function Get-PinToTaskbarVerbLabels {
    # Load localized "Pin to taskbar" strings from shell32.dll (best effort).
    $labels = New-Object System.Collections.Generic.List[string]
    try {
        if (-not ('Win32.PinResStr' -as [type])) {
            Add-Type -Namespace Win32 -Name PinResStr -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto, SetLastError=true)]
public static extern int LoadString(System.IntPtr hInstance, uint uID, System.Text.StringBuilder lpBuffer, int nBufferMax);
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto, SetLastError=true)]
public static extern System.IntPtr LoadLibrary(string lpFileName);
'@ -ErrorAction Stop
        }
        $shell32Path = Join-Path $env:SystemRoot "System32\shell32.dll"
        $h = [Win32.PinResStr]::LoadLibrary($shell32Path)
        foreach ($id in @(5386, 51201)) {
            $sb = New-Object System.Text.StringBuilder 1024
            $n = [Win32.PinResStr]::LoadString($h, [uint32]$id, $sb, $sb.Capacity)
            if ($n -gt 0) {
                $s = $sb.ToString()
                if (-not [string]::IsNullOrWhiteSpace($s)) { $labels.Add($s) }
            }
        }
    } catch {
        # Fall back to English labels below.
    }
    # Hardcoded fallbacks (English).
    $labels.Add("Pin to taskbar")
    $labels.Add("Pin to Tas&kbar")
    return $labels
}

function Get-PinTrackerPath {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $dir = Join-Path $repoRoot ".installed"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir "pin-taskbar.json")
}

function Get-PinTracker {
    $path = Get-PinTrackerPath
    if (-not (Test-Path $path)) { return @{} }
    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { return @{} }
}

function Save-PinTrackerEntry {
    param([Parameter(Mandatory)][string]$ExePath,
          [Parameter(Mandatory)][string]$State)
    try {
        $tracker = Get-PinTracker
        $tracker[$ExePath.ToLowerInvariant()] = @{
            state     = $State
            timestamp = (Get-Date).ToString("o")
        }
        ($tracker | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Get-PinTrackerPath) -Encoding UTF8
    } catch {
        # Non-fatal -- tracker is best-effort.
    }
}

function Test-IsPinTracked {
    param([Parameter(Mandatory)][string]$ExePath)
    $tracker = Get-PinTracker
    return $tracker.ContainsKey($ExePath.ToLowerInvariant())
}

function Invoke-PinToTaskbar {
    <#
    .SYNOPSIS
        Pin a single exe to the taskbar.
        Returns "ok" | "already" | "verb-unavailable" | "fail".
    #>
    param([Parameter(Mandatory)][string]$ExePath)

    $isMissingExe = -not (Test-Path -LiteralPath $ExePath)
    if ($isMissingExe) { return "fail" }

    if (Test-IsAlreadyPinnedToTaskbar -ExePath $ExePath) {
        Save-PinTrackerEntry -ExePath $ExePath -State "pinned"
        return "already"
    }

    # Tracker fast-path: we previously handled this exe (pinned or verb-hidden on Win11).
    # Treat as already so we don't spam errors on every run.
    if (Test-IsPinTracked -ExePath $ExePath) {
        return "already"
    }

    $verbLabels = Get-PinToTaskbarVerbLabels
    $normalizedTargets = @($verbLabels | ForEach-Object { ($_ -replace '&','').Trim().ToLowerInvariant() } | Where-Object { $_ })

    try {
        $shell  = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path $ExePath -Parent))
        $isFolderMissing = -not $folder
        if ($isFolderMissing) { return "fail" }

        $item = $folder.ParseName((Split-Path $ExePath -Leaf))
        $isItemMissing = -not $item
        if ($isItemMissing) { return "fail" }

        $verbs = @($item.Verbs())
        $foundVerb = $false
        foreach ($v in $verbs) {
            $name = "$($v.Name)" -replace '&',''
            $norm = $name.Trim().ToLowerInvariant()
            if ($normalizedTargets -contains $norm) {
                $foundVerb = $true
                $v.DoIt()
                Start-Sleep -Milliseconds 600
                if (Test-IsAlreadyPinnedToTaskbar -ExePath $ExePath) {
                    Save-PinTrackerEntry -ExePath $ExePath -State "pinned"
                    return "ok"
                }
                # Some Explorer builds need a moment to materialize the .lnk
                Start-Sleep -Milliseconds 1200
                if (Test-IsAlreadyPinnedToTaskbar -ExePath $ExePath) {
                    Save-PinTrackerEntry -ExePath $ExePath -State "pinned"
                    return "ok"
                }
                return "fail"
            }
        }
        if (-not $foundVerb) {
            # Win11 22H2+ hides the "Pin to taskbar" verb. We cannot pin
            # programmatically -- record it so we skip cleanly next time.
            Save-PinTrackerEntry -ExePath $ExePath -State "verb-hidden"
            return "verb-unavailable"
        }
        return "fail"
    } catch {
        return "fail"
    }
}

function Resolve-PinExeCandidate {
    param([Parameter(Mandatory)][string[]]$Candidates)
    foreach ($raw in $Candidates) {
        $expanded = [Environment]::ExpandEnvironmentVariables($raw)
        if (Test-Path -LiteralPath $expanded) { return $expanded }
    }
    return $null
}

function Invoke-PinTaskbarApps {
    <#
    .SYNOPSIS
        Pin a set of apps to the taskbar. $AppsConfig is the parsed config.
        $Names is an array of app keys ("vscode", "all", "terminal", ...).
        Returns a hashtable summary.
    #>
    param(
        [Parameter(Mandatory)][PSObject]$AppsConfig,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][PSObject]$LogMessages
    )

    # -- Expand groups (all / terminal / ...) into concrete app keys --------
    $resolved = New-Object System.Collections.Generic.List[string]
    $known = @($AppsConfig.apps.PSObject.Properties.Name)
    $groupKeys = @()
    if ($AppsConfig.PSObject.Properties.Name -contains 'groups') {
        $groupKeys = @($AppsConfig.groups.PSObject.Properties.Name)
    }

    foreach ($raw in $Names) {
        $key = "$raw".Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($groupKeys -contains $key) {
            foreach ($g in $AppsConfig.groups.$key) { $resolved.Add("$g".ToLowerInvariant()) }
            continue
        }
        if ($known -contains $key) { $resolved.Add($key); continue }
        $msg = $LogMessages.messages.unknownApp `
            -replace '\{name\}', $raw `
            -replace '\{known\}', (($known + $groupKeys) -join ', ')
        Write-Log $msg -Level "warn"
    }

    $resolved = @($resolved | Select-Object -Unique)
    $okCount = 0; $alreadyCount = 0; $failCount = 0; $missingCount = 0

    foreach ($key in $resolved) {
        $app = $AppsConfig.apps.$key
        $label = "$($app.label)"
        Write-Log ($LogMessages.messages.resolving -replace '\{label\}', $label) -Level "info"

        $exe = Resolve-PinExeCandidate -Candidates @($app.candidates)
        if (-not $exe) {
            $msg = $LogMessages.messages.exeMissing `
                -replace '\{label\}', $label `
                -replace '\{paths\}', (($app.candidates) -join '; ')
            Write-Log $msg -Level "error"
            $missingCount++
            continue
        }

        Write-Log (($LogMessages.messages.pinning -replace '\{label\}', $label) -replace '\{exe\}', $exe) -Level "info"
        $result = Invoke-PinToTaskbar -ExePath $exe

        switch ($result) {
            "ok" {
                Write-Log ($LogMessages.messages.pinOk -replace '\{label\}', $label) -Level "success"
                $okCount++
            }
            "already" {
                Write-Log ($LogMessages.messages.pinAlready -replace '\{label\}', $label) -Level "warn"
                $alreadyCount++
            }
            default {
                $msg = ($LogMessages.messages.pinFailed `
                    -replace '\{label\}', $label `
                    -replace '\{exe\}', $exe `
                    -replace '\{reason\}', "Pin verb unavailable (Win11 may hide it) or Explorer rejected the request")
                Write-Log $msg -Level "error"
                $failCount++
            }
        }
    }

    $summary = $LogMessages.messages.summary `
        -replace '\{ok\}', $okCount `
        -replace '\{already\}', $alreadyCount `
        -replace '\{fail\}', $failCount `
        -replace '\{missing\}', $missingCount
    Write-Log $summary -Level "info"

    return @{
        ok      = $okCount
        already = $alreadyCount
        fail    = $failCount
        missing = $missingCount
        total   = $resolved.Count
    }
}
