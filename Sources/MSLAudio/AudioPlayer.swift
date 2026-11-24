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
/// 分離したパートを鳴らす時は、パートごとに AVAudioPlayerNode を用意し、同じ時刻に再生を始める。
/// パートの音量は再生中でも変えられる。クリック音は専用のノードで鳴らす(パートのミュートの影響を受けない)。
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
    /// `voices` と同じ順のノード。
    private var nodes: [AVAudioPlayerNode] = []
    private let clickNode = AVAudioPlayerNode()
    private var audio: DecodedAudio?
    /// 同時に鳴らす音声。`voices[voice][channel][frame]`。既定は元の音源 1 つ。
    private var voices: [[[Float]]] = []
    private var gains: [Float] = []
    private var format: AVAudioFormat?
    private var segmentStart = 0
    private var segmentLength = 0
    private var isLooping = false
    private var pausedFrame = 0
    /// 古いバッファの完了通知を無視するための番号。
    private var generation = 0

    public init() {
        engine.attach(clickNode)
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

    /// 同時に鳴らしている音声の数(元の音源なら 1、パート別なら パート数)。
    public var voiceCount: Int { voices.count }

    /// 現在の再生位置(フレーム)。停止中は最後に止めた位置。
    public var currentFrame: Int {
        guard isPlaying,
              let node = nodes.first,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return pausedFrame }
        var elapsed = Swift.max(0, Int(playerTime.sampleTime))
        if isLooping, segmentLength > 0 {
            elapsed %= segmentLength
        }
        return Swift.min(totalFrames, segmentStart + elapsed)
    }

    /// 再生する音源を差し替える。再生中なら止める。パート別の再生は解除される。
    public func load(_ audio: DecodedAudio) {
        stop()
        self.audio = audio
        pausedFrame = 0
        format = Self.playbackFormat(for: audio)
        setVoicesWithoutRestart([Self.playbackChannels(for: audio)], gains: [1])
    }

    public func unload() {
        stop()
        audio = nil
        format = nil
        pausedFrame = 0
        setVoicesWithoutRestart([], gains: [])
        engine.stop()
    }

    /// 同時に鳴らす音声を差し替える(nil で元の音源に戻す)。
    /// 各音声は `playbackChannelCount` チャンネル・音源と同じ長さであること。再生中なら止めて、その位置を返す。
    @discardableResult
    public func setVoices(_ newVoices: [[[Float]]]?, gains newGains: [Float]? = nil) -> Int {
        let frame = pause()
        guard let audio else { return frame }
        let resolved = newVoices ?? [Self.playbackChannels(for: audio)]
        let resolvedGains = newGains ?? [Float](repeating: 1, count: resolved.count)
        setVoicesWithoutRestart(resolved, gains: resolvedGains)
        return frame
    }

    /// 音声ごとの音量(0...1)。再生中にも反映される。
    public func setGains(_ newGains: [Float]) {
        gains = newGains
        for (index, node) in nodes.enumerated() {
            node.volume = index < newGains.count ? Swift.max(0, Swift.min(1, newGains[index])) : 1
        }
    }

    private func setVoicesWithoutRestart(_ newVoices: [[[Float]]], gains newGains: [Float]) {
        voices = newVoices
        while nodes.count > newVoices.count {
            let node = nodes.removeLast()
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        while nodes.count < newVoices.count {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            nodes.append(node)
        }
        connectNodes()
        setGains(newGains)
    }

    private func connectNodes() {
        for node in nodes + [clickNode] {
            engine.disconnectNodeOutput(node)
            if let format {
                engine.connect(node, to: engine.mainMixerNode, format: format)
            }
        }
        if format != nil, !nodes.isEmpty {
            engine.prepare()
        }
    }

    /// `frame` から再生する。再生中に呼ぶとその位置へ移動する。
    /// - Parameters:
    ///   - endFrame: ここで止める(nil なら末尾まで)。
    ///   - loop: `frame..<endFrame` を繰り返す。
    ///   - clicks: クリック音を重ねる位置。
    public func play(from frame: Int, until endFrame: Int? = nil, loop: Bool = false, clicks: [ClickMark] = []) throws {
        guard let audio, let format, !voices.isEmpty else { return }
        let start = Swift.min(Swift.max(0, frame), audio.info.frameCount)
        let end = Swift.min(audio.info.frameCount, endFrame ?? audio.info.frameCount)
        guard start < end else {
            pausedFrame = start
            return
        }
        var buffers = [AVAudioPCMBuffer]()
        for channels in voices {
            guard let buffer = Self.makeBuffer(channels: channels, frameCount: audio.info.frameCount, format: format, startFrame: start, endFrame: end) else {
                throw AudioPlaybackError.bufferCreationFailed
            }
            buffers.append(buffer)
        }
        var clickBuffer: AVAudioPCMBuffer?
        if !clicks.isEmpty {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start)) else {
                throw AudioPlaybackError.bufferCreationFailed
            }
            buffer.frameLength = AVAudioFrameCount(end - start)
            if let data = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    data[channel].update(repeating: 0, count: end - start)
                }
            }
            Self.addClicks(clicks, to: buffer, startFrame: start, sampleRate: format.sampleRate)
            clickBuffer = buffer
        }

        generation += 1
        let current = generation
        stopNodes()

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                isPlaying = false
                throw AudioPlaybackError.engineStartFailed(reason: error.localizedDescription)
            }
        }

        let options: AVAudioPlayerNodeBufferOptions = loop ? [.loops] : []
        for (index, node) in nodes.enumerated() {
            if index == 0 {
                node.scheduleBuffer(buffers[index], at: nil, options: options, completionCallbackType: .dataPlayedBack) { [self] _ in
                    Task { @MainActor in
                        self.segmentFinished(generation: current)
                    }
                }
            } else {
                node.scheduleBuffer(buffers[index], at: nil, options: options, completionHandler: nil)
            }
        }
        if let clickBuffer {
            clickNode.scheduleBuffer(clickBuffer, at: nil, options: options, completionHandler: nil)
        }
        segmentStart = start
        segmentLength = end - start
        isLooping = loop
        pausedFrame = start

        // 複数のノードを同じ時刻から鳴らす(少し先の時刻を指定して、開始のずれを無くす)。
        let playing = nodes + (clickBuffer != nil ? [clickNode] : [])
        if playing.count > 1 {
            let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
            for node in playing { node.play(at: startTime) }
        } else {
            playing.first?.play()
        }
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
        stopNodes()
        isPlaying = false
    }

    private func stopNodes() {
        for node in nodes { node.stop() }
        clickNode.stop()
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
        connectNodes()
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

    /// 再生に使うチャンネルのサンプル(モノラル・ステレオはそのまま、それ以上はモノラルミックス)。
    /// パート分離の入力にもこれを使い、分離したパートが同じチャンネル数になるようにする。
    public nonisolated static func playbackChannels(for audio: DecodedAudio) -> [[Float]] {
        playbackChannelCount(for: audio) == audio.channels.count ? audio.channels : [audio.mono]
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
        guard let buffer = makeBuffer(
            channels: playbackChannels(for: audio),
            frameCount: audio.info.frameCount,
            format: format,
            startFrame: startFrame,
            endFrame: endFrame
        ) else { return nil }
        if !clicks.isEmpty {
            addClicks(clicks, to: buffer, startFrame: startFrame, sampleRate: format.sampleRate)
        }
        return buffer
    }

    /// チャンネルごとのサンプル列から再生用バッファを作る。
    nonisolated static func makeBuffer(
        channels sources: [[Float]],
        frameCount total: Int,
        format: AVAudioFormat,
        startFrame: Int,
        endFrame: Int? = nil
    ) -> AVAudioPCMBuffer? {
        let end = Swift.min(total, endFrame ?? total)
        guard startFrame >= 0, startFrame < end else { return nil }
        let length = end - startFrame
        guard sources.count == Int(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let destination = buffer.floatChannelData
        else { return nil }
        for (channel, samples) in sources.enumerated() {
            guard samples.count >= end else { return nil }
            samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                destination[channel].update(from: base + startFrame, count: length)
            }
        }
        buffer.frameLength = AVAudioFrameCount(length)
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
