import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum EngineError: Error, CustomStringConvertible {
    case binaryNotFound
    case failed(exitCode: Int32, message: String)
    case wrongPassword
    case cancelled
    case insufficientDiskSpace(needed: UInt64, available: UInt64)

    public var description: String {
        switch self {
        case .binaryNotFound: return "7zz engine binary not found"
        // Neutral wording: `.failed` is also thrown for non-7zz
        // reasons (missing sources, Keychain errors) and by the
        // XAD engine — the message itself names the cause.
        case .failed(let code, let msg): return "engine error (exit \(code)): \(msg)"
        case .wrongPassword: return "wrong password or corrupted archive"
        case .cancelled: return "listing cancelled"
        case .insufficientDiskSpace(let needed, let available):
            return "not enough free space: need \(needed) bytes, have \(available)"
        }
    }
}

/// Progress snapshot reported while a listing streams in.
public struct ListingProgress: Sendable {
    public var bytesRead: UInt64
    public var entriesSeen: Int
}

/// Compression presets for the New Archive dialog (and the CLI's
/// `--level`): the 7-Zip levels 1/5/7/9. The default is Normal (5) —
/// 7-Zip's own default. Ultra (9) was the old default and costs
/// ~3x the time for ~1% smaller output, so it is opt-in, not the
/// default (see the 2026-11-11 benchmark: 150MB text took 163s at
/// level 9 on the VM).
public enum CompressionPreset: String, CaseIterable {
    case fast, normal, maximum, ultra
    public var level: Int {
        switch self {
        case .fast: return 1
        case .normal: return 5
        case .maximum: return 7
        case .ultra: return 9
        }
    }
    public var label: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .maximum: return "Maximum"
        case .ultra: return "Ultra"
        }
    }
    public static let `default` = CompressionPreset.normal
}

/// Thin streaming wrapper around the official `7zz` binary.
/// Archive bytes never pass through this process's memory: listing output
/// is read incrementally and parsed as it arrives (M2), and extraction is
/// done by 7zz itself — but only after every entry has passed
/// EntryPathSafety.
public final class SevenZipEngine: ArchiveEngine, @unchecked Sendable {
    public let binaryURL: URL

    public var id: EngineID { .sevenZip }

    /// The 7zz capability matrix (also used for the "not installed"
    /// placeholder in `seekzip engines`).
    public static let engineCapabilities = EngineCapabilities(
        readFormats: [
            "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst",
            "lz4", "iso", "dmg", "cab", "wim", "arj", "lzh", "msi",
            "deb", "rpm", "xar", "cpio", "chm", "nsis",
        ],
        writeFormats: ["zip", "7z", "tar", "wim", "gz", "bz2", "xz"],
        canTest: true,
        supportsEncrypted7z: true,
        supportsStreamingList: true,
        supportsEntryStreaming: true,
        notes: [
            "Creates and edits ZIP/7z/TAR; extracts ~35 formats including RAR/RAR5.",
            "Only engine with encrypted-7z (header) support and split volumes.",
        ])

    public var capabilities: EngineCapabilities { Self.engineCapabilities }

    /// The engine only exists when its binary was found (the
    /// initializer throws otherwise).
    public var isAvailable: Bool { true }

    /// Where stored passwords come from (M5, ENC-05). Defaults to the
    /// shared store — Keychain on macOS, in-memory elsewhere. Tests
    /// replace it with their own store. An explicit password passed
    /// to an operation always wins over the store.
    public var passwordStore: PasswordStoring = PasswordStore.shared

    /// The password for `archive`: the explicit one when given, else
    /// the stored one. 7-Zip has no stdin/env password channel, so
    /// the resolved password still reaches 7zz as `-p…` — the window
    /// is short and the argument vector is never logged.
    public func resolvePassword(for archive: URL,
                                explicit: String?) -> String? {
        explicit ?? passwordStore.password(for: archive.path)
    }

