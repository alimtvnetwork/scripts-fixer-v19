<# Bucket G: steam-shader -- <SteamLibrary>\steamapps\shadercache #>
param([switch]$DryRun, [switch]$Yes, [int]$Days = 30, [hashtable]$SharedResult)

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "_sweep.ps1")

$result = New-CleanResult -Category "steam-shader" -Label "Steam shader cache" -Bucket "G"

# Per-step failure ledger -- captured here and surfaced in $result.Notes so the
# caller's summary block prints exactly which step failed, on which path, and
# with which exception message. CODE RED: every file/path failure logs path + reason.
$stepFailures = New-Object System.Collections.Generic.List[hashtable]

function Add-StepFailure {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason
    )
    $stepFailures.Add(@{ Step = $Step; Path = $Path; Reason = $Reason }) | Out-Null
    Write-Log "steam-shader [$Step] FAIL path=$Path reason=$Reason" -Level "fail"
}

# ---------- Step 1: discover Steam install candidates ----------------------
$candidates = @(
    "C:\Program Files (x86)\Steam",
    "C:\Program Files\Steam",
    (Join-Path (Get-LocalAppDataPath) "Steam")
)

$libraries = New-Object System.Collections.Generic.List[string]
foreach ($c in $candidates) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    if (-not (Test-Path -LiteralPath $c)) { continue }
    $libraries.Add($c) | Out-Null

    # ---------- Step 2: parse libraryfolders.vdf for additional libraries --
    $vdf = Join-Path $c "steamapps\libraryfolders.vdf"
    if (-not (Test-Path -LiteralPath $vdf)) {
        $result.Notes += "vdf-missing: $vdf"
        continue
    }
    try {
        $content = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
    } catch {
        Add-StepFailure -Step "read-vdf" -Path $vdf -Reason $_.Exception.Message
        continue
    }
    try {
        $rxMatches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
        foreach ($m in $rxMatches) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-Path -LiteralPath $p) {
                $libraries.Add($p) | Out-Null
            } else {
                Add-StepFailure -Step "library-missing" -Path $p `
                    -Reason "library declared in $vdf does not exist on disk"
            }
        }
    } catch {
        Add-StepFailure -Step "parse-vdf" -Path $vdf -Reason $_.Exception.Message
    }
}

$libraries = @($libraries | Select-Object -Unique)
if ($libraries.Count -eq 0) {
    $result.Notes += "Steam not installed (no candidate paths matched)"
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
    return $result
}

# ---------- Step 3: sweep each shadercache --------------------------------
# In --dry-run mode we pre-compute file count, dir count and total bytes for
# EACH library's shadercache and surface them to the user BEFORE handing off
# to Invoke-PathSweep. This makes the preview self-explanatory:
#   [dry-run] G:\Steam\steamapps\shadercache files=1842 dirs=37 bytes=432681234 (412.62 MB)
$sweptCount = 0
foreach ($lib in $libraries) {
    $sc = Join-Path $lib "steamapps\shadercache"
    if (-not (Test-Path -LiteralPath $sc)) {
        $result.Notes += "shadercache-absent: $sc"
        continue
    }

    if ($DryRun) {
        try {
            $allItems = @(Get-ChildItem -LiteralPath $sc -Recurse -Force -ErrorAction SilentlyContinue)
            $files    = @($allItems | Where-Object { -not $_.PSIsContainer })
            $dirs     = @($allItems | Where-Object {  $_.PSIsContainer })
            $bytes    = ($files | Measure-Object -Property Length -Sum).Sum
            if ($null -eq $bytes) { $bytes = 0 }
            $mb = [Math]::Round($bytes / 1MB, 2)
            $line = "[dry-run] $sc files=$($files.Count) dirs=$($dirs.Count) bytes=$bytes ($mb MB)"
            $result.Notes += $line
            Write-Log "steam-shader $line" -Level "info"
        } catch {
            Add-StepFailure -Step "dry-run-scan" -Path $sc -Reason $_.Exception.Message
            continue
        }
    }

    try {
        Invoke-PathSweep -Path $sc -Result $result -DryRun:$DryRun -LogPrefix "steam-shader"
        $sweptCount++
    } catch {
        Add-StepFailure -Step "sweep" -Path $sc -Reason $_.Exception.Message
    }
}

# ---------- Step 4: emit detailed failure summary into result.Notes -------
if ($stepFailures.Count -gt 0) {
    $result.Notes += "----- steam-shader failure summary ($($stepFailures.Count) item(s)) -----"
    foreach ($f in $stepFailures) {
        $result.Notes += ("  [{0}] path={1}" -f $f.Step, $f.Path)
        $result.Notes += ("        reason: {0}" -f $f.Reason)
    }
    # Promote to warn if any step failed but we still swept something; fail if nothing swept.
    if ($sweptCount -eq 0) {
        $result.Status = "fail"
    } elseif ($result.Status -eq "ok") {
        $result.Status = "warn"
    }
} else {
    Set-CleanResultStatus -Result $result -DryRun:$DryRun
}

return $result
