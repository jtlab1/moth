import Foundation
import Testing
import MeasurementCore
@testable import MothPersistence

@Suite("UserSettingsStorage")
struct UserSettingsStorageTests {
    /// Never `.standard`, so a developer's installed build can't leak in.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "moth.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    @Test("Nothing saved yet loads as nil, so the caller falls back to defaults")
    func firstLaunchLoadsNil() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(UserSettingsStorage(defaults: defaults).load() == nil)
    }

    @Test("Saved settings, including completed onboarding, survive a fresh storage instance")
    func settingsRoundTrip() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = UserSettings.default
        settings.hasCompletedOnboarding = true
        settings.appearance = .light
        settings.mainsRegion = MainsRegion.allCases.first
        UserSettingsStorage(defaults: defaults).save(settings)

        #expect(UserSettingsStorage(defaults: defaults).load() == settings)
    }
}
