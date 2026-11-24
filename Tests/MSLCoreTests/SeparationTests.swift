@testable import MSLCore
import XCTest

final class RealFFTTests: XCTestCase {
    private func randomSignal(_ count: Int) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in Float.random(in: -1...1, using: &generator) }
    }

    func testForwardMatchesReference() throws {
        let fft = try XCTUnwrap(RealFFT(size: 512))
        let input = randomSignal(512)
        var re = [Float](), im = [Float](), refRe = [Float](), refIm = [Float]()
        fft.forward(input, real: &re, imag: &im)
        fft.referenceForward(input, real: &refRe, imag: &refIm)
        XCTAssertEqual(re.count, 257)
        XCTAssertEqual(im.count, 257)
        for k in 0..<257 {
            XCTAssertEqual(re[k], refRe[k], accuracy: 1e-3, "re \(k)")
            XCTAssertEqual(im[k], refIm[k], accuracy: 1e-3, "im \(k)")
        }
    }

    func testRoundTripRestoresSignal() throws {
        let fft = try XCTUnwrap(RealFFT(size: 1024))
        let input = randomSignal(1024)
        var re = [Float](), im = [Float](), output = [Float]()
        fft.forward(input, real: &re, imag: &im)
        fft.inverse(real: re, imag: im, output: &output)
        XCTAssertEqual(output.count, 1024)
        for i in 0..<1024 {
            XCTAssertEqual(output[i], input[i], accuracy: 1e-4)
        }
        var reference = [Float]()
        fft.referenceInverse(real: re, imag: im, output: &reference)
        for i in 0..<1024 {
            XCTAssertEqual(reference[i], input[i], accuracy: 1e-4)
        }
    }

    func testCosineHasRealPeak() throws {
        let fft = try XCTUnwrap(RealFFT(size: 256))
        let input = (0..<256).map { Float(cos(2 * Double.pi * 8 * Double($0) / 256)) }
        var re = [Float](), im = [Float]()
        fft.forward(input, real: &re, imag: &im)
        XCTAssertEqual(re[8], 128, accuracy: 1e-2)
        XCTAssertEqual(im[8], 0, accuracy: 1e-2)
        XCTAssertEqual(re[3], 0, accuracy: 1e-2)
    }
}

final class StemMixTests: XCTestCase {
    func testMuteAndSolo() {
        var mix = StemMix()
        XCTAssertEqual(mix.gain(for: .drums), 1)
        mix[.bass].volume = 0.5
        XCTAssertEqual(mix.gain(for: .bass), 0.5)
        mix[.drums].isMuted = true
        XCTAssertEqual(mix.gain(for: .drums), 0)

        mix[.melody].isSolo = true
        XCTAssertEqual(mix.gain(for: .melody), 1)
        XCTAssertEqual(mix.gain(for: .bass), 0)
        XCTAssertEqual(mix.gain(for: .chords), 0)

        // ミュートはソロより優先する。
        mix[.melody].isMuted = true
        XCTAssertEqual(mix.gain(for: .melody), 0)
    }

    func testExclusiveSoloToggles() {
        var mix = StemMix()
        mix[.drums].isSolo = true
        mix.toggleExclusiveSolo(.bass)
        XCTAssertTrue(mix[.bass].isSolo)
        XCTAssertFalse(mix[.drums].isSolo)
        mix.toggleExclusiveSolo(.bass)
        XCTAssertFalse(mix.hasSolo)
    }
}

final class SpectralStemSeparatorTests: XCTestCase {
    private let sampleRate = 22_050.0

