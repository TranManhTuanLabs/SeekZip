# SeekZip — 7-Zip / WinRAR parity research
**Date researched:** 2026-11-06 (user local Fri 2026-11-06, +07) · **Target:** free native macOS 14.6+, Apple Silicon, Swift/SwiftUI archive manager
**Confidence key:** `verified live` = opened/fetched in this session; `index` = search-index snippet, not re-fetched; `secondary` = blog/aggregator, single-source, treat as directional. Where sources conflict, both are shown — do not silently pick one.

## Summary

**The bar is not “open ZIP”. It is: 7z at Ultra ratio + RAR5 extraction + recovery + fast browse of 1M-entry archives, in a Finder-native UI.**

- **7-Zip latest: 26.05, 2026-10-21** (index: official history). Pack/unpack only 7z, XZ, BZIP2, GZIP, TAR, ZIP, WIM; unpack-only ~30 formats incl. RAR/RAR5, ISO, DMG, CAB, MSI. LZMA/LZMA2 default, PPMd/BZip2/Deflate, AES-256 for 7z+ZIP, optional header/filename encryption (`-mhe=on`), solid (`-ms`), split (`-v`), SFX for 7z, no recovery record. Free LGPL.
- **WinRAR latest stable: 7.23, 2026-06-30** (`verified live` on win-rar.com changelog; 7.30 beta 1/2 is now listed above it — beta, not stable). Only WinRAR/RAR CLI can *create* RAR; everyone else extracts only. RAR5: dict up to 64 GB (default 32 MB), AES-256-CBC, BLAKE2sp optional, Quick Open, paths to 65,535 chars, recovery record (`.rr`) + recovery volumes (`.rev`, `rc`/`rv`), Repair (`r`), SFX, solid, benchmark, $29 one-time / 40-day trial.
- **Power-user verdict (secondary benchmarks, corpus-dependent):** 7z Ultra = smallest, slowest; WinRAR RAR5 = strong middle ground, faster at defaults; ZIP/Zstd = fastest, largest. `-mx=9` costs ~310% time for ~0.9% size vs `-mx=7` in one 2024 benchmark — default to Fast/Normal, offer Ultra as opt-in.
- **macOS gap to exploit:** Keka (free, no Quick Look, no in-place edit — sources conflict on browse), BetterZip 6 ($35, the current power-user bar: browse/edit in place, Quick Look, Finder/Spotlight/Shortcuts), **MacPacker v1.2.0 (free, GPL-3.0, macOS 14.6+, Swift/SwiftUI — the direct SeekZip analogue and closest competitor)**, The Unarchiver 4.3.9 (free, extract-only, legacy formats, encoding detection), PeaZip 11.4.0 (free, 200+/243 formats, cross-platform Qt/Lazarus feel, no native macOS polish, Homebrew cask reported gone in 2026).
- **Hard limits that shape architecture:** (1) RAR creation is legally impossible without RARLAB licence — do not promise it; offer “repack to 7z/ZIP” + optional external `rar` CLI detection like Keka/BetterZip. (2) Mac App Store sandbox: a bundled `7zz` *can* run only if it is inside the bundle, signed with exactly `app-sandbox + inherit`, and inherits the parent sandbox (files only via user-selected/security-scoped bookmarks); launching anything outside the bundle fails. GPL/LGPL + MAS is also a licensing trap. The clean path most Mac archivers take is Developer-ID signed + notarized DMG outside the MAS (Keka, BetterZip, MacPacker all do this; MacPacker is also on MAS, presumably with a trimmed build). (3) 7-Zip CVEs are frequent and severe (symlink traversal, heap overflow, MotW bypass) — pin the engine, ship an in-app update check (7-Zip itself has no auto-updater), and sandbox extraction (no symlink escape, quarantine/MotW equivalent).

---

## 1. 7-Zip — latest version / features

### 1.1 Versions (confirmed, official history)
| Version | Date | Notes |
|---|---|---|
| **26.05** | **2026-10-21** | Improved Z + Mach-O unpacking; bug/vuln fixes |
| 26.04 | 2026-10-05 | Bug/vuln fixes |
| 26.03 | 2026-09-03 | Joliet ISO + Compound; CVE-2026-58052 MotW |
| 26.02 | 2026-06-25 | CVE-2026-14266 XZ heap overflow RCE |
| 26.01 | 2026-04-27 | Linux huge pages (2 MB) ~+10% 7z/xz/LZMA/LZMA2; new `-spo[d\|c\|r]`; CVE-2026-48095 NTFS, CVE-2026-48092 SquashFS |
| 26.00 | 2026-02-12 | Improved ZIP/CPIO/RAR/UFD/QCOW/Compound; File Manager sort (filename as secondary key); benchmark >64 threads |
| 25.01 | 2025-08-03 | CVE-2025-55188 symlink handling hardened |
| 25.00 | 2025-07-05 | **>64 CPU threads** for zip/7z/xz + benchmark (multi processor-group); bzip2 +15–40%, deflate +1–3%; improved zip/cpio/fat |
| 24.09 | 2024-11-29 | Default LZMA/LZMA2 dicts raised (see §1.3); hashes SHA-512, SHA-384, SHA3-256, MD5; `.sha256`/`.sha1` create/check; XXH64/BLAKE2sp in context menu; RAR dict up to 64 GB unpackable, default allowed limit 4 GB (`-smemx`) |

Sources: `index` — https://www.7-zip.org/history.txt ; https://7zip.dev/en/changelog/ ; https://github.com/ip7z/7zip/releases . `verified live` — https://www.7-zip.org/ fetched 2026-11-06 rendered almost no text (JS site, copyright only), so version facts rest on history.txt index, corroborated by 3 mirrors.

### 1.2 Formats — create vs extract-only
**Pack + unpack (official 7-zip.org list):** `7z, XZ, BZIP2, GZIP, TAR, ZIP, WIM`
**Unpack only:** `AR, ARJ, CAB, CHM, CPIO, CramFS, DMG, EXT, FAT, GPT, HFS, IHEX, ISO, LZH, LZMA, MBR, MSI, NSIS, NTFS, QCOW2, RAR, RPM, SquashFS, UDF, UEFI, VDI, VHD, VMDK, XAR, Z` (+ ZIPX unpack-only, APM, FLV, JAR, Office Open XML, SWF per Wikipedia).
Source: `index` — https://en.wikipedia.org/wiki/7-Zip ; Fedora mirror https://www.mail-archive.com/epel-package-announce@lists.fedoraproject.org/msg98551.html (same list). No RAR creation — see §6.

