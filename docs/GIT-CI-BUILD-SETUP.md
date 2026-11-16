# Git, CI Test & Build Workflow Setup (SeekZip)

The complete setup of git, the CI test workflow, and the app build workflow
for this repo — plus the history of what was changed and why, so a future
maintainer (or another AI entering this repo) can investigate a red run, fix
a failure, or change the setup without rediscovering everything.

SeekZip has a single workflow file (`.github/workflows/ci.yml`, two jobs).
There is no `release.yml` and no pre-release automation — releases are
manual, see `docs/RELEASE.md`. This doc is the one place for the whole
git + CI + build setup; unlike TransPeek, which splits it into
`GIT-CI-BUILD-SETUP.md` (setup + intervention log) and
`BUILD-TEST-WORKFLOW-GITHUB-CI.md` (CI detail), SeekZip's workflow is small
enough that one doc covers it. If the workflow grows a second file (e.g. a
release workflow), split the CI detail out then.

Related docs:

- `docs/BUILD_FROM_ZERO.md` — build the project from scratch, step by step
  (links here from §10).
- `docs/TEST-MATRIX.md` — the test matrix (fixtures, cases, expected
  results).
- `docs/ARCHITECTURE.md` — engine core, three frontends, module map.
- `docs/RELEASE.md` — the release checklist (manual releases).
- `docs/RESEARCH/seekzip-7zip-winrar-parity-20261106-1842/report.md` —
  why the official `7zz` engine, and the hard limits.

## 1. Git setup

### Repo

- GitHub: `TranManhTuanLabs/SeekZip` (public).
- Default branch: `main`. Feature work on a branch, `main` stays clean
  and green.
- Local clones:
  - Manh's Mac (primary):
    `/Users/manhtuan/Documents/AI-Agent-Workspace/AI_Workspace/SeekZip`.
  - This VM: `~/workspace/projects/seekzip/SeekZip-Transfer/repo/`
    (staging copy for pushes; its local git HEAD is stale — **GitHub
    `main` is the source of truth, never the local HEAD**; fetch the
    current file from `raw.githubusercontent.com` before editing it,
    and diff local vs main before pushing).

### Authentication

- Manh's Mac: SSH with an ed25519 key. Verify with
  `ssh -T git@github.com` — it must print `Hi TranManhTuanLabs`. SSH is
  preferred over HTTPS.
- The Muse GitHub App (connector) does NOT have Workflows permission: any
  call touching `.github/workflows/*` returns 403. Stop after the first
  403; do not retry the same call. Edit workflow files from Manh's Mac,
  or through the GitHub web editor (browser session) when Manh has
  explicitly allowed it. (The web editor is also unreliable for YAML —
  verify by reading the file itself after saving.)
- The connector CAN push text files: `github push-files` pushes many
  files in ONE commit (the old 403 only blocks the git/trees API, not
  this path). It cannot push binary files — those go through the browser
  web UI, one file at a time.

### How pushes are done (and the rules)

- **Push related files in ONE commit.** Prepare everything locally first
  (all files written, diff re-read, names/parameters checked consistent),
  then push the whole change as one commit. Never push related files
  one-by-one through the browser web editor — each web edit is 1 commit,
  so the repo passes through intermediate states where the code does not
  fit together and CI goes red mid-batch. (Exception: a binary file that
  the code needs must go first, alone, through the browser — the
  connector cannot push binary, and CI needs the file present to build.)
- Approval cards for connector pushes expire after 30 minutes. An
  expired/denied card only blocks that push — the code is not lost;
  re-push and a new card appears.
- **Branch strategy:** feature work on a branch, `main` stays clean and
  green. Before merging a branch into `main`, sync `main` INTO the branch
  first (merge main → branch), resolve conflicts ON the branch, get CI
  green on the branch, THEN merge. Never merge a stale branch straight
  into main.
- **"Foundation first, branch second":** if CI is red on both `main` and
  a branch, fix `main` FIRST.
- **Gate (milestone flow):** work locally → push one batch → CI green →
  Manh tests live on his Mac → ok / reports bugs → fix → only then move
  to the next milestone.
- **Commit message marker `[build-app]`:** the app artifact is only built
  when the commit message contains `[build-app]` (see §3). Only put
  `[build-app]` in a commit when Manh explicitly says "build-app". Do not
  decide it yourself, even if the change is visible in the app.
- **Docs-only changes never run CI** (see §2). `docs/TIMELOG.md` is
  updated locally after each batch and merged into the next code push —
  never committed on its own.

