# SeekZip Architecture

## 1. Shape

One engine core, three thin frontends. All archive logic lives in
`SeekZipCore`; frontends never invoke `7zz`, parse its output, or touch
entry paths themselves.

```
SeekZipApp (SwiftUI) ─┐
seekzip (CLI) ────────┼──► SeekZipCore ──► 7zz subprocess ──► archive files
seekzip-mcp (MCP) ────┘        │
                               └──► XADMaster (`lsar`/`unar`) fallback (M6)
```

## 2. Modules

| Module | Responsibility |
|---|---|
| `SeekZipCore/ArchiveEntry.swift` | `ArchiveEntry`, `ArchiveInfo` value models (Codable — the same shapes the CLI prints as JSON and MCP returns). `ArchiveInfo.engine` names the handling engine (M6); `ArchiveEntry.filenameEncoding` keeps XAD's recovered filename encoding (M6) |
| `SeekZipCore/ArchiveEngine.swift` | `ArchiveEngine` protocol (M6) + `EngineRouter` (7zz first, XAD fallback, per-format overrides) + `EngineCapabilities` matrix + `EngineSummary` + `UnavailableEngine` placeholder |
| `SeekZipCore/XADMasterEngine.swift` | XADMaster fallback engine (M6): `lsar -j` listing (JSON) + `unar` extraction into a staging dir, then move into place; extraction-only, no encrypted 7z, encoding recovery preserved |
| `SeekZipCore/ListingParser.swift` | Parses `7zz l -slt` technical listings into models |
| `SeekZipCore/EntryPathSafety.swift` | Zip-slip / absolute-path / symlink policy, zip-bomb heuristic |
| `SeekZipCore/SevenZipEngine.swift` | Subprocess wrapper: list, test, extract (selective), create, nested listing, entry streaming; cancellable/pausable runs with `-bsp1` progress (M4), temp-staged atomic creation (M4); edit in place — add/remove/rename (M5), convert (M5), `entryChecksums`/`verify` (M5) |
| `SeekZipCore/PreviewProvider.swift` | Entry previews (M3): text streams in capped at 64 KB / 200 lines, images/PDF/binary defer to Quick Look |
| `SeekZipCore/JobControl.swift` | Pause (SIGSTOP) / resume (SIGCONT) / cancel (SIGTERM) handle for a running `7zz` process, plus `JobProgress` (M4) |
| `SeekZipCore/JobQueue.swift` | Persistent sequential job queue (M4): `JobDescriptor`/`JobRecord`, atomic JSON store, `DiskSpace` free-space precheck. Runs on any `ArchiveEngine` (M6: the router, so queued extracts route too) |
| `SeekZipCore/Checksums.swift` | Pure-Swift CRC-32 (IEEE) and SHA-256 (FIPS 180-4), one-shot + streaming accumulators (M5) — no CryptoKit, so it runs on the Linux test toolchain too |
| `SeekZipCore/PasswordStore.swift` | `PasswordStoring` protocol; Keychain on macOS (Security framework, service `com.seekzip.passwords`) and an in-memory fallback on Linux, tests only (M5) |
| `SeekZipCLI/main.swift` | Argument handling, human/JSON output, exit-code mapping, `queue` subcommands, Ctrl-C via DispatchSource (M4); `add`/`remove`/`rename`/`convert`/`verify`/`checksums`/`password` subcommands, `SEEKZIP_PASSWORD` (M5); `--engine auto\|7zz\|xad` + `engines` command (M6) |
| `SeekZipMCP/main.swift` | MCP stdio JSON-RPC server; tool schemas; delegates to Core; `queue_*` tools on a background runner (M4); `add_entries`/`remove_entries`/`rename_entries`/`convert_archive`/`verify_archive` (M5); `engine` argument on list/test/extract + `list_engines` (M6) |
| `SeekZipApp/SeekZipApp.swift` | SwiftUI browser: open, filter, select, extract, preview (Space), nested navigation, queue panel (M4), edit row + CRC column (M5), engine settings + "handled by" label (M6) |

