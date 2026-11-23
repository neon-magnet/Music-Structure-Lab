import Foundation

public struct KeyEstimate: Equatable, Sendable {
    public var key: MusicalKey
    /// 0...1。1 位と 2 位の相関の差。
    public var confidence: Double
}

/// Krumhansl-Schmuckler 法による調の推定。
public enum KeyDetector {
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// - Parameter chroma: 曲全体で合計したクロマ(12 要素)。
    public static func estimate(chroma: [Float]) -> KeyEstimate? {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return nil }
        let values = chroma.map(Double.init)
        var scored = [(MusicalKey, Double)]()
        for mode in KeyMode.allCases {
            let profile = mode == .major ? majorProfile : minorProfile
            for tonic in 0..<12 {
                let rotated = (0..<12).map { profile[PitchClass.normalize($0 - tonic)] }
                scored.append((MusicalKey(tonic: tonic, mode: mode), pearson(values, rotated)))
            }
        }
        scored.sort { $0.1 > $1.1 }
        let confidence = min(1, max(0, (scored[0].1 - scored[1].1) * 5))
        return KeyEstimate(key: scored[0].0, confidence: confidence)
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var numerator = 0.0
        var denomA = 0.0
        var denomB = 0.0
        for i in a.indices {
            let da = a[i] - meanA
            let db = b[i] - meanB
            numerator += da * db
            denomA += da * da
            denomB += db * db
        }
        let denominator = (denomA * denomB).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
    }
}

/// 区間ごとのクロマから、メジャー/マイナーの三和音を認識する。
/// 隠れマルコフモデル風の平滑化(同じコードが続きやすい)で、細かい揺れを抑える。
public enum ChordRecognizer {
    /// 認識対象(24 個の三和音)。
    public static let candidates: [Chord] = (0..<12).flatMap { root in
        [Chord(root: root, quality: .major), Chord(root: root, quality: .minor)]
    }

    /// - Parameters:
    ///   - chroma: 区間ごとのクロマ。
    ///   - energy: 区間ごとのエネルギー。小さい区間はノーコードにする。
    ///   - changePenalty: コードが変わる時のペナルティ。大きいほど変化しにくい。
    /// - Returns: 区間ごとのコード(nil はノーコード)。
    public static func recognize(chroma: [[Float]], energy: [Float], changePenalty: Float = 0.12) -> [Chord?] {
        let count = chroma.count
        guard count > 0 else { return [] }
        let templates = candidates.map { chord -> [Float] in
            var vector = [Float](repeating: 0, count: 12)
            for (index, pc) in chord.pitchClasses.enumerated() {
                vector[pc] = index == 0 ? 1.0 : 0.8
            }
            return Features.l2Normalized(vector)
        }
        let flat = Features.l2Normalized([Float](repeating: 1, count: 12))
        let maxEnergy = energy.max() ?? 0
        let silenceThreshold = maxEnergy * 1e-4 // -40dB

        let stateCount = templates.count + 1 // 最後はノーコード
        var emissions = [[Float]](repeating: [Float](repeating: 0, count: stateCount), count: count)
        for t in 0..<count {
            let silent = t < energy.count && energy[t] <= silenceThreshold
            if silent {
                emissions[t][stateCount - 1] = 1
                continue
            }
            let vector = Features.l2Normalized(chroma[t])
            for s in 0..<templates.count {
                emissions[t][s] = Features.cosine(vector, templates[s])
            }
            emissions[t][stateCount - 1] = 0.7 * Features.cosine(vector, flat)
        }

        // ビタビ
        var score = emissions[0]
        var backpointers = [[Int]](repeating: [Int](repeating: 0, count: stateCount), count: count)
        for t in 1..<count {
            var bestPrevious = 0
            for s in 1..<stateCount where score[s] > score[bestPrevious] {
                bestPrevious = s
            }
            var next = [Float](repeating: 0, count: stateCount)
            for s in 0..<stateCount {
                let stay = score[s]
                let move = score[bestPrevious] - changePenalty
                if stay >= move {
                    next[s] = stay + emissions[t][s]
                    backpointers[t][s] = s
                } else {
                    next[s] = move + emissions[t][s]
                    backpointers[t][s] = bestPrevious
                }
            }
            score = next
        }
        var state = 0
        for s in 1..<stateCount where score[s] > score[state] {
            state = s
        }
        var path = [Int](repeating: 0, count: count)
        for t in stride(from: count - 1, through: 0, by: -1) {
            path[t] = state
            state = backpointers[t][state]
        }
        return path.map { $0 == stateCount - 1 ? nil : candidates[$0] }
    }

    /// 区間ごとのコードを、同じコードが続く部分でまとめる。
    public static func segments(chords: [Chord?], boundaries: [Double]) -> [ChordSegment] {
        guard boundaries.count == chords.count + 1 else { return [] }
        var result = [ChordSegment]()
        for (index, chord) in chords.enumerated() {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            if let last = result.last, last.chord == chord {
                result[result.count - 1].end = end
            } else {
                result.append(ChordSegment(start: start, end: end, chord: chord))
            }
        }
        return result
    }
}
