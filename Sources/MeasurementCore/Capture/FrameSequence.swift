import CoreVideo
import Foundation

/// Valid only inside the closure that produced it: the buffer is unlocked on exit.
public struct FramePlane {
    public let baseAddress: UnsafeRawPointer
    /// Rows are padded for alignment; always step by this, never by width.
    public let bytesPerRow: Int
    public let width: Int
    public let height: Int
    public var byteCount: Int { bytesPerRow * height }
    public let pixelFormat: UInt32
    public let planeIndex: Int

    /// Traps rather than reading adjacent memory: a silent off-by-one would look like flicker.
    public func rowBytes(_ y: Int) -> UnsafeRawBufferPointer {
        precondition(y >= 0 && y < height, "row \(y) out of range 0..<\(height)")
        return UnsafeRawBufferPointer(
            start: baseAddress.advanced(by: y * bytesPerRow),
            count: bytesPerRow
        )
    }

    public var allBytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: baseAddress, count: byteCount)
    }
}

/// `@unchecked Sendable` holds because `buffers` is immutable after handoff and every access
/// locks read-only. Not `Codable`: Moth never writes camera data to disk.
public final class FrameSequence: @unchecked Sendable {
    public let metadata: CaptureMetadata

    private let buffers: [CVPixelBuffer]
    private let lock = NSLock()
    private var released = false

    /// - Precondition: counts match; a mismatch would silently misalign every timestamp.
    public init(buffers: [CVPixelBuffer], metadata: CaptureMetadata) {
        precondition(
            buffers.count == metadata.frames.count,
            "frame/metadata count mismatch: \(buffers.count) buffers, \(metadata.frames.count) metadata entries"
        )
        self.buffers = buffers
        self.metadata = metadata
    }

    public var count: Int { buffers.count }

    public var isEmpty: Bool { buffers.isEmpty }

    /// - Throws: `pixelBufferUnreadable` when CoreVideo declines the lock, e.g. for an
    ///   IOSurface the process no longer owns.
    public func withPlane<R>(
        at index: Int,
        plane: Int = 0,
        _ body: (FramePlane) throws -> R
    ) throws -> R {
        let buffer = requireBuffer(at: index)

        let lockResult = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard lockResult == kCVReturnSuccess else {
            throw AnalysisError.pixelBufferUnreadable(frameIndex: index, code: Int(lockResult))
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let isPlanar = CVPixelBufferIsPlanar(buffer)
        let planeCount = isPlanar ? CVPixelBufferGetPlaneCount(buffer) : 1
        guard plane >= 0 && plane < planeCount else {
            throw AnalysisError.pixelBufferUnreadable(frameIndex: index, code: -1)
        }

        let base: UnsafeMutableRawPointer?
        let bytesPerRow: Int
        let width: Int
        let height: Int

        if isPlanar {
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        } else {
            base = CVPixelBufferGetBaseAddress(buffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
        }

        guard let base else {
            throw AnalysisError.pixelBufferUnreadable(frameIndex: index, code: -2)
        }

        let framePlane = FramePlane(
            baseAddress: UnsafeRawPointer(base),
            bytesPerRow: bytesPerRow,
            width: width,
            height: height,
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer),
            planeIndex: plane
        )
        return try body(framePlane)
    }

    /// Locks one frame at a time so wired memory stays proportional to one frame.
    public func forEachPlane(
        plane: Int = 0,
        _ body: (Int, FramePlane, FrameMetadata) throws -> Void
    ) throws {
        for index in 0..<count {
            try withPlane(at: index, plane: plane) { framePlane in
                try body(index, framePlane, metadata.frames[index])
            }
        }
    }

    /// Every accessor traps afterwards, rather than analysing a recycled buffer. Not safe to
    /// call while an analysis is in flight.
    public func releaseFrames() {
        lock.lock()
        released = true
        lock.unlock()
    }

    public var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    private func requireBuffer(at index: Int) -> CVPixelBuffer {
        lock.lock()
        let wasReleased = released
        lock.unlock()
        precondition(!wasReleased, "FrameSequence accessed after releaseFrames()")
        precondition(index >= 0 && index < buffers.count, "frame \(index) out of range 0..<\(buffers.count)")
        return buffers[index]
    }
}

/// Confined to the capture delegate queue. Appended buffers must be app-owned copies:
/// holding AVFoundation's own pool buffers starves it into dropping frames.
public final class FrameSequenceBuilder {
    /// A runaway-capture backstop, not a budget: 600 1080p frames is ~1.8 GB.
    public let maximumFrameCount: Int

    public enum AppendResult: Sendable, Equatable {
        case accepted(count: Int)
        case full
    }

    private var buffers: [CVPixelBuffer] = []
    private var frames: [FrameMetadata] = []

    public init(maximumFrameCount: Int) {
        precondition(maximumFrameCount > 0)
        self.maximumFrameCount = maximumFrameCount
        buffers.reserveCapacity(maximumFrameCount)
        frames.reserveCapacity(maximumFrameCount)
    }

    public var count: Int { buffers.count }

    /// Assigns `index` itself so metadata can never disagree with array position.
    @discardableResult
    public func append(
        pixelBuffer: CVPixelBuffer,
        presentationTime: TimeInterval,
        exposureDuration: TimeInterval,
        iso: Float,
        exposureMode: ExposureMode,
        lensAperture: Float? = nil
    ) -> AppendResult {
        guard buffers.count < maximumFrameCount else { return .full }
        frames.append(
            FrameMetadata(
                index: buffers.count,
                presentationTime: presentationTime,
                exposureDuration: exposureDuration,
                iso: iso,
                exposureMode: exposureMode,
                lensAperture: lensAperture
            )
        )
        buffers.append(pixelBuffer)
        return .accepted(count: buffers.count)
    }

    /// Empties the builder, so a second call yields an empty sequence rather than a duplicate.
    public func finalize(
        dimensions: FrameDimensions,
        pixelFormat: UInt32,
        nominalFrameRate: Double,
        region: CaptureRegion? = nil,
        lineReadoutTime: TimeInterval?,
        deviceCapability: DeviceCapabilityProfile,
        startedAt: Date
    ) -> FrameSequence {
        let metadata = CaptureMetadata(
            dimensions: dimensions,
            pixelFormat: pixelFormat,
            nominalFrameRate: nominalFrameRate,
            region: region,
            frames: frames,
            lineReadoutTime: lineReadoutTime,
            deviceCapability: deviceCapability,
            startedAt: startedAt
        )
        let sequence = FrameSequence(buffers: buffers, metadata: metadata)
        buffers.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        return sequence
    }

    public func discard() {
        buffers.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
    }
}
