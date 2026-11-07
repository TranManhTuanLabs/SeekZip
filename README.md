# SeekZip

**English** | [Tiếng Việt](README.vi.md) | [简体中文](README.zh-CN.md)

**Find it inside. Extract only what you need.**

Docs: [Build from zero](docs/BUILD_FROM_ZERO.md) ·
[Architecture](docs/ARCHITECTURE.md) ·
[Test matrix](docs/TEST-MATRIX.md) ·
[Agent handoff](docs/HANDOFF.md) ·
[Reference research](docs/REFERENCE.md) ·
[Release guide](docs/RELEASE.md)
(each also available in Tiếng Việt and 简体中文 with `.vi.md` / `.zh-CN.md` suffixes)

A free, native macOS archive manager for Apple Silicon — browse and preview
archives before extracting, extract only the files you select, and create or
edit archives. Built clean-room in Swift/SwiftUI after studying reference
projects (see `docs/REFERENCE.md`); no third-party app code is copied.

## Architecture

One engine, three frontends:

```
            ┌─────────────┐
            │ SeekZipApp  │  SwiftUI GUI (browse, preview, queue)
            ├─────────────┤
 frontends  │ seekzip     │  CLI — scriptable, `--json`, stable exit codes
            ├─────────────┤
            │ seekzip-mcp │  MCP server (stdio) for AI assistants
            └──────┬──────┘
                   │
            ┌──────▼──────┐
            │SeekZipCore  │  engine wrapper, listing parser, path safety,
            │             │  queue, models — the only place logic lives
            └──────┬──────┘
                   │  Process (streaming, never loads archives into RAM)
            ┌──────▼──────┐
            │  7zz (7-Zip)│  bundled official macOS ARM binary (primary)
            ├─────────────┤
            │ lsar / unar │  XADMaster fallback (legacy formats, M6)
            └─────────────┘
```

Why a CLI *and* MCP, not just terminal access to 7-Zip? A raw terminal gives
AI and scripts unstructured text, no shared queue/password state, and no
built-in zip-slip protection. The CLI gives structured JSON and stable exit
codes (and is what runs the test matrix headlessly in CI); the MCP server is
a thin schema layer on top of the same core, so AI assistants get safe,
typed tools (`list_archive`, `extract_entries`, …) instead of shell parsing.

## Status

v0.1 scaffold: core models, `7zz -slt` listing parser, extraction path
safety, CLI, MCP server skeleton, SwiftUI browser skeleton, full test
matrix spec (`docs/TEST-MATRIX.md`), macOS CI.

M1 green: `swift build` + `swift test` + CLI smoke tests pass on CI
(macos-15). M2 done: listing streams from `7zz` (incremental parser,
progress, cancel, `list --stream`). M3 done: preview (text streams in
via `7zz e -so`, capped at 64 KB / 200 lines; images, PDFs and binary
entries defer to Quick Look) and nested archives (`list outer.zip
inner.zip`, `preview outer.zip "inner.zip!/file.txt"`). GUI preview
wiring is code only until the M7 Xcode project. M4 done: persistent job
queue — batch extract/create/test with pause/resume/cancel, temp-name +
atomic-rename creation, free-space precheck, and clean Ctrl-C handling —
via `seekzip queue` and MCP queue tools. The GUI queue panel is code
only until the M7 Xcode project. M5 done: create/edit polish — add,
remove and rename entries in ZIP/7z/TAR archives (temp copy + atomic
rename, so a failed edit never corrupts the original), conversion
(ZIP ↔ 7z ↔ TAR; RAR cannot be created), per-entry CRC-32/SHA-256
checksums with a `verify` command, and passwords stored in the macOS
Keychain (`SEEKZIP_PASSWORD` env var as the other channel, never a
`-p` argument). The GUI edit panel and CRC column are code only until
the M7 Xcode project. M6 done: XAD fallback engine behind a routing protocol — `ArchiveEngine` with a
capability matrix, `EngineRouter` (7zz first, XAD fallback on failure/empty listing, XAD-first for legacy
formats like StuffIt/Zoo/ARC; encrypted 7z always stays on 7zz), XAD list/extract/test via `lsar`/`unar`
(extraction-only, staged extract so a failed run leaves no partial output, filename-encoding recovery kept
in entry metadata), CLI `--engine auto|7zz|xad` + `seekzip engines`, MCP `engine` argument + `list_engines`,
GUI engine settings (code only until the M7 Xcode project). `seekzip list/test/extract` report which engine
handled the archive.

