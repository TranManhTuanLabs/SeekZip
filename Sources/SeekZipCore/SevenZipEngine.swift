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
        case .failed(let code, let msg): return "7zz exited \(code): \(msg)"
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

/// Thin streaming wrapper around the official `7zz` binary.
/// Archive bytes never pass through this process's memory: listing output
/// is read incrementally and parsed as it arrives (M2), and extraction is
/// done by 7zz itself — but only after every entry has passed
/// EntryPathSafety.
public final class SevenZipEngine: @unchecked Sendable {
    public let binaryURL: URL

    /// Resolution order: explicit path, app bundle Resources, PATH.
    public init(binaryPath: String? = nil) throws {
        if let binaryPath {
            binaryURL = URL(fileURLWithPath: binaryPath)
            return
        }
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            binaryURL = bundled
            return
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("7zz")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                binaryURL = candidate
                return
            }
        }
        throw EngineError.binaryNotFound
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
                     onProgress: ((JobProgress) -> Void)? = nil) throws -> (Int32, String) {
        var args = arguments
        // Switches go right after the command, before any paths: 7zz
        // parses them positionally, and a path could itself start with
        // a dash in theory.
        if onProgress != nil { args.insert("-bsp1", at: 1) }
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = args
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

    /// Lists the contents of an archive stored inside another archive
    /// (M3, TEST-MATRIX NES-01). Each element of `nestedPath` is one
    /// level. The returned `ArchiveInfo.path` is
    /// `outer!/inner!/deep` so callers can tell which level it is.
    public func listNested(archive: URL, nestedPath: [String],
                           password: String? = nil) throws -> ArchiveInfo {
        var listed = try withNestedArchive(archive: archive,
                                           nestedPath: nestedPath,
                                           password: password) { nestedURL in
            try list(archive: nestedURL, password: password)
        }
        listed.path = archive.path + "!/" + nestedPath.joined(separator: "!/")
        return listed
    }

    /// Extracts a nested archive chain to a temp dir and runs `body`
    /// with the extracted (innermost) file's URL, then removes the temp
    /// dir (M3). Each element of `nestedPath` is one level: the entry
    /// is validated with `EntryPathSafety` and must exist, be a file,
    /// and be an archive. The outer archive is never modified.
    public func withNestedArchive<T>(archive: URL, nestedPath: [String],
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
            let info = try list(archive: current, password: password)
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
                        password: password)
            current = dir.appendingPathComponent(component)
        }
        return try body(current)
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
        _ = try EntryPathSafety.destinationURL(
            for: ArchiveEntry(path: entry),
            in: FileManager.default.temporaryDirectory)
        var args = ["e", "-so", "-y", "-sccUTF-8"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        args.append(entry)

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
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break } // EOF
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
        return completed
    }

    /// Test integrity of the whole archive (CRC check).
    public func test(archive: URL, password: String? = nil,
                     control: JobControl? = nil,
                     onProgress: ((JobProgress) -> Void)? = nil) throws {
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
    /// On cancel, partially extracted entries are left in place — the
    /// job is marked cancelled and a re-run overwrites them with `-y`;
    /// deleting them would risk removing files the user already had.
    public func extract(archive: URL, entries: [String]? = nil,
                        to destination: URL, password: String? = nil,
                        control: JobControl? = nil,
                        onProgress: ((JobProgress) -> Void)? = nil) throws {
        let info = try list(archive: archive, password: password, control: control)
        let wanted = entries.map(Set.init)
        for entry in info.entries where wanted?.contains(entry.path) ?? true {
            _ = try EntryPathSafety.destinationURL(for: entry, in: destination)
        }
        try DiskSpace.require(info.totalUncompressed, at: destination)
        var args = ["x", "-y", "-sccUTF-8", "-o\(destination.path)"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        if let entries { args.append(contentsOf: entries) }
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
                       level: Int = 9, password: String? = nil,
                       splitMB: Int = 0, control: JobControl? = nil,
                       onProgress: ((JobProgress) -> Void)? = nil) throws {
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

    private func lastLine(of output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? ""
    }
}
