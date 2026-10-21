import Foundation

/// User-declared, never inferred: Moth measures light, it doesn't identify hardware.
public enum FixtureType: String, Sendable, Codable, CaseIterable, Identifiable {
    case ledPanel
    case fluorescentTube
    case incandescent
    case daylightOnly
    case mixed
    case unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ledPanel: return "LED panel"
        case .fluorescentTube: return "Fluorescent tube"
        case .incandescent: return "Incandescent"
        case .daylightOnly: return "Daylight only"
        case .mixed: return "Mixed"
        case .unknown: return "Unknown"
        }
    }

    public var hint: String {
        switch self {
        case .ledPanel: return "Flat rectangular ceiling panel or downlight"
        case .fluorescentTube: return "Long tube, often behind a diffuser"
        case .incandescent: return "Traditional filament bulb or halogen"
        case .daylightOnly: return "No electric light on"
        case .mixed: return "More than one kind of fixture lit"
        case .unknown: return "Not sure"
        }
    }

    public var iconName: String {
        switch self {
        case .ledPanel: return "rectangle.fill"
        case .fluorescentTube: return "light.strip.2"
        case .incandescent: return "lightbulb.fill"
        case .daylightOnly: return "sun.max.fill"
        case .mixed: return "square.grid.2x2.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Lamps flicker at twice mains frequency because they respond to voltage magnitude, not sign.
public enum MainsRegion: String, Sendable, Codable, CaseIterable, Identifiable {
    case hz50
    case hz60

    public var id: String { rawValue }

    /// Frequency the calibration reference fixture is expected to flicker at, in Hz.
    public var referenceFlickerFrequencyHz: Double {
        switch self {
        case .hz50: return 100
        case .hz60: return 120
        }
    }

    public var title: String {
        switch self {
        case .hz50: return "50 Hz mains"
        case .hz60: return "60 Hz mains"
        }
    }

    public var subtitle: String {
        switch self {
        case .hz50: return "Europe, UK, Africa, most of Asia, Australia"
        case .hz60: return "North America, most of South America, Japan (east), Korea"
        }
    }
}

extension MainsRegion {
    // Allowlists sourced from Wikipedia's "Mains electricity by country" (2026-09-22). Anything
    // absent, including split grids (Japan, Brazil, French Polynesia), returns `nil` so the user
    // is asked: a wrong silent default poisons every reading.

    private static let confident60HzRegionCodes: Set<String> = [
        "US", "CA", "MX", "CO", "CR", "CU", "DO", "EC", "SV", "GT", "GY", "HN",
        "HT", "JM", "NI", "PA", "PE", "PR", "KN", "SR", "VE", "PH", "TW", "SA",
        "KR", "GU", "AS", "FM", "LR", "SX", "BB", "AG", "KY", "BM"
    ]

    private static let confident50HzRegionCodes: Set<String> = [
        "GB", "IE", "FR", "DE", "ES", "PT", "IT", "NL", "BE", "LU", "CH", "AT",
        "DK", "SE", "NO", "FI", "IS", "PL", "CZ", "SK", "HU", "RO", "BG", "GR",
        "HR", "SI", "EE", "LV", "LT", "MT", "CY", "AU", "NZ", "IN", "CN", "ID",
        "MY", "SG", "TH", "VN", "ZA", "NG", "EG", "KE", "RU", "UA", "AE", "IL"
    ]

    /// `nil` means ask rather than assume.
    public static func inferred(fromRegionCode regionCode: String?) -> MainsRegion? {
        guard let regionCode else { return nil }
        if confident60HzRegionCodes.contains(regionCode) { return .hz60 }
        if confident50HzRegionCodes.contains(regionCode) { return .hz50 }
        return nil
    }
}