    /// Archive format from the file extension (`zip`, `7z`, `tar`,
    /// …), or `nil` when the extension says nothing. Used to decide
    /// which operations an archive supports before 7zz is even run.
    public static func format(of archive: URL) -> String? {
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "tar" }
        switch (archive.path as NSString).pathExtension.lowercased() {
        case "zip": return "zip"
        case "7z": return "7z"
        case "tar": return "tar"
        case "gz", "tgz": return "tar"
        case "rar": return "rar"
        case "iso": return "iso"
        case "dmg": return "dmg"
        case "wim": return "wim"
        case "cab": return "cab"
        default: return nil
        }
    }

    /// Formats `7zz` can modify in place (add/delete). Rename is
    /// narrower still (`zip`/`7z` only) — see `renameEntries`.
    /// Everything else (RAR, ISO, DMG, …) is extraction-only: 7-Zip
    /// cannot write those formats, and RAR creation is permanently
    /// out of scope (proprietary, REFERENCE.md §4).
    public static let editableFormats: Set<String> = ["zip", "7z", "tar"]

    /// Resolution order: explicit path, app bundle Resources/Helpers
    /// (M7: the packaged app stages its engines there), the
    /// well-known install dirs, then PATH (see `EngineBinarySearch`).
    public init(binaryPath: String? = nil) throws {
        if let binaryPath {
            binaryURL = URL(fileURLWithPath: binaryPath)
            return
        }
        guard let found = EngineBinarySearch.find(named: "7zz") else {
            throw EngineError.binaryNotFound
        }
        binaryURL = found
    }

    /// Runs `7zz` with a cancellable, pausable process (M4). The
    /// process is attached to `control` (if given) so `cancel()` sends
    /// SIGTERM and `pause()`/`resume()` send SIGSTOP/SIGCONT. With
    /// `onProgress`, `-bsp1` is added and the percent figures 7zz
    /// prints are reported as fractions; without it, no progress
    /// switch is added and the call behaves exactly like before.
    /// Output is kept as a 4 KB rolling tail only — callers use
    /// `lastLine(of:)` for the error text. Throws
    /// `EngineError.cancelled` when the control cancels, even if 7zz
    /// also exited non-zero.
    private func run(_ arguments: [String], control: JobControl? = nil,
                     onProgress: ((JobProgress) -> Void)? = nil,
                     workingDirectory: URL? = nil) throws -> (Int32, String) {
        var args = arguments
        // Switches go right after the command, before any paths: 7zz
        // parses them positionally, and a path could itself start with
        // a dash in theory.
        if onProgress != nil { args.insert("-bsp1", at: 1) }
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        // Never let 7zz prompt on stdin (e.g. "Enter password"): with no
        // terminal attached that prompt would block forever. EOF makes it
        // fail fast instead, and callers pass -p explicitly when needed.
        // See docs/REFERENCE.md §3 (7zz CLI contract).
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        control?.attach(process)
        defer { control?.detach() }
        try process.run()

        // POSIX read() — see listStreaming: Foundation's read helpers
        // loop until the buffer is full, which would hide progress and
        // make cancel sluggish.
        let fd = out.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65536)
        var tail = Data()
        var lastPercent: Int?
        while true {
            if control?.isCancelled == true { break }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break } // EOF
            let chunk = Data(buffer[0..<count])
            tail.append(chunk)
            if tail.count > 4096 { tail.removeFirst(tail.count - 4096) }
            if let onProgress {
                let text = String(decoding: chunk, as: UTF8.self)
                if let percent = Self.lastPercent(in: text),
                   percent != lastPercent {
                    lastPercent = percent
                    onProgress(JobProgress(fraction: Double(percent) / 100.0,
                                           message: ""))
                }
            }
        }
        if control?.isCancelled == true {
            process.terminate()
            process.waitUntilExit()
            throw EngineError.cancelled
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: tail, as: UTF8.self))
    }

    /// The last `NN%` figure in 7zz `-bsp1` output, if any.
    private static func lastPercent(in text: String) -> Int? {
        var found: Int?
        var digits = ""
        for ch in text {
            if ch.isNumber {
                digits.append(ch)
            } else {
                if ch == "%", let value = Int(digits) {
                    found = value
                }
                digits = ""
            }
        }
        return found
    }

    /// Streams a listing: each entry is handed to `onEntry` as soon as
    /// its block is parsed, instead of buffering the whole `7zz` output
    /// in memory first (M2). Returning `false` from `onEntry` terminates
    /// the `7zz` process and throws `EngineError.cancelled` — no partial
    /// `ArchiveInfo` is ever returned. `onProgress` reports bytes read
    /// and entries seen after each chunk. `control` (M4) cancels or
    /// pauses the listing the same way; a control cancel also throws
    /// `EngineError.cancelled`.
    ///
    /// If `7zz` exits non-zero after some entries were already emitted,
    /// the error is thrown and the collected entries are discarded: the
    /// caller must treat a thrown listing as incomplete.
    public func listStreaming(archive: URL, password: String? = nil,
                              control: JobControl? = nil,
                              onProgress: ((ListingProgress) -> Void)? = nil,
                              onEntry: (ArchiveEntry) -> Bool) throws -> ArchiveInfo {
        let password = resolvePassword(for: archive, explicit: password)
        var args = ["l", "-slt", "-sccUTF-8"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        control?.attach(process)
        defer { control?.detach() }
        try process.run()

        let handle = out.fileHandleForReading
        let parser = StreamingListingParser()
        var collected: [ArchiveEntry] = []
        // Rolling tail of the output, kept only to report the error when
        // 7zz exits non-zero; the full listing is never buffered.
        var tail = Data()
        var cancelled = false

        // NB: POSIX read() on the pipe's file descriptor — not
        // FileHandle.readData(ofLength:) or read(upToCount:). Both
        // Foundation methods loop until the buffer is full or EOF, so a
        // slow producer's first entries would only arrive after the
        // whole listing finished. read() returns as soon as any bytes
        // are available, which is what makes this truly streaming.
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !cancelled {
            if control?.isCancelled == true { cancelled = true; break }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break } // EOF
            let chunk = Data(buffer[0..<count])
            tail.append(chunk)
            if tail.count > 4096 { tail.removeFirst(tail.count - 4096) }
            for entry in parser.feed(chunk) {
                collected.append(entry)
                if !onEntry(entry) { cancelled = true; break }
            }
            if !cancelled {
                onProgress?(ListingProgress(bytesRead: parser.bytesRead,
                                           entriesSeen: parser.entriesSeen))
            }
        }
        // Emit entries completed by the trailing partial block, if any.
        // (Not on the cancel path: a cancelled listing reports nothing.)
        if !cancelled {
            for entry in parser.finish() {
                collected.append(entry)
                if !onEntry(entry) { cancelled = true; break }
            }
            onProgress?(ListingProgress(bytesRead: parser.bytesRead,
                                       entriesSeen: parser.entriesSeen))
        }

        if cancelled {
            process.terminate()
            process.waitUntilExit()
            throw EngineError.cancelled
        }
        process.waitUntilExit()
        let code = process.terminationStatus
        guard code == 0 else {
            // Header-encrypted 7z (and wrong passwords) fail listing with
            // exit code 2 and a password/headers error — that means "ask
            // for a password", not "corrupt archive". See REFERENCE.md §3.
            // Error output is small, so it fits in the rolling tail.
            let tailText = String(decoding: tail, as: UTF8.self).lowercased()
            if tailText.contains("password") || tailText.contains("headers error")
                || tailText.contains("cannot open encrypted archive") {
                throw EngineError.wrongPassword
            }
            throw EngineError.failed(exitCode: code, message: lastLine(of: String(decoding: tail, as: UTF8.self)))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? UInt64 ?? 0
        return ArchiveInfo(path: archive.path, format: "unknown",
                           physicalSize: size, entries: collected)
    }

    /// Collects the streamed listing into one `ArchiveInfo`. Callers that
    /// only need the full listing use this; callers that want entries as
    /// they arrive use `listStreaming` directly.
    public func list(archive: URL, password: String? = nil,
                     control: JobControl? = nil) throws -> ArchiveInfo {
        try listStreaming(archive: archive, password: password,
                          control: control) { _ in true }
    }

    /// Streams one entry's contents to `onChunk` without writing it to
    /// disk (M3 preview). Uses `7zz e -so`: bytes are read with POSIX
    /// `read()` and the process is terminated as soon as the handler
    /// returns `false`, so a 10 GB entry is never decompressed in full
    /// for a preview. Returns `true` when the entry streamed to EOF,
    /// `false` when the handler stopped it early. The entry path is
    /// validated with `EntryPathSafety` before it reaches `7zz`.
    public func streamEntry(archive: URL, entry: String,
                            password: String? = nil,
                            onChunk: (Data) -> Bool) throws -> Bool {
        let password = resolvePassword(for: archive, explicit: password)
        _ = try EntryPathSafety.destinationURL(
            for: ArchiveEntry(path: entry),
            in: FileManager.default.temporaryDirectory)
        let (completed, bytes) = try streamEntryOnce(
            archive: archive, entry: entry, password: password, onChunk: onChunk)
        if completed, bytes == 0, let alternate = Self.alternateNormalization(of: entry) {
            // `7zz e -so` with a name that matches nothing exits 0 with
            // empty output — silent. The listing can print a name in a
            // different normalization than the one stored in the
            // archive, so retry once with the alternate form (through
            // the @listfile, so both forms reach 7zz byte-exact). A
            // genuinely empty entry just streams zero bytes again,
            // which is still correct.
            let (retryCompleted, _) = try streamEntryOnce(
                archive: archive, entry: alternate, password: password, onChunk: onChunk)
            return retryCompleted
        }
        return completed
    }

    /// The alternate Unicode normalization of a path (NFC ↔ NFD), or
    /// `nil` when the path has no canonical decomposition/composition
    /// to flip (pure ASCII, or a form where flipping is a no-op).
    /// NOTE: compare UTF-8 bytes, not `String ==` — Swift string
    /// equality is canonical-equivalence-aware, so NFC and NFD forms
    /// of the same name compare equal even though their bytes differ
    /// (and 7zz matches on bytes).
    private static func alternateNormalization(of path: String) -> String? {
        let nfd = path.decomposedStringWithCanonicalMapping
        if !nfd.utf8.elementsEqual(path.utf8) { return nfd }
        let nfc = path.precomposedStringWithCanonicalMapping
        if !nfc.utf8.elementsEqual(path.utf8) { return nfc }
        return nil
    }

    /// Writes archive entry names to a temp file for 7zz's `@listfile`
    /// syntax and returns its URL, or `nil` when the names cannot live
    /// in a list file. 7zz matches entry names byte-for-byte, but
    /// macOS normalizes `Process` argument strings to NFD (decomposed)
    /// — proven by CI #128's diagnostic, where a direct `7zz e -so`
    /// with an NFC name returned content for an NFD-stored entry, which
    /// is only possible if the NFC bytes were converted to NFD before
    /// 7zz saw them. An NFC name stored in the archive can therefore
    /// never match through argv on macOS; through a list file the
    /// bytes reach 7zz verbatim (the `@path` itself is ASCII). A name
    /// containing a newline cannot live in a list file (one name per
    /// line), so those fall back to argv.
    private static func makeEntryListFile(names: [String]) throws -> URL? {
        guard !names.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seekzip-list-\(UUID().uuidString).txt")
        try names.map { $0 + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One `7zz e -so` run. Returns whether the handler consumed the
    /// entry to EOF and how many bytes it was given.
    private func streamEntryOnce(archive: URL, entry: String,
                                 password: String?,
                                 onChunk: (Data) -> Bool) throws -> (completed: Bool, bytes: UInt64) {
        var args = ["e", "-so", "-y", "-sccUTF-8"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        // The entry name goes through a @listfile, not argv (see
        // makeEntryListFile): macOS normalizes Process arguments to
        // NFD, so an NFC name stored in the archive could never match
        // through argv.
        var listFile: URL?
        if let file = try Self.makeEntryListFile(names: [entry]) {
            listFile = file
            args.append("@\(file.path)")
        } else {
            args.append(entry)
        }
        defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        // Stderr stays separate from the entry bytes: error text must
        // never leak into a preview.
        let err = Pipe()
        process.standardError = err
        try process.run()

        let fd = out.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65536)
        var completed = true
        var bytes: UInt64 = 0
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break } // EOF
            bytes += UInt64(count)
            if !onChunk(Data(buffer[0..<count])) { completed = false; break }
        }
        if !completed { process.terminate() }
        process.waitUntilExit()
        // Error output is small (a few lines), so draining it after the
        // process exits cannot block.
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let code = process.terminationStatus
        if completed {
            guard code == 0 else {
                let lowered = String(decoding: errData, as: UTF8.self).lowercased()
                if lowered.contains("password") || lowered.contains("headers error")
                    || lowered.contains("cannot open encrypted archive") {
                    throw EngineError.wrongPassword
                }
                throw EngineError.failed(exitCode: code,
                                         message: lastLine(of: String(decoding: errData, as: UTF8.self)))
            }
        }
        return (completed, bytes)
    }

    /// Test integrity of the whole archive (CRC check).
    public func test(archive: URL, password: String? = nil,
                     control: JobControl? = nil,
                     onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        var args = ["t"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        let (code, output) = try run(args, control: control,
                                     onProgress: onProgress.map { outer in
            { progress in
                outer(JobProgress(fraction: progress.fraction,
                                  message: "Testing \(archive.lastPathComponent)"))
            }
        })
        guard code == 0 else {
            throw EngineError.failed(exitCode: code, message: lastLine(of: output))
        }
    }

    /// Extract selected entries (or all when `entries` is nil) into
    /// `destination`, after validating every target path. Fails fast
    /// with `EngineError.insufficientDiskSpace` when the destination
    /// volume cannot hold the uncompressed listing (M4 precheck).
    /// Like `create`, extraction stages into a fresh directory
    /// inside the destination first, and the finished entries move
    /// into place only on success — a cancel or failure leaves no
    /// half-written file in the destination (only the staging
    /// directory, which is always removed). Previously 7zz wrote
    /// straight into the destination, so a cancelled extract left
    /// partial files behind; the XAD engine already staged this way.
    public func extract(archive: URL, entries: [String]? = nil,
                        to destination: URL, password: String? = nil,
                        control: JobControl? = nil,
                        onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        let info = try list(archive: archive, password: password, control: control)
        let wanted = entries.map(Set.init)
        for entry in info.entries where wanted?.contains(entry.path) ?? true {
            _ = try EntryPathSafety.destinationURL(for: entry, in: destination)
        }
        try DiskSpace.require(info.totalUncompressed, at: destination)
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(
            ".seekzip-7zz-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var args = ["x", "-y", "-sccUTF-8", "-o\(staging.path)"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        // Selected entry names go through a @listfile when possible:
        // macOS normalizes Process arguments to NFD, so an NFC name
        // stored in the archive could never match through argv (see
        // makeEntryListFile).
        var listFile: URL?
        if let entries, let file = try Self.makeEntryListFile(names: entries) {
            listFile = file
            args.append("@\(file.path)")
        } else if let entries {
            args.append(contentsOf: entries)
        }
        defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
        let (code, output) = try run(args, control: control,
                                     onProgress: onProgress.map { outer in
            { progress in
                outer(JobProgress(fraction: progress.fraction,
                                  message: "Extracting \(archive.lastPathComponent)"))
            }
        })
        guard code == 0 else {
            throw EngineError.failed(exitCode: code, message: lastLine(of: output))
        }
        // Move what 7zz produced into place: only the requested
        // entries are ever extracted, so everything in staging is
        // wanted. A directory entry carries its whole subtree with
        // it. When entries were requested and nothing was produced,
        // the names matched nothing — fail instead of reporting a
        // silent success (extracting an empty archive, with
        // `entries == nil`, still succeeds with nothing to move).
        let produced = try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)
        for item in produced {
            try Self.moveIntoPlace(from: item,
                                   to: destination.appendingPathComponent(item.lastPathComponent))
        }
        if entries != nil && produced.isEmpty {
            throw EngineError.failed(
                exitCode: 2,
                message: "no matching entries in \(archive.lastPathComponent)")
        }
    }

    /// Move an extracted item into its final place, merging
    /// directories: when both sides are directories, the children
    /// move one by one instead of failing on the existing directory.
    /// A file (or a type mismatch) replaces what is there, matching
    /// 7zz `-y` overwrite semantics. Existence and directory checks
    /// use attributes (not `fileExists`, which follows symlinks and
    /// misses dangling ones), so an extracted symlink is moved, not
    /// skipped.
    private static func moveIntoPlace(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let targetAttrs = try? fm.attributesOfItem(atPath: target.path)
        guard targetAttrs != nil else {
            try fm.moveItem(at: source, to: target)
            return
        }
        let targetIsDir = (targetAttrs?[.type] as? FileAttributeType) == .typeDirectory
        let sourceIsDir = ((try? fm.attributesOfItem(atPath: source.path)[.type]
            as? FileAttributeType) == .typeDirectory)
        if targetIsDir && sourceIsDir {
            let children = try fm.contentsOfDirectory(at: source,
                                                      includingPropertiesForKeys: nil)
            for child in children {
                try moveIntoPlace(from: child,
                                  to: target.appendingPathComponent(child.lastPathComponent))
            }
            return
        }
        try fm.removeItem(at: target)
        try fm.moveItem(at: source, to: target)
    }

    /// Create a ZIP or 7z archive. Split size in MB when > 0.
    ///
    /// Safe creation (M4, PERF-05): 7zz writes into a staging
    /// directory inside the destination directory first, and the
    /// finished file(s) are renamed into place only on success — a
    /// cancel or failure leaves no half-written final file, and the
    /// staging directory is always removed. The rename is on the same
    /// volume, so it is atomic; a pre-existing archive is replaced by
    /// the rename. A free-space precheck (sources' total size, a
    /// conservative estimate) runs before 7zz starts.
    public func create(archive: URL, sources: [URL], format: String = "zip",
                       level: Int = 5, password: String? = nil,
                       splitMB: Int = 0, control: JobControl? = nil,
                       onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        let needed = try DiskSpace.totalSize(of: sources)
        let parent = archive.deletingLastPathComponent()
        try DiskSpace.require(needed, at: parent)
        try FileManager.default.createDirectory(at: parent,
                                                withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            ".seekzip-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let stagedArchive = staging.appendingPathComponent(archive.lastPathComponent)
        var args = ["a", "-y", "-t\(format)", "-mx=\(level)", "-mmt=on", "-sccUTF-8"]
        if format == "7z" { args.append("-mhe=on") } // encrypt file names too
        if let password { args.append("-p\(password)") }
        if splitMB > 0 { args.append("-v\(splitMB)m") }
        // Keep 7zz from swallowing the staging directory when a source
        // is the destination directory itself.
        args.append("-x!\(staging.lastPathComponent)")
        args.append(stagedArchive.path)
        args.append(contentsOf: sources.map(\.path))
        let (code, output) = try run(args, control: control,
                                     onProgress: onProgress.map { outer in
            { progress in
                outer(JobProgress(fraction: progress.fraction,
                                  message: "Creating \(archive.lastPathComponent)"))
            }
        })
        guard code == 0 else {
            throw EngineError.failed(exitCode: code, message: lastLine(of: output))
        }

        // Move every file 7zz produced into place. Non-split: exactly
        // the archive. Split: the `.001`, `.002`, … volumes. POSIX
        // rename() overwrites an existing file atomically on the same
        // volume; the staging directory is in the destination
        // directory, so this never crosses volumes.
        let produced = try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)
        guard !produced.isEmpty else {
            throw EngineError.failed(exitCode: 2,
                                     message: "7zz produced no output for \(archive.lastPathComponent)")
        }
        for file in produced {
            let target = parent.appendingPathComponent(file.lastPathComponent)
            guard rename(file.path, target.path) == 0 else {
                throw EngineError.failed(
                    exitCode: 2,
                    message: "could not move \(file.lastPathComponent) into place: \(String(cString: strerror(errno)))")
            }
        }
    }

    // MARK: - M5: editing, conversion, verification
    //
    // `EntryChecksum` / `EntryVerification` live at top level in
    // ArchiveEngine.swift (M6) so the protocol can use them.

    /// The shared edit path (M5, REFERENCE.md §3.3): every mutation
    /// of an existing archive works on a temp copy in the same
    /// directory and only replaces the original with a POSIX rename
    /// after the edited copy lists cleanly. A failure or cancel
    /// removes the temp copy and leaves the original byte-for-byte
    /// untouched — a crash or full disk mid-edit can never destroy
    /// the only copy. `extraBytes` is what the edit adds (0 for
    /// remove/rename), for the free-space precheck.
    private func editArchive(archive: URL, format: String,
                             password: String?,
                             control: JobControl? = nil,
                             extraBytes: UInt64 = 0,
                             body: (URL) throws -> Void) throws {
        _ = format // format was validated by the caller; kept for clarity
        let archiveSize = (try? FileManager.default.attributesOfItem(
            atPath: archive.path))?[.size] as? UInt64 ?? 0
        try DiskSpace.require(archiveSize + extraBytes,
                              at: archive.deletingLastPathComponent())
        let parent = archive.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(
            ".\(archive.lastPathComponent).seekzip-tmp-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: archive, to: temp)
        do {
            try body(temp)
            // Sanity: the edited copy must still list cleanly before
            // it is allowed to replace the original.
            _ = try list(archive: temp, password: password, control: control)
            guard rename(temp.path, archive.path) == 0 else {
                throw EngineError.failed(
                    exitCode: 2,
                    message: "could not replace \(archive.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Joins an optional internal prefix with a relative entry name
    /// (`prefix` + `/` + `name`, or just `name`).
    private func prefixedName(_ prefix: String?, _ name: String) -> String {
        guard let prefix, !prefix.isEmpty else { return name }
        return prefix + "/" + name
    }

    /// Adds files/folders to an existing ZIP, 7z or TAR archive (M5).
    /// Each source becomes an entry under `prefix` (when given):
    /// a file keeps its basename, a folder keeps its name and its
    /// contents' relative paths. Sources are staged in a temp dir and
    /// added with `7zz a` from there, so the stored names are exactly
    /// the entry names. The original is only replaced via the
    /// temp-copy path in `editArchive`.
    public func addEntries(archive: URL, sources: [URL],
                           prefix: String? = nil, level: Int = 5,
                           password: String? = nil,
                           control: JobControl? = nil,
                           onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        guard let format = Self.format(of: archive),
              Self.editableFormats.contains(format) else {
            throw EngineError.failed(
                exitCode: 2,
                message: "cannot add entries to this archive format (\(Self.format(of: archive) ?? "unknown")) — only ZIP, 7z and TAR can be edited")
        }
        if let prefix {
            _ = try EntryPathSafety.destinationURL(
                for: ArchiveEntry(path: prefix),
                in: FileManager.default.temporaryDirectory)
        }
        guard !sources.isEmpty else {
            throw EngineError.failed(exitCode: 2, message: "nothing to add")
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var stagedNames: [String] = []
        var addedBytes: UInt64 = 0
        for source in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
                throw EngineError.failed(exitCode: 2,
                                         message: "source not found: \(source.path)")
            }
            if !isDir.boolValue {
                let entryName = prefixedName(prefix, source.lastPathComponent)
                _ = try EntryPathSafety.destinationURL(
                    for: ArchiveEntry(path: entryName),
                    in: fm.temporaryDirectory)
                let target = staging.appendingPathComponent(entryName)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                addedBytes += (try fm.attributesOfItem(atPath: source.path))[.size] as? UInt64 ?? 0
                stagedNames.append(entryName)
                continue
            }
            guard let enumerator = fm.enumerator(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []) else { continue }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                let relative = String(file.path.dropFirst(source.path.count + 1))
                let entryName = prefixedName(
                    prefix, source.lastPathComponent + "/" + relative)
                _ = try EntryPathSafety.destinationURL(
                    for: ArchiveEntry(path: entryName),
                    in: fm.temporaryDirectory)
                let target = staging.appendingPathComponent(entryName)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: target)
                addedBytes += UInt64(values.fileSize ?? 0)
                stagedNames.append(entryName)
            }
        }
        guard !stagedNames.isEmpty else {
            throw EngineError.failed(exitCode: 2,
                                     message: "nothing to add (sources are empty)")
        }

        try editArchive(archive: archive, format: format, password: password,
                        control: control, extraBytes: addedBytes) { temp in
            var args = ["a", "-y", "-t\(format)", "-mmt=on", "-sccUTF-8"]
            if format == "zip" || format == "7z" { args.append("-mx=\(level)") }
            if format == "7z", password != nil { args.append("-mhe=on") }
            if let password { args.append("-p\(password)") }
            args.append(temp.path)
            args.append(contentsOf: stagedNames)
            let (code, output) = try run(args, control: control,
                                         onProgress: onProgress.map { outer in
                { progress in
                    outer(JobProgress(fraction: progress.fraction,
                                      message: "Adding to \(archive.lastPathComponent)"))
                }
            }, workingDirectory: staging)
            guard code == 0 else {
                throw EngineError.failed(exitCode: code, message: lastLine(of: output))
            }
        }
    }

    /// Removes entries from an existing ZIP, 7z or TAR archive (M5).
    /// Names must exist in the listing; anything else fails before
    /// the archive is touched. The original is only replaced via the
    /// temp-copy path in `editArchive`.
    public func removeEntries(archive: URL, entries: [String],
                              password: String? = nil,
                              control: JobControl? = nil,
                              onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        guard let format = Self.format(of: archive),
              Self.editableFormats.contains(format) else {
            throw EngineError.failed(
                exitCode: 2,
                message: "cannot remove entries from this archive format (\(Self.format(of: archive) ?? "unknown")) — only ZIP, 7z and TAR can be edited")
        }
        guard !entries.isEmpty else {
            throw EngineError.failed(exitCode: 2, message: "nothing to remove")
        }
        let info = try list(archive: archive, password: password, control: control)
        for name in entries {
            _ = try EntryPathSafety.destinationURL(
                for: ArchiveEntry(path: name),
                in: FileManager.default.temporaryDirectory)
            guard info.entries.contains(where: { $0.path == name }) else {
                throw EngineError.failed(exitCode: 2,
                                         message: "entry not found in archive: \(name)")
            }
        }
        try removeEntriesOnce(archive: archive, format: format, entries: entries,
                              password: password, control: control, onProgress: onProgress)
        // Verify the entries are really gone: `7zz d` exits 0 even when
        // a name matches nothing, and a name in the wrong Unicode
        // normalization silently matches nothing. Retry once with the
        // alternate normalization for whatever is still there.
        var remaining = try remainingEntries(archive: archive, names: entries,
                                             password: password, control: control)
        if !remaining.isEmpty {
            var retry: [String] = []
            for stored in remaining {
                if let requested = entries.first(where: { $0 == stored }),
                   let alternate = Self.alternateNormalization(of: requested) {
                    retry.append(alternate)
                }
            }
            if !retry.isEmpty {
                try removeEntriesOnce(archive: archive, format: format, entries: retry,
                                      password: password, control: control, onProgress: onProgress)
                remaining = try remainingEntries(archive: archive, names: entries,
                                                 password: password, control: control)
            }
        }
        guard remaining.isEmpty else {
            throw EngineError.failed(exitCode: 2,
                                     message: "entry not found in archive: \(remaining.joined(separator: ", "))")
        }
    }

    /// Stored names (from a fresh listing) that still match any of
    /// `names`. Swift `==` is normalization-insensitive, so an NFC
    /// stored name matches an NFD request and vice versa.
    private func remainingEntries(archive: URL, names: [String], password: String?,
                                  control: JobControl?) throws -> [String] {
        try list(archive: archive, password: password, control: control)
            .entries.map(\.path).filter { names.contains($0) }
    }

    /// One `7zz d` pass over a temp copy (see `editArchive`). Entry
    /// names go through a @listfile when possible — see
    /// `makeEntryListFile`.
    private func removeEntriesOnce(archive: URL, format: String, entries: [String],
                                   password: String?, control: JobControl?,
                                   onProgress: ((JobProgress) -> Void)?) throws {
        try editArchive(archive: archive, format: format, password: password,
                        control: control) { temp in
            var args = ["d", "-y", "-sccUTF-8"]
            if let password { args.append("-p\(password)") }
            args.append(temp.path)
            var listFile: URL?
            if let file = try Self.makeEntryListFile(names: entries) {
                listFile = file
                args.append("@\(file.path)")
            } else {
                args.append(contentsOf: entries)
            }
            defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
            let (code, output) = try run(args, control: control,
                                         onProgress: onProgress.map { outer in
                { progress in
                    outer(JobProgress(fraction: progress.fraction,
                                      message: "Removing from \(archive.lastPathComponent)"))
                }
            })
            guard code == 0 else {
                throw EngineError.failed(exitCode: code, message: lastLine(of: output))
            }
        }
    }

    /// Renames entries in a ZIP or 7z archive (M5, `7zz rn`). TAR has
    /// no rename support in 7-Zip — the error says so and suggests
    /// remove + add instead. Old names must exist, new names must be
    /// safe paths that do not already exist in the archive.
    public func renameEntries(archive: URL,
                              renames: [(old: String, new: String)],
                              password: String? = nil,
                              control: JobControl? = nil,
                              onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        guard let format = Self.format(of: archive),
              format == "zip" || format == "7z" else {
            throw EngineError.failed(
                exitCode: 2,
                message: "rename is only supported for ZIP and 7z archives (format: \(Self.format(of: archive) ?? "unknown")) — for TAR, remove the entry and add it back under the new name")
        }
        guard !renames.isEmpty else {
            throw EngineError.failed(exitCode: 2, message: "nothing to rename")
        }
        let info = try list(archive: archive, password: password, control: control)
        var pairs: [String] = []
        for (old, new) in renames {
            _ = try EntryPathSafety.destinationURL(
                for: ArchiveEntry(path: new),
                in: FileManager.default.temporaryDirectory)
            guard info.entries.contains(where: { $0.path == old }) else {
                throw EngineError.failed(exitCode: 2,
                                         message: "entry not found in archive: \(old)")
            }
            guard !info.entries.contains(where: { $0.path == new }) else {
                throw EngineError.failed(exitCode: 2,
                                         message: "an entry named \(new) already exists")
            }
            pairs.append(contentsOf: [old, new])
        }
        try renameEntriesOnce(archive: archive, format: format, pairs: pairs,
                              password: password, control: control, onProgress: onProgress)
        // Verify the old names are really gone (same silent-no-match
        // caveat as removeEntries); retry once with the alternate
        // normalization of the old names that are still there.
        let olds = renames.map { $0.old }
        var remaining = try remainingEntries(archive: archive, names: olds,
                                             password: password, control: control)
        if !remaining.isEmpty {
            var retryPairs: [String] = []
            for stored in remaining {
                if let pair = renames.first(where: { $0.old == stored }),
                   let alternate = Self.alternateNormalization(of: pair.old) {
                    retryPairs.append(contentsOf: [alternate, pair.new])
                }
            }
            if !retryPairs.isEmpty {
                try renameEntriesOnce(archive: archive, format: format, pairs: retryPairs,
                                      password: password, control: control, onProgress: onProgress)
                remaining = try remainingEntries(archive: archive, names: olds,
                                                 password: password, control: control)
            }
        }
        guard remaining.isEmpty else {
            throw EngineError.failed(exitCode: 2,
                                     message: "entry not found in archive: \(remaining.joined(separator: ", "))")
        }
    }

    /// One `7zz rn` pass over a temp copy (see `editArchive`). The
    /// pairs are flat [old, new, old, new, …] and go through a
    /// @listfile when possible (one name per line) — same NFD reason
    /// as removeEntries (see `makeEntryListFile`).
    private func renameEntriesOnce(archive: URL, format: String, pairs: [String],
                                   password: String?, control: JobControl?,
                                   onProgress: ((JobProgress) -> Void)?) throws {
        try editArchive(archive: archive, format: format, password: password,
                        control: control) { temp in
            var args = ["rn", "-y", "-sccUTF-8"]
            if let password { args.append("-p\(password)") }
            args.append(temp.path)
            var listFile: URL?
            if let file = try Self.makeEntryListFile(names: pairs) {
                listFile = file
                args.append("@\(file.path)")
            } else {
                args.append(contentsOf: pairs)
            }
            defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
            let (code, output) = try run(args, control: control,
                                         onProgress: onProgress.map { outer in
                { progress in
                    outer(JobProgress(fraction: progress.fraction,
                                      message: "Renaming in \(archive.lastPathComponent)"))
                }
            })
            guard code == 0 else {
                throw EngineError.failed(exitCode: code, message: lastLine(of: output))
            }
        }
    }

    /// Converts an archive to another format (M5): extracts everything
    /// to a temp dir, then re-creates it with `create` (which does its
    /// own temp staging + atomic rename + free-space precheck). Entry
    /// names and file timestamps survive where the target format
    /// allows; the source archive is never modified. Targets are ZIP,
    /// 7z and TAR only — converting TO RAR is impossible for any
    /// third-party tool (proprietary format), and converting FROM an
    /// encrypted archive needs its password. An encrypted source stays
    /// encrypted in the target when a password is given.
    public func convert(archive: URL, to destination: URL,
                        targetFormat: String? = nil,
                        password: String? = nil,
                        control: JobControl? = nil,
                        onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        let format = (targetFormat ?? Self.format(of: destination) ?? "").lowercased()
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
        try extract(archive: archive, to: dir, password: password,
                    control: control)
        let extracted = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        guard !extracted.isEmpty else {
            throw EngineError.failed(exitCode: 2,
                                     message: "nothing to convert — the archive is empty")
        }
        try create(archive: destination, sources: extracted, format: format,
                   password: password, control: control, onProgress: onProgress)
    }

    /// CRC-32 of every entry, straight from the listing (M5). Cheap —
    /// no entry bytes are read. Folders and some solid-7z entries
    /// have no CRC (`nil`).
    public func entryChecksums(archive: URL, password: String? = nil,
                               control: JobControl? = nil) throws -> [EntryChecksum] {
        let info = try list(archive: archive, password: password, control: control)
        return info.entries.map {
            EntryChecksum(path: $0.path, crc: $0.crc, size: $0.size)
        }
    }

    /// Verifies entries one by one (M5, TEST-MATRIX COR-02): each
    /// entry is streamed through `streamEntry` and hashed (CRC-32,
    /// plus SHA-256 when `includeSHA256` is set), then compared with
    /// the CRC from the listing. A bad entry is reported as
    /// `.mismatch` and the rest are still checked — verification
    /// never stops at the first failure. 7-Zip itself reports a CRC
    /// failure as exit code 2 after streaming the corrupt bytes, so
    /// a stream error with bytes already hashed is also a mismatch;
    /// an entry that could not be streamed at all is `.error`, and
    /// an entry with no listing CRC is `.unknown`. Directories are
    /// skipped (nothing to hash).
    public func verify(archive: URL, entries: [String]? = nil,
                       includeSHA256: Bool = false,
                       password: String? = nil,
                       control: JobControl? = nil,
                       onProgress: ((JobProgress) -> Void)? = nil) throws -> [EntryVerification] {
        let password = resolvePassword(for: archive, explicit: password)
        let info = try list(archive: archive, password: password, control: control)
        let wanted = entries.map(Set.init)
        let targets = info.entries.filter {
            !$0.isDirectory && (wanted?.contains($0.path) ?? true)
        }
        var results: [EntryVerification] = []
        for (index, entry) in targets.enumerated() {
            var crc = CRC32.Accumulator()
            var sha = SHA256.Accumulator()
            var streamedBytes: UInt64 = 0
            var streamError: Error?
            do {
                _ = try streamEntry(archive: archive, entry: entry.path,
                                    password: password) { chunk in
                    crc.update(chunk)
                    if includeSHA256 { sha.update(chunk) }
                    streamedBytes += UInt64(chunk.count)
                    return true
                }
            } catch {
                streamError = error
            }
            let actual = crc.hex()
            let expected = entry.crc?.uppercased()
            let status: EntryVerification.Status
            let message: String?
            if let streamError {
                if streamedBytes > 0, let expected {
                    status = actual == expected ? .error : .mismatch
                    message = String(describing: streamError)
                } else {
                    status = .error
                    message = String(describing: streamError)
                }
            } else if let expected {
                status = actual == expected ? .ok : .mismatch
                message = status == .mismatch
                    ? "CRC mismatch: listing says \(expected), entry hashes to \(actual)"
                    : nil
            } else {
                status = .unknown
                message = "no CRC in listing — streamed \(streamedBytes) bytes"
            }
            results.append(EntryVerification(
                entryPath: entry.path, status: status,
                expectedCRC: expected, actualCRC: actual,
                sha256: (includeSHA256 && streamError == nil)
                    ? sha.finalizeHex() : nil,
                message: message))
            onProgress?(JobProgress(
                fraction: Double(index + 1) / Double(max(targets.count, 1)),
                message: "Verifying \(entry.path)"))
        }
        return results
    }

    private func lastLine(of output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? ""
    }
}

// MARK: - BinaryReporting (for `seekzip engines`)

extension SevenZipEngine: BinaryReporting {
    var binaryPath: String? { binaryURL.path }
}
