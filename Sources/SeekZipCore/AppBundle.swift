import Foundation

/// M7: shared packaging constants — where the packaged app keeps its
/// engine binaries, and the App Group the app and its extensions use
/// to share engine settings. One source of truth, used by the app,
/// the Finder Sync extension and the Quick Look extension.
///
/// The App Group ID below is a placeholder: the owner must create the
/// group in their Apple Developer account (prefixed with their Team
/// ID, e.g. `group.<TEAMID>.seekzip`) and replace the value here and
/// in the three `.entitlements` files — see `docs/RELEASE.md`.
public enum SeekZipAppGroup {
    public static let suiteName = "group.com.seekzip.app"
    /// Defaults keys shared by the app and its extensions (M6/M7).
    public static let defaultEngineKey = "seekzip.engine.default"
    public static let formatOverridesKey = "seekzip.engine.overrides"
}

/// M7: bundled engine binaries. The packaged app keeps 7zz/lsar/unar
/// in `Resources/Helpers/` (staged by `scripts/package-engines.sh`);
/// the helpers are signed with the inherit entitlement
/// (`SeekZip/Helpers.entitlements`) so they run inside the app
/// sandbox. The CLI and the test runs are not app bundles, so the
/// lookup simply finds nothing there and the engines fall back to
/// the well-known PATH locations.
public enum BundledEngines {
    /// Subdirectory of the bundle's Resources holding the engines.
    public static let helpersSubdirectory = "Helpers"

    /// The containing `.app` when this process runs inside an app
    /// extension (its bundle lives in
    /// `App.app/Contents/PlugIns/*.appex`); nil otherwise. Extensions
    /// resolve the bundled engines from the app bundle, not their own.
    public static func containingAppURL(from bundle: Bundle = .main) -> URL? {
        var url = bundle.bundleURL
        var isExtension = false
        while url.pathExtension == "appex" {
            isExtension = true
            url.deleteLastPathComponent() // *.appex
            if url.lastPathComponent == "PlugIns" { url.deleteLastPathComponent() }
            if url.lastPathComponent == "Contents" { url.deleteLastPathComponent() }
        }
        guard isExtension, url.pathExtension == "app" else { return nil }
        return url
    }

    /// The app bundle for this process: the containing app for an
    /// extension, this bundle otherwise.
    public static func appBundleURL(from bundle: Bundle = .main) -> URL {
        containingAppURL(from: bundle) ?? bundle.bundleURL
    }

    /// URL of a bundled helper binary, or nil when this process is
    /// not running from a packaged app or the helper was not staged.
    /// Pure path probing over `bundleRoot`, so it is unit-testable
    /// without a real app bundle.
    public static func url(named name: String, bundleRoot: URL) -> URL? {
        let candidates = [
            bundleRoot.appendingPathComponent(
                "Contents/Resources/\(helpersSubdirectory)/\(name)"),
            bundleRoot.appendingPathComponent(
                "Resources/\(helpersSubdirectory)/\(name)"),
            bundleRoot.appendingPathComponent("Contents/Resources/\(name)"),
            bundleRoot.appendingPathComponent("Resources/\(name)"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    /// Same lookup, rooted at this process's app bundle (the
    /// containing app for extensions). This is what the engines use.
    public static func url(named name: String,
                           in bundle: Bundle = .main) -> URL? {
        url(named: name, bundleRoot: appBundleURL(from: bundle))
    }

    public static func sevenZipURL(in bundle: Bundle = .main) -> URL? {
        url(named: "7zz", in: bundle)
    }

    public static func lsarURL(in bundle: Bundle = .main) -> URL? {
        url(named: "lsar", in: bundle)
    }

    public static func unarURL(in bundle: Bundle = .main) -> URL? {
        url(named: "unar", in: bundle)
    }
}