## 3. Data flow — listing an archive

1. Frontend asks Core for `list(archive:password:)`.
2. `SevenZipEngine` runs `7zz l -slt -sccUTF-8 [-p…] <archive>` with
   **stdin set to `/dev/null`** (a password prompt must fail fast, never
   block) and captures stdout.
3. `ListingParser` splits the header at the `--` line, then reads one
   `Key = Value` block per entry, splitting on the *first* `" = "` only
   (filenames may contain `=` and spaces).
4. Exit code 2 with a password/headers error maps to `EngineError
   .wrongPassword` — header-encrypted archives are a password prompt,
   not corruption. See `docs/REFERENCE.md` §3 for the full 7zz contract.
5. Frontends render `ArchiveInfo`. Since M2 the listing parses as a
   stream (`StreamingListingParser` + `SevenZipEngine.listStreaming`);
   the 1M-entry case still needs a virtualised UI (M3+, see TEST-MATRIX
   PERF-04). Since M3, nested archives list in place
   (`SevenZipEngine.listNested` / `withNestedArchive`) and entries
   preview without extracting (`PreviewProvider`, `streamEntry` via
   `7zz e -so`); the GUI preview panel and nested navigation are wired
   in code but uncompiled until the M7 Xcode project.

## 4. Data flow — extraction

1. Core lists the archive first and validates **every** entry to be
   extracted with `EntryPathSafety.destinationURL`: the standardised
   destination must remain inside the user-chosen root; absolute paths,
   `..` traversal and (by default) symlinks are violations.
2. `ArchiveInfo.expansionRatio` feeds the zip-bomb warning; the GUI/CLI
   surface it before extracting.
3. `DiskSpace.require` fails fast when the destination volume cannot
   hold the uncompressed listing (M4).
4. Only then does Core run `7zz x -y` with the explicit entry list.
   7zz streams bytes disk-to-disk; archive content never enters this
   process's memory. With a progress callback the run adds `-bsp1` and
   reports percent figures; a `JobControl` can pause (SIGSTOP) or
   cancel (SIGTERM) it mid-run (M4).

## 4b. Data flow — queue (M4)

1. A frontend enqueues a `JobDescriptor` (extract/create/test) into
   `JobQueue`; the record is persisted immediately to
   `~/Library/Application Support/SeekZip/queue.json` (atomic write).
   Passwords are held in memory only and never persisted.
2. `runAll` takes jobs in enqueue order, one at a time, and drives the
   engine with a per-job `JobControl` (progress via `-bsp1`, pause via
   SIGSTOP, cancel via SIGTERM). Every status change is persisted.
3. A job that was `.running` when the process died loads as
   `.interrupted` — it never restarts silently. A `.paused` job stays
   paused; resuming it after a relaunch restarts that job from the
   beginning (a suspended process cannot survive process death).
4. Creation goes through temp staging + atomic rename, so cancel and
   failure leave no half-written final file (PERF-05).
4. CLI maps a safety violation to exit code 4, engine failure to 3.

## 5. Engine routing (M6 — implemented)

