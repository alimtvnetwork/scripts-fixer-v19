# Spec 55 — Universal "Scripts Fixer" Context Menu (Cross-OS)

> Status: **DRAFT** — author: Lovable, awaiting user phase confirmation.
>
> Scope marker: this spec supersedes the Windows-only menu narrative in
> `spec/53-script-fixer-context-menu/`. Script 53 stays as the Windows
> registry backend; this spec adds Linux + macOS backends and a
> consolidated **action catalog** that all three OSes share.
>
> Naming rule (see `mem://preferences/dev-dir-naming`): the dev dir is
> always `dev-tool` (hyphenated). Never `devtool`/`devtools`.
>
> CODE RED rules carried over:
> - Every file/path error logs the exact path + failure reason
>   (`Write-FileError` / Linux equivalent).
> - Every install/extract/repair/sync logs Source + Temp + Target via
>   `Write-InstallPaths` (`scripts/shared/install-paths.ps1`) and the
>   bash equivalent (`scripts-linux/_shared/install-paths.sh`).
> - Destructive registry / shell-integration writes go through the
>   shared `Confirm-DestructiveAction` helper
>   (`scripts/shared/confirm-prompt.ps1`) and the bash equivalent.

---

## 1. Goal

Ship a single right-click integration on **Windows, macOS, and Linux**
that exposes the most common Scripts Fixer actions on:

- a **file** the user clicked,
- a **folder** the user clicked,
- the **empty background** of a folder (Windows "directory background" /
  Nautilus / Finder background).

Users should never need a terminal for the most common chores. The menu
must always run **the latest installed version** of Scripts Fixer (no
hardcoded version paths in command lines — resolve via
`scripts/shared/install-paths.ps1` / `_shared/install-paths.sh`).

---

## 2. Action Catalog (cross-OS)

Every action below MUST work identically on the three OSes unless
explicitly marked as Windows-only. Each action receives the clicked
path as its first positional argument (`%1` on Windows, `$@` on
*nix). Background scope passes the current folder.

| ID | Label                                    | Scope        | Maps to                                    | OS support       |
|----|------------------------------------------|--------------|--------------------------------------------|------------------|
| A1 | Install models in this folder            | folder, bg   | `models install --target <path>`           | Win, mac, Linux  |
| A2 | Open installer in this folder            | folder, bg   | `os installer --cwd <path>`                | Win, mac, Linux  |
| A3 | OS update                                | bg           | `os update`                                | Win, mac, Linux  |
| A4 | OS startup — add this item               | file         | `os startup add <path>`                    | Win, mac, Linux  |
| A5 | OS startup — remove this item            | file         | `os startup remove <path>`                 | Win, mac, Linux  |
| A6 | Set as default app for…                  | file         | `os default set <path>`                    | Win, mac, Linux  |
| A7 | ENV — add this folder to PATH            | folder, bg   | `os env add-path <path>`                   | Win, mac, Linux  |
| A8 | ENV — remove this folder from PATH       | folder, bg   | `os env remove-path <path>`                | Win, mac, Linux  |
| A9 | BIN — add this binary to PATH            | file         | `os env add-bin <path>`                    | Win, mac, Linux  |
| B1 | All context menu — install               | bg           | `os context-menu install --all`            | Win, mac, Linux  |
| B2 | All context menu — uninstall             | bg           | `os context-menu uninstall --all`          | Win, mac, Linux  |
| B3 | ConEmu — open here                       | folder, bg   | (Windows only — script 48)                 | Win              |
| B4 | ConEmu — context menu install            | bg           | `os conemu-context-menu install`           | Win              |
| B5 | Windows tweaks — open here               | bg           | script 15                                  | Win              |

**A6 (default app)** uses the existing cross-OS default-apps backend
(`mem://features/default-apps-cross-os`):
`ms-settings:` deep-link + UserChoice verify on Windows,
`xdg-mime` on Linux, `duti` on macOS.

**A7/A8/A9 (ENV)** must be **persistent** (not per-session):
- Windows: `setx` + HKCU\Environment broadcast.
- Linux: append/remove-line in `~/.profile` (or `~/.zshrc` if zsh
  detected) with a clearly tagged block.
- macOS: `~/.zprofile`, same tagged-block strategy.

Every ENV mutation snapshots the previous value so `os env restore`
can undo it (mirrors the registry-backup contract from
`mem://features/registry-backup-helper`).

---

## 3. OS Backends

### 3.1 Windows (existing — script 53 + 59)
Reuse the cascading `Registry::HKEY_CLASSES_ROOT\*\shell\ScriptFixer`
tree. Add the new actions above as new leaf entries. Background scope
uses `DesktopBackground\Shell` and `Directory\Background\shell`.

