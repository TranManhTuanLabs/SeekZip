# SeekZip — Product & Engineering Spec (v0.1)

## Product

Free native macOS (14.6+, Apple Silicon arm64) archive manager that matches
7-Zip/WinRAR on Windows and beats Keka/BetterZip on preview:

- Browse archives like Finder folders: tree/list/columns, tabs, instant
  filter/search inside the archive, nested archives opened in place.
- Preview without extracting: images, text/code, PDF via Quick Look;
  Space-bar preview like Finder.
- Selective extract: checkboxes/drag-out of individual entries; extract
  here / to folder / to chosen destination.
- Create & edit ZIP and 7z: add/remove/rename entries, AES-256 encryption,
  split volumes, compression levels incl. Ultra, solid 7z.
- Extract everything 7zz reads: ZIP/ZIPX, 7z, RAR4/RAR5 (extract only),
  TAR + gz/bz2/xz/zst/lz4, ISO, DMG, CAB, WIM, ARJ, LZH, MSI, DEB/RPM…
- Integrity test + SHA-256 checksums; batch queue with pause/resume/cancel.
- Finder integration: context-menu extension, Quick Look extension,
  drag & drop onto the Dock icon.
- Passwords in Keychain; filename-encoding detection (UTF-8, CP932/Shift-JIS,
  GBK, CP1252) with manual override.
- Safety by default: zip-slip / absolute-path / symlink-escape blocking,
  zip-bomb ratio warning before extraction, free-space precheck.

## Large-file rules (hard requirements)

1. Streaming only: the engine talks to `7zz` as a subprocess; archive bytes
   are never loaded into memory. Listing parses `-slt` output as a stream.
2. Zip64 end-to-end (archives and single entries > 4 GB).
3. Targets: 50 GB archive, 10 GB single entry, 1,000,000 entries listing
   without UI freeze (pagination/virtualised list, background parse).
4. Multithreaded LZMA2 (`-mmt=on`) using all cores.
5. Every operation cancellable; partial output is written to a temp name
   and renamed on success, so a cancelled/failed job never leaves a
   half-written file that looks complete.
6. Free-space precheck before extraction (uncompressed size vs volume
   free space), with an explicit override.

## Frontends

- **GUI** (`SeekZipApp`): SwiftUI + AppKit where needed.
- **CLI** (`seekzip`): `list | test | extract | create | hash`, `--json`
  machine-readable output, stable exit codes (0 ok, 2 usage, 3 engine,
  4 safety-blocked, 5 password). This is the automation and CI surface.
- **MCP** (`seekzip-mcp`): stdio JSON-RPC server exposing typed tools
  (`list_archive`, `test_archive`, `extract_entries`, `create_archive`,
  `hash_file`) implemented on SeekZipCore. Ships in v1.1 once the CLI
  contract is stable.

## Engine routing (from docs/REFERENCE.md)

- Primary engine: bundled official `7zz` subprocess — the only engine with
  create/edit/test, header-encrypted 7z and RAR5.
- Fallback (phase 2): XADMaster (`unar`/`lsar`) behind the same
  `ArchiveEngine` protocol for legacy formats and filename-encoding
  recovery, and as a second opinion where 7zz fails — the failure pairs
  are documented in REFERENCE.md §1.1/§2. libarchive is deferred to v1.1.
- Differentiators vs MacPacker: integrity test/recovery and checksums in
  v1 (still "coming next" on MacPacker's public roadmap), archive
  conversion, and a published large-file test matrix.

## Non-goals

- Creating RAR (proprietary — impossible for any third-party app).
- Cloud storage, accounts, ads, telemetry. Fully offline.
