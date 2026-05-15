#!/usr/bin/env bash
# Root dispatcher for Linux installer toolkit.
# Verbs:
#   install | check | repair | uninstall      (per-script or all)
#   health           system-wide doctor: ok/drift/broken/uninstalled per id + summary
#   repair-all       run install for every id whose health is drift|broken|uninstalled
#                    (skip ok). Honors --only-drift to limit to broken installs.
#   --list           list all registered scripts
#   -I <id>          restrict to a single script id
#   --parallel N     run N installs in parallel (install verb only)
#   --json           (health only) emit machine-readable JSON to stdout
#   --only-drift     (repair-all only) only repair ids with state=drift
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
export DOCTOR_ROOT="$ROOT"
export SCRIPT_ID="root"
. "$ROOT/_shared/logger.sh"
. "$ROOT/_shared/pkg-detect.sh"
. "$ROOT/_shared/parallel.sh"
. "$ROOT/_shared/file-error.sh"
. "$ROOT/_shared/registry.sh"
. "$ROOT/_shared/doctor.sh"

VERB=""; ONLY_ID=""; PARALLEL=1; JSON_OUT=0; ONLY_DRIFT=0

while [ $# -gt 0 ]; do
  case "$1" in
    install|check|repair|uninstall|health|repair-all) VERB="$1"; shift ;;
    --list)        VERB="list"; shift ;;
    -I)            ONLY_ID="$2"; shift 2 ;;
    --parallel)    PARALLEL="$2"; shift 2 ;;
    --json)        JSON_OUT=1; shift ;;
    --only-drift)  ONLY_DRIFT=1; shift ;;
    -h|--help)     VERB="help"; shift ;;
    # ---- top-level shortcuts to script 64 (cross-OS startup-add) ----
    startup-list|startup-ls)
        VERB="startup-passthrough"; STARTUP_SUB="list"; shift ;;
    startup-remove|startup-rm|startup-del)
        VERB="startup-passthrough"; STARTUP_SUB="remove"; shift; STARTUP_REST=("$@"); break ;;
    startup-add|startup-app)
        VERB="startup-passthrough"; STARTUP_SUB="app";    shift; STARTUP_REST=("$@"); break ;;
    startup-env)
        VERB="startup-passthrough"; STARTUP_SUB="env";    shift; STARTUP_REST=("$@"); break ;;
    startup-prune|startup-purge)
        VERB="startup-passthrough"; STARTUP_SUB="prune";  shift; STARTUP_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 65 (cross-OS os-clean) ----
    os-clean|clean)
        VERB="osclean-passthrough"; OSCLEAN_SUB="run";              shift; OSCLEAN_REST=("$@"); break ;;
    os-clean-list|clean-list|clean-categories)
        VERB="osclean-passthrough"; OSCLEAN_SUB="list-categories";  shift; OSCLEAN_REST=("$@"); break ;;
    os-clean-help|clean-help)
        VERB="osclean-passthrough"; OSCLEAN_SUB="help";             shift; OSCLEAN_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 66 (macOS VS Code menu cleanup) ----
    vscode-mac-clean|vscode-clean-mac|menu-clean-mac)
        VERB="vscmac-passthrough"; VSCMAC_SUB="run";  shift; VSCMAC_REST=("$@"); break ;;
    vscode-mac-clean-list|menu-clean-mac-list)
        VERB="vscmac-passthrough"; VSCMAC_SUB="list"; shift; VSCMAC_REST=("$@"); break ;;
    vscode-mac-clean-help|menu-clean-mac-help)
        VERB="vscmac-passthrough"; VSCMAC_SUB="help"; shift; VSCMAC_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 67 (Linux VS Code cleanup) ----
    vscode-clean-linux|vscode-linux-clean|vscode-uninstall-linux)
        VERB="vsclin-passthrough"; VSCLIN_SUB="run";    shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-detect|vscode-linux-clean-detect)
        VERB="vsclin-passthrough"; VSCLIN_SUB="detect"; shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-resolve|vscode-linux-clean-resolve|vscode-resolve-linux|vscode-linux-resolve)
        VERB="vsclin-passthrough"; VSCLIN_SUB="resolve"; shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-list|vscode-linux-clean-list)
        VERB="vsclin-passthrough"; VSCLIN_SUB="list";   shift; VSCLIN_REST=("$@"); break ;;
    vscode-clean-linux-help|vscode-linux-clean-help)
        VERB="vsclin-passthrough"; VSCLIN_SUB="help";   shift; VSCLIN_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 70 (Ubuntu WordPress installer) ----
    # `./run.sh install wordpress [args...]`  -> full stack install
    # `./run.sh install wp [args...]`         -> alias of 'wordpress'
    # `./run.sh install wp-only [args...]`    -> only the WordPress component
    # `./run.sh wp [args...]` / `./run.sh wordpress [args...]` -> shortcut without 'install'
    wp|wordpress)
        VERB="wp-passthrough"; WP_SUB="install"; WP_COMP=""; shift; WP_REST=("$@"); break ;;
    wp-only)
        VERB="wp-passthrough"; WP_SUB="install"; WP_COMP="wp-only"; shift; WP_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 68 (group creation) ----
    # Two separate shell scripts in 68-user-mgmt/ that the root orchestrator
    # exposes directly so users don't need to remember the folder path:
    #   ./run.sh add-group <name> [--gid N] [--system] [--dry-run]
    #   ./run.sh add-groups-from-json <file.json> [--dry-run]
    # Aliases provided for natural ordering:  group-add / groups-from-json.
    add-group|group-add)
        VERB="grp-passthrough"; GRP_SUB="cli";  shift; GRP_REST=("$@"); break ;;
    add-groups-from-json|groups-from-json|add-group-from-json|group-from-json)
        VERB="grp-passthrough"; GRP_SUB="json"; shift; GRP_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 68 (user creation) ----
    # Mirrors the add-group shortcuts above. The CLI form takes the same
    # flags as 68-user-mgmt/add-user.sh (incl. --ssh-key / --ssh-key-file
    # which can be repeated). The JSON form auto-detects single object,
    # array, or { "users": [...] } shapes and supports per-record
    # sshKeys (array of inline pubkeys) + sshKeyFiles (array of paths).
    add-user|user-add)
        VERB="usr-passthrough"; USR_SUB="cli";  shift; USR_REST=("$@"); break ;;
    add-users-from-json|users-from-json|add-user-from-json|user-from-json)
        VERB="usr-passthrough"; USR_SUB="json"; shift; USR_REST=("$@"); break ;;
    # ---- top-level shortcuts to script 68 (edit / remove user) ----
    # Mirrors add-user shortcuts above. CLI form forwards to edit-user.sh
    # / remove-user.sh; JSON form forwards to the *-from-json.sh loaders
    # which now share helpers/_schema.sh for strict validation.
    edit-user|user-edit|modify-user|edituser)
        VERB="usr-passthrough"; USR_SUB="edit-cli";   shift; USR_REST=("$@"); break ;;
    edit-users-from-json|edit-user-from-json|modify-user-from-json|edit-user-json|modify-user-json)
        VERB="usr-passthrough"; USR_SUB="edit-json";  shift; USR_REST=("$@"); break ;;
    remove-user|user-remove|delete-user|deluser|removeuser)
        VERB="usr-passthrough"; USR_SUB="remove-cli"; shift; USR_REST=("$@"); break ;;
    remove-users-from-json|remove-user-from-json|delete-user-from-json|remove-user-json|delete-user-json)
        VERB="usr-passthrough"; USR_SUB="remove-json"; shift; USR_REST=("$@"); break ;;
    # ---- top-level shortcut: one-page cheat-sheet for the DIRECT CLI ----
    # surface of script 68 (no JSON required). Read-only, no side effects.
    #   ./run.sh useradm-help        -> users + groups + examples
    #   ./run.sh user-help           -> users only
    #   ./run.sh group-help          -> groups only
    useradm-help|usermgmt-help)
        VERB="useradm-help"; USERADM_SUB="all";   shift; break ;;
    user-help|users-help)
        VERB="useradm-help"; USERADM_SUB="user";  shift; break ;;
    group-help|groups-help)
        VERB="useradm-help"; USERADM_SUB="group"; shift; break ;;
    # ---- top-level shortcut: parse-only orchestrator (script 68) ----
    # Takes a unified spec (--spec FILE), separate JSONs (--groups-json /
    # --users-json), or inline --group / --user entries -- in any
    # combination -- and runs all four leaves in the correct order
    # (groups first) with a single shared summary.
    useradm-bootstrap|usermgmt-bootstrap|user-bootstrap)
        VERB="useradm-bootstrap"; shift; USERADM_BOOT_REST=("$@"); break ;;
    # ---- top-level shortcut: read-only verifier (script 68) ----
    # Pass/fail audit of current user + group state. Same input shapes as
    # the orchestrator (--spec / --groups-json / --users-json / --group / --user).
    useradm-verify|usermgmt-verify|user-verify|verify-users)
        VERB="useradm-verify"; shift; USERADM_VRF_REST=("$@"); break ;;
    # ---- top-level shortcut: E2E test matrix for scripts 65/66/67 ----
    # Runs every per-folder smoke test on the current OS, then drives
    # each script through a sandbox-mode dry-run, then asserts the OS
    # guard fires on the wrong OS, then asserts the root-requirement
    # contract. Pure read-only on the host -- everything happens under
    # mktemp sandboxes.
    e2e-matrix|e2e|test-matrix)
        VERB="e2e-matrix"; shift; break ;;
    # ---- top-level shortcuts to default-apps (browser + mail client) ----
    # Mirrors the Windows side `./run.ps1 os browser <name>` /
    # `./run.ps1 os email <name>`. On Linux uses xdg-settings + xdg-mime,
    # on macOS prefers `duti` and falls back to opening System Settings.
    browser|default-browser|set-browser|web-browser)
        VERB="defapp-passthrough"; DEFAPP_KIND="browser"; shift; DEFAPP_REST=("$@"); break ;;
    email|mail|default-email|default-mail|set-email|mail-client)
        VERB="defapp-passthrough"; DEFAPP_KIND="email"; shift; DEFAPP_REST=("$@"); break ;;
    # ---- top-level shortcut: fast-download (aria2c-first) ---------------
    # ./run.sh download <url> [<dir>] [-s|--splits N] [-p|--piece-size SIZE]
    # ./run.sh url      <url> [<dir>] [-s N] [-p SIZE]   (alias)
    # Defaults: splits=16, piece=1M, dir=$PWD.
    download|url|fast-download|fastdownload)
        VERB="fast-download"; shift; FD_REST=("$@"); break ;;
    # ---- top-level shortcut: model download (script 43) -----------------
    # ./run.sh models list                    print catalog
    # ./run.sh models <id> [<id> ...]         download by id(s)
    # ./run.sh models <id> ... -d /path       custom output dir
    models|model)
        VERB="models"; shift; MODELS_REST=("$@"); break ;;
    # ---- top-level shortcut: SHA256-pinned remote installers ------------
    # ./run.sh install coding-guidelines       (alias: clean-code, cg, cc, code-guide)
    # Streams the upstream install.sh from gitub via curl, verifies the
    # pinned sha256 BEFORE execution, then runs it through bash.
    coding-guidelines|clean-code|cg|cc|code-guide)
        VERB="remote-install"; REMOTE_KEY="coding-guidelines"; shift; break ;;
    # ---- top-level: reset state (.logs / .resolved / .installed) -------
    # Wipes per-run state from the repo root so the next run starts fresh.
    reset|fresh|fresh-start|wipe-state|clear-state)
        VERB="reset"; shift; RESET_REST=("$@"); break ;;
    *)
        # `./run.sh install wordpress [args]` lands here AFTER install was consumed.
        # Re-route it through the wp passthrough so the user-friendly form works.
        if [ "$VERB" = "install" ] && { [ "$1" = "wordpress" ] || [ "$1" = "wp" ] || [ "$1" = "wp-only" ]; }; then
            comp=""
            [ "$1" = "wp-only" ] && comp="wp-only"
            VERB="wp-passthrough"; WP_SUB="install"; WP_COMP="$comp"; shift; WP_REST=("$@"); break
        fi
        if [ "$VERB" = "uninstall" ] && { [ "$1" = "wordpress" ] || [ "$1" = "wp" ] || [ "$1" = "wp-only" ]; }; then
            comp=""
            [ "$1" = "wp-only" ] && comp="wp-only"
            VERB="wp-passthrough"; WP_SUB="uninstall"; WP_COMP="$comp"; shift; WP_REST=("$@"); break
        fi
        log_warn "Unknown arg: $1"; shift ;;
  esac
