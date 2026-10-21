import Accelerate
import Foundation

/// Each frame's rows are samples ~18 µs apart (vs ~8 ms between frames), so per-frame
/// spectra averaged by Welch's method reach a Nyquist frame-rate sampling never could.
public enum Periodogram {

    /// Bin `k` is normalized frequency `k / paddedLength`. `window` must match `signal.count`.
    static func magnitudeSpectrum(
        _ signal: [Float],
        window: [Float],
        fftSetup: FFTSetup,
        log2n: vDSP_Length
    ) -> [Float] {
        let n = signal.count
        let paddedLength = 1 << Int(log2n)

        // DC dominates row brightness; left in, the window's leakage off DC swamps the peak.
        var mean: Float = 0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(n))

        var windowed = [Float](repeating: 0, count: paddedLength)
        for i in 0..<n { windowed[i] = (signal[i] - mean) * window[i] }

        let half = paddedLength / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { srcPtr in
                    srcPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        // Bin 0 of the packed real-FFT layout conflates DC and Nyquist; callers skip it.
        return magnitudes
    }

    public struct CoarsePeak {
        /// Into a spectrum of length `paddedLength / 2`.
        public let binIndex: Int
        public let paddedLength: Int
        /// Cycles per sample.
        public let normalizedFrequency: Double
        public let magnitude: Float
        public let noiseFloor: Float
        /// Strongest bin outside the peak's guard band, relative to the peak. High means ambiguous.
        public let runnerUpRatio: Float
        public let runnerUpNormalizedFrequency: Double?
    }

    /// `minBin` keeps the search clear of slow drift (hand shake, exposure walk) that isn't flicker.
    public static func coarsePeak(rowSignals: [[Float]], minBin: Int = 2) throws -> CoarsePeak? {
        var summed: [Float]?
        var paddedLength = 0
        var accumulated = 0
        var window: [Float] = []
        var fftSetup: FFTSetup?
        defer { if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }

        for (index, signal) in rowSignals.enumerated() {
            if index % 16 == 0 { try Task.checkCancellation() }
            guard signal.count >= 8 else { continue }
            let log2n = vDSP_Length(ceil(log2(Double(signal.count))))
            if fftSetup == nil {
                guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
                fftSetup = setup
                paddedLength = 1 << Int(log2n)
            } else if 1 << Int(log2n) != paddedLength {
                // Defensive: a mid-capture row-count change shouldn't happen, but skipping beats a crash.
                continue
            }
            if window.count != signal.count {
                window = [Float](repeating: 0, count: signal.count)
                vDSP_hann_window(&window, vDSP_Length(signal.count), Int32(vDSP_HANN_NORM))
            }
            let spectrum = magnitudeSpectrum(signal, window: window, fftSetup: fftSetup!, log2n: log2n)
            if summed == nil {
                summed = spectrum
            } else {
                vDSP.add(spectrum, summed!, result: &summed!)
            }
            accumulated += 1
        }

        guard var spectrum = summed, accumulated > 0, spectrum.count > minBin + 2 else { return nil }
        vDSP.divide(spectrum, Float(accumulated), result: &spectrum)

        let searchRange = minBin..<spectrum.count
        guard let peakBin = searchRange.max(by: { spectrum[$0] < spectrum[$1] }) else { return nil }

        let refinedBin: Double
        if peakBin > minBin, peakBin < spectrum.count - 1 {
            let yMinus = Double(spectrum[peakBin - 1])
            let yZero = Double(spectrum[peakBin])
            let yPlus = Double(spectrum[peakBin + 1])
            let denominator = yMinus - 2 * yZero + yPlus
            let offset = denominator != 0 ? 0.5 * (yMinus - yPlus) / denominator : 0
            refinedBin = Double(peakBin) + max(-0.5, min(0.5, offset))
        } else {
            refinedBin = Double(peakBin)
        }

        let guardBand = max(1, spectrum.count / 64)
        let excluded = (peakBin - guardBand)...(peakBin + guardBand)
        let backgroundBins = searchRange.filter { !excluded.contains($0) }
        let noiseFloor = backgroundBins.isEmpty ? 0 : median(backgroundBins.map { spectrum[$0] })

        let runnerUpBin = backgroundBins.max(by: { spectrum[$0] < spectrum[$1] })
        let runnerUpMagnitude = runnerUpBin.map { spectrum[$0] } ?? 0
        let runnerUpRatio = spectrum[peakBin] > 0 ? runnerUpMagnitude / spectrum[peakBin] : 0

        return CoarsePeak(
            binIndex: peakBin,
            paddedLength: paddedLength,
            normalizedFrequency: refinedBin / Double(paddedLength),
            magnitude: spectrum[peakBin],
            noiseFloor: noiseFloor,
            runnerUpRatio: runnerUpRatio,
            runnerUpNormalizedFrequency: runnerUpBin.map { Double($0) / Double(paddedLength) }
        )
    }

