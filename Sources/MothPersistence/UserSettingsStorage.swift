import Foundation
import MeasurementCore

/// Lives in `UserDefaults` instead of `MothStore` so it survives `wipeAll` and is readable before the store opens.
public struct UserSettingsStorage {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "moth.userSettings") {
        self.defaults = defaults
        self.key = key
    }

    /// `nil` on first launch or when unreadable.
    public func load() -> UserSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UserSettings.self, from: data)
    }

    public func save(_ settings: UserSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