M7 done: extensions & packaging — `SeekZip.xcodeproj` (app + Finder
Sync + Quick Look preview extensions, sharing SeekZipCore as a static
library and engine settings through an App Group), the 7zz/lsar/unar
binaries staged by `scripts/package-engines.sh` (7-Zip 26.05,
SHA-256-pinned) into the app bundle's `Resources/Helpers/` and signed
with the inherit entitlement, `scripts/release.sh` (archive, Developer
ID export, notarise, staple, DMG/ZIP), and Homebrew formula + cask in
`packaging/homebrew/` (tap `TranManhTuanLabs/homebrew-seekzip`). The
XAD preview gap from M6 is closed: previewing an entry of an XAD-only
archive now extracts just that entry to a temp dir and reads the
capped head (same 64 KB / 200-line rules). The GUI still needs its
first real build on a Mac with full Xcode — see `docs/RELEASE.md`.

## Build (on a Mac)

```sh
swift build          # core + CLI + MCP (GUI needs full Xcode, see Package.swift)
swift test           # unit tests for parser and path safety
./Tests/Matrix/generate-matrix.sh   # build the edge-case fixture archives
```

App (Xcode project — first build needs a Mac with full Xcode):

```sh
open SeekZip.xcodeproj   # set your Team, then Product > Build (⌘B)
./scripts/package-engines.sh   # stage 7zz/lsar/unar into build/Helpers
./scripts/release.sh           # archive, notarise, DMG (needs DEVELOPER_TEAM_ID)
```

See `docs/RELEASE.md` for the full release checklist, including the
Apple Developer account and disk-space questions that must be settled
before the first signed release.

## Queue

```sh
seekzip queue add extract big.zip ~/out   # enqueue; does not run yet
seekzip queue add create out.7z src --format 7z
seekzip queue run                         # run queued jobs in order
seekzip queue list                        # persisted jobs — survives relaunch
seekzip queue pause <id>                  # SIGSTOP; resume continues in place
seekzip queue cancel <id>                 # terminates 7zz, cleans up temp output
```

Jobs run one at a time and are stored in
`~/Library/Application Support/SeekZip/queue.json`. Creating an archive
writes to a staging directory first and renames into place on success,
so a cancelled or failed create leaves no half-written file. Extracts
and creates check free space first and fail fast when the destination
volume cannot hold the result. Passwords are never written to the queue
file — they come from `SEEKZIP_PASSWORD` or the Keychain (see below).

## Edit, convert, verify

```sh
seekzip add archive.zip newfile.txt --into docs   # add entries (ZIP/7z/TAR)
seekzip remove archive.zip old.txt                # remove entries
seekzip rename archive.zip old.txt new.txt        # rename (ZIP/7z only)
seekzip convert archive.zip archive.7z            # convert ZIP → 7z (also 7z → ZIP, TAR → 7z)
seekzip verify archive.zip [--sha256]             # re-check every entry's CRC (and SHA-256)
seekzip checksums archive.zip                     # CRC-32 of every entry, from the listing
```

Every edit works on a temp copy in the same folder and only replaces the
original with an atomic rename after the edited copy lists cleanly — a
failed edit leaves the original byte-for-byte untouched. Conversion
extracts to a temp dir and re-creates the archive; entry names and
contents survive, and converting *to* RAR fails with a clear error (no
third-party tool can create RAR). `verify` streams each entry, hashes it
(CRC-32, plus SHA-256 with `--sha256`) and compares it with the listing
CRC; a bad entry is reported and the rest are still checked.

## Passwords

```sh
SEEKZIP_PASSWORD=hunter2 seekzip list secret.zip  # env var (never a -p argument)
seekzip password store secret.zip                 # save in the macOS Keychain (prompts, twice)
seekzip password forget secret.zip                # forget the stored password
```

A password is never accepted as a command-line argument (it would show
in the process list). The CLI takes it from `SEEKZIP_PASSWORD` or from
the stored password — macOS Keychain (`com.seekzip.passwords`) in the
app and on the CLI, an in-memory store only on Linux test runs. An
explicit password always wins over the stored one. MCP tools take the
same `password` field (`add_entries`, `remove_entries`, `rename_entries`,
`convert_archive`, `verify_archive`).

RAR archives can be extracted but not created — RAR creation is proprietary
(this is true of every macOS archiver).

## License

MIT (planned). Bundled `7zz` remains under the 7-Zip LGPL license.
