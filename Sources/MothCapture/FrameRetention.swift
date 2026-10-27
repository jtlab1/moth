import CoreVideo
import Foundation
import MeasurementCore

/// Flicker lives in the rows, so columns only average noise. Keeping whole frames would blow through memory.
public enum FrameRetentionPolicy: Sendable, Equatable {
        /// The default: ~210 KB per 1080p frame instead of ~3 MB. Costs some noise, not bias; use `.fullFrame` for very dim light.
    case columnStrip(width: Int)
    case fullFrame

        /// Diagnostics only: most likely to starve the capture pool.
    case retainOriginal

    public static let `default` = FrameRetentionPolicy.columnStrip(width: 128)
}

/// Pool is built lazily from the first real frame, since a wrong guess at the format gives silently wrong strides.
final class FrameCopier {
    let policy: FrameRetentionPolicy

    private var pool: CVPixelBufferPool?
    private var poolSourceFormat: OSType = 0
    private var poolWidth = 0
    private var poolHeight = 0

    /// `nil` for `.retainOriginal` and until the first frame arrives.
    private(set) var region: CaptureRegion?

    private(set) var retainedDimensions: FrameDimensions?

    init(policy: FrameRetentionPolicy) {
        self.policy = policy
    }

    /// `nil` should end the capture: a skipped frame leaves a hole that looks like signal.
    func retain(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)

        switch policy {
        case .retainOriginal:
            if retainedDimensions == nil {
                retainedDimensions = FrameDimensions(width: sourceWidth, height: sourceHeight)
            }
            return source

        case .fullFrame:
            guard let destination = makeBuffer(width: sourceWidth, height: sourceHeight, format: format) else {
                return nil
            }
            guard copy(from: source, to: destination, originX: 0, originY: 0) else { return nil }
            if retainedDimensions == nil {
                retainedDimensions = FrameDimensions(width: sourceWidth, height: sourceHeight)
                region = CaptureRegion(
                    sourceDimensions: FrameDimensions(width: sourceWidth, height: sourceHeight)
                )
            }
            return destination

        case .columnStrip(let requestedWidth):
            // 4:2:0 chroma is subsampled 2:1, so odd width or origin would misalign chroma.
            let stripWidth = min(max(2, requestedWidth & ~1), sourceWidth)
            let originX = ((sourceWidth - stripWidth) / 2) & ~1
            // Never crop height: every readout line must survive.
            guard let destination = makeBuffer(width: stripWidth, height: sourceHeight, format: format) else {
                return nil
            }
            guard copy(from: source, to: destination, originX: originX, originY: 0) else { return nil }
            if retainedDimensions == nil {
                retainedDimensions = FrameDimensions(width: stripWidth, height: sourceHeight)
                region = CaptureRegion(
                    sourceDimensions: FrameDimensions(width: sourceWidth, height: sourceHeight),
                    originX: originX,
                    originY: 0
                )
            }
            return destination
        }
    }

    func reset() {
        pool = nil
        region = nil
        retainedDimensions = nil
        poolWidth = 0
        poolHeight = 0
        poolSourceFormat = 0
    }

    // MARK: - Pool

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height || poolSourceFormat != format {
            pool = createPool(width: width, height: height, format: format)
            poolWidth = width
            poolHeight = height
            poolSourceFormat = format
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private func createPool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // No IOSurface: CPU-only buffers are cheaper and stay out of a scarcer shared resource.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    // MARK: - Copy

    /// Row by row because strides differ; a single memcpy would shear the image into fake periodic signal.
    private func copy(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        originX: Int,
        originY: Int
    ) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let isPlanar = CVPixelBufferIsPlanar(source)
        let planeCount = isPlanar ? CVPixelBufferGetPlaneCount(source) : 1

        for plane in 0..<planeCount {
            let sourceBase: UnsafeMutableRawPointer?
            let destinationBase: UnsafeMutableRawPointer?
            let sourceStride: Int
            let destinationStride: Int
            let destinationWidth: Int
            let destinationHeight: Int
            let sourceWidth: Int

            if isPlanar {
                sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane)
                destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                destinationWidth = CVPixelBufferGetWidthOfPlane(destination, plane)
                destinationHeight = CVPixelBufferGetHeightOfPlane(destination, plane)
                sourceWidth = CVPixelBufferGetWidthOfPlane(source, plane)
            } else {
                sourceBase = CVPixelBufferGetBaseAddress(source)
                destinationBase = CVPixelBufferGetBaseAddress(destination)
                sourceStride = CVPixelBufferGetBytesPerRow(source)
                destinationStride = CVPixelBufferGetBytesPerRow(destination)
                destinationWidth = CVPixelBufferGetWidth(destination)
                destinationHeight = CVPixelBufferGetHeight(destination)
                sourceWidth = CVPixelBufferGetWidth(source)
            }

            guard let sourceBase, let destinationBase, sourceWidth > 0 else { return false }

            // Derived from the stride so the biplanar chroma plane needs no special case.
            let bytesPerPixel = max(1, sourceStride / sourceWidth)
            let subsampling = plane == 0 ? 1 : (CVPixelBufferGetWidthOfPlane(source, 0) / max(1, sourceWidth))
            let planeOriginX = originX / max(1, subsampling)
            let planeOriginY = originY / max(1, subsampling)
            let rowBytes = min(destinationWidth * bytesPerPixel, destinationStride)

            for row in 0..<destinationHeight {
                let sourceRow = sourceBase
                    .advanced(by: (planeOriginY + row) * sourceStride)
                    .advanced(by: planeOriginX * bytesPerPixel)
                let destinationRow = destinationBase.advanced(by: row * destinationStride)
                destinationRow.copyMemory(from: sourceRow, byteCount: rowBytes)
            }
        }
        return true
    }
}
