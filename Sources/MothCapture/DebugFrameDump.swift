#if DEBUG
import CoreVideo
import Foundation
import MeasurementCore

// DEBUG-only. The "captures are never saved" promise depends on this compiling to nothing in release.

/// Saves the luma plane only (`load` fills chroma with gray), plus the full `CaptureMetadata` so conditions and curve survive.
public enum DebugFrameDump {
    public enum DumpError: Error, LocalizedError {
        case pixelBufferCreationFailed
        case metadataMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .pixelBufferCreationFailed:
                return "Couldn't allocate a pixel buffer while reloading a dump."
            case .metadataMismatch(let detail):
                return "Dump metadata didn't match its luma data: \(detail)"
            }
        }
    }

    /// In Documents so it's reachable from Xcode's Devices and Simulators browser.
    public static func defaultDirectory(name: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent("MothDumps", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Overwrites an existing dump of the same name.
    @discardableResult
    public static func write(
        _ frames: FrameSequence,
        name: String,
        to directory: URL? = nil
    ) throws -> URL {
        let destination = directory ?? defaultDirectory(name: name)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var luma = Data()
        luma.reserveCapacity(frames.metadata.dimensions.width * frames.metadata.dimensions.height * frames.count)
        try frames.forEachPlane(plane: 0) { _, plane, _ in
            for y in 0..<plane.height {
                let row = plane.rowBytes(y)
                luma.append(Data(bytes: row.baseAddress!, count: plane.width))
            }
        }

        try luma.write(to: destination.appendingPathComponent("luma.bin"))
        let metadataData = try JSONEncoder().encode(frames.metadata)
        try metadataData.write(to: destination.appendingPathComponent("metadata.json"))
        return destination
    }

    public static func load(name: String, from directory: URL? = nil) throws -> FrameSequence {
        let source = directory ?? defaultDirectory(name: name)
        let metadataData = try Data(contentsOf: source.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(CaptureMetadata.self, from: metadataData)
        let luma = try Data(contentsOf: source.appendingPathComponent("luma.bin"))

        let width = metadata.dimensions.width
        let height = metadata.dimensions.height
        let frameByteCount = width * height
        guard luma.count == frameByteCount * metadata.frames.count else {
            throw DumpError.metadataMismatch(
                "expected \(frameByteCount * metadata.frames.count) luma bytes for " +
                "\(metadata.frames.count) frames at \(width)x\(height), found \(luma.count)"
            )
        }

        // The recorded encoding, so video-range black (16) reloads as video range.
        let pixelFormat = CaptureStandard.acceptedPixelFormats.contains(metadata.pixelFormat)
            ? metadata.pixelFormat
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        var buffers: [CVPixelBuffer] = []
        buffers.reserveCapacity(metadata.frames.count)

        try luma.withUnsafeBytes { (allBytes: UnsafeRawBufferPointer) -> Void in
            guard let base = allBytes.baseAddress else { return }
            for frameIndex in 0..<metadata.frames.count {
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferCreate(
                    kCFAllocatorDefault, width, height,
                    pixelFormat, nil, &pixelBuffer
                )
                guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                    throw DumpError.pixelBufferCreationFailed
                }

                CVPixelBufferLockBaseAddress(buffer, [])
                let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
                let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let frameOffset = frameIndex * frameByteCount
                for row in 0..<height {
                    let sourceRow = base.advanced(by: frameOffset + row * width)
                        .assumingMemoryBound(to: UInt8.self)
                    (lumaBase + row * lumaStride).update(from: sourceRow, count: width)
                }

                let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
                let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
                memset(chromaBase, 128, chromaStride * chromaHeight)
                CVPixelBufferUnlockBaseAddress(buffer, [])

                buffers.append(buffer)
            }
        }

        return FrameSequence(buffers: buffers, metadata: metadata)
    }
}
#endif
