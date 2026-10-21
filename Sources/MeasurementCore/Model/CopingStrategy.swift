import Foundation

/// Labels only, with no efficacy claim: the app records what someone does, not what works.
public enum CopingStrategy: String, Sendable, Codable, CaseIterable, Identifiable {
    case headphones
    case tintedGlasses
    case takeBreaks
    case coverOrDimFixture
    case alternativeLightSource
    case requestFixtureSwap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .headphones: return "Wear headphones"
        case .tintedGlasses: return "Wear tinted glasses"
        case .takeBreaks: return "Take breaks from the room"
        case .coverOrDimFixture: return "Cover or dim the fixture"
        case .alternativeLightSource: return "Use a different light source"
        case .requestFixtureSwap: return "Ask about swapping the fixture"
        }
    }

    /// Swapped for a checkmark when checked, so state is never carried by color alone.
    public var iconName: String {
        switch self {
        case .headphones: return "headphones"
        case .tintedGlasses: return "eyeglasses"
        case .takeBreaks: return "figure.walk"
        case .coverOrDimFixture: return "lightbulb.slash"
        case .alternativeLightSource: return "lamp.desk"
        case .requestFixtureSwap: return "wrench.and.screwdriver"
        }
    }
}