    /// 和音(弱め)・メロディ(強め、音が変わる)・ベース・打楽器のノイズを混ぜた信号。
    private func makeSources(duration: Double = 4) -> [StemKind: [Float]] {
        let count = Int(sampleRate * duration)
        func tone(_ frequency: Double, amplitude: Double, harmonics: Int, decay: Double, at i: Int) -> Float {
            var value = 0.0
            for h in 0..<harmonics {
                value += amplitude * pow(decay, Double(h)) * sin(2 * Double.pi * frequency * Double(h + 1) * Double(i) / sampleRate)
            }
            return Float(value)
        }
        let melodyNotes = [523.25, 587.33, 659.25, 783.99]
        var melody = [Float](repeating: 0, count: count)
        var chords = [Float](repeating: 0, count: count)
        var bass = [Float](repeating: 0, count: count)
        var drums = [Float](repeating: 0, count: count)
        var generator = SplitMix(seed: 7)
        for i in 0..<count {
            let note = melodyNotes[min(melodyNotes.count - 1, Int(Double(i) / sampleRate))]
            melody[i] = tone(note, amplitude: 0.25, harmonics: 6, decay: 0.7, at: i)
            chords[i] = tone(261.63, amplitude: 0.08, harmonics: 4, decay: 0.7, at: i)
                + tone(329.63, amplitude: 0.08, harmonics: 4, decay: 0.7, at: i)
                + tone(392.0, amplitude: 0.08, harmonics: 4, decay: 0.7, at: i)
            bass[i] = tone(65.41, amplitude: 0.3, harmonics: 3, decay: 0.4, at: i)
        }
        let burst = Int(0.06 * sampleRate)
        var start = 0
        while start < count {
            for j in 0..<burst where start + j < count {
                drums[start + j] += Float(generator.nextGaussian() * 0.3 * exp(-Double(j) / (0.01 * sampleRate)))
            }
            start += Int(0.5 * sampleRate)
        }
        return [.melody: melody, .chords: chords, .bass: bass, .drums: drums]
    }

    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in 0..<min(a.count, b.count) {
            ab += Double(a[i]) * Double(b[i])
            aa += Double(a[i]) * Double(a[i])
            bb += Double(b[i]) * Double(b[i])
        }
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }

    func testFFTSizeFollowsSampleRate() {
        XCTAssertEqual(SpectralStemSeparator.fftSize(for: 44_100), 4096)
        XCTAssertEqual(SpectralStemSeparator.fftSize(for: 48_000), 4096)
        XCTAssertEqual(SpectralStemSeparator.fftSize(for: 22_050), 2048)
        XCTAssertEqual(SpectralStemSeparator.fftSize(for: 96_000), 8192)
    }

    func testStemsSumToOriginalAndSeparateSources() throws {
        let sources = makeSources()
        let count = sources[.melody]!.count
        var mix = [Float](repeating: 0, count: count)
        for source in sources.values {
            for i in 0..<count { mix[i] += source[i] }
        }
        // ステレオ(左右同じ)で渡す。
        let result = try SpectralStemSeparator().separate(channels: [mix, mix], sampleRate: sampleRate)
        XCTAssertEqual(result.method, .spectral)
        // 左右が同じなのでボーカルは分けられない(無音になり、理由が付く)。
        XCTAssertNotNil(result.unavailable[.vocals])
        XCTAssertTrue(result.channels(for: .vocals)[0].allSatisfy { $0 == 0 })
        XCTAssertEqual(result.frameCount, count)
        for kind in StemKind.allCases {
            XCTAssertEqual(result.channels(for: kind).count, 2)
            XCTAssertEqual(result.channels(for: kind)[0].count, count)
            XCTAssertNotNil(result.overviews[kind])
        }
        // 全パートの和は元の音に一致する。
        for i in stride(from: 0, to: count, by: 97) {
            let sum = StemKind.allCases.reduce(Float(0)) { $0 + result.channels(for: $1)[0][i] }
            XCTAssertEqual(sum, mix[i], accuracy: 1e-3)
        }
        // 各パートは、対応する元の音とよく似ている。
        let bass = correlation(result.channels(for: .bass)[0], sources[.bass]!)
        let melody = correlation(result.channels(for: .melody)[0], sources[.melody]!)
        let drums = correlation(result.channels(for: .drums)[0], sources[.drums]!)
        let chords = correlation(result.channels(for: .chords)[0], sources[.chords]!)
        XCTAssertGreaterThan(bass, 0.9, "bass \(bass)")
        XCTAssertGreaterThan(melody, 0.7, "melody \(melody)")
        XCTAssertGreaterThan(drums, 0.5, "drums \(drums)")
        XCTAssertGreaterThan(chords, 0.5, "chords \(chords)")
    }

    func testCenterChannelBecomesVocals() throws {
        let count = Int(sampleRate * 4)
        var vocal = [Float](repeating: 0, count: count)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        let notes = [440.0, 493.88, 523.25, 587.33]
        var phase = 0.0
        for i in 0..<count {
            let time = Double(i) / sampleRate
            // ビブラートのかかった声(中央)と、左右に振った和音。
            let frequency = notes[min(3, Int(time))] * (1 + 0.01 * sin(2 * Double.pi * 5 * time))
            phase += 2 * Double.pi * frequency / sampleRate
            var v = 0.0
            for h in 0..<8 { v += 0.2 * pow(0.7, Double(h)) * sin(Double(h + 1) * phase) }
            vocal[i] = Float(v)
            var chord = 0.0
            for f in [261.63, 329.63, 392.0] {
                for h in 0..<4 { chord += 0.07 * pow(0.7, Double(h)) * sin(2 * Double.pi * f * Double(h + 1) * time) }
            }
            left[i] = vocal[i] + Float(0.9 * chord)
            right[i] = vocal[i] + Float(0.3 * chord)
        }
        let result = try SpectralStemSeparator().separate(channels: [left, right], sampleRate: sampleRate)
        XCTAssertNil(result.unavailable[.vocals])
        let vocals = correlation(result.channels(for: .vocals)[0], vocal)
        XCTAssertGreaterThan(vocals, 0.85, "vocals \(vocals)")
        for (channelIndex, original) in [left, right].enumerated() {
            for i in stride(from: 0, to: count, by: 101) {
                let sum = StemKind.allCases.reduce(Float(0)) { $0 + result.channels(for: $1)[channelIndex][i] }
                XCTAssertEqual(sum, original[i], accuracy: 1e-3)
            }
        }
    }

    func testOnlyRequestedPartsAreExtracted() throws {
        let sources = makeSources(duration: 2)
        let count = sources[.melody]!.count
        var mix = [Float](repeating: 0, count: count)
        for kind in [StemKind.melody, .chords] {
            for i in 0..<count { mix[i] += sources[kind]![i] }
        }
        let result = try SpectralStemSeparator().separate(channels: [mix], sampleRate: sampleRate, parts: [.melody])
        for kind in [StemKind.drums, .bass, .vocals] {
            XCTAssertTrue(result.channels(for: kind)[0].allSatisfy { $0 == 0 }, "\(kind)")
        }
        XCTAssertGreaterThan(correlation(result.channels(for: .melody)[0], sources[.melody]!), 0.7)
        for i in stride(from: 0, to: count, by: 97) {
            let sum = result.channels(for: .melody)[0][i] + result.channels(for: .chords)[0][i]
            XCTAssertEqual(sum, mix[i], accuracy: 1e-3)
        }
    }

    func testCenterWeight() {
        XCTAssertEqual(SpectralStemSeparator.centerWeight(leftRe: 1, leftIm: 0.5, rightRe: 1, rightIm: 0.5, exponent: 4), 1, accuracy: 1e-5)
        XCTAssertEqual(SpectralStemSeparator.centerWeight(leftRe: 1, leftIm: 0, rightRe: 0, rightIm: 0, exponent: 4), 0, accuracy: 1e-5)
        XCTAssertEqual(SpectralStemSeparator.centerWeight(leftRe: 1, leftIm: 0, rightRe: -1, rightIm: 0, exponent: 4), 0, accuracy: 1e-5)
        XCTAssertEqual(SpectralStemSeparator.centerWeight(leftRe: 0, leftIm: 0, rightRe: 0, rightIm: 0, exponent: 4), 0)
    }

    func testMelodyTrackingFindsNotes() throws {
        let sources = makeSources()
        let count = sources[.melody]!.count
        var mix = [Float](repeating: 0, count: count)
        for kind in [StemKind.melody, .chords] {
            for i in 0..<count { mix[i] += sources[kind]![i] }
        }
        let separator = SpectralStemSeparator()
        let fftSize = SpectralStemSeparator.fftSize(for: sampleRate)
        let hop = fftSize / 4
        let fft = try XCTUnwrap(RealFFT(size: fftSize))
        let frames = count / hop + 1
        let bins = fft.binCount
        var magnitude = [Float](repeating: 0, count: frames * bins)
        var buffer = [Float](repeating: 0, count: fftSize)
        var re = [Float](), im = [Float]()
        let window = Window.hann(fftSize)
        for t in 0..<frames {
            SpectralStemSeparator.fillFrame(&buffer, from: mix, frameCount: count, start: t * hop - fftSize / 2, window: window)
            fft.forward(buffer, real: &re, imag: &im)
            for k in 0..<bins { magnitude[t * bins + k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
        }
        let melody = try separator.trackMelody(
            harmonic: magnitude, frames: frames, bins: bins,
            binHz: sampleRate / Double(fftSize), frameRate: sampleRate / Double(hop)
        )
        let expected = [523.25, 587.33, 659.25, 783.99]
        var correct = 0
        var judged = 0
        for t in 0..<frames {
            let time = Double(t * hop) / sampleRate
            // 音の変わり目の前後は数えない。
            guard abs(time - time.rounded()) > 0.15, time < 3.85 else { continue }
            judged += 1
            if let f0 = melody[t], abs(12 * log2(f0 / expected[min(3, Int(time))])) < 0.6 {
                correct += 1
            }
        }
        XCTAssertGreaterThan(Double(correct) / Double(max(1, judged)), 0.9, "\(correct)/\(judged)")
    }

    func testMedianAndShortRuns() {
        var values: [Float] = [5, 1, 4, 2, 3]
        XCTAssertEqual(SpectralStemSeparator.median(&values, count: 5), 3)
        var even: [Float] = [4, 1, 3, 2]
        XCTAssertEqual(SpectralStemSeparator.median(&even, count: 4), 2.5)
        var flags = [true, false, true, true, true, false, true]
        SpectralStemSeparator.removeShortRuns(&flags, minimumLength: 2)
        XCTAssertEqual(flags, [false, false, true, true, true, false, false])
    }

    func testSilenceAndEmptyInput() throws {
        let silent = try SpectralStemSeparator().separate(channels: [[Float](repeating: 0, count: 30_000)], sampleRate: sampleRate)
        for kind in StemKind.allCases {
            XCTAssertEqual(silent.channels(for: kind)[0].count, 30_000)
            XCTAssertTrue(silent.channels(for: kind)[0].allSatisfy { $0 == 0 })
        }
        let empty = try SpectralStemSeparator().separate(channels: [[]], sampleRate: sampleRate)
        XCTAssertEqual(empty.frameCount, 0)
    }
}

/// テストで再現できる乱数。
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func nextGaussian() -> Double {
        let u1 = max(1e-12, nextUniform())
        let u2 = nextUniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}
