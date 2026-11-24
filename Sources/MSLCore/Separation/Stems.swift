import Foundation

/// 分離するパート。
public enum StemKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case drums
    case bass
    case chords
    case vocals
    case melody

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .drums: return "ドラム"
        case .bass: return "ベース"
        case .chords: return "コード(伴奏)"
        case .vocals: return "ボーカル"
        case .melody: return "メロディ"
        }
    }

    public var systemImage: String {
        switch self {
        case .drums: return "circle.grid.cross"
        case .bass: return "guitars"
        case .chords: return "pianokeys"
        case .vocals: return "music.mic"
        case .melody: return "music.note"
        }
    }
}

/// 分離に使った方法。画面と書き出しに表示し、近似であることを隠さない。
public enum SeparationMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 信号処理による近似(モデル不要)。
    case spectral
    /// 利用者が用意した Core ML モデル(Demucs 系)。
    case mlModel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spectral: return "近似分離(信号処理)"
        case .mlModel: return "機械学習モデル"
        }
    }

    public var explanation: String {
        switch self {
        case .spectral:
            return "打楽器成分と持続音成分の分離・帯域・中央定位(ボーカル)・メロディの音高追跡で振り分ける簡易的な方法です。パート間の音の漏れが大きく、実際の楽器ごとの分離ではありません。ボーカルには中央に置かれた楽器も入り、モノラル音源ではボーカルを分けられません。"
        case .mlModel:
            return "読み込んだ Core ML モデルで分離します。モデルの「ボーカル」をそのまま ボーカル に使います。メロディ は、モデルの「その他」から音高追跡で近似的に取り出し、残りを コード(伴奏) にします。"
        }
    }
}

/// 分離したパートの音声。各パートは元の音源と同じ長さ・サンプルレート・再生チャンネル数を持つ。
public struct StemSet: Sendable {
    public let method: SeparationMethod
    /// モデル名など、方法の補足。
    public let detail: String
    public let sampleRate: Double
    public let frameCount: Int
    /// `stems[kind][channel][frame]`。
    public let stems: [StemKind: [[Float]]]
    /// パートごとの波形概要(モノラル)。
    public let overviews: [StemKind: WaveformOverview]
    /// 分けられなかったパートと、その理由(そのパートは無音)。
    public let unavailable: [StemKind: String]

    public init(
        method: SeparationMethod,
        detail: String,
        sampleRate: Double,
        frameCount: Int,
        stems: [StemKind: [[Float]]],
        unavailable: [StemKind: String] = [:]
    ) {
        self.method = method
        self.unavailable = unavailable
        self.detail = detail
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.stems = stems
        var overviews = [StemKind: WaveformOverview]()
        for (kind, channels) in stems {
            var builder = WaveformBuilder()
            builder.append(contentsOf: StemSet.mono(of: channels, frameCount: frameCount))
            overviews[kind] = builder.build()
        }
        self.overviews = overviews
    }

    public func channels(for kind: StemKind) -> [[Float]] {
        stems[kind] ?? []
    }

    static func mono(of channels: [[Float]], frameCount: Int) -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channels.count)
        for channel in channels {
            for i in 0..<min(frameCount, channel.count) {
                mono[i] += channel[i] * scale
            }
        }
        return mono
    }
}

/// パートごとの音量・ミュート・ソロ。
public struct StemMix: Equatable, Codable, Sendable {
    public struct Channel: Equatable, Codable, Sendable {
        /// 0...1。
        public var volume: Float = 1
        public var isMuted = false
        public var isSolo = false

        public init(volume: Float = 1, isMuted: Bool = false, isSolo: Bool = false) {
            self.volume = volume
            self.isMuted = isMuted
            self.isSolo = isSolo
        }
    }

    public var channels: [StemKind: Channel]

    public init() {
        channels = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Channel()) })
    }

    public subscript(kind: StemKind) -> Channel {
        get { channels[kind] ?? Channel() }
        set { channels[kind] = newValue }
    }

    public var hasSolo: Bool {
        channels.values.contains { $0.isSolo }
    }

    /// 実際に再生する音量。ソロがあればソロのパートだけ鳴らす。ミュートはソロより優先する。
    public func gain(for kind: StemKind) -> Float {
        let channel = self[kind]
        if channel.isMuted { return 0 }
        if hasSolo && !channel.isSolo { return 0 }
        return max(0, min(1, channel.volume))
    }

    /// `kind` だけを鳴らす(他のソロを外す)。もう一度呼ぶと解除する。
    public mutating func toggleExclusiveSolo(_ kind: StemKind) {
        let wasOnlySolo = self[kind].isSolo && StemKind.allCases.allSatisfy { $0 == kind || !self[$0].isSolo }
        for other in StemKind.allCases {
            self[other].isSolo = false
        }
        if !wasOnlySolo {
            self[kind].isSolo = true
        }
    }
}
