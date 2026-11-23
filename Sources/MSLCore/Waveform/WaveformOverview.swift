import Foundation

/// 区間内のサンプルの最小値・最大値。波形の 1 列ぶんを表す。
public struct WaveformPeak: Equatable, Sendable {
    public var min: Float
    public var max: Float

    public init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }

    /// 何も含まない状態。`merge` の初期値として使う。
    public static let empty = WaveformPeak(min: .greatestFiniteMagnitude, max: -.greatestFiniteMagnitude)

    public var isEmpty: Bool { min > max }

    public mutating func merge(_ other: WaveformPeak) {
        if other.min < min { min = other.min }
        if other.max > max { max = other.max }
    }

    public mutating func include(_ sample: Float) {
        if sample < min { min = sample }
        if sample > max { max = sample }
    }
}

/// 1 段の解像度。`samplesPerPeak` サンプルごとに 1 つのピークを持つ。
public struct WaveformLevel: Equatable, Sendable {
    public let samplesPerPeak: Int
    public let peaks: [WaveformPeak]

    public init(samplesPerPeak: Int, peaks: [WaveformPeak]) {
        self.samplesPerPeak = samplesPerPeak
        self.peaks = peaks
    }
}

/// 多段解像度(ミップマップ)の波形概要。
///
/// level 0 は `baseBlockSize` サンプルごとの min/max、以降の段は前の段を 2 つずつまとめたもの。
/// 表示時はズーム倍率に合った段を選ぶことで、長い音源でも 1 列あたりの計算量を一定に抑える。
public struct WaveformOverview: Equatable, Sendable {
    public let sampleCount: Int
    public let levels: [WaveformLevel]

    public init(sampleCount: Int, levels: [WaveformLevel]) {
        self.sampleCount = sampleCount
        self.levels = levels
    }

    public var baseBlockSize: Int { levels.first?.samplesPerPeak ?? 1 }

    /// 指定範囲のピークを集計する。
    ///
    /// - Parameters:
    ///   - range: サンプル番号の半開区間。音源の範囲外は無視される。
    ///   - samples: 元サンプル。`range` が level 0 のブロックより細かい場合に使う(nil なら level 0 で近似)。
    public func peak(in range: Range<Int>, samples: [Float]?) -> WaveformPeak {
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(sampleCount, range.upperBound)
        guard lower < upper else { return .empty }
        let length = upper - lower

        if let samples, length < baseBlockSize || levels.isEmpty {
            var result = WaveformPeak.empty
            let end = Swift.min(upper, samples.count)
            var i = lower
            while i < end {
                result.include(samples[i])
                i += 1
            }
            return result
        }

        // 区間長以下で最も粗い段を選ぶ(区間あたりのピーク数が 1〜数個になる)。
        var chosen = levels[0]
        for level in levels where level.samplesPerPeak <= length {
            chosen = level
        }
        let spp = chosen.samplesPerPeak
        let first = lower / spp
        let last = Swift.min(chosen.peaks.count, (upper + spp - 1) / spp)
        var result = WaveformPeak.empty
        var index = first
        while index < last {
            result.merge(chosen.peaks[index])
            index += 1
        }
        return result
    }

    /// 表示用に、`startSample` から `samplesPerColumn` ごとに `columns` 列ぶんのピークを返す。
    /// 音源の範囲外の列は `.empty` になる。
    public func columns(
        startSample: Double,
        samplesPerColumn: Double,
        columns: Int,
        samples: [Float]?
    ) -> [WaveformPeak] {
        guard columns > 0, samplesPerColumn > 0 else { return [] }
        var result = [WaveformPeak]()
        result.reserveCapacity(columns)
        for column in 0..<columns {
            let s = Int((startSample + Double(column) * samplesPerColumn).rounded(.down))
            var e = Int((startSample + Double(column + 1) * samplesPerColumn).rounded(.down))
            if e <= s { e = s + 1 }
            result.append(peak(in: s..<e, samples: samples))
        }
        return result
    }
}

/// サンプルを順に流し込んで `WaveformOverview` を作る。
/// デコードしながら少しずつ追加できるので、音源全体を 2 回走査する必要がない。
public struct WaveformBuilder: Sendable {
    public let baseBlockSize: Int
    private var basePeaks: [WaveformPeak] = []
    private var current = WaveformPeak.empty
    private var currentCount = 0
    private var total = 0

    public init(baseBlockSize: Int = 256) {
        precondition(baseBlockSize > 0, "baseBlockSize must be positive")
        self.baseBlockSize = baseBlockSize
    }

    public var sampleCount: Int { total }

    public mutating func reserveCapacity(forSampleCount count: Int) {
        basePeaks.reserveCapacity(count / baseBlockSize + 1)
    }

    public mutating func append<C: Collection>(contentsOf samples: C) where C.Element == Float {
        for sample in samples {
            current.include(sample)
            currentCount += 1
            if currentCount == baseBlockSize {
                basePeaks.append(current)
                current = .empty
                currentCount = 0
            }
        }
        total += samples.count
    }

    public func build() -> WaveformOverview {
        var base = basePeaks
        if currentCount > 0 {
            base.append(current)
        }
        guard !base.isEmpty else {
            return WaveformOverview(sampleCount: 0, levels: [])
        }
        var levels = [WaveformLevel(samplesPerPeak: baseBlockSize, peaks: base)]
        var previous = base
        var spp = baseBlockSize
        while previous.count > 1 {
            var next = [WaveformPeak]()
            next.reserveCapacity((previous.count + 1) / 2)
            var i = 0
            while i < previous.count {
                var merged = previous[i]
                if i + 1 < previous.count {
                    merged.merge(previous[i + 1])
                }
                next.append(merged)
                i += 2
            }
            spp *= 2
            levels.append(WaveformLevel(samplesPerPeak: spp, peaks: next))
            previous = next
        }
        return WaveformOverview(sampleCount: total, levels: levels)
    }
}
