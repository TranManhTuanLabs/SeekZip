import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// XADMaster fallback engine (M6) — a subprocess wrapper around the
/// `lsar` (list) and `unar` (extract) CLI tools from The Unarchiver.
///
/// This is deliberately NOT a link against the ObjC XADMaster library:
/// the library cannot build on the Linux VM and is out of scope; the
/// CLI tools are separate executables, which also keeps the LGPL
/// boundary simplest (REFERENCE.md §4) and the crash/isolation
/// properties of the 7zz wrapper.
///
/// Public CLI contracts used (lsar(1)/unar(1) man pages):
/// - `lsar -j [-p password] <archive>` prints one JSON document:
///   `{"lsarFormatName": "Zip", "lsarContents": [{ "XADFileName": …,
///   "XADFileSize": …, "XADIsDirectory": …, "XADIsEncrypted": …,
///   "XADCompressionName": …, "XADLastModificationDate": …,
///   "XADFileNameEncoding": … }]}`. `-e` selects a filename encoding
///   (auto-detected when omitted).
/// - `unar -D -f -q -k skip [-p password] [-e encoding] -o <dir>
///   <archive> [files…]` extracts selected files; `-D` never creates
///   a containing directory, `-f` overwrites without prompting,
///   `-k skip` discards Mac resource forks.
///
/// Limits, surfaced clearly (REFERENCE.md §2.3):
/// - Extraction/listing only — no creation or editing, ever.
/// - 7z with encryption is NOT supported (route stays on 7zz).
/// - Listing is buffered, not streamed: `lsar -j` emits one JSON
///   document, so `listStreaming` collects it first and then feeds
///   entries to `onEntry`. Legacy archives are small; the streaming
///   invariant (ARCHITECTURE §7.1) is waived here and only here.
/// - `test` has no native command: it extracts to a temp dir and
///   discards it (a full integrity read, like 7zz `t`).
/// - Entry streaming is not supported (`unar` only writes files);
///   the protocol default throws a clear error.
public final class XADMasterEngine: ArchiveEngine, @unchecked Sendable {
    public var id: EngineID { .xad }

    public var capabilities: EngineCapabilities {
        EngineCapabilities(
            readFormats: [
                // Legacy long tail only XAD covers well.
                "sit", "sitx", "zoo", "arc", "cpt", "dd", "pit", "ace",
                "sea",
                // Overlapping formats (7zz first, XAD as fallback).
                "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso",
                "dmg", "cab", "wim", "arj", "lzh", "lha", "nsis", "exe",
            ],
            writeFormats: [],
            canTest: true,
            supportsEncrypted7z: false,
            supportsStreamingList: false,
            supportsEntryStreaming: false,
            notes: [
                "Extraction and listing only — never creates or edits archives.",
                "7z with encryption is not supported; encrypted 7z stays on the 7zz engine.",
                "Best filename-encoding recovery (Shift-JIS/GBK); the detected encoding is kept in ArchiveEntry.filenameEncoding.",
            ])
    }

    public var isAvailable: Bool { lsarURL != nil && unarURL != nil }

    public let lsarURL: URL?
    public let unarURL: URL?

    /// Where stored passwords come from (M5, ENC-05) — same store as
    /// the 7zz engine. Tests replace it with their own store.
    public var passwordStore: PasswordStoring = PasswordStore.shared

    public func resolvePassword(for archive: URL,
                                explicit: String?) -> String? {
        explicit ?? passwordStore.password(for: archive.path)
    }

    /// Resolution order: explicit paths, Homebrew / system locations.
    /// Never throws: when the tools are missing the engine simply
    /// reports `isAvailable == false` and the router skips it. An
    /// explicit path that is not an executable file counts as missing.
    public init(lsarPath: String? = nil, unarPath: String? = nil) {
        if let lsarPath {
            let url = URL(fileURLWithPath: lsarPath)
            lsarURL = FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        } else {
            lsarURL = Self.findBinary(named: "lsar")
        }
        if let unarPath {
            let url = URL(fileURLWithPath: unarPath)
            unarURL = FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        } else {
            unarURL = Self.findBinary(named: "unar")
        }
    }

