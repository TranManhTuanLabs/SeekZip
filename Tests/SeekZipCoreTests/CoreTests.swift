import XCTest
@testable import SeekZipCore

final class ListingParserTests: XCTestCase {
    private let sample = """
    7-Zip (z) 24.09 (arm64) : Copyright (c) 1999-2024 Igor Pavlov

    Listing archive: demo.zip

    --
    Path = demo.zip
    Type = zip
    Physical Size = 1234

    ----------
    Path = folder
    Folder = +
    Size = 0
    Packed Size = 0
    Attributes = D drwxr-xr-x

    Path = folder/file = with equals.txt
    Folder = -
    Size = 42
    Packed Size = 40
    Modified = 2024-05-01 10:11:12.1234567
    CRC = DEADBEEF
    Method = Deflate
    Encrypted = -
    Attributes = A -rw-r--r--

    """

    func testParsesEntries() {
        let info = ListingParser.parse(archivePath: "demo.zip", text: sample)
        XCTAssertEqual(info.entries.count, 2)
        XCTAssertTrue(info.entries[0].isDirectory)
        XCTAssertEqual(info.entries[1].path, "folder/file = with equals.txt")
        XCTAssertEqual(info.entries[1].size, 42)
        XCTAssertEqual(info.entries[1].crc, "DEADBEEF")
        XCTAssertFalse(info.entries[1].isEncrypted)
        XCTAssertEqual(info.totalUncompressed, 42)
    }
}

