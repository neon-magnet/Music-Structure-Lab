import AVFoundation
import Foundation
import MSLCore
import UniformTypeIdentifiers

public enum AudioLoadError: LocalizedError, Equatable {
    case cannotOpen(fileName: String, reason: String)
    case unsupportedFormat(fileName: String)
    case emptyFile(fileName: String)
    case readFailed(fileName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(fileName, reason):
            return "「\(fileName)」を開けませんでした。(\(reason))"
        case let .unsupportedFormat(fileName):
            return "「\(fileName)」は対応していない形式です。"
        case let .emptyFile(fileName):
            return "「\(fileName)」には音声データがありません。"
        case let .readFailed(fileName, reason):
            return "「\(fileName)」の読み込み中にエラーが発生しました。(\(reason))"
        }
    }
}

/// AVFoundation で音源ファイルをデコードし、`DecodedAudio` を作る。
///
/// WAV / AIFF / CAF / MP3 / AAC(M4A) / ALAC / FLAC など、Core Audio が読める形式に対応する。
/// 読み込みは同期処理なので、UI からはバックグラウンドのタスクで呼ぶこと。
/// 呼び出し元のタスクがキャンセルされると `CancellationError` を投げて中断する。
public struct AudioFileLoader: Sendable {
    /// ファイル選択ダイアログやドラッグ&ドロップで受け付ける種類。
    public static let supportedContentTypes: [UTType] = [.audio]

    public var chunkFrameCount: AVAudioFrameCount
    public var baseBlockSize: Int

    public init(chunkFrameCount: AVAudioFrameCount = 1 << 16, baseBlockSize: Int = 256) {
        self.chunkFrameCount = chunkFrameCount
        self.baseBlockSize = baseBlockSize
    }

    /// - Parameter progress: 0...1 の進捗。読み込みスレッドから呼ばれる。
    public func load(from url: URL, progress: @Sendable (Double) -> Void = { _ in }) throws -> DecodedAudio {
        let fileName = url.lastPathComponent
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioLoadError.cannotOpen(fileName: fileName, reason: error.localizedDescription)
        }

        // processingFormat は常に 32bit float・非インターリーブ。
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let sampleRate = format.sampleRate
        guard channelCount > 0, sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw AudioLoadError.unsupportedFormat(fileName: fileName)
        }
        let expectedFrames = Int(file.length)
        guard expectedFrames > 0 else {
            throw AudioLoadError.emptyFile(fileName: fileName)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) else {
            throw AudioLoadError.unsupportedFormat(fileName: fileName)
        }

        var channels = [[Float]](repeating: [], count: channelCount)
        var builders = [WaveformBuilder](repeating: WaveformBuilder(baseBlockSize: baseBlockSize), count: channelCount)
        var mono = [Float]()
        var monoBuilder = WaveformBuilder(baseBlockSize: baseBlockSize)
        for c in 0..<channelCount {
            channels[c].reserveCapacity(expectedFrames)
            builders[c].reserveCapacity(forSampleCount: expectedFrames)
        }
        mono.reserveCapacity(expectedFrames)
        monoBuilder.reserveCapacity(forSampleCount: expectedFrames)

        var monoChunk = [Float](repeating: 0, count: Int(chunkFrameCount))
        let scale = 1 / Float(channelCount)
        var framesRead = 0
        progress(0)

        while file.framePosition < file.length {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer, frameCount: chunkFrameCount)
            } catch {
                throw AudioLoadError.readFailed(fileName: fileName, reason: error.localizedDescription)
            }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let data = buffer.floatChannelData else {
                throw AudioLoadError.unsupportedFormat(fileName: fileName)
            }

            for i in 0..<count { monoChunk[i] = 0 }
            for c in 0..<channelCount {
                let samples = UnsafeBufferPointer(start: data[c], count: count)
                channels[c].append(contentsOf: samples)
                builders[c].append(contentsOf: samples)
                for i in 0..<count {
                    monoChunk[i] += samples[i] * scale
                }
            }
            let monoSlice = monoChunk[0..<count]
            mono.append(contentsOf: monoSlice)
            monoBuilder.append(contentsOf: monoSlice)

            framesRead += count
            progress(Swift.min(1, Double(framesRead) / Double(expectedFrames)))
        }

        guard framesRead > 0 else {
            throw AudioLoadError.emptyFile(fileName: fileName)
        }

        let info = AudioFileInfo(
            url: url,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: framesRead,
            sourceFormatDescription: Self.describe(file.fileFormat)
        )
        progress(1)
        return DecodedAudio(
            info: info,
            channels: channels,
            mono: mono,
            channelOverviews: builders.map { $0.build() },
            monoOverview: monoBuilder.build()
        )
    }

    /// 元ファイルの形式を人が読める文字列にする。
    static func describe(_ format: AVAudioFormat) -> String {
        let asbd = format.streamDescription.pointee
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            return "Linear PCM \(asbd.mBitsPerChannel)-bit\(isFloat ? " float" : "")"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD:
            return "AAC"
        case kAudioFormatMPEGLayer3:
            return "MP3"
        case kAudioFormatAppleLossless:
            return "Apple Lossless"
        case kAudioFormatFLAC:
            return "FLAC"
        default:
            return fourCharacterCode(asbd.mFormatID)
        }
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(format: "0x%08X", value)
    }
}
