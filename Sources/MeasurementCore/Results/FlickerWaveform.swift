import Foundation

/// Display-only and never persisted, so it stays out of `FlickerResult`'s Codable contract.
public struct FlickerWaveform: Sendable, Hashable {
    public struct Point: Sendable, Hashable {
        /// 0..<1 within one period.
        public let phase: Double

        /// Normalized against this capture's own extremes; not comparable across captures.
        public let brightness: Double

        public init(phase: Double, brightness: Double) {
            self.phase = phase
            self.brightness = brightness
        }
    }

    public let frequencyHz: Double
    public let points: [Point]

    public init(frequencyHz: Double, points: [Point]) {
        self.frequencyHz = frequencyHz
        self.points = points
    }
}
