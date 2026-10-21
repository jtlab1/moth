import Foundation

/// One definition of the IEEE 1789-2015 limits, so the analyser and UI can't disagree.
///
/// | Frequency        | No-observable-effect | Low-risk         |
/// |------------------|----------------------|------------------|
/// | f < 90 Hz        | Mod% < 0.01 × f      | Mod% < 0.025 × f |
/// | 90 ≤ f < 1250 Hz | Mod% < 0.0333 × f    | Mod% < 0.08 × f  |
/// | f ≥ 1250 Hz      | unrestricted         | unrestricted     |
public enum IEEE1789 {

    public static let unrestrictedAboveHz: Double = 1250
    public static let boundaryHz: Double = 90

    public static func noObservableEffectLimitPercent(frequencyHz: Double) -> Double? {
        guard frequencyHz > 0 else { return nil }
        guard frequencyHz < unrestrictedAboveHz else { return nil }
        return frequencyHz < boundaryHz ? 0.01 * frequencyHz : 0.0333 * frequencyHz
    }

    public static func lowRiskLimitPercent(frequencyHz: Double) -> Double? {
        guard frequencyHz > 0 else { return nil }
        guard frequencyHz < unrestrictedAboveHz else { return nil }
        return frequencyHz < boundaryHz ? 0.025 * frequencyHz : 0.08 * frequencyHz
    }

    /// Boundaries resolve to the safer region: rounding a boundary case towards alarm would
    /// overstate what was measured.
    public static func classify(frequencyHz: Double, modulationDepthPercent: Double) -> IEEE1789Verdict {
        guard let noEffect = noObservableEffectLimitPercent(frequencyHz: frequencyHz),
              let lowRisk = lowRiskLimitPercent(frequencyHz: frequencyHz) else {
            return .noObservableEffect
        }
        if modulationDepthPercent <= noEffect { return .noObservableEffect }
        if modulationDepthPercent <= lowRisk { return .lowRisk }
        return .exceedsLowRisk
    }

    public static func timesOverLowRiskLimit(
        frequencyHz: Double,
        modulationDepthPercent: Double
    ) -> Double? {
        guard let limit = lowRiskLimitPercent(frequencyHz: frequencyHz), limit > 0 else { return nil }
        let ratio = modulationDepthPercent / limit
        return ratio > 1 ? ratio : nil
    }
}

extension FlickerResult {
    /// Plain terms only: the raw frequency and depth are already shown alongside it.
    public var limitComparisonSentence: String? {
        guard let frequencyHz, let modulationDepthPercent else { return nil }
        guard IEEE1789.lowRiskLimitPercent(frequencyHz: frequencyHz) != nil else {
            return "At this speed, flicker isn't considered a health concern at any depth."
        }
        if let over = IEEE1789.timesOverLowRiskLimit(
            frequencyHz: frequencyHz, modulationDepthPercent: modulationDepthPercent
        ) {
            return String(format: "That's about %.1f times stronger than what's generally considered safe.", over)
        }
        return "This is within the range generally considered safe for how fast this light flickers."
    }
}