## 2. CI test workflow (`ci.yml`)

### At a glance

- Trigger: `push` and `pull_request`, on **all branches** (there is no
  `branches: [main]` filter — SeekZip works on feature branches before
  merging, so CI must run there too). `paths-ignore` for `docs/**` and
  `**.md` on both triggers: docs-only changes never start a run.
- Runner: `macos-15` (Apple Silicon — matches the app's target platform).
- Two jobs, no concurrency group (unlike TransPeek, a new push does NOT
  cancel the run still going — rapid pushes can leave several runs in
  flight; the newest run carries all changes, so its result is the
  conclusive one).
- Job 1, `build-and-test` — runs on every code push:
  Checkout → Install 7-Zip engine (`brew install sevenzip unar
  xcbeautify`) → `swift build` (core, CLI, MCP, app) → Build Xcode
  project, Debug, unsigned (`xcodebuild -project SeekZip.xcodeproj
  -scheme SeekZip -configuration Debug build CODE_SIGNING_ALLOWED=NO`,
  piped through `xcbeautify` with `set -o pipefail`) → `swift test` →
  Generate test fixtures (`Tests/Matrix/generate-matrix.sh`) → Matrix
  smoke tests via the CLI (list/test/extract/verify/convert; zip-slip
  must exit 4; truncated archive must fail cleanly).
- Job 2, `build-app` — only when the commit message contains
  `[build-app]`, and only after `build-and-test` passes (see §3).

### How tests run

- `swift test` runs the unit tests (108 tests green as of 2026-11-11).
  The VM has no Xcode/SwiftUI, so `swift test` there only builds
  core/CLI/MCP — **SwiftUI/API errors are only caught by CI** (macOS 15,
  Xcode 16.4, project in Swift 5 language mode).
- The Xcode project build step compiles the app AND both extensions
  (FinderSync, QuickLook) — a broken `project.pbxproj` or a bad
  Resources phase fails here, not in `swift build`.
- The matrix smoke tests use fixtures generated on the runner
  (`/tmp/fixtures`): plain ZIP, solid 7z, header-encrypted 7z (must fail
  without a password), truncated ZIP (must fail cleanly, no crash),
  zip-slip ZIP (extract must exit 4), big ZIP (`list --stream`), nested
  ZIP, preview, verify, convert ZIP → 7z. The full case list is in
  `docs/TEST-MATRIX.md`. Large fixtures (10 GB+, 1M entries) are
  generated on CI runners, never committed.

### Diagnostics: what reaches the CI log and what does NOT

- **Log policy: xcbeautify, never errors-only.** Do NOT configure the
  build to output only error lines. A failing test does not show up as an
  `error:` line — it shows up as `recorded an issue` plus a summary at
  the end of the log. Warnings can also be the clue. Filtering to
  errors-only would hide all of that context. `xcodebuild` output is
  piped through `xcbeautify` with `set -o pipefail` so a failing
  `xcodebuild` still fails the step (see §4, the false-green lesson).
- **Reading CI status via the GitHub API is allowed, reading CI logs via
  the API is blocked (403).** Poll status sparsely — 5–10 minutes apart,
  only while a run is running, then stop. Read logs in the browser when
  diagnosis is needed. Re-check roughly once a week whether API log
  reads are unblocked.
- **Rate limit only affects this VM.** Unauthenticated API calls share
  60/hour per IP with the whole VM host — expect 429s. It does NOT
  affect Manh's GitHub account. `raw.githubusercontent.com` is not
  rate-limited the same way.
- **CI is sometimes flaky:** unit tests occasionally fail or hang with no
  code change. A red run on a test step with no code change → re-run
  first, before reading code.
- **Runner capacity:** GitHub macOS runners sometimes run out of machines
  (a run sits queued, then is cancelled with 0 steps run — that is NOT a
  code failure). TransPeek hit this often in Nov 2026; SeekZip had not
  hit it as of 2026-11-11. A cancelled run with 0 steps is a capacity
  problem, not a red run — re-run it.
- **A red run that is only "cancelled" because a newer push superseded
  it is not a failure** — but `ci.yml` has no concurrency group, so
  supersede-cancels should not happen here; if a run is cancelled, check
  whether it was capacity (0 steps) before assuming anything.

### Caching

- There is **no caching** in `ci.yml`: every run does a fresh
  `brew install sevenzip unar xcbeautify` and a fresh `swift build`.
  Keep it that way unless runs get slow — the TransPeek rule (keep
  caches under ~80 MB) applies if caching is ever added.

## 3. Build workflow (app artifact + ad-hoc signing)

### Build steps (all gated on `[build-app]`)

Job `build-app` (`if: github.event_name == 'push' &&
contains(github.event.head_commit.message, '[build-app]')`,
`needs: build-and-test`, `runs-on: macos-15`):

1. Checkout.
2. Install 7-Zip engine (`brew install sevenzip unar xcbeautify`).
3. Stage engines into `build/Helpers` (`bash scripts/package-engines.sh`
   — bundles the official macOS arm64 `7zz` 26.05 + `License.txt`,
   SHA-256 pinned; never download the engine from third-party mirrors).
4. Build app, Release, unsigned: `xcodebuild -project SeekZip.xcodeproj
   -scheme SeekZip -configuration Release build
   CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=${{ github.run_number }}
   -derivedDataPath .build/xcode-derived | xcbeautify` (with
   `set -o pipefail`). `CURRENT_PROJECT_VERSION` is the CI run number,
   so About shows "Build CI #<number>" (hidden when it is "1", i.e. a
   local build).
5. Ad-hoc sign app and extensions (see below).
6. Zip app: `test -x .../SeekZip.app/Contents/MacOS/SeekZip` guard, then
   `ditto -c -k --keepParent .../SeekZip.app SeekZip-macOS.zip`.
7. Upload artifact: name `SeekZip-macOS`, retention 30 days. The name
   does NOT carry the run number (unlike TransPeek's
   `TransPeek-macOS-<run>`) — each run's artifact is separate, but
   downloads from different runs share a name; always download from the
   newest green run.

### Ad-hoc signing — why, and its limits

- **Why:** macOS refuses an unsigned extension. The FinderSync and
  Quick Look extensions only load if the app is signed, so the build-app
  job signs them ad-hoc (`codesign --force --sign -`, each appex with
  its own entitlements first, then the app, then `codesign --verify
  --deep --strict`). Added 2026-11-11 (commit `8d00729`); verified by
  run #167.
- **Limits (Manh's decision, 2026-11-11: keep ad-hoc):** every build gets
  a new identity, so TCC permissions (Accessibility, Screen Recording)
  granted for one build do NOT carry over to the next, and the app cannot
  be notarized. First launch needs right-click → Open (or `xattr -cr`)
  to pass Gatekeeper. If live testing shows Finder does not load the
  extension with ad-hoc signing, the next step is a self-signed
  certificate (the TransPeek pattern) — not done yet.
- The $99/year Apple Developer membership is deferred; the notarize code
  is kept as a fallback.

### Artifact ≠ Release

- The artifact lives only on the Actions run page, expires after 30
  days, and notifies nobody. It is a test build, not a release.
- A real release is manual (tag + checklist in `docs/RELEASE.md`).
  There is no `release.yml`, no pre-release automation, and no
  auto-update feed yet (Sparkle comes with the release milestone).
- Manh's Mac has only Command Line Tools + Swift (no Xcode.app, ~12 GB
  free vs ~15 GB for Xcode) — **prefer a CI artifact over asking him to
  install heavy tools locally**.

## 4. Intervention log (what was changed, when, why)

Chronological, so a future investigator can see the cause and the fix for
each recurring problem.

- **2026-11-07/08 — `ci.yml` created with two jobs (M7).** `build-and-test`
  on every code push; `build-app` gated on `[build-app]`, building the
  Release app unsigned with `CURRENT_PROJECT_VERSION` = run number.
  The Xcode project build step (Debug, unsigned) was added 2026-11-08
  after Manh added `brew install unar` + the step by hand — it found 3
  real bugs in a row (see `docs/TIMELOG.md`, "Post-M7 — CI repair").
- **2026-11-08 — False-green artifact, run #146 (commit `0b2e325`).**
  Run #146 reported SUCCESS on both jobs, but the artifact was only 306
  bytes: the Release build had actually failed (Swift type-check timeout
  in `BrowserView.body`), but the step piped `xcodebuild` through
  `| xcbeautify` and the Actions shell (`/bin/bash -e`, no pipefail)
  swallowed `xcodebuild`'s exit code — `ditto` then zipped a
  nonexistent `.app` without error. Fix: `set -o pipefail` before both
  `xcodebuild` commands + a `test -x .../SeekZip.app/Contents/MacOS/SeekZip`
  guard before `ditto`. Proven by run #147, which failed loudly in
  1m30s with the real type-check error. **Rule: after every green run,
  check the artifact is real (~5.6 MB), not just that the run is
  green.**
- **2026-11-08 — Body split (commit `c8e5802` [build-app]).** The
  type-check timeout was `BrowserView.body` being too complex. Fix:
  split `body` into 4 declarations (`renameRow`, `fileList`,
  `statusLine`, `@ToolbarContentBuilder mainToolbar`); `body` only
  assembles. The timeout never recurred after the split.
- **2026-11-08 — `.onKeyPress` saga (runs #149/#150 red, fix `d0ea047`,
  run #151 green).** `.onKeyPress(.space) { press in ... }` fails: the
  single-key form takes NO argument. `.onKeyPress([.space])` also fails
  (no Set overload). Fix: the plain zero-arg `.onKeyPress(.space)` form
  + a repeat guard in `QuickLookController` so a held Space does not
  re-extract the entry.
- **2026-11-11 — Docs-only changes ran CI (commit `5fdfbe6`).** `ci.yml`
  had no `paths-ignore` at all, while TransPeek's `test.yml` and
  TransPeek-Windows' `build.yml` both had it — two docs-only commits
  each ran a full CI run. Manh asked why. Fix (via browser): added
  `paths-ignore: ['docs/**', '**.md']` to `push` + `pull_request`,
  exactly like the other two repos. Deliberately did NOT copy
  `branches: [main]` — SeekZip works on feature branches before merging,
  so CI must run there too. The fix commit itself ran CI once (run
  #42924194175) — the last wasted run of this kind.
- **2026-11-11 — Ad-hoc signing (commit `8d00729`, via browser).**
  Added the ad-hoc sign step to `build-app` (appex ×2 with their
  entitlements, then the app, `codesign --verify`). Verified by run
  #167 (commit `2cd86fcf` [build-app], SUCCESS 5m35s): artifact
  `SeekZip-macOS` 5,669,731 bytes, sha256
  `fe0e7c5b8013212516762355d4f7d1251620255419d9354c9acb5538b85dbaad`,
  expires 2026-12-10.
- **2026-11-12/13 — Donate batch (commit `da01136`, run #173 SUCCESS
  2m02s).** The Xcode project build step validated the new Resources
  phase + `project.pbxproj` (the app had no Resources phase before).
  `build-app` skipped as expected (no `[build-app]` in the message).
- **2026-11-17 — `docs/RESEARCH/` added (commit `15c35785`, docs-only)
  and language-rule follow-up (commit `f4f5dd2b`, docs-only).** Both
  produced zero CI runs — the `paths-ignore` rule verified working
  (check-runs total 0). The follow-up reverted the Research link from
  `README.vi.md`/`README.zh-CN.md`: translations are only updated when
  Manh asks (language rule, 2026-11-17, all repos).

## 5. Quick reference

- **Local checks before pushing:** `swift test` (core/CLI/MCP only on
  the VM — no SwiftUI), `swift build`. GUI/Xcode errors are only caught
  by CI.
- **Push:** related files in ONE commit via `github push-files`
  (manifest file, NUL-delimited, outside the source dir); binary files
  via the browser, alone, BEFORE the code commit that needs them.
  Workflow files (`.github/workflows/*`) only from Manh's Mac or the
  browser with his explicit permission (connector = 403).
- **After every push:** monitor the newest CI run to its conclusion and
  report green (with the artifact link + size) or really red — never
  wait for Manh to notice. A cancelled run with 0 steps run is a
  capacity problem, not a failure; re-run it.
- **A red run with no code change:** re-run first. If it stays red, read
  the failing step's log in the browser (API log reads are 403).
- **Need a testable app:** put `[build-app]` in the commit message —
  only when Manh said "build-app". Download the artifact from the newest
  green run (`SeekZip-macOS`, ~5.6 MB); it expires after 30 days.
- **After any test or workflow change:** update this doc in the same
  round (cause, fix, verification status) — same rule as TransPeek.

## Links

- [Build from zero](BUILD_FROM_ZERO.md) (its §10 points here)
- [Test matrix](TEST-MATRIX.md)
- [Architecture](ARCHITECTURE.md)
- [Release guide](RELEASE.md)
- [Agent handoff](HANDOFF.md)
- [Research index](RESEARCH/README.md)
- [README](../README.md)
