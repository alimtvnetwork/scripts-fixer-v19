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
#  Uninstall-ConEmuContextMenu -- remove registry entries + tracking
# --------------------------------------------------------------------------
function Uninstall-ConEmuContextMenu {
    param(
        $Config,
        $LogMessages
    )

    foreach ($modeName in $Config.enabledModes) {
        $mode = $Config.modes.$modeName
        if ($null -eq $mode) { continue }
        foreach ($scope in @("directory", "background")) {
            $regPath = $mode.registryPaths.$scope
            if ([string]::IsNullOrWhiteSpace($regPath)) { continue }
            $isPresent = Test-Path $regPath
            if ($isPresent) {
                Remove-Item -Path $regPath -Recurse -Force
                Write-Log "Removed registry key: $regPath" -Level "success"
            }
        }
    }

    if (Get-Command Remove-InstalledRecord -ErrorAction SilentlyContinue) {
        Remove-InstalledRecord -Name "conemu-context-menu"
    }
    if (Get-Command Remove-ResolvedData -ErrorAction SilentlyContinue) {
        Remove-ResolvedData -ScriptFolder "59-conemu-context-menu"
    }

    Write-Log $LogMessages.messages.uninstallComplete -Level "success"
}
