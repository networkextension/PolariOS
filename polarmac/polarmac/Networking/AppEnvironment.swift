import Foundation

enum AppEnvironment {
    static let baseURLUserDefaultsKey = "baseURL"
    static let workspaceIDUserDefaultsKey = "workspaceID"
    static let lastLoginEmailUserDefaultsKey = "lastLoginEmail"
    static let infoPlistBaseURLKey = "API_BASE_URL"
    static let chatFontSizeUserDefaultsKey = "chatFontSize"

    /// Chat body font size in points. Clamped to [10, 32] by the UI
    /// shortcuts; default 14 matches AppKit body, close enough to iOS's
    /// .preferredFont(forTextStyle: .body) (~17 dynamic-type-medium)
    /// that bot output reads the same on both platforms.
    static let chatFontSizeDefault: CGFloat = 14
    static let chatFontSizeMin: CGFloat = 10
    static let chatFontSizeMax: CGFloat = 32

    static var lastLoginEmail: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: lastLoginEmailUserDefaultsKey) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: lastLoginEmailUserDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastLoginEmailUserDefaultsKey)
            }
        }
    }

    static func apiBaseURLString() -> String {
        if let saved = UserDefaults.standard.string(forKey: baseURLUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        if let configured = (Bundle.main.object(forInfoDictionaryKey: infoPlistBaseURLKey) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }
        return "http://124.221.22.9/"
    }

    static func apiBaseURL() -> URL? {
        URL(string: apiBaseURLString())
    }

    /// Active workspace id sent as `X-Workspace-Id` on every request. nil
    /// means "let the server pick my personal team". Persisted across
    /// launches; updated by the workspace picker in Settings.
    static var currentWorkspaceID: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: workspaceIDUserDefaultsKey) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: workspaceIDUserDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: workspaceIDUserDefaultsKey)
            }
        }
    }

    static func absoluteURL(from rawPath: String) -> URL? {
        if let direct = URL(string: rawPath), direct.scheme != nil {
            return direct
        }
        guard let baseURL = apiBaseURL() else { return nil }
        return URL(string: rawPath, relativeTo: baseURL)?.absoluteURL
    }
}
