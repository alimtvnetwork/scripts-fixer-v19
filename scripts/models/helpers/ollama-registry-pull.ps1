# --------------------------------------------------------------------------
#  Standalone Ollama registry puller -- NO ollama daemon / binary required.
#
#  Pulls model weights directly from registry.ollama.ai (Docker-style v2 API)
#  and lays them out under the configured Ollama models dir using the EXACT
#  on-disk layout the Ollama daemon expects:
#     <root>/blobs/sha256-<hex>
#     <root>/manifests/registry.ollama.ai/library/<name>/<tag>
#  so a later `-I 42` install picks the weights up automatically.
#
#  CODE RED: every download/manifest failure logs upstream URL + target path
#  + reason via Write-FileError.
# --------------------------------------------------------------------------

$__modelsHelpersDir = Split-Path -Parent $PSCommandPath
$__scriptsRoot = Split-Path -Parent (Split-Path -Parent $__modelsHelpersDir)
$__sharedDir = Join-Path $__scriptsRoot "shared"

$__loggingPath = Join-Path $__sharedDir "logging.ps1"
if ((Test-Path $__loggingPath) -and -not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . $__loggingPath
}

$__fastDownloadPath = Join-Path $__sharedDir "fast-download.ps1"
if ((Test-Path $__fastDownloadPath) -and -not (Get-Command Invoke-FastDownload -ErrorAction SilentlyContinue)) {
    . $__fastDownloadPath
}

function _Parse-OllamaSlug {
    param([Parameter(Mandatory)] [string]$Slug)
    $s = $Slug.Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    # Default registry path is "library/<name>" for unscoped slugs.
    $name = $s
    $tag  = "latest"
    if ($s -match '^([^:]+):([^:]+)$') {
        $name = $Matches[1]
        $tag  = $Matches[2]
    }
    if ($name -notmatch '/') { $name = "library/$name" }
    return [PSCustomObject]@{ Name = $name; Tag = $tag; Display = "${name}:${tag}" }
}

function _Download-OllamaBlob {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Target,
        [string]$ExpectedSha256
    )
    $dir = Split-Path -Parent $Target
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (Test-Path $Target -PathType Leaf) {
        if ($ExpectedSha256) {
            try {
                $have = (Get-FileHash -Algorithm SHA256 -LiteralPath $Target).Hash.ToLower()
                if ($have -eq $ExpectedSha256.ToLower()) { return $true }
                Write-Log "Existing blob hash mismatch, re-downloading: $Target" -Level "warn"
                Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
            } catch {}
        } else {
            return $true
        }
    }

    $tmp  = "$Target.part"
    try {
        $label = "ollama blob $(Split-Path -Leaf $Target)"
        $ok = Invoke-FastDownload -Uri $Url -OutFile $tmp -Label $label
        if (-not $ok) { throw "downloaded file not found at $tmp" }

        if ($ExpectedSha256) {
            $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLower()
            if ($got -ne $ExpectedSha256.ToLower()) {
                throw "sha256 mismatch (expected $ExpectedSha256, got $got)"
            }
        }
        Move-Item -LiteralPath $tmp -Destination $Target -Force
        return $true
    } catch {
        $reason = "$_"
        if (Get-Command Write-FileError -ErrorAction SilentlyContinue) {
            Write-FileError -FilePath $Target -Operation "download-attempt" -Reason $reason -Module "_Download-OllamaBlob" `
                -Context @{ downloadUrl = $Url; outputPath = $Target; tempPath = $tmp; downloader = "Invoke-FastDownload (aria2c-first)" }
        } else {
            Write-Log ("Blob download failed -- url={0} target={1} reason={2}" -f $Url, $Target, $reason) -Level "error"
        }
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Invoke-OllamaRegistryPull {
    <#
    .SYNOPSIS
        Pulls one or more Ollama models directly from registry.ollama.ai
        WITHOUT requiring the ollama daemon or CLI to be installed.
    #>
    param(
        [Parameter(Mandatory)] [string[]]$Slugs,
        [Parameter(Mandatory)] [string]$TargetRoot
    )

    $pickerPath = Join-Path $__modelsHelpersDir "picker.ps1"
    if (-not (Get-Command Resolve-StandaloneDownloadModels -ErrorAction SilentlyContinue) -and (Test-Path $pickerPath)) {
        . $pickerPath
    }

    $configPath = Join-Path (Join-Path $__scriptsRoot "models") "config.json"
    if (-not (Test-Path $configPath)) {
        Write-FileError -FilePath $configPath -Operation "load-config" -Reason "models orchestrator config.json not found" -Module "Invoke-OllamaRegistryPull"
        return $false
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $pseudoModels = @()
    foreach ($slug in $Slugs) {
        if (-not [string]::IsNullOrWhiteSpace("$slug")) {
            $pseudoModels += [PSCustomObject]@{
                id = "$slug"
                displayName = "$slug"
                backend = "ollama"
                raw = $null
            }
        }
    }

    $resolved = @(Resolve-StandaloneDownloadModels -Models $pseudoModels -Config $config -ScriptsRoot $__scriptsRoot -OutputRoot $TargetRoot | Where-Object { $null -ne $_ })
    if ($resolved.Count -eq 0) {
        Write-Log "No standalone GGUF downloads could be resolved from legacy Ollama slugs." -Level "error"
        return $false
    }

    Write-Log "[compat] Legacy Ollama registry helper rerouted to standalone GGUF download." -Level "info"
    return (Invoke-StandaloneGgufDownload -Models $resolved -Config $config -ScriptsRoot $__scriptsRoot)
}
