import Foundation

/// モデルを使わない、信号処理によるパートの近似分離。
///
/// 1. 短時間フーリエ変換の振幅に、時間方向・周波数方向のメディアンフィルタをかけ、
///    持続音成分 H と打楽器成分 P を求める(HPSS, Fitzgerald 2010)。
/// 2. 打楽器成分の割合 P²/(H²+P²) を ドラム に振り分ける。
/// 3. 持続音成分のうち、低域(既定で 180Hz 以下、300Hz までなだらかに減らす)を ベース にする。
/// 4. ステレオなら、残りの持続音成分のうち左右で同じ(中央に定位した)成分を ボーカル にする。
///    左右の相関 2·Re(L·R̄)/(|L|²+|R|²) を 4 乗した重みを使う。中央に置かれた楽器も入る。
/// 5. 持続音成分から主旋律の音高を追い(倍音の重み付き和 + 音高の跳躍を抑える動的計画法)、
///    ボーカルに振り分けなかった分のうち、その倍音の周波数を メロディ にする。
/// 6. 残りを コード(伴奏) にする(元の信号からほかのパートを引いて作るので、全パートの和は元の音と一致する)。
///
/// あくまで近似で、パート間の漏れは大きい。ボーカルの子音はドラムに、低音の楽器はベースに入る。
/// モノラル(または左右がほぼ同じ)の音源ではボーカルを分けられないので、ボーカルは無音になる。
public struct SpectralStemSeparator: Sendable {
    public struct Parameters: Sendable {
        /// メディアンフィルタの長さ(フレーム数・ビン数。奇数)。
        public var harmonicMedianLength = 17
        public var percussiveMedianLength = 17
        public var bassFullBelow = 180.0
        public var bassNoneAbove = 300.0
        /// ボーカルの重み(左右の相関)にかける指数。大きいほど中央のものだけを取る。
        public var vocalCenterExponent: Float = 4
        /// 左右の差の大きさが和のこの割合より小さければ、モノラルとみなしてボーカルを分けない。
        public var monoSideRatio = 0.001
        public var melodyLowestHz = 150.0
        public var melodyHighestHz = 1_100.0
        /// メロディとして取り出す倍音の上限周波数。
        public var melodyMaxHarmonicHz = 10_000.0
        public var salienceHarmonics = 10
        /// 音高候補の細かさ(半音あたりの候補数)。
        public var stepsPerSemitone = 2
        /// 音高の跳躍に対するペナルティ(候補 1 つ分あたり)。
        public var jumpPenalty: Float = 0.12
        /// 有声と判定する、候補の中での最大値と平均の比。
        public var voicingPeakRatio: Float = 1.8
        /// 有声と判定する、フレームの最大値の曲全体(大きい方から 5% の位置)に対する比。
        /// 伴奏だけの区間をメロディとして拾わないためのもの。
        public var voicingSalienceRatio: Float = 0.75
        /// 有声と判定する、フレームの持続音の大きさ(大きい方から 5% の位置に対する比)。
        public var voicingLevelRatio: Float = 0.05
        /// これより短い有声区間は無声として扱う(秒)。
        public var minimumVoicedDuration = 0.12
        /// 高い音の候補を少し優先する度合い(主旋律は上の声部にあることが多いため)。
        public var highPitchBias: Float = 0.4

        public init() {}
    }

    /// 主旋律の音高の推定結果(フレームごと)。
    public struct MelodyTrack: Sendable {
        /// 基本周波数(無声なら nil)。
        public var f0: [Double?]
        /// 旋律のはっきりさ(倍音の重み付き和の最大値)。別の音源どうしで比べるのに使う。
        public var strength: [Float]
        public var hopSize: Int

        public init(f0: [Double?], strength: [Float], hopSize: Int) {
            self.f0 = f0
            self.strength = strength
            self.hopSize = hopSize
        }
    }

    /// 取り出せるパート(コード(伴奏) は常に残りになる)。
    public static let extractableParts: [StemKind] = [.drums, .bass, .vocals, .melody]

    public var parameters: Parameters

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// サンプルレートに合わせた FFT 長(約 93ms)。
    public static func fftSize(for sampleRate: Double) -> Int {
        let target = max(256.0, sampleRate * 0.0929)
        var size = 256
        while Double(size) * 1.414 < target { size *= 2 }
        return size
    }

