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
- **Not yet compile-verified**: the code was authored on a Linux machine
  without Swift/Xcode. First job on a Mac: `swift build && swift test`
  (see `docs/BUILD_FROM_ZERO.md`) and fix whatever surfaces.
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
4. Pick the top unfinished milestone (§5), work in small commits.
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
5. **M5 — Create/edit polish**: add/remove/rename entries, conversion,
   checksums UI, Keychain passwords.
6. **M6 — XAD fallback engine** behind the routing protocol.
7. **M7 — Extensions & packaging**: Finder + Quick Look extensions,
   bundled signed 7zz, notarised release, Homebrew cask.

## 6. Trilingual documentation rule

`README.md` and `docs/BUILD_FROM_ZERO.md`, `docs/ARCHITECTURE.md`,
`docs/HANDOFF.md`, `docs/TEST-MATRIX.md` exist in three content-identical
versions: English (no suffix), Vietnamese (`.vi.md`), Simplified Chinese
(`.zh-CN.md`). **When you edit one language, update the other two in the
same commit** — or, if you cannot, add a `> ⚠️ Translation may be stale`
note to the outdated files and flag it in §2. English is the source of
truth when versions disagree.

## 7. Known limitations (v0.1)

- Listing output is buffered in memory (fine to ~100k entries; M2 fixes).
- CLI has no `-p` flag yet; passwords work via Core API and MCP.
- Extraction does not yet do free-space precheck or temp-name staging.
- GUI is a skeleton: no preview, tabs, queue, or drag-out yet.
- Passwords passed to `7zz` via `-p` are visible in the local process
  list (accepted, documented risk).

## 8. Open questions for the owner

- GitHub repo location/account for CI (CI workflow is ready to run).
- Distribution: GitHub Releases + Homebrew first, Mac App Store later?
  (Sandboxing affects engine bundling and file access.)
