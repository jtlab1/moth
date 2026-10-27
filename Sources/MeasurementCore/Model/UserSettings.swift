import Foundation

/// No "match system" option, since the control would look broken whenever the system already agrees.
public enum AppearanceMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Defaults favour the sensory-sensitive user, not the median one.
public struct UserSettings: Sendable, Codable, Hashable {
    /// `nil` until chosen or inferred; a wrong value silently poisons calibration.
    public var mainsRegion: MainsRegion?
    public var hasCompletedOnboarding: Bool

    /// Dark by default: a bright screen in a room someone already finds hostile is a real cost.
    public var appearance: AppearanceMode

    /// Off by default: the raw readout time only invites "is 18.5 good?".
    public var debugModeEnabled: Bool

    /// System Reduce Motion also disables animations regardless of this value.
    public var animationsEnabled: Bool

    public init(
        mainsRegion: MainsRegion? = nil,
        hasCompletedOnboarding: Bool = false,
        appearance: AppearanceMode = .dark,
        debugModeEnabled: Bool = false,
        animationsEnabled: Bool = true
    ) {
        self.mainsRegion = mainsRegion
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.appearance = appearance
        self.debugModeEnabled = debugModeEnabled
        self.animationsEnabled = animationsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case mainsRegion, hasCompletedOnboarding, appearance, debugModeEnabled, animationsEnabled
    }

    /// Tolerates settings saved before `animationsEnabled` existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mainsRegion = try container.decodeIfPresent(MainsRegion.self, forKey: .mainsRegion)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .dark
        debugModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugModeEnabled) ?? false
        animationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .animationsEnabled) ?? true
    }

    public static let `default` = UserSettings()
}
