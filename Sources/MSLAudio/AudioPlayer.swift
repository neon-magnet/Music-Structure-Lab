import AVFoundation
import Foundation
import MSLCore

public enum AudioPlaybackError: LocalizedError {
    case engineStartFailed(reason: String)
    case bufferCreationFailed

    public var errorDescription: String? {
        switch self {
        case let .engineStartFailed(reason):
            return "再生を開始できませんでした。(\(reason))"
        case .bufferCreationFailed:
            return "再生用のバッファを用意できませんでした。"
        }
    }
}

/// クリック音を鳴らす位置。
public struct ClickMark: Equatable, Sendable {
    public var frame: Int
    /// 小節頭など、強く鳴らす位置か。
    public var accent: Bool

    public init(frame: Int, accent: Bool) {
        self.frame = frame
        self.accent = accent
    }
}

/// デコード済みの音源を AVAudioEngine で再生する。
///
/// 再生開始・シークのたびに、指定位置から末尾までのサンプルを再生用バッファへコピーして
/// AVAudioPlayerNode に渡す。音源全体の複製を常に持たずに済み、位置はサンプル単位で正確になる。
/// 3 チャンネル以上の音源はモノラルミックスを再生する。
///
/// メインスレッドから使うこと。
@MainActor
public final class AudioPlayer {
    /// 末尾まで再生し終えた時に呼ばれる。
    public var onFinished: (@MainActor () -> Void)?
    /// 出力デバイスの変更などで再生が止まった時に呼ばれる。引数は停止位置。
    public var onInterrupted: (@MainActor (Int) -> Void)?

    public private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var audio: DecodedAudio?
    private var format: AVAudioFormat?
    private var segmentStart = 0
    private var segmentLength = 0
    private var isLooping = false
    private var pausedFrame = 0
    /// 古いバッファの完了通知を無視するための番号。
    private var generation = 0

    public init() {
        engine.attach(node)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    public var totalFrames: Int { audio?.info.frameCount ?? 0 }

    /// 現在の再生位置(フレーム)。停止中は最後に止めた位置。
    public var currentFrame: Int {
        guard isPlaying,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return pausedFrame }
        var elapsed = Swift.max(0, Int(playerTime.sampleTime))
        if isLooping, segmentLength > 0 {
            elapsed %= segmentLength
        }
        return Swift.min(totalFrames, segmentStart + elapsed)
    }

    /// 再生する音源を差し替える。再生中なら止める。
    public func load(_ audio: DecodedAudio) {
        stop()
        self.audio = audio
        pausedFrame = 0
        let format = Self.playbackFormat(for: audio)
        self.format = format
        engine.disconnectNodeOutput(node)
        if let format {
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
        }
    }

    public func unload() {
        stop()
        audio = nil
        format = nil
        pausedFrame = 0
        engine.disconnectNodeOutput(node)
        engine.stop()
    }

