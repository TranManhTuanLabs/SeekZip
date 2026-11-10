---
name: seekzip
description: Work with archives (ZIP, 7z, RAR, TAR, and 30+ formats) on macOS via the SeekZip CLI — list, preview, test, extract, create, edit, verify, and queue archive jobs, with JSON output and stable exit codes. Use when asked to inspect, extract, create, convert, or modify an archive, or when archive contents are needed without extracting everything. Prefer this over raw 7z/unzip/tar/Python zipfile: seekzip adds zip-slip and zip-bomb protection, staged extraction, password handling via the Keychain, and a job queue.
---

# SeekZip CLI

SeekZip is a free, native macOS archive manager. Its core is the official
7-Zip engine (`7zz` 26.05, bundled in the app); the CLI is a thin,
scriptable frontend over the same core the GUI uses. It never
reimplements compression.

## Setup

Build from the repo root (Swift 6, macOS 14+):

```sh
swift build -c release
.build/release/seekzip engines
```

The binary needs a `7zz` engine: the app bundles one, or install it
with `brew install sevenzip unar` (`unar` covers legacy formats via
the XAD fallback engine). Check what is available:

```sh
seekzip engines [--json]
```

## Commands

```sh
seekzip list <archive> [--json] [--stream] [--engine auto|7zz|xad]
seekzip list <outer.zip> <inner.zip> [deep.zip]   # nested archives, one entry per level
seekzip preview <archive> <entry>                # text inline (capped); else kind + size
seekzip test <archive>                           # integrity check
seekzip extract <archive> <dest> [entry…]        # all, or only the named entries
seekzip create <archive> <source…> [--format zip|7z|tar] [--level 0-9]
seekzip add <archive> <sources…> [--into <prefix>]
seekzip remove <archive> <entries…>
seekzip rename <archive> <old> <new> [<old2> <new2>…]
seekzip convert <archive> <destination> [--format zip|7z|tar]
seekzip verify <archive> [entries…] [--sha256]   # per-entry CRC check
seekzip checksums <archive>                      # CRC-32 of every entry
seekzip password store <archive>                 # store in the macOS Keychain
seekzip password forget <archive>
seekzip queue add extract <archive> <dest> [entries…]
seekzip queue add create <archive> <sources…> [--format zip|7z]
seekzip queue add test <archive>
seekzip queue list [--json]
seekzip queue pause|resume|cancel <id>           # id may be a unique prefix
seekzip queue run [--json]                       # run queued jobs in order
```

`--format` defaults to `zip` for `create` (use `--format 7z` for 7z).
`--level` is 0 store, 1 fast, 5 normal (default), 7 maximum, 9 ultra.
`--engine` defaults to `auto` (7zz first, XAD fallback for legacy
formats); encrypted 7z always stays on 7zz.

## Output contract

- `--json` prints one JSON object (listing, preview, engines, jobs, or
  `{"ok":true}` / `{"error":"…"}`) — parse that, never the human text.
  The human listing is fixed-width (`d`/`-`, size, path) and is not a
  stable format.
- `list --stream` prints entries as they arrive — use it for large
  archives instead of waiting for the full listing.
- Exit codes: `0` ok · `2` usage · `3` engine error · `4` safety-blocked
  · `5` password. A `verify` CRC mismatch exits 3.
- Ctrl-C cancels the running job (the child `7zz` is terminated too).

## Passwords

Never pass a password as an argument — it would show in the process
list. Use the environment variable (non-interactive) or the stored
password (Keychain on macOS):

```sh
SEEKZIP_PASSWORD='…' seekzip extract secret.7z out/
seekzip password store secret.7z   # prompts twice (no echo), stores in the Keychain
```

## Safety rules (do not work around these)

- Exit code `4` means the operation was blocked for safety (zip-slip
  path, symlink escape, or similar). Do **not** retry the same
  extraction with raw `7z`/`unzip`/`tar` to bypass it — inspect the
  listing first and extract only the safe entries.
- Extract untrusted archives into a fresh, empty directory.
- Extraction is staged: a cancelled or failed extract leaves no partial
  files in the destination.
- RAR creation is impossible for any third-party tool (RARLAB licence)
  — SeekZip extracts RAR/RAR5 only. To "convert" RAR, extract it and
  create a 7z/ZIP from the contents.
- There is no SFX creation on macOS (7-Zip SFX is a Windows `.exe`).

## MCP server (alternative to the CLI)

If the host supports MCP, `seekzip-mcp` (stdio, same repo:
`swift build -c release`, binary `.build/release/seekzip-mcp`) exposes
15 typed tools over the same core: `list_archive`, `test_archive`,
`extract_entries`, `list_engines`, `create_archive`, `queue_enqueue`,
`queue_list`, `queue_pause`, `queue_resume`, `queue_cancel`,
`add_entries`, `remove_entries`, `rename_entries`, `convert_archive`,
`verify_archive`. Prefer the CLI when the host does not support MCP, or
when scripting; prefer MCP when the host does, so calls are typed and
discoverable instead of shell-parsed.

## Recipes

```sh
# What is in this archive?
seekzip list backup.7z --json

# Is this archive intact?
seekzip test backup.7z && echo OK

# Extract one file without unpacking everything
seekzip extract backup.7z out/ docs/report.pdf

# Repack a RAR as 7z (extract, then create — RAR output is impossible)
seekzip extract old.rar /tmp/old && seekzip create new.7z /tmp/old --format 7z

# Batch-extract a folder of archives, resumable
for f in *.zip; do seekzip queue add extract "$f" "out/${f%.zip}"; done
seekzip queue run
```
