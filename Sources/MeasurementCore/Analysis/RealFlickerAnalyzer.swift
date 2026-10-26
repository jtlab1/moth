import Accelerate
import Foundation

/// Uses rolling-shutter row timing, not frame rate, whose Nyquist can't reach 100+ Hz flicker.
///
/// Pipeline (spec C): per-pixel linearisation through the calibration's response curve →
/// flat-field ratio `r = v / M(row)` → frequency search in Hz (incoherent per-frame spectrum
/// above ~1.5 cycles per readout window, coherent across frames below it, coherent refine,
/// frame-rate alias check) → exposure-corrected Fourier depth from a phase fold → presence in
/// modulation units → confidence from split halves, motion and capture conditions.
/// Every threshold is the same on every phone; none depends on the sensor's noise level.
public struct RealFlickerAnalyzer: FlickerAnalyzing {
    public init() {}

    // MARK: Search limits

    /// Below this, "flicker" is indistinguishable from hand motion and exposure drift.
    static let lowestFrequencyHz: Double = 20
    static let highestFrequencyHz: Double = 10_000

    /// Fraction of the row sampling rate (1/L) searched; above it a row mean blurs the cycle.
    static let rowNyquistFraction: Double = 0.4

    /// The incoherent per-frame stage needs this many cycles inside one frame's readout to
    /// resolve a peak; below it the coherent cross-frame stage takes over.
    static let cyclesPerReadoutFloor: Double = 1.5

    /// Coherent lines are ~1/duration (0.25 Hz) wide; 0.05 Hz loses at most ~3% power between
    /// grid points.
    static let coherentGridStepHz: Double = 0.05
    static let fineGridStepHz: Double = 0.002

    /// A runner-up alias tooth at ≥ `CaptureStandard.aliasAmbiguityRatio` of the best power
    /// is only ambiguous if the best's amplitude lead is under this many noise sigmas: with a
    /// short readout window the teeth differ by a few percent, which a clean capture still
    /// resolves.
    static let aliasDeficitSigma: Double = 6

    /// Caps the alias teeth's assumed noise correlation, so the deficit test never demands
    /// less than σ·√0.02 of lead.
    static let maximumAliasNoiseCorrelation: Double = 0.99

    /// A slow brightness change (drift, an exposure or hand wobble) moves every frame's mean,
    /// which the cross-frame transform sees as teeth at n × fps ± its rate. A peak that its
    /// own slow tooth (|f − n·fps| < fps/2, below the search) explains at least as well is
    /// such a tooth, not flicker: its teeth within this many Hz are excluded and the search
    /// rerun, up to `maximumSlowAliasExclusions` times.
    static let slowAliasExclusionHz: Double = 0.5
    static let maximumSlowAliasExclusions = 3

    /// Slow teeth this close to 0 Hz are already removed by the flat field.
    static let minimumSlowAliasHz: Double = 0.1

    // MARK: Conditions

    /// Read-back exposure or ISO further than this from its median counts as unstable.
    static let stableExposureTolerance: Double = 0.01

    /// RMS (ratio units) of the per-frame line fitted to the residual; above it the phone
    /// moved or the scene changed enough to cost confidence.
    static let motionResidualLimit: Double = 0.01

    /// …or above this fraction of the fundamental, whichever is larger: a deep, sharp PWM
    /// leaves fold-model residue of a few percent of its swing with no motion at all, and
    /// motion matters only relative to the flicker it could corrupt.
    static let motionResidualAmplitudeFraction: Double = 0.05

    /// A kept harmonic in the top half of the exposure's band at least this fraction of the
    /// fundamental means the spectrum was cut off rather than decayed: reconstruct with
    /// Lanczos σ-factors so the cut doesn't ring (Gibbs overshoot reads as ~18% extra depth).
    static let truncationHarmonicRatio: Double = 0.02

    static let reconstructionPoints = 512

    /// Alternating least-squares passes refining M(row) against the fold model; two converge.
    static let flatFieldRefinements = 2

    public func analyze(frames: FrameSequence, metadata: CaptureMetadata) async throws -> FlickerResult {
        try Task.checkCancellation()

        guard metadata.frames.count >= 3 else {
            throw AnalysisError.tooFewFrames(captured: metadata.frames.count, required: 3)
        }
        guard metadata.duration >= 1.0 else {
            throw AnalysisError.captureTooShort(duration: metadata.duration, required: 1.0)
        }

        let curve = metadata.responseCurve
        let exposure = ExposureSummary(metadata: metadata)
        let extracted = try RowBrightnessExtractor.extract(from: frames, response: curve)
        // ISO × exposure gain changes divide out exactly only in linear units.
        let field = try FlatField.normalise(extracted, frameGains: curve == nil ? nil : exposure.relativeGains)
        try Task.checkCancellation()

        guard let lineReadoutTime = metadata.lineReadoutTime, lineReadoutTime > 0 else {
            return try presenceOnly(field: field, metadata: metadata, exposure: exposure)
        }
        return try calibrated(field: field, metadata: metadata, exposure: exposure, lineReadoutTime: lineReadoutTime)
    }

    // MARK: - Tier 1 / 2

