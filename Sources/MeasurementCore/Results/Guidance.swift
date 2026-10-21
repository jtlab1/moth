import Foundation

/// Split at IEEE 1789's 90 Hz boundary because the harms differ: below it overlaps
/// seizure-trigger ranges, above it is headache and eye strain from PWM dimming.
public enum GuidanceFinding: String, Sendable, Hashable, CaseIterable, Identifiable {
    case exceedsLowRiskLimitBelow90Hz

    /// Above 1250 Hz the standard stops restricting.
    case exceedsLowRiskLimit90To1250Hz

    /// Tier 2/3: a capability finding about the instrument, not the room.
    case detectedNotGraded

    public var id: String { rawValue }
}

public struct GuidanceSource: Sendable, Hashable {
    public let name: String
    public let url: URL?

    public init(name: String, url: URL?) {
        self.name = name
        self.url = url
    }
}

/// Every rule cites a source except `detectedNotGraded`, which makes no external claim.
public struct GuidanceRule: Sendable, Hashable, Identifiable {
    public let finding: GuidanceFinding
    public var id: GuidanceFinding { finding }
    public let title: String
    /// Phrased as options or requests, never instructions or treatments.
    public let actions: [String]
    /// Plural because the frequency bands draw on sources that don't overlap.
    public let sources: [GuidanceSource]
}

/// Deterministic on purpose: the same measurement must always produce the same guidance.
public enum Guidance {
    public static let rules: [GuidanceFinding: GuidanceRule] = [
        .exceedsLowRiskLimitBelow90Hz: GuidanceRule(
            finding: .exceedsLowRiskLimitBelow90Hz,
            title: "This fixture flickers slower than 90 Hz, and more than IEEE 1789 recommends",
            actions: [
                "Ask about swapping this fixture for LED or incandescent lighting, or adding a filter to existing fluorescent tubes — both reduce flicker at the source.",
                "Ask about blocking this fixture instead — a cubicle wall, an office with a door, or a shade over the desk — or ask to turn off the overhead light and use task lighting.",
                "This flicker speed falls in the 3–30 Hz range general photosensitive-epilepsy guidance treats as a seizure risk, with 16–25 Hz flagged as most likely to trigger — worth mentioning if anyone using the room has that history."
            ],
            sources: [
                GuidanceSource(
                    name: "Job Accommodation Network (JAN), \"Photosensitivity\"",
                    url: URL(string: "https://askjan.org/limitations/Photosensitivity.cfm")
                ),
                GuidanceSource(
                    name: "Epilepsy Society, \"Photosensitive epilepsy\"",
                    url: URL(string: "https://epilepsysociety.org.uk/about-epilepsy/epileptic-seizures/seizure-triggers/photosensitive-epilepsy")
                )
            ]
        ),
        .exceedsLowRiskLimit90To1250Hz: GuidanceRule(
            finding: .exceedsLowRiskLimit90To1250Hz,
            title: "This fixture flickers between 90 Hz and 1250 Hz, and more than IEEE 1789 recommends",
            actions: [
                "Ask facilities whether the driver on this fixture can run at a higher PWM frequency, or switch to non-PWM (constant-current) dimming instead — both cut flicker without changing brightness.",
                "Ask about a filter over this fixture, or bringing in a personal lamp so it can be turned off, especially if headaches or eye strain follow time spent under it.",
                "If daylight reaches the room, ask to sit near a window instead of under this fixture."
            ],
            sources: [
                GuidanceSource(
                    name: "U.S. Department of Energy, Solid-State Lighting Program, \"Flicker Research\"",
                    url: URL(string: "https://www.energy.gov/cmei/ssl/flicker-research")
                ),
                GuidanceSource(
                    name: "American Migraine Foundation, \"Workplace Accommodations for People Living With Migraine\"",
                    url: URL(string: "https://americanmigrainefoundation.org/resource-library/workplace-accommodations-for-migraine/")
                ),
                GuidanceSource(
                    name: "Job Accommodation Network (JAN), \"Light\"",
                    url: URL(string: "https://askjan.org/workrelatedfunctions/Light.cfm")
                )
            ]
        ),
        .detectedNotGraded: GuidanceRule(
            finding: .detectedNotGraded,
            title: "Flicker was detected, but this device can't grade how severe it is",
            actions: [
                "Calibrate this iPhone once, using an older fluorescent or incandescent fixture, to unlock frequency measurement.",
                "Even calibrated, some iPhones can measure frequency but not modulation depth — that's a hardware limit, not a setup problem."
            ],
            sources: [
                GuidanceSource(name: "Moth's own tier system", url: nil)
            ]
        )
    ]

    /// Tier-safe because `verdict` is `nil` below Tier 1, so Tier 2 can only reach `.detectedNotGraded`.
    public static func findings(for flicker: FlickerResult) -> [GuidanceFinding] {
        switch flicker.severity {
        case .exceedsLowRisk:
            guard let frequencyHz = flicker.frequencyHz else { return [] }
            return frequencyHz < IEEE1789.boundaryHz
                ? [.exceedsLowRiskLimitBelow90Hz]
                : [.exceedsLowRiskLimit90To1250Hz]
        case .detectedUnrated: return [.detectedNotGraded]
        case .unknown, .none, .noObservableEffect, .lowRisk: return []
        }
    }

    public static func rules(for flicker: FlickerResult) -> [GuidanceRule] {
        findings(for: flicker).compactMap { rules[$0] }
    }
}
