import Foundation

public enum AnalysisStage: String, CaseIterable, Sendable {
    case spectrum
    case rhythm
    case harmony
    case structure

    public var title: String {
        switch self {
        case .spectrum: return "スペクトル解析"
        case .rhythm: return "テンポ・拍の解析"
        case .harmony: return "キー・コードの解析"
        case .structure: return "楽曲構造の解析"
        }
    }

    /// 全体の進捗に占める割合の開始位置と幅。
    var span: (start: Double, length: Double) {
        switch self {
        case .spectrum: return (0, 0.6)
        case .rhythm: return (0.6, 0.15)
        case .harmony: return (0.75, 0.1)
        case .structure: return (0.85, 0.15)
        }
    }
}

public enum AnalysisError: LocalizedError, Equatable {
    case tooShort

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "音源が短すぎるため解析できません(5 秒以上必要です)。"
        }
    }
}

/// 音源全体の解析(テンポ・拍・小節、キー、コード、楽曲構造)。
///
/// 信号処理による推定なので誤りを含みうる。結果は利用者が編集できる前提で使う。
public struct MusicAnalyzer: Sendable {
    public var beatsPerBar: Int
    public var fftSize: Int
    public var hopSize: Int

    public init(beatsPerBar: Int = 4, fftSize: Int = 2048, hopSize: Int = 512) {
        self.beatsPerBar = beatsPerBar
        self.fftSize = fftSize
        self.hopSize = hopSize
    }

