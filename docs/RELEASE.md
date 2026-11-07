# SeekZip — Release guide (v0.2.0)

How to turn this repo into the first signed, notarised SeekZip release.
Read the whole file before starting: steps 1–2 are one-time setup,
steps 3–5 are the first build, steps 6–8 are the release itself.

## 0. What is (and is not) verified yet

Verified on the Linux CI/VM (2026-11-07, M7):

- `swift build` + `swift test` green (101 tests, incl. the new M7
  preview-fallback and bundled-engine tests).
- `SeekZip.xcodeproj/project.pbxproj` parses as a valid OpenStep plist
  (`scripts/validate-xcodeproj.py` — run it after any project edit);
  every referenced file exists, every `SeekZipCore` source is in the
  core target, both extensions are embedded and link the core.
- All `.plist` / `.entitlements` files parse; `scripts/package-engines.sh`
  downloads 7-Zip 26.05 and verifies its SHA-256; both scripts pass
  `bash -n`; `scripts/release.sh` refuses to run off macOS.
- The CLI smoke path works (`seekzip engines`, clean exit codes).

NOT verified — needs a Mac with full Xcode (nobody has run this yet):

- The Xcode project has never been built. The GUI (`Sources/SeekZipApp`)
  has never compiled anywhere: SwiftUI macros need full Xcode, and the
  Mac that owns this project has Command Line Tools only.
- Signing, notarisation, stapling, Gatekeeper, the Finder Sync and
  Quick Look extensions loading, the App Group sharing settings, and
  the bundled helpers running inside the sandbox are all unproven
  until the first build on the Mac. Expect the first build to surface
  small fixable issues (missing team, entitlements, a wrong build
  setting). That is normal for a first Xcode project — fix them in
  Xcode, commit, and re-run the validator.

## 1. One-time setup (owner)

### 1.1 Apple Developer account — OPEN QUESTION

A Developer ID release (distribute outside the App Store) needs a
paid Apple Developer Program membership ($99/year). The owner has not
confirmed whether they have one.

- If yes: the Team ID is at <https://developer.apple.com/account>
  (Membership details). Export it as `DEVELOPER_TEAM_ID` for
  `scripts/release.sh`.
- If no: the app can still be built and run locally from Xcode
  (personal team, "Sign to Run Locally"), but it cannot be notarised
  and Gatekeeper will block it on other Macs. Do not distribute that
  build. The Mac App Store route needs the same paid membership plus
  App Store Connect setup — it is the second distribution step, not
  this release.

### 1.2 Disk space — OPEN QUESTION

Full Xcode needs ~15 GB; the owner's Mac had ~12 GB free when last
checked (2026-11-07). Free space first (Xcode download alone fails
otherwise): delete old simulators (`xcrun simctl delete unavailable`),
DerivedData (`rm -rf ~/Library/Developer/Xcode/DerivedData`), and
unused apps. Then install Xcode from the App Store (not just Command
Line Tools) and open it once so it finishes installing its components.

### 1.3 App Group

The app and its extensions share engine settings through the App Group
`group.com.seekzip.app` (placeholder — see below). In the developer
account, create an App Group with your Team ID prefix
(`group.<TEAMID>.seekzip`), then replace `group.com.seekzip.app` with
it in these places (same string everywhere):

- `Sources/SeekZipCore/AppBundle.swift` (`SeekZipAppGroup.suiteName`)
- `SeekZip/SeekZip.entitlements`
- `SeekZipFinderSync/FinderSync.entitlements`
- `SeekZipQuickLook/QuickLook.entitlements`

Until the group exists, the app falls back to plain `UserDefaults`
(the extensions then cannot see the app's engine settings — verify
this explicitly in step 4).

### 1.4 Notarisation profile (one command, on the Mac)

```sh
xcrun notarytool store-credentials seekzip-notary \
    --apple-id <your Apple ID> --team-id <Team ID> --password <app-specific password>
```

The password is an app-specific password from
<https://appleid.apple.com> (not your Apple ID password). The profile
name `seekzip-notary` is what `scripts/release.sh` expects
(`NOTARY_PROFILE` overrides it).

