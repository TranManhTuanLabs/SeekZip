# CI Notes (SeekZip)

> **Rule (2026-11-17, all repos): both workflow docs — this one and
> `GIT-CI-BUILD-SETUP.md` — must be updated TOGETHER whenever the
> workflow changes: same round, same commit if possible, never deferred
> to later.**

How the `CI` workflow (`.github/workflows/ci.yml`) is set up and how to
read a red run. Written so the next person (or future us) does not have to
rediscover any of this.

## Workflow at a glance

- Trigger: `push` and `pull_request`, on **all branches** (no
  `branches: [main]` filter). `paths-ignore` for `docs/**` and `**.md`:
  docs-only changes never start a run.
- Runner: `macos-15` (Apple Silicon). Two jobs, no concurrency group: a
  new push does NOT cancel the run still going — rapid pushes can leave
  several runs in flight; the newest run carries all changes, so its
  result is the conclusive one.
- Job 1, `build-and-test` — every code push: Checkout → Install 7-Zip
  engine (`brew install sevenzip unar xcbeautify`) → `swift build`
  (core, CLI, MCP, app) → Build Xcode project, Debug, unsigned
  (`CODE_SIGNING_ALLOWED=NO`, piped through `xcbeautify` with
  `set -o pipefail`) → `swift test` (108 tests) → Generate test fixtures
  → Matrix smoke tests via the CLI.
- Job 2, `build-app` — on every code push, and only after
  `build-and-test` passes: Stage engines
  (`scripts/package-engines.sh`) → Build app, Release, unsigned
  (`CURRENT_PROJECT_VERSION=${{ github.run_number }}`) → Ad-hoc sign app
  and extensions → Zip app (`ditto`, keeps the `.app` bundle) → Upload
  artifact `SeekZip-macOS` (30-day retention). The artifact name does
  NOT carry the run number (unlike TransPeek's
  `TransPeek-macOS-<run>`) — always download from the newest green run.

## When CI runs, and when the app is built

