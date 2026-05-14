# scripts/43-install-llama-cpp/tests/models-download-no-binaries.test.ps1
# -----------------------------------------------------------------------------
# Smoke test for the HARD GUARD that prevents 'models-download' from
# triggering llama.cpp binary installation.
#
# Layer 1: Install-LlamaCppExecutables must throw "HARD GUARD TRIPPED" when
#          MODELS_DOWNLOAD_NO_BINARIES=1 is set in the environment.
# Layer 2: scripts/models/helpers/picker.ps1 snapshots the llama.cpp dev
#          dir, sets the sentinel, runs the puller, and post-diffs for
#          leaked llama-*.exe / *.dll / *.zip files.
#
# Run on Windows:
#     Install-Module Pester -Scope CurrentUser -Force   # one-time
#     Invoke-Pester scripts\43-install-llama-cpp\tests\models-download-no-binaries.test.ps1
# -----------------------------------------------------------------------------
#Requires -Version 5.1

BeforeAll {
    $script:TestDir   = Split-Path -Parent $PSCommandPath
    $script:ScriptDir = Split-Path -Parent $script:TestDir
    $script:RepoRoot  = Split-Path -Parent (Split-Path -Parent $script:ScriptDir)
    $script:SharedDir = Join-Path $script:RepoRoot "scripts\shared"

    . (Join-Path $script:SharedDir "logging.ps1")
    . (Join-Path $script:SharedDir "file-error.ps1")
    . (Join-Path $script:ScriptDir "helpers\llama-cpp.ps1")

    Initialize-Logging -ScriptName "hard-guard-test"
}

Describe "models-download HARD GUARD: Install-LlamaCppExecutables" {

    It "throws 'HARD GUARD TRIPPED' when MODELS_DOWNLOAD_NO_BINARIES=1" {
        $env:MODELS_DOWNLOAD_NO_BINARIES = "1"
        try {
            $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("hg-" + [guid]::NewGuid().ToString("N").Substring(0,8))
            New-Item -Path $sandbox -ItemType Directory -Force | Out-Null

            $cfg  = [pscustomobject]@{ executables = @(); path = [pscustomobject]@{} }
            $logs = [pscustomobject]@{ messages = [pscustomobject]@{ hardwareDetecting = "hw"; } }

            { Install-LlamaCppExecutables -Config $cfg -LogMessages $logs -BaseDir $sandbox } |
                Should -Throw "*HARD GUARD TRIPPED*"
        }
        finally {
            Remove-Item Env:\MODELS_DOWNLOAD_NO_BINARIES -ErrorAction SilentlyContinue
            if ($sandbox -and (Test-Path $sandbox)) {
                Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does NOT throw when MODELS_DOWNLOAD_NO_BINARIES is unset (config still drives behavior)" {
        Remove-Item Env:\MODELS_DOWNLOAD_NO_BINARIES -ErrorAction SilentlyContinue
        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("hg-" + [guid]::NewGuid().ToString("N").Substring(0,8))
        New-Item -Path $sandbox -ItemType Directory -Force | Out-Null
        try {
            # Empty executables list -> the function is a no-op past the guard.
            $cfg  = [pscustomobject]@{ executables = @(); path = [pscustomobject]@{} }
            $logs = [pscustomobject]@{ messages = [pscustomobject]@{ hardwareDetecting = "hw"; } }
            { Install-LlamaCppExecutables -Config $cfg -LogMessages $logs -BaseDir $sandbox } |
                Should -Not -Throw
        }
        finally {
            Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "models-download HARD GUARD: post-run binary-leak diff (picker.ps1)" {

    It "detects a fake llama-cli.exe that lands in the dev-tool dir" {
        # Simulate the picker's snapshot/diff logic standalone.
        $devDir  = Join-Path ([IO.Path]::GetTempPath()) ("hg-leak-" + [guid]::NewGuid().ToString("N").Substring(0,8))
        $baseDir = Join-Path $devDir "llama-cpp"
        New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
        try {
            $before = @{}
            Get-ChildItem -LiteralPath $baseDir -Recurse -ErrorAction SilentlyContinue `
                -Include "llama-*.exe","*.dll","*.zip" |
                ForEach-Object { $before[$_.FullName] = $_.Length }

            # Simulate a leak: a fake binary appears mid-run.
            $leakFile = Join-Path $baseDir "llama-cli.exe"
            "stub" | Set-Content -Path $leakFile -NoNewline

            $newBinaries = @()
            $afterFiles = Get-ChildItem -LiteralPath $baseDir -Recurse -ErrorAction SilentlyContinue `
                -Include "llama-*.exe","*.dll","*.zip"
            foreach ($f in $afterFiles) {
                $isNew  = -not $before.ContainsKey($f.FullName)
                $isGrew = $before.ContainsKey($f.FullName) -and ($before[$f.FullName] -ne $f.Length)
                if ($isNew -or $isGrew) { $newBinaries += $f.FullName }
            }

            $newBinaries.Count | Should -Be 1
            $newBinaries[0]    | Should -Match "llama-cli\.exe$"
        }
        finally {
            Remove-Item $devDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports zero new binaries when the dev-tool dir is untouched" {
        $devDir  = Join-Path ([IO.Path]::GetTempPath()) ("hg-clean-" + [guid]::NewGuid().ToString("N").Substring(0,8))
        $baseDir = Join-Path $devDir "llama-cpp"
        New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
        try {
            $before = @{}
            Get-ChildItem -LiteralPath $baseDir -Recurse -ErrorAction SilentlyContinue `
                -Include "llama-*.exe","*.dll","*.zip" |
                ForEach-Object { $before[$_.FullName] = $_.Length }

            # No files added.
            $newBinaries = @()
            $afterFiles = Get-ChildItem -LiteralPath $baseDir -Recurse -ErrorAction SilentlyContinue `
                -Include "llama-*.exe","*.dll","*.zip"
            foreach ($f in $afterFiles) {
                if (-not $before.ContainsKey($f.FullName)) { $newBinaries += $f.FullName }
            }

            $newBinaries.Count | Should -Be 0
        }
        finally {
            Remove-Item $devDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
