# SeekZip — Time log (Vietnam time, UTC+7)

Purpose: separate real coding time from time spent waiting on approvals,
CI runs and round-trips, so we know how much effort the project really
takes and how long a developer building it themselves would need.
Updated after every milestone. Agent times come from the runtime
(start/completed timestamps); approval times come from permissions.history.

## Measured so far (as of 19:00 on 2026-11-08)

| Milestone | Start → done (Vietnam time) | Wall time | Notes |
|---|---|---|---|
| M1 — Compile & CI green | 01:16 → 04:57 | ~3h40m | Mostly plumbing, not coding: research, repo creation, SSH key, GitHub App 403s, CI red 4 times. Real code fixes: 4 errors. |
| M2 — Streaming listing | 05:00 → 06:28 | ~1h28m | 14 commits. 2 pushes stalled because approval cards expired and had to be retried. |
| M3 — Preview + nested | 06:28 → 07:03 | ~35m | 18 commits. |
| M4 — Queue | 07:05 → 07:22 | ~17m | 12 commits. Pushed the old way (one file at a time, approvals spread out). |
| M5 — Create/edit polish | 07:22 → 07:46 | ~24m | 14 files in one batch push (2 new: Checksums.swift, PasswordStore.swift). Local work ~15m (swift test 67/67 green, swift build green); batch push 07:39–07:43, 14 approval cards, all approved in seconds, no expiries; CI run 42319888603 green 07:44 (build + tests + fixtures + smoke, all steps). |
| M6 — XAD fallback engine | 07:54 → 08:28 | ~17m local, ~14m push, ~3m CI | 16 files in one batch push (2 new: ArchiveEngine.swift, XADMasterEngine.swift) + 1 TIMELOG finalize commit. Local work 07:54–08:11 (~17m: protocol + router + XAD engine + CLI/MCP/GUI wiring, swift test 89/89 green (22 new), CLI + MCP smoke-tested end-to-end with fake 7zz/lsar/unar — real binaries not on the Linux VM). Batch push 08:11–08:25, 16 approval cards, no expiries; first card waited ~11 min (owner away), the rest approved in seconds. CI run 42324029579 on head 128c5e7 green (build + tests + fixtures + smoke, all steps). |
| M7 — Extensions & packaging | 08:33 → 09:01 | ~16m local, ~6m push, ~3m CI | 31 files in one batch push (17 new: Xcode project + 6 plists/entitlements, 2 extension sources, AppBundle.swift, 2 scripts, ExportOptions.plist, formula + cask, RELEASE.md; 14 changed) + 1 TIMELOG finalize commit. Local work 08:33–08:49 (~16m: XAD preview fallback + bundled-engine lookup + App Group settings, Xcode project generator + validator, scripts dry-run on Linux, swift test 101/101 green (10 new), CLI smoke-tested; pbxproj validated, 95 objects, all checks pass). Batch push 08:55–09:01, 31 approval cards, all approved in seconds, no expiries. CI run 42327093592 on head dd2725d green (build + tests + fixtures + smoke, all steps). Xcode project NEVER built — needs a Mac with full Xcode. |
| Post-M7 — CI repair (new ci.yml steps) | 01:36 → 02:47 (2026-11-08) | ~1h10m (~45m local, ~10m approvals, ~15m CI) | The owner added `brew install unar` + an Xcode build step + smoke lines to ci.yml; the new steps found 3 real bugs in a row. (1) `JobControl` called `terminate()` on a process that had not launched yet — `NSInvalidArgumentException`, signal 6, only on macOS (Linux is a no-op) — plus a `kill(0, SIGSTOP)` hazard in `pause()`; fixed by guarding on `process.isRunning` (979d849). (2) The smoke step listed `big.zip`, a fixture `generate-matrix.sh` never created; fixed by generating it (4b31520). (3) `verify` failed on `src/tiếng việt.txt` (CRC 00000000): macOS normalizes `Process` argument strings to NFD, so an NFC name stored in the archive could never match through argv — proven by a temporary diagnostic test (9c2a6b8, removed afterwards) whose macOS output showed direct `7zz e -so` returning content for NFC, NFD and listed names alike. A first fix (retry with the alternate normalization, 420d653 + regression test 0b9400c) did not help, because both attempts arrived as NFD. The real fix passes entry names to 7zz via `@listfile` so the bytes reach it verbatim (7c7c2e5, + fake-7zz support and diagnostic removal f391508). Local `swift test` 102/102 green; final run 42407493699 on head f391508 green on every step (build, Xcode project, unit tests, fixtures, smoke). Known debt left: `removeEntries`/`renameEntries` still pass names via argv (loud failure, not silent). One push (the ~106 KB test file) timed out at the tool's 120 s limit but still landed on GitHub. |
| Post-M7 — App completion batch (menus, New Archive, password prompt, drag-drop, sort, listfile remove/rename) | 17:53 → 18:33 (2026-11-08) | ~40m (~22m local, ~2m approvals, ~15m CI incl. one red run) | Owner asked the agent to research and complete the app (UI/UX included). Audit vs parity research + HIG + MacPacker: the app had no menu bar, no New Archive, no password prompt, no drag-drop, no sort, double-click did nothing. 5 files in ONE snapshot commit b8c8bf9 (first successful multi-file push via `github push-files` MCP — 1 commit, 1 approval card; the old note in the push-policy section that the connector can only push one file at a time is now wrong, the 403 only blocks the git/trees API). Local `swift test` 104/104 green (3 skipped: no real 7zz on the Linux VM; `rn`/`d` @listfile later verified with real 7z 23.01 from apt). CI run 42474865405 on b8c8bf9 red at the Xcode build step: exactly one error, `SeekZipApp.swift:508:30: type 'ShapeStyle' has no member 'accentColor'` (`.stroke(.accentColor, ...)` resolves the leading dot against ShapeStyle) — found by reading the log in the browser (the API cannot read logs, only "exit code 65"). Fix commit ed157d1 (1 file, `Color.accentColor` + silenced the `loadObject` unused-result warning); CI run 42475893480 green on every step (build-and-test + build-app), artifact SeekZip-macOS 5,578,500 bytes. The `removeEntries`/`renameEntries` argv debt from the CI-repair row is now fixed (listfile + verify + normalization retry). |
| Post-M7 — Completion batch 2+3 (drag-out, Quick Look, chunked open; Space toggle, Settings popover, native toolbar) | 18:34 → 19:00 (2026-11-08) | ~26m (~15m local, ~1m approvals, ~10m CI incl. one red run) | Drag-out to Finder, native Quick Look panel (QLPreviewPanel), chunked streaming open in a detached task (fixes UI freeze + RAM on huge files, and opening password-protected entries, which the old code streamed with password: nil). CI run 42476945640 on 283be0d red at the Xcode build step: 5 errors — `QLPreviewPanel.shared()` returns an optional in the current SDK (4 errors), and `NSFilePromiseProvider` does NOT conform to `NSItemProviderWriting` (1 error) — found by reading the log in the browser. Owner feedback in the same window (Space never toggled the preview off — `togglePreview` always set `showPreview = true`; Settings sheet trapped the user behind Esc-only dismissal; the two top button rows looked plain): fixed in the same commit — Space now toggles off, Settings is a popover (click outside dismisses), native toolbar (`.toolbar` + `.searchable` + window title shows the archive name) replaces the two rows, only a slim rename row stays inline. Fix + batch 3 pushed as ONE commit 3b41db2; CI run 42477912778 green on every step (build-and-test + build-app), artifact SeekZip-macOS 5,599,594 bytes. Local `swift test` 104/104 green throughout. |

