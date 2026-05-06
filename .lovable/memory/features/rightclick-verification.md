---
name: Right-click verification helper
description: scripts/shared/interactive-verify.ps1 Invoke-RightClickVerification prompts user to test 3 Explorer contexts (folder, empty-folder, background); auto-skips on CI / -NonInteractive / redirected stdin; wired into script 52 (VS Code, label from config) and 59 (ConEmu, "ConEmu Here").
type: feature
---
Shared post-install UX for context-menu scripts. The function:
- Walks 3 contexts: folder, empty-folder, background (configurable via -Contexts)
- Records y/n/skip per context
- Prints colored summary table using bracketed ASCII glyphs ([OK]/[XX]/[--])
- Suggests retry command on FAIL plus "sign out / restart explorer.exe" tip
- Skips silently when $env:CI, $env:SCRIPTS_FIXER_NONINTERACTIVE=1, [Console]::IsInputRedirected, or -NonInteractive

Wiring:
- 52 (VS Code): runs after summary, before Save-ResolvedData; label pulled from $config.editions.<first>.contextMenuLabel; respects existing -NonInteractive switch
- 59 (ConEmu): runs only on the install path (after success/warn summary, before Save-ResolvedData); label hardcoded to "ConEmu Here"; uninstall/restore/list-snapshots paths return early before reaching it