### 3.2 macOS (new — script 71-mac-context-menu)
Backend = **Finder Quick Actions** generated as a `.workflow` bundle in
`~/Library/Services/`. Each action is a small `bash` runner that
invokes `~/.scripts-fixer/run.sh <action> "$@"`.

Install/uninstall = copy/remove the `.workflow` bundles and call
`/System/Library/CoreServices/pbs -flush`.

### 3.3 Linux (new — script 72-linux-context-menu)
Backend = **`.desktop` Action entries** + per-DE handlers:
- GNOME / Nautilus: drop `.desktop` files in
  `~/.local/share/nautilus/scripts/` AND a `Nautilus Action` JSON.
- KDE / Dolphin: `~/.local/share/kio/servicemenus/*.desktop`.
- XFCE / Thunar: `~/.config/Thunar/uca.xml` patch (snapshot before
  edit).

Detection order: `XDG_CURRENT_DESKTOP` → fallback to writing all three
sets so the menu Just Works regardless of file manager.

Each `.desktop` entry calls `bash -lc '~/.scripts-fixer/run.sh <action>
"$@"' dummy %f` (or `%F` for multi-select, `%U` for URI).

---

## 4. Dispatcher surface

Add to `scripts/os/run.ps1` and `scripts-linux/run.sh`:

```
os context-menu install [--all] [--scope file|folder|background]
                        [--actions A1,A2,A4,...]
                        [--yes] [--non-interactive] [--dry-run]
os context-menu uninstall [--all]   [...same flags...]
os context-menu list                # show every installed entry + path
os context-menu restore [--snapshot <path>]
```

Subcommands that hit the registry / `.desktop` / `.workflow` files MUST:
1. Snapshot the current state (registry `.reg` / `cp -p` of `.desktop`
   files / Quick Action `.workflow` zip) into `.installed/snapshots/`.
2. Run through `Confirm-DestructiveAction` (or bash equivalent) unless
   `--yes` is passed.
3. Log a Source/Temp/Target line per CODE RED.

---

## 5. Per-Action Spec Files

Create a one-page `.md` per action in this folder:
`A1-models-install-here.md`, `A4-startup-add.md`, … each documenting:
- exact label per OS (because Linux `.desktop` Name= and Windows MUIVerb
  may differ in casing),
- argv contract,
- failure modes + log lines.

The first three (A1, A4, A7) are blockers for v1; the rest can ship in
phases (see §7).

---

## 6. Shared assets

- `scripts/shared/context-menu-actions.json` — the canonical action
  catalog (id, label, scope, OS gate, command template). Both the
  Windows installer and the *nix installers consume this file so labels
  never drift.
- `scripts/shared/install-paths.ps1` and
  `scripts-linux/_shared/install-paths.sh` already provide the
  Source/Temp/Target log line — reused as-is.

---

## 7. Phased rollout

| Phase | Deliverable                                                                                             |
|-------|---------------------------------------------------------------------------------------------------------|
| P1    | Spec + memory index updated (this commit). No code changes yet.                                          |
| P2    | `scripts/shared/context-menu-actions.json` catalog + JSON schema.                                        |
| P3    | Windows backend wires up A1, A2, A4–A9 in the existing script 53 cascade.                                |
| P4    | New script `72-linux-context-menu/` (Nautilus + KDE + XFCE).                                             |
| P5    | New script `71-mac-context-menu/` (Finder Quick Actions).                                                |
| P6    | `os context-menu` dispatcher + `--all` aggregator + B1/B2 entries.                                       |
| P7    | ConEmu / Windows-tweaks / "open here" leaves (B3–B5).                                                    |
| P8    | E2E smoke under `scripts/53-script-fixer-context-menu/tests/` and Linux/mac equivalents.                 |

User chooses which phases to ship in which release; v1 = P1–P3.

---

## 8. Open questions (need user answer before P3)

1. **A4 startup add — scope.** On Linux, "add to startup" = drop a
   `.desktop` in `~/.config/autostart/`. On macOS, `launchctl`
   `LaunchAgents` plist. Confirm we go user-scope (not system-scope)
   by default. ✅ assumed user-scope.
2. **A7 PATH on Windows.** Confirm we write to `HKCU\Environment` and
   broadcast `WM_SETTINGCHANGE` (not the machine-wide `HKLM` key).
   ✅ assumed user-scope.
3. **B1 "All context menu install".** Is the canonical list
   "everything in the catalog" or "everything in the catalog **minus**
   actions the user has individually unchecked in
   `scripts/53-script-fixer-context-menu/config.json`"? Default: minus.
4. **Action labels** — keep English-only for v1 (no i18n table)?
   ✅ assumed yes.
