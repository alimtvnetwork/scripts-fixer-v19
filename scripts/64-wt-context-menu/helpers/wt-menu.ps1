<#
.SYNOPSIS
    WindowsTerminal context-menu helper for script 59.
    Detects wt.exe, registers right-click entries for normal + admin modes.

.NOTES
    Mirrors scripts/31-pwsh-context-menu/helpers/pwsh-menu.ps1 verb-for-verb so
    the two scripts share the same look, log format, and uninstall semantics.
#>

$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# --------------------------------------------------------------------------
#  Resolve-WtPath -- find wt.exe on the system
# --------------------------------------------------------------------------
function Resolve-WtPath {
    param(
        [PSCustomObject]$WtPaths,
        [string]$VerifyCommand,
        [bool]$FallbackTo32Bit,
        $LogMessages
    )

    Write-Log $LogMessages.messages.detecting -Level "info"

    # 1. PATH lookup
    $cmd = Get-Command $VerifyCommand -ErrorAction SilentlyContinue
    if ($cmd) {
        $exePath = $cmd.Source
        $version = "(installed)"
        try {
            $verLine = & $cmd.Source "-version" 2>&1 | Select-Object -First 1
            if ($verLine) { $version = "$verLine" }
        } catch { }
        Write-Log ($LogMessages.messages.wtFound -replace '\{version\}', $version -replace '\{path\}', $exePath) -Level "success"
        return $exePath
    }

    Write-Log ($LogMessages.messages.wtNotFound -replace '\{command\}', $VerifyCommand) -Level "warn"

    # 2. Known install locations -- WindowsApps stub first (per-user MSIX), then choco shim.
    $candidates = @(
        $WtPaths.userWindowsApps,
        $WtPaths.chocoShim
    )
    foreach ($raw in $candidates) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($raw)
        Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $expanded) -Level "info"
        if (Test-Path -LiteralPath $expanded) {
            Write-Log ($LogMessages.messages.foundAtPath -replace '\{path\}', $expanded) -Level "success"
            return $expanded
        }
        Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $expanded) -Level "warn"
    }

    # 3. Glob versioned WindowsApps install (Microsoft.WindowsTerminal_*)
    $globPattern = $WtPaths.programFiles
    if (-not [string]::IsNullOrWhiteSpace($globPattern)) {
        Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $globPattern) -Level "info"
        try {
            $hit = Get-ChildItem -Path $globPattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                Write-Log ($LogMessages.messages.foundAtPath -replace '\{path\}', $hit.FullName) -Level "success"
                return $hit.FullName
            }
        } catch { }
        Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $globPattern) -Level "warn"
    }

    Write-Log $LogMessages.messages.noExeFound -Level "error"
    return $null
}

# --------------------------------------------------------------------------
#  ConvertTo-WindowsTerminalRegPath -- PS Registry:: path -> reg.exe path (HKCR\...)
# --------------------------------------------------------------------------
function ConvertTo-WindowsTerminalRegPath {
    param([string]$PsPath)

    $p = $PsPath -replace '^Registry::', ''
    $p = $p -replace '^HKEY_CLASSES_ROOT', 'HKCR'
    $p = $p -replace '^HKEY_CURRENT_USER',  'HKCU'
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    return $p
}

function Get-WindowsTerminalParentRegistryPaths {
    param([PSCustomObject]$Config)

    $parentKeyName = "$($Config.menu.parentKeyName)"
    return @{
        directory  = "Registry::HKEY_CLASSES_ROOT\Directory\shell\$parentKeyName"
        background = "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\$parentKeyName"
    }
}

function Get-WindowsTerminalCascadeRegistryRoot {
    param([PSCustomObject]$Config)

    $parentKeyName = "$($Config.menu.parentKeyName)"
    return "Registry::HKEY_CLASSES_ROOT\Directory\ContextMenus\$parentKeyName"
}

