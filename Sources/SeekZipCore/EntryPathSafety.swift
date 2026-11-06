import Foundation

/// Extraction safety checks, applied to every entry before anything is
/// written to disk. This is the layer a raw terminal/`7zz` call does not
/// give you, and the reason extraction goes through SeekZipCore.
public enum EntryPathSafety {

    public enum Violation: Error, CustomStringConvertible {
        case absolutePath(String)
        case pathTraversal(String)
        case symlinkEscape(String)
        case emptyPath

        public var description: String {
            switch self {
            case .absolutePath(let p): return "absolute path entry: \(p)"
            case .pathTraversal(let p): return "path traversal entry: \(p)"
            case .symlinkEscape(let p): return "symlink entry not allowed by policy: \(p)"
            case .emptyPath: return "empty entry path"
            }
        }
    }

    /// Returns the safe destination URL for an entry, or throws a Violation.
    /// - Parameters:
    ///   - entry: the archive entry to place.
    ///   - destination: the extraction root chosen by the user.
    ///   - allowSymlinks: when false (default), symlink entries are rejected.
    public static func destinationURL(for entry: ArchiveEntry,
                                      in destination: URL,
                                      allowSymlinks: Bool = false) throws -> URL {
        let raw = entry.path.replacingOccurrences(of: "\\", with: "/")
        guard !raw.isEmpty else { throw Violation.emptyPath }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else {
            throw Violation.absolutePath(entry.path)
        }
        if entry.isSymlink && !allowSymlinks {
            throw Violation.symlinkEscape(entry.path)
        }
        let root = destination.standardizedFileURL
        let url = root.appendingPathComponent(raw).standardizedFileURL
        // After standardisation the result must still live under the root.
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw Violation.pathTraversal(entry.path)
        }
        return url
    }

    /// Zip-bomb heuristic: expansion ratio above the threshold, or an
    /// implausible entry count for the archive's physical size.
    public static func bombWarning(for info: ArchiveInfo,
                                   ratioThreshold: Double = 100,
                                   sizeThreshold: UInt64 = 100_000_000) -> String? {
        if info.expansionRatio > ratioThreshold && info.totalUncompressed > sizeThreshold {
            return "Suspicious expansion ratio \(Int(info.expansionRatio)):1 " +
                   "(\(info.totalUncompressed) bytes from \(info.physicalSize) bytes)"
        }
        return nil
    }
}
