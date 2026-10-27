import Foundation
import MeasurementCore

/// Plain-value view of an `AVCaptureDevice.Format` so format selection is testable without a camera.
struct CaptureFormatDescriptor: Sendable, Equatable {
    let width: Int
    let height: Int

    /// Raw `OSType` media subtype.
    let pixelFormat: UInt32
    let frameRateRanges: [ClosedRange<Double>]
    let minimumExposure: TimeInterval

    /// Binned modes read the sensor differently from the full-readout mode of the same size.
    let isBinned: Bool

    init(
        width: Int,
        height: Int,
        pixelFormat: UInt32,
        frameRateRanges: [ClosedRange<Double>],
        minimumExposure: TimeInterval,
        isBinned: Bool = false
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.frameRateRanges = frameRateRanges
        self.minimumExposure = minimumExposure
        self.isBinned = isBinned
    }

    /// AVFoundation ranges are floats, so a little slack keeps 29 inside a range that ends at exactly 29.
    var supportsStandardFrameRate: Bool {
        let rate = CaptureStandard.frameRate
        return frameRateRanges.contains { $0.lowerBound <= rate + 1e-3 && rate - 1e-3 <= $0.upperBound }
    }

    var maximumFrameRate: Double {
        frameRateRanges.map(\.upperBound).max() ?? 0
    }
}

/// Picks the one format every phone measures in. Never prefers higher frame rates,
/// since high-speed modes are usually binned and read out differently.
enum CaptureFormatSelector {

    /// False if the format can't run the standard at all.
    static func isEligible(_ format: CaptureFormatDescriptor) -> Bool {
        CaptureStandard.acceptedPixelFormats.contains(format.pixelFormat)
            && format.supportsStandardFrameRate
            && format.height >= CaptureStandard.minimumFormatHeight
            && format.width <= CaptureStandard.maximumFormatWidth
            && format.width > 0
    }

    /// Priorities, smaller wins: exact 1920×1080, closest height, full range, reaches standard exposure,
    /// not binned, lowest max frame rate, then widest buffer.
    struct Rank: Comparable {
        let notPreferredDimensions: Int
        let heightDistance: Int
        let notFullRange: Int
        let cannotReachStandardExposure: Int
        let binned: Int
        let maximumFrameRate: Double
        let negativeWidth: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            // Tuples compare lexicographically, but only up to six elements.
            let lhsHead = (lhs.notPreferredDimensions, lhs.heightDistance, lhs.notFullRange, lhs.cannotReachStandardExposure)
            let rhsHead = (rhs.notPreferredDimensions, rhs.heightDistance, rhs.notFullRange, rhs.cannotReachStandardExposure)
            if lhsHead != rhsHead { return lhsHead < rhsHead }
            return (lhs.binned, lhs.maximumFrameRate, lhs.negativeWidth)
                < (rhs.binned, rhs.maximumFrameRate, rhs.negativeWidth)
        }
    }

    static func rank(_ format: CaptureFormatDescriptor) -> Rank {
        let preferred = CaptureStandard.preferredDimensions
        let exact = format.width == preferred.width && format.height == preferred.height
        return Rank(
            notPreferredDimensions: exact ? 0 : 1,
            heightDistance: abs(format.height - preferred.height),
            notFullRange: format.pixelFormat == CaptureStandard.preferredPixelFormat ? 0 : 1,
            cannotReachStandardExposure: format.minimumExposure <= CaptureStandard.exposureDuration * (1 + CaptureStandard.exposureTolerance) ? 0 : 1,
            binned: format.isBinned ? 1 : 0,
            maximumFrameRate: format.maximumFrameRate,
            negativeWidth: -format.width
        )
    }

    /// Index of the standard format, first of equals wins so the pick is stable. `nil` if nothing qualifies.
    static func bestIndex(of formats: [CaptureFormatDescriptor]) -> Int? {
        var best: (index: Int, rank: Rank)?
        for (index, format) in formats.enumerated() where isEligible(format) {
            let candidate = rank(format)
            if best == nil || candidate < best!.rank {
                best = (index, candidate)
            }
        }
        return best?.index
    }
}
