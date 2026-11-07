# SeekZip — Time log (Vietnam time, UTC+7)

Purpose: separate real coding time from time spent waiting on approvals,
CI runs and round-trips, so we know how much effort the project really
takes and how long a developer building it themselves would need.
Updated after every milestone. Agent times come from the runtime
(start/completed timestamps); approval times come from permissions.history.

## Measured so far (as of 08:11 on 2026-11-07)

| Milestone | Start → done (Vietnam time) | Wall time | Notes |
|---|---|---|---|
| M1 — Compile & CI green | 01:16 → 04:57 | ~3h40m | Mostly plumbing, not coding: research, repo creation, SSH key, GitHub App 403s, CI red 4 times. Real code fixes: 4 errors. |
| M2 — Streaming listing | 05:00 → 06:28 | ~1h28m | 14 commits. 2 pushes stalled because approval cards expired and had to be retried. |
| M3 — Preview + nested | 06:28 → 07:03 | ~35m | 18 commits. |
| M4 — Queue | 07:05 → 07:22 | ~17m | 12 commits. Pushed the old way (one file at a time, approvals spread out). |
| M5 — Create/edit polish | 07:22 → 07:46 | ~24m | 14 files in one batch push (2 new: Checksums.swift, PasswordStore.swift). Local work ~15m (swift test 67/67 green, swift build green); batch push 07:39–07:43, 14 approval cards, all approved in seconds, no expiries; CI run 42319888603 green 07:44 (build + tests + fixtures + smoke, all steps). |
| M6 — XAD fallback engine | 07:54 → 08:28 | ~17m local, ~14m push, ~3m CI | 16 files in one batch push (2 new: ArchiveEngine.swift, XADMasterEngine.swift) + 1 TIMELOG finalize commit. Local work 07:54–08:11 (~17m: protocol + router + XAD engine + CLI/MCP/GUI wiring, swift test 89/89 green (22 new), CLI + MCP smoke-tested end-to-end with fake 7zz/lsar/unar — real binaries not on the Linux VM). Batch push 08:11–08:25, 16 approval cards, no expiries; first card waited ~11 min (owner away), the rest approved in seconds. CI run 42324029579 on head 128c5e7 green (build + tests + fixtures + smoke, all steps). |

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
Note: pushing through the connector is still one file at a time (bulk push via
git/trees is blocked by GitHub with 403), so the number of approval cards does
not drop — they are just bunched at the end so the agent is not blocked mid-work
and cards do not expire. Risk: CI failures are found later; mitigated by running
local tests (Linux Swift toolchain) before pushing.
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