function Resolve-WindowsTerminalLeafRegistryPath {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $leafName = Split-Path -Path $RegistryPath -Leaf
    return ((Get-WindowsTerminalCascadeRegistryRoot -Config $Config) + "\shell\" + $leafName)
}

function Remove-WindowsTerminalParentRegistryTree {
    param([string]$RegistryPath)

    try {
        $subKeyPath = $RegistryPath -replace '^Registry::HKEY_CLASSES_ROOT\\', ''
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
        $probe = $hkcr.OpenSubKey($subKeyPath)
        if ($null -ne $probe) {
            $probe.Close()
            $hkcr.DeleteSubKeyTree($subKeyPath, $false)
        }
    } catch { }
}

function Invoke-WtExplorerRefresh {
    try {
        if (-not ('Win32.WindowsTerminalMenuRefresh' -as [type])) {
            Add-Type -Namespace Win32 -Name WindowsTerminalMenuRefresh -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);
'@ -ErrorAction Stop
        }
        [Win32.WindowsTerminalMenuRefresh]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { }
}

function Register-WindowsTerminalParentMenu {
    param(
        [string]$RegistryPath,
        [string]$Label,
        [string]$IconValue,
        [string]$ExtendedSubCommandsKey,
        [bool]$Runas,
        $LogMessages
    )

    try {
        $subKeyPath = $RegistryPath -replace '^Registry::HKEY_CLASSES_ROOT\\', ''
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
        $key = $hkcr.CreateSubKey($subKeyPath)
        $key.SetValue('', $Label)
        $key.SetValue('MUIVerb', $Label)
        $key.SetValue('Icon', $IconValue)
        # Use the shared ContextMenus reference pattern so both parent entries
        # point at the same cascade tree. Explorer handles this more reliably
        # for real submenus than duplicated inline child verbs.
        $key.SetValue('ExtendedSubCommandsKey', $ExtendedSubCommandsKey, [Microsoft.Win32.RegistryValueKind]::String)
        $existingSubCommands = $key.GetValue('SubCommands', $null)
        if ($null -ne $existingSubCommands) {
            try { $key.DeleteValue('SubCommands') } catch { }
        }
        # Parent must NOT have its own \command subkey -- if it does, Explorer
        # treats it as a normal verb and the cascade collapses into a single
        # click that runs the parent command.
        try {
            $cmdProbe = $hkcr.OpenSubKey("$subKeyPath\command")
            if ($null -ne $cmdProbe) {
                $cmdProbe.Close()
                $hkcr.DeleteSubKeyTree("$subKeyPath\command", $false)
            }
        } catch { }
        if ($Runas) {
            $key.SetValue('HasLUAShield', '')
        }
        $key.Close()
        return $true
    } catch {
        Write-Log (("FAILED parent menu write at {0}: {1}" -f $RegistryPath, $_.Exception.Message)) -Level "error"
        return $false
    }
}

function Remove-WindowsTerminalLegacyEntries {
    <#
    .SYNOPSIS
        Purge old flat top-level WindowsTerminal context-menu entries left by the
        previous (pre-submenu) implementation so they don't duplicate the new
        cascading "WindowsTerminal" parent.
    #>
    param($LogMessages)

    $legacyKeys = @(
        'Directory\shell\OpenWindowsTerminalHere',
        'Directory\shell\OpenWindowsTerminalAdmin',
        'Directory\shell\OpenWindowsTerminalAsAdmin',
        'Directory\shell\WindowsTerminal',
        'Directory\shell\WindowsTerminalAdmin',
        'Directory\shell\wt',
        'Directory\Background\shell\OpenWindowsTerminalHere',
        'Directory\Background\shell\OpenWindowsTerminalAdmin',
        'Directory\Background\shell\OpenWindowsTerminalAsAdmin',
        'Directory\Background\shell\WindowsTerminal',
        'Directory\Background\shell\WindowsTerminalAdmin',
        'Directory\Background\shell\wt'
    )

    $hkcr = [Microsoft.Win32.Registry]::ClassesRoot
    foreach ($k in $legacyKeys) {
        try {
            $probe = $hkcr.OpenSubKey($k)
            if ($null -ne $probe) {
                $probe.Close()
                $hkcr.DeleteSubKeyTree($k, $false)
                Write-Log ("Removed legacy entry: HKCR\{0}" -f $k) -Level "success"
            }
        } catch {
            Write-Log ("Could not remove legacy entry HKCR\{0}: {1}" -f $k, $_.Exception.Message) -Level "warn"
        }
    }
}

# --------------------------------------------------------------------------
#  Register-WindowsTerminalContextMenu -- create one registry entry
# --------------------------------------------------------------------------
function Register-WindowsTerminalContextMenu {
    param(
        [string]$StepLabel,
        [string]$RegistryPath,
        [string]$Label,
        [string]$IconValue,
        [string]$CommandArg,
        [bool]$Runas,
        $LogMessages
    )

    Write-Log ($LogMessages.messages.registerStep   -replace '\{step\}',    $StepLabel) -Level "info"
    Write-Log ($LogMessages.messages.regPathDetail  -replace '\{path\}',    $RegistryPath) -Level "info"
    Write-Log ($LogMessages.messages.regLabelDetail -replace '\{label\}',   $Label) -Level "info"
    Write-Log ($LogMessages.messages.regIconDetail  -replace '\{icon\}',    $IconValue) -Level "info"
    Write-Log ($LogMessages.messages.regCommandDetail -replace '\{command\}', $CommandArg) -Level "info"

    try {
        $subKeyPath = $RegistryPath -replace '^Registry::HKEY_CLASSES_ROOT\\', ''
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot

        Write-Log ("  " + ($LogMessages.messages.settingRegistryDefault -replace '\{label\}', $Label)) -Level "info"
        $key = $hkcr.CreateSubKey($subKeyPath)
        $key.SetValue("", $Label)
        $key.SetValue("MUIVerb", $Label)
        $key.Close()
        Write-Log ("  " + $LogMessages.messages.registryDefaultSet) -Level "success"

        Write-Log ("  " + ($LogMessages.messages.settingIcon -replace '\{icon\}', $IconValue)) -Level "info"
        $key = $hkcr.OpenSubKey($subKeyPath, $true)
        $key.SetValue("Icon", $IconValue)
        $key.Close()
        Write-Log ("  " + $LogMessages.messages.iconSet) -Level "success"

        if ($Runas) {
            Write-Log ("  " + $LogMessages.messages.settingRunas) -Level "info"
            $key = $hkcr.OpenSubKey($subKeyPath, $true)
            $key.SetValue("HasLUAShield", "")
            $key.Close()
            Write-Log ("  " + $LogMessages.messages.runasSet) -Level "success"
        }

        Write-Log ("  " + ($LogMessages.messages.settingCommand -replace '\{command\}', $CommandArg)) -Level "info"
        $cmdKey = $hkcr.CreateSubKey("$subKeyPath\command")
        $cmdKey.SetValue("", $CommandArg)
        $cmdKey.Close()
        Write-Log ("  " + $LogMessages.messages.commandSet) -Level "success"
        return $true
    } catch {
        Write-Log ("  " + ($LogMessages.messages.registryFailed -replace '\{error\}', $_)) -Level "error"
        Write-Log ("  " + ($LogMessages.messages.registryStack  -replace '\{stack\}', $_.ScriptStackTrace)) -Level "error"
        return $false
    }
}

# --------------------------------------------------------------------------
#  Test-WindowsTerminalRegistryEntry -- verify a registry path exists
# --------------------------------------------------------------------------
function Test-WindowsTerminalRegistryEntry {
    param(
        [string]$RegistryPath,
        [string]$Label,
        $LogMessages
    )

    $regPath = ConvertTo-WindowsTerminalRegPath $RegistryPath
    Write-Log ("  " + ($LogMessages.messages.verifyingEntry -replace '\{path\}', $regPath)) -Level "info"

    $null = reg.exe query $regPath 2>&1
    $isEntryFound = $LASTEXITCODE -eq 0
    if ($isEntryFound) {
        Write-Log ("  " + (($LogMessages.messages.verifyPass -replace '\{label\}', $Label) -replace '\{path\}', $regPath)) -Level "success"
        return $true
    } else {
        Write-Log ("  " + (($LogMessages.messages.verifyMiss -replace '\{label\}', $Label) -replace '\{path\}', $regPath)) -Level "error"
        return $false
    }
}

# --------------------------------------------------------------------------
#  Invoke-WtMode -- process one mode (normal or admin)
# --------------------------------------------------------------------------
function Invoke-WtMode {
    param(
        [PSCustomObject]$Mode,
        [string]$ModeName,
        [string]$WtExe,
        [PSCustomObject]$Config,
        $LogMessages
    )

    Write-Host ""
    Write-Host $LogMessages.messages.modeBorderLine -ForegroundColor DarkCyan
    Write-Host ($LogMessages.messages.modeLabel -replace '\{label\}', $Mode.contextMenuLabel) -ForegroundColor Cyan
    Write-Host $LogMessages.messages.modeBorderLine -ForegroundColor DarkCyan

    Write-Log ($LogMessages.messages.processingMode -replace '\{mode\}', $ModeName -replace '\{label\}', $Mode.contextMenuLabel) -Level "info"

    $Label   = $Mode.contextMenuLabel
    $IconVal = "`"$WtExe`""
    $isRunas = if ($Mode.PSObject.Properties['runas']) { $Mode.runas } else { $false }

    $entries = @(
        @{
            Step   = $LogMessages.messages.regDir
            Path   = Resolve-WindowsTerminalLeafRegistryPath -RegistryPath $Mode.registryPaths.directory -Config $Config
            CmdArg = $Mode.commandArgs.directory -replace '\{exe\}', $WtExe
        },
        @{
            Step   = $LogMessages.messages.regBg
            Path   = Resolve-WindowsTerminalLeafRegistryPath -RegistryPath $Mode.registryPaths.background -Config $Config
            CmdArg = $Mode.commandArgs.background -replace '\{exe\}', $WtExe
        }
    )

    $isAllOk = $true

    foreach ($entry in $entries) {
        $result = Register-WindowsTerminalContextMenu `
            -StepLabel    $entry.Step `
            -RegistryPath $entry.Path `
            -Label        $Label `
            -IconValue    $IconVal `
            -CommandArg   $entry.CmdArg `
            -Runas        $isRunas `
            -LogMessages  $LogMessages
        if (-not $result) { $isAllOk = $false }
    }

    Write-Log $LogMessages.messages.verify -Level "info"
    foreach ($entry in $entries) {
        $result = Test-WindowsTerminalRegistryEntry -RegistryPath $entry.Path -Label $entry.Step -LogMessages $LogMessages
        if (-not $result) { $isAllOk = $false }
    }

    return $isAllOk
}

