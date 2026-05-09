<#
.SYNOPSIS
    PowerShell context-menu helper for script 31.
    Detects the latest pwsh.exe, registers context menu entries for normal + admin modes.
#>

$_sharedDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "shared"
$_loggingPath = Join-Path $_sharedDir "logging.ps1"
if ((Test-Path $_loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $_loggingPath
}

# --------------------------------------------------------------------------
#  Resolve-PwshPath -- find the latest pwsh.exe on the system
# --------------------------------------------------------------------------
function Resolve-PwshPath {
    param(
        [PSCustomObject]$PwshPaths,
        [string]$VerifyCommand,
        [string]$VersionFlag,
        [bool]$FallbackToLegacy,
        $LogMessages
    )

    Write-Log $LogMessages.messages.detecting -Level "info"

    # 1. Check PATH first
    $pwshCmd = Get-Command $VerifyCommand -ErrorAction SilentlyContinue
    if ($pwshCmd) {
        $exePath = $pwshCmd.Source
        $version = & $VerifyCommand $VersionFlag 2>&1 | Select-Object -First 1
        Write-Log ($LogMessages.messages.pwshFound -replace '\{version\}', $version -replace '\{path\}', $exePath) -Level "success"
        return $exePath
    }

    Write-Log ($LogMessages.messages.pwshNotFound -replace '\{command\}', $VerifyCommand) -Level "warn"

    # 2. Scan Program Files for highest major version
    $pfBase = "C:\Program Files\PowerShell"
    $isPfExists = Test-Path $pfBase
    if ($isPfExists) {
        $versions = Get-ChildItem $pfBase -Directory | Where-Object { $_.Name -match '^\d+$' } | Sort-Object { [int]$_.Name } -Descending
        foreach ($verDir in $versions) {
            $candidate = Join-Path $verDir.FullName "pwsh.exe"
            Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $candidate) -Level "info"
            $isFound = Test-Path $candidate
            if ($isFound) {
                Write-Log ($LogMessages.messages.foundAtPath -replace '\{path\}', $candidate) -Level "success"
                return $candidate
            }
            Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $candidate) -Level "warn"
        }
    } else {
        Write-Log "Program Files PowerShell directory not found: $pfBase" -Level "warn"
    }

    # 3. Check winget WindowsApps path
    $wingetPath = [System.Environment]::ExpandEnvironmentVariables($PwshPaths.winget)
    Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $wingetPath) -Level "info"
    $isWingetFound = Test-Path $wingetPath
    if ($isWingetFound) {
        Write-Log ($LogMessages.messages.foundAtPath -replace '\{path\}', $wingetPath) -Level "success"
        return $wingetPath
    }
    Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $wingetPath) -Level "warn"

    # 4. Fallback: Chocolatey shim
    $chocoShimPath = Join-Path $env:ProgramData "chocolatey\bin\pwsh.exe"
    Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $chocoShimPath) -Level "info"
    $isChocoFound = Test-Path $chocoShimPath
    if ($isChocoFound) {
        Write-Log ($LogMessages.messages.foundAtPath -replace '\{path\}', $chocoShimPath) -Level "success"
        return $chocoShimPath
    }
    Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $chocoShimPath) -Level "warn"

    # 5. Fallback to legacy powershell.exe
    if ($FallbackToLegacy) {
        $legacyPath = [System.Environment]::ExpandEnvironmentVariables($PwshPaths.legacy)
        Write-Log ($LogMessages.messages.searchingPath -replace '\{path\}', $legacyPath) -Level "info"
        $isLegacyFound = Test-Path $legacyPath
        if ($isLegacyFound) {
            Write-Log ($LogMessages.messages.usingLegacy -replace '\{path\}', $legacyPath) -Level "warn"
            return $legacyPath
        }
        Write-Log ($LogMessages.messages.pathNotFound -replace '\{path\}', $legacyPath) -Level "error"
    }

    Write-Log $LogMessages.messages.noExeFound -Level "error"
    return $null
}

# --------------------------------------------------------------------------
#  ConvertTo-RegPath -- PS registry path to reg.exe path
# --------------------------------------------------------------------------
function ConvertTo-PwshRegPath {
    param([string]$PsPath)

    $p = $PsPath -replace '^Registry::', ''
    $p = $p -replace '^HKEY_CLASSES_ROOT', 'HKCR'
    $p = $p -replace '^HKEY_CURRENT_USER', 'HKCU'
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    return $p
}

function Get-PwshParentRegistryPaths {
    param([PSCustomObject]$Config)

    $parentKeyName = "$($Config.menu.parentKeyName)"
    return @{
        directory  = "Registry::HKEY_CLASSES_ROOT\Directory\shell\$parentKeyName"
        background = "Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\$parentKeyName"
    }
}

function Get-PwshParentLeafLabel {
    param([string]$ContextMenuLabel)

    if ($ContextMenuLabel -like 'Open PowerShell*') {
        return ($ContextMenuLabel -replace '^Open PowerShell Here\s*', '').Trim()
    }
    return $ContextMenuLabel
}

