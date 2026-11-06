# SeekZip — Reference Research (Clean-Room)

Compiled 2026-11-07 from public sources only: MacPacker README / website / MacRumors
developer thread (github.com/sarensw/MacPacker), PeaZip documentation and Wikipedia,
7-zip.org (download page, license, 7z(1) man page), libarchive project documentation,
and The Unarchiver / XADMaster format-support tables (unar README).

**Clean-room rule applied throughout:** only features, behaviour, file-format facts and
public CLI contracts were studied. No reference source code was read for implementation
details and nothing was copied. See "Clean-room / license notes".

---

## 1. Feature matrix to match / beat

### 1.1 MacPacker (the direct competitor — native Swift/SwiftUI, macOS 14.6+, GPL-3.0)

Source: MacPacker README and macpacker.app (v1.2.x era site, repo at v0.19 beta).

| Capability | MacPacker |
|---|---|
| Browse without extracting | Yes — Finder-like window, breadcrumbs, sortable columns, in-archive search, keyboard navigation matching Finder |
| Preview | Spacebar Quick Look on entries, stated to work without writing the file to disk first |
| Nested archives | Yes — drill into archive-in-archive in the app **and** in its Quick Look extension |
| Selective extraction | Drag individual files/folders out to Finder |
| Smart extraction | Multiple top-level items land in a folder named after the archive; a single top folder is not double-nested |
| Create | ZIP and 7z only; from a Compress window or Finder right-click; optional password (AES-256), optional split volumes (`.zip.001`, `.7z.001`) |
| Edit in place | Add / replace / delete entries in ZIP and 7z, save in place |
| Read formats | 40+ formats / ~66 extensions: archives (7z, ar, arj, cab, cbr/cbz, chm, cpio, deb, exe, jar, lha/lzh, lzx, msi, pkg, rar, rpm, sea, sit, sitx, tar, xar, zip, zipx, apk, aar), disk images (dmg, iso, wim, vdi, vhd, vhdx, vmdk, qcow2, squashfs, fat, ntfs), single-file compression (bz2, gz, lz4, lzma, xz, z), tarballs (tgz/tbz2/txz/tlzma/tar.lz4/taz), split sets (zip.001, z01, 7z.001) |
| Encrypted archives | Opens password-protected archives (AES-256 and ZipCrypto on create) |
| Format detection | By magic number, not just extension |
| macOS metadata | Finder tags, custom icons, permissions and symlinks survive archive/extract round-trips |
| Extensions | Quick Look extension (incl. comic archives cbz/cbr), Finder right-click extension with configurable menu entries |
| Integrity check / recovery | **Not yet** — listed on its public roadmap as "coming next". Gap SeekZip can beat |
| Distribution | Sandboxed, signed, notarised; GitHub Releases, Homebrew cask, Mac App Store; 21 languages |

**Engine architecture (publicly documented behaviour):** MacPacker is multi-engine.
Public bug reports and release notes reference at least the **7-Zip engine** and the
**XAD engine**, a per-format engine choice in Settings → Archive Formats, and
**Automatic engine selection** added in v0.19.0-beta.1. Documented behavioural
differences that motivate the multi-engine design:

- The XAD engine preserves original *creation* dates; the engines differ in metadata fidelity.
- For a ZIP with encrypted contents but an unencrypted header, the 7-Zip engine
  produced empty previews while XAD opened the files correctly (fixed later for 7-Zip).
- For a 7z archive with an encrypted header (`-mhe=on`), MacPacker tells the user to
  switch to the 7-Zip engine — XAD cannot open it (consistent with XADMaster's
  "7z: no encryption" limitation, §2.3).
- Its Quick Look extension shares the app's engine settings through an App Group
  (`ArchiveEngineConfigStore`), so engine choice is a single source of truth across
  app + extensions.
- The repo vendors dependencies and test archives as **git submodules**; public
  discussion also tracks upstream engine CVEs (e.g. a 7-Zip RCE fixed in 7-Zip 26.02)
  as release-note items — i.e. engine version is treated as a security surface.

### 1.2 PeaZip (feature ceiling for power features — LGPL, Free Pascal/Lazarus, cross-platform)