done

show_help() {
  cat <<EOF
Linux Installer Toolkit (v0.129.0)

Per-script verbs:
  install              Install
  check                Verify install state
  repair               Re-run install for a single id
  uninstall            Remove

System-wide verbs:
  --list               List all registered scripts
  health               Doctor: report ok | drift | broken | uninstalled per id
                         --json   emit machine-readable JSON
  repair-all           Run install for every id whose health != ok
                         --only-drift   only repair ids in drift state

Fast download (aria2c-first, defaults splits=16, piece=1M):
  download <url> [<dir>] [-s|--splits N] [-p|--piece-size SIZE]
  url      <url> [<dir>] [-s N] [-p SIZE]   (alias)
                                Auto-installs aria2c if missing; falls back
                                to curl/wget. Used by all model pulls.

Model download (script 43 llama.cpp model-pull):
  models list                    Print full catalog (id, family, params, size,
                                 RAM required, ratings cod/rea/spd/ovr, name)
                                 Followed by a syntax + filter examples footer.
  models <id> [<id> ...]         Download one or more models by exact id
       --dir <path>              Output directory (default: ~/models/gguf, alias -d)
  model  ...                     Alias of 'models'

  Filters (compose with 'list' to preview, with --all to download):
       --family <pat>            Match family/displayName/id substring (case-insensitive)
       --max-ram <gb> | --min-ram <gb>     Filter by ramRequiredGB
       --max-size <gb> | --min-size <gb>   Filter by fileSizeGB
       --coding | --reasoning | --writing | --voice | --multilingual | --chat
                                 Keep models flagged with that capability
       --exclude <pat>           Drop ids/family/displayName matching (repeatable)
       --all                     Download every model that survives the filters
       --dry-run                 Show what would be downloaded; do not fetch

Examples:
  ./run.sh models list                                        # full catalog + footer
  ./run.sh models qwen2.5-coder-3b                            # one model
  ./run.sh models qwen2.5-coder-3b nemotron-8b-opus-distill --dir /mnt/ai
  ./run.sh models list --family qwen3.7                       # preview Qwen 3.7 family
  ./run.sh models --family qwen3.7 --max-ram 16 --all         # bulk: Qwen 3.7 fitting 16 GB
  ./run.sh models --family qwen3.7 --max-ram 16 --exclude 32b --all
  ./run.sh models --coding --max-size 8 --all --dry-run       # preview coding picks
  ./run.sh models --reasoning --min-ram 8 --max-ram 32 --all  # reasoning band
  Ratings legend: 9-10 exceptional | 7-8 strong | 5-6 competent | <5 weak

Remote installers (SHA256-pinned, mirror of Windows remote.<key>):
  install coding-guidelines    Coding Guidelines v23 -- alimtvnetwork/coding-guidelines-v23
  install clean-code           Same as 'install coding-guidelines'
  install cg | cc | code-guide Aliases of 'install coding-guidelines'
                                 Body is downloaded, sha256-verified BEFORE
                                 execution; mismatched bodies are quarantined
                                 in scripts-linux/_shared/remote-installers/.quarantine/
                                 (CODE RED). Pin lives in
                                 scripts-linux/_shared/remote-installers/coding-guidelines.json.

Cross-OS startup management (script 64 shortcuts):
  startup-list                 List startup entries created by this toolkit
  startup-remove <name> [...]  Remove a tool-created entry (alias: startup-rm)
      --method M               Limit to one method (autostart|systemd-user|
                               shell-rc-app|launchagent|login-item|shell-rc-env)
      --all                    Remove from every method that holds it
  startup-add <path> [...]     Register an app to run at login
  startup-env  KEY=VALUE       Persist an env var
  startup-prune                Idempotent sweep: remove ALL tool-tagged entries
      --dry-run                Preview only, no changes
      --yes                    Skip the interactive confirmation prompt

Cross-OS cleanup (script 65 shortcuts):
  os-clean                     Sweep temp/caches/trash/pkg-caches/logs (apply mode)
      --dry-run                Preview only, no deletions
      --only A,B,C             Limit to comma-separated category ids
      --exclude A,B,C          Skip these categories
      --yes                    Pre-approve destructive (trash, logs-system)
      --json                   Emit machine-readable summary on stdout
  os-clean-list                Print all defined cleanup categories

Default-app management (cross-OS: Linux uses xdg-settings/xdg-mime, macOS uses duti):
  browser <name> [--list] [--dry-run]   Set default web browser
                                          Names: chrome | firefox | edge | brave |
                                                 opera | vivaldi | librewolf |
                                                 chromium | safari (mac only)
  email <name> [--list] [--dry-run]     Set default mail (mailto:) client
                                          Names: thunderbird | evolution | geary |
                                                 kmail | mailspring | claws | mutt |
                                                 apple-mail | outlook-mac |
                                                 spark | airmail (mac only)
      --list                              Print catalog of available names + exit
      --dry-run                           Detect + plan only; no changes applied
      Linux requires xdg-utils; macOS recommends `brew install duti` for
      non-interactive setting (otherwise opens System Settings as fallback).

macOS VS Code menu cleanup (script 66 shortcuts; macOS only):
  vscode-mac-clean             Remove Finder Services workflows, LaunchAgents/
                               Daemons, Login Items, code/code-insiders shims,
                               and vscode:// LaunchServices handlers.
      --dry-run                Preview every targeted path/label/handler
      --scope user|system      Default 'auto': system if root, else user
      --only A,B,C             Limit to comma-separated category ids
      --edition stable|insiders Limit to one VS Code edition
  vscode-mac-clean-list        Print all defined cleanup categories

Linux VS Code uninstaller (script 67 shortcuts; Linux only):
  vscode-clean-linux           Detect install method (apt|snap|deb|tarball|
                               binary|user-config) and remove ONLY the matching
                               packages, files, and configuration.
      --dry-run                Preview every targeted package/path
      --scope user|system      Default 'auto': system if root, else user
      --only A,B,C             Limit to comma-separated method ids
      --skip-detect            Run --only methods without re-probing
  vscode-clean-linux-detect    Detect-only: print which install methods are
                               present, no changes
  vscode-resolve-linux         Detect-only, print SINGLE classification line:
                                 method=<apt|snap|deb|tarball|binary|user-config|none>
                                 edition=<stable|insiders|both>  detail='...'
                               Exit codes: 0=single method, 1=multiple, 2=none.
  vscode-clean-linux-list      Print catalog of methods + probes + steps

Ubuntu WordPress installer (script 70 shortcuts; Ubuntu/Debian only):
  install wordpress            Install full LEMP stack + latest WordPress
      -i, --interactive        Prompt for port / data dir / PHP version /
                               install path / DB name / user / password
      --db mysql|mariadb       Pick DB engine (default: mysql)
      --php 8.1|8.2|8.3|latest Pin PHP version (default: latest)
      --port <n>               MySQL port (default: 3306)
      --datadir <path>         MySQL data directory (default: /var/lib/mysql)
      --path <path>            WordPress install path (default: /var/www/wordpress)
      --site-port <n>          nginx HTTP port (default: 80)
  install wp                   Alias of 'install wordpress'
  install wp-only              Only the WordPress component (assumes prereqs)
  uninstall wordpress          Remove WordPress + nginx vhost (keeps PHP / MySQL)

Group management (script 68 shortcuts; Linux + macOS):
  add-group <name> [opts]      Create one local group via direct CLI args
      --gid N                  Pin numeric GID (auto-assigned if omitted)
      --system                 System group (Linux only; ignored on macOS)
      --dry-run                Print what would happen, change nothing
      Aliases: group-add
  add-groups-from-json <file>  Bulk-create groups from a JSON file. Accepts:
                                 single object  : { "name": "devs", "gid": 2000 }
                                 array          : [ { ... }, { ... } ]
                                 wrapped object : { "groups": [ ... ] }
      --dry-run                Preview every record, change nothing
      Aliases: groups-from-json, add-group-from-json

User management (script 68 shortcuts; Linux + macOS):
  add-user <name> [opts]       Create one local user via direct CLI args
      --password PW            Plain-text password (logged masked only)
      --password-file FILE     Read password from a 0600 file
      --uid N                  Pin numeric UID
      --primary-group G        Primary group (created if missing on Linux)
      --groups g1,g2,...       Supplementary groups (comma-separated)
      --shell PATH             Login shell (default /bin/bash | /bin/zsh)
      --home  PATH             Home dir (default /home/<n> | /Users/<n>)
      --comment "..."          GECOS / RealName
      --sudo                   Add to sudo (Linux) / admin (macOS) group
      --system                 System account (Linux only)
      --ssh-key "<line>"       Inline OpenSSH public key. Repeatable.
      --ssh-key-file <path>    Read keys from a file (one per line, '#'
                               and blanks ignored). Repeatable.
                               Installed to <home>/.ssh/authorized_keys
                               (mode 0600, dir 0700, owner=<user>:<pgroup>).
                               Existing keys preserved, duplicates merged.
                               Key contents NEVER logged -- only fingerprints.
      --dry-run                Print what would happen, change nothing
      Aliases: user-add
  add-users-from-json <file>   Bulk-create users from a JSON file. Accepts:
                                 single object  : { "name": "alice", ... }
                                 array          : [ { ... }, { ... } ]
                                 wrapped object : { "users": [ ... ] }
                               Per-record fields: name, password, passwordFile,
                                 uid, primaryGroup, groups[], shell, home,
                                 comment, sudo, system, sshKeys[], sshKeyFiles[]
      --dry-run                Preview every record, change nothing
      Aliases: users-from-json, add-user-from-json
  edit-user <name> [opts]      Modify an existing local user (Linux + macOS)
      --rename NEW             Rename the account (applied last)
      --reset-password         Reset password (combine with --password / --ask)
      --promote / --demote     Add to / remove from sudo (Linux) / admin (macOS)
      --add-group G            Add to a supplementary group (repeatable)
      --remove-group G         Remove from a supplementary group (repeatable)
      --shell PATH             Change login shell
      --comment "..."          Update GECOS / RealName
      --enable / --disable     Unlock / lock the account (mutually exclusive)
      --dry-run                Preview, change nothing
      Aliases: user-edit, modify-user
  edit-users-from-json <file>  Bulk user edits from JSON. Same shapes as
                               add-users-from-json. Per-record fields:
                                 name (required), rename, password,
                                 passwordFile, promote, demote, addGroups[],
                                 removeGroups[], shell, comment, enable, disable
      --dry-run                Preview every record, change nothing
      Aliases: edit-user-from-json, edit-user-json, modify-user-json
  remove-user <name> [opts]    Delete a local user (idempotent)
      --purge-home             Also remove the home directory (DESTRUCTIVE)
      --remove-mail-spool      Linux only: drop /var/mail/<n>
      --yes                    Skip confirmation prompt
      --dry-run                Preview, change nothing
      Aliases: user-remove, delete-user, deluser
  remove-users-from-json <file> Bulk user removal from JSON. Same shapes as
                                add-users-from-json plus a bare-string list:
                                  [ "alice", "bob" ]
                                Per-record fields: name (required), purgeHome,
                                purgeProfile (Windows-friendly alias),
                                removeMailSpool. --yes is always added.
      --dry-run                Preview every record, change nothing
      Aliases: remove-user-from-json, remove-user-json, delete-user-json
  useradm-help                 One-page cheat-sheet for the direct-CLI flags
                               (no JSON required). Filtered variants:
                                 user-help    users only
                                 group-help   groups only
  useradm-bootstrap [opts]     Parse-only orchestrator (script 68). Runs
                               groups first, then users, in the correct
                               order with a single shared summary log.
                               Inputs (any combination):
                                 --spec FILE         unified spec
                                 --groups-json FILE  groups-only JSON
                                 --users-json  FILE  users-only JSON
                                 --group  "n:flags"  inline group (repeat)
                                 --user   "n:flags"  inline user  (repeat)
                                 --dry-run           preview, change nothing
                                 --no-verify         skip BEFORE/AFTER verify
                                 --verify-only       just AFTER-verify (no mutations)
  useradm-verify    [opts]     READ-ONLY pass/fail audit of current user +
                               group state. Same inputs as useradm-bootstrap.
                               Optional: --emit-snapshot FILE (TSV), --quiet.
  e2e-matrix                   End-to-end test matrix for scripts 65/66/67.
                               Runs per-folder smoke tests, sandboxed
                               production dry-runs, OS-guard checks (66 on
                               Linux, 67 on macOS), and root-requirement
                               contract checks. Aliases: e2e, test-matrix.

Flags:
  -I <id>              Restrict to a single script id
  --parallel <N>       Run N installs in parallel (install verb only)
EOF
}

