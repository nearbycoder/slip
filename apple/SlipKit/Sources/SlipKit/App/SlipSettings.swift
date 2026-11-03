import Foundation

public enum AppTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// User settings (IMPLEMENTATION.md "Settings"), persisted as JSON in UserDefaults.
public struct SlipSettings: Codable, Equatable, Sendable {
    public var alias: String
    public var port: Int
    public var useHTTPS: Bool
    /// Save directory path (desktop). nil = default (Downloads / iOS Documents).
    public var saveDirectoryPath: String?
    /// Security-scoped bookmark for a user-chosen save directory (sandboxed macOS).
    public var saveDirectoryBookmark: Data?
    public var quickSave: Bool
    public var requirePin: Bool
    public var pin: String
    public var discoverable: Bool
    public var theme: AppTheme
    public var notificationsEnabled: Bool
    public var showMenuBarExtra: Bool

    public init(alias: String = AliasGenerator.random(), port: Int = SlipConstants.defaultPort, useHTTPS: Bool = true,
                saveDirectoryPath: String? = nil, saveDirectoryBookmark: Data? = nil, quickSave: Bool = false,
                requirePin: Bool = false, pin: String = "", discoverable: Bool = true, theme: AppTheme = .system,
                notificationsEnabled: Bool = true, showMenuBarExtra: Bool = true) {
        self.alias = alias
        self.port = port
        self.useHTTPS = useHTTPS
        self.saveDirectoryPath = saveDirectoryPath
        self.saveDirectoryBookmark = saveDirectoryBookmark
        self.quickSave = quickSave
        self.requirePin = requirePin
        self.pin = pin
        self.discoverable = discoverable
        self.theme = theme
        self.notificationsEnabled = notificationsEnabled
        self.showMenuBarExtra = showMenuBarExtra
    }

    public init(from decoder: Decoder) throws {
        let d = SlipSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = (try? c.decode(String.self, forKey: .alias)) ?? d.alias
        port = (try? c.decode(Int.self, forKey: .port)) ?? d.port
        useHTTPS = (try? c.decode(Bool.self, forKey: .useHTTPS)) ?? d.useHTTPS
        saveDirectoryPath = try? c.decodeIfPresent(String.self, forKey: .saveDirectoryPath)
        saveDirectoryBookmark = try? c.decodeIfPresent(Data.self, forKey: .saveDirectoryBookmark)
        quickSave = (try? c.decode(Bool.self, forKey: .quickSave)) ?? d.quickSave
        requirePin = (try? c.decode(Bool.self, forKey: .requirePin)) ?? d.requirePin
        pin = (try? c.decode(String.self, forKey: .pin)) ?? d.pin
        discoverable = (try? c.decode(Bool.self, forKey: .discoverable)) ?? d.discoverable
        theme = (try? c.decode(AppTheme.self, forKey: .theme)) ?? d.theme
        notificationsEnabled = (try? c.decode(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        showMenuBarExtra = (try? c.decode(Bool.self, forKey: .showMenuBarExtra)) ?? d.showMenuBarExtra
    }

    public var transport: TransportProtocol { useHTTPS ? .https : .http }
    public var effectivePin: String? { requirePin && !pin.isEmpty ? pin : nil }

    static let defaultsKey = "slip.settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> SlipSettings {
        var settings: SlipSettings
        if let data = defaults.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(SlipSettings.self, from: data) {
            settings = s
        } else {
            settings = SlipSettings()
            settings.save(to: defaults)
        }
        // Developer overrides via launch arguments, e.g. `-SlipPort 53322 -SlipQuickSave YES`
        // (not persisted) so several instances can run on one host.
        if let port = defaults.object(forKey: "SlipPort") as? Int ?? (defaults.string(forKey: "SlipPort")).flatMap(Int.init) {
            settings.port = port
        }
        if defaults.object(forKey: "SlipQuickSave") != nil { settings.quickSave = defaults.bool(forKey: "SlipQuickSave") }
        if let alias = defaults.string(forKey: "SlipAlias") { settings.alias = alias }
        if let theme = defaults.string(forKey: "SlipTheme").flatMap(AppTheme.init(rawValue:)) { settings.theme = theme }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Default save directory: ~/Downloads on macOS, app Documents on iOS.
    public static var defaultSaveDirectory: URL {
        let fm = FileManager.default
        #if os(iOS)
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        #endif
    }
}
