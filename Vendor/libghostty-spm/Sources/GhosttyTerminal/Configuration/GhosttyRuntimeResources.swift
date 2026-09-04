import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    /// The package-bundled Ghostty resource directory.
    ///
    /// Ghostty expects shell integration below this directory and its compiled
    /// terminfo database in a sibling `terminfo` directory.
    public static var directoryURL: URL? {
        resourceBundle?.url(forResource: "Ghostty", withExtension: nil)
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        resourceBundle?.url(forResource: "terminfo", withExtension: nil)
    }

    /// LOCAL PATCH — see Vendor/libghostty-spm/README.md.
    ///
    /// Deliberately not `Bundle.module`. SwiftPM generates that accessor with
    /// exactly two candidates: `Bundle.main.bundleURL`, which for a packaged
    /// app is the .app ROOT — where nothing may live, because codesign
    /// rejects "unsealed contents present in the bundle root" — and the
    /// absolute `.build/...` path of the machine that compiled the binary.
    /// So on the build machine it silently works, and on every other Mac both
    /// candidates miss and the accessor calls `fatalError`, taking the whole
    /// process down rather than returning nil.
    ///
    /// `Contents/Resources`, where a packaged app actually puts SwiftPM
    /// resource bundles, is not among the candidates. Probing for it here
    /// mirrors what SwiftTerm's Metal renderer already does for the same
    /// reason, and makes a missing bundle a nil instead of a crash.
    private static let resourceBundle: Bundle? = {
        let name = "GhosttyKit_GhosttyTerminal.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle(for: BundleFinder.self).resourceURL?.appendingPathComponent(name),
            Bundle(for: BundleFinder.self).bundleURL.appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()

    private final class BundleFinder {}

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
