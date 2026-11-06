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
