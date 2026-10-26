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

// MARK: - Hz-domain spectra (spec C3)

/// Every frame's DTFT of its rows, kept so any frequency can be read back without
/// recomputing: coherent sums across frames need one coefficient per frame per frequency,
/// incoherent ones its magnitude.
///
/// Frequencies are normalised (cycles per row); multiply Hz by the line readout time.
/// Coefficients are *centred*: their phase origin is the middle row, so they rotate slowly
/// with frequency and linear interpolation between the zero-padded bins stays accurate.
/// Stored bin-major so one frequency's frames are contiguous for vDSP.
struct FrameSpectra: Sendable {
    enum Window: Sendable { case rectangular, hann }

    let frameCount: Int
    let rowCount: Int
    let paddedLength: Int
    let storedBins: Int
    /// Σ window: a sinusoid of amplitude A gives |coefficient| ≈ A · windowSum / 2.
    let windowSum: Double
    let windowSumOfSquares: Double
    private let real: [Double]
    private let imag: [Double]

    /// - Parameter oversampling: zero-padding factor over the row count (rounded up to a power
    ///   of two); 8 keeps linear interpolation between bins within ~1% in amplitude.
    init(
        signals: [[Float]],
        maxNormalizedFrequency: Double,
        window: Window = .rectangular,
        oversampling: Int = 8
    ) throws {
        let rows = signals.first?.count ?? 0
        precondition(rows > 0 && signals.allSatisfy { $0.count == rows }, "frame row counts must match")
        let log2n = vDSP_Length(max(4, Int(ceil(log2(Double(rows * oversampling))))))
        let padded = 1 << Int(log2n)
        let half = padded / 2
        let bins = min(half, Int(ceil(max(0, maxNormalizedFrequency) * Double(padded))) + 3)
        let frames = signals.count

        var windowValues = [Float](repeating: 1, count: rows)
        if window == .hann {
            vDSP_hann_window(&windowValues, vDSP_Length(rows), Int32(vDSP_HANN_DENORM))
        }
        var sum: Float = 0
        var sumSquares: Float = 0
        vDSP_sve(windowValues, 1, &sum, vDSP_Length(rows))
        vDSP_svesq(windowValues, 1, &sumSquares, vDSP_Length(rows))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw AnalysisError.insufficientSignal(reason: "FFT setup failed")
        }
        defer { vDSP_destroy_fftsetup(setup) }

        // Centring: multiply bin k by e^{+i 2π k c / N}, c = (rows − 1) / 2.
        let centre = Double(rows - 1) / 2
        var centreCos = [Double](repeating: 0, count: bins)
        var centreSin = [Double](repeating: 0, count: bins)
        for bin in 0..<bins {
            let angle = 2 * Double.pi * Double(bin) * centre / Double(padded)
            centreCos[bin] = cos(angle)
            centreSin[bin] = sin(angle)
        }

        var realStore = [Double](repeating: 0, count: bins * frames)
        var imagStore = [Double](repeating: 0, count: bins * frames)
        var windowed = [Float](repeating: 0, count: padded)
        var realPart = [Float](repeating: 0, count: half)
        var imagPart = [Float](repeating: 0, count: half)
        var realDouble = [Double](repeating: 0, count: bins)
        var imagDouble = [Double](repeating: 0, count: bins)
        var centredReal = [Double](repeating: 0, count: bins)
        var centredImag = [Double](repeating: 0, count: bins)

