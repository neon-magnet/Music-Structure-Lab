import Foundation

/// 自己類似行列による楽曲構造(セクション)の推定。
///
/// 1. 拍ごとの特徴(クロマ + 音色)から自己類似行列を作る
/// 2. チェッカーボード・カーネル (Foote, 2000) で「切れ目らしさ」を求め、ピークを境界とする
/// 3. 境界を小節頭に寄せる
/// 4. 区間同士を時間方向に揃えて比べ、似ている区間に同じ記号 (A, B, C...) を付ける
public enum StructureAnalyzer {
    public struct Segment: Equatable, Sendable {
        /// 拍単位の半開区間。
        public var startBeat: Int
        public var endBeat: Int
        public var label: String
    }

    /// - Parameters:
    ///   - features: 拍ごとの特徴ベクトル。
    ///   - isDownbeat: 拍が小節頭かどうか。
    ///   - kernelRadius: 境界検出のカーネルの半径(拍)。
    ///   - minimumLength: セクションの最小の長さ(拍)。
    public static func segment(
        features: [[Float]],
        isDownbeat: (Int) -> Bool,
        kernelRadius: Int = 8,
        minimumLength: Int = 16
    ) -> [Segment] {
        let count = features.count
        guard count > 0 else { return [] }
        guard count >= minimumLength * 2 else {
            return [Segment(startBeat: 0, endBeat: count, label: "A")]
        }

        let smoothed = smooth(features, radius: 2).map(Features.l2Normalized)
        let ssm = similarityMatrix(smoothed)
        let curve = novelty(ssm, radius: kernelRadius)
        var boundaries = pickPeaks(curve, minimumDistance: minimumLength)
        boundaries = boundaries.map { snap($0, count: count, isDownbeat: isDownbeat) }
        boundaries = Array(Set(boundaries)).sorted()

        // 先頭と末尾を加え、短すぎる区間を前の区間にまとめる。
        var edges = [0] + boundaries.filter { $0 > 0 && $0 < count } + [count]
        var cleaned = [edges[0]]
        for edge in edges.dropFirst() {
            if edge - cleaned[cleaned.count - 1] >= minimumLength / 2 {
                cleaned.append(edge)
            } else if edge == count {
                cleaned[cleaned.count - 1] = count
            }
        }
        if cleaned.count < 2 { cleaned = [0, count] }
        if cleaned[0] != 0 { cleaned.insert(0, at: 0) }
        edges = cleaned

        let ranges = (0..<(edges.count - 1)).map { edges[$0]..<edges[$0 + 1] }
        let labels = label(ranges: ranges, ssm: ssm)
        return zip(ranges, labels).map { Segment(startBeat: $0.lowerBound, endBeat: $0.upperBound, label: $1) }
    }

    // MARK: - Steps

    static func smooth(_ features: [[Float]], radius: Int) -> [[Float]] {
        guard radius > 0, let dimension = features.first?.count else { return features }
        return features.indices.map { i in
            let lower = max(0, i - radius)
            let upper = min(features.count, i + radius + 1)
            var sum = [Float](repeating: 0, count: dimension)
            for j in lower..<upper {
                for d in 0..<dimension { sum[d] += features[j][d] }
            }
            return sum.map { $0 / Float(upper - lower) }
        }
    }

    static func similarityMatrix(_ normalized: [[Float]]) -> [[Float]] {
        let count = normalized.count
        var matrix = [[Float]](repeating: [Float](repeating: 0, count: count), count: count)
        for i in 0..<count {
            matrix[i][i] = 1
            for j in (i + 1)..<max(i + 1, count) {
                var dot: Float = 0
                for d in normalized[i].indices { dot += normalized[i][d] * normalized[j][d] }
                matrix[i][j] = dot
                matrix[j][i] = dot
            }
        }
        return matrix
    }

