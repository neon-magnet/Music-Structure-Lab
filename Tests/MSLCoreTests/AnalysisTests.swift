@testable import MSLCore
import XCTest

final class FFTTests: XCTestCase {
    func testMatchesReferenceImplementation() throws {
        let fft = try XCTUnwrap(FFT(size: 1024))
        var generator = SystemRandomNumberGenerator()
        let input = (0..<1024).map { _ in Float.random(in: -1...1, using: &generator) }
        let fast = fft.magnitudes(input)
        let reference = fft.referenceMagnitudes(input)
        XCTAssertEqual(fast.count, 513)
        for k in fast.indices {
            XCTAssertEqual(fast[k], reference[k], accuracy: 1e-2 * max(1, reference[k]))
        }
    }

    func testSinePeaksAtItsBin() throws {
        let size = 2048
        let fft = try XCTUnwrap(FFT(size: size))
        let bin = 100
        let input = (0..<size).map { Float(sin(2 * Double.pi * Double(bin) * Double($0) / Double(size))) }
        let magnitudes = fft.magnitudes(input)
        let peak = magnitudes.indices.max { magnitudes[$0] < magnitudes[$1] }
        XCTAssertEqual(peak, bin)
        XCTAssertEqual(magnitudes[bin], Float(size) / 2, accuracy: 1)
    }

    func testRejectsNonPowerOfTwo() {
        XCTAssertNil(FFT(size: 1000))
    }
}

final class MusicAnalyzerTests: XCTestCase {
    /// 120 BPM のクリックと、C → Am の和音を合成した 32 秒の音源。
    private func makeSignal(sampleRate: Double = 22_050) -> [Float] {
        let duration = 32.0
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        let cMajor = [261.63, 329.63, 392.00, 130.81]
        let aMinor = [220.00, 261.63, 329.63, 110.00]
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let chord = t < 16 ? cMajor : aMinor
            var value = 0.0
            for frequency in chord { value += 0.12 * sin(2 * Double.pi * frequency * t) }
            // クリック(拍ごとに減衰するノイズ風の高音)
            let beatPhase = t.truncatingRemainder(dividingBy: 0.5)
            if beatPhase < 0.03 {
                let envelope = exp(-beatPhase * 150)
                value += 0.5 * envelope * sin(2 * Double.pi * 3000 * t) * (Int(t / 0.5) % 4 == 0 ? 1.0 : 0.7)
            }
            samples[i] = Float(value)
        }
        return samples
    }

    func testDetectsTempoChordsAndKey() throws {
        let sampleRate = 22_050.0
        let result = try MusicAnalyzer().analyze(samples: makeSignal(sampleRate: sampleRate), sampleRate: sampleRate)

        XCTAssertEqual(result.duration, 32, accuracy: 0.01)
        XCTAssertEqual(result.beatGrid.bpm, 120, accuracy: 3)
        let beats = result.beatGrid.beats
        XCTAssertGreaterThan(beats.count, 50)
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        XCTAssertEqual(intervals[intervals.count / 2], 0.5, accuracy: 0.03)

        let early = try XCTUnwrap(result.chordSegment(at: 6)?.chord)
        XCTAssertEqual(early, Chord(root: 0, quality: .major))
        let late = try XCTUnwrap(result.chordSegment(at: 26)?.chord)
        XCTAssertEqual(late, Chord(root: 9, quality: .minor))

        let key = try XCTUnwrap(result.key)
        XCTAssertTrue(
            key == MusicalKey(tonic: 0, mode: .major) || key == MusicalKey(tonic: 9, mode: .minor),
            "C major か A minor を期待: \(key.name)"
        )

        XCTAssertFalse(result.sections.isEmpty)
        XCTAssertEqual(result.sections.first?.start, 0)
        XCTAssertEqual(result.sections.last?.end ?? 0, 32, accuracy: 0.01)
        for (a, b) in zip(result.sections, result.sections.dropFirst()) {
            XCTAssertEqual(a.end, b.start, accuracy: 1e-9)
        }
        for (a, b) in zip(result.chords, result.chords.dropFirst()) {
            XCTAssertEqual(a.end, b.start, accuracy: 1e-9)
        }
    }

    func testRejectsVeryShortAudio() {
        XCTAssertThrowsError(try MusicAnalyzer().analyze(samples: [Float](repeating: 0, count: 1000), sampleRate: 44_100)) { error in
            XCTAssertEqual(error as? AnalysisError, .tooShort)
        }
    }

    func testSilenceDoesNotCrash() throws {
        let result = try MusicAnalyzer().analyze(samples: [Float](repeating: 0, count: 22_050 * 8), sampleRate: 22_050)
        XCTAssertFalse(result.beatGrid.beats.isEmpty)
        XCTAssertTrue(result.chords.allSatisfy { $0.chord == nil })
    }
}

