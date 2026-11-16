# Building SeekZip from Zero

Audience: a developer (human or AI agent) with a fresh Mac who has never seen
this project. Follow top to bottom; every step is verifiable.

Background research behind the decisions in this guide lives in
[`docs/RESEARCH/`](RESEARCH/README.md) (see the Research section at the end).

## 1. Prerequisites

| Need | Version | Check |
|---|---|---|
| macOS | 14.6+ on Apple Silicon (arm64) | `sw_vers`, `uname -m` → `arm64` |
| Xcode (or Command Line Tools + Swift) | Swift 5.10+ | `swift --version` |
| Git | any recent | `git --version` |
| 7-Zip engine (`7zz`) | latest stable | see step 3 |

Intel Macs and Linux cannot build the GUI target. The `SeekZipCore`
library is platform-independent Foundation code, but the package as a
whole targets macOS.

## 2. Get the source

```sh
git clone <this-repo> SeekZip
cd SeekZip
```

## 3. Install the engine

SeekZip drives the official `7zz` binary as a subprocess. For development,
install it system-wide:

```sh
brew install sevenzip        # provides /opt/homebrew/bin/7zz
7zz                          # prints the 7-Zip banner
```

Engine resolution order (see `SevenZipEngine.init`): explicit path →
`7zz` in the app bundle's Resources → `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin`. Release builds bundle the official macOS arm64 `7zz` from
7-zip.org together with its `License.txt` (LGPL) — never download it from
third-party mirrors.

Why the official `7zz` binary, and the hard limits (no RAR creation, App
Store sandbox, CVE pinning): see the [7-Zip / WinRAR parity
research](RESEARCH/seekzip-7zip-winrar-parity-20261106-1842/report.md).

## 4. Build

```sh
swift build                  # debug: core + seekzip CLI + seekzip-mcp + app
swift build -c release       # release binaries in .build/release/
```

## 5. Run the unit tests

```sh
swift test                   # listing parser + path-safety tests
```

Expected: all tests pass. These tests need no engine binary.

## 6. Smoke-test the CLI

```sh
echo "hello" > /tmp/hello.txt
.build/debug/seekzip create /tmp/demo.zip /tmp/hello.txt
.build/debug/seekzip list --json /tmp/demo.zip
.build/debug/seekzip test /tmp/demo.zip
mkdir -p /tmp/out && .build/debug/seekzip extract /tmp/demo.zip /tmp/out
cat /tmp/out/tmp/hello.txt
```

## 7. Generate the edge-case fixtures and run matrix smoke tests

```sh
chmod +x Tests/Matrix/generate-matrix.sh
Tests/Matrix/generate-matrix.sh /tmp/fixtures
.build/debug/seekzip list /tmp/fixtures/solid.7z
.build/debug/seekzip list /tmp/fixtures/truncated.zip   # must fail cleanly, no crash
.build/debug/seekzip extract /tmp/fixtures/zip-slip.zip /tmp/out
echo $?                                                  # must be 4 (safety-blocked)
```

The full case list lives in `docs/TEST-MATRIX.md`. Large fixtures
(10 GB+, 1M entries) are generated on CI runners, never committed.

## 8. Run the GUI

```sh
swift run SeekZipApp
```

Open an archive, filter entries, select some, extract them.

## 9. Try the MCP server

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | .build/debug/seekzip-mcp
```

Any MCP client can spawn `seekzip-mcp` over stdio with the same tools.

Background: [CLI + MCP research](RESEARCH/seekzip-cli-mcp-ai-need-20261110-1931/report.md)
(in Vietnamese) — why the CLI exists and what the MCP server is for.

## 10. CI

`.github/workflows/ci.yml` runs on a macOS 15 ARM runner for every push:
install engine → `swift build` → `swift test` → generate fixtures →
CLI matrix smoke tests. A red CI blocks merges. Docs-only changes
(`docs/**`, `*.md`) do not trigger CI; the app artifact is built only when
the commit message contains `[build-app]`. Full git + CI + build setup,
including the intervention log: `docs/GIT-CI-BUILD-SETUP.md`.

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `EngineError.binaryNotFound` | `7zz` not installed; redo step 3 |
| List of an encrypted archive returns "wrong password" | Expected for header-encrypted archives without a password; pass `-p` (CLI flag planned) / `password` (API, MCP) |
| A command hangs forever | Should not happen: engine stdin is `/dev/null` by design. If it does, file a bug with the archive |
| `swift build` fails on the app target on Linux | Expected — build on macOS |

## 12. Packaging (status)

App bundle with bundled `7zz` + license, FinderSync and Quick Look
extensions: implemented (milestones M1–M7, app v0.2.0); CI builds the app
artifact when the commit message contains `[build-app]`, signed ad-hoc.
Still open: Developer ID signing + notarisation (Apple Developer membership
deferred), Homebrew tap/cask. See `docs/HANDOFF.md` for the milestone order
and `docs/RELEASE.md` for the release checklist.

## Research

Background research behind this guide, in [`docs/RESEARCH/`](RESEARCH/README.md):

- [7-Zip / WinRAR parity](RESEARCH/seekzip-7zip-winrar-parity-20261106-1842/report.md)
  (2026-11-06, English) — why the official `7zz` engine, and the hard limits.
  Kept as future marketing source.
- [CLI + MCP for AI assistants](RESEARCH/seekzip-cli-mcp-ai-need-20261110-1931/report.md)
  (2026-11-10, Vietnamese) — why the CLI and MCP server exist.
- [UI/UX redesign, Apple style](RESEARCH/seekzip-ui-redesign-apple-style-20261111-1547/report.md)
  (2026-11-11, Vietnamese) — the full redesign proposal; its direction was
  superseded 2026-11-13 (main keeps the minimal UI, full redesign to a
  separate branch).
