# SeekZip Test Matrix

Every case runs headlessly through the `seekzip` CLI in CI (macOS ARM
runner) and must pass before a release. Fixtures are produced by
`Tests/Matrix/generate-matrix.sh`; large fixtures are generated on the
runner, never committed.

## Formats (FMT)
- FMT-01 ZIP store/deflate/bzip2/lzma (zipx) — list, preview, extract, test
- FMT-02 7z solid and non-solid, LZMA2 multithreaded
- FMT-03 RAR4 and RAR5 (extract only), incl. recovery records
- FMT-04 tar, tar.gz, tar.bz2, tar.xz, tar.zst, tar.lz4
- FMT-05 ISO, DMG, CAB, WIM, ARJ, LZH, MSI, DEB, RPM, XAR
- FMT-06 Self-extracting stubs and archives with prepended junk

## Large files & performance (PERF)
- PERF-01 Archive of 10 GB: list < 5 s, peak RSS < 300 MB
- PERF-02 Single entry of 10 GB (sparse + real data variants)
- PERF-03 Zip64: archive > 4 GB total, entry > 4 GB, offset > 4 GB
- PERF-04 1,000,000 entries: listing streams, UI stays responsive,
  filter returns results incrementally
- PERF-05 Create 20 GB 7z with `-mmt=on`: all cores busy, cancel at 50%
  leaves no half-written final file (temp name cleaned or clearly marked)
- PERF-06 Pause/resume queue across app relaunch

## Encryption (ENC)
- ENC-01 ZIP legacy ZipCrypto (open with correct password)
- ENC-02 ZIP AES-256; 7z AES-256 with encrypted headers (`-mhe=on`)
- ENC-03 Wrong password: clean error, no partial extraction, exit code 5
- ENC-04 Unicode password (Vietnamese diacritics, emoji)
- ENC-05 Password from Keychain; wrong stored password falls back to prompt — CLI `password store` + `SEEKZIP_PASSWORD`, M5

## Split volumes (SPL)
- SPL-01 ZIP split (.z01…), 7z volumes (.7z.001…), RAR parts (part1.rar…)
- SPL-02 Missing middle volume: precise error naming the missing part
- SPL-03 Volumes on different folders prompt for the next volume's location

## Corruption (COR)
- COR-01 Truncated archive (50%, 99%): header error, no crash
- COR-02 Bit-flipped entry data: CRC failure reported per entry; other
  entries still extract — `seekzip verify` reports it per entry (M5)
- COR-03 Corrupted central directory; salvage mode extracts what's readable
- COR-04 Not an archive at all (random bytes, empty file, directory as input)

## Edit & conversion (EDT)
- EDT-01 Add entries to ZIP and 7z (with `--into` prefix); the new
  entry appears with the right CRC
- EDT-02 Remove entries from ZIP, 7z and TAR; removing a missing entry
  fails before the archive is touched
- EDT-03 Rename entries in ZIP and 7z; renaming to an existing name
  fails; TAR rename fails with a clear error
- EDT-04 Add/remove to RAR fails with a clear error (extraction-only
  format)
- EDT-05 Failed edit (7zz exits non-zero) leaves the original
  byte-for-byte untouched, no temp files left
- EDT-06 Conversion ZIP → 7z → ZIP round-trip: entry names and CRCs
  survive; converting TO RAR fails clearly
- EDT-07 `verify` re-checks every entry's CRC (plus SHA-256 with
  `--sha256`); a corrupted entry is reported as a mismatch and the
  rest are still checked

## Nesting & structure (NES)
- NES-01 Archive inside archive inside archive (3 levels) opened in place
- NES-02 Empty archive; archive with only empty folders
- NES-03 Duplicate entry names; entries differing only by case on APFS
- NES-04 Very deep paths (> 1024 chars) and 255-char filename components

## Preview (PRV)
- PRV-01 Text preview: first 200 lines / 64 KB, UTF-8 safe, truncation noted
- PRV-02 Image, PDF and binary entries: no content read, Quick Look verdict
- PRV-03 Encrypted entry without a password: clean "needs password" verdict
- PRV-04 Entry inside a 2-level nested archive previews (via `listNested`)
- PRV-05 Preview of a huge entry never decompresses it in full (stream stops at the limit)

## Filenames & encodings (NAM)
- NAM-01 UTF-8 names with Vietnamese diacritics and emoji
- NAM-02 Shift-JIS (CP932) ZIP from Windows Japan; GBK ZIP; CP1252 ZIP —
  detected or manually selectable encoding, no mojibake
- NAM-03 Names containing `=`, leading/trailing spaces, `..` inside a name
- NAM-04 macOS specifics: `__MACOSX`, `.DS_Store`, resource forks, xattrs

## Safety (SEC)
- SEC-01 Zip-slip: `../` and absolute-path entries are blocked (exit 4)
- SEC-02 Symlink/hardlink entries pointing outside the destination blocked
- SEC-03 Zip bomb (42.zip-style nested + flat 1000:1 ratio): warning shown,
  extraction requires explicit confirmation
- SEC-04 Disk full mid-extraction: clean failure, partial files removed,
  source archive untouched
- SEC-05 Destination read-only or removed mid-operation (USB unplugged)

## Cross-checks (XCHK)
- XCHK-01 Every fixture also listed/tested with official 7-Zip and bsdtar;
  entry lists and CRCs must agree
- XCHK-02 Archives created by SeekZip open in 7-Zip, WinRAR, Keka, The
  Unarchiver and macOS Archive Utility without warnings