run_one() {
  local id="$1" verb="$2"
  local folder script
  folder=$(registry_get_folder "$id")
  if [ -z "$folder" ]; then log_err "Unknown script id: $id"; return 1; fi
  script="$ROOT/$folder/run.sh"
  if [ ! -f "$script" ]; then
    log_file_error "$script" "script not yet implemented (phase pending)"
    return 0
  fi
  log_info "[$id] $verb -> $folder"
  bash "$script" "$verb"
}

verb_health() {
  local rows
  rows=$(doctor_run_all)
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local out_json="$ROOT/.summary/health-$ts.json"
  local out_md="$ROOT/.summary/health-$ts.md"
  mkdir -p "$ROOT/.summary" || log_file_error "$ROOT/.summary" "mkdir failed"

  local ok_n=0 drift_n=0 broken_n=0 uninst_n=0 miss_n=0
  while IFS=$'\t' read -r id folder state age detail; do
    case "$state" in
      ok)             ok_n=$((ok_n+1)) ;;
      drift)          drift_n=$((drift_n+1)) ;;
      broken)         broken_n=$((broken_n+1)) ;;
      uninstalled)    uninst_n=$((uninst_n+1)) ;;
      missing_script) miss_n=$((miss_n+1)) ;;
    esac
  done <<< "$rows"

  if [ "$JSON_OUT" -eq 1 ]; then
    {
      echo "{"
      echo "  \"timestamp\": \"$ts\","
      echo "  \"summary\": {\"ok\":$ok_n,\"drift\":$drift_n,\"broken\":$broken_n,\"uninstalled\":$uninst_n,\"missing_script\":$miss_n},"
      echo "  \"results\": ["
      local first=1
      while IFS=$'\t' read -r id folder state age detail; do
        [ "$first" -eq 1 ] || printf ',\n'
        first=0
        printf '    {"id":"%s","folder":"%s","state":"%s","markerAgeSeconds":%s,"detail":"%s"}' \
          "$id" "$folder" "$state" "$([ "$age" = "-" ] && echo null || echo "$age")" "$detail"
      done <<< "$rows"
      echo
      echo "  ]"
      echo "}"
    } | tee "$out_json"
    log_info "Health JSON written: $out_json"
    return 0
  fi

  # human table
  printf '\n%-4s %-32s %-13s %-10s %s\n' "ID" "FOLDER" "STATE" "AGE" "DETAIL"
  printf '%s\n' "------------------------------------------------------------------------------------------------"
  while IFS=$'\t' read -r id folder state age detail; do
    local color age_h
    age_h=$(doctor_age_human "$age")
    case "$state" in
      ok)             color="\033[32m" ;;
      drift)          color="\033[31m" ;;
      broken)         color="\033[33m" ;;
      uninstalled)    color="\033[2m"  ;;
      missing_script) color="\033[35m" ;;
      *)              color=""         ;;
    esac
    printf "${color}%-4s %-32s %-13s %-10s %s\033[0m\n" "$id" "$folder" "$state" "$age_h" "$detail"
  done <<< "$rows"
  printf '\n'
  printf 'Summary: ok=%d  drift=%d  broken=%d  uninstalled=%d  missing_script=%d\n' \
    "$ok_n" "$drift_n" "$broken_n" "$uninst_n" "$miss_n"

  # write markdown
  {
    echo "# Health Report — $ts"
    echo ""
    echo "**Summary:** ok=$ok_n  drift=$drift_n  broken=$broken_n  uninstalled=$uninst_n  missing_script=$miss_n"
    echo ""
    echo "| ID | Folder | State | Marker Age | Detail |"
    echo "|----|--------|-------|------------|--------|"
    while IFS=$'\t' read -r id folder state age detail; do
      printf "| %s | %s | %s | %s | %s |\n" "$id" "$folder" "$state" "$(doctor_age_human "$age")" "$detail"
    done <<< "$rows"
  } > "$out_md" || log_file_error "$out_md" "health markdown write failed"
  log_info "Health report written: $out_md"

  # exit non-zero if anything is in drift or missing_script (CI signal)
  [ "$drift_n" -eq 0 ] && [ "$miss_n" -eq 0 ]
}