    private func calibrated(
        field: FlatFieldCapture,
        metadata: CaptureMetadata,
        exposure: ExposureSummary,
        lineReadoutTime: TimeInterval
    ) throws -> FlickerResult {
        var notes: [String] = []
        let rows = field.rowCount
        let frameCount = field.frameCount
        let allFrames = 0..<frameCount
        let deviations = field.deviations()
        let readoutWindow = Double(rows) * lineReadoutTime
        let frameRate = Self.measuredFrameRate(field.presentationTimes) ?? metadata.nominalFrameRate
        let floorHz = max(Self.lowestFrequencyHz, Self.cyclesPerReadoutFloor / readoutWindow)
        let ceilingHz = min(Self.rowNyquistFraction / lineReadoutTime, Self.highestFrequencyHz)
        guard ceilingHz > 2 * Self.lowestFrequencyHz else {
            throw AnalysisError.insufficientSignal(reason: "line readout time leaves no searchable band")
        }

        let spectra = try FrameSpectra(signals: deviations, maxNormalizedFrequency: ceilingHz * lineReadoutTime)
        let coherent = CoherentSpectrum(
            spectra: spectra,
            presentationTimes: field.presentationTimes,
            lineReadoutTime: lineReadoutTime,
            usableRows: field.usableRows
        )
        // Wide enough to absorb the per-frame stage's uncertainty and to hold ±2 alias teeth.
        let halfBand = max(0.5 / readoutWindow, 2 * frameRate)
        let search = SearchBand(lowHz: Self.lowestFrequencyHz, highHz: ceilingHz)

        // Stage 1: incoherent per-frame spectrum of detrended rows (refined coherently below).
        var stageOneHz: Double?
        if floorHz < ceilingHz {
            let detrender = FlatField.Detrender(usableRows: field.usableRows)
            let detrended = deviations.map(detrender.detrend)
            let hann = try FrameSpectra(signals: detrended, maxNormalizedFrequency: ceilingHz * lineReadoutTime, window: .hann)
            let spectrum = hann.incoherentSpectrum()
            let padded = Double(hann.paddedLength)
            let lowBin = max(1, Int(ceil(floorHz * lineReadoutTime * padded)))
            let highBin = min(hann.storedBins - 2, Int(floor(ceilingHz * lineReadoutTime * padded)))
            if highBin > lowBin {
                let peakBin = (lowBin...highBin).max { spectrum[$0] < spectrum[$1] }!
                let offset = Self.parabolicOffset(spectrum, at: peakBin, within: lowBin...highBin)
                stageOneHz = (Double(peakBin) + offset) / padded / lineReadoutTime
            }
        }

        // Stage 1b (coherent, 20 Hz up to the incoherent stage's floor), the coherent peak
        // around stage 1's, then stage 2's coherent refine with the frame-rate alias teeth in
        // view. Repeated with the teeth of any slow brightness change excluded (`slowAlias`).
        var slowAliases: [Double] = []
        func searchCoherently() throws -> Refined {
            let excluded: ((Double) -> Bool)? = slowAliases.isEmpty ? nil : { hz in
                Self.isSlowAliasTooth(hz, of: slowAliases, frameRate: frameRate)
            }
            var candidates: [Double] = []
            if floorHz > search.lowHz {
                let peak = try Self.gridPeak(coherent, from: search.lowHz, to: min(floorHz, ceilingHz), step: Self.coherentGridStepHz, frames: allFrames, excluding: excluded)
                candidates.append(peak.frequency)
            }
            if let stageOneHz {
                let peak = try Self.gridPeak(
                    coherent,
                    from: max(search.lowHz, stageOneHz - halfBand),
                    to: min(search.highHz, stageOneHz + halfBand),
                    step: Self.coherentGridStepHz,
                    frames: allFrames,
                    excluding: excluded
                )
                candidates.append(peak.frequency)
            }
            guard !candidates.isEmpty else {
                throw AnalysisError.insufficientSignal(reason: "no searchable frequency band")
            }
            let coarseHz = candidates.max {
                coherent.amplitude(atHz: $0, frames: allFrames) < coherent.amplitude(atHz: $1, frames: allFrames)
            }!
            var refined = try Self.refine(coherent, around: coarseHz, halfBand: halfBand, frameRate: frameRate, search: search, frames: allFrames, excluding: excluded)
            // Stage 1's peak can sit further from the line than the refine band (a few
            // per-frame resolutions when saturated rows leave the frame gappy), and the
            // refine then settles on an alias tooth. The true line is the strongest tooth.
            let tooth = Self.strongestAliasTooth(
                coherent, of: refined.frequency, frameRate: frameRate,
                span: max(halfBand, Self.aliasToothSpanResolutions / readoutWindow),
                search: search, frames: allFrames, excluding: excluded
            )
            if abs(tooth - refined.frequency) > frameRate / 2 {
                refined = try Self.refine(coherent, around: tooth, halfBand: halfBand, frameRate: frameRate, search: search, frames: allFrames, excluding: excluded)
            }
            return refined
        }
        var refined = try searchCoherently()
        var onlySlowVariation = false
        for attempt in 0...Self.maximumSlowAliasExclusions {
            guard let slow = Self.slowAlias(coherent, frequency: refined.frequency, frameRate: frameRate, frames: allFrames) else { break }
            guard attempt < Self.maximumSlowAliasExclusions else {
                onlySlowVariation = true
                break
            }
            slowAliases.append(slow)
            refined = try searchCoherently()
        }
        if onlySlowVariation {
            var penalties = ConfidencePenalties()
            penalties.applyConditions(metadata.conditions, exposure: exposure)
            let (tier, tierNotes) = Self.calibratedTier(metadata: metadata, exposure: exposure)
            return FlickerResult(
                presence: .indeterminate,
                confidence: penalties.apply(to: .low),
                tier: tier,
                diagnosticNotes: tierNotes
                    + ["The light's brightness changed slowly during the capture, which hid any flicker; hold the phone still and measure again."]
                    + penalties.notes,
                conditions: metadata.conditions,
                responseCurveApplied: metadata.responseCurve != nil
            )
        }

        // A light whose 2nd or 3rd harmonic outshines its fundamental (magnetic ballasts,
        // short-duty PWM) still repeats at the fundamental, which is what IEEE 1789 rates.
        let geometry = FoldGeometry(field: field, lineReadoutTime: lineReadoutTime)
        var frequency = refined.frequency
        for _ in 0..<2 {
            guard let fundamental = try Self.subharmonic(
                of: frequency, field: field, geometry: geometry, coherent: coherent,
                exposure: exposure.medianDuration, frameRate: frameRate, search: search, frames: allFrames
            ) else { break }
            // Located on the residual, where the stronger harmonic's alias teeth (which a
            // refine on the full spectrum would land on) are gone; the harmonic relation
            // already fixes which tooth is the line.
            frequency = fundamental
            refined = Refined(
                frequency: fundamental,
                power: coherent.sinusoidFit(atHz: fundamental, frames: allFrames).explainedPower,
                runnerUpFrequency: nil,
                runnerUpPower: 0
            )
        }
        try Task.checkCancellation()

        // Model, residual and noise. The residual's own per-frame spectrum at a frequency is the
        // noise there, correlated noise (motion, scene) included.
        let exposureDuration = exposure.medianDuration
        // Now the frequency is known, M(row) can be re-estimated with the flicker modelled
        // instead of averaged out: v = M(row) · w(phase), solved by alternating least squares.
        // With uniform phase drift this is the plain temporal mean; with only a few cycles of
        // drift (e.g. 2 kHz at 29 fps) the plain mean keeps a row-locked residue of the flicker
        // that biases depth and inflates the noise estimate.
        var field = field
        for _ in 0..<Self.flatFieldRefinements {
            let fold = PhaseFold(geometry: geometry, field: field, frequency: frequency, frames: allFrames)
            guard let factors = fold.rowGains(geometry: geometry, field: field, frequency: frequency) else { break }
            field = field.rescalingRows(by: factors)
        }
        let fold = PhaseFold(geometry: geometry, field: field, frequency: frequency, frames: allFrames)
        let residuals = fold.residuals(geometry: geometry, field: field, frequency: frequency, frames: allFrames)
        let harmonicLimit = Self.harmonicLimit(frequency: frequency, exposure: exposureDuration, lineReadoutTime: lineReadoutTime, binCount: fold.binCount)
        let residualSpectra = try FrameSpectra(
            signals: residuals,
            maxNormalizedFrequency: Double(max(1, harmonicLimit)) * frequency * lineReadoutTime
        )
        let samplesPerFrame = field.usableRowCount
        func noiseSigma(harmonic: Int, frames: Range<Int>) -> Double {
            let power = residualSpectra.summedPower(atNormalizedFrequency: Double(harmonic) * frequency * lineReadoutTime, frames: frames)
            return 2 * (power / 2).squareRoot() / Double(max(1, samplesPerFrame * frames.count))
        }

        let amplitude = coherent.sinusoidFit(atHz: frequency, frames: allFrames).amplitude
        let sigma = max(noiseSigma(harmonic: 1, frames: allFrames), .leastNonzeroMagnitude)
        let significance = amplitude / sigma
        let exposureGain = abs(Self.sinc(frequency * exposureDuration))
        let gainFloor = max(exposureGain, CaptureStandard.minimumExposureSincGain)
        let depthEstimate = 100 * amplitude / gainFloor
        let depthEstimateSigma = 100 * sigma / gainFloor
        let presence = Self.presence(significance: significance, depthPercent: depthEstimate)

        // Tier, decided from what this capture did, before the presence branch so it reads the
        // same whether or not flicker was found.
        let (tier, tierNotes) = Self.calibratedTier(metadata: metadata, exposure: exposure)
        notes.append(contentsOf: tierNotes)

        var penalties = ConfidencePenalties()
        penalties.applyConditions(metadata.conditions, exposure: exposure)

        guard presence == .present else {
            let base: MeasurementConfidence
            switch presence {
            case .absent:
                base = depthEstimate + 3 * depthEstimateSigma < CaptureStandard.presenceDepthFloorPercent ? .high : .medium
            default:
                base = .low
                notes.append("A faint signal was close to the noise floor; measure again closer to the light.")
            }
            notes.append(contentsOf: penalties.notes)
            return FlickerResult(
                presence: presence,
                confidence: penalties.apply(to: base),
                tier: tier,
                diagnosticNotes: notes,
                conditions: metadata.conditions,
                responseCurveApplied: metadata.responseCurve != nil
            )
        }

        // Alias teeth: frame-rate-spaced copies of the line that only within-frame timing tells apart.
        if let runnerUp = refined.runnerUpFrequency,
           refined.runnerUpPower >= CaptureStandard.aliasAmbiguityRatio * refined.power {
            let runnerUpAmplitude = coherent.sinusoidFit(atHz: runnerUp, frames: allFrames).amplitude
            // Both teeth are estimated from the same samples, their noise correlated about
            // as strongly as the teeth resemble each other (ρ ≈ runner-up / best), so the
            // lead's noise is σ·√(2(1 − ρ)), not the independent σ·√2.
            let correlation = min(Self.maximumAliasNoiseCorrelation, max(0, runnerUpAmplitude / amplitude))
            if amplitude - runnerUpAmplitude < Self.aliasDeficitSigma * sigma * (2 * (1 - correlation)).squareRoot() {
                throw AnalysisError.ambiguousFrequency(candidates: [frequency, runnerUp].sorted())
            }
        }

        // Depth (Tier 1 only).
        let phaseDrift = Self.phaseDriftCycles(frequency: frequency, frameRate: frameRate, frameCount: frameCount)
        var depth: HarmonicDepth?
        if tier == .tier1 {
            if exposureGain < CaptureStandard.minimumExposureSincGain {
                notes.append("This light flickers too fast for the exposure to measure its depth.")
            } else if phaseDrift < 1 {
                notes.append("This light's flicker stayed in step with the camera's frame rate, so its depth couldn't be measured.")
                penalties.add("Flicker in step with the frame rate left part of its cycle unsampled.")
            } else if fold.coverage < CaptureStandard.minimumPhaseFoldBinCoverage {
                notes.append("Not enough of the flicker cycle was sampled to measure its depth.")
                penalties.add("Part of the flicker cycle went unsampled.")
            } else {
                depth = Self.harmonicDepth(
                    fold: fold,
                    frequency: frequency,
                    exposure: exposureDuration,
                    harmonicLimit: harmonicLimit,
                    noise: { noiseSigma(harmonic: $0, frames: allFrames) }
                )
                if depth == nil {
                    notes.append("The flicker's shape couldn't be recovered from the noise, so its depth wasn't measured.")
                }
            }
        }
        if depth != nil, metadata.responseCurve?.isStandardAssumption == true {
            notes.append("Depth uses the standard camera light response, because this phone's own couldn't be measured during calibration.")
            penalties.add("The camera's light response was assumed, not measured.")
        }
        if let depth, depth.isApproximate {
            notes.append("Depth is approximate: this light flickers fast enough that the exposure blurs the shape of each cycle.")
            penalties.add("The exposure blurred the flicker's shape.")
        }

        // Split halves: the same answer from each half of the capture, independently.
        if frameCount >= 6 {
            let halves = [0..<(frameCount / 2), (frameCount / 2)..<frameCount]
            var halfFrequencies: [Double] = []
            var halfDepths: [Double] = []
            for half in halves {
                let halfRefined = try Self.refine(
                    coherent,
                    around: frequency,
                    halfBand: 1.5 * frameRate,
                    frameRate: frameRate,
                    search: search,
                    frames: half
                )
                halfFrequencies.append(halfRefined.frequency)
                if depth != nil {
                    let halfFold = PhaseFold(geometry: geometry, field: field, frequency: frequency, frames: half)
                    if let halfDepth = Self.harmonicDepth(
                        fold: halfFold,
                        frequency: frequency,
                        exposure: exposureDuration,
                        harmonicLimit: harmonicLimit,
                        noise: { noiseSigma(harmonic: $0, frames: half) }
                    ) {
                        halfDepths.append(halfDepth.depthPercent)
                    }
                }
            }
            let frequencyAgrees = abs(halfFrequencies[0] - halfFrequencies[1]) / frequency
                <= CaptureStandard.splitHalfFrequencyTolerance
            var depthAgrees = true
            if let depth, halfDepths.count == 2 {
                let tolerance = max(
                    CaptureStandard.splitHalfDepthTolerancePoints,
                    CaptureStandard.splitHalfDepthToleranceFraction * depth.depthPercent
                )
                depthAgrees = abs(halfDepths[0] - halfDepths[1]) <= tolerance
            }
            if !frequencyAgrees || !depthAgrees {
                penalties.add("The two halves of the capture disagreed; the light or the phone may have changed mid-capture.")
            }
        }

        // Motion: a large smooth per-frame trend left after the flicker model is removed.
        let detrender = FlatField.Detrender(usableRows: field.usableRows)
        var trendSquares: Double = 0
        for residual in residuals {
            let trend = detrender.trend(residual)
            trendSquares += trend.offset * trend.offset + trend.slope * trend.slope / 3
        }
        let motionResidual = (trendSquares / Double(max(1, residuals.count))).squareRoot()
        if motionResidual > max(Self.motionResidualLimit, Self.motionResidualAmplitudeFraction * amplitude) {
            penalties.add("The phone or the scene moved during the capture; hold the phone still against something.")
        }

        // Base confidence from how far the flicker stands above the noise.
        let base: MeasurementConfidence
        if significance >= 10 {
            base = .high
        } else if significance >= 6 {
            base = .medium
        } else {
            base = .low
            notes.append("Signal was close to the noise floor; measure again closer to the fixture.")
        }
        if let depth, depth.depthPercent > 0, depth.uncertaintyPercent > 0.1 * depth.depthPercent {
            penalties.add("The depth estimate is uncertain at this signal level.")
        }
        notes.append(contentsOf: penalties.notes)

        let depthPercent = depth?.depthPercent
        return FlickerResult(
            frequencyHz: frequency,
            modulationDepthPercent: depthPercent,
            verdict: depthPercent.map { IEEE1789.classify(frequencyHz: frequency, modulationDepthPercent: $0) },
            presence: .present,
            confidence: penalties.apply(to: base),
            tier: tier,
            diagnosticNotes: notes,
            conditions: metadata.conditions,
            responseCurveApplied: metadata.responseCurve != nil
        )
    }

