<#
.SYNOPSIS
    ConEmu context-menu helper for script 59.
    Detects ConEmu64.exe, registers right-click entries for normal + admin modes.

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
#  Resolve-ConEmuPath -- find ConEmu64.exe on the system
# --------------------------------------------------------------------------
function Resolve-ConEmuPath {
    param(
        [PSCustomObject]$ConEmuPaths,
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
        Write-Log ($LogMessages.messages.conemuFound -replace '\{version\}', $version -replace '\{path\}', $exePath) -Level "success"
        return $exePath
    }

    Write-Log ($LogMessages.messages.conemuNotFound -replace '\{command\}', $VerifyCommand) -Level "warn"

    # 2. Known install locations (in priority order)
    $candidates = @(
        $ConEmuPaths.programFiles,
        $ConEmuPaths.programFilesX86,
        $ConEmuPaths.chocoShim,
        $ConEmuPaths.userLocalAppData
    )

    # Choco lib root usually contains ConEmu64.exe under a versioned ConEmuPack folder
    $chocoTools = [System.Environment]::ExpandEnvironmentVariables($ConEmuPaths.chocoToolsRoot)
    if (Test-Path $chocoTools) {
        $candidates += (Join-Path $chocoTools "ConEmu64.exe")
        if ($FallbackTo32Bit) {
            $candidates += (Join-Path $chocoTools "ConEmu.exe")
        }
    }

    foreach ($raw in $candidates) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($raw)
        Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $expanded) -Level "info"
        if (Test-Path $expanded) {
            Write-Log ($LogMessages.messages.foundAtPath -replace '\{path\}', $expanded) -Level "success"
            return $expanded
        }
        Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $expanded) -Level "warn"
    }

    # 3. 32-bit fallback in standard locations
    if ($FallbackTo32Bit) {
        $fallbacks = @(
            "C:\Program Files\ConEmu\ConEmu.exe",
            "C:\Program Files (x86)\ConEmu\ConEmu.exe"
        )
        foreach ($fb in $fallbacks) {
            Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $fb) -Level "info"
            if (Test-Path $fb) {
                Write-Log ($LogMessages.messages.foundAtPath -replace '\{path\}', $fb) -Level "success"
                return $fb
            }
            Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $fb) -Level "warn"
        }
    }

    Write-Log $LogMessages.messages.noExeFound -Level "error"
    return $null
}

# --------------------------------------------------------------------------
#  ConvertTo-ConEmuRegPath -- PS Registry:: path -> reg.exe path (HKCR\...)
# --------------------------------------------------------------------------
function ConvertTo-ConEmuRegPath {
    param([string]$PsPath)

    $p = $PsPath -replace '^Registry::', ''
    $p = $p -replace '^HKEY_CLASSES_ROOT', 'HKCR'
    $p = $p -replace '^HKEY_CURRENT_USER',  'HKCU'
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    return $p
}