function Register-PwshParentMenu {
    param(
        [string]$RegistryPath,
        [string]$Label,
        [string]$IconValue,
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
        # NOTE: We deliberately do NOT set 'SubCommands' here.  When SubCommands
        # is present (even empty) Explorer treats it as the authoritative verb
        # list and ignores the local '\shell\' children -- which is exactly why
        # the cascading submenu showed up empty.  Without SubCommands and with
        # a child '\shell\' subkey present, Explorer auto-cascades the children.
        $existingSub = $key.GetValue('SubCommands', $null)
        if ($null -ne $existingSub) {
            try { $key.DeleteValue('SubCommands') } catch { }
        }
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

function Remove-PwshLegacyEntries {
    <#
    .SYNOPSIS
        Purge old flat top-level PowerShell context-menu entries left by the
        previous (pre-submenu) implementation so they don't duplicate the new
        cascading "PowerShell" parent.
    #>
    param($LogMessages)

    $legacyKeys = @(
        'Directory\shell\OpenPowerShellHere',
        'Directory\shell\OpenPowerShellAdmin',
        'Directory\shell\OpenPowerShellAsAdmin',
        'Directory\shell\PowerShell',
        'Directory\shell\PowerShellAdmin',
        'Directory\Background\shell\OpenPowerShellHere',
        'Directory\Background\shell\OpenPowerShellAdmin',
        'Directory\Background\shell\OpenPowerShellAsAdmin',
        'Directory\Background\shell\PowerShell',
        'Directory\Background\shell\PowerShellAdmin'
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
#  Register-PwshContextMenu -- create one registry entry
# --------------------------------------------------------------------------
function Register-PwshContextMenu {
    param(
        [string]$StepLabel,
        [string]$RegistryPath,
        [string]$Label,
        [string]$IconValue,
        [string]$CommandArg,
        [bool]$Runas,
        $LogMessages
    )

    Write-Log ($LogMessages.messages.registerStep -replace '\{step\}', $StepLabel) -Level "info"
    Write-Log ($LogMessages.messages.regPathDetail -replace '\{path\}', $RegistryPath) -Level "info"
    Write-Log ($LogMessages.messages.regLabelDetail -replace '\{label\}', $Label) -Level "info"
    Write-Log ($LogMessages.messages.regIconDetail -replace '\{icon\}', $IconValue) -Level "info"
    Write-Log ($LogMessages.messages.regCommandDetail -replace '\{command\}', $CommandArg) -Level "info"

    $regPath = ConvertTo-PwshRegPath $RegistryPath

    try {
        # Extract HKCR subkey path from the full registry path
        $subKeyPath = $RegistryPath -replace '^Registry::HKEY_CLASSES_ROOT\\', ''
        $hkcr = [Microsoft.Win32.Registry]::ClassesRoot

        # Create key and set (Default) = label
        Write-Log ("  " + ($LogMessages.messages.settingRegistryDefault -replace '\{label\}', $Label)) -Level "info"
        $key = $hkcr.CreateSubKey($subKeyPath)
        $key.SetValue("", $Label)
        $key.Close()
        Write-Log ("  " + $LogMessages.messages.registryDefaultSet) -Level "success"

        # Set Icon
        Write-Log ("  " + ($LogMessages.messages.settingIcon -replace '\{icon\}', $IconValue)) -Level "info"
        $key = $hkcr.OpenSubKey($subKeyPath, $true)
        $key.SetValue("Icon", $IconValue)
        $key.Close()
        Write-Log ("  " + $LogMessages.messages.iconSet) -Level "success"

        # Admin mode: set HasLUAShield for UAC elevation
        if ($Runas) {
            Write-Log ("  " + $LogMessages.messages.settingRunas) -Level "info"
            $key = $hkcr.OpenSubKey($subKeyPath, $true)
            $key.SetValue("HasLUAShield", "")
            $key.Close()
            Write-Log ("  " + $LogMessages.messages.runasSet) -Level "success"
        }

        # Create command subkey with (Default) = command
        Write-Log ("  " + ($LogMessages.messages.settingCommand -replace '\{command\}', $CommandArg)) -Level "info"
        $cmdKey = $hkcr.CreateSubKey("$subKeyPath\command")
        $cmdKey.SetValue("", $CommandArg)
        $cmdKey.Close()

        Write-Log ("  " + $LogMessages.messages.commandSet) -Level "success"
        return $true
    } catch {
        Write-Log ("  " + ($LogMessages.messages.registryFailed -replace '\{error\}', $_)) -Level "error"
        Write-Log ("  " + ($LogMessages.messages.registryStack -replace '\{stack\}', $_.ScriptStackTrace)) -Level "error"
        return $false
    }
}

# --------------------------------------------------------------------------
#  Test-PwshRegistryEntry -- verify a registry path exists
# --------------------------------------------------------------------------
function Test-PwshRegistryEntry {
    param(
        [string]$RegistryPath,
        [string]$Label,
        $LogMessages
    )

    $regPath = ConvertTo-PwshRegPath $RegistryPath
    Write-Log ("  " + ($LogMessages.messages.verifyingEntry -replace '\{path\}', $regPath)) -Level "info"

    $out = reg.exe query $regPath 2>&1
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
#  Invoke-PwshMode -- process one mode (normal or admin)
# --------------------------------------------------------------------------
function Invoke-PwshMode {
    param(
        [PSCustomObject]$Mode,
        [string]$ModeName,
        [string]$PwshExe,
        $LogMessages
    )

    Write-Host ""
    Write-Host $LogMessages.messages.modeBorderLine -ForegroundColor DarkCyan
    Write-Host ($LogMessages.messages.modeLabel -replace '\{label\}', $Mode.contextMenuLabel) -ForegroundColor Cyan
    Write-Host $LogMessages.messages.modeBorderLine -ForegroundColor DarkCyan

    Write-Log ($LogMessages.messages.processingMode -replace '\{mode\}', $ModeName -replace '\{label\}', $Mode.contextMenuLabel) -Level "info"

    $Label   = $Mode.contextMenuLabel
    $IconVal = "`"$PwshExe`""
    $isRunas = if ($Mode.PSObject.Properties['runas']) { $Mode.runas } else { $false }

    $entries = @(
        @{
            Step   = $LogMessages.messages.regDir
            Path   = $Mode.registryPaths.directory
            CmdArg = $Mode.commandArgs.directory -replace '\{exe\}', $PwshExe
        },
        @{
            Step   = $LogMessages.messages.regBg
            Path   = $Mode.registryPaths.background
            CmdArg = $Mode.commandArgs.background -replace '\{exe\}', $PwshExe
        }
    )

    $isAllOk = $true

    # Register entries
    foreach ($entry in $entries) {
        $result = Register-PwshContextMenu `
            -StepLabel  $entry.Step `
            -RegistryPath $entry.Path `
            -Label      $Label `
            -IconValue  $IconVal `
            -CommandArg $entry.CmdArg `
            -Runas      $isRunas `
            -LogMessages $LogMessages
        $hasFailed = -not $result
        if ($hasFailed) { $isAllOk = $false }
    }

    # Verify entries
    Write-Log $LogMessages.messages.verify -Level "info"
    foreach ($entry in $entries) {
        $result = Test-PwshRegistryEntry -RegistryPath $entry.Path -Label $entry.Step -LogMessages $LogMessages
        $hasFailed = -not $result
        if ($hasFailed) { $isAllOk = $false }
    }

    return $isAllOk
}

function Install-PwshParentMenus {
    param(
        [PSCustomObject]$Config,
        [string]$PwshExe,
        $LogMessages
    )

    $parentPaths = Get-PwshParentRegistryPaths -Config $Config
    $iconValue = '"' + $PwshExe + '"'
    $parentLabel = "$($Config.menu.parentLabel)"
    $isAllOk = $true

    foreach ($scope in @('directory', 'background')) {
        $ok = Register-PwshParentMenu -RegistryPath $parentPaths[$scope] -Label $parentLabel -IconValue $iconValue -Runas $false -LogMessages $LogMessages
        if (-not $ok) { $isAllOk = $false }
    }

    return $isAllOk
}

function Uninstall-PwshContextMenu {
    <#
    .SYNOPSIS
        Removes PowerShell context menu entries from registry, purges tracking.
    #>
    param(
        $Config,
        $LogMessages
    )

    # 1. Remove registry entries for each mode
    foreach ($modeName in $Config.enabledModes) {
        $mode = $Config.modes.$modeName
        $isModeValid = $null -ne $mode
        if ($isModeValid) {
            foreach ($scope in @("directory", "background")) {
                $regPath = $mode.registryPaths.$scope
                $isPathValid = -not [string]::IsNullOrWhiteSpace($regPath)
                if ($isPathValid) {
                    $isPresent = Test-Path $regPath
                    if ($isPresent) {
                        Remove-Item -Path $regPath -Recurse -Force
                        Write-Log "Removed registry key: $regPath" -Level "success"
                    }
                }
            }
        }
    }

    if ($Config.PSObject.Properties.Name -contains 'menu') {
        $parentPaths = Get-PwshParentRegistryPaths -Config $Config
        foreach ($scope in @('directory', 'background')) {
            $regPath = $parentPaths[$scope]
            if (Test-Path $regPath) {
                Remove-Item -Path $regPath -Recurse -Force
                Write-Log "Removed registry key: $regPath" -Level "success"
            }
        }
    }

    # 2. Remove tracking records
    Remove-InstalledRecord -Name "pwsh-context-menu"
    Remove-ResolvedData -ScriptFolder "31-pwsh-context-menu"

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
