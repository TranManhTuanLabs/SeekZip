import Foundation

/// Which engine handled an archive (M6). The raw value is what the
/// CLI/MCP surface (`ArchiveInfo.engine`, `seekzip engines`).
public enum EngineID: String, Codable, Sendable, CaseIterable {
    /// Official 7-Zip console binary — primary engine.
    case sevenZip = "7zz"
    /// XADMaster (`lsar`/`unar`) — extraction-only fallback.
    case xad = "xad"
}

/// How the router picks an engine for one operation (M6).
public enum EngineSelection: String, Codable, Sendable {
    /// Capability order, with fallback (the default).
    case auto
    /// Force the 7zz engine; no fallback.
    case sevenZip = "7zz"
    /// Force the XAD engine; no fallback.
    case xad = "xad"
}

/// What one engine can do, per format (M6; the capability matrix
/// from `docs/REFERENCE.md` §2.5, made data instead of prose).
/// Routing is data-driven: the router reads these, frontends never
/// hard-code "7zz handles X".
public struct EngineCapabilities: Codable, Sendable {
    /// File extensions this engine can list/extract (lowercase, no dot).
    public var readFormats: [String]
    /// File extensions this engine can create (empty = extraction-only).
    public var writeFormats: [String]
    /// Whether the engine has a real integrity test. XAD's `test`
    /// extracts to a temp dir and discards it (there is no `t`).
    public var canTest: Bool
    /// Whether encrypted 7z archives open on this engine. Only 7zz.
    public var supportsEncrypted7z: Bool
    /// Whether listings stream incrementally (7zz) or arrive as one
    /// buffered document (lsar's JSON).
    public var supportsStreamingList: Bool
    /// Whether one entry's bytes can stream out without extracting
    /// (7zz `e -so`); XAD cannot — it only writes files.
    public var supportsEntryStreaming: Bool
    /// Human-readable limits, shown by `seekzip engines`.
    public var notes: [String]

    public init(readFormats: [String], writeFormats: [String],
                canTest: Bool, supportsEncrypted7z: Bool,
                supportsStreamingList: Bool, supportsEntryStreaming: Bool,
                notes: [String] = []) {
        self.readFormats = readFormats
        self.writeFormats = writeFormats
        self.canTest = canTest
        self.supportsEncrypted7z = supportsEncrypted7z
        self.supportsStreamingList = supportsStreamingList
        self.supportsEntryStreaming = supportsEntryStreaming
        self.notes = notes
    }
}

/// One entry's checksum as reported by a listing (CRC-32 from the
/// engine; `nil` when the format does not report one, e.g. folders
/// and some solid-7z entries). Moved out of `SevenZipEngine` in M6 so
/// the protocol can use it.
public struct EntryChecksum: Codable, Sendable {
    public var path: String
    public var crc: String?
    public var size: UInt64

    public init(path: String, crc: String?, size: UInt64) {
        self.path = path
        self.crc = crc
        self.size = size
    }
}

/// The outcome of verifying one entry (M6: moved out of
/// `SevenZipEngine` so the protocol can use it).
public struct EntryVerification: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Streamed bytes hash to the listing CRC.
        case ok
        /// Streamed bytes do not hash to the listing CRC (COR-02).
        case mismatch
        /// The listing has no CRC for this entry, so nothing to
        /// compare against — the bytes still streamed fine.
        case unknown
        /// The entry could not be streamed at all (wrong password,
        /// unreadable data, …).
        case error
    }

    public var entryPath: String
    public var status: Status
    public var expectedCRC: String?
    public var actualCRC: String?
    public var sha256: String?
    public var message: String?

    public init(entryPath: String, status: Status,
                expectedCRC: String? = nil, actualCRC: String? = nil,
                sha256: String? = nil, message: String? = nil) {
        self.entryPath = entryPath
        self.status = status
        self.expectedCRC = expectedCRC
        self.actualCRC = actualCRC
        self.sha256 = sha256
        self.message = message
    }
}

