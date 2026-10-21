import Foundation

/// Uses rolling-shutter row timing, not frame rate, whose Nyquist can't reach 100+ Hz flicker.
public struct RealFlickerAnalyzer: FlickerAnalyzing {
    public init() {}

    public func analyze(frames: FrameSequence, metadata: CaptureMetadata) async throws -> FlickerResult {
        try Task.checkCancellation()

        guard metadata.frames.count >= 3 else {
            throw AnalysisError.tooFewFrames(captured: metadata.frames.count, required: 3)
        }
        guard metadata.duration >= 1.0 else {
            throw AnalysisError.captureTooShort(duration: metadata.duration, required: 1.0)
        }

        let extracted = try RowBrightnessExtractor.extract(from: frames)

        guard extracted.crushedFraction < 0.9 else {
            throw AnalysisError.insufficientSignal(
                reason: "row brightness near black across \(Int(extracted.crushedFraction * 100))% of samples"
            )
        }

        let rowSignals = extracted.frames.map(\.rowBrightness)
        guard let coarse = try Periodogram.coarsePeak(rowSignals: rowSignals) else {
            throw AnalysisError.insufficientSignal(reason: "no usable periodogram from this capture")
        }

        let snr = coarse.noiseFloor > 0 ? Double(coarse.magnitude / coarse.noiseFloor) : Double(coarse.magnitude)
        let presence: FlickerPresence = snr >= 4 ? .present : (snr >= 2 ? .indeterminate : .absent)

        guard let lineReadoutTime = metadata.lineReadoutTime else {
            let tier = metadata.deviceCapability.clampedTier(.tier3)
            return FlickerResult(
                presence: presence,
                confidence: snr >= 6 ? .high : (snr >= 3 ? .medium : .low),
                tier: tier
            )
        }

        // Decided from what this capture did, not the hardware ceiling, and before the
        // presence branch so tier is reported the same way whether or not flicker was found.
        let stableExposure = metadata.hasStableExposure
            && metadata.frames.allSatisfy { $0.exposureMode != .automatic }
        let candidateTier: MeasurementTier = stableExposure ? .tier1 : .tier2
        let tier = metadata.deviceCapability.clampedTier(candidateTier)

        guard presence == .present else {
            return FlickerResult(
                presence: presence,
                confidence: snr < 1.5 ? .high : .medium,
                tier: tier
            )
        }

        if extracted.saturatedFraction > 0.3 {
            throw AnalysisError.sensorSaturated
        }

        if coarse.runnerUpRatio > 0.7, let runnerUpFrequency = coarse.runnerUpNormalizedFrequency {
            let candidates = [
                coarse.normalizedFrequency / lineReadoutTime,
                runnerUpFrequency / lineReadoutTime
            ].sorted()
            throw AnalysisError.ambiguousFrequency(candidates: candidates)
        }

        let coarseHz = coarse.normalizedFrequency / lineReadoutTime

        var timedSamples: [(time: TimeInterval, value: Float)] = []
        timedSamples.reserveCapacity(extracted.frames.reduce(0) { $0 + $1.rowBrightness.count })
        for frame in extracted.frames {
            for (row, value) in frame.rowBrightness.enumerated() {
                timedSamples.append((frame.presentationTime + Double(row) * lineReadoutTime, value))
            }
        }
        // A coarse bin can be tens of Hz wide, so the band must survive being off by a bin.
        let refinedHz = try Periodogram.refine(
            samples: timedSamples,
            coarseHz: coarseHz,
            bandHz: max(15, coarseHz * 0.15)
        )

        var modulationDepthPercent: Double?
        var verdict: IEEE1789Verdict?
        if tier == .tier1 {
            let depth = Self.modulationDepth(timedSamples: timedSamples, frequencyHz: refinedHz)
            modulationDepthPercent = depth
            verdict = IEEE1789.classify(frequencyHz: refinedHz, modulationDepthPercent: depth)
        }

        var confidence: MeasurementConfidence
        var diagnosticNote: String?
        if snr >= 8 && stableExposure {
            confidence = .high
        } else if snr >= 4 {
            confidence = .medium
        } else {
            confidence = .low
            diagnosticNote = "Signal was close to the noise floor; measure again closer to the fixture."
        }
        if !stableExposure, confidence == .high {
            confidence = .medium
        }

        return FlickerResult(
            frequencyHz: refinedHz,
            modulationDepthPercent: modulationDepthPercent,
            verdict: verdict,
            presence: .present,
            confidence: confidence,
            tier: tier,
            diagnosticNote: diagnosticNote
        )
    }

    /// Phase-folds rather than reading the fundamental alone, which understates the depth of
    /// square-wave PWM flicker.
    static func modulationDepth(timedSamples: [(time: TimeInterval, value: Float)], frequencyHz: Double) -> Double {
        guard frequencyHz > 0 else { return 0 }
        let period = 1.0 / frequencyHz
        let binCount = 64
        var bins = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)

        for sample in timedSamples {
            let rawPhase = sample.time.truncatingRemainder(dividingBy: period) / period
            let normalizedPhase = rawPhase < 0 ? rawPhase + 1 : rawPhase
            let bin = min(binCount - 1, Int(normalizedPhase * Double(binCount)))
            bins[bin] += linearize(Double(sample.value) / 255.0)
            counts[bin] += 1
        }

        let folded = (0..<binCount).compactMap { counts[$0] > 0 ? bins[$0] / Double(counts[$0]) : nil }
        guard let maxValue = folded.max(), let minValue = folded.min(), maxValue + minValue > 0 else { return 0 }
        return (maxValue - minValue) / (maxValue + minValue) * 100
    }

    /// Rec.709 gamma decode: depth is only meaningful in linear light. An unmeasured modelling
    /// assumption; no hardware was available to characterise a per-device curve.
    static func linearize(_ code: Double) -> Double {
        let clamped = max(0, min(1, code))
        if clamped <= 0.081 {
            return clamped / 4.5
        }
        return pow((clamped + 0.099) / 1.099, 1.0 / 0.45)
    }
}
