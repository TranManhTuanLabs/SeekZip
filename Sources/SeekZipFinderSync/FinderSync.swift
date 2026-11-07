import Cocoa
import FinderSync
import SeekZipCore

// SeekZip Finder Sync extension (M7).
//
// Adds "Open with SeekZip" and "Extract Here" to Finder's contextual
// menu for archives, and badges archives in Finder. The extension
// runs in its own process; all archive work goes through SeekZipCore
// (the router: 7zz first, XAD fallback), and the bundled engines are
// resolved from the containing app bundle (see `BundledEngines`).
// Engine settings come from the shared App Group defaults.
//
// This file has never been compiled: it needs full Xcode on a Mac
// (see docs/RELEASE.md for the first-build checklist). The Finder
// Sync extension must also be enabled by the user in
// System Settings → Privacy & Security → Extensions → Finder
// Extensions before its menu items appear.
final class FinderSync: FIFinderSync {

    /// Archive extensions the menu and badges apply to (the formats
    /// the router can open — see `EngineCapabilities`).
    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst",
        "lz4", "iso", "dmg", "cab", "wim", "arj", "lzh", "lha", "msi",
        "deb", "rpm", "xar", "cpio", "chm", "nsis", "sit", "sitx",
        "zoo", "arc", "cpt", "dd", "pit", "ace", "sea",
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
        guard let targets = FIFinderSyncController.default().selectedItemURLs(),
              !targets.isEmpty,
              targets.allSatisfy({ Self.isArchive($0) }) else {
            return menu
        }
        let open = NSMenuItem(title: "Open with SeekZip",
                              action: #selector(openWithSeekZip(_:)),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let extract = NSMenuItem(title: "Extract Here",
                                 action: #selector(extractHere(_:)),
                                 keyEquivalent: "")
        extract.target = self
        menu.addItem(extract)
        return menu
    }

    @IBAction func openWithSeekZip(_ sender: AnyObject?) {
        guard let targets = FIFinderSyncController.default().selectedItemURLs(),
              let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.seekzip.app") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(targets, withApplicationAt: appURL,
                                configuration: config, completionHandler: nil)
    }

    /// Extracts each selected archive next to itself, on a background
    /// queue; the item is badged when it finishes (or on failure).
    /// A failed or cancelled extraction leaves no partial output: the
    /// 7zz path writes entries directly (re-running overwrites them),
    /// the XAD path stages and moves into place only on success.
    @IBAction func extractHere(_ sender: AnyObject?) {
        guard let targets = FIFinderSyncController.default().selectedItemURLs(),
              !targets.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in targets where Self.isArchive(url) {
                do {
                    guard let router = Self.makeRouter() else {
                        throw EngineError.failed(
                            exitCode: 2,
                            message: "no archive engine is available")
                    }
                    try router.extract(archive: url,
                                       to: url.deletingLastPathComponent())
                    FIFinderSyncController.default()
                        .setBadgeIdentifier("extracted", for: url)
                } catch {
                    NSLog("SeekZip FinderSync: extract failed for %@: %@",
                          url.path, String(describing: error))
                    FIFinderSyncController.default()
                        .setBadgeIdentifier("error", for: url)
                }
            }
        }
    }

    // MARK: - Badges

    /// Finder asks for a badge whenever it displays an item in a
    /// watched folder.
    override func requestBadgeIdentifier(for url: URL) {
        let badge = Self.isArchive(url) ? "archive" : nil
        FIFinderSyncController.default().setBadgeIdentifier(badge, for: url)
    }

    private static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(
            url.pathExtension.lowercased())
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