        for (frame, signal) in signals.enumerated() {
            if frame % 16 == 0 { try Task.checkCancellation() }
            vDSP_vclr(&windowed, 1, vDSP_Length(padded))
            vDSP_vmul(signal, 1, windowValues, 1, &windowed, 1, vDSP_Length(rows))
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { source in
                        source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // zrip scales by 2 and packs Nyquist into imag[0]; DC's imaginary part is 0.
            imagPart[0] = 0
            vDSP_vspdp(realPart, 1, &realDouble, 1, vDSP_Length(bins))
            vDSP_vspdp(imagPart, 1, &imagDouble, 1, vDSP_Length(bins))
            realDouble.withUnsafeMutableBufferPointer { re in
                imagDouble.withUnsafeMutableBufferPointer { im in
                    centreCos.withUnsafeMutableBufferPointer { cr in
                        centreSin.withUnsafeMutableBufferPointer { ci in
                            centredReal.withUnsafeMutableBufferPointer { outRe in
                                centredImag.withUnsafeMutableBufferPointer { outIm in
                                    var value = DSPDoubleSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                                    var rotation = DSPDoubleSplitComplex(realp: cr.baseAddress!, imagp: ci.baseAddress!)
                                    var output = DSPDoubleSplitComplex(realp: outRe.baseAddress!, imagp: outIm.baseAddress!)
                                    vDSP_zvmulD(&value, 1, &rotation, 1, &output, 1, vDSP_Length(bins), 1)
                                }
                            }
                        }
                    }
                }
            }
            var packingScale: Double = 0.5
            realStore.withUnsafeMutableBufferPointer { out in
                vDSP_vsmulD(centredReal, 1, &packingScale, out.baseAddress! + frame, vDSP_Stride(frames), vDSP_Length(bins))
            }
            imagStore.withUnsafeMutableBufferPointer { out in
                vDSP_vsmulD(centredImag, 1, &packingScale, out.baseAddress! + frame, vDSP_Stride(frames), vDSP_Length(bins))
            }
        }

        frameCount = frames
        rowCount = rows
        paddedLength = padded
        storedBins = bins
        windowSum = Double(sum)
        windowSumOfSquares = Double(sumSquares)
        real = realStore
        imag = imagStore
    }

    var maxNormalizedFrequency: Double { Double(storedBins - 2) / Double(paddedLength) }

    /// Every frame in `frames`' centred coefficient at `normalizedFrequency`, linearly
    /// interpolated between bins, written to `outReal`/`outImag` (length `frames.count`).
    func coefficients(
        atNormalizedFrequency normalizedFrequency: Double,
        frames: Range<Int>,
        outReal: UnsafeMutablePointer<Double>,
        outImag: UnsafeMutablePointer<Double>
    ) {
        let position = max(0, min(Double(storedBins - 2), normalizedFrequency * Double(paddedLength)))
        let bin = Int(position)
        var fraction = position - Double(bin)
        let count = vDSP_Length(frames.count)
        real.withUnsafeBufferPointer { source in
            let lower = source.baseAddress! + bin * frameCount + frames.lowerBound
            vDSP_vintbD(lower, 1, lower + frameCount, 1, &fraction, outReal, 1, count)
        }
        imag.withUnsafeBufferPointer { source in
            let lower = source.baseAddress! + bin * frameCount + frames.lowerBound
            vDSP_vintbD(lower, 1, lower + frameCount, 1, &fraction, outImag, 1, count)
        }
    }

    /// Σ over `frames` of |coefficient|² at `normalizedFrequency`.
    func summedPower(atNormalizedFrequency normalizedFrequency: Double, frames: Range<Int>) -> Double {
        guard !frames.isEmpty else { return 0 }
        let re = UnsafeMutablePointer<Double>.allocate(capacity: frames.count)
        let im = UnsafeMutablePointer<Double>.allocate(capacity: frames.count)
        defer {
            re.deallocate()
            im.deallocate()
        }
        coefficients(atNormalizedFrequency: normalizedFrequency, frames: frames, outReal: re, outImag: im)
        var sumRe: Double = 0
        var sumIm: Double = 0
        vDSP_svesqD(re, 1, &sumRe, vDSP_Length(frames.count))
        vDSP_svesqD(im, 1, &sumIm, vDSP_Length(frames.count))
        return sumRe + sumIm
    }

    /// Mean over all frames of |coefficient|² at each stored bin: the incoherent (Welch-style)
    /// spectrum. Bin `k` is `k / paddedLength` cycles per row.
    func incoherentSpectrum() -> [Double] {
        var spectrum = [Double](repeating: 0, count: storedBins)
        real.withUnsafeBufferPointer { re in
            imag.withUnsafeBufferPointer { im in
                for bin in 0..<storedBins {
                    var sumRe: Double = 0
                    var sumIm: Double = 0
                    vDSP_svesqD(re.baseAddress! + bin * frameCount, 1, &sumRe, vDSP_Length(frameCount))
                    vDSP_svesqD(im.baseAddress! + bin * frameCount, 1, &sumIm, vDSP_Length(frameCount))
                    spectrum[bin] = (sumRe + sumIm) / Double(max(frameCount, 1))
                }
            }
        }
        return spectrum
    }
}

