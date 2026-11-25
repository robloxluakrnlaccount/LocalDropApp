import SwiftUI
import UIKit

// MARK: - Settings (mirrors the web version's localStorage keys: ld_theme, ld_accent, ld_mode, ld_name, ...)

enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let accents: [(name: String, hex: String)] = [
        ("Blue", "#5b9dff"), ("Green", "#3ecf8e"), ("Orange", "#ff9f43"),
        ("Pink", "#ff6b9d"), ("Purple", "#a78bfa"), ("Red", "#ff6b6b")
    ]

    private let d = UserDefaults.standard

    /// Address of the PC running server.py, e.g. http://192.168.1.20:8000
    @Published var serverAddress: String { didSet { d.set(serverAddress, forKey: "ld_server") } }
    /// The `ld_id` cookie the server uses to recognise this device's private space. Editable on purpose, see CookieIDSheet.
    @Published private(set) var cookieID: String { didSet { d.set(cookieID, forKey: "ld_cookie") } }
    @Published private(set) var cookieHistory: [String] { didSet { d.set(cookieHistory, forKey: "ld_cookie_history") } }
    @Published var deviceName: String { didSet { d.set(deviceName, forKey: "ld_name") } }
    @Published var theme: AppTheme { didSet { d.set(theme.rawValue, forKey: "ld_theme") } }
    @Published var accentHex: String { didSet { d.set(accentHex, forKey: "ld_accent") } }
    @Published var privateMode: String { didSet { d.set(privateMode, forKey: "ld_mode") } }   // "cookie" | "ip"
    @Published var showDates: Bool { didSet { d.set(showDates, forKey: "ld_show_dates") } }
    @Published var mediaBackdrop: Bool { didSet { d.set(mediaBackdrop, forKey: "ld_media_bg") } }
    @Published var customPlayer: Bool { didSet { d.set(customPlayer, forKey: "ld_custom_player") } }
    @Published var buttonFX: Bool { didSet { d.set(buttonFX, forKey: "ld_fx") } }
    @Published var animations: Bool { didSet { d.set(animations, forKey: "ld_anim") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "ld_vol") } }
    @Published var muted: Bool { didSet { d.set(muted, forKey: "ld_muted") } }

    var accent: Color { Color(hex: accentHex) }

    init() {
        let d = UserDefaults.standard
        serverAddress = d.string(forKey: "ld_server") ?? ""
        var ck = d.string(forKey: "ld_cookie") ?? ""
        if AppSettings.normalizeCookie(ck) == nil {
            ck = AppSettings.newCookieID()
            d.set(ck, forKey: "ld_cookie")
        }
        cookieID = ck
        cookieHistory = d.stringArray(forKey: "ld_cookie_history") ?? []
        deviceName = d.string(forKey: "ld_name") ?? AppSettings.defaultDeviceName
        theme = AppTheme(rawValue: d.string(forKey: "ld_theme") ?? "") ?? .dark
        accentHex = d.string(forKey: "ld_accent") ?? "#5b9dff"
        privateMode = d.string(forKey: "ld_mode") == "cookie" ? "cookie" : "ip"
        showDates = d.bool(forKey: "ld_show_dates")
        mediaBackdrop = d.bool(forKey: "ld_media_bg")
        customPlayer = d.object(forKey: "ld_custom_player") as? Bool ?? true
        buttonFX = d.bool(forKey: "ld_fx")
        animations = d.object(forKey: "ld_anim") as? Bool ?? true
        volume = d.object(forKey: "ld_vol") as? Double ?? 1
        muted = d.bool(forKey: "ld_muted")
    }

    static var defaultDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    // MARK: Cookie ID

    /// Random 32 lowercase hex characters, the exact shape server.py accepts (`[0-9a-f]{32}`).
    static func newCookieID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Cleans pasted text (spaces, dashes, upper case) and returns it only if it is a valid ID.
    static func normalizeCookie(_ raw: String) -> String? {
        let t = raw.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        guard t.count == 32, t.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return t
    }

    /// Switches to another ID and remembers the old one so it can be restored later.
    func setCookie(_ id: String) {
        guard id != cookieID else { return }
        var h = cookieHistory.filter { $0 != id && $0 != cookieID }
        h.insert(cookieID, at: 0)
        cookieHistory = Array(h.prefix(8))
        cookieID = id
    }

    func resetPreferences() {
        theme = .dark; accentHex = "#5b9dff"; privateMode = "ip"; deviceName = AppSettings.defaultDeviceName
        showDates = false; mediaBackdrop = false; customPlayer = true; buttonFX = false; animations = true
        volume = 1; muted = false
    }
}
