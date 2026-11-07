import Foundation

/// What kind of preview an archive entry gets (M3).
public enum PreviewKind: String, Codable, Sendable {
    /// Plain text (or sniffed-as-text): first lines are shown inline.
    case text
    /// Image: shown by Quick Look, not rendered by SeekZip itself.
    case image
    /// PDF: shown by Quick Look.
    case pdf
    /// Another archive: open it to browse its contents (see `listNested`).
    case archive
    /// A folder: open it, there is nothing to preview.
    case directory
    /// Binary data: shown by Quick Look, not dumped as text.
    case binary
    /// Encrypted and no password was supplied.
    case encrypted
}

/// The result of previewing one entry. `Codable` so the CLI prints the
/// same shape as `--json`.
public struct EntryPreview: Codable, Sendable {
    public var entryPath: String
    public var kind: PreviewKind
    public var size: UInt64
    /// Text content, only for `.text`. Never the whole file: capped at
    /// `PreviewProvider.maxPreviewBytes` / `maxPreviewLines`.
    public var text: String?
    public var truncated: Bool
    public var linesShown: Int
    public var bytesRead: UInt64
    /// True when the entry is best previewed with Quick Look (Space in
    /// the app / Finder) rather than inline.
    public var quickLook: Bool
    public var note: String?

    public init(entryPath: String, kind: PreviewKind, size: UInt64,
                text: String? = nil, truncated: Bool = false,
                linesShown: Int = 0, bytesRead: UInt64 = 0,
                quickLook: Bool = false, note: String? = nil) {
        self.entryPath = entryPath
        self.kind = kind
        self.size = size
        self.text = text
        self.truncated = truncated
        self.linesShown = linesShown
        self.bytesRead = bytesRead
        self.quickLook = quickLook
        self.note = note
    }
}