/// Coherent (non-uniform DFT) power across frames, using each frame's real presentation time:
/// `X(f) = Σ_frames e^{−i2πf·t_centre} · ã_frame(f·L)`. Equivalent to a DFT over every sample
/// at its true time, including the blanking gaps between frames, at ~frames cost per frequency.
struct CoherentSpectrum: Sendable {
    let spectra: FrameSpectra
    let lineReadoutTime: TimeInterval
    /// Time of each frame's middle row, relative to the first frame.
    let centreTimes: [Double]
    /// Usable samples per frame; amplitude = 2|X| / (samplesPerFrame × frames).
    let samplesPerFrame: Int

    /// Usable rows' offsets from the middle row; the sampling pattern a real-valued fit needs.
    let centredRows: [Double]

    init(spectra: FrameSpectra, presentationTimes: [TimeInterval], lineReadoutTime: TimeInterval, usableRows: [Bool]) {
        self.spectra = spectra
        self.lineReadoutTime = lineReadoutTime
        let origin = presentationTimes.first ?? 0
        let centre = Double(spectra.rowCount - 1) / 2
        centreTimes = presentationTimes.map { $0 - origin + centre * lineReadoutTime }
        centredRows = usableRows.indices.filter { usableRows[$0] }.map { Double($0) - centre }
        samplesPerFrame = centredRows.count
    }

    /// Least-squares fit of a *real* sinusoid `a cos ωt + b sin ωt` at `frequency`.
    ///
    /// `|X|²` alone treats the signal as one complex exponential; with gapped sampling the
    /// negative-frequency image (and its alias teeth) leaks into the positive peak and biases
    /// it by millihertz, which smears a phase fold over 4 s. The fit's Gram matrix comes from
    /// the sampling pattern's transform at 2f, `Σ e^{−i2ωt}`, which is cheap because every frame
    /// shares one row mask.
    func sinusoidFit(atHz frequency: Double, frames: Range<Int>) -> (amplitude: Double, explainedPower: Double) {
        let x = transform(atHz: frequency, frames: frames)
        let c = x.re
        let s = -x.im
        let n = Double(samplesPerFrame * frames.count)
        guard n > 0 else { return (0, 0) }

        // W = Σ_frames e^{−i2ω t_centre} · Σ_rows e^{−i2ω (row − centre) L}.
        let omega2 = 4 * Double.pi * frequency
        var rowRe = 0.0
        var rowIm = 0.0
        for row in centredRows {
            let angle = -omega2 * row * lineReadoutTime
            rowRe += cos(angle)
            rowIm += sin(angle)
        }
        var frameRe = 0.0
        var frameIm = 0.0
        for frame in frames {
            let angle = -omega2 * centreTimes[frame]
            frameRe += cos(angle)
            frameIm += sin(angle)
        }
        let wRe = rowRe * frameRe - rowIm * frameIm
        let wIm = rowRe * frameIm + rowIm * frameRe
        // Σcos2ωt = Re W, Σsin2ωt = −Im W.
        let cc = (n + wRe) / 2
        let ss = (n - wRe) / 2
        let cs = -wIm / 2
        let determinant = cc * ss - cs * cs
        guard determinant > 1e-9 * n * n else {
            return (2 * (c * c + s * s).squareRoot() / n, (c * c + s * s) * 2 / n)
        }
        let a = (ss * c - cs * s) / determinant
        let b = (cc * s - cs * c) / determinant
        return ((a * a + b * b).squareRoot(), a * c + b * s)
    }

    var allFrames: Range<Int> { 0..<spectra.frameCount }

    /// |Σ_rows e^{i2π·offset·L·row}| / rows over the usable rows: how much of a line at f a
    /// frame's rows still see at f ± offset. Alias teeth are this much weaker than the line.
    func withinFrameResponse(offsetHz: Double) -> Double {
        guard !centredRows.isEmpty else { return 0 }
        var re = 0.0
        var im = 0.0
        let omega = 2 * Double.pi * offsetHz * lineReadoutTime
        for row in centredRows {
            re += cos(omega * row)
            im += sin(omega * row)
        }
        return (re * re + im * im).squareRoot() / Double(centredRows.count)
    }

    /// Complex `X(f)` over `frames`.
    func transform(atHz frequency: Double, frames: Range<Int>) -> (re: Double, im: Double) {
        let powers = scan(fromHz: frequency, stepHz: 0, count: 1, frames: frames, keepComplex: true)
        return (powers.real[0], powers.imag[0])
    }