/// The engine contract (M6, `docs/REFERENCE.md` §2.5).
/// `SevenZipEngine` was the first, implicit implementation; the
/// protocol formalises it and `XADMasterEngine` is the second.
/// Operations an engine cannot do (XAD can never create or edit)
/// have a default implementation that fails clearly, so a caller
/// never gets a silent no-op.
public protocol ArchiveEngine: AnyObject, Sendable {
    var id: EngineID { get }
    var capabilities: EngineCapabilities { get }
    /// False when the engine's binaries are not installed — the
    /// router skips such engines instead of failing.
    var isAvailable: Bool { get }

    func list(archive: URL, password: String?,
              control: JobControl?) throws -> ArchiveInfo
    func listStreaming(archive: URL, password: String?,
                       control: JobControl?,
                       onProgress: ((ListingProgress) -> Void)?,
                       onEntry: (ArchiveEntry) -> Bool) throws -> ArchiveInfo
    func test(archive: URL, password: String?,
              control: JobControl?,
              onProgress: ((JobProgress) -> Void)?) throws
    func extract(archive: URL, entries: [String]?,
                 to destination: URL, password: String?,
                 control: JobControl?,
                 onProgress: ((JobProgress) -> Void)?) throws
    func streamEntry(archive: URL, entry: String, password: String?,
                     onChunk: (Data) -> Bool) throws -> Bool
    func create(archive: URL, sources: [URL], format: String,
                level: Int, password: String?, splitMB: Int,
                control: JobControl?,
                onProgress: ((JobProgress) -> Void)?) throws
    func addEntries(archive: URL, sources: [URL], prefix: String?,
                    level: Int, password: String?,
                    control: JobControl?,
                    onProgress: ((JobProgress) -> Void)?) throws
    func removeEntries(archive: URL, entries: [String],
                       password: String?, control: JobControl?,
                       onProgress: ((JobProgress) -> Void)?) throws
    func renameEntries(archive: URL,
                       renames: [(old: String, new: String)],
                       password: String?, control: JobControl?,
                       onProgress: ((JobProgress) -> Void)?) throws
    func convert(archive: URL, to destination: URL,
                 targetFormat: String?, password: String?,
                 control: JobControl?,
                 onProgress: ((JobProgress) -> Void)?) throws
    func entryChecksums(archive: URL, password: String?,
                        control: JobControl?) throws -> [EntryChecksum]
    func verify(archive: URL, entries: [String]?,
                includeSHA256: Bool, password: String?,
                control: JobControl?,
                onProgress: ((JobProgress) -> Void)?) throws -> [EntryVerification]
}

public extension ArchiveEngine {
    /// Default: this engine cannot stream one entry's bytes.
    /// (XAD: `unar` only writes files, there is no `-so` equivalent.)
    func streamEntry(archive: URL, entry: String, password: String?,
                     onChunk: (Data) -> Bool) throws -> Bool {
        throw EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine cannot stream a single entry — extract it instead")
    }

    /// Default: this engine cannot create archives (extraction-only).
    func create(archive: URL, sources: [URL], format: String,
                level: Int, password: String?, splitMB: Int,
                control: JobControl?,
                onProgress: ((JobProgress) -> Void)?) throws {
        throw EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine is extraction-only and cannot create archives")
    }

    /// Default: this engine cannot edit archives in place.
    func addEntries(archive: URL, sources: [URL], prefix: String?,
                    level: Int, password: String?,
                    control: JobControl?,
                    onProgress: ((JobProgress) -> Void)?) throws {
        throw EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine is extraction-only and cannot add entries")
    }

    /// Default: this engine cannot edit archives in place.
    func removeEntries(archive: URL, entries: [String],
                       password: String?, control: JobControl?,
                       onProgress: ((JobProgress) -> Void)?) throws {
        throw EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine is extraction-only and cannot remove entries")
    }

    /// Default: this engine cannot edit archives in place.
    func renameEntries(archive: URL,
                       renames: [(old: String, new: String)],
                       password: String?, control: JobControl?,
                       onProgress: ((JobProgress) -> Void)?) throws {
        throw EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine is extraction-only and cannot rename entries")
    }

