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

    $aria = Get-Command aria2c -ErrorAction SilentlyContinue
    $tmp  = "$Target.part"
    $ok   = $false
    try {
        if ($aria) {
            $args = @("-x","16","-s","16","-k","1M","--continue=true",
                      "--auto-file-renaming=false","--allow-overwrite=true",
                      "-d", $dir, "-o", (Split-Path -Leaf $tmp), $Url)
            & aria2c @args | Out-Null
            $ok = (Test-Path $tmp)
        } else {
            Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            $ok = (Test-Path $tmp)
        }
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
            Write-FileError -Operation "download-attempt" -Path $Target -Reason $reason `
                -Context @{ downloadUrl = $Url; outputPath = $Target }
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

    $registry = "https://registry.ollama.ai"
    $accept   = "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"

    if (-not (Test-Path $TargetRoot)) {
        try {
            New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
        } catch {
            Write-FileError -Operation "create-dir" -Path $TargetRoot -Reason "$_" `
                -Context @{ outputPath = $TargetRoot }
            throw
        }
    }
    $blobsDir = Join-Path $TargetRoot "blobs"
    if (-not (Test-Path $blobsDir)) { New-Item -ItemType Directory -Path $blobsDir -Force | Out-Null }

    $allOk = $true

    foreach ($rawSlug in $Slugs) {
        $parsed = _Parse-OllamaSlug -Slug $rawSlug
        if (-not $parsed) { continue }

        $manifestUrl  = "$registry/v2/$($parsed.Name)/manifests/$($parsed.Tag)"
        $manifestDir  = Join-Path $TargetRoot ("manifests\registry.ollama.ai\" + ($parsed.Name -replace '/','\'))
        $manifestPath = Join-Path $manifestDir $parsed.Tag

        Write-Log ("[ollama] Pulling {0} from {1}" -f $parsed.Display, $manifestUrl) -Level "info"

        try {
            $resp = Invoke-WebRequest -Uri $manifestUrl -Headers @{ Accept = $accept } `
                        -UseBasicParsing -ErrorAction Stop
            $manifestText = $resp.Content
            $manifest = $manifestText | ConvertFrom-Json
        } catch {
            $reason = "$_"
            Write-FileError -Operation "fetch-manifest" -Path $manifestPath -Reason $reason `
                -Context @{
                    requestedInput     = $rawSlug
                    requestedModelName = $parsed.Display
                    modelUrl           = $manifestUrl
                    outputPath         = $manifestPath
                    failureReason      = $reason
                }
            Write-Log ("  >> Failed to fetch manifest. Model: {0}  URL: {1}  Reason: {2}" -f $parsed.Display, $manifestUrl, $reason) -Level "error"
            $allOk = $false
            continue
        }

        # Collect blob digests (config + layers).
        $digests = New-Object System.Collections.Generic.List[string]
        if ($manifest.config -and $manifest.config.digest) { $digests.Add($manifest.config.digest) }
        if ($manifest.layers) {
            foreach ($layer in $manifest.layers) {
                if ($layer.digest) { $digests.Add($layer.digest) }
            }
        }

        $modelOk = $true
        foreach ($d in $digests) {
            # digest format: "sha256:<hex>" -- on-disk filename is "sha256-<hex>"
            $hex = ($d -replace '^sha256:', '')
            $blobFile = Join-Path $blobsDir ("sha256-" + $hex)
            $blobUrl  = "$registry/v2/$($parsed.Name)/blobs/$d"
            Write-Log ("[ollama] blob {0} -> {1}" -f $d, $blobFile) -Level "info"
            $ok = _Download-OllamaBlob -Url $blobUrl -Target $blobFile -ExpectedSha256 $hex
            if (-not $ok) {
                $modelOk = $false
                Write-Log ("  >> Blob download failed. Model: {0}  URL: {1}  Target: {2}" -f $parsed.Display, $blobUrl, $blobFile) -Level "error"
            }
        }

        if ($modelOk) {
            try {
                if (-not (Test-Path $manifestDir)) { New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null }
                Set-Content -LiteralPath $manifestPath -Value $manifestText -Encoding UTF8
                Write-Log ("[ollama]   manifest saved: {0}" -f $manifestPath) -Level "success"
                Write-Log ("[ollama] {0} -- complete (standalone, no daemon)" -f $parsed.Display) -Level "success"
            } catch {
                $reason = "$_"
                Write-FileError -Operation "write-manifest" -Path $manifestPath -Reason $reason `
                    -Context @{ modelUrl = $manifestUrl; outputPath = $manifestPath }
                $allOk = $false
            }
        } else {
            $allOk = $false
            Write-Log ("[ollama] {0} -- INCOMPLETE (one or more blobs failed)" -f $parsed.Display) -Level "error"
        }
    }

    return $allOk
}