    /// Tier 1 unless the calibration lacks a response curve or this capture left the
    /// standard; always clamped by the device. Notes only where Tier 1 was attainable.
    static func calibratedTier(metadata: CaptureMetadata, exposure: ExposureSummary) -> (MeasurementTier, [String]) {
        var candidateTier = MeasurementTier.tier1
        var tierNotes: [String] = []
        if metadata.responseCurve == nil {
            candidateTier = .tier2
            tierNotes.append("This calibration has no camera response curve, so depth wasn't measured. Recalibrate to unlock depth.")
        }
        if !exposure.isStable {
            candidateTier = .tier2
            tierNotes.append("Exposure changed during the capture, so depth wasn't measured.")
        }
        if !exposure.isStandard {
            candidateTier = .tier2
            tierNotes.append("The camera didn't hold the standard 1/4000 s exposure, so depth wasn't measured.")
        }
        let tier = metadata.deviceCapability.clampedTier(candidateTier)
        return (tier, metadata.deviceCapability.maximumAttainableTier == .tier1 ? tierNotes : [])
    }

    // MARK: - Tier 3

    /// Uncalibrated: rows can't map to time, so the test runs in cycles per row on the same
    /// ratio data, and amplitude stays uncorrected for exposure (frequency is unknown).
    private func presenceOnly(
        field: FlatFieldCapture,
        metadata: CaptureMetadata,
        exposure: ExposureSummary
    ) throws -> FlickerResult {
        let rows = field.rowCount
        let detrender = FlatField.Detrender(usableRows: field.usableRows)
        let detrended = field.deviations().map(detrender.detrend)
        let hann = try FrameSpectra(signals: detrended, maxNormalizedFrequency: Self.rowNyquistFraction, window: .hann)
        let spectrum = hann.incoherentSpectrum()
        let padded = Double(hann.paddedLength)
        let binsPerResolution = max(1, Int(padded / Double(rows)))
        let lowBin = max(2 * binsPerResolution, Int(ceil(Self.cyclesPerReadoutFloor / Double(rows) * padded)))
        let highBin = min(hann.storedBins - 2, Int(Self.rowNyquistFraction * padded))
        guard highBin > lowBin else {
            throw AnalysisError.insufficientSignal(reason: "too few rows for a spectrum")
        }
        let range = lowBin...highBin
        let peakBin = range.max { spectrum[$0] < spectrum[$1] }!
        let guardBins = 3 * binsPerResolution
        let background = range.filter { abs($0 - peakBin) > guardBins }.map { spectrum[$0] }
        let noiseFloor = max(Self.median(background) ?? 0, .leastNonzeroMagnitude)
        let excess = max(0, spectrum[peakBin] - noiseFloor)
        // Averaged over frames the floor's own scatter is floor/√frames.
        let significance = excess / (noiseFloor / Double(max(1, field.frameCount)).squareRoot())
        let amplitude = 2 * excess.squareRoot() / hann.windowSum
        let depthEstimate = 100 * amplitude
        let presence = Self.presence(significance: significance, depthPercent: depthEstimate)

        var penalties = ConfidencePenalties()
        penalties.applyConditions(metadata.conditions, exposure: exposure)
        var notes: [String] = []
        let base: MeasurementConfidence
        switch presence {
        case .present:
            base = significance >= 10 ? .high : (significance >= 6 ? .medium : .low)
        case .absent:
            base = depthEstimate < CaptureStandard.absentDepthCeilingPercent / 2 ? .high : .medium
        case .indeterminate:
            base = .low
            notes.append("A faint signal was close to the noise floor; measure again closer to the light.")
        }
        notes.append(contentsOf: penalties.notes)
        return FlickerResult(
            presence: presence,
            confidence: penalties.apply(to: base),
            tier: metadata.deviceCapability.clampedTier(.tier3),
            diagnosticNotes: notes,
            conditions: metadata.conditions,
            responseCurveApplied: metadata.responseCurve != nil
        )
    }