# --------------------------------------------------------------------------
#  Register-ConEmuContextMenu -- create one registry entry
# --------------------------------------------------------------------------
function Register-ConEmuContextMenu {
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
#  Test-ConEmuRegistryEntry -- verify a registry path exists
# --------------------------------------------------------------------------
function Test-ConEmuRegistryEntry {
    param(
        [string]$RegistryPath,
        [string]$Label,
        $LogMessages
    )

    $regPath = ConvertTo-ConEmuRegPath $RegistryPath
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
#  Invoke-ConEmuMode -- process one mode (normal or admin)
# --------------------------------------------------------------------------
function Invoke-ConEmuMode {
    param(
        [PSCustomObject]$Mode,
        [string]$ModeName,
        [string]$ConEmuExe,
        $LogMessages
    )

    Write-Host ""
    Write-Host $LogMessages.messages.modeBorderLine -ForegroundColor DarkCyan
    Write-Host ($LogMessages.messages.modeLabel -replace '\{label\}', $Mode.contextMenuLabel) -ForegroundColor Cyan
    Write-Host $LogMessages.messages.modeBorderLine -ForegroundColor DarkCyan

    Write-Log ($LogMessages.messages.processingMode -replace '\{mode\}', $ModeName -replace '\{label\}', $Mode.contextMenuLabel) -Level "info"

    $Label   = $Mode.contextMenuLabel
    $IconVal = "`"$ConEmuExe`""
    $isRunas = if ($Mode.PSObject.Properties['runas']) { $Mode.runas } else { $false }

    $entries = @(
        @{
            Step   = $LogMessages.messages.regDir
            Path   = $Mode.registryPaths.directory
            CmdArg = $Mode.commandArgs.directory -replace '\{exe\}', $ConEmuExe
        },
        @{
            Step   = $LogMessages.messages.regBg
            Path   = $Mode.registryPaths.background
            CmdArg = $Mode.commandArgs.background -replace '\{exe\}', $ConEmuExe
        }
    )

    $isAllOk = $true

    foreach ($entry in $entries) {
        $result = Register-ConEmuContextMenu `
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
        $result = Test-ConEmuRegistryEntry -RegistryPath $entry.Path -Label $entry.Step -LogMessages $LogMessages
        if (-not $result) { $isAllOk = $false }
    }

    return $isAllOk
}

# --------------------------------------------------------------------------
#  Get-ConEmuContextMenuKeys -- enumerate every HKCR key the script writes
#  Returns the keys in the SAME shape Set-Item / Remove-Item expects:
#    "Registry::HKEY_CLASSES_ROOT\Directory\shell\ConEmuHere"
#  + the bare reg.exe form ("HKEY_CLASSES_ROOT\Directory\shell\...") for
#  snapshotting via reg.exe export.
# --------------------------------------------------------------------------
function Get-ConEmuContextMenuKeys {
    param($Config)

    $psPaths   = @()
    $regPaths  = @()
    foreach ($modeName in $Config.enabledModes) {
        $mode = $Config.modes.$modeName
        if ($null -eq $mode) { continue }
        foreach ($scope in @("directory", "background")) {
            $p = $mode.registryPaths.$scope
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $psPaths  += $p
            $regPaths += ($p -replace '^Registry::', '')
        }
    }
    return [pscustomobject]@{
        PsPaths  = $psPaths
        RegPaths = $regPaths
    }
}

# --------------------------------------------------------------------------
#  Uninstall-ConEmuContextMenu -- remove registry entries + tracking
#
#  Now snapshots every affected HKCR key to a single .reg backup BEFORE
#  any delete (via scripts/shared/registry-backup.ps1), records each
#  delete in the change ledger, and prints a copy-paste rollback hint.
#
#  Supports -DryRun (preview, no writes, no snapshot file kept beyond
#  enumeration) so callers can audit the exact list of keys that would
#  be removed.
# --------------------------------------------------------------------------
function Uninstall-ConEmuContextMenu {
    param(
        $Config,
        $LogMessages,
        [switch]$DryRun
    )

    $modeWord = if ($DryRun) { 'DRY-RUN' } else { 'UNINSTALL' }
    Write-Host ""
    Write-Host ("  ConEmu context menu :: {0}" -f $modeWord) -ForegroundColor Cyan
    Write-Host  "  -------------------------------------------" -ForegroundColor DarkGray

    $keys = Get-ConEmuContextMenuKeys -Config $Config
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
        $backupResult = New-RegistryBackup -Keys $keys.RegPaths -OutputDir $backupRoot -Tag "conemu-context-menu-uninstall"
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
        $jsonLogPath = Save-RegistryChangeLog -OutputDir $backupRoot -Tag "conemu-context-menu-uninstall"
        $bp = if ($null -ne $backupResult) { $backupResult.FilePath } else { '' }
        Write-RegistryChangeLog -BackupFilePath $bp -JsonLogPath $jsonLogPath
    }

    if ($DryRun) {
        Write-Log "Dry-run complete -- no registry writes, no tracking files touched." -Level "success"
        return
    }

    if (Get-Command Remove-InstalledRecord -ErrorAction SilentlyContinue) {
        Remove-InstalledRecord -Name "conemu-context-menu"
    }
    if (Get-Command Remove-ResolvedData -ErrorAction SilentlyContinue) {
        Remove-ResolvedData -ScriptFolder "59-conemu-context-menu"
    }

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}

# --------------------------------------------------------------------------
#  Get-ConEmuContextMenuSnapshots -- list newest-first .reg backups
# --------------------------------------------------------------------------
function Get-ConEmuContextMenuSnapshots {
    $backupRoot = Join-Path $script:ScriptDir ".logs\registry-backups"
    if (-not (Test-Path -LiteralPath $backupRoot)) { return @() }
    return Get-ChildItem -LiteralPath $backupRoot -Filter "registry-backup-conemu-context-menu-*.reg" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

# --------------------------------------------------------------------------
#  Restore-ConEmuContextMenuSnapshot -- re-import the newest BEFORE .reg
#  snapshot (or an explicit -SnapshotFile) using reg.exe import.
# --------------------------------------------------------------------------
function Restore-ConEmuContextMenuSnapshot {
    param(
        [string]$SnapshotFile = '',
        [switch]$DryRun,
        $LogMessages
    )

    Write-Host ""
    Write-Host "  ConEmu context menu :: RESTORE" -ForegroundColor Cyan
    Write-Host  "  -------------------------------------------" -ForegroundColor DarkGray

    if ([string]::IsNullOrWhiteSpace($SnapshotFile)) {
        $snaps = Get-ConEmuContextMenuSnapshots
        if ($snaps.Count -eq 0) {
            $backupRoot = Join-Path $script:ScriptDir ".logs\registry-backups"
            if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
                Write-FileError `
                    -FilePath  $backupRoot `
                    -Operation 'restore' `
                    -Reason    "No 'registry-backup-conemu-context-menu-*.reg' snapshots found. Run uninstall first to create one, or pass -SnapshotFile <path>." `
                    -Module    "Restore-ConEmuContextMenuSnapshot"
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
                -Module    "Restore-ConEmuContextMenuSnapshot"
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
