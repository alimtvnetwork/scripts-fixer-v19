# 61 -- Install JumpJump VPN

Installs the **JumpJump VPN** Windows desktop client.

JumpJump VPN is **not** published on the Chocolatey community feed, so the
script defaults to the **official direct-download installer**
(`jumpjump-vpn-setup.exe` from https://jumpjumpvpn.com). If a third-party
choco package ever ships, set `chocoPackage` in `config.json` and the script
will try Chocolatey first, then fall back to the direct installer.

## Usage

```powershell
# Install
.\run.ps1 install jumpjump-vpn       # bare keyword (also: jumpjump, jumpjumpvpn, jjvpn)
.\run.ps1 -I 61                      # by script id
.\run.ps1 -I 61 -- -Help             # show help

# Uninstall (sweeps registry + shortcuts, removes .installed/jumpjump-vpn.json)
.\run.ps1 uninstall jumpjump-vpn
.\run.ps1 -I 61 uninstall

# Reinstall
.\run.ps1 reinstall jumpjump-vpn
```

## Updating the installer URL

JumpJump rotates installer filenames per release. If the default URL 404s:

1. Visit https://jumpjumpvpn.com (Windows download page).
2. Copy the direct link to the latest `jumpjump-vpn-setup*.exe`.
3. Set `jumpjumpVpn.directInstall.url` and `fileName` in `config.json`.

## State tracking

Successful installs write `.installed/jumpjump-vpn.json` at the project root
(gitignored). Failures write the same file with a `lastError` field so the
next run shows a friendly retry message.