    // MARK: - Presence

    /// Standardised in modulation units, so the same light reads the same on every phone.
    static func presence(significance: Double, depthPercent: Double) -> FlickerPresence {
        if significance >= CaptureStandard.presentSignificanceSigma,
           depthPercent >= CaptureStandard.presenceDepthFloorPercent {
            return .present
        }
        if significance < CaptureStandard.absentSignificanceSigma
            || depthPercent < CaptureStandard.absentDepthCeilingPercent {
            return .absent
        }
        return .indeterminate
    }

    // MARK: - Frequency search helpers

    struct SearchBand {
        let lowHz: Double
        let highHz: Double
    }

    struct Refined {
        let frequency: Double
        let power: Double
        let runnerUpFrequency: Double?
        let runnerUpPower: Double
    }

    static func gridPeak(
        _ coherent: CoherentSpectrum,
        from lowHz: Double,
        to highHz: Double,
        step: Double,
        frames: Range<Int>,
        excluding excluded: ((Double) -> Bool)? = nil
    ) throws -> (frequency: Double, power: Double, grid: [Double]) {
        let count = max(1, Int(((highHz - lowHz) / step).rounded(.up)) + 1)
        var grid = try coherent.power(fromHz: lowHz, stepHz: step, count: count, frames: frames)
        if let excluded {
            for index in grid.indices where excluded(lowHz + Double(index) * step) { grid[index] = 0 }
        }
        let best = grid.indices.max { grid[$0] < grid[$1] }!
        return (lowHz + Double(best) * step, grid[best], grid)
    }

