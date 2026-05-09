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
    <#
    .SYNOPSIS
        Detect whether a given .exe is already pinned to the current user's
        taskbar. Robust against UWP-wrapped apps (e.g. Win11 Notepad) where
        the .lnk filename or target may not exactly match the source exe.
        Match priority:
          1. .lnk TargetPath equals exe full path (case-insensitive)
          2. .lnk TargetPath leaf basename equals exe leaf basename
          3. .lnk display name (file basename) equals exe leaf basename
          4. .lnk Arguments / IconLocation contains the exe leaf basename
    #>
    param([Parameter(Mandatory)][string]$ExePath)

    $userPinDir = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (-not (Test-Path $userPinDir)) { return $false }

    $exeLeaf = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    try {
        $resolved = (Resolve-Path -LiteralPath $ExePath -ErrorAction Stop).Path
    } catch { $resolved = $ExePath }
    $exeFullLower = $resolved.ToLowerInvariant()
    $exeLeafLower = $exeLeaf.ToLowerInvariant()

    $sh = New-Object -ComObject WScript.Shell
    $lnks = Get-ChildItem -LiteralPath $userPinDir -Filter "*.lnk" -ErrorAction SilentlyContinue
    foreach ($l in $lnks) {
        try {
            $sc = $sh.CreateShortcut($l.FullName)
            $tgt = "$($sc.TargetPath)"
            if ($tgt) {
                if ($tgt.ToLowerInvariant() -eq $exeFullLower) { return $true }
                $tgtLeaf = [System.IO.Path]::GetFileNameWithoutExtension($tgt)
                if ($tgtLeaf -ieq $exeLeaf) { return $true }
            }
            $lnkLeaf = [System.IO.Path]::GetFileNameWithoutExtension($l.Name)
            if ($lnkLeaf -ieq $exeLeaf) { return $true }
            $argStr  = "$($sc.Arguments)".ToLowerInvariant()
            $iconStr = "$($sc.IconLocation)".ToLowerInvariant()
            if ($argStr -like "*$exeLeafLower*" -or $iconStr -like "*$exeLeafLower*") { return $true }
        } catch { }
    }
    return $false
}

function Wait-ForTaskbarPin {
    # Poll up to ~3s for the .lnk to materialize after invoking the verb.
    param([Parameter(Mandatory)][string]$ExePath)
    for ($i = 0; $i -lt 6; $i++) {
        if (Test-IsAlreadyPinnedToTaskbar -ExePath $ExePath) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Invoke-TaskbarRefresh {
    try {
        if (-not ('Win32.TaskbarPinRefresh' -as [type])) {
            Add-Type -Namespace Win32 -Name TaskbarPinRefresh -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
'@ -ErrorAction Stop
        }
        [Win32.TaskbarPinRefresh]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch {
        # Best-effort only.
    }
}

function Get-TaskbarShortcutPath {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$AppLabel
    )

    $userPinDir = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (-not (Test-Path $userPinDir)) {
        New-Item -ItemType Directory -Path $userPinDir -Force | Out-Null
    }

    $safeName = ($AppLabel -replace '[\\/:*?"<>|]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    }

    return (Join-Path $userPinDir ("{0}.lnk" -f $safeName))
}

function Invoke-VerbOnShortcut {
    # Try to invoke the "Pin to taskbar" verb on a .lnk file. On Win11 22H2+
    # the verb is hidden on .exe items but is often still exposed on .lnk
    # shortcuts. Returns $true if a matching verb was invoked.
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string[]]$NormalizedTargets,
        [string[]]$AntiTargets = @()
    )
    try {
        $shell  = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path $ShortcutPath -Parent))
        if (-not $folder) { return $false }
        $item = $folder.ParseName((Split-Path $ShortcutPath -Leaf))
        if (-not $item) { return $false }
        foreach ($v in @($item.Verbs())) {
            $name = "$($v.Name)" -replace '&',''
            $norm = $name.Trim().ToLowerInvariant()
            if ($AntiTargets -contains $norm) { continue }   # never pin to Start
            if ($NormalizedTargets -contains $norm) {
                $v.DoIt()
                return $true
            }
        }
    } catch { }
    return $false
}

