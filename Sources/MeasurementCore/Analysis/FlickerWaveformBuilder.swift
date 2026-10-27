import Foundation

/// Display-only, kept separate from `RealFlickerAnalyzer` so showing a picture doesn't change the analyzer API.
public enum FlickerWaveformBuilder {
    /// Folds the flat-field ratio so the scene doesn't show up in the picture.
    /// Falls back to an assumed Rec.709 decode when uncalibrated, which is fine for display but never used for depth.
    public static func fold(
        capture: RowBrightnessCapture,
        frequencyHz: Double,
        binCount: Int = 48
    ) -> FlickerWaveform? {
        guard frequencyHz > 0, binCount > 1, let lineReadoutTime = capture.lineReadoutTime else { return nil }

        let display = capture.isLinear ? capture : linearizedForDisplay(capture)
        guard let field = try? FlatField.normalise(display) else { return nil }

        let period = 1.0 / frequencyHz
        let origin = field.presentationTimes.first ?? 0
        var bins = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)

        for (frameIndex, ratio) in field.ratios.enumerated() {
            let frameTime = field.presentationTimes[frameIndex] - origin
            for row in 0..<field.rowCount where field.usableRows[row] {
                let time = frameTime + Double(row) * lineReadoutTime
                let rawPhase = time.truncatingRemainder(dividingBy: period) / period
                let normalizedPhase = rawPhase < 0 ? rawPhase + 1 : rawPhase
                let bin = min(binCount - 1, Int(normalizedPhase * Double(binCount)))
                bins[bin] += Double(ratio[row])
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

    /// Rec.709 decode of black-subtracted row codes; display only.
    private static func linearizedForDisplay(_ capture: RowBrightnessCapture) -> RowBrightnessCapture {
        let frames = capture.frames.map { frame in
            RowBrightnessFrame(
                rowBrightness: frame.rowBrightness.map { Float(linearize(Double($0) / 255.0)) },
                presentationTime: frame.presentationTime,
                exposureDuration: frame.exposureDuration,
                iso: frame.iso,
                exposureMode: frame.exposureMode
            )
        }
        return RowBrightnessCapture(
            frames: frames,
            lineReadoutTime: capture.lineReadoutTime,
            isLinear: false,
            blackPointCode: capture.blackPointCode,
            rowMeanCodes: capture.rowMeanCodes,
            rowSaturated: capture.rowSaturated,
            rowBlackClipped: capture.rowBlackClipped,
            saturatedFraction: capture.saturatedFraction,
            crushedFraction: capture.crushedFraction,
            meanBrightness: capture.meanBrightness
        )
    }

    private static func linearize(_ code: Double) -> Double {
        let clamped = max(0, min(1, code))
        if clamped <= 0.081 {
            return clamped / 4.5
        }
        return pow((clamped + 0.099) / 1.099, 1.0 / 0.45)
    }
}
