import CoreVideo
import Foundation

/// The one set of capture conditions every phone measures under, so depth, presence and
/// confidence mean the same thing on every device. Capture, calibration and analysis all read
/// these; none of them should hard-code a copy.
public enum CaptureStandard {

    // MARK: - Frame timing

    /// 100, 120, 200 and 240 Hz are not integer multiples of 29, so mains-family flicker drifts
    /// in phase frame to frame; flat-field normalisation depends on that drift.
    public static let frameRate: Double = 29.0

    /// Measured median fps further than this from `frameRate` flags the capture as off-standard.
    public static let frameRateDeviationTolerance: Double = 0.03

    /// Dropped frames above this fraction of delivered + dropped flag the capture.
    public static let droppedFrameFractionTolerance: Double = 0.05

    // MARK: - Exposure

    /// 250 µs on every phone and every measurement: the exposure box filter then attenuates a
    /// given flicker frequency identically everywhere. ISO alone adapts to the scene.
    public static let exposureDuration: TimeInterval = 1.0 / 4000.0

    /// Read-back exposure within this fraction of the standard counts as on-standard.
    public static let exposureTolerance: Double = 0.02

    /// Headroom for the lamp's highlights when converting AE's metering to the standard exposure.
    public static let meteringBiasEV: Double = -1.0

    /// Frames discarded after the custom exposure's sync time, before any frame is kept.
    public static let settleFrames: Int = 3

    /// Seconds of valid, settled frames per measurement.
    public static let captureDuration: TimeInterval = 4.0

    /// Deliberate, consistent defocus: blurs scene detail, which per-row means don't need.
    public static let focusLensPosition: Float = 0.0

    public static let whiteBalanceTemperature: Float = 5000
    public static let whiteBalanceTint: Float = 0

    // MARK: - Format

    /// 8-bit biplanar 4:2:0, full range preferred.
    public static let preferredPixelFormat: UInt32 = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    public static let acceptedPixelFormats: Set<UInt32> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    public static let preferredDimensions = FrameDimensions(width: 1920, height: 1080)
    public static let minimumFormatHeight: Int = 720
    public static let maximumFormatWidth: Int = 1920

    /// Columns retained per frame (`FrameRetentionPolicy.columnStrip`).
    public static let retainedColumnStripWidth: Int = 128

    // MARK: - Response curve sweep

    /// Sweep ISOs as multiples of the metered ISO: two stops either side of the scene's own
    /// level, so every step shows the scene neither black nor clipped, on any phone in any
    /// room. Spanning the whole ISO range instead left most steps unusable at 1/4000 s.
    public static let responseSweepFactors: [Float] = [0.25, 0.5, 1, 2, 4]

    /// Steps in a full sweep (fewer if clamping to the ISO range merges some).
    public static var responseSweepSteps: Int { responseSweepFactors.count }

    /// Minimum seconds of settled frames per sweep step.
    public static let responseSweepStepDuration: TimeInterval = 0.7

    /// Width in columns of one response-solver patch (row band × block).
    public static let responsePatchColumnWidth: Int = 16

    /// Codes at or above this are excluded from response solving and flat-field normalisation.
    public static let saturationCode: Float = 250

    // MARK: - Analysis thresholds shared with tests and UI

    /// Below this estimated depth a flicker is not reported as present, on any phone.
    public static let presenceDepthFloorPercent: Double = 1.0

    /// Below this depth, or `absentSignificanceSigma`, the light is reported as not flickering.
    public static let absentDepthCeilingPercent: Double = 0.5
    public static let presentSignificanceSigma: Double = 4
    public static let absentSignificanceSigma: Double = 2

    /// A row is unusable when more than this fraction of its pixels saturate in any frame.
    public static let saturatedRowPixelFraction: Double = 0.05

    /// Analysis fails only when fewer than this fraction of rows are usable.
    public static let minimumUsableRowFraction: Double = 0.30

    public static let phaseFoldBins: Int = 64
    public static let minimumPhaseFoldBinCoverage: Double = 0.9

    /// Harmonics attenuated below this by the exposure box filter are not corrected, only dropped.
    public static let minimumExposureSincGain: Double = 0.3
    public static let harmonicSignificanceSigma: Double = 3

    /// Runner-up frame-rate alias at or above this fraction of the best makes frequency ambiguous.
    public static let aliasAmbiguityRatio: Double = 0.85

    /// Split-half agreement: frequency within 1%, depth within max(2 points, 15%).
    public static let splitHalfFrequencyTolerance: Double = 0.01
    public static let splitHalfDepthTolerancePoints: Double = 2
    public static let splitHalfDepthToleranceFraction: Double = 0.15

    // MARK: - Readout solver

    /// A sub-multiple of the best readout time with at least this fraction of its power wins.
    public static let readoutHarmonicGuardRatio: Double = 0.25
    public static let readoutMinimumSNR: Double = 3

    // MARK: - Helpers

    /// The standard exposure, lengthened only if the format can't go that short.
    public static func exposureDuration(clampedTo range: ClosedRange<TimeInterval>) -> TimeInterval {
        min(max(exposureDuration, range.lowerBound), range.upperBound)
    }

    /// Converts AE's metered (duration, ISO) to the ISO that gives the same brightness at
    /// `exposure`, minus `meteringBiasEV` stops of headroom, clamped to the format.
    public static func meteredISO(
        autoExposureISO: Float,
        autoExposureDuration: TimeInterval,
        exposure: TimeInterval = exposureDuration,
        isoRange: ClosedRange<Float>
    ) -> Float {
        guard exposure > 0, autoExposureDuration > 0, autoExposureISO > 0 else { return isoRange.lowerBound }
        let iso = Double(autoExposureISO) * autoExposureDuration / exposure * pow(2, meteringBiasEV)
        guard iso.isFinite else { return isoRange.upperBound }
        return min(max(Float(iso), isoRange.lowerBound), isoRange.upperBound)
    }

    /// `responseSweepFactors` × `meteredISO`, clamped to `isoRange`, ascending, with levels
    /// that clamping pushes within 5% of each other merged: a repeated ISO adds no information.
    /// The centre is clamped into the range first, so there are always at least three levels
    /// unless the range itself spans under a stop.
    public static func responseSweepISOs(meteredISO: Float, isoRange: ClosedRange<Float>) -> [Float] {
        let metered = meteredISO.isFinite && meteredISO > 0
            ? meteredISO
            : (isoRange.lowerBound * isoRange.upperBound).squareRoot()
        // Clamped first, so a scene metered past either end still gets steps on one side.
        let center = min(max(metered, isoRange.lowerBound), isoRange.upperBound)
        var levels: [Float] = []
        for factor in responseSweepFactors {
            let iso = min(max(center * factor, isoRange.lowerBound), isoRange.upperBound)
            if let last = levels.last, iso <= last * 1.05 { continue }
            levels.append(iso)
        }
        return levels
    }

    public static func isStandardExposure(_ duration: TimeInterval) -> Bool {
        abs(duration - exposureDuration) <= exposureDuration * exposureTolerance
    }
}