Source: PeaZip site/Wikipedia (v11.x; 234 supported extensions as of 9.4.0).

Worth matching from PeaZip's matrix:

- **Archive test** as a first-class operation (test one/many archives, with password variant).
- **Checksum/hash tooling** for files *and* archives: multiple algorithms, save/verify
  checksum files, byte-for-byte file comparison.
- **Archive conversion**: open in one format, write out in another (batch-capable).
- **Job queue / job definition**: GUI operations can be queued, logged, and **exported
  as a command line** for inspection/reuse in scripts; archive "layouts" can be saved
  and restored to speed up repeat archiving/backup jobs.
- **Batch operations**: create/extract/convert multiple archives at once; "add each
  object to a separate archive".
- **In-archive editing**: open a file inside an archive, edit, save back (added 6.9.2);
  add files to root or subfolders of an existing archive.
- **Filters**: fine-grained multiple inclusion/exclusion filter rules on archive
  contents; flat (non-tree) browsing mode as an alternative view; search + history.
- **Split and join** of plain files (file spanning) independent of archive formats.
- **Encryption depth**: AES-256 in 7z and ZIP; optional **two-factor** (password +
  keyfile); encrypted password manager; random password/keyfile generator.
- **Secure deletion** of files, and free-space wipe (PeaUtils suite: hash, compare,
  secure delete, hex preview).
- **Duplicate-file detection** inside selections/archives.
- **System benchmark** (it reuses the 7-Zip benchmark) with exportable results.
- **Self-extracting archives**, bookmarks for archives/folders, on-the-fly image
  thumbnails without writing a cache to disk.
- Create formats: 7Z, ARC, BZ2, GZ, PAQ/LPAQ/ZPAQ, PEA, TAR, WIM, ZIP (+ split);
  browse/test/extract for ~200 more. (PEA/ARC/PAQ are PeaZip-ecosystem formats —
  **not** worth matching for SeekZip; the queue/test/hash/convert/job-export ideas are.)

### 1.3 Baseline every serious competitor ships (7-Zip GUI / WinRAR / BetterZip class)

- Test integrity, per-entry CRC display, archive properties/comment.
- Compression profiles: level (Store→Ultra), method (LZMA2/Deflate/PPMd/BZip2),
  dictionary, solid on/off + solid block size, thread count.
- Split volumes with named size presets; pause/cancel with a clean partial state.
- Repair attempts / extract-ignoring-errors for damaged archives (WinRAR strength).

### 1.4 Where SeekZip can beat the field

1. **Integrity check + recovery is still "coming next" on MacPacker's roadmap** —
   ship test/verify + checksum files in v1, not later.
2. **PeaZip-class job system on macOS**: queue with pause/resume, job log, and
   "copy as CLI invocation" — no native Mac competitor exposes this well.
3. **Conversion** (e.g. RAR→7z, ZIP→7z) as a one-step queued job.
4. **Checksum tooling** (hash files, verify `.sha256`, find duplicates) built in.
5. Large-file engineering (streaming, Zip64, 100k+ entries) with a published test
   matrix — none of the reference apps document this publicly.

---

## 2. Engine comparison and recommendation

### 2.1 Official 7-Zip console binary (`7zz`) — primary engine candidate

- Official macOS build from 7-zip.org: "7-Zip for MacOS: console version", distributed
  as a `.tar.xz` for macOS (arm64 / x86-64). The binary is named **`7zz`** (not `7z`);
  Homebrew's `p7zip`/`sevenzip` naming differs and lags upstream. Current upstream
  release on the download page at research time: **7-Zip 26.05 (2026-10-21)**.
- `7zz` is the **full** console version (unlike reduced `7za`): packing/unpacking for
  7z, XZ, BZIP2, GZIP, TAR, ZIP, WIM; unpacking-only for ~35 more incl. RAR/RAR5,
  ISO, DMG, HFS, NTFS, FAT, SquashFS, VDI/VHD/VHDX/VMDK, QCOW2, CAB, CHM, MSI, NSIS,
  CPIO, RPM, DEB, XAR, Z, UDF, GPT/MBR images.
