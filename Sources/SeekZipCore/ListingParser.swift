import Foundation

/// Parser for `7zz l -slt` technical listings.
///
/// The listing is a header block, a line containing only `--`, then the
/// archive header, a `----------` separator, then one `Key = Value`
/// block per entry, blocks separated by blank lines.
/// Filenames may contain "=" and spaces, so values are taken verbatim
/// after the first " = ".
public enum ListingParser {

    public static func parse(format: String = "unknown",
                             physicalSize: UInt64 = 0,
                             archivePath: String,
                             text: String) -> ArchiveInfo {
        let parser = StreamingListingParser()
        let entries = parser.feed(Data(text.utf8)) + parser.finish()
        return ArchiveInfo(path: archivePath, format: format,
                           physicalSize: physicalSize, entries: entries)
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: String(value.prefix(19)))
    }
}

/// Incremental `7zz l -slt` parser (M2).
///
/// Feed it raw output bytes as they arrive from the `7zz` subprocess;
/// it returns each entry as soon as its `Key = Value` block is
/// complete, so a 1M-entry listing never sits in memory as one big
/// string. Lines are decoded only once terminated by `\n`, so a
/// multi-byte UTF-8 character split across two chunks is never
/// decoded half-way: the newline byte (0x0A) cannot occur inside a
/// UTF-8 sequence.
public final class StreamingListingParser {
    public private(set) var bytesRead: UInt64 = 0
    public private(set) var entriesSeen: Int = 0

    private var pending = Data()
    private var inEntries = false
    private var entriesStarted = false
    private var current: [String: String] = [:]

    public init() {}

    /// Feed raw bytes; returns entries completed by this chunk.
    public func feed(_ data: Data) -> [ArchiveEntry] {
        bytesRead += UInt64(data.count)
        pending.append(data)
        var completed: [ArchiveEntry] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if let entry = processLine(line) {
                entriesSeen += 1
                completed.append(entry)
            }
        }
        return completed
    }

    /// Process any unterminated trailing line and flush the last block;
    /// returns entries completed by the tail. Call once at end of stream.
    public func finish() -> [ArchiveEntry] {
        var completed: [ArchiveEntry] = []
        if !pending.isEmpty {
            var line = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            if line.hasSuffix("\r") { line.removeLast() }
            if let entry = processLine(line) {
                entriesSeen += 1
                completed.append(entry)
            }
        }
        if let entry = flush() {
            entriesSeen += 1
            completed.append(entry)
        }
        return completed
    }

    /// Handles one decoded line; returns an entry when a block closes.
    private func processLine(_ line: String) -> ArchiveEntry? {
        if !inEntries {
            if line.trimmingCharacters(in: .whitespaces) == "--" { inEntries = true }
            return nil
        }
        if line.isEmpty { return flush() }
        // "----------" separates the archive header from the entries.
        if line.allSatisfy({ $0 == "-" }) {
            current = [:]
            entriesStarted = true
            return nil
        }
        guard let eq = line.range(of: " = ") else { return nil }
        let key = String(line[line.startIndex..<eq.lowerBound])
        let value = String(line[eq.upperBound...])
        current[key] = value
        return nil
    }

    /// Closes the current block; returns its entry, if it is a real one.
    /// The block between "--" and the "----------" separator is the
    /// archive header (Path/Type/Physical Size), not an entry.
    private func flush() -> ArchiveEntry? {
        defer { current = [:] }
        guard entriesStarted else { return nil }
        guard let path = current["Path"], !path.isEmpty else { return nil }
        let folder = current["Folder"] == "+"
        let attr = current["Attributes"]
        return ArchiveEntry(
            path: path,
            isDirectory: folder || (attr?.hasPrefix("D") ?? false),
            size: UInt64(current["Size"] ?? "") ?? 0,
            packedSize: UInt64(current["Packed Size"] ?? "") ?? 0,
            modified: ListingParser.parseDate(current["Modified"]),
            crc: current["CRC"],
            method: current["Method"],
            isEncrypted: current["Encrypted"] == "+",
            attributes: attr
        )
    }
}
