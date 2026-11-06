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

    private let engine: SevenZipEngine

    public init(engine: SevenZipEngine) {
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

    /// Streams an entry's bytes and returns the first lines as text.
    /// Stops at the preview limits (or at the first NUL byte, which
    /// means "binary, not text") and terminates the `7zz` process, so
    /// the rest of a huge entry is never decompressed. Lines are split
    /// on `\n` bytes before decoding, so a multi-byte UTF-8 character
    /// is never decoded half-way (the same trick as the M2 parser).
    private func streamTextPreview(archive: URL, entry: ArchiveEntry,
                                   password: String?) throws -> EntryPreview {
        var pending = Data()
        var lines: [String] = []
        var bytesRead: UInt64 = 0
        var foundNUL = false

        func appendLine(_ data: Data) {
            var line = String(decoding: data, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() } // CRLF files
            lines.append(line)
        }

        let completed = try engine.streamEntry(
            archive: archive, entry: entry.path, password: password
        ) { chunk in
            // A NUL byte means binary data, not text.
            if chunk.contains(0) { foundNUL = true; return false }
            bytesRead += UInt64(chunk.count)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                appendLine(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
                if lines.count >= Self.maxPreviewLines { return false }
            }
            // Enough bytes: stop here; the rest is never decompressed.
            // (If the entry ends exactly at the limit, `truncated` is
            // set even though nothing was missed — harmless.)
            if bytesRead >= UInt64(Self.maxPreviewBytes) { return false }
            return true
        }

        if foundNUL {
            return EntryPreview(entryPath: entry.path, kind: .binary,
                                size: entry.size, bytesRead: bytesRead,
                                quickLook: true,
                                note: "Binary file — preview it with Quick Look (Space in the app).")
        }
        // The unterminated last line, if the stream ran to the end.
        if completed, !pending.isEmpty {
            appendLine(pending)
            pending.removeAll()
        }
        let truncated = !completed
        return EntryPreview(
            entryPath: entry.path, kind: .text, size: entry.size,
            text: lines.joined(separator: "\n"),
            truncated: truncated, linesShown: lines.count,
            bytesRead: bytesRead,
            note: truncated
                ? "Showing the first \(lines.count) lines (max \(Self.maxPreviewBytes / 1024) KB) — extract the file to see the rest."
                : nil)
    }
}
