import Foundation

/// 読み込んだ音源ファイルのメタデータ。
public struct AudioFileInfo: Equatable, Sendable {
    public let url: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int
    /// 元ファイルの形式の説明(例: "Linear PCM 24-bit", "MPEG-4 AAC")。
    public let sourceFormatDescription: String

    public init(url: URL, sampleRate: Double, channelCount: Int, frameCount: Int, sourceFormatDescription: String) {
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.sourceFormatDescription = sourceFormatDescription
    }

    public var fileName: String { url.lastPathComponent }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }
}

/// デコード済みの音源。サンプルは 32bit float、チャンネルごとに分離して保持する。
///
/// 今後の解析(テンポ・キー・構造)はこの型を入力とする想定。
public struct DecodedAudio: Sendable {
    public let info: AudioFileInfo
    /// `channels[c][frame]`。
    public let channels: [[Float]]
    /// 全チャンネルの平均。解析の入力と「ミックス表示」に使う。
    public let mono: [Float]
    /// `channels` と同じ順の波形概要。
    public let channelOverviews: [WaveformOverview]
    public let monoOverview: WaveformOverview

    public init(
        info: AudioFileInfo,
        channels: [[Float]],
        mono: [Float],
        channelOverviews: [WaveformOverview],
        monoOverview: WaveformOverview
    ) {
        self.info = info
        self.channels = channels
        self.mono = mono
        self.channelOverviews = channelOverviews
        self.monoOverview = monoOverview
    }

    /// 既にメモリ上にあるサンプルから組み立てる(テストや、今後の生成音源向け)。
    public init(info: AudioFileInfo, channels: [[Float]], baseBlockSize: Int = 256) {
        let frameCount = channels.map(\.count).min() ?? 0
        var mono = [Float](repeating: 0, count: frameCount)
        if !channels.isEmpty {
            let scale = 1 / Float(channels.count)
            for channel in channels {
                for i in 0..<frameCount {
                    mono[i] += channel[i] * scale
                }
            }
        }
        let overviews = channels.map { samples -> WaveformOverview in
            var builder = WaveformBuilder(baseBlockSize: baseBlockSize)
            builder.append(contentsOf: samples)
            return builder.build()
        }
        var monoBuilder = WaveformBuilder(baseBlockSize: baseBlockSize)
        monoBuilder.append(contentsOf: mono)
        self.init(
            info: info,
            channels: channels,
            mono: mono,
            channelOverviews: overviews,
            monoOverview: monoBuilder.build()
        )
    }
}