    /// 左右がほぼ同じ(実質モノラル)か。
    func isEffectivelyMono(_ channels: [[Float]], frameCount: Int) -> Bool {
        guard channels.count == 2 else { return true }
        var mid = 0.0
        var side = 0.0
        for i in 0..<frameCount {
            let l = Double(channels[0][i])
            let r = Double(channels[1][i])
            mid += (l + r) * (l + r)
            side += (l - r) * (l - r)
        }
        return mid <= 0 || side < mid * parameters.monoSideRatio
    }

    /// - Parameters:
    ///   - channels: 再生と同じチャンネル(モノラルかステレオ)。長さは揃っていること。
    ///   - parts: 取り出すパート。含めなかったパートは無音になり、その分は コード(伴奏) に入る。
    ///   - progress: 0...1。
    public func separate(
        channels: [[Float]],
        sampleRate: Double,
        parts: Set<StemKind> = Set(SpectralStemSeparator.extractableParts),
        melodyOverride: [Double?]? = nil,
        progress: (Double) -> Void = { _ in }
    ) throws -> StemSet {
        let frameCount = channels.map(\.count).min() ?? 0
        let fftSize = Self.fftSize(for: sampleRate)
        let hop = fftSize / 4
        guard !channels.isEmpty, frameCount > 0, sampleRate > 0, let fft = RealFFT(size: fftSize) else {
            let empty = channels.map { _ in [Float](repeating: 0, count: frameCount) }
            var stems = [StemKind: [[Float]]]()
            for kind in StemKind.allCases { stems[kind] = empty }
            stems[.chords] = channels.map { Array($0.prefix(frameCount)) }
            return StemSet(method: .spectral, detail: "", sampleRate: sampleRate, frameCount: frameCount, stems: stems)
        }
        let bins = fft.binCount
        let frames = frameCount / hop + 1
        let window = Window.hann(fftSize)
        let binHz = sampleRate / Double(fftSize)

        var unavailable = [StemKind: String]()
        var useVocals = parts.contains(.vocals)
        if useVocals && isEffectivelyMono(channels, frameCount: frameCount) {
            useVocals = false
            unavailable[.vocals] = "モノラル(左右が同じ)の音源なので、近似分離ではボーカルを分けられません。"
        }
        let useDrums = parts.contains(.drums)
        let useBass = parts.contains(.bass)
        let useMelody = parts.contains(.melody)
        let extracted = Self.extractableParts.filter { kind in
            switch kind {
            case .drums: return useDrums
            case .bass: return useBass
            case .vocals: return useVocals
            case .melody: return useMelody
            case .chords: return false
            }
        }

        // 1. モノラルの振幅スペクトログラム。
        var magnitude = try Self.magnitudeSpectrogram(
            channels: channels, frameCount: frameCount, fft: fft, hop: hop, frames: frames, window: window
        ) { progress(0.2 * $0) }
        var frameBuffer = [Float](repeating: 0, count: fftSize)

        // 2. 持続音成分(時間方向のメディアン)。
        let harmonic = try Self.medianOverTime(magnitude, frames: frames, bins: bins, length: parameters.harmonicMedianLength) {
            progress(0.2 + 0.2 * $0)
        }
        // 打楽器成分(周波数方向のメディアン)。振幅の配列をそのまま置き換える。
        var percussive = magnitude
        magnitude = []
        try Self.medianOverFrequencyInPlace(&percussive, frames: frames, bins: bins, length: parameters.percussiveMedianLength)
        progress(0.45)

        // 3. 主旋律の音高。
        let melody: [Double?]
        if !useMelody {
            melody = [Double?](repeating: nil, count: frames)
        } else if let melodyOverride, melodyOverride.count == frames {
            melody = melodyOverride
        } else {
            melody = try trackMelody(
                harmonic: harmonic, frames: frames, bins: bins, binHz: binHz, frameRate: sampleRate / Double(hop)
            ).f0
        }
        progress(0.55)

        // 4. マスクをかけて逆変換する。
        let bassWeight = (0..<bins).map { k -> Float in
            guard useBass else { return 0 }
            let f = Double(k) * binHz
            if f <= parameters.bassFullBelow { return 1 }
            if f >= parameters.bassNoneAbove { return 0 }
            let x = (f - parameters.bassFullBelow) / (parameters.bassNoneAbove - parameters.bassFullBelow)
            return Float(0.5 + 0.5 * cos(Double.pi * x))
        }
        var outputs = [[[Float]]](
            repeating: channels.map { _ in [Float](repeating: 0, count: frameCount) },
            count: extracted.count
        )
        var drumMask = [Float](repeating: 0, count: bins)
        var bassMask = [Float](repeating: 0, count: bins)
        var vocalMask = [Float](repeating: 0, count: bins)
        var melodyMask = [Float](repeating: 0, count: bins)
        var melodyWeight = [Float](repeating: 0, count: bins)
        var spectraRe = [[Float]](repeating: [Float](repeating: 0, count: bins), count: channels.count)
        var spectraIm = [[Float]](repeating: [Float](repeating: 0, count: bins), count: channels.count)
        var maskedRe = [Float](repeating: 0, count: bins)
        var maskedIm = [Float](repeating: 0, count: bins)
        var timeSignal = [Float](repeating: 0, count: fftSize)
        let exponent = parameters.vocalCenterExponent

        for t in 0..<frames {
            if t % 32 == 0 {
                try Task.checkCancellation()
                progress(0.55 + 0.43 * Double(t) / Double(frames))
            }
            let start = t * hop - fftSize / 2
            for channelIndex in channels.indices {
                Self.fillFrame(&frameBuffer, from: channels[channelIndex], frameCount: frameCount, start: start, window: window)
                fft.forward(frameBuffer, real: &spectraRe[channelIndex], imag: &spectraIm[channelIndex])
            }
            if useMelody {
                Self.melodyWeights(&melodyWeight, f0: melody[t], binHz: binHz, maxHz: parameters.melodyMaxHarmonicHz)
            }
            let base = t * bins
            for k in 0..<bins {
                let h = harmonic[base + k]
                let p = percussive[base + k]
                let h2 = h * h
                let p2 = p * p
                let total = h2 + p2
                let drumShare: Float = useDrums && total > 1e-12 ? p2 / total : 0
                let tonal = 1 - drumShare
                let rest = tonal * (1 - bassWeight[k])
                var center: Float = 0
                if useVocals {
                    center = Self.centerWeight(
                        leftRe: spectraRe[0][k], leftIm: spectraIm[0][k],
                        rightRe: spectraRe[1][k], rightIm: spectraIm[1][k],
                        exponent: exponent
                    )
                }
                drumMask[k] = drumShare
                bassMask[k] = tonal * bassWeight[k]
                vocalMask[k] = rest * center
                melodyMask[k] = useMelody ? rest * (1 - center) * melodyWeight[k] : 0
            }
            for (stem, kind) in extracted.enumerated() {
                let mask: [Float]
                switch kind {
                case .drums: mask = drumMask
                case .bass: mask = bassMask
                case .vocals: mask = vocalMask
                default: mask = melodyMask
                }
                for channelIndex in channels.indices {
                    let sourceRe = spectraRe[channelIndex]
                    let sourceIm = spectraIm[channelIndex]
                    for k in 0..<bins {
                        maskedRe[k] = sourceRe[k] * mask[k]
                        maskedIm[k] = sourceIm[k] * mask[k]
                    }
                    fft.inverse(real: maskedRe, imag: maskedIm, output: &timeSignal)
                    let lower = max(0, -start)
                    let upper = min(fftSize, frameCount - start)
                    if lower < upper {
                        outputs[stem][channelIndex].withUnsafeMutableBufferPointer { output in
                            for i in lower..<upper {
                                output[start + i] += timeSignal[i] * window[i]
                            }
                        }
                    }
                }
            }
        }

        // 窓の二乗の重なりで割って振幅を戻す。
        let normalization = Self.windowSquareSum(window: window, hop: hop, frames: frames, frameCount: frameCount)
        for stem in 0..<extracted.count {
            for channelIndex in channels.indices {
                outputs[stem][channelIndex].withUnsafeMutableBufferPointer { output in
                    for i in 0..<frameCount {
                        let n = normalization[i]
                        output[i] = n > 1e-6 ? output[i] / n : 0
                    }
                }
            }
        }
        var stems = [StemKind: [[Float]]]()
        let silent = channels.map { _ in [Float](repeating: 0, count: frameCount) }
        for kind in StemKind.allCases where kind != .chords {
            stems[kind] = silent
        }
        for (index, kind) in extracted.enumerated() {
            stems[kind] = outputs[index]
        }
        // コード(伴奏)は残り。全パートの和が元の音と一致する。
        stems[.chords] = channels.enumerated().map { channelIndex, channel in
            var rest = Array(channel.prefix(frameCount))
            for stem in 0..<extracted.count {
                let part = outputs[stem][channelIndex]
                for i in 0..<frameCount { rest[i] -= part[i] }
            }
            return rest
        }
        progress(1)
        var steps = ["HPSS", "帯域"]
        if useVocals { steps.append("中央定位") }
        if useMelody { steps.append("音高追跡") }
        return StemSet(
            method: .spectral,
            detail: steps.joined(separator: " + ") + "(FFT \(fftSize))",
            sampleRate: sampleRate,
            frameCount: frameCount,
            stems: stems,
            unavailable: unavailable
        )
    }