    /// `frame` から再生する。再生中に呼ぶとその位置へ移動する。
    /// - Parameters:
    ///   - endFrame: ここで止める(nil なら末尾まで)。
    ///   - loop: `frame..<endFrame` を繰り返す。
    ///   - clicks: クリック音を重ねる位置。
    public func play(from frame: Int, until endFrame: Int? = nil, loop: Bool = false, clicks: [ClickMark] = []) throws {
        guard let audio, let format else { return }
        let start = Swift.min(Swift.max(0, frame), audio.info.frameCount)
        let end = Swift.min(audio.info.frameCount, endFrame ?? audio.info.frameCount)
        guard start < end else {
            pausedFrame = start
            return
        }
        guard let buffer = Self.makeBuffer(from: audio, format: format, startFrame: start, endFrame: end, clicks: clicks) else {
            throw AudioPlaybackError.bufferCreationFailed
        }

        generation += 1
        let current = generation
        node.stop()

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                isPlaying = false
                throw AudioPlaybackError.engineStartFailed(reason: error.localizedDescription)
            }
        }

        node.scheduleBuffer(buffer, at: nil, options: loop ? [.loops] : [], completionCallbackType: .dataPlayedBack) { [self] _ in
            Task { @MainActor in
                self.segmentFinished(generation: current)
            }
        }
        segmentStart = start
        segmentLength = end - start
        isLooping = loop
        pausedFrame = start
        node.play()
        isPlaying = true
    }

    /// 一時停止して、その位置を返す。
    @discardableResult
    public func pause() -> Int {
        guard isPlaying else { return pausedFrame }
        let frame = currentFrame
        stop()
        pausedFrame = frame
        return frame
    }

    private func stop() {
        generation += 1
        node.stop()
        isPlaying = false
    }

    private func segmentFinished(generation finished: Int) {
        guard finished == generation, isPlaying else { return }
        stop()
        pausedFrame = segmentStart + segmentLength
        onFinished?()
    }

    private func handleConfigurationChange() {
        // 出力デバイスが変わるとエンジンは止まる。接続を張り直し、再生していたら止まった位置を知らせる。
        let wasPlaying = isPlaying
        let frame = currentFrame
        stop()
        pausedFrame = frame
        if let format {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
        }
        if wasPlaying {
            onInterrupted?(frame)
        }
    }

    // MARK: - Buffer

    /// 再生に使うチャンネル数。モノラル・ステレオはそのまま、それ以上はモノラルミックス。
    nonisolated static func playbackChannelCount(for audio: DecodedAudio) -> Int {
        audio.channels.count <= 2 ? audio.channels.count : 1
    }

    nonisolated static func playbackFormat(for audio: DecodedAudio) -> AVAudioFormat? {
        let channels = playbackChannelCount(for: audio)
        guard channels > 0, audio.info.sampleRate > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: audio.info.sampleRate, channels: AVAudioChannelCount(channels))
    }

    /// `startFrame..<endFrame`(既定は末尾まで)のサンプルを、`format`(非インターリーブ float)のバッファにコピーする。
    /// `clicks` の位置にはクリック音を足す。
    nonisolated static func makeBuffer(
        from audio: DecodedAudio,
        format: AVAudioFormat,
        startFrame: Int,
        endFrame: Int? = nil,
        clicks: [ClickMark] = []
    ) -> AVAudioPCMBuffer? {
        let total = audio.info.frameCount
        let end = Swift.min(total, endFrame ?? total)
        guard startFrame >= 0, startFrame < end else { return nil }
        let length = end - startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let destination = buffer.floatChannelData
        else { return nil }

        let sources: [[Float]] = playbackChannelCount(for: audio) == audio.channels.count ? audio.channels : [audio.mono]
        guard sources.count == Int(format.channelCount) else { return nil }
        for (channel, samples) in sources.enumerated() {
            guard samples.count >= total else { return nil }
            samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                destination[channel].update(from: base + startFrame, count: length)
            }
        }
        buffer.frameLength = AVAudioFrameCount(length)
        if !clicks.isEmpty {
            addClicks(clicks, to: buffer, startFrame: startFrame, sampleRate: format.sampleRate)
        }
        return buffer
    }

    /// 短い減衰する正弦波をクリック音として足す(小節頭は高く・大きく)。
    nonisolated static func addClicks(_ clicks: [ClickMark], to buffer: AVAudioPCMBuffer, startFrame: Int, sampleRate: Double) {
        guard let data = buffer.floatChannelData else { return }
        let length = Int(buffer.frameLength)
        let clickLength = Int(sampleRate * 0.03)
        let channels = Int(buffer.format.channelCount)
        for click in clicks {
            let offset = click.frame - startFrame
            guard offset + clickLength > 0, offset < length else { continue }
            let frequency = click.accent ? 1_600.0 : 1_100.0
            let amplitude: Float = click.accent ? 0.45 : 0.3
            for i in Swift.max(0, -offset)..<clickLength {
                let index = offset + i
                guard index < length else { break }
                let t = Double(i) / sampleRate
                let value = amplitude * Float(exp(-t * 120) * sin(2 * Double.pi * frequency * t))
                for channel in 0..<channels {
                    data[channel][index] += value
                }
            }
        }
    }
}