    private static func findBinary(named name: String) -> URL? {
        // M7: the packaged app bundles lsar/unar in Resources/Helpers.
        if let bundled = BundledEngines.url(named: name) { return bundled }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func requireBinaries() throws -> (lsar: URL, unar: URL) {
        guard let lsarURL, let unarURL else {
            throw EngineError.failed(
                exitCode: 2,
                message: "the XAD engine is not installed (lsar/unar not found — install The Unarchiver's command-line tools or `brew install unar`)")
        }
        return (lsarURL, unarURL)
    }

    // MARK: - Listing

    /// One entry of `lsar -j` output. Every field is optional in
    /// practice: lsar emits per-format keys, and a missing key means
    /// "unknown", never "fail the whole listing".
    private struct LsarEntry: Decodable {
        var XADFileName: String?
        var XADFileSize: UInt64?
        var XADCompressedSize: UInt64?
        var XADIsDirectory: Bool?
        var XADIsEncrypted: Bool?
        var XADIsLink: Bool?
        var XADCompressionName: String?
        var XADLastModificationDate: String?
        var XADFileNameEncoding: String?
    }

    private struct LsarListing: Decodable {
        var lsarFormatName: String?
        var lsarContents: [LsarEntry]?
    }

    /// `lsar` dates look like "2021-06-15 12:00:00 +0000"; older
    /// builds omit the zone. Both parse, anything else is nil.
    static func parseLsarDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    public func list(archive: URL, password: String? = nil,
                     control: JobControl? = nil) throws -> ArchiveInfo {
        let password = resolvePassword(for: archive, explicit: password)
        let (lsar, _) = try requireBinaries()
        var args = ["-j"]
        if let password { args.append("-p\(password)") }
        args.append(archive.path)
        let (code, output, errorText) = try run(binary: lsar, args: args,
                                                control: control)
        guard code == 0 else {
            let lowered = errorText.lowercased()
            if lowered.contains("password") || lowered.contains("encrypted") {
                throw EngineError.wrongPassword
            }
            throw EngineError.failed(exitCode: code,
                                     message: lastLine(of: errorText.isEmpty ? output : errorText))
        }
        guard let data = output.data(using: .utf8) else {
            throw EngineError.failed(exitCode: 2, message: "lsar output was not UTF-8")
        }
        let listing: LsarListing
        do {
            listing = try JSONDecoder().decode(LsarListing.self, from: data)
        } catch {
            throw EngineError.failed(exitCode: 2,
                                     message: "could not parse lsar JSON output: \(error)")
        }
        let entries = (listing.lsarContents ?? []).compactMap { raw -> ArchiveEntry? in
            guard let path = raw.XADFileName, !path.isEmpty else { return nil }
            return ArchiveEntry(
                path: path,
                isDirectory: raw.XADIsDirectory ?? false,
                size: raw.XADFileSize ?? 0,
                packedSize: raw.XADCompressedSize ?? 0,
                modified: Self.parseLsarDate(raw.XADLastModificationDate),
                method: raw.XADCompressionName,
                isEncrypted: raw.XADIsEncrypted ?? false,
                // Symlinks are marked with a unix-style mode string so
                // ArchiveEntry.isSymlink (and EntryPathSafety) see them.
                attributes: (raw.XADIsLink ?? false) ? "lrwxrwxrwx" : nil,
                filenameEncoding: raw.XADFileNameEncoding)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? UInt64 ?? 0
        return ArchiveInfo(path: archive.path,
                           format: (listing.lsarFormatName ?? "unknown").lowercased(),
                           physicalSize: size, entries: entries)
    }

    /// Buffered listing (see header): collect via `list`, then feed
    /// entries to `onEntry` in order. Returning `false` throws
    /// `EngineError.cancelled` — there is no live process left to
    /// terminate, the JSON document is already in hand.
    public func listStreaming(archive: URL, password: String? = nil,
                              control: JobControl? = nil,
                              onProgress: ((ListingProgress) -> Void)? = nil,
                              onEntry: (ArchiveEntry) -> Bool) throws -> ArchiveInfo {
        let info = try list(archive: archive, password: password, control: control)
        var bytesRead: UInt64 = 0
        var entriesSeen = 0
        for entry in info.entries {
            if control?.isCancelled == true { throw EngineError.cancelled }
            bytesRead += UInt64(entry.path.utf8.count) + entry.size
            if !onEntry(entry) { throw EngineError.cancelled }
            entriesSeen += 1
            onProgress?(ListingProgress(bytesRead: bytesRead,
                                        entriesSeen: entriesSeen))
        }
        return info
    }

    // MARK: - Test

    /// XAD has no `t` command: integrity is checked by extracting
    /// everything to a temp dir and discarding it. A failure there
    /// means the archive does not extract cleanly.
    public func test(archive: URL, password: String? = nil,
                     control: JobControl? = nil,
                     onProgress: ((JobProgress) -> Void)? = nil) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try extract(archive: archive, entries: nil, to: dir,
                    password: password, control: control, onProgress: onProgress)
    }

    // MARK: - Extraction

    /// Extract selected entries (or all when `entries` is nil) into
    /// `destination`, through the same safety path as 7zz (M4/M5):
    /// list first, validate every entry with `EntryPathSafety`,
    /// free-space precheck, then `unar` into a staging directory
    /// inside the destination and move the results into place only
    /// on success. A failed or cancelled extract removes the staging
    /// directory, so it leaves no partial output behind.
    public func extract(archive: URL, entries: [String]? = nil,
                        to destination: URL, password: String? = nil,
                        control: JobControl? = nil,
                        onProgress: ((JobProgress) -> Void)? = nil) throws {
        let password = resolvePassword(for: archive, explicit: password)
        let (_, unar) = try requireBinaries()
        let info = try list(archive: archive, password: password, control: control)
        let wanted = entries.map(Set.init)
        let targets = info.entries.filter { wanted?.contains($0.path) ?? true }
        for entry in targets {
            _ = try EntryPathSafety.destinationURL(for: entry, in: destination)
        }
        try DiskSpace.require(info.totalUncompressed, at: destination)
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)

        // The filename encoding lsar recovered for this archive, if
        // any — pass it to unar so extraction decodes names the same
        // way the listing did.
        let encoding = info.entries.compactMap(\.filenameEncoding).first

        let staging = destination.appendingPathComponent(
            ".seekzip-xad-tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        do {
            var args = ["-D", "-f", "-q", "-k", "skip"]
            if let password { args.append("-p\(password)") }
            if let encoding { args.append("-e\(encoding)") }
            args.append("-o\(staging.path)")
            args.append(archive.path)
            if let entries { args.append(contentsOf: entries) }
            let (code, _, errorText) = try run(binary: unar, args: args,
                                               control: control)
            guard code == 0 else {
                let lowered = errorText.lowercased()
                if lowered.contains("password") || lowered.contains("encrypted") {
                    throw EngineError.wrongPassword
                }
                throw EngineError.failed(exitCode: code,
                                         message: lastLine(of: errorText))
            }
            // Move the extracted tree into place. Only the top-level
            // components of wanted entries move — a directory entry
            // carries its whole subtree with it, and anything unar
            // produced that was not requested (e.g. AppleDouble
            // leftovers) stays in staging and is deleted with it.
            let topLevel = Set(targets.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
            for component in topLevel {
                let source = staging.appendingPathComponent(component)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw EngineError.failed(
                        exitCode: 2,
                        message: "unar did not produce expected entry: \(component)")
                }
                let target = destination.appendingPathComponent(component)
                try moveIntoPlace(from: source, to: target)
            }
            onProgress?(JobProgress(fraction: 1.0,
                                    message: "Extracted \(archive.lastPathComponent)"))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try? FileManager.default.removeItem(at: staging)
    }

    /// Moves `source` onto `target`, merging directories: a rename
    /// when the target does not exist yet, a recursive merge when
    /// both are directories (the destination may already hold files),
    /// and a rename-overwrite for files. All moves stay on the same
    /// volume (staging lives inside the destination directory).
    private func moveIntoPlace(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let targetExists = fm.fileExists(atPath: target.path, isDirectory: &isDir)
        guard targetExists else {
            guard rename(source.path, target.path) == 0 else {
                throw EngineError.failed(
                    exitCode: 2,
                    message: "could not move \(source.lastPathComponent) into place: \(String(cString: strerror(errno)))")
            }
            return
        }
        var sourceIsDir: ObjCBool = false
        _ = fm.fileExists(atPath: source.path, isDirectory: &sourceIsDir)
        guard isDir.boolValue, sourceIsDir.boolValue else {
            // File onto file (or file onto dir): rename overwrites files.
            guard rename(source.path, target.path) == 0 else {
                throw EngineError.failed(
                    exitCode: 2,
                    message: "could not move \(source.lastPathComponent) into place: \(String(cString: strerror(errno)))")
            }
            return
        }
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try moveIntoPlace(from: child,
                              to: target.appendingPathComponent(child.lastPathComponent))
        }
        try? fm.removeItem(at: source)
    }

