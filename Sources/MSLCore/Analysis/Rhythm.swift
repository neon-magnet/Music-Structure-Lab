import Foundation

public struct TempoEstimate: Equatable, Sendable {
    public var bpm: Double
    /// 0...1。自己相関のピークがどれだけ際立っているか。
    public var confidence: Double
}

/// 立ち上がり強度の自己相関からテンポを推定する。
public enum TempoEstimator {
    public static let minimumBPM = 50.0
    public static let maximumBPM = 220.0

    /// - Parameters:
    ///   - onset: `Features.onsetEnvelope` の出力。
    ///   - frameRate: onset の 1 秒あたりのフレーム数。
    ///   - preferredBPM: 事前分布の中心。倍・半分のテンポの取り違えを減らす。
    public static func estimate(onset: [Float], frameRate: Double, preferredBPM: Double = 120) -> TempoEstimate? {
        let minLag = max(1, Int((60 / maximumBPM * frameRate).rounded(.down)))
        let maxLag = Int((60 / minimumBPM * frameRate).rounded(.up))
        guard onset.count > maxLag * 2 + 2 else { return nil }

        let lagLimit = min(onset.count - 1, maxLag * 2 + 1)
        var correlation = [Double](repeating: 0, count: lagLimit + 1)
        for lag in 0...lagLimit {
            var sum = 0.0
            let count = onset.count - lag
            for t in 0..<count {
                sum += Double(onset[t]) * Double(onset[t + lag])
            }
            correlation[lag] = sum / Double(count)
        }

        var bestLag = minLag
        var bestScore = -Double.infinity
        var scores = [Double]()
        for lag in minLag...maxLag {
            let bpm = 60 * frameRate / Double(lag)
            let octaves = log2(bpm / preferredBPM)
            let prior = exp(-0.5 * octaves * octaves)
            // 2 倍の周期にも相関があるほど、その周期が拍らしい。
            var support = correlation[lag]
            if lag * 2 <= lagLimit { support += 0.5 * correlation[lag * 2] }
            let score = prior * support
            scores.append(score)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        // 放物線補間で周期を細かく求める。
        var refinedLag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let y0 = correlation[bestLag - 1]
            let y1 = correlation[bestLag]
            let y2 = correlation[bestLag + 1]
            let denominator = y0 - 2 * y1 + y2
            if abs(denominator) > 1e-12 {
                let delta = 0.5 * (y0 - y2) / denominator
                if abs(delta) < 1 { refinedLag += delta }
            }
        }

        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        let confidence = bestScore > 0 ? min(1, max(0, (bestScore - median) / bestScore)) : 0
        return TempoEstimate(bpm: 60 * frameRate / refinedLag, confidence: confidence)
    }
}

/// 動的計画法による拍の追跡 (Ellis, 2007)。
public enum BeatTracker {
    /// - Returns: 拍のフレーム番号(昇順)。
    public static func track(onset: [Float], frameRate: Double, bpm: Double, tightness: Double = 100) -> [Int] {
        guard !onset.isEmpty, bpm > 0 else { return [] }
        let period = 60 * frameRate / bpm
        guard period >= 1 else { return [] }
        let count = onset.count
        var score = [Double](repeating: 0, count: count)
        var backlink = [Int](repeating: -1, count: count)
        let searchStart = Int((2 * period).rounded())
        let searchEnd = Int((period / 2).rounded())

        for t in 0..<count {
            var best = -Double.infinity
            var bestPrevious = -1
            let lower = max(0, t - searchStart)
            let upper = t - searchEnd
            if upper >= lower {
                for p in lower...upper {
                    let interval = Double(t - p)
                    let penalty = log(interval / period)
                    let value = score[p] - tightness * penalty * penalty
                    if value > best {
                        best = value
                        bestPrevious = p
                    }
                }
            }
            if bestPrevious >= 0, best > 0 {
                score[t] = Double(onset[t]) + best
                backlink[t] = bestPrevious
            } else {
                score[t] = Double(onset[t])
            }
        }

        // 最後の 1 周期の中で最もスコアの高いフレームから辿る。
        let tailStart = max(0, count - Int(period.rounded(.up)))
        var end = tailStart
        for t in tailStart..<count where score[t] > score[end] {
            end = t
        }
        var beats = [Int]()
        var current = end
        while current >= 0 {
            beats.append(current)
            current = backlink[current]
        }
        beats.reverse()

        // 先頭側で辿れなかった拍を、周期で埋める(曲頭の静かな部分など)。
        if let first = beats.first {
            var filled = [Int]()
            var position = Double(first) - period
            while position >= 0 {
                filled.append(Int(position.rounded()))
                position -= period
            }
            beats = filled.reversed() + beats
        }
        return beats
    }

    /// 小節頭がどの拍から始まるかを推定する。
    /// 各位相について、小節頭の拍での「立ち上がり」と「和音の変化」の平均を比べる。
    public static func downbeatOffset(beatStrength: [Float], harmonicChange: [Float], beatsPerBar: Int) -> Int {
        guard beatsPerBar > 1, !beatStrength.isEmpty else { return 0 }
        var bestPhase = 0
        var bestScore = -Float.infinity
        let strength = normalize(beatStrength)
        let change = normalize(harmonicChange)
        for phase in 0..<beatsPerBar {
            var sum: Float = 0
            var count = 0
            var index = phase
            while index < strength.count {
                sum += strength[index] + 1.5 * (index < change.count ? change[index] : 0)
                count += 1
                index += beatsPerBar
            }
            let score = count > 0 ? sum / Float(count) : 0
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
        }
        return bestPhase
    }

    private static func normalize(_ values: [Float]) -> [Float] {
        guard let maximum = values.max(), maximum > 0 else { return values }
        return values.map { $0 / maximum }
    }
}