### 1.3 Compression methods / levels
- **Methods in 7z:** LZMA (default historically), **LZMA2 (current default, multithreaded, less expansion on incompressible data)**, PPMd (best on plain text), BZip2, Deflate, Copy/store; pre-filters BCJ/BCJ2 (x86/ARM executables), Delta, ARM/ARM64/RISCV filters (24.09+).
- **Levels `-mx0…9`:** 0=Store, 1=Fastest, 5=Normal, 7=Maximum, 9=Ultra. Default dicts (24.09, 64-bit): mx4 16 MB, mx5 32 MB, mx6 64 MB, mx7 128 MB, mx8/9 256 MB; max LZMA/LZMA2 dict 4 GB (3840 MiB). 32-bit caps at 64 MB.
- **ZIP/GZIP:** 7-Zip's own DEFLATE encoder, claimed 2–10% smaller than PKZip/WinZip (vendor claim, `secondary` — repeat as vendor claim only).
- **Solid archives:** `-ms=on` (default for 7z) — many files as one stream, big win on similar files; cost: extracting one file decompresses all preceding data in the block; corruption in a solid block can lose the whole block. Offer non-solid / small solid-block option for large archives.
- **Split volumes:** `-v<size>[b|k|m|g]` e.g. `-v100m`; parts `.7z.001/.002…`; **header/index lives in the last volume — `.001` alone is not extractable; all parts must be present in one folder.**
- **SFX:** self-extracting `.exe` for 7z (Windows only — no macOS SFX equivalent; do not promise macOS SFX).
- **Hashes:** CRC-32, CRC-64, SHA-1, SHA-256, SHA-512, SHA-384, SHA3-256, MD5, XXH64, BLAKE2sp; can create/check `file.sha256`/`file.sha1` in sha256sum format.
- **Limits:** 7z up to ~16 EiB (2^64) per file and per archive, up to 2^32 (4 bn) files per archive. Source: `index` — https://peazip.github.io/rar-zip-file-format-size-limitations.html ; https://en.m.wikipedia.org/wiki/7z

### 1.4 Encryption
- **AES-256 for 7z and ZIP only.** Key derived via SHA-256-based KDF from password. **Header encryption `-mhe=on` (7z only)** hides filenames/sizes/timestamps — password required just to list. ZIP encryption in 7-Zip is AES-256 (not ZipCrypto by default; Keka uses Zip 2.0 legacy for ZIP — a compatibility trap: AES-ZIP needs a modern extractor).
- No recovery record in 7z — unlike RAR, a flipped byte is detected (CRC) but not repaired.

### 1.5 CLI (the parity surface for scripting users)
`7z <command> [switches] <archive> [files] [@listfile]`
Commands: `a` add, `b` benchmark, `d` delete, `e` extract (no paths), `h` hash, `i` info, `l` list, `rn` rename, `t` test integrity, `u` update, `x` extract with full paths.
Key switches: `-t{type}` (7z/zip/tar/gzip/bzip2/xz), `-m0=lzma2|lzma|ppmd|bzip2|deflate|copy`, `-mx=N`, `-md={dict}`, `-mfb=`, `-ms=on|off`, `-mmt[N]` threads, `-p{password}`, `-mhe=on`, `-v{size}`, `-o{dir}`, `-y`, `-ao{a|s|t|u}` overwrite, `-slt` technical list, `-sfx`, `-i/-x` include/exclude, `-r`, `-w`, `-spf` etc.
Examples: `7z a -t7z -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on archive.7z dir1` ; `7z a -psecret -mhe=on -v100m -mx=9 archive.7z largefile.iso` ; `7z t archive.7z`
Source: `index` — https://manpages.org/7z ; https://www.e2encrypted.com/howtos/how-to-securely-encrypt-decrypt-with-7zip-via-command-line/
**macOS binary is `7zz`** (not `7z`/`7za`): official Linux/macOS CLI since 21.01, `brew install sevenzip` — Homebrew formula `LGPL-2.1-or-later AND BSD-3-Clause`, binary `7zz`. p7zip 16.02 is obsolete. Source: `index` — https://formulae.brew.sh/formula/sevenzip ; https://github.com/Homebrew/homebrew-core/blob/c4aed10c2ba52d90dc02bda1c24ddd20bd179a84/Formula/s/sevenzip.rb

### 1.6 Benchmarks (built-in)
`7z b` — built-in LZMA benchmark (compress/decompress MIPS + usage). 25.00+/26.00 support >64 threads. No built-in “compare my archive” — power users use `7z b` + timed `a`/`x` runs.

---

## 2. WinRAR — latest version / features

### 2.1 Versions
| Version | Date | Status / notes |
|---|---|---|
| **7.23** | **2026-06-30** | **Latest stable** — security: RAR5 recovery-volume heap overflow (CVE-2026-14191, CVSS 7.8, `secondary` via VPN Central), symlink-outside-destination fix, 7zxa.dll → 26.02 |
| 7.22 | 2026-05-01 | Solid RAR4 delete fix (reverted to pre-7.20 behaviour) |
| 7.21 | ~2026-04 | Wrong-extension nested-archive handling; size/time column reverse sort |
| 7.20 | 2026-02 (secondary sources say 4 Feb 2026; one stale source says 2025 — **date conflict, use 2026-02**) | Solid-delete perf, `-ag` mask (K=weekday, O=month name), `-s=` solid modes, `-tk YYYYMMDDHHMMSS`, UTF-8 report + BOM, SFX “Cloud files” option, large ZIP/TAR speed |
| 7.13 | 2025-07-30 | Large memory pages, 64 GB dict, XZ ARM64, `.tar.zst` 128 MB+ dicts, dark mode (secondary) |
| **7.30 beta 1 / beta 2** | 2026 (listed above 7.23) | TAR sparse files, `-lim` disk/memory/time limit (exit 15), `-da` delete-after-extract, `-ed1`, REV limits (4096 vols / 1024 missing) — **beta only, do not ship against** |

Sources: `verified live` — https://www.win-rar.com/whatsnew.html?&L=0 (opened 2026-11-06, lists 7.30 beta 2 first, then 7.23/7.22/7.21/7.20); https://www.win-rar.com/singlenewsview.html?&L=0&tx_ttnews%5Btt_news%5D=304&cHash=0c65306ac391a7c5e6f3056a035efe08 (7.23 announcement, 30 Jun 2026). Stable-release date 7.22 = 2026-05-01 via `index` https://en.wikipedia.org/wiki/RARLAB (Wikipedia infobox, secondary).