    /// Sinusoid amplitude, in the signal's units (ratio units for `r − 1`).
    func amplitude(atHz frequency: Double, frames: Range<Int>) -> Double {
        let x = transform(atHz: frequency, frames: frames)
        return 2 * (x.re * x.re + x.im * x.im).squareRoot() / Double(max(1, samplesPerFrame * frames.count))
    }

    /// Converts |X|² from `scan` to amplitude.
    func amplitude(fromPower power: Double, frameCount: Int) -> Double {
        2 * power.squareRoot() / Double(max(1, samplesPerFrame * frameCount))
    }

    /// |X|² on an even grid `fromHz + i·stepHz`, i < count.
    func power(fromHz: Double, stepHz: Double, count: Int, frames: Range<Int>) throws -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(count)
        let chunk = 2048
        var start = 0
        while start < count {
            try Task.checkCancellation()
            let length = min(chunk, count - start)
            let part = scan(fromHz: fromHz + Double(start) * stepHz, stepHz: stepHz, count: length, frames: frames, keepComplex: false)
            result.append(contentsOf: part.power)
            start += length
        }
        return result
    }

    private func scan(
        fromHz: Double,
        stepHz: Double,
        count: Int,
        frames: Range<Int>,
        keepComplex: Bool
    ) -> (power: [Double], real: [Double], imag: [Double]) {
        let n = frames.count
        guard n > 0, count > 0 else { return ([], [], []) }
        let coefficientReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let coefficientImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let phasorReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let phasorImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let rotatedReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let rotatedImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let rotationReal = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let rotationImag = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let angles = UnsafeMutablePointer<Double>.allocate(capacity: n)
        defer {
            for buffer in [coefficientReal, coefficientImag, phasorReal, phasorImag, rotatedReal,
                           rotatedImag, rotationReal, rotationImag, angles] {
                buffer.deallocate()
            }
        }
        var vForceCount = Int32(n)
        let times = Array(centreTimes[frames])

        var phasor = DSPDoubleSplitComplex(realp: phasorReal, imagp: phasorImag)
        var rotated = DSPDoubleSplitComplex(realp: rotatedReal, imagp: rotatedImag)
        func seed(_ frequency: Double, into target: DSPDoubleSplitComplex) {
            var omega = -2 * Double.pi * frequency
            vDSP_vsmulD(times, 1, &omega, angles, 1, vDSP_Length(n))
            vvsincos(target.imagp, target.realp, angles, &vForceCount)
        }
        seed(fromHz, into: phasor)
        var stepOmega = -2 * Double.pi * stepHz
        vDSP_vsmulD(times, 1, &stepOmega, angles, 1, vDSP_Length(n))
        vvsincos(rotationImag, rotationReal, angles, &vForceCount)

        var rotation = DSPDoubleSplitComplex(realp: rotationReal, imagp: rotationImag)
        var coefficient = DSPDoubleSplitComplex(realp: coefficientReal, imagp: coefficientImag)
        let dotReal = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        let dotImag = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        defer {
            dotReal.deallocate()
            dotImag.deallocate()
        }
        var dot = DSPDoubleSplitComplex(realp: dotReal, imagp: dotImag)

        var power = [Double](repeating: 0, count: count)
        var realOut = keepComplex ? [Double](repeating: 0, count: count) : []
        var imagOut = keepComplex ? [Double](repeating: 0, count: count) : []
        for index in 0..<count {
            let frequency = fromHz + Double(index) * stepHz
            // Re-seed now and then so rotation round-off can't accumulate.
            if index > 0, index % 256 == 0 { seed(frequency, into: phasor) }
            spectra.coefficients(
                atNormalizedFrequency: abs(frequency) * lineReadoutTime,
                frames: frames,
                outReal: coefficientReal,
                outImag: coefficientImag
            )
            vDSP_zdotprD(&coefficient, 1, &phasor, 1, &dot, vDSP_Length(n))
            power[index] = dotReal.pointee * dotReal.pointee + dotImag.pointee * dotImag.pointee
            if keepComplex {
                realOut[index] = dotReal.pointee
                imagOut[index] = dotImag.pointee
            }
            vDSP_zvmulD(&phasor, 1, &rotation, 1, &rotated, 1, vDSP_Length(n), 1)
            swap(&phasor, &rotated)
        }
        return (power, realOut, imagOut)
    }
}