function Install-WtParentMenus {
    param(
        [PSCustomObject]$Config,
        [string]$WtExe,
        $LogMessages
    )

    # Purge old flat top-level entries before installing the new submenu --
    # otherwise the right-click menu shows duplicates from prior versions.
    Remove-WindowsTerminalLegacyEntries -LogMessages $LogMessages

    $parentPaths = Get-WindowsTerminalParentRegistryPaths -Config $Config
    $cascadeRoot = Get-WindowsTerminalCascadeRegistryRoot -Config $Config
    $extendedSubCommandsKey = ($cascadeRoot -replace '^Registry::HKEY_CLASSES_ROOT\\', '')
    Remove-WindowsTerminalParentRegistryTree -RegistryPath $cascadeRoot
    $iconValue = '"' + $WtExe + '"'
    $parentLabel = "$($Config.menu.parentLabel)"
    $isAllOk = $true

    foreach ($scope in @('directory', 'background')) {
        Remove-WindowsTerminalParentRegistryTree -RegistryPath $parentPaths[$scope]
        $ok = Register-WindowsTerminalParentMenu -RegistryPath $parentPaths[$scope] -Label $parentLabel -IconValue $iconValue -ExtendedSubCommandsKey $extendedSubCommandsKey -Runas $false -LogMessages $LogMessages
        if (-not $ok) { $isAllOk = $false }
    }

    return $isAllOk
}