### 2.2 Formats
**Create:** RAR (RAR5 only since 7.20 — RAR4 creation dropped) + ZIP. **Unpack:** RAR, ZIP, CAB, ARJ, LZH, ACE, TAR, GZip, UUE, ISO, BZIP2, Z, 7-Zip (+ ZIPX with BZIP2/LZMA/PPMd, XZ). macOS/Linux command-line `rar`/`unrar` exist (RAR 7.x / 6.12 for Mac per secondary) but there is **no WinRAR GUI for macOS**.
Source: `index` — https://www.techspot.com/downloads/67-winrar.html ; https://en.wikipedia.org/wiki/RARLAB

### 2.3 RAR5 — why it matters
- Introduced WinRAR 5.0 (2013). Dict **default 32 MB (was 4 MB in RAR4), max 64 GB** (64-bit; 256 MB on 32-bit; archives with >4 GB dict need WinRAR 7.0+ to extract; 7-Zip asks permission / `-smemx` above 4 GB).
- **AES-256-CBC** (was AES-128), PBKDF2/HMAC-SHA256 KDF (`secondary` — copyprogramming), optional **filename encryption**, optional **BLAKE2sp 256-bit file hash** replacing CRC-32, duplicate-file detection, NTFS hard/symbolic links, **Quick Open record** (fast open of huge archives), paths **up to 65,535 chars** (was 2,047), max file/archive size **16 EiB per Wikipedia / 8 EiB per PeaZip table — conflict, report as “8–16 EiB, effectively unlimited”**.
- Removed in RAR5: per-file comments, authenticity verification, specialised text/WAV/BMP/Itanium codecs (sometimes RAR4 compresses those better — edge case).
- Two extra algorithms added in “RAR7” per Wikipedia (`secondary`, vague — do not quote as a format name; RAR5 is still the format name in 7.20+).

### 2.4 Recovery / repair — WinRAR's killer feature vs 7-Zip
- **Recovery record `-rr[N]` / `rr`:** Reed-Solomon redundancy inside the archive (~1% size ≈ recovers ~0.6% continuously damaged data; up to 524,288 sectors; configurable %).
- **Recovery volumes `-rv[N]` / `rv` + `rc` reconstruct:** `.rev` files rebuild missing/damaged volumes of a multi-volume set; WinRAR auto-reconstructs on unpack if enough `.rev` present.
- **Repair `r`:** two-stage — first uses recovery record, then scans for intact files; `rebuilt.rar`/`_reconst.rar`. Also repairs damaged ZIP.
- **Test `t` / “Test archived files”:** verify CRC/BLAKE2 before trusting; 7.12+: if Test + recovery volumes both on, recovery volumes are also tested.
- **7z has no equivalent** — SeekZip cannot add recovery to 7z/ZIP without inventing a sidecar format; the honest parity move is: (a) extract RAR recovery volumes when present, (b) offer PAR2-style sidecar or “recovery record” only for RAR via external `rar` CLI, (c) surface CRC/BLAKE2 test prominently.

### 2.5 Encryption, solid, split, SFX, UI power features
- Solid: `-s` (incl. `-s=e` extension-grouped, `-s=v` per-volume, `-s=r` reset stats); solid = better ratio, slower single-file access — same trade-off as 7z, plus WinRAR 7.20 optimised solid delete.
- Split: `.partNN.rar` naming (RAR5; RAR4 was `.rNN`); volumes of variable size.
- SFX: GUI + console SFX modules, programmable, ZIP SFX too; 7.13+ ZIP SFX rejects dangerous commands in comments, links default HTTPS (`secondary`).
- UI power users rely on: **dual-pane file manager + tree panel, context-menu shell integration, drag-and-drop, wizard, password manager, archive comments, file-order list (`rarfiles.lst`), profiles/presets, “Generate archive name by mask” (`-ag`), convert archives (incl. to SFX), benchmark tool (compatible across RAR builds), virus scan hook, NTFS ADS + Unix nanosecond timestamps, “Keep broken files” (`-kb`), overwrite modes, repair/test from toolbar.**
- CLI: `rar`/`unrar` — commands `a, x, e, l, v, t, r, rc, rr, rv, s (SFX), c, cf, ch, d, k, m, p, u, f` etc.; switches `-rr, -rv, -s, -sfx, -m0…5` (Store…Best), `-md, -p, -hp` (header encrypt), `-v, -o+, -inul, -tk, -ag, -iver, -lim` (7.30b). Source: `index` — https://documentation.help (WinRAR docs mirror, table of contents only in snippet) + https://www.softdlx.com/windows/winrar-professional-free-download-for-windows/

