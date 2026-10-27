import Foundation
import MeasurementCore

/// The exposure a capture runs at. Pure, so the metering math is testable without a camera.
struct ExposurePlan: Sendable, Equatable {
    /// The standard exposure, lengthened only if the format can't go that short.
    let exposureDuration: TimeInterval
    let iso: Float

    /// How many stops short of the metering target the scene is even at max ISO; 0 if reachable.
    let shortfallStops: Double

    /// Past this shortfall, warn about dim light from the start.
    /// Exposure is fixed for the capture, so only a brighter target helps.
    static let dimShortfallStops: Double = 4

    var predictsDim: Bool { shortfallStops >= Self.dimShortfallStops }

    /// Converts AE's duration and ISO to the standard exposure, keeping the unclamped ISO to measure any shortfall.
    static func metered(
        autoExposureDuration: TimeInterval,
        autoExposureISO: Float,
        exposureRange: ClosedRange<TimeInterval>,
        isoRange: ClosedRange<Float>
    ) -> ExposurePlan {
        let exposure = CaptureStandard.exposureDuration(clampedTo: exposureRange)
        let iso = CaptureStandard.meteredISO(
            autoExposureISO: autoExposureISO,
            autoExposureDuration: autoExposureDuration,
            exposure: exposure,
            isoRange: isoRange
        )
        var shortfall = 0.0
        if autoExposureISO > 0, autoExposureDuration > 0, isoRange.upperBound > 0 {
            let wanted = Double(autoExposureISO) * autoExposureDuration / exposure
                * pow(2, CaptureStandard.meteringBiasEV)
            if wanted.isFinite, wanted > Double(isoRange.upperBound) {
                shortfall = log2(wanted / Double(isoRange.upperBound))
            }
        }
        return ExposurePlan(exposureDuration: exposure, iso: iso, shortfallStops: shortfall)
    }

    /// A response-sweep step: a set ISO and exposure, clamped to the format.
    static func fixed(
        iso: Float,
        duration: TimeInterval,
        exposureRange: ClosedRange<TimeInterval>,
        isoRange: ClosedRange<Float>
    ) -> ExposurePlan {
        ExposurePlan(
            exposureDuration: min(max(duration, exposureRange.lowerBound), exposureRange.upperBound),
            iso: min(max(iso, isoRange.lowerBound), isoRange.upperBound),
            shortfallStops: 0
        )
    }
}

/// How a capture picks its exposure: standard duration with ISO adapting, except for response sweep steps.
public enum CaptureExposure: Sendable, Equatable {
    /// From continuous AE at capture start (measurements and readout calibration).
    case metered

    /// A set ISO and duration for sweep steps; shorter than standard only when the scene's too bright for the min ISO.
    case fixed(iso: Float, duration: TimeInterval)
}

/// Decides whether each frame belongs to the capture: drops frames before the new exposure plus `settleFrames` more.
/// Elapsed time counts from the first kept frame.
struct SettleGate: Sendable, Equatable {
    let settleFrames: Int

    /// If the exposure completion never arrives, stop waiting after this long; read-back values still tell the truth.
    let maximumWait: TimeInterval

    /// PTS rounding slack when comparing against the sync time.
    static let syncTolerance: TimeInterval = 1e-4

    private(set) var syncTime: TimeInterval?
    private(set) var firstKeptTime: TimeInterval?
    private(set) var discardedFrameCount = 0
    private(set) var timedOut = false
    private var firstSeenTime: TimeInterval?
    private var settlingFramesSeen = 0

    init(settleFrames: Int = CaptureStandard.settleFrames, maximumWait: TimeInterval = 1.0) {
        self.settleFrames = max(0, settleFrames)
        self.maximumWait = maximumWait
    }

    var isSettled: Bool { firstKeptTime != nil }

    /// Sync time from the completion handler (PTS of the first frame with the new exposure). Only the first call counts.
    mutating func exposureApplied(syncTime: TimeInterval) {
        guard self.syncTime == nil, firstKeptTime == nil else { return }
        self.syncTime = syncTime
    }

    /// True if the frame is kept. Once one frame is kept, every later frame is.
    mutating func admit(presentationTime: TimeInterval) -> Bool {
        if firstKeptTime != nil { return true }
        if firstSeenTime == nil { firstSeenTime = presentationTime }

        if syncTime == nil, let firstSeenTime, presentationTime - firstSeenTime >= maximumWait {
            syncTime = presentationTime
            timedOut = true
        }
        guard let syncTime, presentationTime >= syncTime - Self.syncTolerance else {
            discardedFrameCount += 1
            return false
        }
        if settlingFramesSeen < settleFrames {
            settlingFramesSeen += 1
            discardedFrameCount += 1
            return false
        }
        firstKeptTime = presentationTime
        return true
    }

    /// Settled time: 0 until the first frame is kept.
    func elapsed(at presentationTime: TimeInterval) -> TimeInterval {
        guard let firstKeptTime else { return 0 }
        return max(0, presentationTime - firstKeptTime)
    }
}

/// Accumulates what `CaptureConditions` records over the kept frames.
struct CaptureConditionsAccumulator: Sendable, Equatable {
    private(set) var presentationTimes: [TimeInterval] = []
    private(set) var exposureDurations: [TimeInterval] = []
    private(set) var isos: [Float] = []

    /// Only drops inside the valid window count: a drop while settling costs nothing.
    private(set) var droppedFrameCount = 0

    init(expectedFrameCount: Int = 0) {
        presentationTimes.reserveCapacity(expectedFrameCount)
        exposureDurations.reserveCapacity(expectedFrameCount)
        isos.reserveCapacity(expectedFrameCount)
    }

    mutating func recordFrame(presentationTime: TimeInterval, exposureDuration: TimeInterval, iso: Float) {
        presentationTimes.append(presentationTime)
        exposureDurations.append(exposureDuration)
        isos.append(iso)
    }

    mutating func recordDrop() {
        droppedFrameCount += 1
    }

    /// Median, not mean: a dropped frame doubles one interval and would drag a mean.
    static func medianFrameInterval(_ times: [TimeInterval]) -> TimeInterval? {
        guard times.count >= 2 else { return nil }
        let deltas = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }
        return median(deltas)
    }

    static func median<T: BinaryFloatingPoint>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Measured frame rate; 0 (which flags as off-standard) with fewer than two frames.
    var measuredFrameRate: Double {
        guard let interval = Self.medianFrameInterval(presentationTimes), interval > 0 else { return 0 }
        return 1 / interval
    }

    func conditions(
        formatSignature: CaptureFormatSignature,
        settledFrameCount: Int,
        thermalStateRawValue: Int?,
        lensPosition: Float?,
        whiteBalanceLocked: Bool
    ) -> CaptureConditions {
        CaptureConditions(
            exposureDuration: Self.median(exposureDurations) ?? 0,
            iso: Self.median(isos) ?? 0,
            frameRate: measuredFrameRate,
            formatSignature: formatSignature,
            capturedFrameCount: presentationTimes.count,
            droppedFrameCount: droppedFrameCount,
            thermalStateRawValue: thermalStateRawValue,
            settledFrameCount: settledFrameCount,
            lensPosition: lensPosition,
            whiteBalanceLocked: whiteBalanceLocked
        )
    }
}