    /// Non-uniform DFT power search near `coarseHz`, using true sample times including the
    /// blanking gaps between frames, which a bin-quantized FFT can't handle.
    public static func refine(
        samples: [(time: TimeInterval, value: Float)],
        coarseHz: Double,
        bandHz: Double,
        gridPoints: Int = 400
    ) throws -> Double {
        guard !samples.isEmpty, bandHz > 0, gridPoints > 1 else { return coarseHz }

        let times = samples.map { $0.time }
        let mean = samples.reduce(0.0) { $0 + Double($1.value) } / Double(samples.count)
        let values = samples.map { Double($0.value) - mean }

        let lowHz = max(0, coarseHz - bandHz / 2)
        let highHz = coarseHz + bandHz / 2
        let step = (highHz - lowHz) / Double(gridPoints - 1)
        let lowOmega = 2 * Double.pi * lowHz
        let stepOmega = 2 * Double.pi * step

        var real = [Double](repeating: 0, count: gridPoints)
        var imag = [Double](repeating: 0, count: gridPoints)

        // Trig per (sample, grid point) dominated analysis time, so each sample's phasor is
        // rotated across the grid instead. vDSP, not Swift SIMD: SIMD is ~100x slower in Debug.
        let blockSize = 1024
        let phase = UnsafeMutablePointer<Double>.allocate(capacity: blockSize)
        let phasorReal = UnsafeMutablePointer<Double>.allocate(capacity: blockSize)
        let phasorImag = UnsafeMutablePointer<Double>.allocate(capacity: blockSize)
        let rotationReal = UnsafeMutablePointer<Double>.allocate(capacity: blockSize)
        let rotationImag = UnsafeMutablePointer<Double>.allocate(capacity: blockSize)
        defer {
            for buffer in [phase, phasorReal, phasorImag, rotationReal, rotationImag] {
                buffer.deallocate()
            }
        }
        var phasor = DSPDoubleSplitComplex(realp: phasorReal, imagp: phasorImag)
        var rotatedPhasor = phasor
        var rotation = DSPDoubleSplitComplex(realp: rotationReal, imagp: rotationImag)

        try times.withUnsafeBufferPointer { times in
            try values.withUnsafeBufferPointer { values in
                for start in stride(from: 0, to: values.count, by: blockSize) {
                    try Task.checkCancellation()
                    let length = min(blockSize, values.count - start)
                    var vForceLength = Int32(length)
                    let blockTimes = times.baseAddress! + start
                    let blockValues = values.baseAddress! + start

                    var omega = lowOmega
                    vDSP_vsmulD(blockTimes, 1, &omega, phase, 1, vDSP_Length(length))
                    vvsincos(phasorImag, phasorReal, phase, &vForceLength)
                    omega = stepOmega
                    vDSP_vsmulD(blockTimes, 1, &omega, phase, 1, vDSP_Length(length))
                    vvsincos(rotationImag, rotationReal, phase, &vForceLength)

                    for i in 0..<gridPoints {
                        var dotReal = 0.0
                        var dotImag = 0.0
                        vDSP_dotprD(blockValues, 1, phasorReal, 1, &dotReal, vDSP_Length(length))
                        vDSP_dotprD(blockValues, 1, phasorImag, 1, &dotImag, vDSP_Length(length))
                        real[i] += dotReal
                        imag[i] += dotImag
                        vDSP_zvmulD(&phasor, 1, &rotation, 1, &rotatedPhasor, 1, vDSP_Length(length), 1)
                    }
                }
            }
        }

        var bestHz = coarseHz
        var bestPower = -Double.infinity
        for i in 0..<gridPoints {
            let power = real[i] * real[i] + imag[i] * imag[i]
            if power > bestPower {
                bestPower = power
                bestHz = lowHz + Double(i) * step
            }
        }
        return bestHz
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