### 1.5 Homebrew tap repo (one-time, on GitHub)

Create an empty public repo `TranManhTuanLabs/homebrew-seekzip`.
After the first release (step 7), copy into it:

- `packaging/homebrew/Formula/seekzip.rb` → `Formula/seekzip.rb`
- `packaging/homebrew/Casks/seekzip.rb` → `Casks/seekzip.rb`

with the two SHA-256 values filled in (step 7). Users then install with:

```sh
brew tap TranManhTuanLabs/seekzip
brew install --cask seekzip   # the app
brew install seekzip          # the CLI + MCP server
```

## 2. First build in Xcode (on the Mac)

```sh
git pull
open SeekZip.xcodeproj
```

1. Select the **SeekZip** target → Signing & Capabilities → Team:
   pick your team. (The project ships with an empty team; Xcode will
   offer to fix signing — accept it, then check the bundle IDs are
   still `com.seekzip.app`, `com.seekzip.app.FinderSync`,
   `com.seekzip.app.QuickLook`, or your own equivalents.)
2. Select the **SeekZipCore** scheme? No — build the **SeekZip** scheme
   (Product → Build, ⌘B). The core builds as a static library inside
   the app; the CLI/MCP are not Xcode targets (they stay SwiftPM:
   `swift build`).
3. If the build complains about the App Group capability, add it in
   Signing & Capabilities → + Capability → App Groups, and tick the
   group created in §1.3.
4. Run (⌘R). Verify by hand:
   - the browser opens an archive, lists entries, previews text with
     Space, drills into a nested archive;
   - Engines… → change the default engine, quit, relaunch — the
     setting sticks (App Group works);
   - `seekzip` CLI from the same checkout still builds
     (`swift build` — the Xcode project must not break SwiftPM).
5. Extensions: after the first run, enable the Finder Sync extension
   in System Settings → Privacy & Security → Extensions → Finder
   Extensions, then right-click a ZIP in Finder — "Open with SeekZip"
   and "Extract Here" should appear. Quick Look (Space on a ZIP in
   Finder) should show the entry listing. If an extension does not
   appear, check Console.app for the extension's bundle ID.

## 3. Release build (scripted)

```sh
DEVELOPER_TEAM_ID=<Team ID> ./scripts/release.sh
```

What it does: stages the engines (`scripts/package-engines.sh`,
7-Zip 26.05 SHA-256-checked, `brew install unar` for lsar/unar),
archives with Xcode, exports a Developer ID app, builds the DMG +
ZIP, notarises with `notarytool` (profile `seekzip-notary`), staples
the ticket to the app and the DMG, and runs `spctl --assess` +
`codesign --verify`. It prints the DMG SHA-256 at the end.

`--skip-notarize` builds and signs without notarising (first smoke
build only — that build is NOT Gatekeeper-clean, do not distribute it).

Manual equivalents (if the script fails midway, resume by hand):

```sh
./scripts/package-engines.sh
xcodebuild -project SeekZip.xcodeproj -scheme SeekZip \
    -configuration Release -archivePath build/SeekZip.xcarchive \
    DEVELOPMENT_TEAM=<Team ID> archive
xcodebuild -exportArchive -archivePath build/SeekZip.xcarchive \
    -exportPath build -exportOptionsPlist build/ExportOptions.plist
xcrun notarytool submit build/SeekZip-0.2.0.dmg \
    --keychain-profile seekzip-notary --wait
xcrun stapler staple build/SeekZip.app build/SeekZip-0.2.0.dmg
spctl --assess --type execute --verbose build/SeekZip.app
```

## 4. Pre-release verification checklist

Run through this on the Mac before uploading anything:

- [ ] App launches from the DMG on a fresh user account (or after
      `xattr -cr` on a copy) with no Gatekeeper warning.
- [ ] `spctl --assess --type execute build/SeekZip.app` passes.
- [ ] Bundled helpers run inside the sandbox: in the app, extract a
      ZIP and a StuffIt archive (7zz + unar from
      `SeekZip.app/Contents/Resources/Helpers/`).
