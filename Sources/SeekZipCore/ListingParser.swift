import Foundation

/// Parser for `7zz l -slt` technical listings.
///
/// The listing is a header block, a line containing only `--`, then one
/// `Key = Value` block per entry, blocks separated by blank lines.
/// Filenames may contain "=" and spaces, so values are taken verbatim
/// after the first " = ".
public enum ListingParser {

    public static func parse(format: String = "unknown",
                             physicalSize: UInt64 = 0,
                             archivePath: String,
                             text: String) -> ArchiveInfo {
        var entries: [ArchiveEntry] = []
        var inEntries = false
        var current: [String: String] = [:]

        func flush() {
            guard let path = current["Path"], !path.isEmpty else { return }
            let folder = current["Folder"] == "+"
            let attr = current["Attributes"]
            entries.append(ArchiveEntry(
                path: path,
                isDirectory: folder || (attr?.hasPrefix("D") ?? false),
                size: UInt64(current["Size"] ?? "") ?? 0,
                packedSize: UInt64(current["Packed Size"] ?? "") ?? 0,
                modified: parseDate(current["Modified"]),
                crc: current["CRC"],
                method: current["Method"],
                isEncrypted: current["Encrypted"] == "+",
                attributes: attr
            ))
            current = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !inEntries {
                if line.trimmingCharacters(in: .whitespaces) == "--" { inEntries = true }
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[line.startIndex..<eq.lowerBound])
            let value = String(line[eq.upperBound...])
            current[key] = value
        }
        flush()
        return ArchiveInfo(path: archivePath, format: format,
                           physicalSize: physicalSize, entries: entries)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: String(value.prefix(19)))
    }
}