    /// Default: conversion needs a writer, which an extraction-only
    /// engine does not have. The router overrides this: it extracts
    /// through the routed engine and creates through 7zz.
    func convert(archive: URL, to destination: URL,
                 targetFormat: String?, password: String?,
                 control: JobControl?,
                 onProgress: ((JobProgress) -> Void)?) throws {
        throw EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine is extraction-only and cannot convert archives")
    }

    /// Default: checksums come from the listing, which an
    /// extraction-only engine still has — but the shared
    /// implementation lives in the router/7zz path; a bare engine
    /// reports that it cannot do it alone.
    func entryChecksums(archive: URL, password: String?,
                        control: JobControl?) throws -> [EntryChecksum] {
        let info = try list(archive: archive, password: password, control: control)
        return info.entries.map {
            EntryChecksum(path: $0.path, crc: $0.crc, size: $0.size)
        }
    }

    /// Default: verification needs entry streaming, which an
    /// extraction-only engine cannot do.
    func verify(archive: URL, entries: [String]?,
                includeSHA256: Bool, password: String?,
                control: JobControl?,
                onProgress: ((JobProgress) -> Void)?) throws -> [EntryVerification] {
        throw EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine cannot verify entries — it has no entry streaming (use the 7zz engine)")
    }

    /// Lists the contents of an archive stored inside another archive
    /// (M3, TEST-MATRIX NES-01). Each element of `nestedPath` is one
    /// level. The returned `ArchiveInfo.path` is
    /// `outer!/inner!/deep` so callers can tell which level it is.
    /// Implemented once here from `list`/`extract`, so every engine —
    /// and the router — gets nesting for free.
    func listNested(archive: URL, nestedPath: [String],
                    password: String? = nil) throws -> ArchiveInfo {
        var listed = try withNestedArchive(archive: archive,
                                           nestedPath: nestedPath,
                                           password: password) { nestedURL in
            try list(archive: nestedURL, password: password, control: nil)
        }
        listed.path = archive.path + "!/" + nestedPath.joined(separator: "!/")
        return listed
    }