    /// Coherent grid over `around ± halfBand`, then a fine grid and a parabola around the best
    /// point. The runner-up is the strongest point at least half a frame rate away: in practice
    /// the nearest alias tooth.
    static func refine(
        _ coherent: CoherentSpectrum,
        around centre: Double,
        halfBand: Double,
        frameRate: Double,
        search: SearchBand,
        frames: Range<Int>,
        excluding excluded: ((Double) -> Bool)? = nil
    ) throws -> Refined {
        let low = max(search.lowHz, centre - halfBand)
        let high = min(search.highHz, centre + halfBand)
        let coarse = try gridPeak(coherent, from: low, to: high, step: coherentGridStepHz, frames: frames, excluding: excluded)
        let coarseBest = coarse.frequency

        var runnerUpFrequency: Double?
        var runnerUpPower: Double = 0
        for (index, power) in coarse.grid.enumerated() {
            let candidate = low + Double(index) * coherentGridStepHz
            if abs(candidate - coarseBest) >= frameRate / 2, power > runnerUpPower {
                runnerUpPower = power
                runnerUpFrequency = candidate
            }
        }
        if let runner = runnerUpFrequency {
            let fine = fitPeak(coherent, around: runner, frames: frames)
            runnerUpFrequency = fine.frequency
            runnerUpPower = fine.power
        }

        let fine = fitPeak(coherent, around: coarseBest, frames: frames)
        let frequency = fine.frequency
        return Refined(frequency: frequency, power: fine.power, runnerUpFrequency: runnerUpFrequency, runnerUpPower: runnerUpPower)
    }

    /// Real-sinusoid least-squares power on a fine grid around `centre`, then a parabola.
    static func fitPeak(_ coherent: CoherentSpectrum, around centre: Double, frames: Range<Int>) -> (frequency: Double, power: Double) {
        let halfWidth = 1.5 * coherentGridStepHz
        let count = Int((2 * halfWidth / fineGridStepHz).rounded()) + 1
        let low = centre - halfWidth
        let powers = (0..<count).map { coherent.sinusoidFit(atHz: low + Double($0) * fineGridStepHz, frames: frames).explainedPower }
        let best = powers.indices.max { powers[$0] < powers[$1] }!
        let offset = parabolicOffset(powers, at: best, within: 0...(count - 1))
        return (low + (Double(best) + offset) * fineGridStepHz, powers[best])
    }

    /// The slow tooth `|f − n·fps|` of `frequency`, if `frequency` is better read as a
    /// frame-rate alias of a slow brightness change than as flicker. A flicker at f puts
    /// s² of its power on its slow tooth, s = |within-frame transform at n·fps| (≈ sinc(n·fps·W));
    /// a slow change at the slow tooth puts s² of its power on f. The cut sits between (power
    /// ratio ≥ s), never below `aliasAmbiguityRatio`, so for n ≥ 2 only a clearly dominant
    /// slow tooth vetoes.
    static func slowAlias(_ coherent: CoherentSpectrum, frequency: Double, frameRate: Double, frames: Range<Int>) -> Double? {
        guard frameRate > 0, frequency > frameRate / 2 else { return nil }
        let harmonic = (frequency / frameRate).rounded()
        let slow = abs(frequency - harmonic * frameRate)
        guard slow >= minimumSlowAliasHz else { return nil }
        let atSlow = coherent.sinusoidFit(atHz: slow, frames: frames).explainedPower
        let atPeak = coherent.sinusoidFit(atHz: frequency, frames: frames).explainedPower
        let response = coherent.withinFrameResponse(offsetHz: harmonic * frameRate)
        let cut = max(response, CaptureStandard.aliasAmbiguityRatio)
        return atSlow >= cut * atPeak ? slow : nil
    }

