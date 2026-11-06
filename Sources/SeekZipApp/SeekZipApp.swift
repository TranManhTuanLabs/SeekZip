import SwiftUI
import SeekZipCore

// SeekZipApp — SwiftUI frontend skeleton (v0.1).
// Open an archive → browse its entries → extract selected.
// Preview, tabs, queue and Finder extensions land in later milestones;
// all real work goes through SeekZipCore so the GUI stays thin.
//
// M3 preview wiring (code only — NOT compiled by SwiftPM yet: it needs
// full Xcode for SwiftUIMacros, and the M7 Xcode project is where this
// file first builds): Space toggles an inline preview panel driven by
// `PreviewProvider` (text inline, images/PDF/binary via Quick Look),
// and double-clicking a nested archive drills into it in place.
// The native Quick Look panel (QLPreviewPanel) itself is wired in M7,
// once this file can be compile-checked with Xcode.

@main
struct SeekZipApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .windowStyle(.titleBar)
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
                Button("Extract Selected") { extractSelected() }
                    .disabled(selection.isEmpty)
            }
            .padding(8)

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

            Divider()
            Text(status).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(minWidth: 640, minHeight: 420)
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
                let engine = try SevenZipEngine()
                let provider = PreviewProvider(engine: engine)
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
    private func drillInto(_ entry: ArchiveEntry) {
        guard entry.isArchive, let archiveURL else { return }
        let next = nestedPath + [entry.path]
        Task {
            do {
                let engine = try SevenZipEngine()
                let loaded = try engine.listNested(archive: archiveURL,
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
                let engine = try SevenZipEngine()
                let loaded = next.isEmpty
                    ? try engine.list(archive: archiveURL)
                    : try engine.listNested(archive: archiveURL, nestedPath: next)
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
        archiveURL = url
        nestedPath = []
        preview = nil
        showPreview = false
        Task {
            do {
                let engine = try SevenZipEngine()
                let loaded = try engine.list(archive: url)
                info = loaded
                status = "\(loaded.entries.count) entries · " +
                         ByteCountFormatter.string(fromByteCount: Int64(loaded.totalUncompressed),
                                                   countStyle: .file) + " uncompressed"
            } catch {
                status = "Error: \(error)"
            }
        }
    }

    private func extractSelected() {
        guard let archiveURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Extract Here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let entries = Array(selection)
        Task {
            do {
                let engine = try SevenZipEngine()
                try engine.extract(archive: archiveURL, entries: entries, to: dest)
                status = "Extracted \(entries.count) entries to \(dest.path)"
            } catch {
                status = "Extract failed: \(error)"
            }
        }
    }
}
