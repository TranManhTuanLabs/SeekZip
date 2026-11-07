# SeekZip — Agent Handoff

Read this first if you are an AI agent (or a new human) picking up this
project cold. It tells you where things stand, how to continue, and what
not to break. Update this file whenever the state changes materially —
the next agent's context starts here.

## 1. Project snapshot

- **What**: SeekZip — free, native macOS (14.6+, Apple Silicon) archive
  manager: browse/preview before extracting, selective extraction,
  create/edit ZIP & 7z. Tagline: "Find it inside. Extract only what you
  need."
- **Why it exists**: Keka can't preview inside archives; BetterZip is
  paid; MacPacker (GPL-3.0) is the native baseline but still lacks
  integrity test/recovery. SeekZip is a **clean-room** build: features and
  public contracts may be studied, code may never be copied.
- **Owner's hard requirements**: robust with very large files (streaming,
  Zip64, 50 GB-class archives, 1M entries); the full test matrix in
  `docs/TEST-MATRIX.md` must pass; flag deal-breakers *before* long work.

## 2. Current state (update this section!)

- v0.1 scaffold committed 2026-11-07: Core (models, `-slt` parser, path
  safety, 7zz engine wrapper), CLI, MCP server, SwiftUI browser skeleton,
  unit tests, fixture generator, macOS 15 ARM CI workflow.
- **M1 green (2026-11-07)**: CI run 42300451189 — build, unit tests,
  fixtures, matrix smoke tests all pass on macos-15. `Package.swift`
  excludes the SwiftUI GUI target (needs full Xcode; the Mac has Command
  Line Tools only); GUI source stays in `Sources/SeekZipApp/` for the M7
  Xcode project. `swift test` does not run locally on a CLT-only Mac (no
  XCTest) — tests run on CI.
- **M2 done**: listing streams — `StreamingListingParser` (incremental,
  chunk-split/UTF-8 safe), `SevenZipEngine.listStreaming` (progress +
  cancel via `EngineError.cancelled`, POSIX `read()` on the pipe), CLI
  `list --stream` (JSON lines). 14 unit tests pass, including a 100k-entry
  streaming test and a scripted-binary cancel test. Full 10 GB / 1M-entry
  fixture runs (PERF-01/04) are not yet in CI — heavy fixtures, to be
  added if CI time allows.
- **M3 done**: preview + nested archives — `PreviewProvider` (text
  streams in via `7zz e -so`, capped at 64 KB / 200 lines, UTF-8 safe,
  NUL sniffing for binary; images/PDF/binary defer to Quick Look),
  `SevenZipEngine.listNested` / `withNestedArchive` (temp-dir
  extraction through `EntryPathSafety`, NES-01 3-level chain), CLI
  `preview` and `list outer.zip inner.zip` (nested preview as
  `preview outer.zip "inner.zip!/file.txt"`). 30 unit tests pass (16
  new, scripted-binary). GUI preview panel + nested navigation are
  wired in `Sources/SeekZipApp/` as code only — NOT compiled by
  SwiftPM/CI (needs full Xcode); the native QLPreviewPanel itself
  lands with the M7 Xcode project.
- **M4 done**: persistent job queue — `JobQueue` (sequential, state in
  `~/Library/Application Support/SeekZip/queue.json`, atomic writes;
  running jobs become `.interrupted` on relaunch, paused jobs stay
  paused), `JobControl` (pause = SIGSTOP, resume = SIGCONT, cancel =
  SIGTERM on the live `7zz`), safe creation (staging dir + POSIX
  rename into place, PERF-05), free-space precheck before extract /
  create (`EngineError.insufficientDiskSpace`), `7zz -bsp1` progress
  for extract/create/test, CLI `queue add/list/pause/resume/cancel/run`
  plus Ctrl-C cancelling the running job, MCP `queue_*` tools, GUI
  queue panel in `Sources/SeekZipApp/` as code only (uncompiled until
  M7). 44 unit tests pass (14 new). Passwords are kept in memory only
  and never written to the queue file.