## Whole v1 total (M1–M7)

| | Wall time |
|---|---|
| Milestone wall times summed (M1 3h40m + M2 1h28m + M3 35m + M4 17m + M5 24m + M6 ~34m + M7 ~16m local, push/CI to follow) | ~7h15m. |
| Elapsed, first message (01:16) → M7 local done (08:49) | 7h33m — includes gaps between milestones, owner replies and approval waiting. |
| Hands-on local work, M5–M7 (measured split) | 15m + 17m + 16m = 48m of pure coding/testing; the batch-push + CI tail adds ~15–20m per milestone. M1–M4 predate the split measurement. |
| Developer estimate for the whole v1 (from the estimate section below) | 3–6 focused working days — unchanged. |

## Approval waiting time (measured sample, latest history page, 20 approvals)

- Most were approved in 3–17 seconds (while the owner had the phone in hand).
- Longest: 11 minutes 47 seconds and 4 minutes 43 seconds (owner away).
- Total ~19 minutes of approval waiting across those 20 approvals.
- M2 alone had 2 approval cards expire (cards expire after 30 minutes).
- Every commit pushed to GitHub needs its own approval card — M2 14 commits,
  M3 18 commits, M4 12 commits, M5 14 commits — so the waiting adds up fast.
  This is the biggest cost outside of coding.