final class StructureAnalyzerTests: XCTestCase {
    func testFindsRepeatedSections() {
        let a: [Float] = [1, 0, 0, 0, 1, 0]
        let b: [Float] = [0, 1, 0, 1, 0, 0]
        let features = Array(repeating: a, count: 32) + Array(repeating: b, count: 32) + Array(repeating: a, count: 32)
        let segments = StructureAnalyzer.segment(features: features, isDownbeat: { $0 % 4 == 0 })
        XCTAssertEqual(segments.map(\.startBeat), [0, 32, 64])
        XCTAssertEqual(segments.map(\.label), ["A", "B", "A"])
        XCTAssertEqual(segments.last?.endBeat, 96)
    }

    func testShortInputIsOneSection() {
        let segments = StructureAnalyzer.segment(features: Array(repeating: [1, 0], count: 10), isDownbeat: { _ in true })
        XCTAssertEqual(segments, [StructureAnalyzer.Segment(startBeat: 0, endBeat: 10, label: "A")])
    }

    func testLetters() {
        XCTAssertEqual(StructureAnalyzer.letter(0), "A")
        XCTAssertEqual(StructureAnalyzer.letter(25), "Z")
        XCTAssertEqual(StructureAnalyzer.letter(26), "A2")
    }
}

final class MusicTheoryTests: XCTestCase {
    func testRomanNumerals() {
        let c = MusicalKey(tonic: 0, mode: .major)
        XCTAssertEqual(MusicTheory.romanNumeral(for: Chord(root: 9, quality: .minor), in: c), "vi")
        XCTAssertEqual(MusicTheory.romanNumeral(for: Chord(root: 7, quality: .dominant7), in: c), "V7")
        XCTAssertEqual(MusicTheory.romanNumeral(for: Chord(root: 10, quality: .major), in: c), "♭VII")
        XCTAssertEqual(MusicTheory.romanNumeral(for: Chord(root: 11, quality: .diminished), in: c), "vii°")
        let aMinor = MusicalKey(tonic: 9, mode: .minor)
        XCTAssertEqual(MusicTheory.romanNumeral(for: Chord(root: 0, quality: .major), in: aMinor), "♭III")
    }

    func testKeySignatures() {
        XCTAssertEqual(MusicalKey(tonic: 7, mode: .major).sharpsOrFlats, 1)
        XCTAssertEqual(MusicalKey(tonic: 5, mode: .major).sharpsOrFlats, -1)
        XCTAssertEqual(MusicalKey(tonic: 4, mode: .minor).sharpsOrFlats, 1) // E minor
        XCTAssertEqual(MusicalKey(tonic: 2, mode: .minor).sharpsOrFlats, -1) // D minor
        XCTAssertEqual(MusicalKey(tonic: 10, mode: .major).shortName, "Bb")
        XCTAssertEqual(MusicalKey(tonic: 6, mode: .minor).shortName, "F#m")
    }

    func testDiatonicTriads() {
        let symbols = MusicTheory.diatonicTriads(in: MusicalKey(tonic: 0, mode: .major)).map { $0.symbol() }
        XCTAssertEqual(symbols, ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])
        XCTAssertTrue(MusicTheory.isDiatonic(Chord(root: 7, quality: .dominant7), in: MusicalKey(tonic: 0, mode: .major)))
        XCTAssertFalse(MusicTheory.isDiatonic(Chord(root: 10, quality: .major), in: MusicalKey(tonic: 0, mode: .major)))
    }

    func testKeyDetectorFindsCMajorProfile() throws {
        let chroma: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let estimate = try XCTUnwrap(KeyDetector.estimate(chroma: chroma))
        XCTAssertEqual(estimate.key, MusicalKey(tonic: 0, mode: .major))
    }
}
