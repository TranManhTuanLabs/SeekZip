import Cocoa
import Quartz
import SeekZipCore

// SeekZip Quick Look preview extension (M7).
//
// Shows an archive's entry listing in Finder (Space / Quick Look)
// without extracting anything. Listings go through the router (7zz
// first, XAD fallback), so legacy archives preview too; engine
// settings come from the shared App Group defaults (same keys as the
// app's `EngineSettings`). Images, PDFs and other single entries
// still preview with the system's own Quick Look — this extension
// previews the archive itself, not its contents.
//
// This file has never been compiled: it needs full Xcode on a Mac
// (see docs/RELEASE.md for the first-build checklist). Supported
// content types are declared in the extension's Info.plist
// (`QLSupportedContentTypes`).
final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Most entries ever shown in the preview (the full listing stays
    /// in the app, where the list is virtualised).
    private static let maxEntriesShown = 500

    private let textView = NSTextView()

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view = scrollView
    }

    func preparePreviewOfFile(at url: URL,
                              completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let text = try Self.listingText(for: url)
                DispatchQueue.main.async {
                    self.textView.string = text
                    completionHandler(nil)
                }
            } catch {
                DispatchQueue.main.async { completionHandler(error) }
            }
        }
    }

    /// One text listing: header (archive, entry count, sizes, handling
    /// engine) plus one line per entry. Runs off the main thread; the
    /// listing itself streams from the engine (M2), so a huge archive
    /// does not block on a full in-memory parse.
    private static func listingText(for url: URL) throws -> String {
        guard let router = makeRouter() else {
            throw EngineError.failed(
                exitCode: 2,
                message: "no archive engine is available (7zz and unar both missing)")
        }
        let info = try router.list(archive: url)
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(info.totalUncompressed), countStyle: .file)
        var lines = [
            "\(url.lastPathComponent)",
            "\(info.entries.count) entries · \(size) uncompressed" +
                (info.engine.map { " · engine: \($0)" } ?? ""),
            "",
        ]
        for entry in info.entries.prefix(maxEntriesShown) {
            let entrySize = ByteCountFormatter.string(
                fromByteCount: Int64(entry.size), countStyle: .file)
            lines.append("\(entry.isDirectory ? "▸" : " ") \(entry.path)  \(entrySize)")
        }
        if info.entries.count > maxEntriesShown {
            lines.append("")
            lines.append("… and \(info.entries.count - maxEntriesShown) more — open in SeekZip to browse all entries.")
        }
        return lines.joined(separator: "\n")
    }

    /// A router honouring the shared engine settings (App Group
    /// defaults, same keys as the app's `EngineSettings`).
    private static func makeRouter() -> EngineRouter? {
        guard let sevenZip = try? SevenZipEngine() else { return nil }
        let router = EngineRouter(sevenZip: sevenZip, xad: XADMasterEngine())
        let defaults = UserDefaults(suiteName: SeekZipAppGroup.suiteName) ?? .standard
        if let raw = defaults.string(forKey: SeekZipAppGroup.defaultEngineKey),
           let selection = EngineSelection(rawValue: raw) {
            router.defaultSelection = selection
        }
        if let rawOverrides = defaults.dictionary(
            forKey: SeekZipAppGroup.formatOverridesKey) as? [String: String] {
            router.overrides = rawOverrides.compactMapValues { EngineID(rawValue: $0) }
        }
        return router
    }
}
