import SwiftUI
import SeekZipCore

// SeekZipApp — SwiftUI frontend skeleton (v0.1).
// Open an archive → browse its entries → extract selected.
// Preview, tabs, queue and Finder extensions land in later milestones;
// all real work goes through SeekZipCore so the GUI stays thin.

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
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                    Text(entry.path)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size),
                                                   countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .tag(entry.path)
            }
            Divider()
            Text(status).font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private func openArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveURL = url
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