final class NestedPreviewTests: XCTestCase {
    /// A fake `7zz` that serves three listing levels (outer → inner →
    /// deep), creates extracted files for `x`, and prints preview bytes
    /// for `e -so` according to `previewMode` ("text", "long",
    /// "binary", "utf8"). Mirrors the fixture layout of
    /// Tests/Matrix/generate-matrix.sh (nested.zip / inner.zip).
    private func makeFake7zz(previewMode: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake7zz")
        let previewCommand: String
        switch previewMode {
        case "binary":
            previewCommand = "printf 'PNG\\000binary\\000data'"
        case "long":
            previewCommand = "i=1; while [ $i -le 300 ]; do printf 'line %d\\n' \"$i\"; i=$((i+1)); done"
        case "utf8":
            // Octal UTF-8 for "xin chào tiếng Việt" (dash printf has no \x).
            previewCommand = "printf 'xin ch\\303\\240o ti\\341\\272\\277ng Vi\\341\\273\\207t\\nsecond line\\n'"
        default:
            previewCommand = "printf 'hello seekzip\\nsecond line\\n'"
        }
        let text = """
        #!/bin/sh
        for last in "$@"; do :; done
        cmd="$1"
        if [ "$cmd" = "l" ]; then
          case "$last" in
            *deep.zip)
              printf '7-Zip (z) 24.09\\n\\nListing archive: deep.zip\\n\\n--\\nPath = deep.zip\\nType = zip\\nPhysical Size = 10\\n\\n----------\\nPath = deep-file.txt\\nFolder = -\\nSize = 4\\n\\n'
              ;;
            *inner.zip)
              printf '7-Zip (z) 24.09\\n\\nListing archive: inner.zip\\n\\n--\\nPath = inner.zip\\nType = zip\\nPhysical Size = 50\\n\\n----------\\nPath = deep.zip\\nFolder = -\\nSize = 40\\n\\nPath = inner-file.txt\\nFolder = -\\nSize = 9\\n\\n'
              ;;
            *)
              printf '7-Zip (z) 24.09\\n\\nListing archive: outer.zip\\n\\n--\\nPath = outer.zip\\nType = zip\\nPhysical Size = 100\\n\\n----------\\nPath = hello.txt\\nFolder = -\\nSize = 5\\n\\nPath = inner.zip\\nFolder = -\\nSize = 50\\n\\n'
              ;;
          esac
          exit 0
        fi
        if [ "$cmd" = "x" ]; then
          dest=""
          for a in "$@"; do case "$a" in -o*) dest="${a#-o}";; esac; done
          mkdir -p "$(dirname "$dest/$last")"
          : > "$dest/$last"
          exit 0
        fi
        if [ "$cmd" = "e" ]; then
          \(previewCommand)
          exit 0
        fi
        exit 2
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    private func outerURL() -> URL {
        URL(fileURLWithPath: "/tmp/outer.zip")
    }

    // MARK: Nested listing

    func testNestedListsOneLevel() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let info = try engine.listNested(archive: outerURL(), nestedPath: ["inner.zip"])
        XCTAssertEqual(info.entries.map(\.path), ["deep.zip", "inner-file.txt"])
        XCTAssertTrue(info.path.contains("outer.zip!/inner.zip"))
    }

    func testNestedListsTwoLevels() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let info = try engine.listNested(archive: outerURL(),
                                         nestedPath: ["inner.zip", "deep.zip"])
        XCTAssertEqual(info.entries.map(\.path), ["deep-file.txt"])
        XCTAssertTrue(info.path.contains("inner.zip!/deep.zip"))
    }

    func testNestedRejectsTraversal() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        XCTAssertThrowsError(try engine.listNested(archive: outerURL(),
                                                   nestedPath: ["../evil.zip"])) { error in
            XCTAssertTrue(error is EntryPathSafety.Violation,
                          "expected a path-safety violation, got \(error)")
        }
    }

    func testNestedMissingEntryThrows() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        XCTAssertThrowsError(try engine.listNested(archive: outerURL(),
                                                   nestedPath: ["nope.zip"]))
    }

    func testNestedRejectsNonArchiveEntry() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        XCTAssertThrowsError(try engine.listNested(archive: outerURL(),
                                                   nestedPath: ["hello.txt"]))
    }

    // MARK: Streaming entry bytes

    func testStreamEntryCompletes() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        var bytes = Data()
        let completed = try engine.streamEntry(archive: outerURL(), entry: "hello.txt") { chunk in
            bytes.append(chunk)
            return true
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self),
                       "hello seekzip\nsecond line\n")
    }

    func testStreamEntryStopsEarly() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "long").path)
        var chunks = 0
        let completed = try engine.streamEntry(archive: outerURL(), entry: "hello.txt") { _ in
            chunks += 1
            return false // stop after the first chunk
        }
        XCTAssertFalse(completed)
        XCTAssertEqual(chunks, 1)
    }

    /// Regression test for CI #126: `verify` reported a CRC mismatch
    /// (expected 762D6F5D, got 00000000) for `src/tiếng việt.txt` on
    /// macOS while the same fixture verified fine on Linux. The entry
    /// name in the listing is NFC (composed) but the name 7zz stores —
    /// and matches against — can be NFD (decomposed) on macOS, and
    /// `7zz e -so` with a non-matching name exits 0 with empty output,
    /// so the entry hashed to the CRC of zero bytes. `streamEntry` must
    /// retry with the alternate normalization instead of returning
    /// empty content. Uses the real 7zz (CI installs it before unit
    /// tests); skipped when no engine is installed.
    func testStreamEntryRetriesAlternateNormalization() throws {
        guard let engine = try? SevenZipEngine() else {
            throw XCTSkip("real 7zz not installed")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "tiếng việt.txt".precomposedStringWithCanonicalMapping
        let file = dir.appendingPathComponent(name)
        try "xin chào\n".write(to: file, atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("nfc.zip")
        let create = Process()
        create.executableURL = engine.binaryURL
        create.currentDirectoryURL = dir
        create.arguments = ["a", "-tzip", archive.path, name]
        create.standardOutput = FileHandle.nullDevice
        create.standardError = FileHandle.nullDevice
        try create.run()
        create.waitUntilExit()
        XCTAssertEqual(create.terminationStatus, 0, "fixture creation failed")

        let info = try engine.list(archive: archive)
        XCTAssertTrue(info.entries.contains { $0.path == name })
        // Ask for the entry in the alternate (NFD) form: the stored
        // name is NFC, so the first attempt matches nothing. (Compare
        // bytes: Swift `String ==` treats NFC and NFD as equal.)
        let nfd = name.decomposedStringWithCanonicalMapping
        XCTAssertFalse(nfd.utf8.elementsEqual(name.utf8),
                       "test needs a name with two normal forms")
        var bytes = Data()
        let completed = try engine.streamEntry(archive: archive, entry: nfd) { chunk in
            bytes.append(chunk)
            return true
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "xin chào\n")
    }

    /// TEMPORARY DIAGNOSTIC for CI #128: `verify` still reports
    /// `src/tiếng việt.txt` as CRC 00000000 on macOS even after the
    /// NFC/NFD retry, while the regression test above passes there.
    /// Prints the exact bytes of the on-disk name, the listed name,
    /// and what direct `7zz e -so` returns for each candidate form,
    /// then fails on purpose so the data lands in the CI log. REMOVE
    /// once the real cause is known.
    func testDiagnoseVietnameseFilename() throws {
        guard let engine = try? SevenZipEngine() else {
            throw XCTSkip("real 7zz not installed")
        }
        func hex(_ s: String) -> String {
            s.utf8.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let name = "tiếng việt.txt".precomposedStringWithCanonicalMapping
        // Mirror generate-matrix.sh: create the file with /bin/sh.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "printf 'xin chào, đây là file tiếng Việt\\n' > \"src/\(name)\""]
        sh.currentDirectoryURL = dir
        sh.standardOutput = FileHandle.nullDevice
        sh.standardError = FileHandle.nullDevice
        try sh.run()
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 0, "fixture file creation failed")
        let zip = Process()
        zip.executableURL = engine.binaryURL
        zip.currentDirectoryURL = dir
        zip.arguments = ["a", "-tzip", "plain.zip", "src"]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0, "fixture zip creation failed")

        var lines: [String] = []
        for n in try FileManager.default.contentsOfDirectory(atPath: src.path) {
            lines.append("on-disk: \(hex(n))")
        }
        let archive = dir.appendingPathComponent("plain.zip")
        let info = try engine.list(archive: archive)
        for e in info.entries {
            lines.append("listed: \(hex(e.path)) crc=\(e.crc ?? "?")")
        }
        let listed = info.entries.first { $0.path.contains("vit") || $0.path.contains("ti") }?.path
            ?? "src/" + name
        lines.append("listed-used: \(hex(listed))")
        for (label, candidate) in [
            ("listed", listed),
            ("NFC", "src/" + name),
            ("NFD", "src/" + name.decomposedStringWithCanonicalMapping),
        ] {
            let p = Process()
            p.executableURL = engine.binaryURL
            p.arguments = ["e", "-so", "-y", "-sccUTF-8", archive.path, candidate]
            let out = Pipe()
            p.standardOutput = out
            let err = Pipe()
            p.standardError = err
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "\\n")
            lines.append("e-so \(label): exit=\(p.terminationStatus) bytes=\(data.count) err=[\(errText)]")
        }
        var bytes = Data()
        let completed = try engine.streamEntry(archive: archive, entry: listed) { chunk in
            bytes.append(chunk)
            return true
        }
        lines.append("streamEntry(listed): completed=\(completed) bytes=\(bytes.count)")
        for line in lines { print("DIAG " + line) }
        XCTFail("DIAG\n" + lines.joined(separator: "\n"))
    }

    // MARK: Text preview

    func testPreviewText() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "hello.txt", size: 24))
        XCTAssertEqual(preview.kind, .text)
        XCTAssertEqual(preview.text, "hello seekzip\nsecond line")
        XCTAssertFalse(preview.truncated)
        XCTAssertEqual(preview.linesShown, 2)
        XCTAssertFalse(preview.quickLook)
    }

    func testPreviewTruncatesLongText() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "long").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "long.txt", size: 1_000_000))
        XCTAssertEqual(preview.kind, .text)
        XCTAssertTrue(preview.truncated)
        XCTAssertEqual(preview.linesShown, PreviewProvider.maxPreviewLines)
        XCTAssertTrue(preview.text?.hasPrefix("line 1\n") ?? false)
        XCTAssertTrue(preview.text?.hasSuffix("line 200") ?? false)
        XCTAssertFalse(preview.text?.contains("line 201") ?? true)
    }

    func testPreviewUTF8Safe() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "utf8").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "tiếng việt.txt", size: 40))
        XCTAssertEqual(preview.kind, .text)
        XCTAssertEqual(preview.text, "xin chào tiếng Việt\nsecond line")
        XCTAssertFalse(preview.truncated)
    }

    func testPreviewNestedText() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let preview = try PreviewProvider(engine: engine)
            .previewNested(archive: outerURL(), nestedPath: ["inner.zip"],
                           entry: ArchiveEntry(path: "inner-file.txt", size: 9))
        XCTAssertEqual(preview.kind, .text)
        XCTAssertEqual(preview.text, "hello seekzip\nsecond line")
        XCTAssertFalse(preview.truncated)
    }

    func testPreviewBinaryDetectedByNUL() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "binary").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "data.bin", size: 100))
        XCTAssertEqual(preview.kind, .binary)
        XCTAssertNil(preview.text)
        XCTAssertTrue(preview.quickLook)
    }

    // MARK: Preview kinds without reading content

    func testPreviewImageNeedsQuickLook() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "photo.png", size: 12_345))
        XCTAssertEqual(preview.kind, .image)
        XCTAssertNil(preview.text)
        XCTAssertTrue(preview.quickLook)
        XCTAssertNotNil(preview.note)
    }

    func testPreviewArchiveEntry() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "inner.zip", size: 50))
        XCTAssertEqual(preview.kind, .archive)
        XCTAssertNil(preview.text)
        XCTAssertFalse(preview.quickLook)
    }

    func testPreviewDirectory() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "src", isDirectory: true))
        XCTAssertEqual(preview.kind, .directory)
        XCTAssertNil(preview.text)
    }

    func testPreviewEncryptedWithoutPassword() throws {
        let engine = try SevenZipEngine(binaryPath: try makeFake7zz(previewMode: "text").path)
        let preview = try PreviewProvider(engine: engine)
            .preview(archive: outerURL(), entry: ArchiveEntry(path: "secret.txt", isEncrypted: true))
        XCTAssertEqual(preview.kind, .encrypted)
        XCTAssertNil(preview.text)
    }
}

final class EntryPathSafetyTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/out")

    func testRejectsTraversal() {
        let e = ArchiveEntry(path: "../evil.txt")
        XCTAssertThrowsError(try EntryPathSafety.destinationURL(for: e, in: root))
    }

    func testRejectsAbsolute() {
        let e = ArchiveEntry(path: "/etc/passwd")
        XCTAssertThrowsError(try EntryPathSafety.destinationURL(for: e, in: root))
    }

    func testRejectsSymlinkByDefault() {
        let e = ArchiveEntry(path: "link", attributes: "lrwxrwxrwx")
        XCTAssertThrowsError(try EntryPathSafety.destinationURL(for: e, in: root))
    }

    func testAcceptsNormal() throws {
        let e = ArchiveEntry(path: "a/b/c.txt")
        let url = try EntryPathSafety.destinationURL(for: e, in: root)
        XCTAssertEqual(url.path, "/tmp/out/a/b/c.txt")
    }

    func testBombWarning() {
        let info = ArchiveInfo(path: "bomb.zip", format: "zip", physicalSize: 1_000_000,
                               entries: [ArchiveEntry(path: "big", size: 500_000_000)])
        XCTAssertNotNil(EntryPathSafety.bombWarning(for: info))
    }
}

final class StreamingParserTests: XCTestCase {
    private let sample = """
    7-Zip (z) 24.09 (arm64) : Copyright (c) 1999-2024 Igor Pavlov

    Listing archive: demo.zip

    --
    Path = demo.zip
    Type = zip
    Physical Size = 1234

    ----------
    Path = folder
    Folder = +
    Size = 0
    Packed Size = 0
    Attributes = D drwxr-xr-x

    Path = folder/file = with equals.txt
    Folder = -
    Size = 42
    Packed Size = 40
    Modified = 2024-05-01 10:11:12.1234567
    CRC = DEADBEEF
    Method = Deflate
    Encrypted = -
    Attributes = A -rw-r--r--

    """

    private func feedAll(_ text: String, chunkSize: Int) -> [ArchiveEntry] {
        let parser = StreamingListingParser()
        let data = Data(text.utf8)
        var entries = [ArchiveEntry]()
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            entries += parser.feed(data[offset..<end])
            offset = end
        }
        entries += parser.finish()
        return entries
    }

    func testFeedsOneByteAtATime() {
        let entries = feedAll(sample, chunkSize: 1)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].path, "folder/file = with equals.txt")
        XCTAssertEqual(entries[1].size, 42)
        XCTAssertEqual(entries[1].crc, "DEADBEEF")
    }

    func testFeedsArbitraryChunks() {
        // 13-byte chunks split lines, " = " separators and blocks.
        let entries = feedAll(sample, chunkSize: 13)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].path, "folder/file = with equals.txt")
    }

    func testSplitsMultiByteUTF8NameAcrossChunks() {
        let text = """
        7-Zip (z) 24.09

        Listing archive: uni.zip

        --
        Path = uni.zip
        Type = zip
        Physical Size = 99

        ----------
        Path = tiếng việt.txt
        Folder = -
        Size = 7

        """
        // One byte at a time: every multi-byte UTF-8 character in the
        // Vietnamese name is split across chunks.
        let entries = feedAll(text, chunkSize: 1)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "tiếng việt.txt")
        XCTAssertEqual(entries[0].size, 7)
    }

    func testFinishWithoutTrailingNewline() {
        let text = """
        --
        Path = a.zip
        Type = zip

        ----------
        Path = last.txt
        Folder = -
        Size = 3
        """
        let entries = feedAll(text, chunkSize: 8)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "last.txt")
    }

    func testStreamsOneHundredThousandEntries() {
        var text = "7-Zip (z) 24.09\n\nListing archive: big.zip\n\n--\n"
        text += "Path = big.zip\nType = zip\nPhysical Size = 1\n\n----------\n"
        for i in 0..<100_000 {
            text += "Path = f\(i).txt\nFolder = -\nSize = \(i)\n\n"
        }
        let entries = feedAll(text, chunkSize: 65536)
        XCTAssertEqual(entries.count, 100_000)
        XCTAssertEqual(entries[99_999].path, "f99999.txt")
        XCTAssertEqual(entries[99_999].size, 99_999)
        XCTAssertEqual(entries[0].path, "f0.txt")
    }

    func testParseMatchesStreaming() {
        let streamed = feedAll(sample, chunkSize: 64)
        let parsed = ListingParser.parse(archivePath: "demo.zip", text: sample)
        XCTAssertEqual(streamed.map(\.path), parsed.entries.map(\.path))
        XCTAssertEqual(streamed.map(\.size), parsed.entries.map(\.size))
    }
}

final class DiskSpaceTests: XCTestCase {
    func testRequireThrowsWhenTooSmall() {
        let old = DiskSpace.freeBytesProvider
        defer { DiskSpace.freeBytesProvider = old }
        DiskSpace.freeBytesProvider = { _ in 10 }
        XCTAssertThrowsError(try DiskSpace.require(100, at: URL(fileURLWithPath: "/tmp"))) { error in
            guard case EngineError.insufficientDiskSpace(let needed, let available) = error else {
                XCTFail("expected insufficientDiskSpace, got \(error)")
                return
            }
            XCTAssertEqual(needed, 100)
            XCTAssertEqual(available, 10)
        }
    }

    func testRequirePassesWhenUnknown() throws {
        let old = DiskSpace.freeBytesProvider
        defer { DiskSpace.freeBytesProvider = old }
        DiskSpace.freeBytesProvider = { _ in nil }
        try DiskSpace.require(1_000_000_000_000, at: URL(fileURLWithPath: "/tmp"))
    }

    func testTotalSizeSumsFilesAndFolders() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100).write(to: dir.appendingPathComponent("a.txt"))
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 250).write(to: sub.appendingPathComponent("b.bin"))
        XCTAssertEqual(try DiskSpace.totalSize(of: [dir]), 350)
    }
}

final class QueueTests: XCTestCase {
    /// A fake `7zz` for queue tests. `l` lists one `hello.txt` (5
    /// bytes) — or one 100-byte entry for `*big.zip`. `x` logs the
    /// archive to the order log, optionally ticks a marker file (slow
    /// mode, for pause tests), writes `hello.txt` into `-o<dest>` and
    /// prints `50%` / `100%`. `a` writes the archive file (first
    /// non-flag argument), optionally sleeps (slow) or fails. `t`
    /// prints progress and exits 0. Traps TERM so cancel tests can
    /// prove the process really died.
    private func makeQueueFake(slow: Bool = false, failCreate: Bool = false) throws -> (script: URL, marker: URL, log: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake7zz")
        let marker = dir.appendingPathComponent("marker")
        let log = dir.appendingPathComponent("order.log")
        let text = """
        #!/bin/sh
        MARKER="\(marker.path)"
        LOG="\(log.path)"
        trap 'echo terminated >> "$MARKER"; exit 0' TERM
        cmd="$1"; shift
        if [ "$cmd" = "l" ]; then
          for last in "$@"; do :; done
          case "$last" in
            *big.zip)
              printf '7-Zip (z) 24.09\\n\\nListing archive: big.zip\\n\\n--\\nPath = big.zip\\nType = zip\\nPhysical Size = 10\\n\\n----------\\nPath = big.bin\\nFolder = -\\nSize = 100\\n\\n'
              ;;
            *)
              printf '7-Zip (z) 24.09\\n\\nListing archive: a.zip\\n\\n--\\nPath = a.zip\\nType = zip\\nPhysical Size = 10\\n\\n----------\\nPath = hello.txt\\nFolder = -\\nSize = 5\\n\\n'
              ;;
          esac
          exit 0
        fi
        if [ "$cmd" = "x" ]; then
          dest=""; arch=""
          for a in "$@"; do case "$a" in -o*) dest="${a#-o}";; -*) ;; *) arch="$a";; esac; done
          echo "$arch" >> "$LOG"
          if [ "\(slow ? "1" : "0")" = "1" ]; then
            i=1; while [ $i -le 30 ]; do echo "$i" >> "$MARKER"; sleep 0.1; i=$((i+1)); done
          fi
          mkdir -p "$dest"
          : > "$dest/hello.txt"
          printf ' 50%%\\n'; sleep 0.2; printf '100%%\\n'
          exit 0
        fi
        if [ "$cmd" = "a" ]; then
          arch=""
          for a in "$@"; do case "$a" in -*) ;; *) if [ -z "$arch" ]; then arch="$a"; fi;; esac; done
          echo "$arch" >> "$LOG"
          if [ "\(failCreate ? "1" : "0")" = "1" ]; then echo "fake failure" >&2; exit 2; fi
          if [ "\(slow ? "1" : "0")" = "1" ]; then sleep 3; fi
          mkdir -p "$(dirname "$arch")"
          printf 'fake archive\\n' > "$arch"
          printf ' 50%%\\n'; sleep 0.2; printf '100%%\\n'
          exit 0
        fi
        if [ "$cmd" = "t" ]; then
          printf ' 50%%\\n'; sleep 0.2; printf '100%%\\n'
          exit 0
        fi
        exit 2
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return (script, marker, log, dir)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func lineCount(_ url: URL) -> Int {
        (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0
    }

    private func logLines(_ url: URL) -> [String] {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    // MARK: Ordering and progress

    func testQueueRunsJobsInOrder() throws {
        let fake = try makeQueueFake()
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let queue = JobQueue(engine: engine,
                             storeURL: try tempDir().appendingPathComponent("queue.json"))
        let dest = try tempDir()
        let a = queue.enqueue(JobDescriptor(kind: .extract, archive: "/tmp/a.zip",
                                            destination: dest.path))
        let b = queue.enqueue(JobDescriptor(kind: .extract, archive: "/tmp/b.zip",
                                            destination: dest.path))
        queue.runAll()
        XCTAssertEqual(queue.record(for: a.id)?.status, .done)
        XCTAssertEqual(queue.record(for: b.id)?.status, .done)
        XCTAssertEqual(logLines(fake.log), ["/tmp/a.zip", "/tmp/b.zip"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("hello.txt").path))
    }

    func testExtractReportsProgressFractions() throws {
        let fake = try makeQueueFake()
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        var fractions: [Double] = []
        try engine.extract(archive: URL(fileURLWithPath: "/tmp/a.zip"),
                           to: try tempDir(),
                           onProgress: { fractions.append($0.fraction ?? -1) })
        XCTAssertEqual(fractions, [0.5, 1.0])
    }

    func testCancelOfQueuedJobSkipsIt() throws {
        let fake = try makeQueueFake()
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let queue = JobQueue(engine: engine,
                             storeURL: try tempDir().appendingPathComponent("queue.json"))
        let dest = try tempDir()
        let job = queue.enqueue(JobDescriptor(kind: .extract, archive: "/tmp/a.zip",
                                              destination: dest.path))
        XCTAssertTrue(queue.cancel(id: job.id))
        XCTAssertEqual(queue.record(for: job.id)?.status, .cancelled)
        queue.runAll()
        XCTAssertEqual(logLines(fake.log), [])
        XCTAssertEqual(queue.record(for: job.id)?.status, .cancelled)
    }

    // MARK: Pause / resume (SIGSTOP / SIGCONT)

    func testPauseFreezesAndResumeCompletesExtract() throws {
        let fake = try makeQueueFake(slow: true)
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let control = JobControl()
        let dest = try tempDir()
        var extractError: Error?
        DispatchQueue.global().async {
            do {
                try engine.extract(archive: URL(fileURLWithPath: "/tmp/a.zip"),
                                   to: dest, control: control)
            } catch {
                extractError = error
            }
        }
        XCTAssertTrue(waitUntil(timeout: 5) { self.lineCount(fake.marker) >= 3 },
                      "fake 7zz never started ticking")
        control.pause()
        XCTAssertTrue(control.isPaused)
        let frozen = lineCount(fake.marker)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(lineCount(fake.marker), frozen,
                       "marker kept ticking while paused — SIGSTOP did not stop the process")
        control.resume()
        XCTAssertFalse(control.isPaused)
        XCTAssertTrue(waitUntil(timeout: 10) {
            FileManager.default.fileExists(atPath: dest.appendingPathComponent("hello.txt").path)
        }, "extract did not complete after resume: \(String(describing: extractError))")
        XCTAssertNil(extractError)
    }

    func testJobControlFlags() {
        let control = JobControl()
        XCTAssertFalse(control.isCancelled)
        XCTAssertFalse(control.isPaused)
        control.pause()
        XCTAssertTrue(control.isPaused)
        control.resume()
        XCTAssertFalse(control.isPaused)
        control.cancel()
        XCTAssertTrue(control.isCancelled)
    }

    // MARK: Safe creation (PERF-05)

    func testCreateAppearsAtomicallyOnSuccess() throws {
        let fake = try makeQueueFake()
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let queue = JobQueue(engine: engine,
                             storeURL: try tempDir().appendingPathComponent("queue.json"))
        let dir = try tempDir()
        let src = dir.appendingPathComponent("src.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("out.zip")
        let job = queue.enqueue(JobDescriptor(kind: .create, archive: archive.path,
                                              sources: [src.path], format: "zip"))
        queue.runAll()
        XCTAssertEqual(queue.record(for: job.id)?.status, .done)
        XCTAssertEqual(try String(contentsOf: archive, encoding: .utf8), "fake archive\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".seekzip-tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "staging directory left behind: \(leftovers)")
    }

    func testCancelCreateLeavesNoHalfWrittenFile() throws {
        let fake = try makeQueueFake(slow: true)
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let queue = JobQueue(engine: engine,
                             storeURL: try tempDir().appendingPathComponent("queue.json"))
        let dir = try tempDir()
        let src = dir.appendingPathComponent("src.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("out.zip")
        let job = queue.enqueue(JobDescriptor(kind: .create, archive: archive.path,
                                              sources: [src.path], format: "zip"))
        DispatchQueue.global().async { queue.runAll() }
        XCTAssertTrue(waitUntil(timeout: 5) {
            queue.record(for: job.id)?.status == .running
        }, "job never started running")
        Thread.sleep(forTimeInterval: 0.5) // let 7zz get well into its sleep
        XCTAssertTrue(queue.cancel(id: job.id))
        XCTAssertTrue(waitUntil(timeout: 5) {
            queue.record(for: job.id)?.status == .cancelled
        }, "job did not end cancelled, status is \(String(describing: queue.record(for: job.id)?.status))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path),
                       "half-written archive left at the final path")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".seekzip-tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "staging directory left behind: \(leftovers)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.marker.path),
                      "fake 7zz was not terminated (no TERM trap marker)")
    }

    func testFailedCreateLeavesNoFile() throws {
        let fake = try makeQueueFake(failCreate: true)
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let queue = JobQueue(engine: engine,
                             storeURL: try tempDir().appendingPathComponent("queue.json"))
        let dir = try tempDir()
        let src = dir.appendingPathComponent("src.txt")
        try "hello".write(to: src, atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("out.zip")
        let job = queue.enqueue(JobDescriptor(kind: .create, archive: archive.path,
                                              sources: [src.path], format: "zip"))
        queue.runAll()
        XCTAssertEqual(queue.record(for: job.id)?.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".seekzip-tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: Free-space precheck (SEC-04)

    func testExtractPrecheckFailsFastWhenDiskFull() throws {
        let old = DiskSpace.freeBytesProvider
        defer { DiskSpace.freeBytesProvider = old }
        DiskSpace.freeBytesProvider = { _ in 10 } // 10 bytes free
        let fake = try makeQueueFake()
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        XCTAssertThrowsError(
            try engine.extract(archive: URL(fileURLWithPath: "/tmp/big.zip"),
                               to: try tempDir())
        ) { error in
            guard case EngineError.insufficientDiskSpace(let needed, let available) = error else {
                XCTFail("expected insufficientDiskSpace, got \(error)")
                return
            }
            XCTAssertEqual(needed, 100)
            XCTAssertEqual(available, 10)
        }
        // The precheck runs before 7zz starts: nothing was extracted.
        XCTAssertEqual(logLines(fake.log), [])
    }

    // MARK: Persistence across relaunch (PERF-06)

    func testQueueSurvivesRelaunch() throws {
        let fake = try makeQueueFake()
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let store = try tempDir().appendingPathComponent("queue.json")
        let dest = try tempDir()
        let queueA = JobQueue(engine: engine, storeURL: store)
        let extractJob = queueA.enqueue(JobDescriptor(kind: .extract, archive: "/tmp/a.zip",
                                                      destination: dest.path))
        let testJob = queueA.enqueue(JobDescriptor(kind: .test, archive: "/tmp/a.zip"))
        XCTAssertTrue(queueA.pause(id: testJob.id)) // queued -> paused
        queueA.runAll() // extract runs; the paused test job is skipped
        XCTAssertEqual(queueA.record(for: extractJob.id)?.status, .done)
        XCTAssertEqual(queueA.record(for: testJob.id)?.status, .paused)

        // A fresh queue from the same store file (simulated relaunch).
        let queueB = JobQueue(engine: engine, storeURL: store)
        XCTAssertEqual(queueB.record(for: extractJob.id)?.status, .done)
        XCTAssertEqual(queueB.record(for: testJob.id)?.status, .paused)
        XCTAssertTrue(queueB.resume(id: testJob.id))
        queueB.runAll()
        XCTAssertEqual(queueB.record(for: testJob.id)?.status, .done)
    }

    func testRunningJobBecomesInterruptedOnRelaunch() throws {
        let fake = try makeQueueFake(slow: true)
        let engine = try SevenZipEngine(binaryPath: fake.script.path)
        let store = try tempDir().appendingPathComponent("queue.json")
        let dest = try tempDir()
        let queueA = JobQueue(engine: engine, storeURL: store)
        let job = queueA.enqueue(JobDescriptor(kind: .extract, archive: "/tmp/a.zip",
                                               destination: dest.path))
        DispatchQueue.global().async { queueA.runAll() }
        XCTAssertTrue(waitUntil(timeout: 5) {
            queueA.record(for: job.id)?.status == .running
        }, "job never started running")
        // The app "dies" here: a fresh queue reads the store while the
        // first one is still mid-job.
        let queueB = JobQueue(engine: engine, storeURL: store)
        XCTAssertEqual(queueB.record(for: job.id)?.status, .interrupted,
                       "a job that was running at relaunch must not silently restart")
        XCTAssertTrue(queueB.resume(id: job.id))
        XCTAssertEqual(queueB.record(for: job.id)?.status, .queued)
        XCTAssertTrue(queueA.cancel(id: job.id)) // stop the first runner's job
        XCTAssertTrue(waitUntil(timeout: 5) {
            queueA.record(for: job.id)?.status == .cancelled
        })
        queueB.runAll()
        XCTAssertEqual(queueB.record(for: job.id)?.status, .done)
    }
}

final class StreamingEngineTests: XCTestCase {
    /// Writes a fake `7zz` — a shell script that prints a `-slt` listing
    /// slowly, one entry at a time — and returns its URL. The script
    /// ignores its arguments and traps TERM so the test can prove the
    /// engine really terminated it.
    private func makeScriptedBinary(entryCount: Int, delay: String,
                                    marker: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake7zz")
        let text = """
        #!/bin/sh
        trap 'echo terminated > "\(marker.path)"; exit 0' TERM
        printf '7-Zip (z) 24.09\\n\\nListing archive: scripted.zip\\n\\n--\\nPath = scripted.zip\\nType = zip\\nPhysical Size = 1234\\n\\n----------\\n'
        i=1
        while [ $i -le \(entryCount) ]; do
          printf 'Path = file%05d.txt\\nFolder = -\\nSize = %d\\n\\n' "$i" "$i"
          sleep \(delay)
          i=$((i+1))
        done
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    private func tempMarker() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terminated")
    }

    func testListStreamingCollectsAll() throws {
        let marker = try tempMarker()
        let script = try makeScriptedBinary(entryCount: 50, delay: "0", marker: marker)
        let engine = try SevenZipEngine(binaryPath: script.path)
        var seenProgress: [ListingProgress] = []
        let info = try engine.listStreaming(
            archive: URL(fileURLWithPath: "/tmp/scripted.zip"),
            onProgress: { seenProgress.append($0) }) { _ in true }
        XCTAssertEqual(info.entries.count, 50)
        XCTAssertEqual(info.entries[49].path, "file00050.txt")
        XCTAssertEqual(info.entries[49].size, 50)
        XCTAssertFalse(seenProgress.isEmpty)
        XCTAssertEqual(seenProgress.last?.entriesSeen, 50)
        XCTAssertGreaterThan(seenProgress.last?.bytesRead ?? 0, 0)
    }

    func testCancelTerminatesProcess() throws {
        let marker = try tempMarker()
        // Uninterrupted this script takes ~10 s (200 entries x 0.05 s).
        let script = try makeScriptedBinary(entryCount: 200, delay: "0.05", marker: marker)
        let engine = try SevenZipEngine(binaryPath: script.path)
        let started = Date()
        var received = 0
        XCTAssertThrowsError(
            try engine.listStreaming(
                archive: URL(fileURLWithPath: "/tmp/scripted.zip")) { _ in
                    received += 1
                    return received < 3 // cancel after the 3rd entry
                }
        ) { error in
            guard case EngineError.cancelled = error else {
                XCTFail("expected EngineError.cancelled, got \(error)")
                return
            }
        }
        XCTAssertEqual(received, 3)
        // Cancellation must stop promptly, not after the full listing.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
        // The process really received SIGTERM (trap ran), not just a
        // closed pipe: no zombie producer left behind.
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

// MARK: - M5: checksums (COR-02)

final class ChecksumTests: XCTestCase {

    func testCRC32KnownVectors() {
        XCTAssertEqual(CRC32.hex(of: Data("123456789".utf8)), "CBF43926")
        XCTAssertEqual(CRC32.hex(of: Data()), "00000000")
        XCTAssertEqual(CRC32.hex(of: Data("abc".utf8)), "352441C2")
        XCTAssertEqual(CRC32.checksum(of: Data("123456789".utf8)), 0xCBF43926)
    }

    func testCRC32AccumulatorMatchesOneShotAcrossChunks() {
        let bytes = Data("hello world, this is a chunked checksum test".utf8)
        var acc = CRC32.Accumulator()
        for start in stride(from: 0, to: bytes.count, by: 3) {
            acc.update(bytes[start..<min(start + 3, bytes.count)])
        }
        XCTAssertEqual(acc.hex(), CRC32.hex(of: bytes))
        XCTAssertEqual(acc.finalize(), CRC32.checksum(of: bytes))
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testSHA256AccumulatorMatchesOneShotAcrossChunks() {
        let bytes = Data("the quick brown fox jumps over the lazy dog, twice over".utf8)
        var acc = SHA256.Accumulator()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 7, bytes.count)
            acc.update(bytes[offset..<end])
            offset = end
        }
        XCTAssertEqual(acc.finalizeHex(), SHA256.hex(of: bytes))
    }
}

// MARK: - M5: password storage (ENC-05)

final class PasswordStoreTests: XCTestCase {

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryPasswordStore()
        XCTAssertNil(store.password(for: "/tmp/a.zip"))
        try store.save(password: "hunter2", for: "/tmp/a.zip")
        XCTAssertEqual(store.password(for: "/tmp/a.zip"), "hunter2")
        XCTAssertNil(store.password(for: "/tmp/other.zip"))
        try store.save(password: "second", for: "/tmp/a.zip")
        XCTAssertEqual(store.password(for: "/tmp/a.zip"), "second")
    }

    func testInMemoryStoreForgetRemovesPassword() throws {
        let store = InMemoryPasswordStore()
        try store.save(password: "hunter2", for: "/tmp/a.zip")
        try store.forget(archivePath: "/tmp/a.zip")
        XCTAssertNil(store.password(for: "/tmp/a.zip"))
        // Forgetting an unknown archive is not an error.
        try store.forget(archivePath: "/tmp/a.zip")
    }

    func testExplicitPasswordWinsOverStored() throws {
        let store = InMemoryPasswordStore()
        try store.save(password: "stored-pw", for: "/tmp/a.zip")
        let engine = try SevenZipEngine(binaryPath: "/bin/true")
        engine.passwordStore = store
        XCTAssertEqual(engine.resolvePassword(for: URL(fileURLWithPath: "/tmp/a.zip"),
                                              explicit: "explicit-pw"),
                       "explicit-pw")
        XCTAssertEqual(engine.resolvePassword(for: URL(fileURLWithPath: "/tmp/a.zip"),
                                              explicit: nil),
                       "stored-pw")
        XCTAssertNil(engine.resolvePassword(for: URL(fileURLWithPath: "/tmp/b.zip"),
                                            explicit: nil))
    }

    #if canImport(Security)
    // Keychain on real macOS (needs the Security framework and a
    // keychain that accepts writes — not available on Linux CI).
    func testKeychainStoreRoundTrip() throws {
        let store = KeychainPasswordStore()
        let path = "/tmp/seekzip-keychain-test-\(UUID().uuidString).zip"
        try store.save(password: "keychain-pw", for: path)
        XCTAssertEqual(store.password(for: path), "keychain-pw")
        try store.forget(archivePath: path)
        XCTAssertNil(store.password(for: path))
    }
    #else
    // Linux has no Keychain (Security framework is macOS-only), so
    // the shared store is the clearly-marked in-memory fallback —
    // process lifetime only, never persisted. The Keychain test
    // above runs on macOS CI instead.
    func testSharedStoreIsInMemoryFallbackOnLinux() throws {
        let path = "/tmp/seekzip-linux-store-\(UUID().uuidString).zip"
        try PasswordStore.shared.save(password: "fallback-pw", for: path)
        XCTAssertEqual(PasswordStore.shared.password(for: path), "fallback-pw")
        try PasswordStore.shared.forget(archivePath: path)
        XCTAssertNil(PasswordStore.shared.password(for: path))
    }
    #endif
}

// MARK: - M5: edit, convert, verify (EDT-01..07, COR-01..02)

final class EditTests: XCTestCase {

    private struct StatefulFake {
        let script: URL
        let stateDir: URL
        let log: URL
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// A stateful fake 7zz: a small Python script that keeps one
    /// entry table per archive basename (JSON in `stateDir`), so add /
    /// remove / rename / create / extract / stream all see the same
    /// archive state. The engine's temp copies
    /// (`.<name>.seekzip-tmp-<uuid>`) and create staging dirs map
    /// back to the same basename key, exactly like a real archive
    /// file would. Every invocation's argv is appended to `log`
    /// (one JSON array per line). Entries can be seeded from Swift;
    /// writing `corrupt.json` in the state dir makes `e -so` stream
    /// wrong bytes for those entries (verify test). With
    /// `failAdd`, `a` exits 3 before touching anything.
    private func makeStatefulFake(failAdd: Bool = false) throws -> StatefulFake {
        let dir = try tempDir()
        let stateDir = dir.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir,
                                                withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake7zz")
        let log = dir.appendingPathComponent("argv.log")
        let text = """
        #!/usr/bin/env python3
        import sys, os, json, base64, zlib

        STATE_DIR = "\(stateDir.path)"
        LOG = "\(log.path)"
        FAIL_ADD = \(failAdd ? "True" : "False")
        NL = chr(10)

        def log_args():
            with open(LOG, "a") as f:
                f.write(json.dumps(sys.argv[1:]) + NL)

        def key(archive):
            base = os.path.basename(archive)
            if base.startswith("."):
                base = base[1:]
            if ".seekzip-tmp-" in base:
                base = base.split(".seekzip-tmp-")[0]
            return base

        def state_path(archive):
            return os.path.join(STATE_DIR, key(archive) + ".json")

        def load(archive):
            p = state_path(archive)
            if os.path.exists(p):
                with open(p) as f:
                    return json.load(f)
            return {"entries": []}

        def save(archive, st):
            with open(state_path(archive), "w") as f:
                json.dump(st, f)

        def crc_hex(data):
            return "%08X" % (zlib.crc32(data) & 0xFFFFFFFF)

        def listing(archive):
            st = load(archive)
            out = []
            out.append("7-Zip (z) 24.09")
            out.append("")
            out.append("Listing archive: " + archive)
            out.append("")
            out.append("--")
            out.append("Path = " + archive)
            out.append("Type = zip")
            out.append("Physical Size = 1234")
            out.append("")
            out.append("----------")
            out.append("")
            for e in st["entries"]:
                content = base64.b64decode(e["content"])
                out.append("Path = " + e["path"])
                out.append("Folder = " + ("+" if e.get("dir") else "-"))
                out.append("Size = %d" % len(content))
                out.append("CRC = " + crc_hex(content))
                out.append("")
            sys.stdout.write(NL.join(out))

        def non_flags(args):
            return [a for a in args if not a.startswith("-")]

        def add_entries(archive, names):
            if FAIL_ADD:
                sys.stderr.write("simulated add failure" + NL)
                sys.exit(3)
            st = load(archive)
            by_path = {}
            for e in st["entries"]:
                by_path[e["path"]] = e
            for name in names:
                p = name if os.path.isabs(name) else os.path.join(os.getcwd(), name)
                if os.path.isdir(p):
                    for root, dirs, files in os.walk(p):
                        for fn in files:
                            fp = os.path.join(root, fn)
                            rel = os.path.relpath(fp, p)
                            en = (name + "/" + rel) if not os.path.isabs(name) else (os.path.basename(p) + "/" + rel)
                            with open(fp, "rb") as f:
                                data = f.read()
                            by_path[en] = {"path": en, "content": base64.b64encode(data).decode()}
                elif os.path.isfile(p):
                    en = name if not os.path.isabs(name) else os.path.basename(p)
                    with open(p, "rb") as f:
                        data = f.read()
                    by_path[en] = {"path": en, "content": base64.b64encode(data).decode()}
            st["entries"] = list(by_path.values())
            save(archive, st)
            with open(archive, "wb") as f:
                f.write(b"fake archive" + NL.encode())

        def remove_entries(archive, names):
            st = load(archive)
            st["entries"] = [e for e in st["entries"] if e["path"] not in names]
            save(archive, st)

        def rename_entries(archive, pairs):
            st = load(archive)
            mapping = {}
            i = 0
            while i + 1 < len(pairs):
                mapping[pairs[i]] = pairs[i + 1]
                i += 2
            for e in st["entries"]:
                if e["path"] in mapping:
                    e["path"] = mapping[e["path"]]
            save(archive, st)

        def corrupt_set():
            p = os.path.join(STATE_DIR, "corrupt.json")
            if os.path.exists(p):
                with open(p) as f:
                    return set(json.load(f).get("entries", []))
            return set()

        def stream_entry(archive, entry):
            st = load(archive)
            for e in st["entries"]:
                if e["path"] == entry:
                    if entry in corrupt_set():
                        sys.stdout.buffer.write(b"corrupted bytes, not the real content")
                    else:
                        sys.stdout.buffer.write(base64.b64decode(e["content"]))
                    return
            sys.stderr.write("ERROR: No such entry" + NL)
            sys.exit(2)

        def extract(archive, dest, names):
            st = load(archive)
            wanted = set(names) if names else None
            for e in st["entries"]:
                if wanted is not None and e["path"] not in wanted:
                    continue
                target = os.path.join(dest, e["path"])
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as f:
                    f.write(base64.b64decode(e["content"]))

        def main():
            log_args()
            args = sys.argv[1:]
            if not args:
                sys.exit(2)
            cmd = args[0]
            if cmd == "l":
                listing(non_flags(args[1:])[0])
            elif cmd == "t":
                pass
            elif cmd == "a":
                rest = non_flags(args[1:])
                add_entries(rest[0], rest[1:])
            elif cmd == "d":
                rest = non_flags(args[1:])
                remove_entries(rest[0], rest[1:])
            elif cmd == "rn":
                rest = non_flags(args[1:])
                rename_entries(rest[0], rest[1:])
            elif cmd == "e":
                rest = non_flags(args[1:])
                stream_entry(rest[0], rest[1])
            elif cmd == "x":
                dest = ""
                rest = []
                for a in args[1:]:
                    if a.startswith("-o"):
                        dest = a[2:]
                    elif a.startswith("-"):
                        continue
                    else:
                        rest.append(a)
                extract(rest[0], dest, rest[1:])
            else:
                sys.exit(2)

        main()
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return StatefulFake(script: script, stateDir: stateDir, log: log)
    }

    /// Seeds the fake's entry table for `url` (keyed by basename)
    /// and creates the archive file itself, so the engine can copy
    /// it for the temp-copy edit path.
    private func seedArchive(_ fake: StatefulFake, at url: URL,
                             entries: [(path: String, content: String)]) throws {
        let state: [String: [[String: String]]] = ["entries": entries.map {
            ["path": $0.path,
             "content": Data($0.content.utf8).base64EncodedString()]
        }]
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: fake.stateDir
            .appendingPathComponent(url.lastPathComponent + ".json"))
        try "seed archive".write(to: url, atomically: true, encoding: .utf8)
    }

    private func engine(for fake: StatefulFake) throws -> SevenZipEngine {
        try SevenZipEngine(binaryPath: fake.script.path)
    }

    private func argvLog(_ fake: StatefulFake) -> [[String]] {
        let text = (try? String(contentsOf: fake.log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return nil }
            return arr
        }
    }

    private func entryPaths(_ engine: SevenZipEngine, _ archive: URL) throws -> [String] {
        try engine.list(archive: archive).entries.map(\.path)
    }

    // MARK: Add / remove / rename (EDT-01..04)

    func testAddEntriesToZip() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive, entries: [("hello.txt", "hello")])
        let src = dir.appendingPathComponent("new.txt")
        try "brand new".write(to: src, atomically: true, encoding: .utf8)
        try engine.addEntries(archive: archive, sources: [src])
        let info = try engine.list(archive: archive)
        XCTAssertEqual(info.entries.map(\.path).sorted(), ["hello.txt", "new.txt"])
        XCTAssertEqual(info.entries.first(where: { $0.path == "new.txt" })?.crc,
                       CRC32.hex(of: Data("brand new".utf8)))
        XCTAssertTrue(argvLog(fake).contains { $0.first == "a" && $0.contains("-tzip") })
    }

    func testAddEntriesWithPrefix() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive, entries: [])
        let src = dir.appendingPathComponent("note.txt")
        try "noted".write(to: src, atomically: true, encoding: .utf8)
        try engine.addEntries(archive: archive, sources: [src], prefix: "docs")
        XCTAssertEqual(try entryPaths(engine, archive), ["docs/note.txt"])
    }

    func testAddEntriesRejectsUnsafePrefix() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive, entries: [])
        let src = dir.appendingPathComponent("note.txt")
        try "noted".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try engine.addEntries(archive: archive, sources: [src],
                                  prefix: "../escape"))
        XCTAssertEqual(try entryPaths(engine, archive), [])
    }

    func testRemoveEntries() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive,
                        entries: [("a.txt", "aaa"), ("b.txt", "bbb"),
                                  ("c.txt", "ccc")])
        try engine.removeEntries(archive: archive, entries: ["b.txt"])
        XCTAssertEqual(try entryPaths(engine, archive), ["a.txt", "c.txt"])
        XCTAssertThrowsError(
            try engine.removeEntries(archive: archive, entries: ["nope.txt"])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("entry not found"))
        }
        // The failed remove left the archive alone.
        XCTAssertEqual(try entryPaths(engine, archive), ["a.txt", "c.txt"])
    }

    func testRenameEntriesZipAnd7z() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let zip = dir.appendingPathComponent("x.zip")
        try seedArchive(fake, at: zip, entries: [("old.txt", "old content")])
        try engine.renameEntries(archive: zip,
                                 renames: [(old: "old.txt", new: "new.txt")])
        XCTAssertEqual(try entryPaths(engine, zip), ["new.txt"])
        let sevenZ = dir.appendingPathComponent("y.7z")
        try seedArchive(fake, at: sevenZ, entries: [("old.txt", "old content")])
        try engine.renameEntries(archive: sevenZ,
                                 renames: [(old: "old.txt", new: "renamed.txt")])
        XCTAssertEqual(try entryPaths(engine, sevenZ), ["renamed.txt"])
    }

    func testRenameToExistingNameFails() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive,
                        entries: [("a.txt", "aaa"), ("b.txt", "bbb")])
        XCTAssertThrowsError(
            try engine.renameEntries(archive: archive,
                                     renames: [(old: "a.txt", new: "b.txt")])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("already exists"))
        }
        XCTAssertEqual(try entryPaths(engine, archive), ["a.txt", "b.txt"])
    }

    func testRenameTarFailsClearly() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.tar")
        try seedArchive(fake, at: archive, entries: [("old.txt", "old")])
        XCTAssertThrowsError(
            try engine.renameEntries(archive: archive,
                                     renames: [(old: "old.txt", new: "new.txt")])
        ) { error in
            XCTAssertTrue(String(describing: error)
                .contains("only supported for ZIP and 7z"))
        }
        XCTAssertEqual(try entryPaths(engine, archive), ["old.txt"])
    }

    func testAddToRarFailsClearly() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.rar")
        try seedArchive(fake, at: archive, entries: [("a.txt", "aaa")])
        let src = dir.appendingPathComponent("new.txt")
        try "new".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try engine.addEntries(archive: archive, sources: [src])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("only ZIP, 7z and TAR"))
        }
        XCTAssertEqual(try entryPaths(engine, archive), ["a.txt"])
    }

    // MARK: Temp-name safety on failed edit (PERF-05 / EDT-05)

    func testFailedAddLeavesOriginalUntouched() throws {
        let fake = try makeStatefulFake(failAdd: true)
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive, entries: [("hello.txt", "hello")])
        let before = try Data(contentsOf: archive)
        let src = dir.appendingPathComponent("new.txt")
        try "brand new".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try engine.addEntries(archive: archive, sources: [src]))
        // Byte-for-byte the same file, same listing, no temp leftovers.
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertEqual(try entryPaths(engine, archive), ["hello.txt"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("seekzip-tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "temp left behind: \(leftovers)")
    }

    // MARK: Conversion (EDT-06)

    func testConvertZipTo7zAndBack() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let src = dir.appendingPathComponent("src.zip")
        try seedArchive(fake, at: src,
                        entries: [("a.txt", "hello zip"), ("b.txt", "second file")])
        let before = try engine.list(archive: src)
        let sevenZ = dir.appendingPathComponent("out.7z")
        try engine.convert(archive: src, to: sevenZ)
        let converted = try engine.list(archive: sevenZ)
        XCTAssertEqual(converted.entries.map(\.path).sorted(), ["a.txt", "b.txt"])
        for entry in before.entries {
            XCTAssertEqual(converted.entries.first(where: { $0.path == entry.path })?.crc,
                           entry.crc, "CRC changed for \(entry.path) in conversion")
        }
        let roundTrip = dir.appendingPathComponent("roundtrip.zip")
        try engine.convert(archive: sevenZ, to: roundTrip)
        let back = try engine.list(archive: roundTrip)
        XCTAssertEqual(back.entries.map(\.path).sorted(), ["a.txt", "b.txt"])
        for entry in before.entries {
            XCTAssertEqual(back.entries.first(where: { $0.path == entry.path })?.crc,
                           entry.crc, "CRC changed for \(entry.path) on the way back")
        }
        // The source archive was never modified.
        XCTAssertEqual(try entryPaths(engine, src), ["a.txt", "b.txt"])
    }

    func testConvertToRarFailsClearly() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let src = dir.appendingPathComponent("src.zip")
        try seedArchive(fake, at: src, entries: [("a.txt", "aaa")])
        let dest = dir.appendingPathComponent("out.rar")
        XCTAssertThrowsError(try engine.convert(archive: src, to: dest)) { error in
            XCTAssertTrue(String(describing: error).contains("RAR cannot be created"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: Checksums and verify (COR-01..02, EDT-07)

    func testEntryChecksumsFromListing() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive,
                        entries: [("a.txt", "aaa"), ("b.txt", "bbb")])
        let checksums = try engine.entryChecksums(archive: archive)
        XCTAssertEqual(checksums.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(checksums[0].crc, CRC32.hex(of: Data("aaa".utf8)))
        XCTAssertEqual(checksums[1].crc, CRC32.hex(of: Data("bbb".utf8)))
        XCTAssertEqual(checksums[0].size, 3)
    }

    func testVerifyAllOkWithSHA256() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive,
                        entries: [("a.txt", "aaa"), ("b.txt", "bbb")])
        let results = try engine.verify(archive: archive, includeSHA256: true)
        XCTAssertEqual(results.map(\.entryPath), ["a.txt", "b.txt"])
        XCTAssertTrue(results.allSatisfy { $0.status == .ok })
        XCTAssertEqual(results[0].sha256, SHA256.hex(of: Data("aaa".utf8)))
        XCTAssertEqual(results[0].expectedCRC, CRC32.hex(of: Data("aaa".utf8)))
        XCTAssertEqual(results[0].actualCRC, CRC32.hex(of: Data("aaa".utf8)))
    }

    func testVerifyDetectsCorruptedEntry() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive,
                        entries: [("good.txt", "good content"),
                                  ("bad.txt", "real content")])
        // The fake streams wrong bytes for bad.txt, but the listing
        // still reports the CRC of the real content — exactly what a
        // corrupted entry looks like to `verify`.
        let corrupt: [String: [String]] = ["entries": ["bad.txt"]]
        let corruptData = try JSONSerialization.data(withJSONObject: corrupt)
        try corruptData.write(to: fake.stateDir.appendingPathComponent("corrupt.json"))
        let results = try engine.verify(archive: archive)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first(where: { $0.entryPath == "good.txt" })?.status, .ok)
        let bad = results.first(where: { $0.entryPath == "bad.txt" })
        XCTAssertEqual(bad?.status, .mismatch)
        XCTAssertEqual(bad?.expectedCRC, CRC32.hex(of: Data("real content".utf8)))
        XCTAssertEqual(bad?.actualCRC,
                       CRC32.hex(of: Data("corrupted bytes, not the real content".utf8)))
    }

    // MARK: Password reaches 7zz (ENC-05)

    func testStoredPasswordIsPassedTo7zz() throws {
        let fake = try makeStatefulFake()
        let engine = try engine(for: fake)
        let store = InMemoryPasswordStore()
        engine.passwordStore = store
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try seedArchive(fake, at: archive, entries: [("a.txt", "aaa")])
        try store.save(password: "stored-pw", for: archive.path)
        _ = try engine.list(archive: archive)
        let listCall = argvLog(fake).first { $0.first == "l" }
        XCTAssertTrue(listCall?.contains("-pstored-pw") ?? false,
                      "stored password was not passed to 7zz: \(String(describing: listCall))")
        // An explicit password wins over the stored one.
        _ = try engine.list(archive: archive, password: "explicit-pw")
        let listCalls = argvLog(fake).filter { $0.first == "l" }
        XCTAssertTrue(listCalls.last?.contains("-pexplicit-pw") ?? false)
        XCTAssertFalse(listCalls.last?.contains("-pstored-pw") ?? true)
    }
}

