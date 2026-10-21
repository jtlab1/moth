import Foundation

/// Buffer coordinates, before any display rotation.
public struct FrameDimensions: Sendable, Codable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// The capture layer only crops perpendicular to readout, so line *n* of a buffer is
/// always line *n* of the sensor frame.
public struct CaptureRegion: Sendable, Codable, Hashable {
    public let sourceDimensions: FrameDimensions
    public let originX: Int
    public let originY: Int

    public init(sourceDimensions: FrameDimensions, originX: Int = 0, originY: Int = 0) {
        self.sourceDimensions = sourceDimensions
        self.originX = originX
        self.originY = originY
    }
}

/// Per-frame because auto exposure can change mid-capture, which corrupts amplitude invisibly.
public enum ExposureMode: String, Sendable, Codable {
    case manual
    case locked
    case automatic
}

/// Exposure values are read back from the device, not the values requested.
public struct FrameMetadata: Sendable, Codable, Hashable {
    public let index: Int

    /// Arbitrary zero shared across the sequence; only differences are meaningful.
    public let presentationTime: TimeInterval
    public let exposureDuration: TimeInterval
    public let iso: Float
    public let exposureMode: ExposureMode

    /// Fixed on current iPhones; carried anyway for completeness of the exposure triangle.
    public let lensAperture: Float?

    public init(
        index: Int,
        presentationTime: TimeInterval,
        exposureDuration: TimeInterval,
        iso: Float,
        exposureMode: ExposureMode,
        lensAperture: Float? = nil
    ) {
        self.index = index
        self.presentationTime = presentationTime
        self.exposureDuration = exposureDuration
        self.iso = iso
        self.exposureMode = exposureMode
        self.lensAperture = lensAperture
    }
}

/// Codable so captures can be replayed against a new analyser without a device.
public struct CaptureMetadata: Sendable, Codable, Hashable {
    public let dimensions: FrameDimensions

    /// Raw `OSType`, stored as `UInt32` to keep CoreVideo out of this type.
    public let pixelFormat: UInt32

    /// Nominal target; real intervals come from `frames[i].presentationTime`.
    public let nominalFrameRate: Double

    /// `nil` means whole frames.
    public let region: CaptureRegion?
    public let frames: [FrameMetadata]

    /// `nil` when uncalibrated, which forces Tier 3.
    public let lineReadoutTime: TimeInterval?
    public let deviceCapability: DeviceCapabilityProfile

    /// Never used for timing: `Date` is not monotonic.
    public let startedAt: Date

    public init(
        dimensions: FrameDimensions,
        pixelFormat: UInt32,
        nominalFrameRate: Double,
        region: CaptureRegion? = nil,
        frames: [FrameMetadata],
        lineReadoutTime: TimeInterval?,
        deviceCapability: DeviceCapabilityProfile,
        startedAt: Date
    ) {
        self.dimensions = dimensions
        self.pixelFormat = pixelFormat
        self.nominalFrameRate = nominalFrameRate
        self.region = region
        self.frames = frames
        self.lineReadoutTime = lineReadoutTime
        self.deviceCapability = deviceCapability
        self.startedAt = startedAt
    }
}

extension CaptureMetadata {
    /// The capture layer never rotates buffers, so readout runs down rows.
    public var lineCount: Int { dimensions.height }

    public var duration: TimeInterval {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.presentationTime - first.presentationTime
    }

    /// When false, depth needs per-frame normalisation before it means anything.
    public var hasStableExposure: Bool {
        guard let reference = frames.first else { return false }
        return frames.allSatisfy {
            $0.exposureDuration == reference.exposureDuration && $0.iso == reference.iso
        }
    }

}
