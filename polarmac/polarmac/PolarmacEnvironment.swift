import Foundation
import PolarKit

/// Mac-app-specific environment bits that aren't part of the shared
/// PolarKit contract (UI prefs, identity strings tied to this bundle).
/// Backend settings — base URL, workspace id, last login email — live
/// in `PolarKit.AppEnvironment`.
extension AppEnvironment {
    public static let chatFontSizeUserDefaultsKey = "chatFontSize"

    /// Chat body font size in points. Clamped to [10, 32] by the UI
    /// shortcuts; default 14 matches AppKit body, close enough to iOS's
    /// .preferredFont(forTextStyle: .body) (~17 dynamic-type-medium)
    /// that bot output reads the same on both platforms.
    public static let chatFontSizeDefault: CGFloat = 14
    public static let chatFontSizeMin: CGFloat = 10
    public static let chatFontSizeMax: CGFloat = 32
}

enum PolarmacBootstrap {
    /// Wire PolarKit defaults into this bundle. Call once before the
    /// first UI loads (PolarmacApp.init). Keep this in sync with the
    /// Info.plist API_BASE_URL fallback chain in PolarKit's
    /// AppEnvironment.apiBaseURLString().
    static func configure() {
        AppEnvironment.defaultBaseURLString = "http://124.221.22.9/"
        KeychainStore.loginService = "com.change.polarmac.login"
    }
}
