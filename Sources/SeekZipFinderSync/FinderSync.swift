import Cocoa
import FinderSync
import SeekZipCore

// SeekZip Finder Sync extension (M7, submenu since 2026-11-11).
//
// One "SeekZip" submenu in Finder's contextual menu, with the
// commands depending on what is selected — the 7-Zip way:
// archives get Open / Extract Here / Extract to "name/" / Extract
// to… / Test Archive; ordinary files and folders get Add to
// "name.7z" / Add to "name.zip" / Add to Archive…; a mixed
// selection gets both groups, separated. Archives are badged in
// Finder, and the extension reports a heartbeat (last seen) to the
// app through the App Group, so the app's Settings → Finder tab can
// tell the user whether the extension is running.
//
// The extension runs in its own process; all archive work goes
// through SeekZipCore (the router: 7zz first, XAD fallback), and
// the bundled engines are resolved from the containing app bundle
// (see `BundledEngines`). Engine settings come from the shared App
// Group defaults. The extension must be enabled by the user in
// System Settings → Privacy & Security → Extensions → Finder
// Extensions before its menu items appear (the app's Finder tab
// walks the user through that).
final class FinderSync: FIFinderSync {

    /// Archive extensions the menu and badges apply to (the formats
    /// the router can open — see `EngineCapabilities`).
    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst",
        "lz4", "iso", "dmg", "cab", "wim", "arj", "lzh", "lha", "msi",
        "deb", "rpm", "xar", "cpio", "chm", "nsis", "sit", "sitx",
        "zoo", "arc", "cpt", "dd", "pit", "ace", "sea",
    ]

    /// Extensions whose name is really two parts (`.tar.gz` and
    /// friends) — the folder name strips both.
    private static let doubleExtensions: Set<String> = [
        "gz", "bz2", "xz", "zst", "lz4",
    ]

    override init() {
        super.init()
        // Watch the user's home folder; the user can narrow the
        // watched folders in System Settings → Extensions.
        FIFinderSyncController.default().directoryURLs = [
            FileManager.default.homeDirectoryForCurrentUser
        ]
        // Badge images for the states the extension reports.
        let controller = FIFinderSyncController.default()
        if let icon = NSImage(systemSymbolName: "archivebox",
                              accessibilityDescription: "Archive") {
            controller.setBadgeImage(icon, label: "Archive",
                                     forBadgeIdentifier: "archive")
        }
        if let done = NSImage(systemSymbolName: "checkmark.circle",
                              accessibilityDescription: "Extracted") {
            controller.setBadgeImage(done, label: "Extracted",
                                     forBadgeIdentifier: "extracted")
        }
        if let error = NSImage(systemSymbolName: "exclamationmark.circle",
                               accessibilityDescription: "Error") {
            controller.setBadgeImage(error, label: "Error",
                                     forBadgeIdentifier: "error")
        }
        // Heartbeat for the app's Settings → Finder tab: the tab
        // reads this timestamp from the App Group defaults to show
        // whether the extension has ever run.
        let defaults = UserDefaults(suiteName: SeekZipAppGroup.suiteName) ?? .standard
        defaults.set(Date(), forKey: SeekZipAppGroup.finderSyncLastSeenKey)
    }

    // MARK: - Toolbar item

    override var toolbarItemName: String { "SeekZip" }
    override var toolbarItemToolTip: String { "Open with SeekZip" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "archivebox",
                accessibilityDescription: "SeekZip")
            ?? NSImage()
    }

    // MARK: - Contextual menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind == .contextualMenuForItems,
              let targets = FIFinderSyncController.default().selectedItemURLs(),
              !targets.isEmpty else {
            return menu
        }
        let archives = targets.filter { Self.isArchive($0) }
        let regulars = targets.filter { !Self.isArchive($0) }
        let submenu = NSMenu(title: "SeekZip")
        if !archives.isEmpty {
            submenu.addItem(makeItem(title: "Open with SeekZip",
                                     action: #selector(openWithSeekZip(_:))))
            submenu.addItem(makeItem(title: "Extract Here",
                                     action: #selector(extractHere(_:))))
            if archives.count == 1, let first = archives.first {
                submenu.addItem(makeItem(
                    title: "Extract to \"\(Self.folderName(for: first))/\"",
                    action: #selector(extractToFolder(_:))))
            } else {
                submenu.addItem(makeItem(title: "Extract to Separate Folders",
                                         action: #selector(extractToFolder(_:))))
            }
            submenu.addItem(makeItem(title: "Extract to…",
                                     action: #selector(extractTo(_:))))
            submenu.addItem(makeItem(title: "Test Archive",
                                     action: #selector(testArchive(_:))))
        }
        if !archives.isEmpty && !regulars.isEmpty {
            submenu.addItem(.separator())
        }
        if !regulars.isEmpty {
            let base = Self.addArchiveBaseName(for: regulars)
            submenu.addItem(makeItem(title: "Add to \"\(base).7z\"",
                                     action: #selector(addTo7z(_:))))
            submenu.addItem(makeItem(title: "Add to \"\(base).zip\"",
                                     action: #selector(addToZip(_:))))
            submenu.addItem(makeItem(title: "Add to Archive…",
                                     action: #selector(addToArchive(_:))))
        }
        let item = NSMenuItem(title: "SeekZip", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
        return menu
    }

    private func makeItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Archive actions

    @IBAction func openWithSeekZip(_ sender: AnyObject?) {
        guard let targets = FIFinderSyncController.default().selectedItemURLs(),
              !targets.isEmpty else { return }
        Self.openApp(with: targets)
    }

    /// Extracts each selected archive next to itself, on a background
    /// queue; the item is badged when it finishes (or on failure).
    /// A failed or cancelled extraction leaves no partial output:
    /// both engines stage and move into place only on success.
    @IBAction func extractHere(_ sender: AnyObject?) {
        guard let archives = selectedArchives() else { return }
        Self.extractArchives(archives) { $0.deletingLastPathComponent() }
    }

    /// Extracts each archive into a folder named after it, next to
    /// itself (one archive → "name/", several → one folder per
    /// archive). The folder is created by the extract itself.
    @IBAction func extractToFolder(_ sender: AnyObject?) {
        guard let archives = selectedArchives() else { return }
        Self.extractArchives(archives) {
            $0.deletingLastPathComponent()
                .appendingPathComponent(Self.folderName(for: $0), isDirectory: true)
        }
    }

    /// Asks for a destination folder (on the main thread — this is a
    /// menu action) and extracts every selected archive into it.
    @IBAction func extractTo(_ sender: AnyObject?) {
        guard let archives = selectedArchives() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Self.extractArchives(archives) { _ in dest }
    }

    /// Tests every selected archive and reports the results in an
    /// alert (the extension has no other way to show results).
    /// The tests run on a background queue; the alert is main-thread.
    @IBAction func testArchive(_ sender: AnyObject?) {
        guard let archives = selectedArchives() else { return }
        DispatchQueue.global(qos: .utility).async {
            var lines: [String] = []
            var allOK = true
            for url in archives {
                do {
                    guard let router = Self.makeRouter() else {
                        throw EngineError.failed(
                            exitCode: 2,
                            message: "no archive engine is available")
                    }
                    try router.test(archive: url)
                    lines.append("✓ \(url.lastPathComponent): OK")
                } catch {
                    allOK = false
                    lines.append("✗ \(url.lastPathComponent): \(error)")
                    FIFinderSyncController.default()
                        .setBadgeIdentifier("error", for: url)
                }
            }
            let message = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = allOK ? "All archives passed"
                                          : "Some archives failed the test"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    /// The shared extract worker: one archive at a time, on a
    /// background queue, into the destination the caller computes
    /// per archive. A password-protected archive cannot be asked
    /// about here — the extension has no Keychain sharing without a
    /// Team ID — so it opens the app instead, which has the password
    /// sheet and the Keychain.
    private static func extractArchives(_ archives: [URL],
                                        destinationFor: @escaping (URL) -> URL) {
        DispatchQueue.global(qos: .utility).async {
            for url in archives {
                let destination = destinationFor(url)
                do {
                    guard let router = Self.makeRouter() else {
                        throw EngineError.failed(
                            exitCode: 2,
                            message: "no archive engine is available")
                    }
                    try router.extract(archive: url, to: destination)
                    FIFinderSyncController.default()
                        .setBadgeIdentifier("extracted", for: url)
                } catch EngineError.wrongPassword {
                    Self.openApp(with: [url])
                } catch {
                    NSLog("SeekZip FinderSync: extract failed for %@: %@",
                          url.path, String(describing: error))
                    FIFinderSyncController.default()
                        .setBadgeIdentifier("error", for: url)
                }
            }
        }
    }

    // MARK: - Add-to-archive actions

    /// Creates "name.7z" next to the selection right away, on a
    /// background queue. The name comes from the single file, or
    /// from the parent folder for several files.
    @IBAction func addTo7z(_ sender: AnyObject?) {
        addToArchive(format: "7z")
    }

    @IBAction func addToZip(_ sender: AnyObject?) {
        addToArchive(format: "zip")
    }

    private func addToArchive(format: String) {
        guard let targets = FIFinderSyncController.default().selectedItemURLs(),
              !targets.isEmpty else { return }
        let base = Self.addArchiveBaseName(for: targets)
        let dest = targets[0].deletingLastPathComponent()
            .appendingPathComponent("\(base).\(format)")
        DispatchQueue.global(qos: .utility).async {
            do {
                guard let router = Self.makeRouter() else {
                    throw EngineError.failed(
                        exitCode: 2,
                        message: "no archive engine is available")
                }
                try router.create(archive: dest, sources: targets, format: format)
            } catch {
                NSLog("SeekZip FinderSync: create failed for %@: %@",
                      dest.path, String(describing: error))
            }
        }
    }

    /// "Add to Archive…" needs the full New Archive dialog, which
    /// only the app has. The selection is handed over through the
    /// App Group (`pending-create.json`); the app picks it up when
    /// it becomes active and opens the dialog with these sources.
    @IBAction func addToArchive(_ sender: AnyObject?) {
        guard let targets = FIFinderSyncController.default().selectedItemURLs(),
              !targets.isEmpty else { return }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SeekZipAppGroup.suiteName) else {
            NSLog("SeekZip FinderSync: no App Group container for the create handoff")
            return
        }
        let file = container.appendingPathComponent(SeekZipAppGroup.pendingCreateFileName)
        do {
            let data = try JSONEncoder().encode(targets.map(\.path))
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("SeekZip FinderSync: could not write the create handoff: %@",
                  String(describing: error))
            return
        }
        Self.openApp()
    }

    // MARK: - Badges

    /// Finder asks for a badge whenever it displays an item in a
    /// watched folder.
    override func requestBadgeIdentifier(for url: URL) {
        // setBadgeIdentifier takes a non-optional String; "" clears the badge.
        let badge = Self.isArchive(url) ? "archive" : ""
        FIFinderSyncController.default().setBadgeIdentifier(badge, for: url)
    }

    // MARK: - Helpers

    private static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(
            url.pathExtension.lowercased())
    }

    /// The selected archives, if any (the menu only shows archive
    /// actions when at least one is selected, so this is normally
    /// non-nil).
    private func selectedArchives() -> [URL]? {
        guard let targets = FIFinderSyncController.default().selectedItemURLs() else {
            return nil
        }
        let archives = targets.filter { Self.isArchive($0) }
        return archives.isEmpty ? nil : archives
    }

    /// The folder name for "Extract to": the archive name without
    /// its extension, stripping both parts of `.tar.gz` and friends
    /// (so `photos.tar.gz` → `photos`, not `photos.tar`).
    private static func folderName(for url: URL) -> String {
        let withoutOuter = url.deletingPathExtension()
        if doubleExtensions.contains(url.pathExtension.lowercased()),
           withoutOuter.pathExtension.lowercased() == "tar" {
            let name = withoutOuter.deletingPathExtension().lastPathComponent
            return name.isEmpty ? "Archive" : name
        }
        let name = withoutOuter.lastPathComponent
        return name.isEmpty ? "Archive" : name
    }

    /// The base name for "Add to": the single file's name without
    /// its extension, or the parent folder's name for several files.
    private static func addArchiveBaseName(for targets: [URL]) -> String {
        if targets.count == 1, let first = targets.first {
            let name = first.deletingPathExtension().lastPathComponent
            return name.isEmpty ? "Archive" : name
        }
        let parent = targets.first?.deletingLastPathComponent().lastPathComponent ?? ""
        return parent.isEmpty ? "Archive" : parent
    }

    private static func openApp(with urls: [URL]) {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.seekzip.app") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: config, completionHandler: nil)
    }

    private static func openApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.seekzip.app") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config,
                                           completionHandler: nil)
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
