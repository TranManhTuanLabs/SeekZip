import Foundation

/// One item inside an archive, as reported by the engine's technical listing.
public struct ArchiveEntry: Codable, Identifiable, Sendable {
    public var id: String { path }
    /// Path inside the archive, always using "/" separators.
    public var path: String
    public var isDirectory: Bool
    /// Uncompressed size in bytes.
    public var size: UInt64
    /// Compressed (packed) size in bytes.
    public var packedSize: UInt64
    public var modified: Date?
    public var crc: String?
    public var method: String?
    public var isEncrypted: Bool
    /// Raw attributes string from the engine (may contain symlink info).
    public var attributes: String?

    public init(path: String, isDirectory: Bool = false, size: UInt64 = 0,
                packedSize: UInt64 = 0, modified: Date? = nil, crc: String? = nil,
                method: String? = nil, isEncrypted: Bool = false,
                attributes: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.crc = crc
        self.method = method
        self.isEncrypted = isEncrypted
        self.attributes = attributes
    }

    public var name: String {
        (path as NSString).lastPathComponent
    }

    /// True when the attributes mark this entry as a symlink.
    public var isSymlink: Bool {
        attributes?.contains("l") ?? false // unix mode "lrwxrwxrwx"
    }
}

/// Summary information about a whole archive.
public struct ArchiveInfo: Codable, Sendable {
    public var path: String
    public var format: String
    public var physicalSize: UInt64
    public var entries: [ArchiveEntry]

    public var totalUncompressed: UInt64 { entries.reduce(0) { $0 + $1.size } }

    /// Expansion ratio — used for the zip-bomb warning.
    public var expansionRatio: Double {
        guard physicalSize > 0 else { return 0 }
        return Double(totalUncompressed) / Double(physicalSize)
    }
}