    /// Per-frame resolutions (1 / readout window) either side of a peak whose alias teeth
    /// are compared; within it the within-frame transform still separates them.
    static let aliasToothSpanResolutions: Double = 2

    /// The frame-rate alias tooth `frequency + n·fps` (|n·fps| ≤ `span`) with the most
    /// explained power.
    static func strongestAliasTooth(
        _ coherent: CoherentSpectrum,
        of frequency: Double,
        frameRate: Double,
        span: Double,
        search: SearchBand,
        frames: Range<Int>,
        excluding excluded: ((Double) -> Bool)?
    ) -> Double {
        guard frameRate > 0 else { return frequency }
        let count = Int(span / frameRate)
        guard count >= 1 else { return frequency }
        var best = (frequency: frequency, power: coherent.sinusoidFit(atHz: frequency, frames: frames).explainedPower)
        for n in -count...count where n != 0 {
            let candidate = frequency + Double(n) * frameRate
            guard candidate >= search.lowHz, candidate <= search.highHz, !(excluded?(candidate) ?? false) else { continue }
            let peak = fitPeak(coherent, around: candidate, frames: frames)
            if peak.power > best.power { best = peak }
        }
        return best.frequency
    }

    static func isSlowAliasTooth(_ hz: Double, of slowAliases: [Double], frameRate: Double) -> Bool {
        guard frameRate > 0 else { return false }
        let offset = abs(hz - (hz / frameRate).rounded() * frameRate)
        return slowAliases.contains { abs(offset - $0) <= slowAliasExclusionHz }
    }

    /// `frequency / k` (k = 2, 3) if the capture holds a significant component there that
    /// `frequency`'s own waveform doesn't explain. Measured on the residual after folding at
    /// `frequency`, so `frequency`'s alias teeth (one may sit on f/k) can't pose as it.
    static func subharmonic(
        of frequency: Double,
        field: FlatFieldCapture,
        geometry: FoldGeometry,
        coherent: CoherentSpectrum,
        exposure: TimeInterval,
        frameRate: Double,
        search: SearchBand,
        frames: Range<Int>
    ) throws -> Double? {
        let candidates = [2, 3].map { frequency / Double($0) }.filter { $0 >= search.lowHz }
        guard !candidates.isEmpty else { return nil }
        let lineReadoutTime = geometry.lineReadoutTime
        let fold = PhaseFold(geometry: geometry, field: field, frequency: frequency, frames: frames)
        let residuals = fold.residuals(geometry: geometry, field: field, frequency: frequency, frames: frames)
        let residualSpectra = try FrameSpectra(signals: residuals, maxNormalizedFrequency: frequency * lineReadoutTime)
        let residualCoherent = CoherentSpectrum(
            spectra: residualSpectra,
            presentationTimes: field.presentationTimes,
            lineReadoutTime: lineReadoutTime,
            usableRows: field.usableRows
        )
        let samples = Double(max(1, field.usableRowCount * frames.count))
        for candidate in candidates {
            let peak = fitPeak(residualCoherent, around: candidate, frames: frames).frequency
            guard abs(peak - candidate) <= coherentGridStepHz else { continue }
            let amplitude = residualCoherent.sinusoidFit(atHz: peak, frames: frames).amplitude
            // The residual's own incoherent power there: noise, plus this component itself
            // (conservative).
            let power = residualSpectra.summedPower(atNormalizedFrequency: peak * lineReadoutTime, frames: frames)
            let sigma = max((2 * power).squareRoot() / samples, .leastNonzeroMagnitude)
            let gain = max(abs(sinc(peak * exposure)), CaptureStandard.minimumExposureSincGain)
            guard amplitude / sigma >= CaptureStandard.presentSignificanceSigma,
                  100 * amplitude / gain >= CaptureStandard.presenceDepthFloorPercent,
                  slowAlias(residualCoherent, frequency: peak, frameRate: frameRate, frames: frames) == nil
            else { continue }
            return peak
        }
        return nil
    }