- M5 proved the batch policy works: 14 approval cards bunched at the
  end (07:39–07:43), every one approved in seconds, none expired —
  versus M2, where 2 cards expired mid-milestone. The agent was never
  blocked mid-work.

## CI time

- Each CI run on macos-15 takes about 50 seconds (build + tests + fixtures + smoke).
- M1 needed 8 CI runs to go green (4 red: code errors / CI script). M2/M3 ran
  CI several times each; only the final green run counts as done.

## CI flakiness (M5 batch, 2026-11-07)

- 15 runs fired (one per pushed commit). 4 failed at the "Unit tests"
  step: 41cfbca, 1ebf5d2, b152d41, 0bb9fee. Each failed run's code is a
  subset of — or identical to, except docs — a neighbouring green run
  (e.g. 0bb9fee differs from green 056a41b only in this file), so these
  are flaky runs, not regressions. Local `swift test` passes 67/67
  three times in a row. Likely a timing-sensitive test on a loaded
  runner (several queue/cancel tests use sleeps and 5 s timeouts).
  If a run goes red on unit tests with no code change, re-run it
  before investigating the code.

## Push policy change (decided 2026-11-07)

Before M5, every file was pushed as its own commit with its own approval card,
so approvals were spread across the whole milestone and the agent kept blocking
while waiting. From M5: work locally, run local tests, and only push to GitHub
in one batch at the end of the milestone, then check CI once.
Note (updated 2026-11-08): pushing many files in ONE commit now works
via `github push-files` (MCP `push_files` snapshot) — 1 commit, 1 approval
card (first proven by b8c8bf9, 5 files). The 403 only blocks the git/trees
API, not push_files. `.github/workflows/` files are still blocked (403)
and must be edited via the web UI or from a Mac. Risk: CI failures are
found later; mitigated by running local tests (Linux Swift toolchain)
before pushing.
Priority order: Muse pushes to git itself first; only if pushing truly cannot
complete does the owner push locally from a downloaded zip of the changed files
(last resort). Once Muse can connect directly to the owner's machine, git pushes
will go straight from local and this workaround goes away.

## Estimate if a developer builds it themselves (Mac + Xcode + direct git push, no per-commit approvals)

- M1: 1–2 hours. M2: 2–4 hours. M3: 2–4 hours. M4: 3–5 hours.
- M5: 4–8 hours. M6: 4–8 hours (XAD engine integration). M7: 1–2 days
  (Xcode project, signing, notarization, Homebrew).
- Whole v1: roughly 3–6 focused working days, excluding review/polish.
- This is an estimate, not a commitment. The agent path is slower per milestone
  because of per-commit approvals and CI round-trips, but it runs unattended
  overnight.