To avoid wasting CI runs (and other people's runners):

- **Docs-only changes do not trigger CI at all.** The `push` and
  `pull_request` triggers have `paths-ignore` for `docs/**` and
  `**.md` (added 2026-11-11, commit `5fdfbe6`).
- **Tests run on every code commit, and the app is built on every code
  commit too** (always build — Manh 2026-11-18, no more `[build-app]`
  gate). (Same as TransPeek mac and TransPeek-Windows — all three
  dropped the gate the same day.)

## The artifact is ad-hoc signed — verified working since run #167

The CI build used to be unsigned (`CODE_SIGNING_ALLOWED=NO`). An
unsigned build gets a new TCC identity (code hash) on every rebuild, so
permissions granted for one build do not carry over to the next — and
macOS refuses an unsigned extension outright, so Finder would never
load FinderSync or QuickLook.

Since 2026-11-11 (commit `8d00729`) the workflow has an "Ad-hoc sign
app and extensions" step (after Build app, before Zip app). It signs each `.appex` with its own entitlements first,
then the app, then `codesign --verify --deep --strict`. **Verified
working: run #167 (2026-11-11), artifact `SeekZip-macOS` 5,669,731
bytes, sha256
`fe0e7c5b8013212516762355d4f7d1251620255419d9354c9acb5538b85dbaad`.**
Ad-hoc is Manh's decision for now (2026-11-11): every build still gets
a new identity, so TCC permissions do not carry over and the app cannot
be notarized; first launch needs right-click → Open (or `xattr -cr`).
If live testing shows Finder does not load the extension with ad-hoc
signing, the next step is a self-signed certificate (the TransPeek
pattern) — not done yet. The $99/year Apple Developer membership is
deferred.

## Log policy: xcbeautify, never errors-only

Do NOT configure the build to output only error lines. A failing test
does not show up as an `error:` line — it shows up as `recorded an
issue` plus a summary at the end of the log. Warnings can also be the
clue. Filtering to errors-only would hide all of that context.

Instead, both `xcodebuild` steps pipe through **xcbeautify**
(`brew install xcbeautify`, then `xcodebuild ... | xcbeautify` with
`set -o pipefail` so a failing `xcodebuild` still fails the step). The
log stays complete for test results but drops the thousands of
`SwiftCompile` lines, so it loads fast in the GitHub web viewer.

## Caching

There is **no caching** in `ci.yml`: every run does a fresh
`brew install sevenzip unar xcbeautify` and a fresh `swift build`.
Keep it that way unless runs get slow — the TransPeek rule (keep caches
under ~80 MB) applies if caching is ever added.

## Reading a red run

1. Open the run, pick the job (`build-and-test` or `build-app`), then
   the step.
2. The failure is at the END of the step log: a compile error lists
   `file:line: error: ...`, a test failure lists `recorded an issue`
   and the final summary names the failing tests.
3. Check the step BEFORE blaming the last change: a red test step with
   no code change is usually the CI flake — re-run before touching
   code.
4. A run cancelled with 0 steps run is a runner-capacity problem, not a
   code failure — re-run it.
5. If the web viewer hangs on the huge log, download the log archive
   ("Download log archive") instead of fighting the viewer. CI logs
   cannot be read through the GitHub API (403) — use the browser.

## Known gotchas (learned the hard way)

- **False green (run #146, 2026-11-08).** The run reported SUCCESS but
  the artifact was only 306 bytes: the Release build had failed, but the
  step piped `xcodebuild` through `| xcbeautify` without `pipefail`, so
  the shell swallowed the exit code and `ditto` zipped a nonexistent
  `.app`. Fix: `set -o pipefail` before both `xcodebuild` commands + a
  `test -x .../SeekZip.app/Contents/MacOS/SeekZip` guard before `ditto`.
  **After every green run, check the artifact is real (~5.6 MB), not
  just that the run is green.**
- **Do not inline a huge `body`.** `BrowserView.body` grew too complex
  for the type checker (run #146's real failure: type-check timeout).
  Split `body` into small declarations (`renameRow`, `fileList`,
  `statusLine`, `mainToolbar`); `body` only assembles.
- **`.onKeyPress(.space)` takes zero arguments.** The form with a
  `press` parameter does not compile, and there is no Set overload
  (`.onKeyPress([.space])` fails too). Use the plain zero-arg form
  (runs #149/#150 red, fix `d0ea047`, run #151 green).
- **`upload-artifact` with a directory path loses the directory
  itself** — zip the `.app` first (`ditto -c -k --keepParent`).
- **macOS normalizes `Process` arguments to NFD.** An entry name stored
  NFC in the archive can never match through argv — pass entry names to
  `7zz` via `@listfile` so the bytes reach it verbatim (proven by the
  `verify` failure on `src/tiếng việt.txt`, fixed 2026-11-08).
- **API rate limit (60/hour, unauthenticated, shared VM IP).** Status
  checks via the API: poll sparsely (5–10 minutes apart, only while a
  run is running). Log reads via the API are blocked (403) — use the
  browser. The limit does NOT affect Manh's GitHub account.
- **Approval cards expire after 30 minutes.** An expired/denied card
  only blocks that push — the code is not lost; re-push and a new card
  appears.
- **The VM cannot catch SwiftUI errors.** `swift test` on the VM only
  builds core/CLI/MCP (no Xcode/SwiftUI) — a green local test run says
  nothing about the GUI. Only CI catches SwiftUI/API errors.
- **Docs-only commits never run CI** — but a commit that touches
  `.github/workflows/*.yml` DOES run CI (workflows are not in
  `paths-ignore`), and the connector cannot push workflow files at all
  (403). Workflow edits go through Manh's Mac or the browser, with his
  explicit permission.

## Links

- [Setup + intervention log](GIT-CI-BUILD-SETUP.md)
- [Build from zero](../BUILD_FROM_ZERO.md)
- [Test matrix](../TEST-MATRIX.md)
- [Architecture](../ARCHITECTURE.md)
- [README](../README.md)