function Invoke-Win11PinUnlock {
    <#
    .SYNOPSIS
        Win11 22H2+ hides the "Pin to taskbar" verb on Shell items. The
        well-known workaround: temporarily mirror the system's
        Windows.taskbarpin ExplorerCommandHandler CLSID into
        HKCU:\Software\Classes\*\shell\{:} so the verb re-appears on every
        Shell item for the current user. Run the supplied scriptblock with
        the unlock active, then always remove the override.
        Returns whatever the scriptblock returns ($false on any failure).
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $unlockKey = 'HKCU:\Software\Classes\*\shell\{:}'
    $sourceKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell\Windows.taskbarpin'
    $created   = $false
    try {
        $clsid = $null
        try { $clsid = (Get-ItemProperty -Path $sourceKey -Name 'ExplorerCommandHandler' -ErrorAction Stop).ExplorerCommandHandler } catch { $clsid = $null }
        if ([string]::IsNullOrWhiteSpace($clsid)) { return (& $Action) }

        if (-not (Test-Path $unlockKey)) {
            New-Item -Path $unlockKey -Force | Out-Null
            $created = $true
        }
        New-ItemProperty -Path $unlockKey -Name 'ExplorerCommandHandler' -Value $clsid -PropertyType String -Force | Out-Null

        return (& $Action)
    } catch {
        return $false
    } finally {
        if ($created) {
            try { Remove-Item -Path $unlockKey -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        } else {
            try { Remove-ItemProperty -Path $unlockKey -Name 'ExplorerCommandHandler' -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Invoke-PinViaUnlockedVerb {
    <#
    .SYNOPSIS
        Run the Win11 unlock, then invoke the "Pin to taskbar" verb directly
        on the .exe (preferred) or on a Start-menu .lnk pointing at it.
        Returns $true only if Wait-ForTaskbarPin confirms a real .lnk landed
        in User Pinned\TaskBar.
    #>
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$AppLabel,
        [Parameter(Mandatory)][string[]]$NormalizedVerbTargets
    )

    # Snapshot anti-targets (Start-pin verbs) so we never invoke them by accident.
    $startAntiTargets = @()
    if ($script:_PinStartLabels) { $startAntiTargets = @($script:_PinStartLabels) }

    return (Invoke-Win11PinUnlock -Action {
        $startLnk = $null
        try {
            $shell  = New-Object -ComObject Shell.Application
            $folder = $shell.Namespace((Split-Path $ExePath -Parent))
            if ($folder) {
                $item = $folder.ParseName((Split-Path $ExePath -Leaf))
                if ($item) {
                    foreach ($v in @($item.Verbs())) {
                        $norm = (("$($v.Name)") -replace '&','').Trim().ToLowerInvariant()
                        if ($startAntiTargets -contains $norm) { continue }   # never pin to Start
                        if ($NormalizedVerbTargets -contains $norm) {
                            $v.DoIt()
                            Invoke-TaskbarRefresh
                            if (Wait-ForTaskbarPin -ExePath $ExePath) { return $true }
                            break
                        }
                    }
                }
            }

            # Fallback: invoke the now-unlocked verb on a TEMP shortcut rather
            # than a Start-menu shortcut so we never accidentally surface or pin
            # a Start-menu entry while trying to target the taskbar.
            $shortcutPath = Get-TaskbarShortcutPath -ExePath $ExePath -AppLabel $AppLabel
            $tempShortcutDir = Join-Path $env:TEMP "scripts-fixer\taskbar-pin"
            if (-not (Test-Path $tempShortcutDir)) { New-Item -ItemType Directory -Path $tempShortcutDir -Force | Out-Null }
            $startLnk = Join-Path $tempShortcutDir ("{0}.lnk" -f ([System.IO.Path]::GetFileNameWithoutExtension($shortcutPath)))
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($startLnk)
            $sc.TargetPath = $ExePath
            $sc.WorkingDirectory = Split-Path $ExePath -Parent
            $sc.IconLocation = "$ExePath,0"
            $sc.Save()

            if (Invoke-VerbOnShortcut -ShortcutPath $startLnk -NormalizedTargets $NormalizedVerbTargets -AntiTargets $startAntiTargets) {
                Invoke-TaskbarRefresh
                if (Wait-ForTaskbarPin -ExePath $ExePath) { return $true }
            }
            return $false
        } catch {
            return $false
        } finally {
            # Always remove the temp shortcut so we don't leave pinning debris.
            if ($startLnk -and (Test-Path -LiteralPath $startLnk)) {
                try { Remove-Item -LiteralPath $startLnk -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    })
}

function Invoke-ShortcutPinFallback {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$AppLabel,
        [string[]]$NormalizedVerbTargets = @('pin to taskbar')
    )

    # 1. Win11 22H2+ unlock + verb invocation -- only path that produces a
    #    real, Explorer-honored taskbar pin. Manual .lnk drops into
    #    User Pinned\TaskBar are NOT honored on modern Windows and must
    #    never be reported as success.
    try {
        if (Invoke-PinViaUnlockedVerb -ExePath $ExePath -AppLabel $AppLabel -NormalizedVerbTargets $NormalizedVerbTargets) {
            return $true
        }
    } catch { }

    return $false
}

function Get-PinToTaskbarVerbLabels {
    # Load localized "Pin to taskbar" strings from shell32.dll (best effort).
    # CRITICAL: 5386 / 51201 are "Pin to Start" -- DO NOT use them, or we end
    # up pinning to the Start menu instead of the taskbar.
    # 5387 / 51202 are "Pin to taskbar" (Win10 / Win11 respectively).
    $labels = New-Object System.Collections.Generic.List[string]
    # Anti-labels: never invoke a verb that resolves to one of these.
    $startLabels = New-Object System.Collections.Generic.List[string]
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
        # Taskbar pin string IDs.
        foreach ($id in @(5387, 51202)) {
            $sb = New-Object System.Text.StringBuilder 1024
            $n = [Win32.PinResStr]::LoadString($h, [uint32]$id, $sb, $sb.Capacity)
            if ($n -gt 0) {
                $s = $sb.ToString()
                if (-not [string]::IsNullOrWhiteSpace($s)) { $labels.Add($s) }
            }
        }
        # Start pin string IDs (used purely to *exclude* matching).
        foreach ($id in @(5386, 51201)) {
            $sb = New-Object System.Text.StringBuilder 1024
            $n = [Win32.PinResStr]::LoadString($h, [uint32]$id, $sb, $sb.Capacity)
            if ($n -gt 0) {
                $s = $sb.ToString()
                if (-not [string]::IsNullOrWhiteSpace($s)) { $startLabels.Add($s) }
            }
        }
    } catch {
        # Fall back to English labels below.
    }
    # Hardcoded fallbacks (English).
    $labels.Add("Pin to taskbar")
    $labels.Add("Pin to Tas&kbar")
    $startLabels.Add("Pin to Start")
    $startLabels.Add("Pin to &Start")
    # Stash anti-labels on a script-scoped var so callers can avoid them.
    $script:_PinStartLabels = @($startLabels | ForEach-Object { ($_ -replace '&','').Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
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
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$AppLabel
    )

    $isMissingExe = -not (Test-Path -LiteralPath $ExePath)
    if ($isMissingExe) { return "fail" }

    if (Test-IsAlreadyPinnedToTaskbar -ExePath $ExePath) {
        Save-PinTrackerEntry -ExePath $ExePath -State "pinned"
        return "already"
    }

    # NOTE: We deliberately do NOT short-circuit on the tracker here. A prior
    # run may have stored "verb-invoked-no-lnk" / "verb-hidden" -- those are
    # *recoverable* states (Explorer might cooperate this time, or the user
    # restarted Explorer). We always re-attempt the pin and only suppress the
    # repeat warning at the end if the tracker shows we've seen it before.
    $previousState = $null
    $tracker = Get-PinTracker
    $key = $ExePath.ToLowerInvariant()
    if ($tracker.ContainsKey($key)) { $previousState = "$($tracker[$key].state)" }

    $verbLabels = Get-PinToTaskbarVerbLabels
    $normalizedTargets = @($verbLabels | ForEach-Object { ($_ -replace '&','').Trim().ToLowerInvariant() } | Where-Object { $_ })
    $antiTargets = @()
    if ($script:_PinStartLabels) { $antiTargets = @($script:_PinStartLabels) }

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
            if ($antiTargets -contains $norm) { continue }   # never pin to Start
            if ($normalizedTargets -contains $norm) {
                $foundVerb = $true
                $v.DoIt()
                if (Wait-ForTaskbarPin -ExePath $ExePath) {
                    Save-PinTrackerEntry -ExePath $ExePath -State "pinned"
                    return "ok"
                }
                if (Invoke-ShortcutPinFallback -ExePath $ExePath -AppLabel $AppLabel -NormalizedVerbTargets $normalizedTargets) {
                    Save-PinTrackerEntry -ExePath $ExePath -State "pinned-shortcut"
                    return "ok"
                }
                # Verb invoked but no .lnk materialized -- usually means the
                # exe is a Store/UWP-redirected stub (Win11 Notepad) where the
                # real pinned shortcut points to an AppX target. Record + skip
                # cleanly so we don't fail the parent install.
                Save-PinTrackerEntry -ExePath $ExePath -State "verb-invoked-no-lnk"
                return "verb-unavailable"
            }
        }
        if (-not $foundVerb) {
            if (Invoke-ShortcutPinFallback -ExePath $ExePath -AppLabel $AppLabel -NormalizedVerbTargets $normalizedTargets) {
                Save-PinTrackerEntry -ExePath $ExePath -State "pinned-shortcut"
                return "ok"
            }
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
    $okCount = 0; $alreadyCount = 0; $failCount = 0; $missingCount = 0; $verbHiddenCount = 0

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
        $result = Invoke-PinToTaskbar -ExePath $exe -AppLabel $label

        switch ($result) {
            "ok" {
                Write-Log ($LogMessages.messages.pinOk -replace '\{label\}', $label) -Level "success"
                $okCount++
            }
            "already" {
                Write-Log ($LogMessages.messages.pinAlready -replace '\{label\}', $label) -Level "warn"
                $alreadyCount++
            }
            "verb-unavailable" {
                # Win11 22H2+ hides the "Pin to taskbar" shell verb. We cannot
                # pin programmatically. Treat as already-installed (skip, warn,
                # not a CODE RED) so the parent install doesn't fail.
                $template = $LogMessages.messages.pinVerbHidden
                if ([string]::IsNullOrWhiteSpace($template)) {
                    $template = "{label} skipped: Windows 11 hides the 'Pin to taskbar' verb -- exe: {exe} -- treating as already-installed (pin manually if needed)."
                }
                $msg = ($template -replace '\{label\}', $label) -replace '\{exe\}', $exe
                Write-Log $msg -Level "warn"
                $alreadyCount++
                $verbHiddenCount++
            }
            default {
                $msg = ($LogMessages.messages.pinFailed `
                    -replace '\{label\}', $label `
                    -replace '\{exe\}', $exe `
                    -replace '\{reason\}', "Explorer rejected the pin request (verb invoked but no shortcut materialized)")
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