    /// Extracts a nested archive chain to a temp dir and runs `body`
    /// with the extracted (innermost) file's URL, then removes the temp
    /// dir (M3). Each element of `nestedPath` is one level: the entry
    /// is validated with `EntryPathSafety` and must exist, be a file,
    /// and be an archive. The outer archive is never modified.
    func withNestedArchive<T>(archive: URL, nestedPath: [String],
                              password: String? = nil,
                              body: (URL) throws -> T) throws -> T {
        guard !nestedPath.isEmpty else {
            throw EngineError.failed(exitCode: 2, message: "nested path is empty")
        }
        // Reject unsafe nested paths before any work reaches the engine.
        for component in nestedPath {
            _ = try EntryPathSafety.destinationURL(
                for: ArchiveEntry(path: component),
                in: FileManager.default.temporaryDirectory)
        }
        var tempDirs: [URL] = []
        defer {
            for dir in tempDirs {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        var current = archive
        for component in nestedPath {
            let info = try list(archive: current, password: password, control: nil)
            guard let entry = info.entries.first(where: { $0.path == component }) else {
                throw EngineError.failed(exitCode: 2,
                                         message: "nested entry not found: \(component)")
            }
            guard !entry.isDirectory, !entry.isSymlink else {
                throw EngineError.failed(exitCode: 2,
                                         message: "nested entry is not a file: \(component)")
            }
            guard entry.isArchive else {
                throw EngineError.failed(exitCode: 2,
                                         message: "nested entry is not an archive: \(component)")
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            tempDirs.append(dir)
            try extract(archive: current, entries: [component], to: dir,
                        password: password, control: nil, onProgress: nil)
            current = dir.appendingPathComponent(component)
        }
        return try body(current)
    }
}

/// One engine's summary for `seekzip engines` / MCP `list_engines`.
public struct EngineSummary: Codable, Sendable {
    public var id: String
    public var displayName: String
    public var available: Bool
    public var binaryPath: String?
    public var capabilities: EngineCapabilities

    public init(id: String, displayName: String, available: Bool,
                binaryPath: String?,
                capabilities: EngineCapabilities) {
        self.id = id
        self.displayName = displayName
        self.available = available
        self.binaryPath = binaryPath
        self.capabilities = capabilities
    }
}

/// Routes archive operations across engines (M6).
///
/// Selection order for one archive:
/// 1. `defaultSelection` when it names one engine (`--engine`);
/// 2. a per-format override (`overrides`, from GUI settings);
/// 3. capability order — XAD-first for legacy formats 7zz cannot
///    open at all (StuffIt, Zoo, ARC, …), otherwise 7zz first;
/// 4. fallback: when the primary engine fails, returns an empty
///    listing for a non-empty archive, or is missing, the next
///    available engine is tried.
///
/// Fallback never masks a password error, a cancel, a safety
/// violation or a full disk — those are reported as-is. Encrypted
/// 7z stays on 7zz whenever a password is in play (XAD cannot open
/// encrypted 7z at all). The engine that handled an operation is
/// recorded in `ArchiveInfo.engine` (list) and in `lastEngine`
/// (test/extract, which return no info).
public final class EngineRouter: ArchiveEngine, @unchecked Sendable {

    /// Extensions 7zz cannot open at all, so XAD goes first for
    /// them. ARJ/LZH are NOT in this set: 7-Zip unpacks several
    /// ARJ/LZH variants, so they stay 7zz-first with XAD fallback.
    /// (REFERENCE.md §2.3: XAD is the only reader for StuffIt,
    /// StuffIt X, Zoo, ARC, Compact Pro, DiskDoubler, PackIt,
    /// Ace pre-2.0 and Amiga formats.)
    public static let xadFirstExtensions: Set<String> = [
        "sit", "sitx", "zoo", "arc", "cpt", "dd", "pit", "ace", "sea",
    ]

    public let engines: [any ArchiveEngine]
    /// Per-format override: format/extension (lowercase) -> engine.
    /// Set from GUI settings; the CLI `--engine` flag sets
    /// `defaultSelection` instead.
    public var overrides: [String: EngineID] = [:]
    /// Per-invocation selection (CLI `--engine`); `.auto` by default.
    public var defaultSelection: EngineSelection = .auto
    /// The engine that handled the last routed operation
    /// (single-threaded frontends only — the CLI/MCP call one
    /// operation at a time).
    public private(set) var lastEngine: EngineID?

    /// The router reports its primary engine's id; the engine that
    /// actually handled an operation is stamped into
    /// `ArchiveInfo.engine` / `lastEngine` instead.
    public var id: EngineID { engines.first?.id ?? .sevenZip }
    public var capabilities: EngineCapabilities {
        EngineCapabilities(
            readFormats: Array(Set(engines.flatMap { $0.capabilities.readFormats })).sorted(),
            writeFormats: Array(Set(engines.flatMap { $0.capabilities.writeFormats })).sorted(),
            canTest: engines.contains { $0.capabilities.canTest },
            supportsEncrypted7z: engines.contains { $0.capabilities.supportsEncrypted7z },
            supportsStreamingList: engines.contains { $0.capabilities.supportsStreamingList },
            supportsEntryStreaming: engines.contains { $0.capabilities.supportsEntryStreaming },
            notes: ["Routes across \(engines.count) engines; see `seekzip engines` for the per-engine matrix."])
    }
    public var isAvailable: Bool { engines.contains { $0.isAvailable } }

    public init(engines: [any ArchiveEngine]) {
        self.engines = engines
    }

    /// Convenience: 7zz first, XAD second (the standard order).
    public convenience init(sevenZip: SevenZipEngine, xad: XADMasterEngine) {
        self.init(engines: [sevenZip, xad])
    }

    /// Summaries for `seekzip engines` / MCP `list_engines`.
    public func summaries() -> [EngineSummary] {
        engines.map { engine in
            EngineSummary(
                id: engine.id.rawValue,
                displayName: engine.id == .sevenZip
                    ? "7-Zip (7zz)" : "XADMaster (lsar/unar)",
                available: engine.isAvailable,
                binaryPath: (engine as? BinaryReporting)?.binaryPath,
                capabilities: engine.capabilities)
        }
    }

    // MARK: - Primary selection

    /// The engine to try first for `archive` under the current
    /// selection and overrides. Throws when an explicitly selected
    /// engine is not installed.
    public func resolvePrimary(for archive: URL) throws -> any ArchiveEngine {
        switch defaultSelection {
        case .sevenZip: return try requireEngine(.sevenZip)
        case .xad: return try requireEngine(.xad)
        case .auto: break
        }
        if let format = SevenZipEngine.format(of: archive)?.lowercased(),
           let override = overrides[format] {
            return try requireEngine(override)
        }
        let ext = (archive.path as NSString).pathExtension.lowercased()
        if Self.xadFirstExtensions.contains(ext),
           let xad = engine(withId: .xad), xad.isAvailable {
            return xad
        }
        guard let first = engines.first(where: \.isAvailable) else {
            throw EngineError.failed(
                exitCode: 2,
                message: "no archive engine is available (7zz and unar both missing)")
        }
        return first
    }

    private func engine(withId id: EngineID) -> (any ArchiveEngine)? {
        engines.first { $0.id == id }
    }

    private func requireEngine(_ id: EngineID) throws -> any ArchiveEngine {
        guard let engine = engine(withId: id), engine.isAvailable else {
            throw EngineError.failed(
                exitCode: 2,
                message: "the \(id.rawValue) engine is not available (not installed)")
        }
        return engine
    }

    /// The 7zz engine, for operations only it can do (create/edit/
    /// verify/streaming). Throws clearly when 7zz is missing.
    private func sevenZip() throws -> any ArchiveEngine {
        try requireEngine(.sevenZip)
    }

    private func fallbackEngines(after primary: any ArchiveEngine) -> [any ArchiveEngine] {
        engines.filter { $0.id != primary.id && $0.isAvailable }
    }

    /// Whether a failed primary attempt may fall back to the next
    /// engine. Never for password errors (the same password would
    /// fail there too, and XAD cannot open encrypted 7z at all),
    /// cancels, full disks or safety violations — those are final.
    private func canFallback(after error: Error, format: String?,
                             password: String?) -> Bool {
        guard let engineError = error as? EngineError else { return false }
        switch engineError {
        case .cancelled, .wrongPassword, .insufficientDiskSpace:
            return false
        case .binaryNotFound:
            return true
        case .failed:
            // Encrypted 7z with a password stays on 7zz: XAD's
            // "7z: no encryption" hole means the fallback could only
            // produce a second, more confusing error.
            if format == "7z", password != nil { return false }
            return true
        }
    }

    /// Runs `operation` on the primary engine, falling back to the
    /// next available engines on a fallback-eligible failure.
    /// Returns the result and the engine that produced it.
    private func attempt<T>(archive: URL, password: String?,
                            operation: (any ArchiveEngine) throws -> T)
    throws -> (T, any ArchiveEngine) {
        let primary = try resolvePrimary(for: archive)
        let format = SevenZipEngine.format(of: archive)
        do {
            return (try operation(primary), primary)
        } catch {
            guard canFallback(after: error, format: format, password: password) else {
                throw error
            }
            var lastError = error
            for next in fallbackEngines(after: primary) {
                do {
                    return (try operation(next), next)
                } catch {
                    lastError = error
                    guard canFallback(after: error, format: format, password: password) else {
                        throw error
                    }
                }
            }
            throw lastError
        }
    }

    // MARK: - Routed read operations

    public func list(archive: URL, password: String? = nil,
                     control: JobControl? = nil) throws -> ArchiveInfo {
        let (listed, engine) = try attempt(archive: archive, password: password) { engine in
            try engine.list(archive: archive, password: password, control: control)
        }
        var info = listed
        info.engine = engine.id.rawValue
        lastEngine = engine.id
        // Empty listing from a non-empty file means "garbled" (the
        // parser saw nothing it could use) — give the next engine a
        // chance before reporting zero entries.
        if info.entries.isEmpty,
           let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? UInt64,
           size > 0 {
            for next in fallbackEngines(after: engine) {
                if let alt = try? next.list(archive: archive, password: password, control: control),
                   !alt.entries.isEmpty {
                    var alt = alt
                    alt.engine = next.id.rawValue
                    lastEngine = next.id
                    return alt
                }
            }
        }
        return info
    }

    public func listStreaming(archive: URL, password: String? = nil,
                              control: JobControl? = nil,
                              onProgress: ((ListingProgress) -> Void)? = nil,
                              onEntry: (ArchiveEntry) -> Bool) throws -> ArchiveInfo {
        let primary = try resolvePrimary(for: archive)
        let format = SevenZipEngine.format(of: archive)
        var emitted = 0
        do {
            var info = try primary.listStreaming(
                archive: archive, password: password, control: control,
                onProgress: onProgress,
                onEntry: { entry in emitted += 1; return onEntry(entry) })
            info.engine = primary.id.rawValue
            lastEngine = primary.id
            return info
        } catch {
            // Streaming cannot rewind: once entries were emitted to
            // the caller, a fallback would emit them twice. Fall
            // back only when nothing was emitted yet.
            guard emitted == 0,
                  canFallback(after: error, format: format, password: password) else {
                throw error
            }
            var lastError = error
            for next in fallbackEngines(after: primary) {
                do {
                    var info = try next.listStreaming(
                        archive: archive, password: password, control: control,
                        onProgress: onProgress, onEntry: onEntry)
                    info.engine = next.id.rawValue
                    lastEngine = next.id
                    return info
                } catch {
                    lastError = error
                    guard canFallback(after: error, format: format, password: password) else {
                        throw error
                    }
                }
            }
            throw lastError
        }
    }

    public func test(archive: URL, password: String? = nil,
                     control: JobControl? = nil,
                     onProgress: ((JobProgress) -> Void)? = nil) throws {
        let (_, engine) = try attempt(archive: archive, password: password) { engine in
            try engine.test(archive: archive, password: password,
                            control: control, onProgress: onProgress)
        }
        lastEngine = engine.id
    }

    public func extract(archive: URL, entries: [String]? = nil,
                        to destination: URL, password: String? = nil,
                        control: JobControl? = nil,
                        onProgress: ((JobProgress) -> Void)? = nil) throws {
        let (_, engine) = try attempt(archive: archive, password: password) { engine in
            try engine.extract(archive: archive, entries: entries, to: destination,
                               password: password, control: control,
                               onProgress: onProgress)
        }
        lastEngine = engine.id
    }

    /// Entry streaming stays on 7zz: XAD has no `e -so` equivalent
    /// (it only writes files), so there is nothing to route to.
    public func streamEntry(archive: URL, entry: String, password: String? = nil,
                            onChunk: (Data) -> Bool) throws -> Bool {
        try sevenZip().streamEntry(archive: archive, entry: entry,
                                   password: password, onChunk: onChunk)
    }

    // MARK: - 7zz-only operations (delegated)

    public func create(archive: URL, sources: [URL], format: String,
                       level: Int = 9, password: String? = nil,
                       splitMB: Int = 0, control: JobControl? = nil,
                       onProgress: ((JobProgress) -> Void)? = nil) throws {
        try sevenZip().create(archive: archive, sources: sources, format: format,
                              level: level, password: password, splitMB: splitMB,
                              control: control, onProgress: onProgress)
    }

    public func addEntries(archive: URL, sources: [URL], prefix: String? = nil,
                           level: Int = 9, password: String? = nil,
                           control: JobControl? = nil,
                           onProgress: ((JobProgress) -> Void)? = nil) throws {
        try sevenZip().addEntries(archive: archive, sources: sources, prefix: prefix,
                                  level: level, password: password,
                                  control: control, onProgress: onProgress)
    }

    public func removeEntries(archive: URL, entries: [String],
                              password: String? = nil,
                              control: JobControl? = nil,
                              onProgress: ((JobProgress) -> Void)? = nil) throws {
        try sevenZip().removeEntries(archive: archive, entries: entries,
                                     password: password, control: control,
                                     onProgress: onProgress)
    }

    public func renameEntries(archive: URL,
                              renames: [(old: String, new: String)],
                              password: String? = nil,
                              control: JobControl? = nil,
                              onProgress: ((JobProgress) -> Void)? = nil) throws {
        try sevenZip().renameEntries(archive: archive, renames: renames,
                                     password: password, control: control,
                                     onProgress: onProgress)
    }

    /// Conversion extracts through the router (so a legacy archive
    /// can be the source — XAD extracts it) and creates through 7zz.
    public func convert(archive: URL, to destination: URL,
                        targetFormat: String? = nil,
                        password: String? = nil,
                        control: JobControl? = nil,
                        onProgress: ((JobProgress) -> Void)? = nil) throws {
        let format = (targetFormat ?? SevenZipEngine.format(of: destination) ?? "").lowercased()
        guard format == "zip" || format == "7z" || format == "tar" else {
            throw EngineError.failed(
                exitCode: 2,
                message: "cannot convert to '\(format)' — conversion targets are ZIP, 7z and TAR (RAR cannot be created by any third-party tool)")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try extract(archive: archive, to: dir, password: password, control: control)
        let extracted = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        guard !extracted.isEmpty else {
            throw EngineError.failed(exitCode: 2,
                                     message: "nothing to convert — the archive is empty")
        }
        try sevenZip().create(archive: destination, sources: extracted, format: format,
                              level: 9, password: password, splitMB: 0,
                              control: control, onProgress: onProgress)
    }

    public func entryChecksums(archive: URL, password: String? = nil,
                               control: JobControl? = nil) throws -> [EntryChecksum] {
        try sevenZip().entryChecksums(archive: archive, password: password,
                                      control: control)
    }

    public func verify(archive: URL, entries: [String]? = nil,
                       includeSHA256: Bool = false,
                       password: String? = nil,
                       control: JobControl? = nil,
                       onProgress: ((JobProgress) -> Void)? = nil) throws -> [EntryVerification] {
        try sevenZip().verify(archive: archive, entries: entries,
                              includeSHA256: includeSHA256, password: password,
                              control: control, onProgress: onProgress)
    }
}

/// Engines that can report the binary they run (for `seekzip engines`).
protocol BinaryReporting {
    var binaryPath: String? { get }
}

/// A stand-in for an engine whose binaries are not installed (M6).
/// It reports `isAvailable == false` with the real capability matrix,
/// so `seekzip engines` can show the missing engine instead of
/// hiding it, and the router skips it. Every operation fails clearly.
public final class UnavailableEngine: ArchiveEngine, @unchecked Sendable {
    public let id: EngineID
    public let capabilities: EngineCapabilities
    public var isAvailable: Bool { false }

    public init(id: EngineID, capabilities: EngineCapabilities) {
        self.id = id
        self.capabilities = capabilities
    }

    private func unavailable() -> Error {
        EngineError.failed(
            exitCode: 2,
            message: "the \(id.rawValue) engine is not installed")
    }

    public func list(archive: URL, password: String?,
                     control: JobControl?) throws -> ArchiveInfo {
        throw unavailable()
    }

    public func listStreaming(archive: URL, password: String?,
                              control: JobControl?,
                              onProgress: ((ListingProgress) -> Void)?,
                              onEntry: (ArchiveEntry) -> Bool) throws -> ArchiveInfo {
        throw unavailable()
    }

    public func test(archive: URL, password: String?,
                     control: JobControl?,
                     onProgress: ((JobProgress) -> Void)?) throws {
        throw unavailable()
    }

    public func extract(archive: URL, entries: [String]?,
                        to destination: URL, password: String?,
                        control: JobControl?,
                        onProgress: ((JobProgress) -> Void)?) throws {
        throw unavailable()
    }
}
