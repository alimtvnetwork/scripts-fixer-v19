---
name: llama.cpp prebuilt-binary install (Linux)
description: Linux script 43 downloads pinned prebuilt llama.cpp tarball, symlinks bins, and exposes a sourceable env file -- no compile
type: feature
---

User rule: **llama.cpp must NOT be built/installed from source on Linux.**
Download the prebuilt binary, drop it in `~/.local/share/llama.cpp/<tag>/bin`,
symlink the CLIs into `~/.local/bin`, and write a sourceable env file.

## Files

- `scripts-linux/43-install-llama-cpp/config.json` — pins `tag` (e.g. `b9145`),
  arch->asset map (`x86_64`, `aarch64`), `installRoot`, `binDir`, `envFile`,
  `binaries[]`, `profileSnippetMarker`.
- `scripts-linux/43-install-llama-cpp/run.sh` — `install/check/repair/uninstall`.

## Behaviour

1. Resolves asset by `uname -m` (errors clearly if arch unmapped).
2. Downloads via `fast_download` (aria2c) when present, else curl, else wget.
3. Extracts to `$installRoot/$tag/`; if archive nests `build/bin`, symlinks it
   to `$VERSION_DIR/bin` so the layout is uniform.
4. Symlinks each `binaries[]` entry into `$binDir`.
5. Writes `$envFile` exporting `LLAMA_CPP_HOME`, `LLAMA_CPP_BIN`, and
   prepending to `PATH`.
6. Appends a guarded snippet to `~/.bashrc` and `~/.zshrc` that sources
   the env file (idempotent, marker-fenced).
7. Prints `source "$envFile"` hint so the current shell can activate now.

## Bump procedure

Edit `config.json` `install.tag` to a new release (e.g. `b9300`),
optional asset rename in `install.assets`, then run
`./scripts-linux/run.sh install llama-cpp` (or `repair` to force rebuild
of the install tree).

## CODE-RED logging

Every failure path uses `log_file_error <path> <reason>` (download, extract,
symlink, env-file write, profile-snippet append).
