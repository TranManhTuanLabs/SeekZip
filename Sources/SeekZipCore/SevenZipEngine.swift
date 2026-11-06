import Foundation

public enum EngineError: Error, CustomStringConvertible {
    case binaryNotFound
    case failed(exitCode: Int32, message: String)
    case wrongPassword

    public var description: String {
        switch self {
        case .binaryNotFound: return "7zz engine binary not found"
        case .failed(let code, let msg): return "7zz exited \(code): \(msg)"
        case .wrongPassword: return "wrong password or corrupted archive"
        }
    }
}

/// Thin streaming wrapper around the official `7zz` binary.
/// Archive bytes never pass through this process's memory: listing output
/// is the only thing read, and extraction is done by 7zz itself — but only
/// after every entry has passed EntryPathSafety.
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
        // Listing output for huge archives can be large but is text; stream
        // it through a temp file instead of a memory buffer in production
        // use — see docs/TEST-MATRIX.md case PERF-04.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public func list(archive: URL, password: String? = nil) throws -> ArchiveInfo {
        var args = ["l", "-slt", "-sccUTF-8"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        let (code, output) = try run(args)
        guard code == 0 else {
            // Header-encrypted 7z (and wrong passwords) fail listing with
            // exit code 2 and a password/headers error — that means "ask
            // for a password", not "corrupt archive". See REFERENCE.md §3.
            let lowered = output.lowercased()
            if lowered.contains("password") || lowered.contains("headers error")
                || lowered.contains("cannot open encrypted archive") {
                throw EngineError.wrongPassword
            }
            throw EngineError.failed(exitCode: code, message: lastLine(of: output))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? UInt64 ?? 0
        return ListingParser.parse(archivePath: archive.path,
                                   physicalSize: size ?? 0,
                                   text: output)
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