`ArchiveEngine` is the engine contract; `SevenZipEngine` and
`XADMasterEngine` (`lsar`/`unar` subprocesses) implement it, and
`EngineRouter` routes across them. Selection order per archive:
explicit selection (`--engine` / MCP `engine` arg) → per-format
override (GUI settings, persisted in UserDefaults) → capability
order (XAD-first for extensions 7zz cannot open at all: sit, sitx,
zoo, arc, cpt, dd, pit, ace, sea; otherwise 7zz first) → fallback
when the primary fails, returns an empty listing for a non-empty
archive, or is missing. Fallback never masks a password error, a
cancel, a full disk or a safety violation, and encrypted 7z stays on
7zz whenever a password is in play (XAD cannot open encrypted 7z).
The handling engine is recorded in `ArchiveInfo.engine` and in the
router's `lastEngine`, and surfaced in the CLI (`list`/`test`/
`extract` output, `seekzip engines`) and MCP (`list_archive`
response, `list_engines` tool). Create/edit/verify/streaming stay on
7zz (XAD is extraction-only); `convert` extracts through the router
and creates through 7zz, so a legacy archive can be the source.
`listNested`/`withNestedArchive` are protocol-extension methods
built on `list`/`extract`, so nesting routes too. libarchive is
deferred (no 7z/RAR decryption, no multi-volume).

## 6. Frontend contracts

**CLI exit codes** (stable, scripted against): `0` ok · `2` usage ·
`3` engine error · `4` safety-blocked · `5` password required/wrong.
`--json` prints exactly one JSON document on stdout; diagnostics go to
stderr.

**MCP tools**: `list_archive`, `test_archive`, `extract_entries`,
`create_archive`, `queue_enqueue`, `queue_list`, `queue_pause`,
`queue_resume`, `queue_cancel`, `add_entries`, `remove_entries`,
`rename_entries`, `convert_archive`, `verify_archive`, `list_engines`
— schemas in `SeekZipMCP/main.swift`. `list_archive` /
`test_archive` / `extract_entries` take an optional `engine`
(`auto`/`7zz`/`xad`); list responses carry the handling engine in
`ArchiveInfo.engine`, test/extract name it in their result text.
The server speaks newline-delimited JSON-RPC 2.0 on stdio (MCP
`2024-11-05`). Queue tools share the CLI's persistent store and run
jobs on a background thread (M4).

## 7. Invariants (do not break)

1. **Streaming**: never load archive bytes (or full extracted files) into
   memory in Core. Listing output is read incrementally from the `7zz`
   pipe and parsed as it arrives (M2); only a 4 KB rolling tail is kept,
   for error reporting. Exception (M6): the XAD listing is buffered —
   `lsar -j` emits one JSON document, so `XADMasterEngine.list`
   collects it first; legacy archives are small and the exception is
   documented, not a pattern to copy.
2. **Safety before engine**: no extraction path reaches `7zz` without
   `EntryPathSafety` validation of the full entry set.
3. **No interactive subprocesses**: stdin is always `/dev/null`; every
   prompt-prone command carries `-y` and an explicit `-p` when needed.
4. **Atomic results**: operations write to temp names and rename on
   success. Creation writes into a staging directory in the
   destination directory and POSIX-renames into place (M4); a
   cancelled/failed create leaves no half-written file. Edits work on
   a temp copy of the archive in the same directory and POSIX-rename
   over the original only after the edited copy lists cleanly (M5); a
   failed edit leaves the original byte-for-byte untouched.
   Extraction destinations are excepted (entries land directly; a
   cancelled extract may leave partial entries, re-running overwrites
   them). Exception (M6): XAD extracts stage into a temp directory
   inside the destination and move into place only on success — a
   failed or cancelled XAD extract leaves no partial output.
5. **Clean-room**: behaviour and public contracts may be learned from
   reference projects; code may not be copied (MacPacker is GPL-3.0).

## 8. Decision log

| Decision | Why |
|---|---|
| Subprocess `7zz` instead of linking a library | Only engine with create/edit/test + header-encrypted 7z + RAR5; process isolation is also a security boundary against crafted archives |
| CLI in v1, MCP as thin layer on Core | CLI is the CI/test-matrix surface and the stable contract; MCP adds schemas, not new logic |
| SwiftPM package for everything | Builds/tests with one command locally and in CI; Xcode project arrives with extensions/signing |
| Passwords via `-p` argument | 7zz's only non-interactive channel; known trade-off: visible in the process list on the same machine (documented risk, REFERENCE.md §5) |
