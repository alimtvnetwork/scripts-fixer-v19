---
name: Universal context menu (cross-OS)
description: Cross-OS right-click menu spec — Windows registry + macOS Finder Quick Actions + Linux .desktop / KIO / Thunar; shared action catalog at scripts/shared/context-menu-actions.json
type: feature
---

Spec lives at `spec/55-universal-context-menu/readme.md`. Drives a single
"Scripts Fixer" right-click menu on Windows, macOS, and Linux with a
shared action catalog (install models here, open installer, OS update,
startup add/remove, set default app, ENV add/remove path, BIN add, "all
context menu install", ConEmu open-here, Windows-tweaks open-here).

Backends:
- Windows = existing script 53 cascade (HKCR\*\shell\ScriptFixer +
  Directory\Background + DesktopBackground\Shell). Script 59 still owns
  the ConEmu sub-tree.
- macOS = new script `71-mac-context-menu/` writing `.workflow` Finder
  Quick Actions into `~/Library/Services/` + `pbs -flush`.
- Linux = new script `72-linux-context-menu/` fanning out to
  `~/.local/share/nautilus/scripts/` (GNOME),
  `~/.local/share/kio/servicemenus/*.desktop` (KDE),
  `~/.config/Thunar/uca.xml` (XFCE). Detect via `$XDG_CURRENT_DESKTOP`
  and fall back to writing all three sets.

Dispatcher surface lives under `os context-menu {install|uninstall|list|
restore}` with `--all`, `--scope`, `--actions`, `--yes`,
`--non-interactive`, `--dry-run`. All destructive ops snapshot first
(.reg / cp -p / .workflow zip into `.installed/snapshots/`) and route
through `Confirm-DestructiveAction` (Windows) or its bash equivalent.

ENV mutations (A7/A8/A9) are persistent: `setx` + HKCU\Environment
broadcast on Windows, tagged blocks in `~/.profile`/`~/.zshrc`/
`~/.zprofile` on Linux/macOS, with snapshot for `os env restore`.

CODE RED rules carry over:
- Every file/path error logs exact path + failure reason.
- Every install/extract/repair logs Source + Temp + Target via
  `Write-InstallPaths` / `write_install_paths`.
- Default dev dir is always `dev-tool` (hyphenated).

Phased rollout (v1 = P1..P3 = spec + shared catalog + Windows backend),
P4=Linux, P5=macOS, P6=`os context-menu` dispatcher + B1/B2, P7=ConEmu/
Windows-tweaks leaves, P8=E2E smokes.

Open questions (pre-P3) tracked in §8 of the spec. Key defaults:
user-scope startup + user-scope PATH on Windows; "All install" excludes
actions the user disabled in script 53 config.json; English-only labels
for v1.