// MARK: - M6: XAD fallback engine

final class XADEngineTests: XCTestCase {

    private struct FakeXAD {
        let dir: URL
        let lsar: URL
        let unar: URL
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// A fake `lsar` that prints the canned `lsar -j` document from
    /// `lsar.json` next to it (and logs argv), and a fake `unar` that
    /// creates the files listed in `unar-manifest.txt` (`path|content`
    /// per line) under its `-o` directory. Touching `lsar-fail` /
    /// `unar-fail` in the dir makes that tool fail (`unar-fail` writes
    /// one partial file first, so cleanup can be proven).
    private func makeFakeXAD(listing: String, manifest: String,
                             failLsar: Bool = false,
                             failUnar: Bool = false) throws -> FakeXAD {
        let dir = try tempDir()
        let lsar = dir.appendingPathComponent("lsar")
        let unar = dir.appendingPathComponent("unar")
        let lsarScript = """
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$@" >> "$dir/lsar-argv.log"
        if [ -f "$dir/lsar-fail" ]; then echo "lsar: cannot open archive" >&2; exit 2; fi
        cat "$dir/lsar.json"
        """
        let unarScript = """
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$@" >> "$dir/unar-argv.log"
        out=""
        for a in "$@"; do case "$a" in -o*) out="${a#-o}";; esac; done
        if [ -f "$dir/unar-fail" ]; then
          mkdir -p "$out"
          printf 'partial' > "$out/partial.txt"
          echo "unar: extraction failed" >&2
          exit 1
        fi
        while IFS='|' read -r path content; do
          [ -z "$path" ] && continue
          mkdir -p "$out/$(dirname "$path")"
          printf '%s' "$content" > "$out/$path"
        done < "$dir/unar-manifest.txt"
        """
        try lsarScript.write(to: lsar, atomically: true, encoding: .utf8)
        try unarScript.write(to: unar, atomically: true, encoding: .utf8)
        for script in [lsar, unar] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        }
        try listing.write(to: dir.appendingPathComponent("lsar.json"),
                          atomically: true, encoding: .utf8)
        try manifest.write(to: dir.appendingPathComponent("unar-manifest.txt"),
                           atomically: true, encoding: .utf8)
        if failLsar {
            try "".write(to: dir.appendingPathComponent("lsar-fail"),
                         atomically: true, encoding: .utf8)
        }
        if failUnar {
            try "".write(to: dir.appendingPathComponent("unar-fail"),
                         atomically: true, encoding: .utf8)
        }
        return FakeXAD(dir: dir, lsar: lsar, unar: unar)
    }