- [ ] Engine setting changed in the app is honoured by Quick Look
      (App Group sharing works).
- [ ] Finder Sync menu appears and "Extract Here" extracts.
- [ ] `swift build && swift test` still green in the same checkout.
- [ ] `seekzip verify` on a fixture archive passes.

## 5. GitHub release

```sh
git tag v0.2.0
git push origin v0.2.0
```

Then on <https://github.com/TranManhTuanLabs/SeekZip/releases/new>:
tag `v0.2.0`, title `SeekZip v0.2.0 — first packaged release`, upload
`build/SeekZip-0.2.0.dmg` (and the ZIP), and paste the release notes
from the README status section. Get the source tarball SHA-256:

```sh
curl -sL -o /tmp/seekzip-0.2.0.tar.gz \
  https://github.com/TranManhTuanLabs/SeekZip/archive/refs/tags/v0.2.0.tar.gz
shasum -a 256 /tmp/seekzip-0.2.0.tar.gz
```

## 6. Homebrew

Fill in the two placeholders and push to the tap repo (§1.5):

- `Formula/seekzip.rb`: `sha256` = source tarball SHA-256 (§5).
- `Casks/seekzip.rb`: `sha256` = DMG SHA-256 printed by
  `scripts/release.sh`.

Then test the tap on a clean machine:

```sh
brew tap TranManhTuanLabs/seekzip
brew install --cask seekzip
brew install seekzip
seekzip engines
```

## 7. Lines owed in `.github/workflows/ci.yml` (owner only)

Muse cannot edit workflow files (GitHub App has no Workflows
permission — 403). Add these to `ci.yml` from the Mac and push. The
current `ci.yml` is the M1 version: install sevenzip, `swift build`,
`swift test`, fixtures, smoke tests.

```yaml
      - name: Install 7-Zip engine
        run: brew install sevenzip unar   # <- add unar (M6, ENG-09)

      - name: Build (core, CLI, MCP, app)
        run: swift build

      - name: Build Xcode project (app + extensions, unsigned)
        run: |
          xcodebuild -project SeekZip.xcodeproj -scheme SeekZip \
            -configuration Debug build \
            CODE_SIGNING_ALLOWED=NO
```

And append these lines to the "Matrix smoke tests via CLI" step
(smoke coverage owed since M2/M3/M5 — the fixtures already exist,
`generate-matrix.sh` makes `big.zip` and `nested.zip`):

```sh
          $BIN list --stream /tmp/fixtures/big.zip > /dev/null
          $BIN list /tmp/fixtures/nested.zip inner.zip
          $BIN preview /tmp/fixtures/nested.zip "inner.zip!/src/hello.txt"
          $BIN verify /tmp/fixtures/plain.zip
          $BIN convert /tmp/fixtures/plain.zip /tmp/converted.7z
          $BIN test /tmp/converted.7z
```

Notes: the `xcodebuild` step is unsigned (`CODE_SIGNING_ALLOWED=NO`)
because CI has no Developer ID certificate — it proves the project
compiles, not that it is signed. It also needs a macOS runner with
Xcode (macos-15 already has it). The `brew install unar` line enables
ENG-09 (real-unar smoke test); the unar smoke itself is a later
addition once the fixture exists.

## 8. After v0.2.0

- Mac App Store (second distribution): separate bundle IDs /
  entitlements review (sandbox + `com.apple.security.files.bookmarks`
  for security-scoped access), App Store Connect listing, screenshots,
  AppIcon asset catalog (the project currently ships without an app
  icon — add `SeekZip/Assets.xcassets` with an AppIcon set before any
  store submission).
- Versioning: bump `MARKETING_VERSION` in the Xcode project (and the
  Homebrew files) per release; `CURRENT_PROJECT_VERSION` increments
  per build.
- Engine updates: 7-Zip releases are infrequent but security-critical
  (CVE-2026-14266 was fixed in 26.02). To update the pinned engine,
  change `SEVENZIP_VERSION` / `SEVENZIP_URL` / `SEVENZIP_SHA256` in
  `scripts/package-engines.sh`, re-run it, and re-run the parser
  golden tests (`swift test`) before releasing.
