# --------------------------------------------------------------------------
#  Models uninstall -- enumerate locally installed GGUF + Ollama models,
#  multi-select, delete via each backend's natural removal path.
#  Used by `.\run.ps1 models uninstall` (see spec/models/readme.md).
# --------------------------------------------------------------------------

function Get-InstalledLlamaCppModels {
    <#
    .SYNOPSIS
        Returns array of locally installed llama.cpp GGUF models. Sources of truth:
          1. .installed/model-*.json  -- saved by Install-SelectedModels
          2. Cross-reference with catalog (43-install-llama-cpp/models-catalog.json)
             to recover fileName + display name.
        Also reports whether the GGUF file is still on disk.
    #>
    param(
        [Parameter(Mandatory)] [string]$ScriptsRoot,
        [Parameter(Mandatory)] [string]$ProjectRoot
    )

    $installedDir = Join-Path $ProjectRoot ".installed"
    $catalogPath  = Join-Path $ScriptsRoot "43-install-llama-cpp\models-catalog.json"
    $resolvedPath = Join-Path $ProjectRoot ".resolved\43-install-llama-cpp.json"

    $hasInstalledDir = Test-Path $installedDir
    if (-not $hasInstalledDir) { return @() }

    $hasCatalog = Test-Path $catalogPath
    $catalog = $null
    if ($hasCatalog) {
        $catalog = (Get-Content $catalogPath -Raw | ConvertFrom-Json).models
    }

    # Resolve where the GGUF files live. Prefer .resolved entry, fall back to
    # default subfolder under DEV_DIR / current dir.
    $modelsDir = $null
    if (Test-Path $resolvedPath) {
        $resolved = Get-Content $resolvedPath -Raw | ConvertFrom-Json
        if ($resolved.baseDir) {
            $modelsDir = Join-Path (Split-Path -Parent $resolved.baseDir) "models"
        }
    }
    if (-not $modelsDir -and $env:DEV_DIR) {
        $modelsDir = Join-Path $env:DEV_DIR "models"
    }

    $records = Get-ChildItem -Path $installedDir -Filter "model-*.json" -ErrorAction SilentlyContinue
    $results = @()
    foreach ($rec in $records) {
        $data = Get-Content $rec.FullName -Raw | ConvertFrom-Json
        $name = $data.name  # e.g. "model-qwen2.5-coder-3b"
        $id   = $name -replace '^model-', ''

        # Cross-ref catalog for filename + display name
        $displayName = $id
        $fileName    = $null
        $sizeGB      = $null
        if ($catalog) {
            $hit = $catalog | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if ($hit) {
                $displayName = $hit.displayName
                $fileName    = $hit.fileName
                $sizeGB      = $hit.fileSizeGB
            }
        }

        $filePath = $null
        $isPresent = $false
        if ($fileName -and $modelsDir) {
            $filePath = Join-Path $modelsDir $fileName
            $isPresent = Test-Path $filePath
        }

        $results += [PSCustomObject]@{
            backend      = "llama-cpp"
            id           = $id
            displayName  = $displayName
            fileName     = $fileName
            filePath     = $filePath
            isFilePresent= $isPresent
            sizeGB       = $sizeGB
            trackingFile = $rec.FullName
            trackingName = $name
            installedAt  = $data.installedAt
        }
    }
    return $results
}

function Get-InstalledOllamaModels {
    <#
    .SYNOPSIS
        Runs `ollama list` and parses its tabular output. Returns one entry
        per locally cached Ollama model. Returns @() when ollama is missing
        or the daemon isn't reachable -- never throws.
    #>
    $hasOllama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $hasOllama) { return @() }

    $raw = $null
    try {
        $raw = & ollama list 2>&1
    } catch {
        Write-Log "ollama list failed: $_" -Level "warn"
        return @()
    }

    $isExitOk = $LASTEXITCODE -eq 0
    if (-not $isExitOk) {
        Write-Log "ollama list returned exit code $LASTEXITCODE -- daemon may be down." -Level "warn"
        return @()
    }

    $lines = @($raw -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    $hasRows = $lines.Count -gt 1
    if (-not $hasRows) { return @() }

    # Skip header row (NAME ID SIZE MODIFIED). Columns are space-padded; split on 2+ spaces.
    $results = @()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $cols = $lines[$i] -split '\s{2,}' | Where-Object { $_.Length -gt 0 }
        if ($cols.Count -lt 2) { continue }
        $results += [PSCustomObject]@{
            backend     = "ollama"
            id          = $cols[0]            # e.g. "llama3.2:latest"
            displayName = $cols[0]
            ollamaId    = if ($cols.Count -ge 2) { $cols[1] } else { "" }
            sizeStr     = if ($cols.Count -ge 3) { $cols[2] } else { "" }
            modified    = if ($cols.Count -ge 4) { ($cols[3..($cols.Count-1)] -join ' ') } else { "" }
        }
    }
    return $results
}

