import Foundation

/// The camera's inverse response: raw 8-bit luma code → relative linear exposure. Black is
/// inside the table (codes at or below black map to ~0), so callers never subtract a black
/// level on top of it. Solved per device and format during calibration.
public struct ResponseCurve: Sendable, Hashable {
    public static let entryCount = 256

    /// Exactly `entryCount` finite, non-negative, non-decreasing values; the last exceeds the first.
    public let values: [Float]

    public enum ValidationError: Error, Sendable, Equatable {
        case wrongEntryCount(Int)
        case nonFinite(code: Int)
        case negative(code: Int)
        case notMonotone(code: Int)
        case flat
        case wrongByteCount(Int)
    }

    /// - Throws: `ValidationError` for anything that couldn't be a camera's inverse response:
    ///   a non-monotone table would turn brighter light into a smaller reading.
    public init(values: [Float]) throws {
        guard values.count == Self.entryCount else {
            throw ValidationError.wrongEntryCount(values.count)
        }
        for (code, value) in values.enumerated() {
            guard value.isFinite else { throw ValidationError.nonFinite(code: code) }
            guard value >= 0 else { throw ValidationError.negative(code: code) }
            if code > 0, value < values[code - 1] { throw ValidationError.notMonotone(code: code) }
        }
        guard values[Self.entryCount - 1] > values[0] else { throw ValidationError.flat }
        self.values = values
    }

    /// Linearly interpolated between neighbouring codes; clamped to 0...255. Fractional codes
    /// come from averaged or dithered values.
    public func linear(forCode code: Float) -> Float {
        guard code.isFinite else { return code > 0 ? values[Self.entryCount - 1] : values[0] }
        let clamped = min(max(code, 0), Float(Self.entryCount - 1))
        let lower = Int(clamped)
        guard lower < Self.entryCount - 1 else { return values[Self.entryCount - 1] }
        let fraction = clamped - Float(lower)
        return values[lower] + (values[lower + 1] - values[lower]) * fraction
    }

    /// The per-pixel fast path.
    @inline(__always)
    public func linear(forByte code: UInt8) -> Float {
        values[Int(code)]
    }
}

// MARK: - Persistence

extension ResponseCurve {
    /// Little-endian Float32 × 256 (1024 bytes): the persisted form.
    public var data: Data {
        var data = Data(capacity: Self.entryCount * MemoryLayout<UInt32>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// - Throws: `ValidationError` for a wrong length or a table that fails `init(values:)`.
    public init(data: Data) throws {
        let stride = MemoryLayout<UInt32>.size
        guard data.count == Self.entryCount * stride else {
            throw ValidationError.wrongByteCount(data.count)
        }
        let bytes = [UInt8](data)
        var values: [Float] = []
        values.reserveCapacity(Self.entryCount)
        for index in 0..<Self.entryCount {
            let offset = index * stride
            let bits = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            values.append(Float(bitPattern: bits))
        }
        try self.init(values: values)
    }
}

// Encoded as a bare array, and validated on decode so a corrupt backup can't smuggle in a
// non-monotone table.
extension ResponseCurve: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(values: container.decode([Float].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

extension ResponseCurve {
    /// The sRGB decoding curve. The camera is forced into the sRGB colour space with tone
    /// mapping off, so this is what it's asked to encode; used only when a phone's own
    /// response couldn't be measured, and flagged wherever it's used.
    public static let standardSRGB: ResponseCurve = {
        let values = (0..<entryCount).map { code -> Float in
            let encoded = Double(code) / 255
            return Float(encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4))
        }
        // A fixed, valid table: init can't fail.
        return try! ResponseCurve(values: values)
    }()

    /// This is the assumed standard curve, not one measured on this phone.
    public var isStandardAssumption: Bool { self == Self.standardSRGB }
}
