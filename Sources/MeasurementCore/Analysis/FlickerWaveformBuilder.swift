import Foundation

/// Display-only re-derivation, kept apart from `RealFlickerAnalyzer` so the fixed
/// `FlickerAnalyzing` seam doesn't change to show a picture.
public enum FlickerWaveformBuilder {
    public static func fold(
        capture: RowBrightnessCapture,
        frequencyHz: Double,
        binCount: Int = 48
    ) -> FlickerWaveform? {
        guard frequencyHz > 0, let lineReadoutTime = capture.lineReadoutTime else { return nil }

        let period = 1.0 / frequencyHz
        var bins = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)

        for frame in capture.frames {
            for (row, value) in frame.rowBrightness.enumerated() {
                let time = frame.presentationTime + Double(row) * lineReadoutTime
                let rawPhase = time.truncatingRemainder(dividingBy: period) / period
                let normalizedPhase = rawPhase < 0 ? rawPhase + 1 : rawPhase
                let bin = min(binCount - 1, Int(normalizedPhase * Double(binCount)))
                bins[bin] += linearize(Double(value) / 255.0)
                counts[bin] += 1
            }
        }

        let folded = (0..<binCount).map { counts[$0] > 0 ? bins[$0] / Double(counts[$0]) : Double.nan }
        let observed = folded.filter { !$0.isNaN }
        guard let minValue = observed.min(), let maxValue = observed.max(), maxValue > minValue else {
            return nil
        }

        let points: [FlickerWaveform.Point] = folded.enumerated().compactMap { index, value in
            guard !value.isNaN else { return nil }
            let normalized = (value - minValue) / (maxValue - minValue)
            return FlickerWaveform.Point(phase: Double(index) / Double(binCount), brightness: normalized)
        }
        return FlickerWaveform(frequencyHz: frequencyHz, points: points)
    }

    /// Duplicated from `RealFlickerAnalyzer` so the picture never reaches into the analyzer.
    private static func linearize(_ code: Double) -> Double {
        let clamped = max(0, min(1, code))
        if clamped <= 0.081 {
            return clamped / 4.5
        }
        return pow((clamped + 0.099) / 1.099, 1.0 / 0.45)
    }
}
