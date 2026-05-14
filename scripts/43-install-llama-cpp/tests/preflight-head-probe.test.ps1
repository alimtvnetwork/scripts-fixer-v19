# scripts/43-install-llama-cpp/tests/preflight-head-probe.test.ps1
# -----------------------------------------------------------------------------
# Smoke test for the pre-batch HEAD preflight in Install-SelectedModels.
# Uses Pester 5+ Mock to stub Invoke-WebRequest and Invoke-FastDownload so we
# never touch the network or disk.
#
# Run on Windows:
#     Install-Module Pester -Scope CurrentUser -Force   # one-time
#     Invoke-Pester scripts\43-install-llama-cpp\tests\preflight-head-probe.test.ps1
# -----------------------------------------------------------------------------
#Requires -Version 5.1

BeforeAll {
    $script:TestDir   = Split-Path -Parent $PSCommandPath
    $script:ScriptDir = Split-Path -Parent $script:TestDir
    $script:RepoRoot  = Split-Path -Parent (Split-Path -Parent $script:ScriptDir)
    $script:SharedDir = Join-Path $script:RepoRoot "scripts\shared"

    # Dot-source dependencies in this scope.
    . (Join-Path $script:SharedDir "logging.ps1")
    . (Join-Path $script:SharedDir "file-error.ps1")
    . (Join-Path $script:SharedDir "download-retry.ps1")
    . (Join-Path $script:SharedDir "aria2c-download.ps1")
    . (Join-Path $script:SharedDir "aria2c-batch.ps1")
    . (Join-Path $script:ScriptDir "helpers\model-picker.ps1")

    Initialize-Logging -ScriptName "preflight-test"
}

Describe "Install-SelectedModels pre-batch HEAD preflight" {

    BeforeEach {
        $script:Sandbox  = Join-Path ([IO.Path]::GetTempPath()) ("prefl-" + [guid]::NewGuid().ToString("N").Substring(0,8))
        New-Item -Path $script:Sandbox -ItemType Directory -Force | Out-Null

        $script:Models = @(
            [pscustomobject]@{
                index         = 1
                id            = "good-id"
                displayName   = "Good entry"
                fileName      = "good.gguf"
                downloadUrl   = "https://example.invalid/good.gguf"
                fileSizeGB    = 0.001
                ramRequiredGB = 1
                parameters    = "1B"
                quantization  = "Q4_K_M"
                bestFor       = "test"
            },
            [pscustomobject]@{
                index         = 2
                id            = "bad-id"
                displayName   = "Bad entry (fictional)"
                fileName      = "bad.gguf"
                downloadUrl   = "https://example.invalid/bad.gguf"
                fileSizeGB    = 0.001
                ramRequiredGB = 1
                parameters    = "1B"
                quantization  = "Q4_K_M"
                bestFor       = "test"
            }
        )

        # Mock: HEAD probes return 200 for /good, 404 for /bad.
        Mock Invoke-WebRequest {
            param($Uri, $Method, $MaximumRedirection, $TimeoutSec, $UseBasicParsing, $ErrorAction)
            if ($Uri -match "/bad\.gguf$") {
                $resp  = [System.Net.HttpWebResponse]::new
                $err   = New-Object System.Exception "404 Not Found"
                $exObj = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = 404 } }
                throw ([System.Management.Automation.ErrorRecord]::new(
                    $err, "404", "ProtocolError", $exObj))
            }
            return [pscustomobject]@{ StatusCode = 200 }
        }

        # Mock: Invoke-FastDownload records every call so we can assert no leak.
        $script:DownloadCalls = New-Object System.Collections.ArrayList
        Mock Invoke-FastDownload {
            param($Uri, $OutFile, $Splits, $PieceSize, $Label)
            [void]$script:DownloadCalls.Add($Uri)
            New-Item -Path $OutFile -ItemType File -Force | Out-Null
            return $true
        }

        # Disable parallel batch so we exercise the per-file path predictably,
        # but the pre-batch preflight runs regardless.
        $script:Aria2Cfg    = [pscustomobject]@{
            maxConnections = 4; maxDownloads = 4; chunkSize = "1M"; continueDownload = $true
        }
        $script:DownloadCfg = [pscustomobject]@{
            parallelEnabled = $false; requireChecksum = $false
        }
        $script:LogMsgs = [pscustomobject]@{ messages = [pscustomobject]@{ csvUnknown = "{id} unknown" } }
    }

    AfterEach {
        Remove-Item -Path $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "probes BOTH urls before any download starts" {
        Install-SelectedModels -Models $script:Models -SelectedIndices @(1,2) `
            -ModelsDir $script:Sandbox -Aria2Config $script:Aria2Cfg `
            -DownloadConfig $script:DownloadCfg -LogMessages $script:LogMsgs *> $null

        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Uri -like "*good.gguf" }
        Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $Uri -like "*bad.gguf"  }
    }

    It "downloads ONLY the good entry (no leak for bad-id)" {
        Install-SelectedModels -Models $script:Models -SelectedIndices @(1,2) `
            -ModelsDir $script:Sandbox -Aria2Config $script:Aria2Cfg `
            -DownloadConfig $script:DownloadCfg -LogMessages $script:LogMsgs *> $null

        $script:DownloadCalls | Should -Contain "https://example.invalid/good.gguf"
        $script:DownloadCalls | Should -Not -Contain "https://example.invalid/bad.gguf"
    }

    It "emits the '404 Not Found' + ACTION line for the bad entry" {
        $output = Install-SelectedModels -Models $script:Models -SelectedIndices @(1,2) `
            -ModelsDir $script:Sandbox -Aria2Config $script:Aria2Cfg `
            -DownloadConfig $script:DownloadCfg -LogMessages $script:LogMsgs *>&1 | Out-String

        $output | Should -Match "404 Not Found"
        $output | Should -Match "ACTION: remove or correct this entry"
        $output | Should -Match "bad-id"
    }

    It "does not call the downloader at all when EVERY entry fails preflight" {
        # Force every URL to 404
        Mock Invoke-WebRequest {
            $err = New-Object System.Exception "404"
            $exObj = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = 404 } }
            throw ([System.Management.Automation.ErrorRecord]::new($err,"404","ProtocolError",$exObj))
        }
        Install-SelectedModels -Models $script:Models -SelectedIndices @(1,2) `
            -ModelsDir $script:Sandbox -Aria2Config $script:Aria2Cfg `
            -DownloadConfig $script:DownloadCfg -LogMessages $script:LogMsgs *> $null

        Should -Invoke Invoke-FastDownload -Times 0
    }
}