    /// 左右のスペクトルがどれだけ同じ(中央に定位している)か。0...1。
    static func centerWeight(leftRe: Float, leftIm: Float, rightRe: Float, rightIm: Float, exponent: Float) -> Float {
        let power = leftRe * leftRe + leftIm * leftIm + rightRe * rightRe + rightIm * rightIm
        guard power > 1e-20 else { return 0 }
        // 2·Re(L·conj(R)) / (|L|² + |R|²)。左右が同じなら 1、片側だけや逆相なら 0 以下。
        let correlation = 2 * (leftRe * rightRe + leftIm * rightIm) / power
        let clamped = max(0, min(1, correlation))
        return pow(clamped, exponent)
    }

    /// モノラルにした信号の振幅スペクトログラム(`frames × bins`、行ごと)。
    static func magnitudeSpectrogram(
        channels: [[Float]],
        frameCount: Int,
        fft: RealFFT,
        hop: Int,
        frames: Int,
        window: [Float],
        progress: (Double) -> Void
    ) throws -> [Float] {
        let fftSize = fft.size
        let bins = fft.binCount
        var mono = [Float](repeating: 0, count: frameCount)
        let channelScale = 1 / Float(channels.count)
        for channel in channels {
            for i in 0..<frameCount { mono[i] += channel[i] * channelScale }
        }
        var magnitude = [Float](repeating: 0, count: frames * bins)
        var frameBuffer = [Float](repeating: 0, count: fftSize)
        var re = [Float](repeating: 0, count: bins)
        var im = [Float](repeating: 0, count: bins)
        for t in 0..<frames {
            if t % 64 == 0 {
                try Task.checkCancellation()
                progress(Double(t) / Double(frames))
            }
            fillFrame(&frameBuffer, from: mono, frameCount: frameCount, start: t * hop - fftSize / 2, window: window)
            fft.forward(frameBuffer, real: &re, imag: &im)
            let base = t * bins
            for k in 0..<bins {
                magnitude[base + k] = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            }
        }
        return magnitude
    }

