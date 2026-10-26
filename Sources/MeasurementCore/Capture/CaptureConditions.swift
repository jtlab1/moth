import Foundation

/// What a readout time and response curve were solved under. A calibration applies only to
/// captures with a matching signature: readout time per row depends on the sensor mode, and the
/// response curve on the pixel format.
public struct CaptureFormatSignature: Sendable, Codable, Hashable {
    /// Full sensor-buffer dimensions, before any column strip crop.
    public let width: Int
    public let height: Int
    public let frameRate: Double

    /// Raw `OSType`.
    public let pixelFormat: UInt32
    public let exposureDuration: TimeInterval

    public init(width: Int, height: Int, frameRate: Double, pixelFormat: UInt32, exposureDuration: TimeInterval) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
        self.exposureDuration = exposureDuration
    }

    /// Tight enough that a different sensor mode never passes, loose enough for read-back jitter.
    public static let frameRateTolerance: Double = 0.005
    public static let exposureTolerance: Double = CaptureStandard.exposureTolerance

    /// Exact dimensions and pixel format; frame rate within 0.5%; exposure within 2%.
    public func matches(_ other: CaptureFormatSignature) -> Bool {
        width == other.width
            && height == other.height
            && pixelFormat == other.pixelFormat
            && Self.relativelyClose(frameRate, other.frameRate, tolerance: Self.frameRateTolerance)
            && Self.relativelyClose(exposureDuration, other.exposureDuration, tolerance: Self.exposureTolerance)
    }

    private static func relativelyClose(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
        guard lhs > 0, rhs > 0, lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) / max(lhs, rhs) <= tolerance
    }

    /// The standard capture at the given buffer size and pixel format.
    public static func standard(
        dimensions: FrameDimensions = CaptureStandard.preferredDimensions,
        pixelFormat: UInt32 = CaptureStandard.preferredPixelFormat
    ) -> CaptureFormatSignature {
        CaptureFormatSignature(
            width: dimensions.width,
            height: dimensions.height,
            frameRate: CaptureStandard.frameRate,
            pixelFormat: pixelFormat,
            exposureDuration: CaptureStandard.exposureDuration
        )
    }

    /// Prefers the signature the capture layer recorded; otherwise derives one from the source
    /// dimensions, nominal rate and median read-back exposure.
    public init(metadata: CaptureMetadata) {
        if let recorded = metadata.conditions?.formatSignature {
            self = recorded
            return
        }
        let source = metadata.region?.sourceDimensions ?? metadata.dimensions
        let exposures = metadata.frames.map(\.exposureDuration).sorted()
        let medianExposure = exposures.isEmpty ? 0 : exposures[exposures.count / 2]
        self.init(
            width: source.width,
            height: source.height,
            frameRate: metadata.nominalFrameRate,
            pixelFormat: metadata.pixelFormat,
            exposureDuration: medianExposure
        )
    }

    /// e.g. "1920×1080".
    public var formattedDimensions: String { "\(width)×\(height)" }
}

/// How a capture was actually taken, recorded with every measurement so readings stay
/// comparable and an off-standard one can explain itself.
public struct CaptureConditions: Sendable, Codable, Hashable {
    /// Median read-back exposure.
    public let exposureDuration: TimeInterval

    /// Median read-back ISO.
    public let iso: Float

    /// Measured: 1 / median presentation-time delta.
    public let frameRate: Double
    public let formatSignature: CaptureFormatSignature

    /// Frames kept for analysis.
    public let capturedFrameCount: Int

    /// `didDrop` callbacks during the valid window.
    public let droppedFrameCount: Int

    /// `ProcessInfo.ThermalState.rawValue` at capture start.
    public let thermalStateRawValue: Int?

    /// Frames discarded while the custom exposure settled; never stored.
    public let settledFrameCount: Int
    public let lensPosition: Float?
    public let whiteBalanceLocked: Bool

    public init(
        exposureDuration: TimeInterval,
        iso: Float,
        frameRate: Double,
        formatSignature: CaptureFormatSignature,
        capturedFrameCount: Int,
        droppedFrameCount: Int,
        thermalStateRawValue: Int? = nil,
        settledFrameCount: Int,
        lensPosition: Float? = nil,
        whiteBalanceLocked: Bool
    ) {
        self.exposureDuration = exposureDuration
        self.iso = iso
        self.frameRate = frameRate
        self.formatSignature = formatSignature
        self.capturedFrameCount = capturedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.thermalStateRawValue = thermalStateRawValue
        self.settledFrameCount = settledFrameCount
        self.lensPosition = lensPosition
        self.whiteBalanceLocked = whiteBalanceLocked
    }
}

extension CaptureConditions {
    public var droppedFrameFraction: Double {
        let total = capturedFrameCount + droppedFrameCount
        guard total > 0 else { return 0 }
        return Double(droppedFrameCount) / Double(total)
    }

    public var frameRateDeviates: Bool {
        guard frameRate > 0 else { return true }
        return abs(frameRate - CaptureStandard.frameRate) / CaptureStandard.frameRate
            > CaptureStandard.frameRateDeviationTolerance
    }

    public var droppedTooManyFrames: Bool {
        droppedFrameFraction > CaptureStandard.droppedFrameFractionTolerance
    }

    public var isStandardExposure: Bool {
        CaptureStandard.isStandardExposure(exposureDuration)
    }

    /// Off-standard captures are still analysed, at a confidence (or tier) penalty.
    public var isOnStandard: Bool {
        isStandardExposure && !frameRateDeviates && !droppedTooManyFrames
    }
}
