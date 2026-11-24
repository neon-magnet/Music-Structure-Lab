import Foundation

/// スペクトログラムから求める特徴量。
public enum Features {
    // MARK: - Onset

    /// 立ち上がりの強さ(スペクトルフラックス)。拍・テンポ推定に使う。
    /// 局所平均を引いて半波整流し、標準偏差で正規化してある。
    public static func onsetEnvelope(_ spectrogram: Spectrogram) -> [Float] {
        let frames = spectrogram.magnitudes
        guard frames.count > 1 else { return [Float](repeating: 0, count: frames.count) }
        let maxBin = min(spectrogram.binCount, Int(Double(spectrogram.fftSize) * 11_000 / spectrogram.sampleRate))
        var previous = frames[0].prefix(maxBin).map { log1pf(1000 * $0) }
        var flux = [Float](repeating: 0, count: frames.count)
        for t in 1..<frames.count {
            var sum: Float = 0
            var current = [Float](repeating: 0, count: maxBin)
            for k in 0..<maxBin {
                let value = log1pf(1000 * frames[t][k])
                current[k] = value
                let diff = value - previous[k]
                if diff > 0 { sum += diff }
            }
            flux[t] = sum
            previous = current
        }

        // 局所平均(約 0.5 秒)を引く
        let radius = max(1, Int(spectrogram.frameRate * 0.25))
        let mean = movingAverage(flux, radius: radius)
        var envelope = zip(flux, mean).map { max(0, $0 - $1) }
        let std = standardDeviation(envelope)
        if std > 0 {
            for i in envelope.indices { envelope[i] /= std }
        }
        return envelope
    }

    // MARK: - Chroma

    /// フレームごとのクロマ(12 音名の強さ)。55Hz〜4.2kHz の成分を音名に割り当てる。
    public static func chroma(_ spectrogram: Spectrogram) -> [[Float]] {
        var mapping = [(bin: Int, pitchClass: Int)]()
        for bin in 1..<spectrogram.binCount {
            let frequency = spectrogram.frequency(ofBin: bin)
            guard frequency >= 55, frequency <= 4200 else { continue }
            let midi = 69 + 12 * log2(frequency / 440)
            mapping.append((bin, PitchClass.normalize(Int(midi.rounded()))))
        }
        return spectrogram.magnitudes.map { frame in
            var chroma = [Float](repeating: 0, count: 12)
            for entry in mapping {
                chroma[entry.pitchClass] += frame[entry.bin]
            }
            return chroma
        }
    }

    // MARK: - Timbre

    /// 音色のおおまかな特徴: 対数間隔の帯域ごとの対数エネルギー(平均を引いたもの)。
    public static func bandEnergies(_ spectrogram: Spectrogram, bands: Int = 16) -> [[Float]] {
        let low = 60.0
        let high = min(10_000.0, spectrogram.sampleRate / 2)
        var edges = [Int]()
        for i in 0...bands {
            let frequency = low * pow(high / low, Double(i) / Double(bands))
            edges.append(min(spectrogram.binCount - 1, max(1, Int(frequency * Double(spectrogram.fftSize) / spectrogram.sampleRate))))
        }
        return spectrogram.magnitudes.map { frame in
            var values = [Float](repeating: 0, count: bands)
            for b in 0..<bands {
                let lower = edges[b]
                let upper = max(edges[b + 1], lower + 1)
                var sum: Float = 0
                for k in lower..<min(upper, frame.count) { sum += frame[k] * frame[k] }
                values[b] = log10f(sum + 1e-10)
            }
            let mean = values.reduce(0, +) / Float(bands)
            return values.map { $0 - mean }
        }
    }

    /// フレームごとのエネルギー(振幅の二乗和)。
    public static func frameEnergy(_ spectrogram: Spectrogram) -> [Float] {
        spectrogram.magnitudes.map { frame in frame.reduce(0) { $0 + $1 * $1 } }
    }

    // MARK: - Beat-synchronous

    /// 拍などの区切り時刻で区間を作り、区間ごとにフレームの特徴を平均する。
    /// `boundaries` は昇順で、n 個の区切りから n-1 個の区間ができる。
    public static func aggregate(_ features: [[Float]], spectrogram: Spectrogram, boundaries: [Double]) -> [[Float]] {
        guard boundaries.count >= 2, let dimension = features.first?.count else { return [] }
        var result = [[Float]]()
        result.reserveCapacity(boundaries.count - 1)
        for i in 0..<(boundaries.count - 1) {
            var first = spectrogram.frame(atTime: boundaries[i])
            var last = spectrogram.frame(atTime: boundaries[i + 1])
            first = min(max(0, first), features.count - 1)
            last = min(max(first + 1, last), features.count)
            var sum = [Float](repeating: 0, count: dimension)
            for t in first..<last {
                for d in 0..<dimension { sum[d] += features[t][d] }
            }
            let scale = 1 / Float(last - first)
            result.append(sum.map { $0 * scale })
        }
        return result
    }

    public static func aggregate(_ values: [Float], spectrogram: Spectrogram, boundaries: [Double]) -> [Float] {
        aggregate(values.map { [$0] }, spectrogram: spectrogram, boundaries: boundaries).map { $0[0] }
    }

    // MARK: - Helpers

    public static func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        guard !values.isEmpty, radius > 0 else { return values }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for i in values.indices { prefix[i + 1] = prefix[i] + Double(values[i]) }
        return values.indices.map { i in
            let lower = max(0, i - radius)
            let upper = min(values.count, i + radius + 1)
            return Float((prefix[upper] - prefix[lower]) / Double(upper - lower))
        }
    }

    public static func standardDeviation(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        return variance.squareRoot()
    }

    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return vector.map { _ in 0 } }
        return vector.map { $0 / norm }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denominator = (na * nb).squareRoot()
        return denominator > 1e-12 ? dot / denominator : 0
    }
}