- Strong AES-256 for 7z (data **and** header/filename encryption via `-mhe=on`) and
  for ZIP (WinZip AES standard; ZIP format itself has no filename encryption).
  Reads legacy ZipCrypto. Does **not** support every third-party ZIP-AES variant
  (e.g. pkAES-encrypted headers are a known failure case in the 7-Zip forums).
- Zip64 fully supported (read/write; required automatically past 4 GiB / 65,535 entries).
- Split volumes: create with `-v{size}` (`-v100m` → `.7z.001`, `.7z.002`, …);
  open by pointing at the first volume.
- Solid archives (LZMA/LZMA2, `-ms=on`) — best ratios, but selective extraction is
  expensive (see Risks).
- Multi-threaded compression (`-mmt`), benchmark command (`b`) built in.
- RAR is **extract-only** (unRAR-derived code); RAR creation is proprietary and no
  engine in this study can do it. 7-Zip also ignores RAR recovery records.

### 2.2 libarchive / bsdtar

- C library (BSD 2-clause), streaming architecture; front-ends `bsdtar`/`bsdcpio`.
  macOS ships a system libarchive/bsdtar, but the bundled system version historically
  lags upstream by years — ship our own build if used.
- Reads: tar family (ustar, pax, GNU tar incl. long names/sparse), cpio variants,
  ISO9660 (Joliet/Rock Ridge), ZIP (incl. encrypted ZIP) and ZIPX (bzip2/zstd/ppmd/
  lzma/xz entries), 7z (incl. zstd-compressed 7z), RAR and RAR5 (with limitations),
  CAB, LHA/LZH, XAR, ar, mtree; filters gzip/bzip2/xz/zstd/lz4/lzip etc.
- Writes: tar/pax/cpio, ISO, ZIP, 7z, xar, mtree, shar — but streaming-only:
  **no in-place modification and no random access** by design.