verb_repair_all() {
  local rows
  rows=$(doctor_run_all)
  local targets=() id folder state age detail
  while IFS=$'\t' read -r id folder state age detail; do
    if [ "$ONLY_DRIFT" -eq 1 ]; then
      [ "$state" = "drift" ] && targets+=("$id")
    else
      case "$state" in drift|broken|uninstalled) targets+=("$id") ;; esac
    fi
  done <<< "$rows"

  if [ "${#targets[@]}" -eq 0 ]; then
    log_ok "Nothing to repair (all healthy)"
    return 0
  fi
  log_info "repair-all: ${#targets[@]} target(s): ${targets[*]}"
  local rc_total=0
  for id in "${targets[@]}"; do
    run_one "$id" install || { log_warn "[$id] repair-all: install failed"; rc_total=1; }
  done
  return "$rc_total"
}

case "${VERB:-help}" in
  help) show_help ;;
  fast-download)
    # Parse: <url> [<dir>] [-s|--splits N] [-p|--piece-size SIZE]
    fd_url=""; fd_dir="$PWD"; fd_splits=16; fd_piece="1M"
    fd_pos=0
    fd_args=("${FD_REST[@]:-}")
    fd_i=0
    while [ "$fd_i" -lt "${#fd_args[@]}" ]; do
      fd_a="${fd_args[$fd_i]}"
      case "$fd_a" in
        -s|--splits)            fd_i=$((fd_i+1)); fd_splits="${fd_args[$fd_i]:-16}" ;;
        --splits=*)             fd_splits="${fd_a#*=}" ;;
        -s=*)                   fd_splits="${fd_a#*=}" ;;
        -p|--piece-size|--piece) fd_i=$((fd_i+1)); fd_piece="${fd_args[$fd_i]:-1M}" ;;
        --piece-size=*)         fd_piece="${fd_a#*=}" ;;
        --piece=*)              fd_piece="${fd_a#*=}" ;;
        -p=*)                   fd_piece="${fd_a#*=}" ;;
        -h|--help)
          echo "Usage: ./run.sh download <url> [<dir>] [-s|--splits N] [-p|--piece-size SIZE]"
          echo "Defaults: splits=16, piece=1M, dir=\$PWD"
          exit 0 ;;
        -*)
          log_warn "fast-download: unknown flag '$fd_a'" ;;
        *)
          if [ "$fd_pos" -eq 0 ]; then fd_url="$fd_a"
          elif [ "$fd_pos" -eq 1 ]; then fd_dir="$fd_a"
          else log_warn "fast-download: extra positional '$fd_a' ignored"
          fi
          fd_pos=$((fd_pos+1)) ;;
      esac
      fd_i=$((fd_i+1))
    done
    if [ -z "$fd_url" ]; then
      log_err "fast-download: <url> is required"
      echo "Usage: ./run.sh download <url> [<dir>] [-s N] [-p SIZE]"
      exit 64
    fi
    . "$ROOT/_shared/apt-install.sh" 2>/dev/null || true
    . "$ROOT/_shared/fast-download.sh"
    fast_download "$fd_url" "$fd_dir" "$fd_splits" "$fd_piece"
    exit $?
    ;;
  models)
    # Forward every arg to model-pull.sh -- it owns flag parsing (filters,
    # --dir, --all, --dry-run, --exclude, capability flags, etc).
    mp_filtered=()
    for _a in "${MODELS_REST[@]:-}"; do [ -n "$_a" ] && mp_filtered+=("$_a"); done
    MP_SCRIPT="$ROOT/43-install-llama-cpp/model-pull.sh"
    if [ ! -x "$MP_SCRIPT" ] && [ ! -f "$MP_SCRIPT" ]; then
      log_file_error "$MP_SCRIPT" "model-pull.sh missing or not executable"
      exit 1
    fi

    # HARD GUARD: 'models' (a.k.a. models-download) must NEVER install
    # llama.cpp binaries. Snapshot the llama.cpp install dir + bin dir,
    # set the sentinel env var, then post-diff to detect any leak.
    LLAMA_CFG="$ROOT/43-install-llama-cpp/config.json"
    LLAMA_INSTALL_ROOT=""
    LLAMA_BIN_DIR=""
    if [ -f "$LLAMA_CFG" ] && command -v jq >/dev/null 2>&1; then
      _r=$(jq -r '.install.installRoot' "$LLAMA_CFG"); LLAMA_INSTALL_ROOT="${_r//\$\{HOME\}/$HOME}"
      _b=$(jq -r '.install.binDir'      "$LLAMA_CFG"); LLAMA_BIN_DIR="${_b//\$\{HOME\}/$HOME}"
    fi
    SNAP_BEFORE="$(mktemp -t models-dl-snap-before.XXXXXX)"
    SNAP_AFTER="$(mktemp  -t models-dl-snap-after.XXXXXX)"
    _snap() {
      : > "$1"
      for d in "$LLAMA_INSTALL_ROOT" "$LLAMA_BIN_DIR"; do
        [ -n "$d" ] && [ -d "$d" ] && \
          find "$d" -type f \( -name 'llama-*' -o -name '*.so' -o -name '*.dylib' \
                              -o -name '*.tar.gz' -o -name '*.zip' \) \
                    -printf '%p\t%s\n' 2>/dev/null >> "$1"
      done
      sort -o "$1" "$1"
    }
    _snap "$SNAP_BEFORE"

    export MODELS_DOWNLOAD_NO_BINARIES=1
    if [ "${#mp_filtered[@]}" -gt 0 ]; then
      bash "$MP_SCRIPT" "${mp_filtered[@]}"; mp_rc=$?
    else
      bash "$MP_SCRIPT"; mp_rc=$?
    fi
    unset MODELS_DOWNLOAD_NO_BINARIES

    _snap "$SNAP_AFTER"
    LEAK="$(comm -13 "$SNAP_BEFORE" "$SNAP_AFTER" || true)"
    rm -f "$SNAP_BEFORE" "$SNAP_AFTER"
    if [ -n "$LEAK" ] || [ "$mp_rc" = 87 ]; then
      log_err "HARD GUARD: 'models' must not install llama.cpp binaries."
      if [ -n "$LEAK" ]; then
        log_err "Detected new/changed binary file(s) under $LLAMA_INSTALL_ROOT / $LLAMA_BIN_DIR :"
        printf '%s\n' "$LEAK" | sed 's/^/  + /' >&2
      fi
      log_err "Aborting models. Use './run.sh -I 43' to install llama.cpp binaries explicitly."
      exit 87
    fi
    exit "$mp_rc"
    ;;
  remote-install)
    # SHA256-pinned remote installer (Linux mirror of Windows remote.<key>).
    descriptor="$ROOT/_shared/remote-installers/${REMOTE_KEY}.json"
    if [ ! -f "$descriptor" ]; then
      log_file_error "$descriptor" "remote-install: descriptor missing for key '${REMOTE_KEY}'"
      exit 1
    fi
    . "$ROOT/_shared/remote-installers/remote-install.sh"
    remote_install "$descriptor"
    exit $?
    ;;
  list) registry_list_all | column -t -s$'\t' ;;
  health)      verb_health ;;
  repair-all)  verb_repair_all ;;
  startup-passthrough)
    bash "$ROOT/64-startup-add/run.sh" "$STARTUP_SUB" "${STARTUP_REST[@]:-}"
    ;;
  osclean-passthrough)
    bash "$ROOT/65-os-clean/run.sh" "$OSCLEAN_SUB" "${OSCLEAN_REST[@]:-}"
    ;;
  vscmac-passthrough)
    bash "$ROOT/66-vscode-menu-cleanup-mac/run.sh" "$VSCMAC_SUB" "${VSCMAC_REST[@]:-}"
    ;;
  vsclin-passthrough)
    # Filter out a stray empty element that some bash versions add when "$@"
    # was empty at the time VSCLIN_REST=("$@") was set.
    _vsclin_filtered=()
    for _a in "${VSCLIN_REST[@]:-}"; do [ -n "$_a" ] && _vsclin_filtered+=("$_a"); done
    if [ "${#_vsclin_filtered[@]}" -gt 0 ]; then
      bash "$ROOT/67-vscode-cleanup-linux/run.sh" "$VSCLIN_SUB" "${_vsclin_filtered[@]}"
    else
      bash "$ROOT/67-vscode-cleanup-linux/run.sh" "$VSCLIN_SUB"
    fi
    ;;
  wp-passthrough)
    _wp_filtered=()
    for _a in "${WP_REST[@]:-}"; do [ -n "$_a" ] && _wp_filtered+=("$_a"); done
    if [ -n "$WP_COMP" ]; then
      bash "$ROOT/70-install-wordpress-ubuntu/run.sh" "$WP_SUB" "$WP_COMP" "${_wp_filtered[@]}"
    else
      bash "$ROOT/70-install-wordpress-ubuntu/run.sh" "$WP_SUB" "${_wp_filtered[@]}"
    fi
    ;;
  grp-passthrough)
    # Filter empties (some bash versions add a stray "" when "$@" was empty
    # at capture time -- same dance as vsclin/wp passthroughs above).
    _grp_filtered=()
    for _a in "${GRP_REST[@]:-}"; do [ -n "$_a" ] && _grp_filtered+=("$_a"); done
    case "$GRP_SUB" in
      cli)
        if [ "${#_grp_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-group.sh" "${_grp_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-group.sh"
        fi
        ;;
      json)
        if [ "${#_grp_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-group-from-json.sh" "${_grp_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-group-from-json.sh"
        fi
        ;;
      *)
        log_err "internal: unknown grp sub '$GRP_SUB'"; exit 64 ;;
    esac
    ;;
  usr-passthrough)
    # Same empty-arg-filter dance as grp/vsclin/wp passthroughs.
    _usr_filtered=()
    for _a in "${USR_REST[@]:-}"; do [ -n "$_a" ] && _usr_filtered+=("$_a"); done
    case "$USR_SUB" in
      cli)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-user.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-user.sh"
        fi
        ;;
      json)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/add-user-from-json.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/add-user-from-json.sh"
        fi
        ;;
      edit-cli)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/edit-user.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/edit-user.sh"
        fi
        ;;
      edit-json)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/edit-user-from-json.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/edit-user-from-json.sh"
        fi
        ;;
      remove-cli)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/remove-user.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/remove-user.sh"
        fi
        ;;
      remove-json)
        if [ "${#_usr_filtered[@]}" -gt 0 ]; then
          bash "$ROOT/68-user-mgmt/remove-user-from-json.sh" "${_usr_filtered[@]}"
        else
          bash "$ROOT/68-user-mgmt/remove-user-from-json.sh"
        fi
        ;;
      *)
        log_err "internal: unknown usr sub '$USR_SUB'"; exit 64 ;;
    esac
    ;;
  useradm-help)
    # One-page cheat-sheet for the direct-CLI surface of script 68.
    # Pure stdout dump -- no helpers loaded, no root required.
    bash "$ROOT/68-user-mgmt/cli-cheatsheet.sh" "${USERADM_SUB:-all}"
    ;;
  useradm-bootstrap)
    # Thin parse-only orchestrator: forwards every flag to orchestrate.sh
    # which then dispatches the four leaves in the correct order.
    _boot_filtered=()
    for _a in "${USERADM_BOOT_REST[@]:-}"; do [ -n "$_a" ] && _boot_filtered+=("$_a"); done
    if [ "${#_boot_filtered[@]}" -gt 0 ]; then
      bash "$ROOT/68-user-mgmt/orchestrate.sh" "${_boot_filtered[@]}"
    else
      bash "$ROOT/68-user-mgmt/orchestrate.sh"
    fi
    ;;
  useradm-verify)
    # Read-only audit. Same arg-filtering dance as the other passthroughs.
    _vrf_filtered=()
    for _a in "${USERADM_VRF_REST[@]:-}"; do [ -n "$_a" ] && _vrf_filtered+=("$_a"); done
    if [ "${#_vrf_filtered[@]}" -gt 0 ]; then
      bash "$ROOT/68-user-mgmt/verify.sh" "${_vrf_filtered[@]}"
    else
      bash "$ROOT/68-user-mgmt/verify.sh"
    fi
    ;;
  e2e-matrix)
    # Pure test harness -- no helpers loaded, no root required, runs
    # everything inside mktemp sandboxes and stubs.
    bash "$ROOT/_shared/tests/e2e/run-matrix.sh"
    ;;
  defapp-passthrough)
    # Filter empties (some bash versions add a stray "" when "$@" was
    # empty at capture time -- same dance as other passthroughs).
    _defapp_filtered=()
    for _a in "${DEFAPP_REST[@]:-}"; do [ -n "$_a" ] && _defapp_filtered+=("$_a"); done
    if [ "${#_defapp_filtered[@]}" -gt 0 ]; then
      bash "$ROOT/default-apps/run.sh" "$DEFAPP_KIND" "${_defapp_filtered[@]}"
    else
      bash "$ROOT/default-apps/run.sh" "$DEFAPP_KIND"
    fi
    ;;
  install|check|repair|uninstall)
    if [ -n "$ONLY_ID" ]; then
      run_one "$ONLY_ID" "$VERB"
    else
      ids=$(registry_list_ids)
      if [ "$VERB" = "install" ] && [ "$PARALLEL" -gt 1 ]; then
        log_info "Running install in parallel (N=$PARALLEL)"
        cmds=()
        for id in $ids; do cmds+=("bash '$ROOT/run.sh' install -I $id"); done
        run_parallel "$PARALLEL" "${cmds[@]}"
      else
        for id in $ids; do
          run_one "$id" "$VERB" || log_warn "[$id] returned non-zero"
        done
      fi
    fi
    ;;
  *) show_help ;;
esac