    static func novelty(_ ssm: [[Float]], radius: Int) -> [Float] {
        let count = ssm.count
        var kernel = [[Float]](repeating: [Float](repeating: 0, count: radius * 2), count: radius * 2)
        let sigma = Float(radius) / 2
        for a in 0..<(radius * 2) {
            for b in 0..<(radius * 2) {
                let x = Float(a - radius) + 0.5
                let y = Float(b - radius) + 0.5
                let sign: Float = (x < 0) == (y < 0) ? 1 : -1
                kernel[a][b] = sign * exp(-(x * x + y * y) / (2 * sigma * sigma))
            }
        }
        var curve = [Float](repeating: 0, count: count)
        // 端ではカーネルがはみ出して値が偏るので、半径ぶんは計算しない。
        guard count > radius * 2 else { return curve }
        for i in radius..<(count - radius) {
            var sum: Float = 0
            for a in 0..<(radius * 2) {
                let row = i + a - radius
                guard row >= 0, row < count else { continue }
                for b in 0..<(radius * 2) {
                    let column = i + b - radius
                    guard column >= 0, column < count else { continue }
                    sum += kernel[a][b] * ssm[row][column]
                }
            }
            curve[i] = max(0, sum)
        }
        return curve
    }

    static func pickPeaks(_ curve: [Float], minimumDistance: Int) -> [Int] {
        guard !curve.isEmpty else { return [] }
        let mean = curve.reduce(0, +) / Float(curve.count)
        let threshold = mean + 0.3 * Features.standardDeviation(curve)
        let candidates = curve.indices.filter { i in
            guard curve[i] > threshold else { return false }
            let lower = max(0, i - 4)
            let upper = min(curve.count - 1, i + 4)
            return (lower...upper).allSatisfy { curve[$0] <= curve[i] }
        }
        var chosen = [Int]()
        for index in candidates.sorted(by: { curve[$0] > curve[$1] }) {
            if chosen.allSatisfy({ abs($0 - index) >= minimumDistance }) {
                chosen.append(index)
            }
        }
        return chosen.sorted()
    }

    static func snap(_ beat: Int, count: Int, isDownbeat: (Int) -> Bool) -> Int {
        for distance in 0...2 {
            for candidate in [beat - distance, beat + distance] where candidate > 0 && candidate < count {
                if isDownbeat(candidate) { return candidate }
            }
        }
        return beat
    }

    /// 区間同士の似ている度合いで記号を付ける。
    static func label(ranges: [Range<Int>], ssm: [[Float]]) -> [String] {
        var values = [Float]()
        let count = ssm.count
        let step = max(1, count / 200)
        for i in stride(from: 0, to: count, by: step) {
            for j in stride(from: i + 1, to: count, by: step) { values.append(ssm[i][j]) }
        }
        values.sort()
        // 上位 20% 程度の類似度を「同じ素材」とみなす。ただし滑らかさの影響で 1 に届かないことがあるので上限を設ける。
        let threshold: Float = values.isEmpty ? 0.9 : min(0.9, values[Int(Double(values.count - 1) * 0.8)])

        var labels = [String]()
        var representatives = [(range: Range<Int>, label: String)]()
        for range in ranges {
            var bestLabel: String?
            var bestSimilarity: Float = -1
            for representative in representatives {
                let a = range.count
                let b = representative.range.count
                guard max(a, b) <= 2 * min(a, b) else { continue }
                let similarity = alignedSimilarity(range, representative.range, ssm: ssm)
                if similarity > bestSimilarity {
                    bestSimilarity = similarity
                    bestLabel = representative.label
                }
            }
            if let bestLabel, bestSimilarity >= threshold {
                labels.append(bestLabel)
            } else {
                let label = letter(representatives.count)
                representatives.append((range, label))
                labels.append(label)
            }
        }
        return labels
    }

    static func alignedSimilarity(_ a: Range<Int>, _ b: Range<Int>, ssm: [[Float]]) -> Float {
        let length = min(a.count, b.count)
        guard length > 0 else { return 0 }
        var sum: Float = 0
        for k in 0..<length {
            sum += ssm[a.lowerBound + k][b.lowerBound + k]
        }
        return sum / Float(length)
    }

    /// 0 → "A", 25 → "Z", 26 → "A2"...
    public static func letter(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let base = String(letters[index % 26])
        return index < 26 ? base : base + String(index / 26 + 1)
    }
}
