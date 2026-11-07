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
