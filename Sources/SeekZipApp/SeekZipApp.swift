import SwiftUI
import UniformTypeIdentifiers
import QuickLookUI
import SeekZipCore

// SeekZipApp — SwiftUI frontend skeleton (v0.1).
// Open an archive → browse its entries → extract selected.
// Preview, tabs, queue and Finder extensions land in later milestones;
// all real work goes through SeekZipCore so the GUI stays thin.
//
// M5 edit wiring (code only — NOT compiled by SwiftPM yet: it needs
// full Xcode for SwiftUIMacros, and the M7 Xcode project is where this
// file first builds): Add/Remove/Rename/Convert/Verify call the core
// edit operations (temp-copy + atomic replace, per-entry CRC verify),
// and the list shows each entry's CRC from the listing. Passwords come
// from the Keychain store when the user saved them; the CLI/MCP use
// SEEKZIP_PASSWORD or the stored password, never a `-p` argument.
//
// M6 engine wiring (code only, same caveat): `EngineSettings` holds
// the default engine and per-format overrides in UserDefaults (the
// Quick Look / Finder extensions read the same keys in M7); listings
// go through the router (7zz first, XAD fallback), the status line
// shows which engine handled the archive, and Convert uses the
// router so a legacy archive (e.g. StuffIt) can be the source.
// Preview and edits stay on 7zz (entry streaming and writing are
// 7zz-only — XAD is extraction-only).

/// M7: opening an archive from Finder (double-click, or the Finder
/// Sync extension's "Open with SeekZip") delivers its URL through the
/// app delegate; the browser picks it up via notification.
final class SeekZipAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .seekZipOpenArchive, object: url)
    }
}

extension Notification.Name {
    static let seekZipOpenArchive = Notification.Name("seekzip.openArchive")
    /// Menu-bar commands (see `SeekZipApp.commands`): the App struct
    /// posts these; BrowserView performs them. Same pattern as the
    /// Finder-open notification above — the menu lives outside the
    /// view, so notifications are the thinnest bridge.
    static let seekZipOpenArchiveRequest = Notification.Name("seekzip.openArchiveRequest")
    static let seekZipNewArchiveRequest = Notification.Name("seekzip.newArchiveRequest")
    static let seekZipExtractSelectedRequest = Notification.Name("seekzip.extractSelectedRequest")
    static let seekZipVerifyRequest = Notification.Name("seekzip.verifyRequest")
    static let seekZipConvertRequest = Notification.Name("seekzip.convertRequest")
    static let seekZipAddFilesRequest = Notification.Name("seekzip.addFilesRequest")
    static let seekZipRemoveSelectedRequest = Notification.Name("seekzip.removeSelectedRequest")
    static let seekZipQuickLookRequest = Notification.Name("seekzip.quickLookRequest")
}