    private func lsarEntry(_ path: String, size: Int = 5,
                           dir: Bool = false, encrypted: Bool = false,
                           method: String? = nil,
                           encoding: String? = nil) -> [String: Any] {
        var e: [String: Any] = [
            "XADFileName": path,
            "XADFileSize": size,
            "XADCompressedSize": size,
            "XADIsDirectory": dir,
            "XADIsEncrypted": encrypted,
        ]
        if let method { e["XADCompressionName"] = method }
        if let encoding { e["XADFileNameEncoding"] = encoding }
        return e
    }

    private func lsarJSON(format: String = "StuffIt",
                          entries: [[String: Any]]) throws -> String {
        let doc: [String: Any] = ["lsarFormatName": format,
                                  "lsarContents": entries]
        let data = try JSONSerialization.data(withJSONObject: doc)
        return String(decoding: data, as: UTF8.self)
    }

    private func engine(for fake: FakeXAD) -> XADMasterEngine {
        XADMasterEngine(lsarPath: fake.lsar.path, unarPath: fake.unar.path)
    }

    private func dummyArchive(in dir: URL, name: String = "old.sit") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "dummy archive bytes".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testXadListsFromLsarJSON() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [
                lsarEntry("hello.txt", size: 11, method: "StuffIt"),
                lsarEntry("docs", dir: true),
                lsarEntry("secret.txt", size: 6, encrypted: true),
            ]),
            manifest: "")
        let archive = try dummyArchive(in: dir)
        let info = try engine(for: fake).list(archive: archive)
        XCTAssertEqual(info.format, "stuffit")
        XCTAssertEqual(info.entries.map(\.path),
                       ["hello.txt", "docs", "secret.txt"])
        XCTAssertEqual(info.entries[0].size, 11)
        XCTAssertEqual(info.entries[0].method, "StuffIt")
        XCTAssertTrue(info.entries[1].isDirectory)
        XCTAssertTrue(info.entries[2].isEncrypted)
    }

    func testXadPreservesFilenameEncoding() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [
                lsarEntry("notes.txt", encoding: "Shift_JIS"),
                lsarEntry("plain.txt"),
            ]),
            manifest: "")
        let info = try engine(for: fake).list(archive: try dummyArchive(in: dir))
        XCTAssertEqual(info.entries[0].filenameEncoding, "Shift_JIS")
        XCTAssertNil(info.entries[1].filenameEncoding)
    }

    func testXadListFailsClearlyWhenLsarFails() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: []), manifest: "", failLsar: true)
        XCTAssertThrowsError(
            try engine(for: fake).list(archive: try dummyArchive(in: dir))
        ) { error in
            guard case EngineError.failed(_, let message) = error else {
                return XCTFail("expected EngineError.failed, got \(error)")
            }
            XCTAssertTrue(message.contains("lsar"), "message: \(message)")
        }
    }

    func testXadExtractsToDestination() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [
                lsarEntry("hello.txt", size: 5),
                lsarEntry("sub/b.txt", size: 3),
            ]),
            manifest: "hello.txt|hello\nsub/b.txt|bye\n")
        let dest = dir.appendingPathComponent("out")
        try engine(for: fake).extract(archive: try dummyArchive(in: dir),
                                      to: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("hello.txt"),
                                  encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("sub/b.txt"),
                                  encoding: .utf8), "bye")
    }

    func testXadExtractMovesOnlyWantedEntries() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [
                lsarEntry("a.txt", size: 1),
                lsarEntry("b.txt", size: 1),
            ]),
            manifest: "a.txt|A\nb.txt|B\n")
        let dest = dir.appendingPathComponent("out")
        try engine(for: fake).extract(archive: try dummyArchive(in: dir),
                                      entries: ["a.txt"], to: dest)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("b.txt").path))
    }

    func testXadExtractBlocksTraversal() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [lsarEntry("../evil.txt")]),
            manifest: "../evil.txt|evil\n")
        let dest = dir.appendingPathComponent("out")
        XCTAssertThrowsError(
            try engine(for: fake).extract(archive: try dummyArchive(in: dir),
                                          to: dest)
        ) { error in
            XCTAssertTrue(error is EntryPathSafety.Violation,
                          "expected a safety violation, got \(error)")
        }
        // unar never ran, and nothing was written.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fake.dir.appendingPathComponent("unar-argv.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testXadFailedExtractLeavesNoPartialOutput() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [lsarEntry("hello.txt", size: 5)]),
            manifest: "hello.txt|hello\n", failUnar: true)
        let dest = dir.appendingPathComponent("out")
        XCTAssertThrowsError(
            try engine(for: fake).extract(archive: try dummyArchive(in: dir),
                                          to: dest))
        // The partial file unar wrote into staging is gone with it.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("partial.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("hello.txt").path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: dest, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "staging left behind: \(leftovers)")
    }

    func testXadTestSucceedsAndFailsWithUnar() throws {
        let dir = try tempDir()
        let good = try makeFakeXAD(
            listing: try lsarJSON(entries: [lsarEntry("hello.txt", size: 5)]),
            manifest: "hello.txt|hello\n")
        try engine(for: good).test(archive: try dummyArchive(in: dir))
        let bad = try makeFakeXAD(
            listing: try lsarJSON(entries: [lsarEntry("hello.txt", size: 5)]),
            manifest: "hello.txt|hello\n", failUnar: true)
        XCTAssertThrowsError(
            try engine(for: bad).test(archive: try dummyArchive(in: dir)))
    }

    func testXadCreateAndEditFailClearly() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [lsarEntry("hello.txt", size: 5)]),
            manifest: "hello.txt|hello\n")
        let xad = engine(for: fake)
        let archive = try dummyArchive(in: dir)
        let dest = dir.appendingPathComponent("new.zip")
        let src = dir.appendingPathComponent("src.txt")
        try "src".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try xad.create(archive: dest, sources: [src], format: "zip", level: 9, password: nil, splitMB: 0, control: nil, onProgress: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("extraction-only"), "\(error)")
        }
        XCTAssertThrowsError(try xad.addEntries(archive: archive, sources: [src], prefix: nil, level: 9, password: nil, control: nil, onProgress: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("extraction-only"), "\(error)")
        }
        XCTAssertThrowsError(try xad.removeEntries(archive: archive, entries: ["hello.txt"], password: nil, control: nil, onProgress: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("extraction-only"), "\(error)")
        }
        XCTAssertThrowsError(try xad.renameEntries(archive: archive, renames: [(old: "hello.txt", new: "bye.txt")], password: nil, control: nil, onProgress: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("extraction-only"), "\(error)")
        }
        XCTAssertThrowsError(try xad.verify(archive: archive, entries: nil, includeSHA256: false, password: nil, control: nil, onProgress: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("cannot verify"), "\(error)")
        }
    }

    func testXadStreamEntryUnsupported() throws {
        let dir = try tempDir()
        let fake = try makeFakeXAD(
            listing: try lsarJSON(entries: [lsarEntry("hello.txt", size: 5)]),
            manifest: "hello.txt|hello\n")
        XCTAssertThrowsError(
            try engine(for: fake).streamEntry(archive: try dummyArchive(in: dir),
                                              entry: "hello.txt", password: nil) { _ in true }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("cannot stream"), "\(error)")
        }
    }

    func testXadMissingBinariesReportsUnavailable() throws {
        let xad = XADMasterEngine(lsarPath: "/nonexistent/lsar",
                                  unarPath: "/nonexistent/unar")
        XCTAssertFalse(xad.isAvailable)
        let dir = try tempDir()
        XCTAssertThrowsError(
            try xad.list(archive: try dummyArchive(in: dir))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("not installed"), "\(error)")
        }
    }
}