- Hard limits vs 7zz (documented by libarchive and third-party guides):
  **cannot decrypt encrypted 7z or RAR** (fails with "Reading encrypted data is not
  currently supported"; encrypted ZIP is OK), and **no multi-volume support** in the
  CLI/library workflow (`.7z.001` sets must go to 7-Zip).
- Strengths: best-in-class tar/pax fidelity (ACLs, xattrs, sparse files), excellent
  automatic format detection, embeddable as an in-process library (no subprocess
  parsing), permissive licence.

### 2.3 XADMaster (The Unarchiver's engine)

- Objective-C library by Dag Ågren / MacPaw, **LGPL-2.1**; ships with `lsar` (list)
  and `unar` (extract) CLI tools. **Extraction only — creates nothing.**
- Format table (unar README / The Unarchiver):
  - ZIP: **Full** — AES, Zip64, Mac OS extensions, Deflate64/Bzip/LZMA/PPMd methods,
    self-extracting EXEs.
  - RAR: **Full** — including encryption and multiple volumes, RAR SFX.
  - 7z: **most methods, but NO encryption** — the single biggest functional hole.
  - TAR/GZIP/BZIP2/LZMA/XZ: Full. NSIS: extensive. EXE SFX: partial. Split raw
    files (.001/.002 join): basic.
  - Legacy long tail nobody else covers well: StuffIt (no encryption), StuffIt X
    (partial, no JPEG compression), DiskDoubler, Compact Pro, PackIt, Ace (pre-2.0
    only), ARJ (no multi-part), ARC, Zoo, LZH/LZX, Amiga formats via bundled libxad.
- Standout feature: **filename-encoding autodetection** (Mozilla charset-detector
  heritage) — best-in-class recovery of CP932/GBK/CP1251 filenames that other engines
  show as mojibake. This is a primary reason The Unarchiver keeps users.
- Weaknesses: no creation/editing at all; upstream pace is slow (app at 4.3.9,
  March 2025); Objective-C/GNUstep-era codebase; per-format support is uneven and
  must be checked per format, not assumed from the headline list.

### 2.4 Comparison summary

| | 7zz | libarchive | XADMaster |
|---|---|---|---|
| Role fit | Create/edit/test + modern formats | Streaming read/write, tar family | Legacy read/extract fallback |
| Licence | LGPL-2.1+ (+ unRAR restriction, some BSD parts) | BSD 2-clause | LGPL-2.1 |
| Integration | Subprocess + stdout parsing | In-process C library | In-process ObjC library (or `lsar`/`unar` subprocess) |
| Create ZIP/7z | Yes / Yes | Yes / Yes (limited options) | No / No |
| Edit in place | Yes (`a`/`d`/`rn`/`u`) | No (stream rewrite only) | No |
| Encrypted 7z (incl. header) | Yes | **No** | **No** |
| Encrypted RAR | Yes (extract) | No | Yes (extract) |
| Encrypted ZIP | Yes (AES + ZipCrypto) | Yes | Yes (AES) |
| Split volumes | Create + read | No | Read some (RAR yes, raw join basic) |
| RAR5 extract | Yes | Yes (limitations) | Yes |
| Legacy formats (StuffIt etc.) | No | Few | **Best** |
| Filename-encoding recovery | Manual (`-scs`/`-mcp`) | Partial | **Automatic, best** |
| Tar/pax fidelity | Adequate | **Best** | Adequate |
| Test/verify command | Yes (`t`, CRC) | Via full read | Via full extract only |

### 2.5 Recommendation

- **SeekZipCore exposes an `ArchiveEngine` protocol with an explicit capability
  matrix** (canCreate, canEdit, canTest, encrypted7z, split, formats…) — routing is
  data-driven, never hard-coded per screen. This mirrors the pattern MacPacker
  converged on (per-format engine pick + automatic selection) without copying it.
- **Primary engine: bundled official `7zz`** (arm64), invoked as a separate process.
  It alone covers creation, editing, testing, encrypted 7z, split volumes and RAR5.
  Process isolation doubles as a security boundary for hostile archives.
- **Fallback engine: XADMaster-derived read path** (or its `lsar`/`unar` tools) for
  legacy formats, encoding-broken filenames, and as a second opinion when 7zz fails
  or returns empty/garbled results — the exact failure pairs MacPacker users report.
- **libarchive: defer to v1.1** unless tar-fidelity bugs appear; if added, bundle our
  own build (system copy is old). Its streaming model is attractive for huge tarballs.
- Automatic engine selection: try engines in capability order, record which engine
  handled an archive, surface it in the UI/log, and let users override per format.
- Pin and **checksum the bundled 7zz**, track upstream releases/CVEs as a release
  blocker checklist item (see Risks), and keep `License.txt` beside the binary.

---

## 3. `7zz` CLI contract notes

Command grammar: `7zz <command> [switches] <archive> [files...] [@listfile]`.
Commands SeekZip needs: `a` add/create, `d` delete, `rn` rename, `u` update,
`e` extract flat, `x` extract with paths, `l` list, `t` test, `h` hash, `b` benchmark,
`i` format info.

### 3.1 Key switches

| Switch | Meaning / notes |
|---|---|
| `-t{type}` | Force archive type (`-tzip`, `-t7z`, `-ttar`…); also `-tzip` needed when creating `.zip` from an ambiguous name |
| `-p{password}` | Password (no space). Also prompts interactively if omitted for encrypted input — see cautions |
| `-mhe=on` | 7z header (filename) encryption (7z only, requires `-p`) |
| `-mx={0..9}` | Compression level; 0 = store |
| `-m0=lzma2` etc. | Method chain per format (`-m` family is format-specific — validate per target type) |
| `-ms=on/off` | Solid mode (7z); `-ms={size}` solid block size |
| `-mmt={n}` | Thread count (default: all cores) |
| `-v{size}` | Split volumes: `-v100m`, `-v2g`; suffixes b/k/m/g |
| `-o{dir}` | Output directory (no space after `-o`) |
| `-y` | Assume Yes on all queries — **mandatory** for automation |
| `-aoa` / `-aou` / `-aot` | Overwrite mode: all / auto-rename extracting file / auto-rename existing file |
| `-slt` | Technical listing for `l` (see §3.2) |
| `-sccUTF-8` | Console output charset = UTF-8 (set explicitly; default follows locale) |
| `-scsUTF-8` | List-file / charset handling for filenames in related switches |
| `-mcp={codepage}` | Filename codepage for legacy ZIPs when autodetection fails |
| `-bb[0-3]` | Log level to stderr/stdout |
| `-bsp1` | Redirect progress lines to stdout (parse `%` lines); `-bso`/`-bse` control stdout/stderr streams |
| `-spf` | Store full paths (incl. drive/root) on add — use deliberately |
| `-snl` / `-snh` | Store symlinks / hardlinks as links |
| `-xr!` / `-x!` | Exclude patterns on add/extract |
| `--` | Stop switch parsing (protects filenames starting with `-`) |

Exit codes (7z(1) man page — the authoritative list):

| Code | Meaning |
|---|---|
| 0 | Normal — no errors or warnings |
| 1 | Warning, non-fatal (e.g. some files unreadable during compression, so skipped) |
| 2 | Fatal error (includes wrong password, CRC failure on test/extract, truncated archive) |
| 7 | Bad command-line parameters |
| 8 | Not enough memory |
| 255 | User stopped the process (Ctrl-C / termination) |

⚠️ Some secondary docs/man-page mirrors garble this table (3/4/5 renumbering). Trust
7/8/255. Treat **1 as "succeeded with warnings"**, never as clean success: parse the
warning text (e.g. "Headers Error", "Data Error", unreadable-file lists).

### 3.2 Parsing `7zz l -slt`

Output anatomy (stable across modern versions):

```
<banner: version line, locale/threads line>
Scanning the drive for archives:
1 file, 356873 bytes (349 KiB)

Listing archive: protected.zip

--
Path = protected.zip
Type = zip
Physical Size = 356873

----------
Path = encoded.png
Folder = -
Size = 356705
Packed Size = 356717
Modified = 2025-06-07 08:43:07
Created =
Accessed =
Attributes = A
Encrypted = +
Comment =
CRC = DC0D4039
Method = ZipCrypto Store
Host OS = FAT
Version = 20
Volume Index = 0
Offset = 306264399
<blank line>
... next entry ...
```

Contract facts and cautions:

1. **Two block types.** First block (after `--`) describes the archive itself
   (`Path`, `Type`, `Physical Size`, plus format-specific keys: `Method`, `Solid`,
   `Blocks`, `Headers Size`, `Offset`, `Comment`, …). A line of ten dashes
   (`----------`) separates it from entry blocks. Entry blocks are separated by
   blank lines; each line is `Key = Value`.
2. **Split on the first ` = ` only.** Values — above all `Path` — may themselves
   contain ` = `. Never split on every `=`.
3. **Filenames can contain newlines.** A `Path` value with an embedded newline
   breaks naive line/block parsing (documented weakness of the `l` output format).
   Mitigations: sanity-check parsed entries (known key set, monotonic offsets where
   present), prefer `-slt` over the columnar `l` output (columns are worse), and
   cross-check entry counts against the trailing summary. Accept residual risk for
   adversarial names; XAD/libarchive listing is the fallback for such archives.
4. **Field sets vary by format and entry kind.** ZIP entries add `Folder`,
   `Comment`, `Host OS`, `Version`, `Characteristics`, `Offset`, `Volume Index`;
   7z entries add `Block`; folders have `Folder = +`, `Size = 0`, often no `CRC` /
   `Method = Store`-ish values. **Every field is optional in practice** — model all
   as optional. `Created`/`Accessed` are frequently empty. `Modified` may carry
   fractional seconds (`2026-02-20 09:06:13.8740000`) or be empty.
5. **Solid archives:** per-entry `Packed Size` may be **empty** (the bytes live in a
   shared solid block); group by `Block`. Don't compute per-file ratios from it.
6. **`Encrypted` is `+` / `-`.** `Method` reveals the scheme: `ZipCrypto …`,
   `AES-256 …`, `LZMA … 7zAES…`, `pkAES-256 …` (the last is a known unsupported
   case — surface "unsupported encryption" instead of a generic failure).
7. **Header-encrypted 7z** cannot even be listed without the right `-p…`; failure
   exit code is 2 with a password/headers error — map this to a password prompt,
   not to "corrupt archive". Wrong password on data-encrypted archives also exits 2,
   sometimes only at `t`/`x` time after a successful `l`.
8. **Interactive prompts hang subprocesses.** Without `-y`, overwrite and password
   prompts block forever on a pipe. Always pass `-y`, always pass `-p` explicitly
   (even `-p""` semantics where relevant), and close stdin or feed it deliberately.
9. **Password on the command line is visible** in the process list to other local
   processes while 7zz runs. 7zz offers no env-var/stdin password channel — accept
   and document the risk; keep operation windows short; never log the argument vector.
10. **Streaming parse for huge archives.** `l -slt` on a 1M-entry archive produces
    hundreds of MB of text. Parse incrementally from the pipe; never hold full stdout
    in memory; build the entry tree incrementally. (Plain `l` column output wraps and
    localises — do not parse it.)
11. **Progress:** with `-bsp1`, progress is emitted as percentage lines interleaved
    on stdout during `a`/`x`/`e`/`t`; keep progress parsing separate from `-slt`
    parsing (different commands), strip `\r` updates, and rely on exit code + final
    summary, not on reaching "100%".
12. **Locale/banner variance:** the banner and "Scanning…" preamble vary by version
    and build (official 7zz vs p7zip `7z` differ). Skip everything until the `--`
    marker; don't assert on banner text. Pin one bundled build and re-run parser
    golden tests on every engine bump.
13. `7zz h -scrcSHA256` produces hash listings usable for checksum features; its
    column layout is version-sensitive too — parse defensively or compute hashes
    natively in Swift for files we extracted ourselves.

### 3.3 Behavioural notes

- `e` flattens paths (collision-prone); SeekZip selective extraction should use `x`
  with explicit include patterns into a controlled temp dir, then move into place.
- 7zz **does not by itself guarantee zip-slip safety for every format**: validate
  every entry path (no absolute paths, no `..` escape, symlink/hardlink targets
  contained) in SeekZipCore before/independent of extraction, and extract into a
  staging directory.
- Editing (`a`/`d`/`rn` on an existing archive) rewrites the archive; a crash or
  full disk mid-edit can destroy the only copy — SeekZip must operate on a temp copy
  and atomically replace (also gives us free "undo" on failure).
- `t` verifies CRCs by decompressing everything — on multi-GB solid archives this is
  a full read; show progress and allow cancel (terminate → exit 255 path).

---

## 4. Clean-room / license notes

Process rules used for this document and required for the build:

- Reference projects were studied at **feature/behaviour level only** (READMEs,
  websites, docs, public issue reports). Their source code is not to be read,
  adapted, or paraphrased into SeekZip. All SeekZip code is written from the
  functional spec and public format/CLI documentation.
- File-format facts (ZIP/7z headers, `-slt` grammar, exit codes) are public
  documentation facts, not protectable expression — safe to use.

Licence inventory:

| Component | Licence | Consequence for SeekZip |
|---|---|---|
| MacPacker | **GPL-3.0** | Feature reference only. Copying code would force SeekZip itself under GPL-3.0 (copyleft on the whole app). Even "small" borrowed functions taint. Keep the study at docs/behaviour level, as done here. |
| PeaZip | **LGPL** (app; bundles 7-Zip etc.) | Feature reference only; no code reuse is needed or planned. |
| 7-Zip / `7zz` binary | **LGPL-2.1-or-later** for most code; **unRAR restriction** on the RAR decompression parts (may not be used to reimplement RAR compression); some parts BSD 3-clause; LZMA SDK public domain | Bundling the **unmodified** official binary as a separate, user-replaceable executable invoked via `Process` is the standard LGPL-compliant route (the pattern used by e.g. JetBrains' bundling: ship `License.txt`, offer corresponding source, let users drop in a replacement binary). Ship `License.txt` + a source-availability note in the app bundle. Do not statically link 7-Zip code into SeekZip binaries. Respect the unRAR restriction (we never create RAR anyway). |
| libarchive | **BSD 2-clause** | Permissive: may link/embed with attribution in notices. No copyleft concerns. |
| XADMaster (+ libxad) | **LGPL-2.1** | If linked as a library, LGPL obligations apply (relability/reverse-engineering allowance, license text, source offer for the library). Using its `lsar`/`unar` as separate executables keeps the boundary simplest. |
| RAR format | Proprietary (win.rar GmbH) | **No engine may create RAR.** Creation support is permanently out of scope; extraction only. |
| ZIP AES | WinZip AES spec, implemented by 7-Zip | Interoperable; filename encryption is not part of ZIP AES — only 7z `-mhe` hides names. Set user expectations in UI copy. |

Also: `7zz` bundled inside a sandboxed/notarised app must itself be signed (and the
app's entitlements must permit spawning it); verify the official binary's signature
requirements at packaging time and re-sign consistently with the release pipeline.

---

## 5. Risks

1. **Parser fragility (highest engineering risk).** `-slt` is a human-readable
   format, not an API: embedded newlines/` = ` in filenames, per-format field drift,
   banner/locale variance. Mitigations in §3.2; plus golden-file parser tests pinned
   to the bundled 7zz version, re-run on every engine update.
2. **Engine CVE cadence.** Archive parsers are a proven RCE surface — public
   MacPacker discussion cites a crafted-archive 7-Zip RCE fixed only in 7-Zip 26.02
   (CVE-2026-14266). Mitigations: run engines out-of-process with least privilege,
   keep bundled engines current, never parse untrusted archives in the app process
   with a native library where a subprocess option exists, fuzz the listing parser.
3. **Zip-slip / link attacks.** Malicious `../`, absolute paths, symlink/hardlink
   escapes, device files, and overwrite races. SeekZipCore must enforce its own
   containment policy on staged extraction regardless of engine defaults; test with
   hostile fixtures (part of the large-file/adversarial test matrix).
4. **Zip bombs & resource exhaustion.** High-ratio archives (e.g. 42.zip-style
   nesting, quilted bombs) — enforce expansion-ratio and total-size warnings,
   incremental disk-space checks during extraction, and a working cancel that
   cleans partial output.
5. **Solid-archive selective extraction cost.** Pulling one file from a large solid
   7z block can require decompressing the whole block; naive progress/ETA will lie.
   Surface "solid" state in the UI (from `Solid`/`Block` listing fields) and set
   expectations; consider XAD/libarchive only where they genuinely help (often they
   face the same format constraint).
6. **Password UX & security.** Wrong-password vs corrupt-archive both surface as
   exit 2 — error taxonomy must use stderr text + operation phase. Passwords appear
   in the subprocess argument list (§3.2.9). Keychain storage must be opt-in.
   Non-ASCII passwords are an interoperability minefield across engines (encoding
   of the password bytes differs) — include in the test matrix.
7. **In-place edit data loss.** Any engine's edit rewrites the archive; disk-full or
   crash mid-write destroys data. Temp-copy + atomic swap is mandatory, plus free-
   space preflight (archive size + working margin).
8. **Format long tail disappointment.** Headline "supports N formats" hides
   per-format caveats (XAD 7z-no-encryption, libarchive no-encrypted-7z/RAR,
   7-Zip pkAES gaps, StuffIt X partial…). The capability matrix must be per-format
   and user-visible in error messages ("switch engine" hints like MacPacker's),
   not buried in docs.
9. **App Store / sandbox constraints.** Bundled CLI spawning, file access via
   security-scoped bookmarks, and Quick Look/Finder extensions sharing settings
   (App Group) all need early prototyping — MacPacker proves it's achievable
   sandboxed + notarised, but it constrains engine packaging choices.
10. **Licence drift.** If SeekZip's own licence is ever meant to be non-GPL,
    discipline must be maintained: no MacPacker (GPL-3.0) code, LGPL components kept
    as separate executables/libraries with notices, and a THIRD_PARTY_NOTICES file
    maintained from day one.
11. **Upstream dependency pace.** XADMaster/The Unarchiver updates slowly; official
    7zz releases are infrequent but security-critical. Pin versions, automate
    update checks in CI, and don't depend on system-provided tools (`/usr/bin/tar`,
    Homebrew) being present or current.

---

*End of reference. Next documents: ARCHITECTURE.md (SeekZipCore engine protocol +
capability matrix) and TEST-MATRIX.md (large-file and adversarial fixtures).*