@main
struct SeekZipApp: App {
    @NSApplicationDelegateAdaptor(SeekZipAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .windowStyle(.titleBar)
        // Menu bar (HIG: the menu is the primary discovery mechanism
        // — users look there before anywhere else). Before this, the
        // app had no commands at all and the status line's "⌘O" was
        // a lie. ⌘N stays "New Window" (SwiftUI default), so New
        // Archive takes ⌘⇧N, the usual "New <thing>" slot.
        .commands {
            CommandGroup(before: .newItem) {
                Button("Open Archive…") {
                    NotificationCenter.default.post(name: .seekZipOpenArchiveRequest, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("New Archive…") {
                    NotificationCenter.default.post(name: .seekZipNewArchiveRequest, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Archive") {
                Button("Extract Selected") {
                    NotificationCenter.default.post(name: .seekZipExtractSelectedRequest, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("Quick Look") {
                    NotificationCenter.default.post(name: .seekZipQuickLookRequest, object: nil)
                }
                Button("Add Files…") {
                    NotificationCenter.default.post(name: .seekZipAddFilesRequest, object: nil)
                }
                Divider()
                Button("Verify") {
                    NotificationCenter.default.post(name: .seekZipVerifyRequest, object: nil)
                }
                Button("Convert…") {
                    NotificationCenter.default.post(name: .seekZipConvertRequest, object: nil)
                }
                Divider()
                Button("Remove Selected", role: .destructive) {
                    NotificationCenter.default.post(name: .seekZipRemoveSelectedRequest, object: nil)
                }
            }
        }
    }
}

/// M6: engine settings (code only — NOT compiled by SwiftPM yet).
/// The default engine and per-format overrides live in the App Group
/// shared defaults (M7), so the app and its extensions share one
/// source of truth (the Quick Look / Finder extensions read the same
/// keys); without a packaged App Group (development builds) they fall
/// back to the standard defaults. The group itself must be created in
/// the Apple Developer account first — see `docs/RELEASE.md`.
final class EngineSettings: ObservableObject {
    static let shared = EngineSettings()

    /// Shared defaults: the App Group suite when available, plain
    /// standard defaults otherwise.
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: SeekZipAppGroup.suiteName) ?? .standard
    }

    /// Legacy formats the settings sheet offers an override for.
    static let overridableFormats = [
        "sit", "sitx", "arj", "lzh", "zoo", "arc", "cpt", "dd", "pit", "ace",
    ]

    @Published var defaultEngine: EngineSelection {
        didSet { Self.sharedDefaults.set(defaultEngine.rawValue, forKey: SeekZipAppGroup.defaultEngineKey) }
    }
    @Published var formatOverrides: [String: EngineID] {
        didSet {
            Self.sharedDefaults.set(formatOverrides.mapValues(\.rawValue),
                                      forKey: SeekZipAppGroup.formatOverridesKey)
        }
    }

    init() {
        let rawDefault = Self.sharedDefaults.string(forKey: SeekZipAppGroup.defaultEngineKey)
            ?? EngineSelection.auto.rawValue
        self.defaultEngine = EngineSelection(rawValue: rawDefault) ?? .auto
        let rawOverrides = Self.sharedDefaults.dictionary(forKey: SeekZipAppGroup.formatOverridesKey)
            as? [String: String] ?? [:]
        self.formatOverrides = rawOverrides.compactMapValues { EngineID(rawValue: $0) }
    }

    /// A router wired with these settings (fresh each call — cheap).
    func makeRouter() -> EngineRouter? {
        guard let sevenZip = try? SevenZipEngine() else { return nil }
        let router = EngineRouter(sevenZip: sevenZip, xad: XADMasterEngine())
        router.defaultSelection = defaultEngine
        router.overrides = formatOverrides
        return router
    }
}

/// M6: engine settings sheet (code only). Default-engine picker plus
/// one override row per legacy format; "Automatic" in a row means "no
/// override — follow the default".
struct EngineSettingsView: View {
    @ObservedObject var settings: EngineSettings

    var body: some View {
        Form {
            Section("Default engine") {
                Picker("Engine", selection: $settings.defaultEngine) {
                    Text("Automatic (7zz first, XAD fallback)").tag(EngineSelection.auto)
                    Text("7-Zip (7zz)").tag(EngineSelection.sevenZip)
                    Text("XADMaster (lsar/unar)").tag(EngineSelection.xad)
                }
                .pickerStyle(.radioGroup)
                Text("Automatic tries 7zz first and falls back to XAD when 7zz fails or returns nothing. Legacy formats (StuffIt, Zoo, …) go to XAD first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Per-format override") {
                ForEach(EngineSettings.overridableFormats, id: \.self) { format in
                    Picker(format.uppercased(), selection: binding(for: format)) {
                        Text("Automatic").tag(nil as EngineID?)
                        Text("7zz").tag(EngineID.sevenZip as EngineID?)
                        Text("xad").tag(EngineID.xad as EngineID?)
                    }
                }
                Button("Reset overrides") { settings.formatOverrides = [:] }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    private func binding(for format: String) -> Binding<EngineID?> {
        Binding(
            get: { settings.formatOverrides[format] },
            set: { newValue in
                if let newValue { settings.formatOverrides[format] = newValue }
                else { settings.formatOverrides.removeValue(forKey: format) }
            })
    }
}

/// Settings sheet: engine settings plus About (app version + GitHub link).
struct SettingsView: View {
    @ObservedObject var settings: EngineSettings

    var body: some View {
        TabView {
            EngineSettingsView(settings: settings)
                .tabItem { Label("Engines", systemImage: "gearshape") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 460, minHeight: 380)
    }
}

/// About: what SeekZip is, its version, and where its source lives.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SeekZip")
                .font(.largeTitle)
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("Browse and preview archives before extracting, extract only what you need, and create ZIP and 7z archives — free, native for Apple Silicon.")
            Link("SeekZip on GitHub", destination: URL(string: "https://github.com/TranManhTuanLabs/SeekZip")!)
            Text("Free and open source. Report issues and request features on GitHub.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

/// Lock-guarded URL list for the async drop loader: the
/// `NSItemProvider` completion is @Sendable, so a captured `var`
/// would not compile cleanly under Swift 6 checking.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    func append(_ url: URL) { lock.lock(); _urls.append(url); lock.unlock() }
}

/// List sort order (MacPacker/Finder offer sortable columns; the
/// flat List gets a menu picker instead — same function, less chrome).
private enum EntrySortOrder: String, CaseIterable {
    case archive = "Archive order"
    case name = "Name"
    case size = "Size"
    case date = "Date"
}

/// Stream one entry's bytes to a file in `tempDir`, chunk by chunk
/// (the whole file never sits in RAM), and return the file URL.
/// On any failure the function throws and the caller never receives
/// the URL, so a partial file in the temp dir cannot be mistaken for
/// a complete one (the OS purges the temp dir).
func streamOneEntry(router: EngineRouter, archive: URL, entry: String,
                    password: String?, fileName: String,
                    in tempDir: URL) throws -> URL {
    let dest = tempDir.appendingPathComponent(fileName)
    guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
        throw EngineError.failed(exitCode: 3, message: "Cannot create temp file for \(entry)")
    }
    guard let handle = FileHandle(forWritingAtPath: dest.path) else {
        throw EngineError.failed(exitCode: 3, message: "Cannot open temp file for \(entry)")
    }
    defer { try? handle.close() }
    let ok = try router.streamEntry(archive: archive, entry: entry,
                                    password: password) { chunk in
        handle.write(chunk)
        return true
    }
    guard ok else {
        throw EngineError.failed(exitCode: 3, message: "Entry is empty: \(entry)")
    }
    return dest
}

/// Walk the nested-archive chain, streaming each level to a temp
/// file, and return the innermost archive URL (the original URL when
/// `nestedPath` is empty). Intermediate files get a unique name that
/// keeps the original extension, so an engine that sniffs by
/// extension still recognises the format — and so a level never
/// truncates the file the next level reads from (two levels can share
/// a base name).
func resolveNestedArchive(archiveURL: URL, nestedPath: [String],
                          password: String?) throws -> URL {
    guard !nestedPath.isEmpty else { return archiveURL }
    guard let router = EngineSettings.shared.makeRouter() else {
        throw EngineError.failed(exitCode: 3, message: "No engine available")
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("seekzip-nested-\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    var currentArchive = archiveURL
    for nestedEntry in nestedPath {
        let ext = URL(fileURLWithPath: nestedEntry).pathExtension
        let uniqueName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        currentArchive = try streamOneEntry(router: router, archive: currentArchive,
                                            entry: nestedEntry, password: password,
                                            fileName: uniqueName, in: tempDir)
    }
    return currentArchive
}

/// Stream one (file) entry to a temp file, walking the nested chain
/// first. The returned file keeps the entry's real name, so the
/// default app / Quick Look see the right extension. Temp files stay
/// in the temp dir (the OS purges them); the opened app may keep the
/// file open, so they are not deleted on quit.
func streamEntryToTempFile(archiveURL: URL, nestedPath: [String],
                           entry: ArchiveEntry, password: String?) throws -> URL {
    let resolved = try resolveNestedArchive(archiveURL: archiveURL,
                                            nestedPath: nestedPath,
                                            password: password)
    guard let router = EngineSettings.shared.makeRouter() else {
        throw EngineError.failed(exitCode: 3, message: "No engine available")
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("seekzip-open-\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return try streamOneEntry(router: router, archive: resolved,
                              entry: entry.path, password: password,
                              fileName: entry.name, in: tempDir)
}

/// Extract one entry (a file, or a whole directory subtree) to a
/// fresh temp dir and return the extracted item's URL. Used by
/// drag-out: Finder asks for the file only when the drop lands, so
/// nothing is copied up front.
func extractEntryToTemp(archiveURL: URL, nestedPath: [String],
                        entry: ArchiveEntry, password: String?) throws -> URL {
    let resolved = try resolveNestedArchive(archiveURL: archiveURL,
                                            nestedPath: nestedPath,
                                            password: password)
    guard let router = EngineSettings.shared.makeRouter() else {
        throw EngineError.failed(exitCode: 3, message: "No engine available")
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("seekzip-drag-\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try router.extract(archive: resolved, entries: [entry.path],
                       to: tempDir, password: password)
    return tempDir.appendingPathComponent(entry.path)
}

/// Native Quick Look (QLPreviewPanel) for one entry: the entry is
/// streamed to a temp file, then the system panel shows it (images,
/// PDFs, text — whatever the system can preview, including archives
/// via SeekZip's own Quick Look extension). Triggered from the
/// context menu, the Archive menu, and Space (Finder-style — Space
/// used to toggle the inline text preview instead). The panel is
/// shown programmatically, so the responder-chain
/// `acceptsPreviewPanelControl` dance is not needed.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var itemURL: URL?
    /// The archive-relative path of the entry currently shown (or
    /// being shown). Only trusted together with `isVisible`, so a
    /// stale path after the panel closes cannot block a later
    /// Quick Look.
    private var shownEntryPath: String?

    func show(url: URL, entryPath: String) {
        itemURL = url
        shownEntryPath = entryPath
        // shared() returns an optional in the current SDK — unwrap
        // it; if there is no panel (headless run), there is nothing
        // to show.
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// True when the panel is currently visible showing this entry —
    /// used to ignore repeat triggers (e.g. a held Space key) that
    /// would otherwise re-extract the same entry over and over.
    func isShowing(entryPath: String) -> Bool {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return false }
        return shownEntryPath == entryPath
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        itemURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let itemURL else { return nil }
        let item: QLPreviewItem = itemURL as NSURL
        return item
    }
}

struct BrowserView: View {
    @State private var archiveURL: URL?
    @State private var info: ArchiveInfo?
    @State private var selection = Set<String>()
    @State private var status = "Open an archive to begin (⌘O)"
    @State private var filter = ""
    @State private var sortOrder = EntrySortOrder.archive
    @State private var dropTargeted = false
    // Password prompt for encrypted archives (see `openArchive`):
    // the sheet asks once, saves to the Keychain, and retries.
    @State private var showPasswordPrompt = false
    @State private var passwordInput = ""
    @State private var passwordPromptWrong = false
    @State private var pendingPasswordURL: URL?
    // M3: where we are inside nested archives, and the Space preview.
    @State private var nestedPath: [String] = []
    @State private var preview: EntryPreview?
    @State private var showPreview = false
    // M4: the persistent job queue (batch extract/create/test).
    // Code only — NOT compiled by SwiftPM yet: it needs full Xcode
    // for SwiftUIMacros, and the M7 Xcode project is where this file
    // first builds. Jobs run on a background Task; pause/resume/cancel
    // go through JobQueue, and the list survives app relaunch.
    @State private var queueJobs: [JobRecord] = []
    @State private var queue: JobQueue?
    // M5: rename target for the selected entry, and verify results.
    @State private var renameTo = ""
    @State private var verifySummary: String?
    // M6: engine settings (default engine + per-format overrides)
    // and the settings sheet. Listings go through the router.
    @StateObject private var engineSettings = EngineSettings.shared
    @State private var showSettings = false

    private var shownEntries: [ArchiveEntry] {
        guard let info else { return [] }
        let filtered: [ArchiveEntry]
        if filter.isEmpty { filtered = info.entries }
        else { filtered = info.entries.filter { $0.path.localizedCaseInsensitiveContains(filter) } }
        switch sortOrder {
        case .archive:
            return filtered
        case .name:
            return filtered.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        case .size:
            return filtered.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.size > $1.size
            }
        case .date:
            return filtered.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                switch ($0.modified, $1.modified) {
                case (nil, nil): return $0.path < $1.path
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return a > b
                }
            }
        }
    }

    // The body used to be one giant expression (VStack + List +
    // toolbar + all modifiers), and the Release compiler gave up
    // type-checking it: "unable to type-check this expression in
    // reasonable time" (SeekZipApp.swift:454). The big pieces live
    // in their own declarations now, so each is type-checked on
    // its own; `body` only assembles them.
    private var renameRow: some View {
        // Rename row: the only inline editing control left at the
        // top. Every other action lives in the native toolbar
        // (`.toolbar` on this VStack), the menu bar, or the
        // context menu, so the top of the window is one clean
        // strip instead of two rows of plain buttons.
        HStack {
            TextField("New name", text: $renameTo)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button("Rename") { renameSelected() }
                .disabled(selection.count != 1 || renameTo.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var fileList: some View {
        List(shownEntries, selection: $selection) { entry in
            HStack {
                Image(systemName: entry.isDirectory ? "folder"
                    : entry.isArchive ? "archivebox" : "doc")
                if entry.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.path)
                Spacer()
                // M5: CRC-32 from the listing (— when the format
                // does not report one); `verify` re-checks it.
                Text(entry.crc ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size),
                                               countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .tag(entry.path)
            // The whole row is the hit target, not just the
            // text: without a content shape, SwiftUI only
            // hit-tests the text and icons, so double-clicking
            // the empty space between the name (left) and the
            // CRC/size (right) did nothing. This also makes
            // drag-out work across the row.
            .contentShape(Rectangle())
            // Double-click opens: drill into a nested archive,
            // open a file in its default app (folders do nothing
            // — the list is flat, there is no folder to enter).
            .onTapGesture(count: 2) { openSelected(entry) }
            // NOTE: no `.onHover` selection here, on purpose.
            // Hover used to move the selection while browsing,
            // but that mutated the selection (and re-rendered
            // the row) right as the user clicked, so clicks
            // landed only sometimes — the redraw could swallow
            // the click. Selection now changes only on click
            // and arrow keys, like Finder/Keka/BetterZip; the
            // preview follows that selection.
            // Drag out to Finder: the entry is promised, not
            // copied up front — Finder asks for its bytes only
            // when the drop lands (see `dragItemProvider`).
            .onDrag {
                guard let archiveURL else { return NSItemProvider() }
                return dragItemProvider(for: entry, archiveURL: archiveURL)
            } preview: {
                // Custom drag preview: the default one snapshots
                // the row in its selected state (white text)
                // without the selection background, so the name
                // came out unreadable white-on-light. An explicit
                // chip keeps the text primary-coloured on a
                // material background in both light and dark mode.
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? "folder"
                        : entry.isArchive ? "archivebox" : "doc")
                    Text(entry.path)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            // Right-click menu: the same actions as the toolbar,
            // for the row under the cursor.
            .contextMenu {
                Button("Open") { selection = [entry.path]; openSelected(entry) }
                Button("Preview") { selection = [entry.path]; togglePreview() }
                Button("Quick Look") { selection = [entry.path]; quickLookSelected() }
                    .disabled(entry.isDirectory)
                Button("Extract Selected") { selection = [entry.path]; extractSelected() }
                Button("Copy Path") { copyEntryPath(entry) }
                Divider()
                Button("Remove Selected", role: .destructive) { selection = [entry.path]; removeSelected() }
            }
        }
        // Space opens Quick Look for the selected entry (the
        // native QLPreviewPanel, same as the context-menu
        // Quick Look) — Finder-style. The single-key form
        // takes no argument, so repeats from a held key are
        // filtered inside `quickLookSelected()` instead (it
        // ignores the trigger while the panel already shows
        // this entry). The inline text preview is still on
        // the context menu ("Preview") and follows the
        // selection while open.
        .onKeyPress(.space) {
            quickLookSelected()
            return .handled
        }
        // Return opens the selected entry (same as double-click),
        // so opening is never mouse-only (HIG).
        .onKeyPress(.return) {
            if let selected = selection.first,
               let entry = info?.entries.first(where: { $0.path == selected }) {
                openSelected(entry)
            }
            return .handled
        }
        // Preview follows the selection (click or arrow keys)
        // while the preview panel is open.
        // (Zero-parameter form: the one-parameter `onChange`
        // action is deprecated in macOS 14.)
        .onChange(of: selection) {
            if showPreview { loadPreview() }
        }
    }

    private var statusLine: some View {
        // M6: the status line names the engine that handled the
        // archive (`ArchiveInfo.engine`, stamped by the router).
        Text(status + (info?.engine.map { " · engine: \($0)" } ?? ""))
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { openArchive() } label: {
                Label("Open Archive", systemImage: "folder")
            }
            .help("Open an archive…")
        }
        ToolbarItem(placement: .navigation) {
            Button { createNewArchive() } label: {
                Label("New Archive", systemImage: "doc.badge.plus")
            }
            .help("Create a new archive…")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { extractSelected() } label: {
                Label("Extract", systemImage: "square.and.arrow.down")
            }
            .disabled(selection.isEmpty)
            .help("Extract the selected entries")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { addFiles() } label: {
                Label("Add Files", systemImage: "plus.square")
            }
            .disabled(archiveURL == nil)
            .help("Add files to this archive")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { quickLookSelected() } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .disabled(selection.isEmpty)
            .help("Quick Look the selected entry")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { verifyArchive() } label: {
                Label("Verify", systemImage: "checkmark.shield")
            }
            .disabled(archiveURL == nil)
            .help("Verify the archive's integrity")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { convertArchive() } label: {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(archiveURL == nil)
            .help("Convert this archive to another format")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Sort", selection: $sortOrder) {
                ForEach(EntrySortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
            // Settings is a popover, not a sheet: a popover
            // dismisses when the user clicks outside it (or
            // presses Esc), so Settings never traps the user
            // behind a modal that only Esc can close.
            .popover(isPresented: $showSettings) {
                SettingsView(settings: engineSettings)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            renameRow

            if let verifySummary {
                Text(verifySummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }

            if let warning = info.flatMap({ EntryPathSafety.bombWarning(for: $0) }) {
                Text("⚠️ \(warning)")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }

            fileList

            // M3: breadcrumb for nested archives.
            if !nestedPath.isEmpty {
                HStack {
                    Button("‹ Back") { goBack() }
                    Text(nestedPath.joined(separator: " › "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            // M3: inline preview panel (Space toggles it).
            if showPreview {
                Divider()
                previewPanel
                    .frame(maxHeight: 220)
            }

            // M4: queue panel — batch jobs with pause/resume/cancel.
            if !queueJobs.isEmpty {
                Divider()
                queuePanel
            }

            Divider()
            statusLine
        }
        .frame(minWidth: 640, minHeight: 420)
        // The window title is the open archive's name (Finder-like);
        // the search field lives in the toolbar via `.searchable`.
        .navigationTitle(archiveURL?.lastPathComponent ?? "SeekZip")
        .searchable(text: $filter, prompt: "Filter entries")
        // Native toolbar (replaces the two hand-made button rows):
        // icon buttons with labels, grouped leading/trailing the
        // way macOS apps do it. The search field (`.searchable`)
        // and the sort picker sit in the same strip.
        .toolbar { mainToolbar }
        .sheet(isPresented: $showPasswordPrompt) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Password required").font(.headline)
                Text(pendingPasswordURL?.lastPathComponent ?? "This archive")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if passwordPromptWrong {
                    Text("Wrong password — try again.")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                SecureField("Password", text: $passwordInput)
                    .textFieldStyle(.roundedBorder)
                Text("The password is saved in your Keychain for this archive, so previews and extracts work without asking again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showPasswordPrompt = false; passwordInput = "" }
                    Button("Open") { submitPassword() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(minWidth: 320)
        }
        // Drag files in from Finder: an archive opens, files are
        // added to the open archive, or start a new archive.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(4)
            }
        }
        // M7: an archive opened from Finder (double-click / extension)
        // arrives via the app delegate as a notification.
        .onReceive(NotificationCenter.default.publisher(for: .seekZipOpenArchive)) { note in
            if let url = note.object as? URL { openArchive(url) }
        }
        // Menu-bar commands (see `SeekZipApp.commands`).
        .onReceive(NotificationCenter.default.publisher(for: .seekZipOpenArchiveRequest)) { _ in openArchive() }
        .onReceive(NotificationCenter.default.publisher(for: .seekZipNewArchiveRequest)) { _ in createNewArchive() }
        .onReceive(NotificationCenter.default.publisher(for: .seekZipExtractSelectedRequest)) { _ in extractSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .seekZipVerifyRequest)) { _ in verifyArchive() }
        .onReceive(NotificationCenter.default.publisher(for: .seekZipConvertRequest)) { _ in convertArchive() }
        .onReceive(NotificationCenter.default.publisher(for: .seekZipAddFilesRequest)) { _ in addFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .seekZipRemoveSelectedRequest)) { _ in removeSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .seekZipQuickLookRequest)) { _ in quickLookSelected() }
    }

    /// M4: the queue panel. Jobs are persisted by `JobQueue`, so this
    /// list is the same after an app relaunch; interrupted jobs show
    /// as such and resume explicitly.
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                Button("Refresh") { refreshQueue() }
                    .font(.caption)
            }
            ForEach(queueJobs) { job in
                HStack {
                    Text(job.descriptor.kind.rawValue).font(.caption)
                    Text(job.descriptor.archive).lineLimit(1).font(.caption)
                    Spacer()
                    if let fraction = job.progress {
                        ProgressView(value: fraction).frame(width: 80)
                    }
                    Text(job.status.rawValue).font(.caption)
                        .foregroundStyle(.secondary)
                    if job.status == .running || job.status == .queued {
                        Button("Pause") { queue?.pause(id: job.id); refreshQueue() }
                            .font(.caption)
                    }
                    if job.status == .paused || job.status == .interrupted {
                        Button("Resume") { queue?.resume(id: job.id); runQueueInBackground() }
                            .font(.caption)
                    }
                    if job.status == .queued || job.status == .running || job.status == .paused {
                        Button("Cancel") { queue?.cancel(id: job.id); refreshQueue() }
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// M4: lazily builds the shared queue (same store file as the CLI's
    /// `seekzip queue`, so jobs enqueued here are visible there).
    /// M6: the queue runs on the router, so queued extracts route
    /// across engines too.
    private func makeQueue() -> JobQueue? {
        if let queue { return queue }
        guard let router = engineSettings.makeRouter() else { return nil }
        let created = JobQueue(engine: router)
        queue = created
        return created
    }

    private func refreshQueue() {
        queueJobs = queue?.jobs() ?? []
    }

    /// M4: runs queued jobs on a background queue and refreshes the
    /// panel on the main queue when the runner drains the queue.
    /// (`runAll` blocks, so it must never run on the main actor.)
    private func runQueueInBackground() {
        guard let queue else { return }
        DispatchQueue.global(qos: .utility).async {
            queue.runAll()
            DispatchQueue.main.async { self.refreshQueue() }
        }
    }

    /// The preview panel: text inline, everything else as metadata
    /// with a Quick Look hint (the native QLPreviewPanel is M7).
    @ViewBuilder
    private var previewPanel: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(preview.entryPath).font(.headline).lineLimit(1)
                    Spacer()
                    Text(preview.kind.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Close") { showPreview = false }
                }
                if let text = preview.text {
                    ScrollView {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if preview.truncated {
                        Text("Showing the first \(preview.linesShown) lines — extract the file to see the rest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let note = preview.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } else {
            Text("Select an entry and press Space to preview it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    /// M3: open the selected entry's preview with the core provider.
    /// Text streams in (max 64 KB / 200 lines); images, PDFs and
    /// binary entries report back as "use Quick Look".
    /// M7: the preview goes through the router, so an XAD-only
    /// archive previews via a temporary extraction (core fallback)
    /// instead of failing on the missing 7zz stream.
    /// Toggles the inline panel: pressing it again while the panel
    /// is open closes the panel (it used to re-open it every time
    /// — the `showPreview = true` below never turned it off).
    /// Reached from the context menu ("Preview"); Space now opens
    /// Quick Look instead.
    private func togglePreview() {
        if showPreview {
            showPreview = false
            preview = nil
            return
        }
        guard let archiveURL,
              let selected = selection.first,
              let entry = info?.entries.first(where: { $0.path == selected }) else { return }
        showPreview = true
        loadPreview(archiveURL: archiveURL, entry: entry)
    }

    /// Load (or reload) the preview for the current selection, without
    /// toggling the panel — used when the selection moves while the
    /// panel is already open (click, arrow keys).
    private func loadPreview() {
        guard let archiveURL,
              let selected = selection.first,
              let entry = info?.entries.first(where: { $0.path == selected }) else { return }
        loadPreview(archiveURL: archiveURL, entry: entry)
    }

    private func loadPreview(archiveURL: URL, entry: ArchiveEntry) {
        Task {
            do {
                guard let router = engineSettings.makeRouter() else {
                    status = "No engine available"
                    return
                }
                let provider = PreviewProvider(engine: router)
                let loaded = nestedPath.isEmpty
                    ? try provider.preview(archive: archiveURL, entry: entry)
                    : try provider.previewNested(archive: archiveURL,
                                                 nestedPath: nestedPath,
                                                 entry: entry)
                preview = loaded
            } catch {
                status = "Preview failed: \(error)"
            }
        }
    }

    /// Copy the entry's path inside the archive to the clipboard.
    private func copyEntryPath(_ entry: ArchiveEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
    }

    /// M3: drill into a nested archive entry, in place.
    /// M6: listings go through the router (XAD fallback applies
    /// inside nested archives too).
    private func drillInto(_ entry: ArchiveEntry) {
        guard entry.isArchive, let archiveURL else { return }
        let next = nestedPath + [entry.path]
        Task {
            do {
                guard let router = engineSettings.makeRouter() else {
                    status = "No engine available"
                    return
                }
                let loaded = try router.listNested(archive: archiveURL,
                                                   nestedPath: next)
                nestedPath = next
                info = loaded
                preview = nil
                showPreview = false
                status = "\(loaded.entries.count) entries inside \(entry.path)"
            } catch {
                status = "Cannot open nested archive: \(error)"
            }
        }
    }

    /// M3: one level back up out of a nested archive.
    private func goBack() {
        guard let archiveURL else { return }
        let next = Array(nestedPath.dropLast())
        Task {
            do {
                guard let router = engineSettings.makeRouter() else {
                    status = "No engine available"
                    return
                }
                let loaded = next.isEmpty
                    ? try router.list(archive: archiveURL)
                    : try router.listNested(archive: archiveURL, nestedPath: next)
                nestedPath = next
                info = loaded
                preview = nil
                showPreview = false
                status = "\(loaded.entries.count) entries"
            } catch {
                status = "Cannot go back: \(error)"
            }
        }
    }

    private func openArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openArchive(url)
    }

    /// M7: open an archive URL directly (Finder double-click /
    /// extension), without the file panel. A header-encrypted archive
    /// (or a wrong stored password) throws `wrongPassword` — the
    /// router deliberately does not fall back to XAD for that error,
    /// so it reaches here and the password sheet asks the user
    /// instead of failing with a bare status line.
    private func openArchive(_ url: URL, password: String? = nil) {
        archiveURL = url
        nestedPath = []
        preview = nil
        showPreview = false
        Task {
            do {
                guard let router = engineSettings.makeRouter() else {
                    status = "No engine available"
                    return
                }
                let loaded = try router.list(archive: url, password: password)
                info = loaded
                status = "\(loaded.entries.count) entries · " +
                         ByteCountFormatter.string(fromByteCount: Int64(loaded.totalUncompressed),
                                                   countStyle: .file) + " uncompressed"
            } catch EngineError.wrongPassword {
                pendingPasswordURL = url
                passwordPromptWrong = password != nil
                passwordInput = ""
                showPasswordPrompt = true
                status = "This archive needs a password"
            } catch {
                status = "Error: \(error)"
            }
        }
    }

    /// The password sheet's Open button: save to the Keychain (so
    /// previews, extracts and reloads resolve it too) and retry the
    /// listing with the password. A wrong password re-opens the sheet
    /// with the error flag (see `openArchive`'s catch).
    private func submitPassword() {
        guard let url = pendingPasswordURL, !passwordInput.isEmpty else { return }
        let password = passwordInput
        passwordInput = ""
        showPasswordPrompt = false
        try? PasswordStore.shared.save(password: password, for: url.path)
        openArchive(url, password: password)
    }

    /// Create a new archive from files (menu ⌘⇧N, or files dropped
    /// onto the window with no archive open). Picks the source files
    /// first, then the destination; the format follows the destination
    /// extension (7z / ZIP / TAR, default 7z). The new archive opens
    /// in the browser when it is created.
    private func createNewArchive(sources: [URL]? = nil) {
        let picked: [URL]
        if let sources {
            picked = sources
        } else {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            panel.prompt = "Choose"
            guard panel.runModal() == .OK else { return }
            picked = panel.urls
        }
        guard !picked.isEmpty else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "Archive.7z"
        save.prompt = "Create"
        guard save.runModal() == .OK, let dest = save.url else { return }
        let ext = dest.pathExtension.lowercased()
        let format = (ext == "zip" || ext == "7z" || ext == "tar") ? ext : "7z"
        let finalDest = (ext == "zip" || ext == "7z" || ext == "tar")
            ? dest : dest.appendingPathExtension("7z")
        Task {
            do {
                let engine = try SevenZipEngine()
                try engine.create(archive: finalDest, sources: picked, format: format)
                status = "Created \(finalDest.lastPathComponent)"
                openArchive(finalDest)
            } catch {
                status = "Create failed: \(error)"
            }
        }
    }

    /// Open the selected entry: drill into a nested archive, open a
    /// file in its default app, do nothing for folders (the list is
    /// flat — there is no folder to navigate into). This is what
    /// double-click, Return and the context menu's Open all call, so
    /// no action is mouse-only (HIG).
    private func openSelected(_ entry: ArchiveEntry) {
        if entry.isArchive { drillInto(entry); return }
        guard !entry.isDirectory else { return }
        openEntryInDefaultApp(entry)
    }

    /// Open one entry in its default app: stream its bytes to a temp
    /// file and hand it to the workspace. The streaming runs in a
    /// detached task (off the main actor) and writes chunk by chunk
    /// to disk, so a huge file neither freezes the UI nor sits whole
    /// in RAM — the old version accumulated a `Data` on the main
    /// actor. Also fixed here: the old version streamed with
    /// `password: nil`, so entries from a password-protected archive
    /// could never open; the stored password is used now.
    private func openEntryInDefaultApp(_ entry: ArchiveEntry) {
        guard let archiveURL else { return }
        let nested = nestedPath
        let password = PasswordStore.shared.password(for: archiveURL.path)
        Task {
            do {
                let dest = try await Task.detached(priority: .userInitiated) {
                    try streamEntryToTempFile(archiveURL: archiveURL,
                                              nestedPath: nested,
                                              entry: entry, password: password)
                }.value
                _ = NSWorkspace.shared.open(dest)
                status = "Opened \(entry.path)"
            } catch {
                status = "Cannot open \(entry.path): \(error)"
            }
        }
    }

    /// Quick Look the selected entry in the system panel (images,
    /// PDFs, text, archives — whatever the system can preview).
    /// Files only: a directory has no single file to show. The entry
    /// is streamed to a temp file first (see `openEntryInDefaultApp`
    /// for why the streaming is detached and chunked).
    private func quickLookSelected() {
        guard let archiveURL,
              let path = selection.first,
              let entry = info?.entries.first(where: { $0.path == path }),
              !entry.isDirectory else { return }
        // A held Space key repeats the event: ignore it while the
        // panel is already showing this entry, so the entry is not
        // re-extracted over and over. (The KeyPress value that
        // would let us filter repeats is not available from
        // `onKeyPress` in this SDK — the single-key form takes
        // no argument and there is no Set form.)
        if QuickLookController.shared.isShowing(entryPath: entry.path) { return }
        let nested = nestedPath
        let password = PasswordStore.shared.password(for: archiveURL.path)
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try streamEntryToTempFile(archiveURL: archiveURL,
                                              nestedPath: nested,
                                              entry: entry, password: password)
                }.value
                QuickLookController.shared.show(url: url, entryPath: entry.path)
            } catch {
                status = "Quick Look failed: \(error)"
            }
        }
    }

    /// Build the drag-out item for one row: a file representation
    /// that Finder loads on demand (when the drop lands). The entry
    /// is extracted to a temp file only then — nothing is copied up
    /// front, and a huge file does not block the drag from starting.
    /// `registerFileRepresentation` is the way to promise a file
    /// from SwiftUI: `NSFilePromiseProvider` does NOT conform to
    /// `NSItemProviderWriting`, so it cannot be wrapped in an
    /// `NSItemProvider` (that was the batch-2 build error).
    private func dragItemProvider(for entry: ArchiveEntry, archiveURL: URL) -> NSItemProvider {
        let fileType: String
        if entry.isDirectory {
            fileType = "public.folder"
        } else {
            fileType = UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension)?.identifier
                ?? "public.data"
        }
        let password = PasswordStore.shared.password(for: archiveURL.path)
        let nested = nestedPath
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        provider.registerFileRepresentation(forTypeIdentifier: fileType, visibility: .all) { completion in
            do {
                let url = try extractEntryToTemp(archiveURL: archiveURL,
                                                 nestedPath: nested,
                                                 entry: entry, password: password)
                completion(url, true, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    /// Drag & drop in (Finder → SeekZip): resolve the dropped file
    /// URLs, then hand them to `handleDroppedURLs` on the main queue.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let collector = URLCollector()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.handleDroppedURLs(collector.urls) }
        return true
    }

    /// What a drop means depends on what was dropped and what is
    /// open: one archive opens it; files dropped onto an open archive
    /// are added to it; files dropped with nothing open start a new
    /// archive (the MacPacker/Keka pattern).
    private func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            status = "Couldn't read the dropped files"
            return
        }
        if urls.count == 1, SevenZipEngine.format(of: urls[0]) != nil {
            openArchive(urls[0])
            return
        }
        if archiveURL != nil {
            addFiles(sources: urls)
            return
        }
        createNewArchive(sources: urls)
    }

    /// M5: reload the current archive's listing after an edit, so the
    /// list, CRC column and counts reflect the new contents.
    private func reloadListing() {
        guard let archiveURL else { return }
        Task {
            do {
                guard let router = engineSettings.makeRouter() else {
                    status = "No engine available"
                    return
                }
                let loaded = nestedPath.isEmpty
                    ? try router.list(archive: archiveURL)
                    : try router.listNested(archive: archiveURL,
                                            nestedPath: nestedPath)
                info = loaded
                status = "\(loaded.entries.count) entries"
            } catch {
                status = "Error: \(error)"
            }
        }
    }

    /// M5: add files to the archive (temp-copy + atomic replace in
    /// the core, so a failed add leaves the original untouched).
    /// With `sources` given (drag & drop), the panel is skipped.
    private func addFiles(sources: [URL]? = nil) {
        guard let archiveURL else { return }
        let picked: [URL]
        if let sources {
            picked = sources
        } else {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            panel.prompt = "Add"
            guard panel.runModal() == .OK else { return }
            picked = panel.urls
        }
        guard !picked.isEmpty else { return }
        Task {
            do {
                let engine = try SevenZipEngine()
                try engine.addEntries(archive: archiveURL,
                                      sources: picked)
                status = "Added \(picked.count) file(s)"
                reloadListing()
            } catch {
                status = "Add failed: \(error)"
            }
        }
    }

    /// M5: remove the selected entries (temp-copy + atomic replace).
    private func removeSelected() {
        guard let archiveURL else { return }
        let names = Array(selection)
        Task {
            do {
                let engine = try SevenZipEngine()
                try engine.removeEntries(archive: archiveURL, entries: names)
                selection.removeAll()
                status = "Removed \(names.count) entr\(names.count == 1 ? "y" : "ies")"
                reloadListing()
            } catch {
                status = "Remove failed: \(error)"
            }
        }
    }

    /// M5: rename the single selected entry to `renameTo`.
    private func renameSelected() {
        guard let archiveURL, let old = selection.first,
              !renameTo.isEmpty else { return }
        let newName = renameTo
        Task {
            do {
                let engine = try SevenZipEngine()
                try engine.renameEntries(archive: archiveURL,
                                         renames: [(old: old, new: newName)])
                renameTo = ""
                selection.removeAll()
                status = "Renamed to \(newName)"
                reloadListing()
            } catch {
                status = "Rename failed: \(error)"
            }
        }
    }

    /// M5: convert the archive to 7z (ZIP/7z/TAR targets are offered
    /// by the core; RAR is impossible and the core says so).
    /// M6: conversion goes through the router, so a legacy archive
    /// (e.g. StuffIt, via XAD) can be the source.
    private func convertArchive() {
        guard let archiveURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = archiveURL.deletingPathExtension()
            .appendingPathExtension("7z").lastPathComponent
        panel.prompt = "Convert"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do {
                guard let router = engineSettings.makeRouter() else {
                    status = "No engine available"
                    return
                }
                try router.convert(archive: archiveURL, to: dest)
                status = "Converted to \(dest.lastPathComponent)"
            } catch {
                status = "Convert failed: \(error)"
            }
        }
    }

    /// M5: per-entry CRC verification (COR-02). Bad entries are
    /// listed in the summary instead of stopping at the first one.
    private func verifyArchive() {
        guard let archiveURL else { return }
        verifySummary = "Verifying…"
        Task {
            do {
                let engine = try SevenZipEngine()
                let results = try engine.verify(archive: archiveURL)
                let bad = results.filter {
                    $0.status == .mismatch || $0.status == .error
                }
                verifySummary = bad.isEmpty
                    ? "Verified: \(results.count) entries OK"
                    : "Verified: \(results.count - bad.count)/\(results.count) OK — bad: \(bad.map(\.entryPath).joined(separator: ", "))"
            } catch {
                verifySummary = "Verify failed: \(error)"
            }
        }
    }

    /// M4: Extract Selected now enqueues a job instead of extracting
    /// inline — the queue runs it in the background, shows progress in
    /// the queue panel, and survives an app relaunch.
    private func extractSelected() {
        guard let archiveURL, let queue = makeQueue() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let entries = Array(selection)
        queue.enqueue(JobDescriptor(kind: .extract, archive: archiveURL.path,
                                    destination: dest.path, entries: entries))
        refreshQueue()
        status = "Queued extraction of \(entries.count) entries to \(dest.path)"
        runQueueInBackground()
    }
}