// MARK: - M6: engine router

final class EngineRouterTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// Fake 7zz with a mode file next to it: "ok" (2-entry listing),
    /// "empty" (0-entry listing, exit 0), "fail" (exit 2), "wrongPassword"
    /// (exit 2, password text), and "a" creates the archive file it is
    /// asked to write (for the convert test).
    private func makeFake7zz(mode: String) throws -> URL {
        let dir = try tempDir()
        let script = dir.appendingPathComponent("fake7zz")
        let text = """
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$@" >> "$dir/fake7zz-argv.log"
        mode="$(cat "$dir/mode")"
        cmd="$1"
        if [ "$cmd" = "a" ]; then
          shift
          for a in "$@"; do case "$a" in -*) ;; *) touch "$a"; break;; esac; done
          exit 0
        fi
        case "$mode" in
          fail) echo "ERROR: Can not open the file as archive" >&2; exit 2;;
          wrongPassword) echo "ERROR: Wrong password" >&2; exit 2;;
          empty) printf '7-Zip (z) 24.09\\n\\nListing archive: x\\n\\n--\\nPath = x\\nType = zip\\nPhysical Size = 100\\n\\n----------\\n';;
          *) printf '7-Zip (z) 24.09\\n\\nListing archive: x\\n\\n--\\nPath = x\\nType = zip\\nPhysical Size = 100\\n\\n----------\\nPath = seven.txt\\nFolder = -\\nSize = 7\\n\\nPath = other.txt\\nFolder = -\\nSize = 5\\n\\n';;
        esac
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try mode.write(to: dir.appendingPathComponent("mode"),
                       atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    /// Fake lsar/unar pair (same shape as XADEngineTests): lsar prints
    /// the canned JSON, unar creates the manifest files.
    private func makeFakeXAD(listing: String, manifest: String) throws -> (lsar: URL, unar: URL, dir: URL) {
        let dir = try tempDir()
        let lsar = dir.appendingPathComponent("lsar")
        let unar = dir.appendingPathComponent("unar")
        let lsarScript = """
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$@" >> "$dir/lsar-argv.log"
        cat "$dir/lsar.json"
        """
        let unarScript = """
        #!/bin/sh
        dir="$(dirname "$0")"
        echo "$@" >> "$dir/unar-argv.log"
        out=""
        for a in "$@"; do case "$a" in -o*) out="${a#-o}";; esac; done
        while IFS='|' read -r path content; do
          [ -z "$path" ] && continue
          mkdir -p "$out/$(dirname "$path")"
          printf '%s' "$content" > "$out/$path"
        done < "$dir/unar-manifest.txt"
        """
        try lsarScript.write(to: lsar, atomically: true, encoding: .utf8)
        try unarScript.write(to: unar, atomically: true, encoding: .utf8)
        for script in [lsar, unar] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        }
        try listing.write(to: dir.appendingPathComponent("lsar.json"),
                          atomically: true, encoding: .utf8)
        try manifest.write(to: dir.appendingPathComponent("unar-manifest.txt"),
                           atomically: true, encoding: .utf8)
        return (lsar, unar, dir)
    }

    private func lsarJSON(entries: [[String: Any]]) throws -> String {
        let doc: [String: Any] = ["lsarFormatName": "StuffIt",
                                  "lsarContents": entries]
        return String(decoding: try JSONSerialization.data(withJSONObject: doc),
                      as: UTF8.self)
    }

    private func router(sevenMode: String,
                        xadEntries: [[String: Any]] = [
                            ["XADFileName": "legacy.txt", "XADFileSize": 6,
                             "XADCompressedSize": 6, "XADIsDirectory": false,
                             "XADIsEncrypted": false],
                        ],
                        manifest: String = "legacy.txt|legacy\n") throws -> (EngineRouter, URL, URL) {
        let seven = try SevenZipEngine(binaryPath: try makeFake7zz(mode: sevenMode).path)
        let xadFake = try makeFakeXAD(listing: try lsarJSON(entries: xadEntries),
                                      manifest: manifest)
        let xad = XADMasterEngine(lsarPath: xadFake.lsar.path,
                                  unarPath: xadFake.unar.path)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("a.zip")
        try "dummy archive bytes".write(to: archive, atomically: true, encoding: .utf8)
        return (EngineRouter(engines: [seven, xad]), archive, xadFake.dir)
    }

    private func invoked(_ dir: URL, _ log: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(log).path)
    }

    func testRouterPrefers7zzForZip() throws {
        let (router, archive, xadDir) = try router(sevenMode: "ok")
        let info = try router.list(archive: archive)
        XCTAssertEqual(info.engine, "7zz")
        XCTAssertEqual(info.entries.map(\.path), ["seven.txt", "other.txt"])
        XCTAssertFalse(invoked(xadDir, "lsar-argv.log"), "lsar must not run when 7zz succeeds")
    }

    func testRouterFallsBackToXadWhen7zzFails() throws {
        let (router, archive, _) = try router(sevenMode: "fail")
        let info = try router.list(archive: archive)
        XCTAssertEqual(info.engine, "xad")
        XCTAssertEqual(info.entries.map(\.path), ["legacy.txt"])
    }

    func testRouterFallsBackOnEmpty7zzListing() throws {
        let (router, archive, _) = try router(sevenMode: "empty")
        let info = try router.list(archive: archive)
        XCTAssertEqual(info.engine, "xad")
        XCTAssertEqual(info.entries.map(\.path), ["legacy.txt"])
    }

    func testRouterHonoursXadOverride() throws {
        let (router, archive, _) = try router(sevenMode: "ok")
        router.defaultSelection = .xad
        let info = try router.list(archive: archive)
        XCTAssertEqual(info.engine, "xad")
        XCTAssertEqual(info.entries.map(\.path), ["legacy.txt"])
    }

    func testRouterUsesXadFirstForStuffIt() throws {
        let seven = try SevenZipEngine(binaryPath: try makeFake7zz(mode: "ok").path)
        let xadFake = try makeFakeXAD(
            listing: try lsarJSON(entries: [
                ["XADFileName": "legacy.txt", "XADFileSize": 6,
                 "XADCompressedSize": 6, "XADIsDirectory": false,
                 "XADIsEncrypted": false],
            ]),
            manifest: "legacy.txt|legacy\n")
        let xad = XADMasterEngine(lsarPath: xadFake.lsar.path,
                                  unarPath: xadFake.unar.path)
        let router = EngineRouter(engines: [seven, xad])
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("old.sit")
        try "dummy archive bytes".write(to: archive, atomically: true, encoding: .utf8)
        let info = try router.list(archive: archive)
        XCTAssertEqual(info.engine, "xad")
        // 7zz would have succeeded if asked — prove it was never tried.
        let sevenDir = URL(fileURLWithPath: seven.binaryURL.path)
            .deletingLastPathComponent()
        XCTAssertFalse(invoked(sevenDir, "fake7zz-argv.log"))
    }

    func testEncrypted7zStaysOn7zz() throws {
        let seven = try SevenZipEngine(binaryPath: try makeFake7zz(mode: "wrongPassword").path)
        let xadFake = try makeFakeXAD(
            listing: try lsarJSON(entries: [
                ["XADFileName": "legacy.txt", "XADFileSize": 6,
                 "XADCompressedSize": 6, "XADIsDirectory": false,
                 "XADIsEncrypted": false],
            ]),
            manifest: "legacy.txt|legacy\n")
        let xad = XADMasterEngine(lsarPath: xadFake.lsar.path,
                                  unarPath: xadFake.unar.path)
        let router = EngineRouter(engines: [seven, xad])
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("secret.7z")
        try "dummy archive bytes".write(to: archive, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try router.list(archive: archive, password: "pw")) { error in
            guard case EngineError.wrongPassword = error else {
                return XCTFail("expected wrongPassword, got \(error)")
            }
        }
        XCTAssertFalse(invoked(xadFake.dir, "lsar-argv.log"),
                       "XAD must never be tried for an encrypted 7z")
    }

    func testRouterPerFormatOverride() throws {
        let (router, archive, _) = try router(sevenMode: "ok")
        router.overrides["zip"] = .xad
        let info = try router.list(archive: archive)
        XCTAssertEqual(info.engine, "xad")
    }

    func testRouterListStreamingFallsBackBeforeFirstEntry() throws {
        let (router, archive, _) = try router(sevenMode: "fail")
        var seen: [String] = []
        let info = try router.listStreaming(archive: archive) { entry in
            seen.append(entry.path)
            return true
        }
        XCTAssertEqual(info.engine, "xad")
        XCTAssertEqual(seen, ["legacy.txt"])
    }

    func testRouterCancelDoesNotFallBack() throws {
        let (router, archive, xadDir) = try router(sevenMode: "ok")
        XCTAssertThrowsError(
            try router.listStreaming(archive: archive) { _ in false }
        ) { error in
            guard case EngineError.cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
        XCTAssertFalse(invoked(xadDir, "lsar-argv.log"),
                       "a cancel must not trigger a fallback run")
    }

    func testRouterConvertFromLegacyFormat() throws {
        let seven = try SevenZipEngine(binaryPath: try makeFake7zz(mode: "ok").path)
        let xadFake = try makeFakeXAD(
            listing: try lsarJSON(entries: [
                ["XADFileName": "hello.txt", "XADFileSize": 5,
                 "XADCompressedSize": 5, "XADIsDirectory": false,
                 "XADIsEncrypted": false],
            ]),
            manifest: "hello.txt|hello\n")
        let xad = XADMasterEngine(lsarPath: xadFake.lsar.path,
                                  unarPath: xadFake.unar.path)
        let router = EngineRouter(engines: [seven, xad])
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("old.sit")
        try "dummy archive bytes".write(to: archive, atomically: true, encoding: .utf8)
        let dest = dir.appendingPathComponent("converted.zip")
        try router.convert(archive: archive, to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testRouterSummaries() throws {
        let (router, _, _) = try router(sevenMode: "ok")
        let summaries = router.summaries()
        XCTAssertEqual(summaries.map(\.id), ["7zz", "xad"])
        XCTAssertTrue(summaries.allSatisfy(\.available))
        let xadSummary = summaries[1]
        XCTAssertTrue(xadSummary.capabilities.writeFormats.isEmpty)
        XCTAssertFalse(xadSummary.capabilities.supportsEncrypted7z)
        XCTAssertTrue(xadSummary.capabilities.readFormats.contains("sit"))
        XCTAssertTrue(summaries[0].capabilities.supportsEncrypted7z)
    }
}

// MARK: - M7: bundled engine lookup

final class BundledEnginesTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutable(at url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }

    func testFindsHelperInHelpersSubdirectory() throws {
        let root = try tempDir()
        let helpers = root.appendingPathComponent("Contents/Resources/Helpers",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: helpers,
                                                withIntermediateDirectories: true)
        let binary = helpers.appendingPathComponent("7zz")
        try makeExecutable(at: binary)
        XCTAssertEqual(BundledEngines.url(named: "7zz", bundleRoot: root), binary)
    }

    func testFindsHelperAtResourcesRoot() throws {
        let root = try tempDir()
        let resources = root.appendingPathComponent("Contents/Resources",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: resources,
                                                withIntermediateDirectories: true)
        let binary = resources.appendingPathComponent("7zz")
        try makeExecutable(at: binary)
        XCTAssertEqual(BundledEngines.url(named: "7zz", bundleRoot: root), binary)
    }

    func testPrefersHelpersOverResourcesRoot() throws {
        let root = try tempDir()
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let helpers = resources.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers,
                                                withIntermediateDirectories: true)
        let inHelpers = helpers.appendingPathComponent("unar")
        let atRoot = resources.appendingPathComponent("unar")
        try makeExecutable(at: inHelpers)
        try makeExecutable(at: atRoot)
        XCTAssertEqual(BundledEngines.url(named: "unar", bundleRoot: root), inHelpers)
    }

    func testReturnsNilWhenMissingOrNotExecutable() throws {
        let root = try tempDir()
        XCTAssertNil(BundledEngines.url(named: "7zz", bundleRoot: root))
        let helpers = root.appendingPathComponent("Resources/Helpers",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: helpers,
                                                withIntermediateDirectories: true)
        let binary = helpers.appendingPathComponent("7zz")
        try "not executable".write(to: binary, atomically: true, encoding: .utf8)
        XCTAssertNil(BundledEngines.url(named: "7zz", bundleRoot: root))
    }

    func testContainingAppURLForExtensionBundle() throws {
        let root = try tempDir()
        let appex = root.appendingPathComponent(
            "SeekZip.app/Contents/PlugIns/SeekZipFinderSync.appex",
            isDirectory: true)
        try FileManager.default.createDirectory(at: appex,
                                                withIntermediateDirectories: true)
        let bundle = Bundle(url: appex)
        XCTAssertNotNil(bundle)
        XCTAssertEqual(
            BundledEngines.containingAppURL(from: bundle!),
            root.appendingPathComponent("SeekZip.app"))
        XCTAssertEqual(
            BundledEngines.appBundleURL(from: bundle!),
            root.appendingPathComponent("SeekZip.app"))
    }

    func testContainingAppURLIsNilOutsideAnExtension() throws {
        let root = try tempDir()
        let bundle = Bundle(url: root)
        XCTAssertNotNil(bundle)
        XCTAssertNil(BundledEngines.containingAppURL(from: bundle!))
        // Compare paths: Bundle(url:) normalises the URL with a
        // trailing slash, so URL equality would fail on that alone.
        XCTAssertEqual(BundledEngines.appBundleURL(from: bundle!).path, root.path)
    }
}

// MARK: - M7: preview of XAD-only archives (extract fallback)

final class XADPreviewTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    /// Fake 7zz: mode "fail" exits 2 for every command; mode "stream"
    /// lists one text entry and prints its content for `e -so`.
    private func makeFake7zz(mode: String) throws -> URL {
        let dir = try tempDir()
        let script = dir.appendingPathComponent("fake7zz")
        let text = """
        #!/bin/sh
        dir="$(dirname "$0")"
        mode="$(cat "$dir/mode")"
        if [ "$mode" = "fail" ]; then echo "ERROR: Can not open the file as archive" >&2; exit 2; fi
        if [ "$1" = "e" ]; then printf 'hello\\nworld\\n'; exit 0; fi
        printf '7-Zip (z) 24.09\\n\\nListing archive: x\\n\\n--\\nPath = x\\nType = zip\\nPhysical Size = 100\\n\\n----------\\nPath = hello.txt\\nFolder = -\\nSize = 11\\n\\n'
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try mode.write(to: dir.appendingPathComponent("mode"),
                       atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    /// Fake lsar/unar pair (same shape as XADEngineTests): lsar prints
    /// the canned JSON, unar creates the manifest files. Manifest
    /// content `__LONG__` writes 300 lines, `__NUL__` writes bytes
    /// with an embedded NUL.
    private func makeFakeXAD(listing: String, manifest: String,
                             failUnar: Bool = false) throws -> (lsar: URL, unar: URL) {
        let dir = try tempDir()
        let lsar = dir.appendingPathComponent("lsar")
        let unar = dir.appendingPathComponent("unar")
        let lsarScript = """
        #!/bin/sh
        cat "$(dirname "$0")/lsar.json"
        """
        let unarScript = """
        #!/bin/sh
        dir="$(dirname "$0")"
        if [ -f "$dir/unar-fail" ]; then echo "unar: extraction failed" >&2; exit 2; fi
        out=""
        for a in "$@"; do case "$a" in -o*) out="${a#-o}";; esac; done
        while IFS='|' read -r path content; do
          [ -z "$path" ] && continue
          mkdir -p "$out/$(dirname "$path")"
          if [ "$content" = "__LONG__" ]; then
            i=1; while [ "$i" -le 300 ]; do echo "line $i"; i=$((i + 1)); done > "$out/$path"
          elif [ "$content" = "__NUL__" ]; then
            printf 'AB\\0CD' > "$out/$path"
          else
            printf '%s' "$content" > "$out/$path"
          fi
        done < "$dir/unar-manifest.txt"
        """
        try lsarScript.write(to: lsar, atomically: true, encoding: .utf8)
        try unarScript.write(to: unar, atomically: true, encoding: .utf8)
        for script in [lsar, unar] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        }
        try listing.write(to: dir.appendingPathComponent("lsar.json"),
                          atomically: true, encoding: .utf8)
        try manifest.write(to: dir.appendingPathComponent("unar-manifest.txt"),
                           atomically: true, encoding: .utf8)
        if failUnar {
            try "".write(to: dir.appendingPathComponent("unar-fail"),
                         atomically: true, encoding: .utf8)
        }
        return (lsar, unar)
    }

    private func lsarEntry(_ path: String, size: Int = 5) -> [String: Any] {
        ["XADFileName": path, "XADFileSize": size, "XADCompressedSize": size,
         "XADIsDirectory": false, "XADIsEncrypted": false]
    }

    private func lsarJSON(entries: [[String: Any]]) throws -> String {
        let doc: [String: Any] = ["lsarFormatName": "StuffIt",
                                  "lsarContents": entries]
        return String(decoding: try JSONSerialization.data(withJSONObject: doc),
                      as: UTF8.self)
    }

    private func router(sevenMode: String, entries: [[String: Any]],
                        manifest: String, failUnar: Bool = false,
                        archiveName: String = "a.sit") throws -> (EngineRouter, URL) {
        let seven = try SevenZipEngine(
            binaryPath: try makeFake7zz(mode: sevenMode).path)
        let xadFake = try makeFakeXAD(listing: try lsarJSON(entries: entries),
                                      manifest: manifest, failUnar: failUnar)
        let xad = XADMasterEngine(lsarPath: xadFake.lsar.path,
                                  unarPath: xadFake.unar.path)
        let dir = try tempDir()
        let archive = dir.appendingPathComponent(archiveName)
        try "dummy archive bytes".write(to: archive, atomically: true, encoding: .utf8)
        return (EngineRouter(engines: [seven, xad]), archive)
    }

    private func previewedEntry(router: EngineRouter,
                                archive: URL) throws -> ArchiveEntry {
        let info = try router.list(archive: archive)
        return info.entries[0]
    }

    func testPreviewFallsBackToExtractForXADArchive() throws {
        let (router, archive) = try router(
            sevenMode: "fail",
            entries: [lsarEntry("hello.txt", size: 5)],
            manifest: "hello.txt|hello\n")
        let entry = try previewedEntry(router: router, archive: archive)
        let preview = try PreviewProvider(engine: router)
            .preview(archive: archive, entry: entry)
        XCTAssertEqual(preview.kind, .text)
        XCTAssertEqual(preview.text, "hello")
        XCTAssertEqual(preview.linesShown, 1)
        XCTAssertFalse(preview.truncated)
        XCTAssertTrue(preview.note?.contains("temporary") ?? false,
                      "note: \(preview.note ?? "nil")")
    }

    func testPreviewFallbackTruncatesLongText() throws {
        let (router, archive) = try router(
            sevenMode: "fail",
            entries: [lsarEntry("long.txt", size: 2400)],
            manifest: "long.txt|__LONG__\n")
        let entry = try previewedEntry(router: router, archive: archive)
        let preview = try PreviewProvider(engine: router)
            .preview(archive: archive, entry: entry)
        XCTAssertEqual(preview.kind, .text)
        XCTAssertEqual(preview.linesShown, PreviewProvider.maxPreviewLines)
        XCTAssertTrue(preview.truncated)
    }

    func testPreviewFallbackDetectsBinary() throws {
        let (router, archive) = try router(
            sevenMode: "fail",
            entries: [lsarEntry("bin.dat", size: 5)],
            manifest: "bin.dat|__NUL__\n")
        let entry = try previewedEntry(router: router, archive: archive)
        let preview = try PreviewProvider(engine: router)
            .preview(archive: archive, entry: entry)
        XCTAssertEqual(preview.kind, .binary)
        XCTAssertTrue(preview.quickLook)
    }

    func testPreviewFallbackThrowsOriginalErrorWhenExtractFails() throws {
        let (router, archive) = try router(
            sevenMode: "fail",
            entries: [lsarEntry("hello.txt", size: 5)],
            manifest: "hello.txt|hello\n", failUnar: true)
        let entry = try previewedEntry(router: router, archive: archive)
        XCTAssertThrowsError(
            try PreviewProvider(engine: router)
                .preview(archive: archive, entry: entry)
        ) { error in
            // The 7zz streaming failure, not the unar failure.
            XCTAssertTrue(String(describing: error).contains("Can not open"),
                          "\(error)")
        }
    }

    func testPreviewFallbackBlocksTraversal() throws {
        let (router, archive) = try router(
            sevenMode: "fail",
            entries: [lsarEntry("../evil.txt", size: 4)],
            manifest: "../evil.txt|evil\n")
        let entry = try previewedEntry(router: router, archive: archive)
        XCTAssertThrowsError(
            try PreviewProvider(engine: router)
                .preview(archive: archive, entry: entry)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("traversal"),
                          "\(error)")
        }
    }

    func testPreviewStillStreamsThroughRouter() throws {
        let (router, archive) = try router(
            sevenMode: "stream",
            entries: [lsarEntry("hello.txt", size: 11)],
            manifest: "hello.txt|hello\n", archiveName: "a.zip")
        let entry = try previewedEntry(router: router, archive: archive)
        let preview = try PreviewProvider(engine: router)
            .preview(archive: archive, entry: entry)
        XCTAssertEqual(preview.kind, .text)
        XCTAssertEqual(preview.text, "hello\nworld")
        XCTAssertEqual(preview.linesShown, 2)
        XCTAssertFalse(preview.truncated)
        XCTAssertNil(preview.note)
    }
}
