# SeekZip Architecture

## 1. Shape

One engine core, three thin frontends. All archive logic lives in
`SeekZipCore`; frontends never invoke `7zz`, parse its output, or touch
entry paths themselves.

```
SeekZipApp (SwiftUI) ─┐
seekzip (CLI) ────────┼──► SeekZipCore ──► 7zz subprocess ──► archive files
seekzip-mcp (MCP) ────┘        │
                               └──► (phase 2) XADMaster fallback engine
```

## 2. Modules

| Module | Responsibility |
|---|---|
| `SeekZipCore/ArchiveEntry.swift` | `ArchiveEntry`, `ArchiveInfo` value models (Codable — the same shapes the CLI prints as JSON and MCP returns) |
| `SeekZipCore/ListingParser.swift` | Parses `7zz l -slt` technical listings into models |
| `SeekZipCore/EntryPathSafety.swift` | Zip-slip / absolute-path / symlink policy, zip-bomb heuristic |
| `SeekZipCore/SevenZipEngine.swift` | Subprocess wrapper: list, test, extract (selective), create |
| `SeekZipCLI/main.swift` | Argument handling, human/JSON output, exit-code mapping |
| `SeekZipMCP/main.swift` | MCP stdio JSON-RPC server; tool schemas; delegates to Core |
| `SeekZipApp/SeekZipApp.swift` | SwiftUI browser: open, filter, select, extract |

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
   PERF-04).

## 4. Data flow — extraction

1. Core lists the archive first and validates **every** entry to be
   extracted with `EntryPathSafety.destinationURL`: the standardised
   destination must remain inside the user-chosen root; absolute paths,
   `..` traversal and (by default) symlinks are violations.
2. `ArchiveInfo.expansionRatio` feeds the zip-bomb warning; the GUI/CLI
   surface it before extracting.
3. Only then does Core run `7zz x -y` with the explicit entry list.
   7zz streams bytes disk-to-disk; archive content never enters this
   process's memory.
4. CLI maps a safety violation to exit code 4, engine failure to 3.

## 5. Engine routing (phase 2)

`SevenZipEngine` is the first implementation of an implicit
`ArchiveEngine` contract. Phase 2 formalises the protocol and adds
XADMaster (`unar`/`lsar`) as fallback: better filename-encoding recovery
(Shift-JIS/GBK) and legacy formats, and a second opinion where 7zz
fails. Selection is per-format with automatic fallback — the pattern
documented in `docs/REFERENCE.md` §1–2. libarchive is deferred (no 7z/RAR
decryption, no multi-volume).

## 6. Frontend contracts

**CLI exit codes** (stable, scripted against): `0` ok · `2` usage ·
`3` engine error · `4` safety-blocked · `5` password required/wrong.
`--json` prints exactly one JSON document on stdout; diagnostics go to
stderr.

**MCP tools**: `list_archive`, `test_archive`, `extract_entries`,
`create_archive` — schemas in `SeekZipMCP/main.swift`. The server speaks
newline-delimited JSON-RPC 2.0 on stdio (MCP `2024-11-05`).

## 7. Invariants (do not break)

1. **Streaming**: never load archive bytes (or full extracted files) into
   memory in Core. Listing output is read incrementally from the `7zz`
   pipe and parsed as it arrives (M2); only a 4 KB rolling tail is kept,
   for error reporting.
2. **Safety before engine**: no extraction path reaches `7zz` without
   `EntryPathSafety` validation of the full entry set.
3. **No interactive subprocesses**: stdin is always `/dev/null`; every
   prompt-prone command carries `-y` and an explicit `-p` when needed.
4. **Atomic results**: operations write to temp names and rename on
   success (extraction destinations excepted in v0.1; creation adopts
   this with the queue milestone).
5. **Clean-room**: behaviour and public contracts may be learned from
   reference projects; code may not be copied (MacPacker is GPL-3.0).

## 8. Decision log

| Decision | Why |
|---|---|
| Subprocess `7zz` instead of linking a library | Only engine with create/edit/test + header-encrypted 7z + RAR5; process isolation is also a security boundary against crafted archives |
| CLI in v1, MCP as thin layer on Core | CLI is the CI/test-matrix surface and the stable contract; MCP adds schemas, not new logic |
| SwiftPM package for everything | Builds/tests with one command locally and in CI; Xcode project arrives with extensions/signing |
| Passwords via `-p` argument | 7zz's only non-interactive channel; known trade-off: visible in the process list on the same machine (documented risk, REFERENCE.md §5) |