# --------------------------------------------------------------------------
#  Get-WindowsTerminalContextMenuKeys -- enumerate every HKCR key the script writes
#  Returns the keys in the SAME shape Set-Item / Remove-Item expects:
#    "Registry::HKEY_CLASSES_ROOT\Directory\shell\WindowsTerminalHere"
#  + the bare reg.exe form ("HKEY_CLASSES_ROOT\Directory\shell\...") for
#  snapshotting via reg.exe export.
# --------------------------------------------------------------------------
function Get-WindowsTerminalContextMenuKeys {
    param($Config)

    $psPaths   = @()
    $regPaths  = @()
    $useCascadeRoot = $Config.PSObject.Properties.Name -contains 'menu'
    foreach ($modeName in $Config.enabledModes) {
        $mode = $Config.modes.$modeName
        if ($null -eq $mode) { continue }
        foreach ($scope in @("directory", "background")) {
            $p = if ($useCascadeRoot) {
                Resolve-WindowsTerminalLeafRegistryPath -RegistryPath $mode.registryPaths.$scope -Config $Config
            } else {
                $mode.registryPaths.$scope
            }
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $psPaths  += $p
            $regPaths += ($p -replace '^Registry::', '')
        }
    }
    if ($Config.PSObject.Properties.Name -contains 'menu') {
        $parentPaths = Get-WindowsTerminalParentRegistryPaths -Config $Config
        $cascadeRoot = Get-WindowsTerminalCascadeRegistryRoot -Config $Config
        $psPaths += $parentPaths.directory
        $psPaths += $parentPaths.background
        $psPaths += $cascadeRoot
        $regPaths += ($parentPaths.directory -replace '^Registry::', '')
        $regPaths += ($parentPaths.background -replace '^Registry::', '')
        $regPaths += ($cascadeRoot -replace '^Registry::', '')
    }
    return [pscustomobject]@{
        PsPaths  = $psPaths
        RegPaths = $regPaths
    }
}