/// Builds previews of archive entries without extracting them and
/// without loading them into memory (M3).
///
/// Text is streamed out of `7zz` (`e -so`) and read in chunks, so a
/// 10 GB entry is never decompressed in full for a preview: reading
/// stops as soon as the preview limits are reached and the `7zz`
/// process is terminated. Images, PDFs and other binary content are
/// never read at all — the preview only says "use Quick Look".
///
/// M7: the provider now takes any `ArchiveEngine` (the router), not
/// just 7zz. When the handling engine cannot stream a single entry
/// (XAD: `unar` only writes files), the preview falls back to
/// extracting just that entry to a temp dir and reading the capped
/// head of the extracted file — see `extractTextPreview`. If that
/// fails too, the original streaming error is reported.
public struct PreviewProvider: Sendable {
    /// Most preview bytes ever read from one entry (64 KiB).
    public static let maxPreviewBytes: Int = 64 * 1024
    /// Most preview lines ever shown for one entry.
    public static let maxPreviewLines: Int = 200

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "xml", "html",
        "htm", "css", "js", "ts", "swift", "c", "h", "cpp", "hpp", "m",
        "mm", "py", "rb", "sh", "bash", "zsh", "log", "csv", "tsv",
        "ini", "toml", "plist", "rs", "go", "java", "kt", "sql",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif",
        "bmp", "webp", "svg", "ico",
    ]

    private let engine: any ArchiveEngine

    public init(engine: any ArchiveEngine) {
        self.engine = engine
    }

    /// Decides the preview kind from the entry alone, without reading
    /// any content. Unknown extensions start as `.binary` and may be
    /// upgraded to `.text` by sniffing in `preview(_:entry:password:)`.
    public static func kind(for entry: ArchiveEntry) -> PreviewKind {
        if entry.isDirectory { return .directory }
        if entry.isArchive { return .archive }
        let ext = (entry.path as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        return .binary
    }

    /// Previews one entry of an archive. The entry must come from a
    /// listing of `archive` (its size, encryption flag and attributes
    /// decide the kind); the archive itself is never extracted.
    public func preview(archive: URL, entry: ArchiveEntry,
                        password: String? = nil) throws -> EntryPreview {
        if entry.isDirectory {
            return EntryPreview(entryPath: entry.path, kind: .directory,
                                size: entry.size,
                                note: "Folders cannot be previewed — open the folder to see its contents.")
        }
        if entry.isEncrypted && password == nil {
            return EntryPreview(entryPath: entry.path, kind: .encrypted,
                                size: entry.size,
                                note: "This entry is encrypted — provide its password to preview it.")
        }
        switch Self.kind(for: entry) {
        case .image:
            return EntryPreview(entryPath: entry.path, kind: .image,
                                size: entry.size, quickLook: true,
                                note: "Image — preview it with Quick Look (Space in the app).")
        case .pdf:
            return EntryPreview(entryPath: entry.path, kind: .pdf,
                                size: entry.size, quickLook: true,
                                note: "PDF — preview it with Quick Look (Space in the app).")
        case .archive:
            return EntryPreview(entryPath: entry.path, kind: .archive,
                                size: entry.size,
                                note: "Nested archive — open it to browse its contents.")
        case .text, .binary:
            return try streamTextPreview(archive: archive, entry: entry,
                                         password: password)
        case .directory, .encrypted:
            // Handled above; kept for exhaustiveness.
            return EntryPreview(entryPath: entry.path, kind: .directory,
                                size: entry.size)
        }
    }

    /// Previews an entry that lives inside a nested archive chain
    /// (M3): the chain is extracted to a temp dir, the entry is
    /// previewed from the extracted file, and the temp dir is removed.
    public func previewNested(archive: URL, nestedPath: [String],
                              entry: ArchiveEntry,
                              password: String? = nil) throws -> EntryPreview {
        try engine.withNestedArchive(archive: archive, nestedPath: nestedPath,
                                     password: password) { nestedURL in
            try preview(archive: nestedURL, entry: entry)
        }
    }

    /// Accumulates the head of one entry's bytes into preview lines.
    /// Shared by the streaming path (7zz `e -so`) and the extract
    /// fallback (M7: engines that cannot stream, e.g. XAD), so both
    /// apply exactly the same caps and sniffing rules.
    private struct TextHead {
        var lines: [String] = []
        var pending = Data()
        var bytesRead: UInt64 = 0
        var foundNUL = false

        /// Feeds one chunk; returns false when the caller should stop
        /// (limit reached or a NUL byte seen). Lines are split on `\n`
        /// bytes before decoding, so a multi-byte UTF-8 character is
        /// never decoded half-way (the same trick as the M2 parser).
        mutating func feed(_ chunk: Data) -> Bool {
            // A NUL byte means binary data, not text.
            if chunk.contains(0) { foundNUL = true; return false }
            bytesRead += UInt64(chunk.count)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                appendLine(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
                if lines.count >= PreviewProvider.maxPreviewLines { return false }
            }
            // Enough bytes: stop here; the rest is never decompressed.
            // (If the entry ends exactly at the limit, `truncated` is
            // set even though nothing was missed — harmless.)
            if bytesRead >= UInt64(PreviewProvider.maxPreviewBytes) { return false }
            return true
        }

        mutating func appendLine(_ data: Data) {
            var line = String(decoding: data, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() } // CRLF files
            lines.append(line)
        }

        /// The unterminated last line, only when the source ran to
        /// the end.
        mutating func finish(completed: Bool) {
            if completed, !pending.isEmpty {
                appendLine(pending)
                pending.removeAll()
            }
        }

        /// The verdict for a text head. `viaExtract` notes that the
        /// bytes came from a temporary extraction, not a stream.
        func result(for entry: ArchiveEntry, truncated: Bool,
                    viaExtract: Bool = false) -> EntryPreview {
            if foundNUL {
                return EntryPreview(entryPath: entry.path, kind: .binary,
                                    size: entry.size, bytesRead: bytesRead,
                                    quickLook: true,
                                    note: "Binary file — preview it with Quick Look (Space in the app).")
            }
            var note: String?
            if truncated {
                note = "Showing the first \(lines.count) lines (max \(PreviewProvider.maxPreviewBytes / 1024) KB) — extract the file to see the rest."
            }
            if viaExtract {
                let fallback = "Previewed by extracting this entry to a temporary location (this archive's engine cannot stream single entries)."
                note = note.map { "\($0) \(fallback)" } ?? fallback
            }
            return EntryPreview(
                entryPath: entry.path, kind: .text, size: entry.size,
                text: lines.joined(separator: "\n"),
                truncated: truncated, linesShown: lines.count,
                bytesRead: bytesRead, note: note)
        }
    }

    /// Streams an entry's bytes and returns the first lines as text.
    /// Stops at the preview limits (or at the first NUL byte, which
    /// means "binary, not text") and terminates the `7zz` process, so
    /// the rest of a huge entry is never decompressed.
    ///
    /// M7: when the handling engine cannot stream the entry at all
    /// (XAD has no `e -so` equivalent), falls back to
    /// `extractTextPreview`. If that fails too, the original streaming
    /// error is the one thrown — the extract error never masks it.
    private func streamTextPreview(archive: URL, entry: ArchiveEntry,
                                   password: String?) throws -> EntryPreview {
        var head = TextHead()
        do {
            let completed = try engine.streamEntry(
                archive: archive, entry: entry.path, password: password
            ) { chunk in head.feed(chunk) }
            head.finish(completed: completed)
            return head.result(for: entry, truncated: !completed)
        } catch let streamError {
            do {
                return try extractTextPreview(archive: archive, entry: entry,
                                              password: password)
            } catch {
                throw streamError
            }
        }
    }

    /// M7 fallback for engines that cannot stream a single entry:
    /// extracts just this entry to a temp dir and reads the capped
    /// head of the extracted file with the same rules as the streaming
    /// path. The entry path is resolved through `EntryPathSafety`, so
    /// a hostile name cannot escape the temp dir, and the temp dir is
    /// removed afterwards. The extraction itself goes through the
    /// routed engine, so XAD-only archives preview here; a huge entry
    /// is still only read up to the preview limits (the file on disk
    /// is the extracted entry, not a full in-memory copy).
    private func extractTextPreview(archive: URL, entry: ArchiveEntry,
                                    password: String?) throws -> EntryPreview {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("seekzip-preview-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try engine.extract(archive: archive, entries: [entry.path],
                           to: tempRoot, password: password,
                           control: nil, onProgress: nil)
        let fileURL = try EntryPathSafety.destinationURL(for: entry, in: tempRoot)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw EngineError.failed(
                exitCode: 2,
                message: "preview: entry '\(entry.path)' was not extracted")
        }
        var head = TextHead()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var completed = true
        while true {
            guard let chunk = try handle.read(upToCount: 8192),
                  !chunk.isEmpty else { break }
            if !head.feed(chunk) { completed = false; break }
        }
        head.finish(completed: completed)
        return head.result(for: entry, truncated: !completed, viaExtract: true)
    }
}