    static func parabolicOffset(_ values: [Double], at index: Int, within range: ClosedRange<Int>) -> Double {
        guard index > range.lowerBound, index < range.upperBound else { return 0 }
        let yMinus = values[index - 1]
        let yZero = values[index]
        let yPlus = values[index + 1]
        let denominator = yMinus - 2 * yZero + yPlus
        guard denominator != 0 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (yMinus - yPlus) / denominator))
    }

    // MARK: - Depth

    struct HarmonicDepth {
        let depthPercent: Double
        let uncertaintyPercent: Double
        let keptHarmonics: [Int]
        /// Highest harmonic the exposure leaves measurable.
        let bandLimit: Int
        let truncated: Bool

        /// The shape was cut off by the exposure with only a handful of harmonics left.
        var isApproximate: Bool { truncated && bandLimit <= 3 }
    }

    /// Highest harmonic k with |sinc(k f T)| ≥ `minimumExposureSincGain`, that the fold can
    /// represent (< bins/2) and that rows sample (k f L ≤ 0.45).
    static func harmonicLimit(frequency: Double, exposure: TimeInterval, lineReadoutTime: TimeInterval, binCount: Int) -> Int {
        var limit = 0
        for k in 1..<(binCount / 2) {
            let harmonicHz = Double(k) * frequency
            guard abs(sinc(harmonicHz * exposure)) >= CaptureStandard.minimumExposureSincGain,
                  harmonicHz * exposure < 1,
                  harmonicHz * lineReadoutTime <= 0.45 else { break }
            limit = k
        }
        return limit
    }

    /// Fourier-decomposes the folded waveform; each harmonic is divided by the exposure's
    /// box-filter gain |sinc(k f T)| and the phase bin's own sinc, kept only above
    /// `harmonicSignificanceSigma`, and the light's waveform is rebuilt from what's kept.
    static func harmonicDepth(
        fold: PhaseFold,
        frequency: Double,
        exposure: TimeInterval,
        harmonicLimit: Int,
        noise: (Int) -> Double
    ) -> HarmonicDepth? {
        guard harmonicLimit >= 1, let values = fold.filledMeans() else { return nil }
        let bins = values.count
        let mean = values.reduce(0, +) / Double(bins)
        guard mean > 0 else { return nil }

        var kept: [(k: Int, re: Double, im: Double, sigma: Double)] = []
        for k in 1...harmonicLimit {
            var re = 0.0
            var im = 0.0
            for (bin, value) in values.enumerated() {
                let angle = -2 * Double.pi * Double(k) * (Double(bin) + 0.5) / Double(bins)
                re += value * cos(angle)
                im += value * sin(angle)
            }
            re /= Double(bins)
            im /= Double(bins)
            let amplitude = 2 * (re * re + im * im).squareRoot()
            let sigma = noise(k)
            guard amplitude >= CaptureStandard.harmonicSignificanceSigma * sigma else { continue }
            let gain = sinc(Double(k) / Double(bins)) * sinc(Double(k) * frequency * exposure)
            kept.append((k, re / gain, im / gain, sigma / abs(gain)))
        }
        guard let fundamental = kept.first(where: { $0.k == 1 }) else { return nil }

        let fundamentalAmplitude = 2 * (fundamental.re * fundamental.re + fundamental.im * fundamental.im).squareRoot()
        let truncated = harmonicLimit >= 2 && kept.contains { harmonic in
            harmonic.k >= 2 && 2 * harmonic.k > harmonicLimit
                && 2 * (harmonic.re * harmonic.re + harmonic.im * harmonic.im).squareRoot()
                    >= truncationHarmonicRatio * fundamentalAmplitude
        }

        var minimum = Double.infinity
        var maximum = -Double.infinity
        for point in 0..<reconstructionPoints {
            let phase = Double(point) / Double(reconstructionPoints)
            var value = mean
            for harmonic in kept {
                let lanczos = truncated ? sinc(Double(harmonic.k) / Double(harmonicLimit + 1)) : 1
                let angle = 2 * Double.pi * Double(harmonic.k) * phase
                value += 2 * lanczos * (harmonic.re * cos(angle) - harmonic.im * sin(angle))
            }
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        guard maximum + minimum > 0 else { return nil }
        let depth = max(0, min(100, (maximum - minimum) / (maximum + minimum) * 100))
        let uncertainty = 100 * kept.reduce(0) { $0 + $1.sigma * $1.sigma }.squareRoot() / mean
        return HarmonicDepth(
            depthPercent: depth,
            uncertaintyPercent: uncertainty,
            keptHarmonics: kept.map(\.k),
            bandLimit: harmonicLimit,
            truncated: truncated || harmonicLimit == 1
        )
    }

    // MARK: - Small helpers

    static func sinc(_ x: Double) -> Double {
        guard abs(x) > 1e-12 else { return 1 }
        return sin(Double.pi * x) / (Double.pi * x)
    }

    /// Cycles the flicker's phase drifts, relative to the frames, over the whole capture.
    static func phaseDriftCycles(frequency: Double, frameRate: Double, frameCount: Int) -> Double {
        guard frameRate > 0 else { return 0 }
        let ratio = frequency / frameRate
        return abs(ratio - ratio.rounded()) * Double(frameCount)
    }

    /// A least-squares line through the timestamps against their frame numbers (a drop skips
    /// one), not 1 / median delta: whether the flicker's phase drifted a whole cycle hinges on
    /// the rate to ~0.01%, and a median delta carries the timestamps' jitter.
    static func measuredFrameRate(_ times: [TimeInterval]) -> Double? {
        guard times.count >= 2 else { return nil }
        let deltas = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }
        guard let median = median(deltas), median > 0 else { return nil }
        let origin = times[0]
        let numbers = times.map { (($0 - origin) / median).rounded() }
        let meanNumber = numbers.reduce(0, +) / Double(numbers.count)
        let meanTime = times.reduce(0) { $0 + ($1 - origin) } / Double(times.count)
        var covariance = 0.0
        var variance = 0.0
        for (number, time) in zip(numbers, times) {
            covariance += (number - meanNumber) * (time - origin - meanTime)
            variance += (number - meanNumber) * (number - meanNumber)
        }
        guard variance > 0 else { return 1 / median }
        let interval = covariance / variance
        // A fit far from the median means the numbering slipped (wild timestamps): don't trust it.
        guard interval > 0, abs(interval / median - 1) < 0.02 else { return 1 / median }
        return 1 / interval
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - Exposure

/// What the frames' read-back exposure says about tier and gain correction.
struct ExposureSummary {
    let medianDuration: TimeInterval
    let medianISO: Float
    let isStable: Bool
    let isStandard: Bool
    /// Per frame, ISO × exposure over its median.
    let relativeGains: [Double]

    init(metadata: CaptureMetadata) {
        let frames = metadata.frames
        medianDuration = RealFlickerAnalyzer.median(frames.map(\.exposureDuration)) ?? 0
        medianISO = Float(RealFlickerAnalyzer.median(frames.map { Double($0.iso) }) ?? 0)
        let gains = frames.map { Double($0.iso) * $0.exposureDuration }
        let medianGain = RealFlickerAnalyzer.median(gains) ?? 0
        relativeGains = gains.map { medianGain > 0 && $0 > 0 ? $0 / medianGain : 1 }

        let tolerance = RealFlickerAnalyzer.stableExposureTolerance
        let duration = medianDuration
        let iso = Double(medianISO)
        isStable = !frames.isEmpty && frames.allSatisfy { frame in
            frame.exposureMode != .automatic
                && duration > 0 && abs(frame.exposureDuration / duration - 1) <= tolerance
                && iso > 0 && abs(Double(frame.iso) / iso - 1) <= tolerance
        }
        isStandard = CaptureStandard.isStandardExposure(metadata.conditions?.exposureDuration ?? duration)
    }
}

// MARK: - Confidence

/// Each condition that cost confidence lowers it one level (high → medium → low) and leaves a
/// note saying why. The base level comes from significance (present: ≥ 10σ high, ≥ 6σ medium);
/// penalties: split halves disagree, motion residual, unstable exposure, dropped frames, frame
/// rate off-standard, poor phase coverage, a blurred or uncertain depth.
struct ConfidencePenalties {
    private(set) var notes: [String] = []

    mutating func add(_ note: String) {
        notes.append(note)
    }

    mutating func applyConditions(_ conditions: CaptureConditions?, exposure: ExposureSummary) {
        if !exposure.isStable {
            add("Exposure wasn't steady during the capture.")
        }
        guard let conditions else { return }
        if conditions.droppedTooManyFrames {
            add("The camera dropped \(conditions.droppedFrameCount) frames during the capture.")
        }
        if conditions.frameRateDeviates {
            add(String(format: "The camera ran at %.1f fps instead of the standard %.0f fps.", conditions.frameRate, CaptureStandard.frameRate))
        }
    }

    func apply(to base: MeasurementConfidence) -> MeasurementConfidence {
        let levels: [MeasurementConfidence] = [.low, .medium, .high]
        let start = levels.firstIndex(of: base) ?? 0
        return levels[max(0, start - notes.count)]
    }
}

// MARK: - Phase fold

/// Sample times shared by every fold of one capture.
struct FoldGeometry {
    let usableRowIndices: [Int]
    let frameTimes: [Double]
    let lineReadoutTime: TimeInterval

    init(field: FlatFieldCapture, lineReadoutTime: TimeInterval) {
        usableRowIndices = field.usableRows.indices.filter { field.usableRows[$0] }
        let origin = field.presentationTimes.first ?? 0
        frameTimes = field.presentationTimes.map { $0 - origin }
        self.lineReadoutTime = lineReadoutTime
    }
}

/// Mean ratio per phase bin at one frequency. No detrend: depth needs the absolute level.
struct PhaseFold {
    let binCount: Int
    let sums: [Double]
    let counts: [Int]

    init(geometry: FoldGeometry, field: FlatFieldCapture, frequency: Double, frames: Range<Int>, binCount: Int = CaptureStandard.phaseFoldBins) {
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        let step = frequency * geometry.lineReadoutTime
        let bins = Double(binCount)
        geometry.usableRowIndices.withUnsafeBufferPointer { rows in
            for frame in frames {
                let base = frequency * geometry.frameTimes[frame]
                field.ratios[frame].withUnsafeBufferPointer { ratio in
                    for row in rows {
                        let phase = base + Double(row) * step
                        let bin = min(binCount - 1, Int((phase - phase.rounded(.down)) * bins))
                        sums[bin] += Double(ratio[row])
                        counts[bin] += 1
                    }
                }
            }
        }
        self.binCount = binCount
        self.sums = sums
        self.counts = counts
    }

    var coverage: Double {
        Double(counts.lazy.filter { $0 > 0 }.count) / Double(binCount)
    }

    /// Bin means with empty bins filled by circular linear interpolation; `nil` under 2 bins.
    func filledMeans() -> [Double]? {
        let populated = (0..<binCount).filter { counts[$0] > 0 }
        guard populated.count >= 2 else { return nil }
        var means = [Double](repeating: 0, count: binCount)
        for bin in populated { means[bin] = sums[bin] / Double(counts[bin]) }
        for bin in 0..<binCount where counts[bin] == 0 {
            let previous = populated.last { $0 < bin } ?? (populated.last! - binCount)
            let next = populated.first { $0 > bin } ?? (populated.first! + binCount)
            let previousValue = means[(previous + binCount) % binCount]
            let nextValue = means[next % binCount]
            let fraction = Double(bin - previous) / Double(next - previous)
            means[bin] = previousValue + (nextValue - previousValue) * fraction
        }
        return means
    }

    /// Per row, the least-squares gain `g = Σ r·w / Σ w²` of the ratio against the fold model
    /// across frames; dividing the row by it re-centres M(row) on the modelled flicker.
    /// Least squares rather than `mean(r / w)` so deep PWM's near-zero phases can't blow up.
    func rowGains(geometry: FoldGeometry, field: FlatFieldCapture, frequency: Double) -> [Float]? {
        guard let model = filledMeans() else { return nil }
        let step = frequency * geometry.lineReadoutTime
        var crossSums = [Double](repeating: 0, count: field.rowCount)
        var modelSquares = [Double](repeating: 0, count: field.rowCount)
        for frame in 0..<field.frameCount {
            let base = frequency * geometry.frameTimes[frame]
            field.ratios[frame].withUnsafeBufferPointer { ratio in
                for row in geometry.usableRowIndices {
                    let value = Self.interpolate(model, phase: base + Double(row) * step)
                    crossSums[row] += Double(ratio[row]) * value
                    modelSquares[row] += value * value
                }
            }
        }
        var gains = [Float](repeating: 1, count: field.rowCount)
        for row in geometry.usableRowIndices where modelSquares[row] > 0 {
            let gain = crossSums[row] / modelSquares[row]
            if gain.isFinite, gain > 0 { gains[row] = Float(gain) }
        }
        return gains
    }

    /// Linear between bin centres: a step model would leave the in-bin slope of sharp PWM
    /// edges behind and read it as noise or motion.
    static func interpolate(_ model: [Double], phase: Double) -> Double {
        let count = model.count
        let position = (phase - phase.rounded(.down)) * Double(count) - 0.5
        let lower = position.rounded(.down)
        let fraction = position - lower
        let index = (Int(lower) + count) % count
        return model[index] + (model[(index + 1) % count] - model[index]) * fraction
    }

    /// `r − fold(phase)` per frame on usable rows, 0 elsewhere; one array per frame in `frames`.
    func residuals(geometry: FoldGeometry, field: FlatFieldCapture, frequency: Double, frames: Range<Int>) -> [[Float]] {
        let model = filledMeans() ?? [Double](repeating: 1, count: binCount)
        let step = frequency * geometry.lineReadoutTime
        return frames.map { frame in
            var residual = [Float](repeating: 0, count: field.rowCount)
            let base = frequency * geometry.frameTimes[frame]
            field.ratios[frame].withUnsafeBufferPointer { ratio in
                for row in geometry.usableRowIndices {
                    let value = Self.interpolate(model, phase: base + Double(row) * step)
                    residual[row] = ratio[row] - Float(value)
                }
            }
            return residual
        }
    }
}
