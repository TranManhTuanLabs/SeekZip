# SeekZip

**English** | [Tiếng Việt](README.vi.md) | [简体中文](README.zh-CN.md)

**Find it inside. Extract only what you need.**

Docs: [Build from zero](docs/BUILD_FROM_ZERO.md) ·
[Architecture](docs/ARCHITECTURE.md) ·
[Test matrix](docs/TEST-MATRIX.md) ·
[Agent handoff](docs/HANDOFF.md) ·
[Reference research](docs/REFERENCE.md)
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
            │  7zz (7-Zip)│  bundled official macOS ARM binary
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
only until the M7 Xcode project.

## Build (on a Mac)

```sh
swift build          # core + CLI + MCP (GUI needs full Xcode, see Package.swift)
swift test           # unit tests for parser and path safety
./Tests/Matrix/generate-matrix.sh   # build the edge-case fixture archives
```

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
volume cannot hold the result. Passwords are kept in memory only and
are never written to the queue file.

RAR archives can be extracted but not created — RAR creation is proprietary
(this is true of every macOS archiver).

## License

MIT (planned). Bundled `7zz` remains under the 7-Zip LGPL license.