    /// - Parameters:
    ///   - samples: モノラルのサンプル。
    ///   - progress: (段階, 全体の進捗 0...1)。
    public func analyze(
        samples: [Float],
        sampleRate: Double,
        progress: @Sendable (AnalysisStage, Double) -> Void = { _, _ in }
    ) throws -> AnalysisResult {
        let duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        guard duration >= 5 else { throw AnalysisError.tooShort }

        func report(_ stage: AnalysisStage, _ fraction: Double) {
            progress(stage, stage.span.start + stage.span.length * min(1, max(0, fraction)))
        }

        // 1. スペクトル
        report(.spectrum, 0)
        let factor = Resampling.analysisFactor(for: sampleRate)
        let reduced = Resampling.decimate(samples, factor: factor)
        let reducedRate = sampleRate / Double(factor)
        let spectrogram = try Spectrogram.compute(
            samples: reduced,
            sampleRate: reducedRate,
            fftSize: fftSize,
            hopSize: hopSize
        ) { report(.spectrum, $0) }
        try Task.checkCancellation()

        // 2. テンポ・拍
        report(.rhythm, 0)
        let onset = Features.onsetEnvelope(spectrogram)
        let tempo = TempoEstimator.estimate(onset: onset, frameRate: spectrogram.frameRate)
            ?? TempoEstimate(bpm: 120, confidence: 0)
        report(.rhythm, 0.4)
        let beatFrames = BeatTracker.track(onset: onset, frameRate: spectrogram.frameRate, bpm: tempo.bpm)
        var beats = beatFrames.map { spectrogram.time(ofFrame: $0) }.filter { $0 < duration }
        if beats.count < 2 {
            beats = Self.uniformBeats(bpm: tempo.bpm, start: 0, duration: duration)
        }
        try Task.checkCancellation()
        report(.rhythm, 1)

        // 3. キー・コード
        report(.harmony, 0)
        let boundaries = Self.boundaries(beats: beats, duration: duration)
        let leadingSegment = (beats.first ?? 0) > 0.05
        let chroma = Features.chroma(spectrogram)
        let energy = Features.frameEnergy(spectrogram)
        let segmentChroma = Features.aggregate(chroma, spectrogram: spectrogram, boundaries: boundaries)
        let segmentEnergy = Features.aggregate(energy, spectrogram: spectrogram, boundaries: boundaries)
        var totalChroma = [Float](repeating: 0, count: 12)
        let maxEnergy = segmentEnergy.max() ?? 0
        for (index, vector) in segmentChroma.enumerated() where segmentEnergy[index] > maxEnergy * 1e-4 {
            let sum = vector.reduce(0, +)
            guard sum > 0 else { continue }
            for pc in 0..<12 { totalChroma[pc] += vector[pc] / sum }
        }
        let key = KeyDetector.estimate(chroma: totalChroma)
        let chordPerSegment = ChordRecognizer.recognize(chroma: segmentChroma, energy: segmentEnergy)
        let chords = ChordRecognizer.segments(chords: chordPerSegment, boundaries: boundaries)
        try Task.checkCancellation()
        report(.harmony, 1)

        // 4. 小節頭と構造
        report(.structure, 0)
        // 拍ごとの値に揃える(先頭の拍より前の区間を除く)
        let offset = leadingSegment ? 1 : 0
        let beatChroma = Array(segmentChroma.dropFirst(offset).prefix(beats.count))
        let beatStrength = beats.map { time -> Float in
            let frame = min(max(0, spectrogram.frame(atTime: time)), onset.count - 1)
            return onset.isEmpty ? 0 : onset[frame]
        }
        var harmonicChange = [Float](repeating: 0, count: beatChroma.count)
        for i in 1..<max(1, beatChroma.count) {
            harmonicChange[i] = 1 - Features.cosine(beatChroma[i], beatChroma[i - 1])
        }
        let downbeatOffset = BeatTracker.downbeatOffset(
            beatStrength: beatStrength,
            harmonicChange: harmonicChange,
            beatsPerBar: beatsPerBar
        )
        let grid = BeatGrid(bpm: tempo.bpm, beats: beats, beatsPerBar: beatsPerBar, downbeatOffset: downbeatOffset)

        let timbre = Features.aggregate(Features.bandEnergies(spectrogram), spectrogram: spectrogram, boundaries: boundaries)
        let beatTimbre = Array(timbre.dropFirst(offset).prefix(beats.count))
        let beatFeatures = zip(beatChroma, beatTimbre).map { chromaVector, timbreVector in
            Features.l2Normalized(chromaVector) + Features.l2Normalized(timbreVector).map { $0 * 0.8 }
        }
        let structure = StructureAnalyzer.segment(features: beatFeatures, isDownbeat: grid.isDownbeat)
        let sections = structure.enumerated().map { index, segment -> Section in
            let start = index == 0 ? 0 : beats[min(segment.startBeat, beats.count - 1)]
            let isLast = index == structure.count - 1
            let end = isLast || segment.endBeat >= beats.count ? duration : beats[segment.endBeat]
            return Section(start: start, end: end, label: segment.label, name: "セクション \(segment.label)")
        }
        report(.structure, 1)

        return AnalysisResult(
            duration: duration,
            beatGrid: grid,
            tempoConfidence: tempo.confidence,
            key: key?.key,
            keyConfidence: key?.confidence ?? 0,
            chords: chords,
            sections: sections.isEmpty
                ? [Section(start: 0, end: duration, label: "A", name: "セクション A")]
                : sections
        )
    }

    /// 拍の時刻から区間の区切りを作る。曲頭から最初の拍までと、最後の拍から曲末までも区間に含める。
    static func boundaries(beats: [Double], duration: Double) -> [Double] {
        var result = [Double]()
        if let first = beats.first, first > 0.05 { result.append(0) }
        result.append(contentsOf: beats)
        if let last = beats.last, duration - last > 0.05 { result.append(duration) }
        if result.count < 2 { result = [0, duration] }
        return result
    }

    /// 一定テンポの拍を作る。
    public static func uniformBeats(bpm: Double, start: Double, duration: Double) -> [Double] {
        guard bpm > 0, duration > 0 else { return [] }
        let period = 60 / bpm
        var beats = [Double]()
        var time = start
        while time > period { time -= period }
        while time < duration {
            if time >= 0 { beats.append(time) }
            time += period
        }
        return beats
    }
}
