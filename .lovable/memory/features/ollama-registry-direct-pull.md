---
name: Ollama standalone registry pull
description: models-download fetches Ollama models directly from registry.ollama.ai with no daemon/binary required
type: feature
---

`models-download` (Windows: `.\run.ps1 models-download <slug>`) pulls Ollama
models WITHOUT requiring the `ollama` binary or daemon to be installed.

Implementation: `scripts/models/helpers/ollama-registry-pull.ps1`
`Invoke-OllamaRegistryPull` — called from `Invoke-BackendInstall` in
`scripts/models/helpers/picker.ps1`.

Algorithm per slug `name[:tag]` (default tag `latest`, unscoped `name` becomes
`library/<name>`):
1. `GET https://registry.ollama.ai/v2/<name>/manifests/<tag>` with
   `Accept: application/vnd.docker.distribution.manifest.v2+json`.
2. For `config.digest` + each `layers[].digest`,
   `GET https://registry.ollama.ai/v2/<name>/blobs/sha256:<hex>` →
   `<ollama-dir>/blobs/sha256-<hex>` (sha256 verified, aria2c with `-x16 -s16`
   when present, else `Invoke-WebRequest`).
3. Save the raw manifest text to
   `<ollama-dir>/manifests/registry.ollama.ai/<name>/<tag>`.

This matches the on-disk layout the Ollama daemon uses, so a later
`-I 42` install picks the weights up automatically.

Every failure logs upstream URL + target path + reason via `Write-FileError`
(`fetch-manifest`, `download-attempt`, `write-manifest` operations) — CODE RED
contract.
