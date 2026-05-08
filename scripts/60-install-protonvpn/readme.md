# 60 -- Install Proton VPN

Installs the **Proton VPN** Windows desktop client via Chocolatey
(`choco install protonvpn`), with an optional fallback to the official
`ProtonVPN_win_v<ver>.exe` installer when a current URL is provided in
`config.json`.

## Usage

```powershell
# Install
.\run.ps1 install protonvpn          # bare keyword (also: proton-vpn, proton, vpn)
.\run.ps1 -I 60                       # by script id
.\run.ps1 -I 60 -- -Help              # show help

# Uninstall (sweeps registry + shortcuts, removes .installed/protonvpn.json)
.\run.ps1 uninstall protonvpn
.\run.ps1 -I 60 uninstall

# Reinstall (uninstall then install via Chocolatey)
.\run.ps1 reinstall protonvpn
```

## State tracking

Successful installs write `.installed/protonvpn.json` at the project root
(gitignored). Failures write the same file with a `lastError` field so the
next run shows a friendly retry message.

## Fallback installer

`config.json -> protonvpn.fallback` is **disabled by default** because Proton
rotates the installer filename every release. To enable it:

1. Visit https://protonvpn.com/download-windows
2. Copy the direct link to the latest `ProtonVPN_win_v<version>.exe`
3. Set `fallback.enabled = true`, `fallback.url` to that link, and
   `fallback.fileName` to match.