    // MARK: - Subprocess

    /// Runs one `lsar`/`unar` invocation: stdin is `/dev/null` (a
    /// prompt must fail fast, never block), stdout and stderr are
    /// separate pipes (error text must never leak into a listing),
    /// output is read with POSIX `read()` so cancel stays prompt
    /// (M2), and only a 4 KB tail of stderr is kept. Returns
    /// (exitCode, stdout, stderrTail). Throws `EngineError.cancelled`
    /// when the control cancels.
    private func run(binary: URL, args: [String],
                     control: JobControl? = nil) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        control?.attach(process)
        defer { control?.detach() }
        try process.run()

        // Drain stdout fully (lsar's JSON is one document), keeping
        // it all — legacy archives are small; the streaming invariant
        // is waived for XAD (see header). Stderr is tail-only.
        let outFD = out.fileHandleForReading.fileDescriptor
        let errFD = err.fileHandleForReading.fileDescriptor
        var stdoutData = Data()
        var errTail = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var outOpen = true
        var errOpen = true
        while outOpen || errOpen {
            if control?.isCancelled == true { break }
            var fds = [
                pollfd(fd: outOpen ? outFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errOpen ? errFD : -1, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            for (index, fd) in [outFD, errFD].enumerated() {
                let rev = fds[index].revents
                // POLLIN or POLLHUP: try to read — on HUP the read
                // still returns buffered bytes first, then 0.
                guard rev & Int16(POLLIN) != 0 || rev & Int16(POLLHUP) != 0 else {
                    if rev & Int16(POLLERR) != 0 {
                        if index == 0 { outOpen = false } else { errOpen = false }
                    }
                    continue
                }
                let count = read(fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    if index == 0 { outOpen = false } else { errOpen = false }
                } else if count == 0 {
                    if index == 0 { outOpen = false } else { errOpen = false }
                } else if index == 0 {
                    stdoutData.append(contentsOf: buffer[0..<count])
                } else {
                    errTail.append(contentsOf: buffer[0..<count])
                    if errTail.count > 4096 { errTail.removeFirst(errTail.count - 4096) }
                }
            }
        }
        if control?.isCancelled == true {
            process.terminate()
            process.waitUntilExit()
            throw EngineError.cancelled
        }
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: errTail, as: UTF8.self))
    }

    private func lastLine(of output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? ""
    }
}

// MARK: - BinaryReporting (for `seekzip engines`)

extension XADMasterEngine: BinaryReporting {
    var binaryPath: String? { unarURL?.path }
}
