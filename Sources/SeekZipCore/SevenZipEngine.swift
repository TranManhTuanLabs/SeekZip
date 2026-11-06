import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum EngineError: Error, CustomStringConvertible {
    case binaryNotFound
    case failed(exitCode: Int32, message: String)
    case wrongPassword
    case cancelled

    public var description: String {
        switch self {
        case .binaryNotFound: return "7zz engine binary not found"
        case .failed(let code, let msg): return "7zz exited \(code): \(msg)"
        case .wrongPassword: return "wrong password or corrupted archive"
        case .cancelled: return "listing cancelled"
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

    private func run(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        // Never let 7zz prompt on stdin (e.g. "Enter password"): with no
        // terminal attached that prompt would block forever. EOF makes it
        // fail fast instead, and callers pass -p explicitly when needed.
        // See docs/REFERENCE.md §3 (7zz CLI contract).
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Streams a listing: each entry is handed to `onEntry` as soon as
    /// its block is parsed, instead of buffering the whole `7zz` output
    /// in memory first (M2). Returning `false` from `onEntry` terminates
    /// the `7zz` process and throws `EngineError.cancelled` — no partial
    /// `ArchiveInfo` is ever returned. `onProgress` reports bytes read
    /// and entries seen after each chunk.
    ///
    /// If `7zz` exits non-zero after some entries were already emitted,
    /// the error is thrown and the collected entries are discarded: the
    /// caller must treat a thrown listing as incomplete.
    public func listStreaming(archive: URL, password: String? = nil,
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
    public func list(archive: URL, password: String? = nil) throws -> ArchiveInfo {
        try listStreaming(archive: archive, password: password) { _ in true }
    }

    /// Test integrity of the whole archive (CRC check).
    public func test(archive: URL, password: String? = nil) throws {
        var args = ["t"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        let (code, output) = try run(args)
        guard code == 0 else {
            throw EngineError.failed(exitCode: code, message: lastLine(of: output))
        }
    }

    /// Extract selected entries (or all when `entries` is nil) into
    /// `destination`, after validating every target path.
    public func extract(archive: URL, entries: [String]? = nil,
                        to destination: URL, password: String? = nil) throws {
        let info = try list(archive: archive, password: password)
        let wanted = entries.map(Set.init)
        for entry in info.entries where wanted?.contains(entry.path) ?? true {
            _ = try EntryPathSafety.destinationURL(for: entry, in: destination)
        }
        var args = ["x", "-y", "-sccUTF-8", "-o\(destination.path)"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        if let entries { args.append(contentsOf: entries) }
        let (code, output) = try run(args)
        guard code == 0 else {
            throw EngineError.failed(exitCode: code, message: lastLine(of: output))
        }
    }

    /// Create a ZIP or 7z archive. Split size in MB when > 0.
    public func create(archive: URL, sources: [URL], format: String = "zip",
                       level: Int = 9, password: String? = nil,
                       splitMB: Int = 0) throws {
        var args = ["a", "-y", "-t\(format)", "-mx=\(level)", "-mmt=on", "-sccUTF-8"]
        if format == "7z" { args.append("-mhe=on") } // encrypt file names too
        if let password { args.append("-p\(password)") }
        if splitMB > 0 { args.append("-v\(splitMB)m") }
        args.append(archive.path)
        args.append(contentsOf: sources.map(\.path))
        let (code, output) = try run(args)
        guard code == 0 else {
            throw EngineError.failed(exitCode: code, message: lastLine(of: output))
        }
    }

    private func lastLine(of output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? ""
    }
}