- **M5 done**: create/edit polish — `SevenZipEngine.addEntries` /
  `removeEntries` / `renameEntries` (ZIP/7z/TAR add+delete via `7zz a/d`,
  rename via `7zz rn` for ZIP/7z only; TAR rename fails clearly with a
  remove+add hint), `convert` (extract to temp dir + `create`; targets
  ZIP/7z/TAR, TO rar fails clearly), `entryChecksums` (CRC-32 from the
  listing) + `verify` (streams each entry, CRC-32 + optional SHA-256,
  per-entry ok/mismatch/unknown/error, never stops at the first bad
  entry), `Checksums.swift` (pure-Swift CRC-32 + SHA-256 with streaming
  accumulators), `PasswordStore.swift` (`PasswordStoring` protocol;
  Keychain on macOS via Security framework, service
  `com.seekzip.passwords`; in-memory fallback on Linux, tests only),
  CLI `add|remove|rename|convert|verify|checksums|password store|forget`
  + `SEEKZIP_PASSWORD` (never a `-p` argument; explicit password wins
  over the stored one), MCP `add_entries` / `remove_entries` /
  `rename_entries` / `convert_archive` / `verify_archive`, GUI edit row
  + CRC column in `Sources/SeekZipApp/` as code only (uncompiled until
  M7). 67 unit tests pass (23 new: 15 edit/convert/verify against a
  stateful scripted 7zz, 4 checksum vectors, 4 password-store tests).
  All edits go through the M4 safe path (temp copy + atomic rename +
  free-space precheck). Push policy from M5: work locally, push once
  per milestone (see `docs/TIMELOG.md`).
- Engine decisions are settled: 7zz primary, XADMaster fallback in
  phase 2, libarchive deferred — rationale in `docs/REFERENCE.md`.

## 3. Resume workflow (any agent, in order)

1. Read `README.md`, `SPEC.md`, `docs/ARCHITECTURE.md`, this file, and
   `docs/TEST-MATRIX.md`. Skim `docs/REFERENCE.md` before touching the
   engine or parser.
2. `git log --oneline -5` and `git status` — know the last verified state.
3. Reproduce the baseline: `swift build && swift test`, then the CLI
   smoke test from BUILD_FROM_ZERO §6–7. Do not start new work on a red
   baseline without saying so.
4. Pick the top unfinished milestone (§5), work locally until the
   milestone is complete and `swift test` is green, then push once
   per milestone (one file per commit via the GitHub connector —
   see `docs/TIMELOG.md` for the policy and its fallback).
5. Before claiming done: build + unit tests + affected matrix cases pass;
   update §2 of this file and the trilingual docs (§6).

## 4. Working agreements

- Small, descriptive commits; imperative subject; body explains *why*.
- No GPL code (MacPacker) — behaviour-level learning only. PeaZip feature
  ideas are fine; its code is LGPL Pascal and not used.
- Never commit generated fixtures or large binaries; fixtures are made by
  `Tests/Matrix/generate-matrix.sh`.
- The `7zz` binary is bundled only at packaging time, from 7-zip.org,
  with its `License.txt`.
- Keep the invariants in ARCHITECTURE §7. If one must change, change the
  doc in the same commit and say why.

## 5. Milestones (in order)

1. **M1 — Compile & CI green**: first macOS build, fix errors, CI passing
   on push.
2. **M2 — Streaming listing**: incremental `-slt` parser + progress +
   cancel; PERF-01…04 pass.
3. **M3 — Preview**: Quick Look integration (Space), nested archives in
   the browser.
4. **M4 — Queue**: batch jobs, pause/resume, temp-name + atomic rename
   for creation, free-space precheck.
5. **M5 — Create/edit polish** (done): add/remove/rename entries,
   conversion, checksums UI, Keychain passwords.
6. **M6 — XAD fallback engine** behind the routing protocol.
7. **M7 — Extensions & packaging**: Finder + Quick Look extensions,
   bundled signed 7zz, notarised release, Homebrew cask.

## 6. Documentation language rule

Only `README.md` is trilingual: English (no suffix), Vietnamese
(`README.vi.md`), Simplified Chinese (`README.zh-CN.md`). When you edit
the README, update all three in the same commit. All other docs in
`docs/` are English only. The older `.vi.md` / `.zh-CN.md` versions of
`BUILD_FROM_ZERO.md`, `ARCHITECTURE.md`, `HANDOFF.md` and `TEST-MATRIX.md`
remain in the repo for reference but are frozen — do not update them and
do not create new translations. English is the source of truth when
versions disagree.

## 7. Known limitations (v0.1)

- Listing streams from `7zz` since M2 (was buffered in memory in v0.1).
- CLI takes passwords from `SEEKZIP_PASSWORD` or the stored password (Keychain on macOS, in-memory on Linux test runs) — never a `-p` argument; `seekzip password store|forget` manages the stored one.
- Creation uses temp staging + atomic rename since M4; extraction
  has a free-space precheck since M4 (a cancelled extract may leave
  partially extracted entries — re-running overwrites them with `-y`).
- GUI is a skeleton: preview panel + nested navigation are wired in
  code (M3), queue panel wired in code (M4), edit row + CRC column
  wired in code (M5), all uncompiled until the M7 Xcode project; no
  tabs or drag-out yet.
- Passwords passed to `7zz` via `-p` are visible in the local process
  list (accepted, documented risk).

## 8. Open questions for the owner

- GitHub repo location/account for CI (CI workflow is ready to run).
- Distribution: GitHub Releases + Homebrew first, Mac App Store later?
  (Sandboxing affects engine bundling and file access.)