### 2.6 Pricing / licence
**$29 single-user, one-time, lifetime updates** (win-rar.com affiliates page, `index` — https://www.win-rar.com/partners/affiliates/index.php?afid=400). **40-day trial; after expiry a nag dialog on launch, app keeps working fully** (widely reported, `secondary` — do not present as official policy without the FAQ citation). Volume pricing $21 (2–9) down to ~$6 (500–999). Trialware, not free.

---

## 3. What power users actually compare

| Criterion | What matters | SeekZip implication |
|---|---|---|
| **Ratio vs speed** | 7z Ultra smallest/slowest; RAR5 middle; ZIP/Zstd fastest/largest. One 1.2 GB mixed-folder test (`secondary`, techisness): 7z Ultra 412 MB / 3m42s, 7z Fast 489 MB / 48s, RAR5 441 MB / 1m31s, WinZip ZIP 533 MB / 33s. Another 2.1 GB test (`secondary`): 7z 1.05 GB / 5 min, RAR 1.2 GB / 4 min, ZIP 1.4 GB / 2.5–2.7 min. **Treat absolute numbers as corpus/hardware-specific; the ordering is consistent across sources.** | Ship presets Fast / Normal / Maximum / Ultra with live ETA + predicted size; never default to Ultra. Show ratio + MB/s after each job. |
| **Large files** | 50 GB archives, 1M entries: need Zip64 (auto-switch >4 GB / >65,535 entries), 64-bit sizes throughout, streaming (never load whole archive in RAM), central-directory-only listing for ZIP (fast list without decompressing), Quick Open equivalent for 7z/RAR. 7z/RAR/ZIP64 ceiling 16 EiB; classic ZIP 4 GB / 65,535 files. FAT32 destination still caps at 4 GB regardless of format. | Test with 50 GB + 1M-entry fixtures; lazy central-directory parse; progress in bytes + files. |
| **Zip64** | Auto-upgrade when >4 GB or >65,535 entries; older tools choke on Zip64 — warn when creating for legacy recipients. | Always write Zip64 when needed; show “Zip64” badge. |
| **Split / corrupt** | Missing part = total failure for 7z split (header in last volume); RAR `.rev` can rebuild; ZIP split (`.z01`) similar fragility. Corrupt: CRC/BLAKE2 detection everywhere; repair only with RAR recovery record. Partial extraction of undamaged files from a damaged solid archive is often impossible — warn before creating solid archives for archival use. | Missing-part dialog naming exactly which part is missing; “Test” (`7z t` equivalent) as first-class button; extract-undamaged-files mode for non-solid ZIP/7z. |
| **Nested archives** | `.zip` in `.tar.gz` in `.dmg`, `.rar` in `.7z`, installers (MSI/EXE/NSIS) as archives. MacPacker/BetterZip drill in place with breadcrumbs; 7-Zip opens EXE as archive. | Breadcrumb drill-in, no temp extraction to disk for browsing; temp-extract only the file being previewed, in a sandboxed temp dir, cleaned on quit. |
| **Filename encodings** | ZIP stores raw bytes + optional UTF-8 flag (bit 11). Legacy Windows ZIPs use Shift-JIS/CP932 (JP), GBK/CP936 (CN), Big5 (TW), EUC-KR/CP949 (KR), CP1252/CP437 (Western). macOS Archive Utility assumes UTF-8 → mojibake. The Unarchiver's heuristic detection is its moat; Keka/BetterZip let you pick encoding manually. Also macOS NFD vs Windows NFC (Korean jamo split). 7z/RAR5 store Unicode natively — no problem there. | Auto-detect (Shift-JIS/GBK/Big5/EUC-KR/CP1252/CP437) + manual override per archive + preview before/after + NFC normalisation on write for Windows recipients. This is a v1 differentiator on macOS. |
| **Checksums / integrity** | `7z t`, WinRAR Test, CRC-32/64, SHA-256, BLAKE2sp, `.sha256` files. Users test after download, before delete-original. | One-click Test with per-file pass/fail, hash export (SHA-256/512), verify-against-`.sha256`. |
| **Conversion** | RAR→ZIP/7z, 7z→ZIP, ZIP→7z, archive→SFX, split↔single. PeaZip/BetterZip/WinRAR all convert; 7-Zip does not (extract + re-add manually). | Convert = extract-to-temp + re-add, streaming where possible; never claim RAR output. |
| **Batch / queue** | Multiple jobs, pause/resume/cancel per job, queue ordering, “extract all in folder”, presets per job, post-action (delete source, shutdown — Windows only). | Job queue with pause (suspend `7zz` process), cancel (kill + clean partial output), resume only where format allows (re-extract skipped files; compression resume = restart job, be honest). |
| **CLI / scripting** | `7z`/`rar` one-liners, `@listfile`, exit codes (7-Zip: 0 ok, 1 warning, 2 fatal, 7 cmd-line error, 8 out-of-memory, 255 user stop; WinRAR similar + 14 delete-error in 7.30b), stdout parsing. Power users script backups. | Ship a `seekzip` CLI (or document `7zz` passthrough) with stable exit codes + machine-readable `--json` listing; Shortcuts/App Intents + AppleScript in v1.1 (BetterZip 6 already has these). |

Sources: benchmarks `secondary` — https://techisness.com/best-file-compression-software-in-2026/ ; https://blog.usro.net/2024/10/winrar-vs-7-zip-detailed-comparison-with-compression-sizes-and-efficiency/ ; https://lifetips.alibaba.com/tech-efficiency/best-file-compression-tools (mx9 +310% time / +0.9% size vs mx7); encodings `index` — https://bundl.run/apps/the-unarchiver ; https://www.filerepairhub.com/guides/zip-cross-platform-extract-issue/ ; https://usezivo.com/tools/zip-filename-encoding-fixer ; limits `index` — https://peazip.github.io/rar-zip-file-format-size-limitations.html

---

## 4. macOS competitors 2025–2026

| App | Price | Latest (as found) | Create | Extract | Strengths | Gaps SeekZip must beat |
|---|---|---|---|---|---|---|
| **Keka** | Free (keka.io) / **$6.49 MAS** ($4.99–$5.99 in older listings — price varies by store/date) | 1.6.7 (2026-06-30) / 1.6.8 (2026-09-24 per 1dot.ai — **conflict**) | 7z, ZIP, TAR, GZ, BZ2, XZ, LZIP, DMG, ISO, Brotli, Zstd, Lrzip, AAR, WIM (14) | 30+ incl. RAR/RAR5, ZIPX, EXE/CAB/MSI | Best free default; Dock drag-to-compress, Finder extension, split, AES-256 (7z) / Zip 2.0 (ZIP), 7zz engine on Apple Silicon, UNRAR 7.23 | **No Quick Look; no in-place edit; browse is disputed** (some sources: “cannot preview without extracting”, others: browse window with selective extract — likely version-dependent; verify by testing 1.6.8). No RAR creation. SFX/recovery vols only in direct-download (sandboxed MAS build trimmed). Utilitarian UI. |
| **BetterZip 6** | **$35 one-time**, 30-day trial, 5 Macs personal; upgrade $15 from v5 | **6.0.6, 2026-09-16**, macOS 13.5+ | ZIP, DMG, TAR/TGZ/TBZ/TXZ, Zstd, Brotli, 7z, XAR, ISO; RAR via external `rar` CLI | 30+ incl. RAR, 7z, DMG, ISO, ePub, winmail.dat, split `.001` | **The bar:** browse/edit in place (add/delete/rename without extract+rebuild, Normal + Direct modes), icon/column/flat/outline views, full-screen image/comic viewer, **free Quick Look extension (Space in Finder)**, Finder submenu/toolbar, Share ext., Spotlight importer, presets, AES-256 + password manager/generator, Shortcuts/App Intents + CLI helper, AppleScript, 7z helper ~20% faster on Apple Silicon (vendor claim) | $35; RAR creation needs user-supplied `rar` binary; no recovery-record creation natively; UI redesigned in v6 (Liquid Glass hints) but still dense. |
| **MacPacker** | **Free, GPL-3.0** | **v1.2.0**, macOS **14.6+**, Apple Silicon native, Swift/SwiftUI | **ZIP + 7z only** (split, AES-256/ZipCrypto, edit in place) | 40+ formats / 66 extensions incl. RAR, DMG, ISO, CAB, VMDK | **Closest to SeekZip's brief:** browse like Finder, Space Quick Look (incl. nested, CBZ/CBR), nested drill-in + breadcrumbs, drag-out single files, Finder right-click, search in archive, 21 languages, signed/notarized + MAS + Homebrew | Only ZIP/7z creation (no TAR/Zstd/Brotli/DMG/ISO creation); GPL-3.0 (copyleft — cannot borrow code into a closed app); young project (v1.x, bugs reported e.g. password-protected ZIP preview); no CLI/Shortcuts/presets depth; no recovery, no benchmark. **SeekZip must beat it on: creation breadth, presets/automation, large-archive performance, encoding handling.** |
| **The Unarchiver** | **Free**, no IAP | **4.3.9, 2025-03-18**, macOS 10.13+, MacPaw (acq. 2017) | **None — extract only** | 50+ incl. RAR/RAR5, 7z, ZIP/ZIPX, StuffIt/DiskDoubler/Compact Pro/LZH/ARJ/ARC/Amiga, ISO/BIN/MDF, MSI/EXE/NSIS | Best legacy-format + **filename-encoding detection** (Shift-JIS/GBK/EUC-KR/CP1252 heuristic); set-and-forget default opener; `unar`/`lsar` CLI siblings | No creation, no browse/preview, no Quick Look, slow release cadence (18 months since 4.3.9), 4.3.9 added usage analytics (App Store notes, `secondary`). |
| **PeaZip** | **Free, LGPLv3** | **11.4.0, 2026-10-17** (11.3.0 2026-09-26); backends Pea 1.34 + 7z/p7zip 26.04 | 7Z, ARC, Brotli, Zstd, PEA, TAR, WIM, ZIP (+ ZIPX) | **200+ / 243 extensions** | Widest format count, batch jobs, SFX, split, convert, export task as console script, AES/Twofish/Serpent + **2FA password+keyfile**, password manager, secure delete, file hashing, full file manager | Cross-platform (Lazarus) UI — not native macOS, no Finder/Quick Look/Spotlight integration, no Liquid Glass; macOS DMG reported **not notarized** (needs `xattr -dr com.apple.quarantine` per peazip.app, `secondary/unverified`); Homebrew cask reported gone in 2026 (`secondary` — verify before citing). |
| Built-in Archive Utility | Free (macOS) | — | ZIP (+ TAR/GZ/BZ2 via Finder) | ZIP, TAR, GZ, BZ2, CPGZ | Zero friction, double-click | No RAR/7z, no browse, no encryption, no split, silent failure on >4 GB in some reports (`secondary`). |

Sources: Keka — https://bundl.run/apps/keka ; https://www.nuanyue.com/software/keka/ ; https://1dot.ai/blog/preview-zip-archive-contents-mac ; BetterZip — https://macitbetter.com/ ; https://www.betterzip.pro/ ; https://www.nuanyue.com/software/betterzip/ ; MacPacker — https://macpacker.app/en ; https://github.com/sarensw/macpacker/blob/HEAD/README.md ; The Unarchiver — https://www.nuanyue.com/software/the-unarchiver/ ; https://bundl.run/apps/the-unarchiver ; PeaZip — https://www.techspot.com/downloads/4849-peazip.html ; https://peazip.app/ (notarization claim) ; comparison — https://en.wikipedia.org/wiki/Comparison_of_file_archivers (PeaZip 11.3.0 2026-09-26, The Unarchiver 4.3.8 2024-05-16 — stale vs vendor pages, prefer vendor dates above).

**What a new app must beat (synthesis):** BetterZip's browse/edit + Quick Look, MacPacker's native SwiftUI polish + nested drill-in, Keka's free breadth + speed, The Unarchiver's encoding/legacy handling — at **free** (SeekZip's stated model) with a **faster engine update cadence** than Keka/The Unarchiver.

---

## 5. UI/UX for a beautiful, smooth macOS archive app

### 5.1 Patterns to copy (not code)
- **Finder itself:** `NavigationSplitView` — sidebar (Recents / Favourites / Locations, 220–260 pt) + content + optional inspector; toolbar with view-mode segmented control (icon/list/column), search field, sort; status bar (item count, total size, free space). Column view is the natural metaphor for nested archives. Source: HIG-derived guidance `index` — https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/design-and-accessibility.md ; https://github.com/elevatormusic/apple-hig/blob/HEAD/skills/apple-hig/guidelines/platforms/macos.md
- **BetterZip 6 / MacPacker:** archive-as-folder browsing, breadcrumbs for nested archives, in-place edit, full-screen image viewer for CBZ/photo archives.
- **Transmit / ForkLift / Nova / Things / Linear (macOS):** cited by practitioners as smooth-native exemplars — dense, keyboard-first, menu-bar-driven, multi-window, no custom chrome fighting the system. *(No primary source in this research ties a specific pattern to a specific app — treat as design direction, not a sourced claim.)*
- **macOS Tahoe 26 Liquid Glass:** glass only on the functional layer (toolbar/sidebar/tab bar), never on content/list cells; use standard components so dark mode / Reduce Transparency / Increase Contrast adapt for free; semantic colours (`windowBackgroundColor`, `labelColor`), SF Symbols, 13 pt body on macOS. Liquid Glass APIs require macOS 26+ — SeekZip's 14.6 floor means gate glass with `#available(macOS 26, *)` and ship a clean Sonoma/Sequoia fallback. Source: `index` — https://github.com/okle42/hig42_design/blob/HEAD/plugins/hig42-design/skills/hig42-design/SKILL.md

### 5.2 Finder-like browsing + Quick Look
- Open archive → virtual folder tree (outline/list/column/icon views, like BetterZip 6). Double-click folder navigates; double-click file previews (in-app preview for text/image/PDF via Quick Look framework) or opens via temp-extract + default app.
- **Quick Look with Space:** two surfaces — (a) *inside* the app, Space previews the selected entry (MacPacker does this); (b) *in Finder*, a **Quick Look extension** (`com.apple.quicklook.preview`) so Space on a `.zip/.7z/.rar` in Finder shows the contents list without launching the app (BetterZip's free extension is the reference). QL extensions **must be sandboxed** — a sandboxed main app + sandboxed QL extension sharing via App Group is the known-working shape; an unsandboxed QL extension silently fails to register (`pluginkit` omits it). Source: `index` — https://markemark.app/how-it-was-built.html (first-hand build log, sandbox/QL pitfalls); BetterZip QL — https://macitbetter.com/
- **Finder integration:** Finder Sync / Finder Extension (context menu: Compress / Extract Here / Extract to… / Test), Share extension, Services, file-association + default-opener helper (Keka needs a separate `KekaExternalHelper` — avoid that; register UTIs properly). Drag-and-drop both ways: drop files/folders onto Dock icon/window to compress; drag entries out of the archive to Finder (promise files via `NSFilePromiseProvider` so a 2 GB archive doesn't need full extraction for one file).

### 5.3 Virtualized / lazy lists for 100k–1M rows
- **Apple's WWDC25 claim (`verified` via Apple transcript):** “On macOS, lists of over 100,000 items now load 6x faster. And these lists update up to 16x faster.” — https://developer.apple.com/videos/play/wwdc2025/256/ (What's new in SwiftUI, WWDC25). Applies to macOS 26 / Xcode 26 rebuilds — **SeekZip targeting 14.6 cannot rely on it on Sonoma/Sequoia; it helps only on Tahoe+**.
- **Pre-WWDC25 evidence (`secondary`, single-vendor blog — directional):** Rockxy, 100k rows: SwiftUI `List` 22 FPS / ~800 MB, `LazyVStack` worse (>1.2 GB, no recycling at all), `NSTableView` 45 MB / constant 60 FPS, ~50 live views regardless of row count. https://rockxy.io/blog/virtual-scrolling-swiftui — the author replaced `List` with `NSTableView` via `NSViewRepresentable` within two weeks.
- **Convergent guidance:** use `List` (not `LazyVStack`) if staying in SwiftUI — `List` recycles, `LazyVStack` does not free realised rows; stable `id()` (never index), lightweight rows (precompute size/date strings in the view model, no `.task`/network/image-decode in rows, no `GeometryReader` in rows), paginate/window the data source, profile with the SwiftUI Instrument in Instruments 26. For 1M rows or variable-height rows, **plan an `NSTableView`/`NSOutlineView` escape hatch via `NSViewRepresentable`** — Finder itself is AppKit for this reason. Do not build a custom virtual scroller first.
- **Data layer:** parse central directory / 7z header on a background thread, stream entries into a windowed store (e.g. first 5k rows + on-demand pages), sort/filter without re-parsing; icons via `NSWorkspace` icon cache, thumbnails lazily and cancellable.

### 5.4 Progress / pause / resume / cancel
- Per-job progress: bytes + files, current filename, MB/s, ETA, elapsed; indeterminate state while scanning; **pause** = suspend the `7zz` process (SIGSTOP) or cancel + resume-by-skipping-completed-files on extract; **cancel** = kill process + delete partial output + offer “keep partial”; **resume** for compression is a restart (be honest in UI — no fake resume). Queue with reorder, per-job presets, “extract all” batch, conflict policy (skip/rename/overwrite/ask), error list with “retry failed only”.
- Never block the main thread; never show a modal progress sheet that blocks browsing another archive (multi-window / multi-job).

### 5.5 Dark mode, accessibility, misc
- Light + dark from day one via semantic colours/materials; test contrast in both (4.5:1 for small text); respect Reduce Transparency / Increase Contrast / Reduce Motion (`\.accessibilityReduceTransparency`, `\.colorSchemeContrast`); VoiceOver labels on every control, accessible tables (row = file, columns announced), full keyboard navigation (arrows, Space=preview, ⌘O=open, ⌘E=extract, type-to-select, ⌘F search in archive); menu bar with every command + shortcuts (Mac is menu-bar-driven, not on-screen-chrome-driven); localisation from the start (7-Zip ships 87 languages; MacPacker 21 — archive users are global, and encoding handling is part of i18n).

---

## 6. Deal-breakers and hard limits

| Limit | Consequence for SeekZip |
|---|---|
| **RAR creation is proprietary** | UnRAR licence: “may be used in any software to handle RAR archives without limitations free of charge, but **cannot be used to develop RAR (WinRAR) compatible archiver and to re-create RAR compression algorithm, which is proprietary**.” Only WinRAR (Windows), RAR for Android, CLI `rar` (macOS/Linux/FreeBSD/Windows), or licensees with written permission from Alexander Roshal can create RAR. **SeekZip must never claim RAR creation.** Options: extract-only via bundled `unrar`/`7zz` RAR decoder; optional “create RAR if user has `rar` CLI installed” (Keka/BetterZip pattern — detect, don't bundle, don't download it for the user without licence clarity); offer repack-to-7z/ZIP. Sources: `index` — https://en.wikipedia.org/wiki/RAR_(file_format) ; https://kutio.karpinity.com/acknowledgements/ (quotes licence verbatim). |
| **7-Zip licence (LGPL-2.1-or-later + unRAR restriction; LZMA SDK public domain)** | Bundling `7zz` is allowed if you comply: ship LGPL + unRAR licence text, offer source / link to upstream, do not use the RAR decoder code to build a RAR compressor. Homebrew lists `LGPL-2.1-or-later AND BSD-3-Clause`. **Do not link 7-Zip statically into a closed binary without LGPL compliance review; subprocess + dynamic separation is the safer shape.** Source: `index` — https://formulae.brew.sh/formula/sevenzip ; https://en.wikipedia.org/wiki/7-Zip |
| **Mac App Store sandbox + bundled `7zz` subprocess** | MAS apps **cannot `Process` a binary outside the bundle** (“launch path not accessible” / `deny(1) forbidden-sandbox-reinit`). A helper **inside** the bundle *can* run if signed with **exactly** `com.apple.security.app-sandbox` + `com.apple.security.inherit` (any third entitlement aborts the child). The child inherits the parent sandbox: it can only touch files the parent was granted (user-selected via open/save panels, security-scoped bookmarks, App Group). Finder-extension / Quick Look / XPC helpers each need their own signing + entitlements. MAS review also scrutinises large embedded GPL binaries. **Practical consequence:** a full-featured MAS build is possible but constrained (Keka's MAS build drops SFX + RAR recovery volumes; MacPacker ships both MAS and direct). The direct-download Developer-ID build is unconstrained (except Gatekeeper/notarization). **Recommendation: ship Developer-ID + notarized DMG first; MAS as a second, feature-flagged build — do not design v1 around MAS.** Sources: `index` — https://github.com/rossetv/toolbox/blob/HEAD/.claude/specs/20260722-pdf-toolbox-v1-evidence/engine-research.md ; https://indiestack.com/2017/09/sandbox-inheritance-tax/ ; https://github.com/dinhduy/mac-closed-display/blob/HEAD/docs/app-publishing-checklist.md |
| **Signing / notarization** | Outside MAS: Developer ID Application certificate, Hardened Runtime, `notarytool submit` + staple; every nested bundle/framework/helper/QL-extension individually signed, bottom-up re-sign after `xcodebuild -exportArchive` (it can silently merge entitlements from the App ID). Unsigned/notarized apps trigger Gatekeeper (“damaged / can't be opened”) and `xattr -dr com.apple.quarantine` workarounds (PeaZip's macOS reputation suffers for this). Source: `index` — https://markemark.app/how-it-was-built.html ; https://github.com/openrocket/macOS-QuickLook-extension |
| **7-Zip security CVEs + update cadence** | 7-Zip ships **no auto-updater** — old versions linger for years. Recent CVEs: CVE-2025-0411 MotW bypass (7.0, fixed 24.09+), CVE-2025-11001/11002 ZIP symlink traversal RCE (7.8/7.0, fixed 25.00), CVE-2025-55188 symlink arbitrary write (fixed 25.01), CVE-2025-53816 RAR5 heap OOB (7.5, fixed 25.00), CVE-2025-53817 Compound null-deref (fixed 25.00), CVE-2026-14266 XZ heap overflow RCE (7.8, fixed 26.02), CVE-2026-48095 NTFS heap overflow (8.8, fixed 26.01), CVE-2026-58052 MotW via RAR5 Zone.Identifier (3.3, fixed 26.03), CVE-2026-48102 UDF OOB read (fixed 26.01). WinRAR has its own: CVE-2025-6218 (directory traversal, fixed 7.12), CVE-2026-14191 RAR5 recovery-volume heap overflow (7.8, fixed 7.23). **SeekZip must:** pin `7zz` + `unrar` versions, check for engine updates in-app (Sparkle or manual check + banner), never extract symlinks/hardlinks outside the destination, strip/validate `Zone.Identifier`/quarantine propagation, run extraction with least privilege, and treat every archive as untrusted input (fuzz the parsers, limit memory via `-smemx`-style caps for RAR dicts >4 GB). Sources: `index` — https://app.opencve.io/cve/?vendor=7-zip ; https://www.threatlocker.com/blog/analysis-of-7-zip-vulnerabilities-cve-2025-11001-and-cve-2025-11002 ; https://www.7-zip.org/history.txt |
| **Other hard limits** | 7z: no recovery record, no per-file comments in RAR5 sense, no filesystem permissions in 7z (owner/group/ACLs not stored — unsuitable as a backup format without TAR wrapper). ZIP: ZipCrypto is weak (crackable in minutes — never offer it as “secure”; offer AES-256 only, with a legacy-compat warning). macOS: no native SFX for macOS; APFS vs FAT32 4 GB destination cap; sandbox + TCC (Full Disk Access prompts) for “extract anywhere”. |

---

## Prioritized feature checklist

### v1 — must ship (parity + the macOS win)
- [ ] **Browse before extracting** — virtual folder tree (list/column/icon), search in archive, sort, breadcrumbs for nested archives (ZIP in TAR.GZ in DMG, RAR in 7z), no full extraction to browse
- [ ] **Formats:** create 7z (LZMA2 default, LZMA/PPMd/BZip2/Deflate), ZIP (Deflate + AES-256, Zip64 auto), TAR/TGZ/TXZ/TBZ, GZ/BZ2/XZ/Zstd; extract + RAR/RAR5 (incl. encrypted + multi-volume), 7z, ZIP/ZIPX, ISO, DMG, CAB, MSI, NSIS, WIM, CPIO — via bundled `7zz` (pinned, e.g. 26.05) + `unrar` decoder
- [ ] **Selective extraction** — drag-out single files/folders via file promises; extract selected only
- [ ] **Compression presets** Fast/Normal/Maximum/Ultra + method/dict/solid/split controls; split volumes (`.7z.001`, `.zip.001`); solid on/off with corruption warning
- [ ] **Encryption:** AES-256 for 7z/ZIP, header encryption for 7z, password manager (Keychain), show-password, wrong-password handling without re-scanning
- [ ] **Integrity:** Test button (CRC/SHA/BLAKE2), hash export/verify (`.sha256`), per-file failure list
- [ ] **Encodings:** auto-detect Shift-JIS/GBK/Big5/EUC-KR/CP1252/CP437 + manual override + before/after preview + NFC on write
- [ ] **Jobs:** queue, progress (bytes/files/MB/s/ETA), pause/suspend, cancel + clean partial, batch extract, conflict policy, error retry
- [ ] **Finder + Quick Look:** Finder context menu (Compress/Extract/Test), Dock drag-to-compress, Space Quick Look *inside* app + Finder QL extension (contents list), file associations
- [ ] **Performance:** central-directory-only ZIP listing, background parsing, windowed/paginated list, `List` first with `NSTableView` escape hatch, 50 GB / 1M-entry test fixtures
- [ ] **Safety:** symlink/hardlink traversal block, quarantine/MotW handling, no auto-run, engine version shown + update banner, signed + notarized Developer-ID DMG
- [ ] **macOS polish:** NavigationSplitView, toolbar, dark mode, VoiceOver/keyboard, menu bar, multi-window, drag-and-drop, Liquid Glass gated to macOS 26+

### v1.1 — beat the incumbents
- [ ] **Edit in place** — add/delete/rename/replace in ZIP/7z without full rebuild (BetterZip parity; Direct mode for large archives)
- [ ] **Conversion** — RAR/7z/ZIP → ZIP/7z/TAR, archive → split/single, batch convert
- [ ] **Presets + automation** — named presets (destination/format/encryption/filters/rename/conflict), Shortcuts/App Intents, AppleScript, `seekzip` CLI with `--json` + stable exit codes, Services
- [ ] **Preview depth** — in-app text/image/PDF/audio preview, full-screen image/comic viewer, Spotlight importer (filenames inside archives searchable)
- [ ] **Recovery surfacing** — use RAR `.rev`/recovery records on extract/repair where present; PAR2-style sidecar or “verify + re-download missing part” helper for 7z/ZIP; “extract undamaged files” mode
- [ ] **More creation formats** — DMG/ISO creation, Brotli, TAR.Zstd, Apple Archive; SFX for Windows `.exe` via `7zz` (document Windows-only)
- [ ] **Power tools** — built-in benchmark (`7z b` wrapper + compare), duplicate detection, archive comments, strip `__MACOSX`/`.DS_Store` toggle, exclude patterns
- [ ] **MAS build** (feature-flagged, sandbox-compliant) + Homebrew cask, Sparkle updates for direct build
- [ ] **Optional RAR creation** — only if user supplies licensed `rar` CLI; detect + wire through, never bundle

### Explicitly not in v1/v1.1
- RAR creation without a RARLAB licence; macOS SFX; claiming 7z recovery records; ZipCrypto as “secure”.

---

## Could not verify / open questions
- **7-Zip 26.05 exact feature list beyond history.txt one-liners** — official site is JS-rendered and fetched near-empty; version/date corroborated by 3 mirrors, but no primary feature page was readable in-session.
- **WinRAR 7.20 release date** — secondary sources split Feb 2026 vs Feb 2025; official whatsnew page lists contents without dates. 7.23 date (2026-06-30) is confirmed via RARLAB news page.
- **WinRAR 7.30.1** — one aggregator (SoftDLX) claims a 7.30.1 build; official whatsnew tops out at 7.30 beta 2 in-session. Treat 7.30.1 as unverified.
- **Keka 1.6.8 vs 1.6.7, and whether Keka browses archives** — sources conflict (Bundl: 1.6.7 Jun 2026; 1dot.ai: 1.6.8 Sep 2026 with browse window; older reviews: no preview). Needs a live test of the current Keka build.
- **Keka “open source” status** — one reviewer notes the GitHub repo holds issues/translations/wiki, not app source, and no licence is published; do not call Keka open-source without checking keka.io.
- **PeaZip macOS notarization / Homebrew cask** — “not notarized, cask gone in 2026” is secondary (peazip.app / Bundl); verify against peazip.org + `brew` before citing in product copy.
- **Benchmark numbers** — all ratio/speed figures above are secondary, corpus- and hardware-dependent; no independent reproducible benchmark was run in this research. Re-run on Apple Silicon with a fixed corpus before publishing any “X% smaller/faster” claim.
- **SwiftUI List on macOS 14/15 at 1M rows** — WWDC25 6x/16x gains are macOS 26 only; Rockxy's NSTableView numbers are pre-WWDC25, single-vendor, and on an older macOS. Profile SeekZip's actual list on 14.6/15/26 before choosing List vs NSTableView.
- **BetterZip “20% faster 7z on Apple Silicon”** — vendor claim via Nuanyue, not independently measured.

## Sources
- 7-Zip official history: https://www.7-zip.org/history.txt
- 7-Zip official site: https://www.7-zip.org/
- 7-Zip changelog mirror: https://7zip.dev/en/changelog/
- 7-Zip releases: https://github.com/ip7z/7zip/releases
- 7-Zip Wikipedia (formats/licence): https://en.wikipedia.org/wiki/7-Zip
- 7z format: https://en.m.wikipedia.org/wiki/7z
- 7z man page / CLI: https://manpages.org/7z
- Homebrew sevenzip (7zz, licence): https://formulae.brew.sh/formula/sevenzip
- WinRAR what's new (`verified live` 2026-11-06): https://www.win-rar.com/whatsnew.html?&L=0
- WinRAR 7.23 announcement: https://www.win-rar.com/singlenewsview.html?&L=0&tx_ttnews%5Btt_news%5D=304&cHash=0c65306ac391a7c5e6f3056a035efe08
- WinRAR price: https://www.win-rar.com/partners/affiliates/index.php?afid=400
- WinRAR/RARLAB Wikipedia: https://en.wikipedia.org/wiki/RARLAB
- RAR format + UnRAR licence: https://en.wikipedia.org/wiki/RAR_(file_format) ; https://kutio.karpinity.com/acknowledgements/
- WinRAR docs mirror: https://documentation.help (WinRAR Documentation — contents only in snippet)
- Benchmarks (secondary): https://techisness.com/best-file-compression-software-in-2026/ ; https://blog.usro.net/2024/10/winrar-vs-7-zip-detailed-comparison-with-compression-sizes-and-efficiency/ ; https://lifetips.alibaba.com/tech-efficiency/best-file-compression-tools
- Format size limits: https://peazip.github.io/rar-zip-file-format-size-limitations.html
- Filename encodings: https://bundl.run/apps/the-unarchiver ; https://www.filerepairhub.com/guides/zip-cross-platform-extract-issue/ ; https://usezivo.com/tools/zip-filename-encoding-fixer
- CVEs: https://app.opencve.io/cve/?vendor=7-zip ; https://www.threatlocker.com/blog/analysis-of-7-zip-vulnerabilities-cve-2025-11001-and-cve-2025-11002 ; https://vpncentral.com/winrar-7-23-fixes-rar5-recovery-volume-heap-overflow-vulnerability/
- Keka: https://bundl.run/apps/keka ; https://www.nuanyue.com/software/keka/ ; https://1dot.ai/blog/preview-zip-archive-contents-mac
- BetterZip: https://macitbetter.com/ ; https://www.betterzip.pro/ ; https://www.nuanyue.com/software/betterzip/
- MacPacker: https://macpacker.app/en ; https://github.com/sarensw/macpacker/blob/HEAD/README.md
- The Unarchiver: https://www.nuanyue.com/software/the-unarchiver/ ; https://bundl.run/apps/the-unarchiver
- PeaZip: https://www.techspot.com/downloads/4849-peazip.html ; https://peazip.app/
- Archiver comparison: https://en.wikipedia.org/wiki/Comparison_of_file_archivers
- WWDC25 SwiftUI lists: https://developer.apple.com/videos/play/wwdc2025/256/
- SwiftUI large-list failure case: https://rockxy.io/blog/virtual-scrolling-swiftui
- macOS HIG / Liquid Glass / accessibility: https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/design-and-accessibility.md ; https://github.com/okle42/hig42_design/blob/HEAD/plugins/hig42-design/skills/hig42-design/SKILL.md
- Sandbox / subprocess: https://github.com/rossetv/toolbox/blob/HEAD/.claude/specs/20260722-pdf-toolbox-v1-evidence/engine-research.md ; https://indiestack.com/2017/09/sandbox-inheritance-tax/
- Quick Look extension sandbox pitfalls: https://markemark.app/how-it-was-built.html
- Notes: notes/source-01-7zip-official.md, notes/source-02-winrar-official.md, notes/source-03-mac-competitors.md