    /// 音源の主旋律の音高を推定する(分離はしない)。
    public func melodyTrack(channels: [[Float]], sampleRate: Double) throws -> MelodyTrack {
        let frameCount = channels.map(\.count).min() ?? 0
        let fftSize = Self.fftSize(for: sampleRate)
        let hop = fftSize / 4
        guard !channels.isEmpty, frameCount > 0, sampleRate > 0, let fft = RealFFT(size: fftSize) else {
            return MelodyTrack(f0: [], strength: [], hopSize: hop)
        }
        let frames = frameCount / hop + 1
        let magnitude = try Self.magnitudeSpectrogram(
            channels: channels, frameCount: frameCount, fft: fft, hop: hop, frames: frames, window: Window.hann(fftSize)
        ) { _ in }
        let harmonic = try Self.medianOverTime(
            magnitude, frames: frames, bins: fft.binCount, length: parameters.harmonicMedianLength
        ) { _ in }
        var track = try trackMelody(
            harmonic: harmonic, frames: frames, bins: fft.binCount,
            binHz: sampleRate / Double(fftSize), frameRate: sampleRate / Double(hop)
        )
        track.hopSize = hop
        return track
    }

    /// 複数の楽器の音源(機械学習モデルの other / guitar / piano など)から、メロディを取り出す。
    ///
    /// 各音源の主旋律を推定し、フレームごとに旋律が最もはっきりしている音源だけからメロディを取り出す。
    /// 同時に鳴っている別の楽器(伴奏)の音がメロディに混ざりにくくなる。取り出さなかった分は伴奏になる。
    /// 戻り値の和は、入力の音源の和と一致する。
    public func splitMelody(
        from sources: [[[Float]]],
        sampleRate: Double,
        progress: (Double) -> Void = { _ in }
    ) throws -> (melody: [[Float]], rest: [[Float]], leadShare: [Double]) {
        guard let first = sources.first else { return ([], [], []) }
        let channelCount = first.count
        let frameCount = sources.flatMap { $0 }.map(\.count).min() ?? 0
        var tracks = [MelodyTrack]()
        for (index, source) in sources.enumerated() {
            tracks.append(try melodyTrack(channels: source, sampleRate: sampleRate))
            progress(0.4 * Double(index + 1) / Double(sources.count))
        }
        let frames = tracks.map(\.f0.count).min() ?? 0
        // フレームごとに、旋律がいちばんはっきりした音源を選ぶ。
        var chosen = [[Double?]](repeating: [Double?](repeating: nil, count: frames), count: sources.count)
        var counts = [Int](repeating: 0, count: sources.count)
        for t in 0..<frames {
            var best: Int?
            for index in sources.indices where tracks[index].f0[t] != nil {
                if best == nil || tracks[index].strength[t] > tracks[best!].strength[t] {
                    best = index
                }
            }
            if let best {
                chosen[best][t] = tracks[best].f0[t]
                counts[best] += 1
            }
        }
        var melody = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channelCount)
        var rest = melody
        for (index, source) in sources.enumerated() {
            let result = try separate(
                channels: source,
                sampleRate: sampleRate,
                parts: [.melody],
                melodyOverride: chosen[index]
            ) { value in
                progress(0.4 + 0.6 * (Double(index) + value) / Double(sources.count))
            }
            for channel in 0..<channelCount {
                let m = result.channels(for: .melody)[channel]
                let r = result.channels(for: .chords)[channel]
                for i in 0..<frameCount {
                    melody[channel][i] += m[i]
                    rest[channel][i] += r[i]
                }
            }
        }
        let voiced = max(1, counts.reduce(0, +))
        return (melody, rest, counts.map { Double($0) / Double(voiced) })
    }

    // MARK: - Melody

    /// フレームごとの主旋律の基本周波数(無声なら nil)。
    func trackMelody(harmonic: [Float], frames: Int, bins: Int, binHz: Double, frameRate: Double) throws -> MelodyTrack {
        let p = parameters
        let steps = max(1, p.stepsPerSemitone)
        let lowMidi = 69 + 12 * log2(p.melodyLowestHz / 440)
        let highMidi = 69 + 12 * log2(p.melodyHighestHz / 440)
        let candidateCount = max(1, Int(((highMidi - lowMidi) * Double(steps)).rounded(.down)) + 1)
        let frequencies = (0..<candidateCount).map { 440 * pow(2, (lowMidi + Double($0) / Double(steps) - 69) / 12) }
        let harmonicWeights = (0..<p.salienceHarmonics).map { Float(pow(0.85, Double($0))) }

        // 候補ごとに、各倍音を探すビンの範囲を前もって求める。
        struct Probe { var lower: Int; var upper: Int; var weight: Float }
        let probes: [[Probe]] = frequencies.map { f0 in
            (0..<p.salienceHarmonics).compactMap { index -> Probe? in
                let f = f0 * Double(index + 1)
                guard f < 5_000, f / binHz < Double(bins - 1) else { return nil }
                let center = f / binHz
                let spread = max(1.0, center * 0.03)
                return Probe(
                    lower: max(0, Int((center - spread).rounded(.down))),
                    upper: min(bins - 1, Int((center + spread).rounded(.up))),
                    weight: harmonicWeights[index]
                )
            }
        }
        let levelLower = max(1, Int(p.melodyLowestHz / binHz))
        let levelUpper = min(bins - 1, Int(5_000 / binHz))

        var salience = [Float](repeating: 0, count: frames * candidateCount)
        var levels = [Float](repeating: 0, count: frames)
        var peaky = [Bool](repeating: false, count: frames)
        var frameMaxima = [Float](repeating: 0, count: frames)
        var compressed = [Float](repeating: 0, count: bins)
        for t in 0..<frames {
            if t % 256 == 0 { try Task.checkCancellation() }
            let base = t * bins
            var level: Float = 0
            for k in 0..<bins {
                compressed[k] = harmonic[base + k].squareRoot()
            }
            if levelLower <= levelUpper {
                for k in levelLower...levelUpper { level += harmonic[base + k] }
            }
            levels[t] = level
            var maxValue: Float = 0
            var sum: Float = 0
            for c in 0..<candidateCount {
                var value: Float = 0
                var fundamental: Float = 0
                var strongest: Float = 0
                for (index, probe) in probes[c].enumerated() {
                    var peak: Float = 0
                    for k in probe.lower...probe.upper where compressed[k] > peak { peak = compressed[k] }
                    value += probe.weight * peak
                    if index == 0 { fundamental = peak }
                    strongest = max(strongest, peak)
                }
                // 基本音が弱い候補を下げ、1 オクターブ下などの誤検出を防ぐ。
                if strongest > 0 {
                    value *= (fundamental / strongest).squareRoot()
                }
                salience[t * candidateCount + c] = value
                maxValue = max(maxValue, value)
                sum += value
            }
            let mean = sum / Float(candidateCount)
            peaky[t] = mean > 0 && maxValue / mean >= p.voicingPeakRatio
            frameMaxima[t] = maxValue
        }

        // 有声の判定: 十分な大きさがあり、倍音の和にはっきりした山があるフレーム。
        let sortedLevels = levels.sorted()
        let reference = sortedLevels.isEmpty ? 0 : sortedLevels[min(sortedLevels.count - 1, Int(Double(sortedLevels.count) * 0.95))]
        let sortedMaxima = frameMaxima.sorted()
        let salienceReference = sortedMaxima.isEmpty ? 0 : sortedMaxima[min(sortedMaxima.count - 1, Int(Double(sortedMaxima.count) * 0.95))]
        var voiced = (0..<frames).map {
            reference > 0 && levels[$0] > reference * p.voicingLevelRatio
                && peaky[$0]
                && frameMaxima[$0] >= salienceReference * p.voicingSalienceRatio
        }
        Self.removeShortRuns(&voiced, minimumLength: max(1, Int((p.minimumVoicedDuration * frameRate).rounded())))

        // 有声区間ごとに、跳躍を抑えた最適な音高の列を動的計画法で求める。
        var result = [Double?](repeating: nil, count: frames)
        var t = 0
        while t < frames {
            guard voiced[t] else { t += 1; continue }
            var end = t
            while end < frames && voiced[end] { end += 1 }
            let path = viterbi(salience: salience, candidates: candidateCount, from: t, to: end)
            for (offset, candidate) in path.enumerated() {
                result[t + offset] = frequencies[candidate]
            }
            t = end
        }
        return MelodyTrack(f0: result, strength: frameMaxima, hopSize: 0)
    }

    private func viterbi(salience: [Float], candidates: Int, from start: Int, to end: Int) -> [Int] {
        let length = end - start
        guard length > 0 else { return [] }
        let penalty = parameters.jumpPenalty
        let highBias = parameters.highPitchBias
        var back = [Int32](repeating: 0, count: length * candidates)
        func emission(_ t: Int) -> [Float] {
            let base = t * candidates
            var maxValue: Float = 0
            for c in 0..<candidates { maxValue = max(maxValue, salience[base + c]) }
            let scale = maxValue > 0 ? 1 / maxValue : 0
            let bias = candidates > 1 ? highBias / Float(candidates - 1) : 0
            return (0..<candidates).map { log(salience[base + $0] * scale + 1e-3) + bias * Float($0) }
        }
        var score = emission(start)
        var next = [Float](repeating: 0, count: candidates)
        for offset in stride(from: 1, to: length, by: 1) {
            let e = emission(start + offset)
            for c in 0..<candidates {
                var best = -Float.infinity
                var bestIndex = 0
                for previous in 0..<candidates {
                    let value = score[previous] - penalty * Float(abs(c - previous))
                    if value > best {
                        best = value
                        bestIndex = previous
                    }
                }
                next[c] = best + e[c]
                back[offset * candidates + c] = Int32(bestIndex)
            }
            swap(&score, &next)
        }
        var path = [Int](repeating: 0, count: length)
        var current = score.indices.max { score[$0] < score[$1] } ?? 0
        for offset in stride(from: length - 1, through: 0, by: -1) {
            path[offset] = current
            if offset > 0 { current = Int(back[offset * candidates + current]) }
        }
        return path
    }

    static func removeShortRuns(_ flags: inout [Bool], minimumLength: Int) {
        var t = 0
        while t < flags.count {
            guard flags[t] else { t += 1; continue }
            var end = t
            while end < flags.count && flags[end] { end += 1 }
            if end - t < minimumLength {
                for i in t..<end { flags[i] = false }
            }
            t = end
        }
    }

    /// 基本周波数 `f0` の倍音の位置を 1 とする重み(ガウス形)。
    static func melodyWeights(_ weights: inout [Float], f0: Double?, binHz: Double, maxHz: Double) {
        for k in weights.indices { weights[k] = 0 }
        guard let f0, f0 > 0 else { return }
        var harmonic = 1
        while true {
            let center = f0 * Double(harmonic)
            if center > maxHz || center / binHz >= Double(weights.count - 1) { break }
            let sigma = max(binHz * 0.8, center * 0.012)
            let lower = max(0, Int(((center - 3 * sigma) / binHz).rounded(.down)))
            let upper = min(weights.count - 1, Int(((center + 3 * sigma) / binHz).rounded(.up)))
            if lower <= upper {
                for k in lower...upper {
                    let d = (Double(k) * binHz - center) / sigma
                    let w = Float(exp(-0.5 * d * d))
                    if w > weights[k] { weights[k] = w }
                }
            }
            harmonic += 1
        }
    }

    // MARK: - Helpers

    static func fillFrame(_ buffer: inout [Float], from samples: [Float], frameCount: Int, start: Int, window: [Float]) {
        let size = buffer.count
        if start >= 0 && start + size <= frameCount {
            for i in 0..<size { buffer[i] = samples[start + i] * window[i] }
        } else {
            for i in 0..<size {
                let index = start + i
                buffer[i] = (index >= 0 && index < frameCount) ? samples[index] * window[i] : 0
            }
        }
    }

    static func windowSquareSum(window: [Float], hop: Int, frames: Int, frameCount: Int) -> [Float] {
        let size = window.count
        var sum = [Float](repeating: 0, count: frameCount)
        for t in 0..<frames {
            let start = t * hop - size / 2
            let lower = max(0, -start)
            let upper = min(size, frameCount - start)
            guard lower < upper else { continue }
            for i in lower..<upper {
                sum[start + i] += window[i] * window[i]
            }
        }
        return sum
    }

    /// 時間方向のメディアンフィルタ(端は範囲を狭める)。
    static func medianOverTime(
        _ values: [Float],
        frames: Int,
        bins: Int,
        length: Int,
        progress: (Double) -> Void
    ) throws -> [Float] {
        var result = [Float](repeating: 0, count: values.count)
        let half = max(0, length / 2)
        var column = [Float](repeating: 0, count: frames)
        var window = [Float](repeating: 0, count: 2 * half + 1)
        for k in 0..<bins {
            if k % 64 == 0 {
                try Task.checkCancellation()
                progress(Double(k) / Double(bins))
            }
            for t in 0..<frames { column[t] = values[t * bins + k] }
            for t in 0..<frames {
                let lower = max(0, t - half)
                let upper = min(frames - 1, t + half)
                let count = upper - lower + 1
                for i in 0..<count { window[i] = column[lower + i] }
                result[t * bins + k] = median(&window, count: count)
            }
        }
        return result
    }

    /// 周波数方向のメディアンフィルタ(フレームごと、その場で置き換える)。
    static func medianOverFrequencyInPlace(_ values: inout [Float], frames: Int, bins: Int, length: Int) throws {
        let half = max(0, length / 2)
        var row = [Float](repeating: 0, count: bins)
        var window = [Float](repeating: 0, count: 2 * half + 1)
        for t in 0..<frames {
            if t % 256 == 0 { try Task.checkCancellation() }
            let base = t * bins
            for k in 0..<bins { row[k] = values[base + k] }
            for k in 0..<bins {
                let lower = max(0, k - half)
                let upper = min(bins - 1, k + half)
                let count = upper - lower + 1
                for i in 0..<count { window[i] = row[lower + i] }
                values[base + k] = median(&window, count: count)
            }
        }
    }

    /// 先頭 `count` 個の中央値(挿入ソート。並びは変わる)。
    static func median(_ values: inout [Float], count: Int) -> Float {
        guard count > 0 else { return 0 }
        for i in 1..<max(1, count) {
            let value = values[i]
            var j = i - 1
            while j >= 0 && values[j] > value {
                values[j + 1] = values[j]
                j -= 1
            }
            values[j + 1] = value
        }
        if count % 2 == 1 { return values[count / 2] }
        return (values[count / 2 - 1] + values[count / 2]) / 2
    }
}
