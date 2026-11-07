import SwiftUI
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
}

@main
struct SeekZipApp: App {
    @NSApplicationDelegateAdaptor(SeekZipAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .windowStyle(.titleBar)
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

struct BrowserView: View {
    @State private var archiveURL: URL?
    @State private var info: ArchiveInfo?
    @State private var selection = Set<String>()
    @State private var status = "Open an archive to begin (⌘O)"
    @State private var filter = ""
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
    @State private var showEngineSettings = false

    private var shownEntries: [ArchiveEntry] {
        guard let info else { return [] }
        guard !filter.isEmpty else { return info.entries }
        return info.entries.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Open Archive…") { openArchive() }
                TextField("Filter entries", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                // M6: engine settings — default engine + per-format
                // overrides (UserDefaults, shared with extensions).
                Button("Engines…") { showEngineSettings = true }
                Button("Extract Selected") { extractSelected() }
                    .disabled(selection.isEmpty)
            }
            .padding(8)
            .sheet(isPresented: $showEngineSettings) {
                EngineSettingsView(settings: engineSettings)
            }

            // M5: edit row — add/remove/rename/convert/verify. All of
            // these go through the core edit path (temp copy + atomic
            // replace), so a failed edit never corrupts the archive.
            HStack {
                Button("Add Files…") { addFiles() }
                    .disabled(archiveURL == nil)
                Button("Remove Selected") { removeSelected() }
                    .disabled(selection.isEmpty)
                TextField("New name", text: $renameTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                Button("Rename") { renameSelected() }
                    .disabled(selection.count != 1 || renameTo.isEmpty)
                Button("Convert…") { convertArchive() }
                    .disabled(archiveURL == nil)
                Button("Verify") { verifyArchive() }
                    .disabled(archiveURL == nil)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            if let verifySummary {
                Text(verifySummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }

            if let warning = info.flatMap(EntryPathSafety.bombWarning) {
                Text("⚠️ \(warning)")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }

            List(shownEntries, selection: $selection) { entry in
                HStack {
                    Image(systemName: entry.isDirectory ? "folder"
                        : entry.isArchive ? "archivebox" : "doc")
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
                // M3: double-click a nested archive to drill into it.
                .onTapGesture(count: 2) { drillInto(entry) }
            }
            .onKeyPress(.space) {
                togglePreview()
                return .handled
            }

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
            // M6: the status line names the engine that handled the
            // archive (`ArchiveInfo.engine`, stamped by the router).
            Text(status + (info?.engine.map { " · engine: \($0)" } ?? ""))
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(minWidth: 640, minHeight: 420)
        // M7: an archive opened from Finder (double-click / extension)
        // arrives via the app delegate as a notification.
        .onReceive(NotificationCenter.default.publisher(for: .seekZipOpenArchive)) { note in
            if let url = note.object as? URL { openArchive(url) }
        }
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
    private func togglePreview() {
        guard let archiveURL,
              let selected = selection.first,
              let entry = info?.entries.first(where: { $0.path == selected }) else {
            showPreview.toggle()
            return
        }
        showPreview = true
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
    /// extension), without the file panel.
    private func openArchive(_ url: URL) {
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
                let loaded = try router.list(archive: url)
                info = loaded
                status = "\(loaded.entries.count) entries · " +
                         ByteCountFormatter.string(fromByteCount: Int64(loaded.totalUncompressed),
                                                   countStyle: .file) + " uncompressed"
            } catch {
                status = "Error: \(error)"
            }
        }
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
    private func addFiles() {
        guard let archiveURL else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        Task {
            do {
                let engine = try SevenZipEngine()
                try engine.addEntries(archive: archiveURL,
                                      sources: panel.urls)
                status = "Added \(panel.urls.count) file(s)"
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
