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
    /// Filename encoding the engine recovered for this entry, when it
    /// reports one (M6: XAD's encoding recovery — e.g. "Shift_JIS").
    /// `nil` when the name was plain UTF-8 or the engine says nothing.
    public var filenameEncoding: String?

    public init(path: String, isDirectory: Bool = false, size: UInt64 = 0,
                packedSize: UInt64 = 0, modified: Date? = nil, crc: String? = nil,
                method: String? = nil, isEncrypted: Bool = false,
                attributes: String? = nil,
                filenameEncoding: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.crc = crc
        self.method = method
        self.isEncrypted = isEncrypted
        self.attributes = attributes
        self.filenameEncoding = filenameEncoding
    }

    public var name: String {
        (path as NSString).lastPathComponent
    }

    /// True when the attributes mark this entry as a symlink.
    public var isSymlink: Bool {
        attributes?.contains("l") ?? false // unix mode "lrwxrwxrwx"
    }

    /// Archive formats SeekZip can open as a nested archive (M3).
    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst",
        "lz4", "iso", "dmg", "cab", "wim", "arj", "lzh", "jar", "war",
        "apk", "ipa", "xar", "deb", "rpm", "msi", "cpio", "lzma",
    ]

    /// True when this entry is itself an archive that can be opened
    /// in place (`SevenZipEngine.listNested`).
    public var isArchive: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return Self.archiveExtensions.contains(ext)
    }
}

/// Summary information about a whole archive.
public struct ArchiveInfo: Codable, Sendable {
    public var path: String
    public var format: String
    public var physicalSize: UInt64
    public var entries: [ArchiveEntry]
    /// Which engine handled this archive (`EngineID` raw value:
    /// "7zz" or "xad"), stamped by the router (M6). `nil` for a
    /// listing taken straight from one engine without routing.
    public var engine: String?

    public init(path: String, format: String, physicalSize: UInt64,
                entries: [ArchiveEntry], engine: String? = nil) {
        self.path = path
        self.format = format
        self.physicalSize = physicalSize
        self.entries = entries
        self.engine = engine
    }

    public var totalUncompressed: UInt64 { entries.reduce(0) { $0 + $1.size } }

    /// Expansion ratio — used for the zip-bomb warning.
    public var expansionRatio: Double {
        guard physicalSize > 0 else { return 0 }
        return Double(totalUncompressed) / Double(physicalSize)
    }
}