function Show-UninstallList {
    <#
    .SYNOPSIS
        Renders combined backend listing as a numbered table.
    #>
    param([Parameter(Mandatory)] [array]$All)

    Write-Host ""
    Write-Host "  Locally installed models: $($All.Count)" -ForegroundColor Cyan
    Write-Host ""

    $colNum  = 5
    $colBack = 10
    $colId   = 38
    $colSize = 10
    $colNote = 30

    Write-Host ("  {0,-$colNum} {1,-$colBack} {2,-$colId} {3,-$colSize} {4}" -f "#", "Backend", "Id / Tag", "Size", "Status") -ForegroundColor Yellow
    Write-Host ("  " + ("-" * 100)) -ForegroundColor DarkGray

    $idx = 1
    foreach ($m in $All) {
        $id = $m.id
        if ($id.Length -gt ($colId - 2)) { $id = $id.Substring(0, $colId - 4) + ".." }

        $size = ""
        $note = ""
        $color = "White"
        if ($m.backend -eq "llama-cpp") {
            $size = if ($m.sizeGB) { "$($m.sizeGB) GB" } else { "?" }
            if ($m.isFilePresent) {
                $note = "GGUF on disk"
            } elseif ($m.filePath) {
                $note = "tracked but file missing"
                $color = "DarkYellow"
            } else {
                $note = "tracked (path unknown)"
                $color = "DarkYellow"
            }
        } else {
            $size = $m.sizeStr
            $note = "ollama daemon"
            $color = "Cyan"
        }

        Write-Host ("  {0,-$colNum} {1,-$colBack} {2,-$colId} {3,-$colSize} {4}" -f "[$idx]", $m.backend, $id, $size, $note) -ForegroundColor $color
        $idx++
    }
    Write-Host ""
}

function Read-UninstallSelection {
    <#
    .SYNOPSIS
        Prompts user to multi-select indices to uninstall.
        Supports: 1,3 | 1-5 | all | q (quit) | empty (skip).
        Returns array of 1-based indices, or $null when user quits.
    #>
    param([int]$MaxIndex)

    Write-Host "  Select models to UNINSTALL:" -ForegroundColor Cyan
    Write-Host "    Examples: 1,3,5  |  1-3  |  all  |  [Enter] cancel  |  q quit" -ForegroundColor DarkGray
    Write-Host ""
    $input = Read-Host -Prompt "  Your selection"
    $trimmed = $input.Trim().ToLower()

    $isEmpty = [string]::IsNullOrWhiteSpace($trimmed)
    if ($isEmpty) { return @() }
    if ($trimmed -eq "q" -or $trimmed -eq "quit") { return $null }
    if ($trimmed -eq "all") { return @(1..$MaxIndex) }

    $picks = @()
    foreach ($part in ($trimmed -split ",")) {
        $part = $part.Trim()
        if ($part -match "^(\d+)\s*-\s*(\d+)$") {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $a, $b = $b, $a }
            for ($i = $a; $i -le $b; $i++) {
                if ($i -ge 1 -and $i -le $MaxIndex) { $picks += $i }
            }
        } elseif ($part -match "^\d+$") {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $MaxIndex) { $picks += $n }
        }
    }
    return ($picks | Sort-Object -Unique)
}

function Confirm-Uninstall {
    <#
    .SYNOPSIS
        Final confirmation prompt. Returns $true if user confirms.
    #>
    param([Parameter(Mandatory)] [array]$Targets)

    Write-Host ""
    Write-Host "  About to uninstall $($Targets.Count) model(s):" -ForegroundColor Yellow
    foreach ($t in $Targets) {
        Write-Host "    [$($t.backend)] $($t.id)" -ForegroundColor DarkYellow
    }
    Write-Host ""
    $answer = Read-Host -Prompt "  Type 'yes' to confirm (anything else cancels)"
    return ($answer.Trim().ToLower() -eq "yes")
}

function Invoke-ModelUninstall {
    <#
    .SYNOPSIS
        Deletes the selected models. For llama.cpp: removes the GGUF file
        and the .installed/model-<id>.json tracking record. For Ollama:
        runs `ollama rm <id>`.
        Logs success/failure per item, returns counts.
    #>
    param([Parameter(Mandatory)] [array]$Targets)

    $okCount   = 0
    $failCount = 0

    foreach ($t in $Targets) {
        try {
            if ($t.backend -eq "llama-cpp") {
                # 1. Delete the GGUF file if present
                $isFileThere = $t.isFilePresent -and $t.filePath
                if ($isFileThere) {
                    Write-Log "  Removing GGUF: $($t.filePath)" -Level "info"
                    Remove-Item -Path $t.filePath -Force -ErrorAction Stop
                } elseif ($t.filePath) {
                    Write-Log "  GGUF file already missing: $($t.filePath)" -Level "info"
                }

                # 2. Drop the .installed/ tracking record (uses shared helper)
                Remove-InstalledRecord -Name $t.trackingName | Out-Null

                Write-Log "  [OK] llama-cpp/$($t.id) uninstalled." -Level "success"
                $okCount++
            }
            elseif ($t.backend -eq "ollama") {
                Write-Log "  ollama rm $($t.id)" -Level "info"
                $output = & ollama rm $t.id 2>&1
                $isOk = $LASTEXITCODE -eq 0
                if ($isOk) {
                    Write-Log "  [OK] ollama/$($t.id) uninstalled." -Level "success"
                    $okCount++
                } else {
                    Write-Log "  [FAIL] ollama rm exit $LASTEXITCODE -- $output" -Level "error"
                    $failCount++
                }
            }
        } catch {
            Write-Log "  [FAIL] $($t.backend)/$($t.id): $_" -Level "error"
            $failCount++
        }
    }

    Write-Host ""
    Write-Log "Uninstall summary: $okCount succeeded, $failCount failed (of $($Targets.Count) selected)." -Level "info"
    return @{ Ok = $okCount; Fail = $failCount }
}
