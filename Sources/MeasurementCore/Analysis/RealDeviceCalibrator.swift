import Foundation

/// The analyzer's periodogram run in reverse: the frequency is known, the readout time isn't.
public struct RealDeviceCalibrator: DeviceCalibrating {
    public init() {}

    public func solveLineReadoutTime(
        from frames: FrameSequence,
        knownFrequencyHz: Double
    ) async throws -> TimeInterval {
        try Task.checkCancellation()
        guard knownFrequencyHz > 0 else {
            throw AnalysisError.insufficientSignal(reason: "non-positive reference frequency")
        }

        let extracted = try RowBrightnessExtractor.extract(from: frames)
        guard extracted.crushedFraction < 0.9 else {
            throw AnalysisError.insufficientSignal(reason: "reference capture was too dark to calibrate from")
        }

        let rowSignals = extracted.frames.map(\.rowBrightness)
        guard let coarse = try Periodogram.coarsePeak(rowSignals: rowSignals) else {
            throw AnalysisError.insufficientSignal(reason: "no usable periodogram from the calibration capture")
        }

        let snr = coarse.noiseFloor > 0 ? Double(coarse.magnitude / coarse.noiseFloor) : Double(coarse.magnitude)
        guard snr >= 3 else {
            throw AnalysisError.insufficientSignal(
                reason: "reference fixture's flicker was not clearly separated from the noise floor"
            )
        }

        // normalizedFrequency (cycles/row) = Hz × lineReadoutTime (sec/row).
        let solved = coarse.normalizedFrequency / knownFrequencyHz

        guard DeviceCalibration.isPlausible(solved) else {
            throw AnalysisError.implausibleCalibration(
                solved: solved,
                plausible: DeviceCalibration.plausibleLineReadoutRange
            )
        }

        return solved
    }
}