# --------------------------------------------------------------------------
#  Uninstall-WtContextMenu -- remove registry entries + tracking
#
#  Now snapshots every affected HKCR key to a single .reg backup BEFORE
#  any delete (via scripts/shared/registry-backup.ps1), records each
#  delete in the change ledger, and prints a copy-paste rollback hint.
#
#  Supports -DryRun (preview, no writes, no snapshot file kept beyond
#  enumeration) so callers can audit the exact list of keys that would
#  be removed.
# --------------------------------------------------------------------------
function Uninstall-WtContextMenu {
    param(
        $Config,
        $LogMessages,
        [switch]$DryRun
    )

    $modeWord = if ($DryRun) { 'DRY-RUN' } else { 'UNINSTALL' }
    Write-Host ""
    Write-Host ("  Windows Terminal context menu :: {0}" -f $modeWord) -ForegroundColor Cyan
    Write-Host  "  -------------------------------------------" -ForegroundColor DarkGray

    $keys = Get-WindowsTerminalContextMenuKeys -Config $Config
    if ($keys.PsPaths.Count -eq 0) {
        Write-Log "No registry paths declared in config.modes -- nothing to do." -Level "warn"
        return
    }

    # ---- Snapshot first (skip in dry-run; we still print what WOULD be backed up) ----
    $backupResult = $null
    $jsonLogPath  = $null
    $backupRoot   = Join-Path $script:ScriptDir ".logs\registry-backups"

    $hasBackupHelper = $null -ne (Get-Command New-RegistryBackup -ErrorAction SilentlyContinue)
    if ($hasBackupHelper) { Start-RegistryChangeLog }

    if ($DryRun) {
        Write-Log "Dry-run: would snapshot the following keys to a .reg file under .logs\registry-backups\:" -Level "info"
        foreach ($k in $keys.RegPaths) {
            $isPresent = $false
            $null = reg.exe query $k 2>&1
            if ($LASTEXITCODE -eq 0) { $isPresent = $true }
            $marker = if ($isPresent) { "[present]" } else { "[absent]" }
            Write-Log ("  {0}  {1}" -f $marker, $k) -Level "info"
        }
    } elseif ($hasBackupHelper) {
        Write-Log "Snapshotting affected HKCR keys to a .reg file (rollback insurance)..." -Level "info"
        $backupResult = New-RegistryBackup -Keys $keys.RegPaths -OutputDir $backupRoot -Tag "wt-context-menu-uninstall"
        if ($null -ne $backupResult -and $null -ne $backupResult.FilePath) {
            Write-Log ("Backup written: " + $backupResult.FilePath) -Level "success"
            foreach ($row in $backupResult.Keys) {
                Add-RegistryChange `
                    -Operation 'BACKUP' `
                    -Path      $row.Path `
                    -Target    'HKCR' `
                    -Detail    ("present={0}, exported={1}" -f $row.Present, $row.Exported) `
                    -Success   ($row.Exported -or -not $row.Present)
            }
        } else {
            Write-Log "Snapshot helper returned no FilePath -- proceeding without rollback file (degraded mode)." -Level "warn"
        }
    } else {
        Write-Log "scripts/shared/registry-backup.ps1 not loaded -- proceeding without rollback snapshot." -Level "warn"
    }

    # ---- Delete pass ----
    foreach ($psPath in $keys.PsPaths) {
        $regPath = $psPath -replace '^Registry::', ''
        $isPresent = Test-Path $psPath

        if ($DryRun) {
            $verb = if ($isPresent) { "WOULD REMOVE" } else { "WOULD SKIP (absent)" }
            Write-Log ("  {0,-22}  {1}" -f $verb, $regPath) -Level "info"
            continue
        }

        if (-not $isPresent) {
            Write-Log ("  SKIP (absent): {0}" -f $regPath) -Level "info"
            if ($hasBackupHelper) {
                Add-RegistryChange -Operation 'SKIP' -Path $regPath -Target 'HKCR' -Detail 'key not present at uninstall time'
            }
            continue
        }

        try {
            Remove-Item -Path $psPath -Recurse -Force -ErrorAction Stop
            Write-Log ("  Removed registry key: {0}" -f $regPath) -Level "success"
            if ($hasBackupHelper) {
                Add-RegistryChange -Operation 'DELETE' -Path $regPath -Target 'HKCR' -Detail 'recursive remove'
            }
        } catch {
            Write-Log ("  FAILED to remove {0}: {1}" -f $regPath, $_.Exception.Message) -Level "error"
            if ($hasBackupHelper) {
                Add-RegistryChange -Operation 'FAIL' -Path $regPath -Target 'HKCR' -Detail $_.Exception.Message -Success $false
            }
        }
    }

    # ---- Persist ledger + print colored summary ----
    if ($hasBackupHelper -and -not $DryRun) {
        $jsonLogPath = Save-RegistryChangeLog -OutputDir $backupRoot -Tag "wt-context-menu-uninstall"
        $bp = if ($null -ne $backupResult) { $backupResult.FilePath } else { '' }
        Write-RegistryChangeLog -BackupFilePath $bp -JsonLogPath $jsonLogPath
    }

    if ($DryRun) {
        Write-Log "Dry-run complete -- no registry writes, no tracking files touched." -Level "success"
        return
    }

    if (Get-Command Remove-InstalledRecord -ErrorAction SilentlyContinue) {
        Remove-InstalledRecord -Name "wt-context-menu"
    }
    if (Get-Command Remove-ResolvedData -ErrorAction SilentlyContinue) {
        Remove-ResolvedData -ScriptFolder "59-wt-context-menu"
    }

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}

# --------------------------------------------------------------------------
#  Get-WtContextMenuSnapshots -- list newest-first .reg backups
# --------------------------------------------------------------------------
function Get-WtContextMenuSnapshots {
    $backupRoot = Join-Path $script:ScriptDir ".logs\registry-backups"
    if (-not (Test-Path -LiteralPath $backupRoot)) { return @() }
    return Get-ChildItem -LiteralPath $backupRoot -Filter "registry-backup-wt-context-menu-*.reg" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

# --------------------------------------------------------------------------
#  Restore-WtContextMenuSnapshot -- re-import the newest BEFORE .reg
#  snapshot (or an explicit -SnapshotFile) using reg.exe import.
# --------------------------------------------------------------------------
function Restore-WtContextMenuSnapshot {
    param(
        [string]$SnapshotFile = '',
        [switch]$DryRun,
        $LogMessages
    )

    Write-Host ""
    Write-Host "  Windows Terminal context menu :: RESTORE" -ForegroundColor Cyan
    Write-Host  "  -------------------------------------------" -ForegroundColor DarkGray

    if ([string]::IsNullOrWhiteSpace($SnapshotFile)) {
        $snaps = Get-WtContextMenuSnapshots
        if ($snaps.Count -eq 0) {
            $backupRoot = Join-Path $script:ScriptDir ".logs\registry-backups"
            if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
                Write-FileError `
                    -FilePath  $backupRoot `
                    -Operation 'restore' `
                    -Reason    "No 'registry-backup-wt-context-menu-*.reg' snapshots found. Run uninstall first to create one, or pass -SnapshotFile <path>." `
                    -Module    "Restore-WtContextMenuSnapshot"
            } else {
                Write-Log ("No snapshots found under: " + $backupRoot) -Level "error"
                Write-Log "Run uninstall first to create one, or pass -SnapshotFile <path>." -Level "error"
            }
            return $false
        }
        $SnapshotFile = $snaps[0].FullName
        Write-Log ("Newest snapshot selected: " + $SnapshotFile) -Level "info"
    }

    if (-not (Test-Path -LiteralPath $SnapshotFile)) {
        if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
            Write-FileError `
                -FilePath  $SnapshotFile `
                -Operation 'restore' `
                -Reason    "Snapshot file does not exist (failure: bad -SnapshotFile path or file deleted)." `
                -Module    "Restore-WtContextMenuSnapshot"
        } else {
            Write-Log ("Snapshot file not found: " + $SnapshotFile) -Level "error"
        }
        return $false
    }

    if ($DryRun) {
        Write-Log "Dry-run: would run the following command:" -Level "info"
        Write-Log ("  reg.exe import `"" + $SnapshotFile + "`"") -Level "info"
        Write-Log "Snapshot contents (header):" -Level "info"
        Get-Content -LiteralPath $SnapshotFile -TotalCount 12 |
            ForEach-Object { Write-Log ("    " + $_) -Level "info" }
        return $true
    }

    Write-Log ("Importing: " + $SnapshotFile) -Level "info"
    $null = reg.exe import $SnapshotFile 2>&1
    $isOk = ($LASTEXITCODE -eq 0)
    if ($isOk) {
        Write-Log "Snapshot imported successfully -- previous registry state restored." -Level "success"
        return $true
    } else {
        Write-Log ("reg.exe import failed (exit {0}). File: {1}" -f $LASTEXITCODE, $SnapshotFile) -Level "error"
        return $false
    }
}
