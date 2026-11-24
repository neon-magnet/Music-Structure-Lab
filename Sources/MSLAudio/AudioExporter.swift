import AVFoundation
import Foundation
import MSLCore

public enum AudioExportError: LocalizedError {
    case invalidRange
    case writeFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "書き出す範囲が正しくありません。"
        case let .writeFailed(reason): return "音声ファイルを書き出せませんでした。(\(reason))"
        }
    }
}

/// デコード済みの音源の一部を WAV (24bit PCM) で書き出す。セクションの切り出しに使う。
public enum AudioExporter {
    public static func writeWAV(_ audio: DecodedAudio, frames: Range<Int>, to url: URL) throws {
        try writeWAV(channels: audio.channels, sampleRate: audio.info.sampleRate, frames: frames, to: url)
    }

    /// チャンネルごとのサンプル列(分離したパートなど)を書き出す。
    public static func writeWAV(channels: [[Float]], sampleRate: Double, frames: Range<Int>, to url: URL) throws {
        let frameCount = channels.map(\.count).min() ?? 0
        let lower = max(0, frames.lowerBound)
        let upper = min(frameCount, frames.upperBound)
        guard lower < upper, !channels.isEmpty else { throw AudioExportError.invalidRange }
        let channelCount = channels.count
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 1 << 16
            var position = lower
            while position < upper {
                let count = min(chunk, upper - position)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                      let data = buffer.floatChannelData
                else { throw AudioExportError.writeFailed(reason: "buffer") }
                for channel in 0..<channelCount {
                    channels[channel].withUnsafeBufferPointer { source in
                        guard let base = source.baseAddress else { return }
                        data[channel].update(from: base + position, count: count)
                    }
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                position += count
            }
        } catch let error as AudioExportError {
            throw error
        } catch {
            throw AudioExportError.writeFailed(reason: error.localizedDescription)
        }
    }
}
