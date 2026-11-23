import Foundation
import MSLAudio
import MSLCore
import SwiftUI

enum WaveformDisplayMode: String, CaseIterable, Identifiable {
    case channels
    case mix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .channels: return "チャンネル別"
        case .mix: return "ミックス"
        }
    }
}

/// 開いている音源と、その読み込み状態を管理する。
@MainActor
final class AudioDocumentModel: ObservableObject {
    @Published private(set) var audio: DecodedAudio?
    /// 読み込みが完了するたびに変わる。波形ビューの状態(ズーム等)をリセットするのに使う。
    @Published private(set) var documentID = UUID()

    @Published private(set) var isLoading = false
    @Published private(set) var loadingFileName = ""
    @Published private(set) var loadingProgress: Double = 0
    @Published var errorMessage: String?

    @Published var isImporterPresented = false
    @Published var displayMode: WaveformDisplayMode = .channels
    /// 再生位置(フレーム)。クリックで移動し、再生中は再生に合わせて進む。
    @Published private(set) var cursorFrame: Int?
    @Published private(set) var isPlaying = false

    private let loader = AudioFileLoader()
    private let player: AudioPlayer
    private var playheadTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var loadToken = UUID()

    init() {
        player = AudioPlayer()
        player.onFinished = { [weak self] in
            guard let self else { return }
            self.playbackStopped(at: self.player.totalFrames)
        }
        player.onInterrupted = { [weak self] frame in
            self?.playbackStopped(at: frame)
        }
    }

    func open(url: URL) {
        pause()
        loadTask?.cancel()
        let token = UUID()
        loadToken = token
        isLoading = true
        loadingFileName = url.lastPathComponent
        loadingProgress = 0
        errorMessage = nil

        let loader = self.loader
        // モデルはアプリ終了まで生きるので、読み込み中は強参照で保持してよい。
        loadTask = Task.detached(priority: .userInitiated) { [self] in
            let throttle = ProgressThrottle()
            do {
                let decoded = try loader.load(from: url) { progress in
                    guard throttle.shouldReport(progress) else { return }
                    Task { @MainActor in
                        self.reportProgress(progress, token: token)
                    }
                }
                try Task.checkCancellation()
                await self.finishLoading(decoded, token: token)
            } catch is CancellationError {
                // 新しいファイルを開いた、または利用者が中止した。
            } catch {
                await self.failLoading(error, token: token)
            }
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        loadToken = UUID()
        isLoading = false
    }

    func close() {
        cancelLoading()
        stopPlayheadTimer()
        player.unload()
        isPlaying = false
        audio = nil
        cursorFrame = nil
        documentID = UUID()
    }

    // MARK: - Playback

    var canPlay: Bool { audio != nil && !isLoading }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// カーソル位置から再生する。末尾にいる場合は先頭から。
    func play() {
        guard let audio, canPlay else { return }
        var start = cursorFrame ?? 0
        if start >= audio.info.frameCount - 1 { start = 0 }
        startPlayback(from: start)
    }

    func pause() {
        guard isPlaying else { return }
        cursorFrame = player.pause()
        isPlaying = false
        stopPlayheadTimer()
    }

    /// 再生位置を移動する。再生中ならその位置から再生を続ける。
    func seek(to frame: Int) {
        guard let audio else { return }
        let clamped = min(max(0, frame), max(0, audio.info.frameCount - 1))
        cursorFrame = clamped
        if isPlaying {
            startPlayback(from: clamped)
        }
    }

    func returnToStart() {
        seek(to: 0)
    }

    private func startPlayback(from frame: Int) {
        do {
            try player.play(from: frame)
            cursorFrame = frame
            isPlaying = player.isPlaying
            if isPlaying { startPlayheadTimer() }
        } catch {
            isPlaying = false
            stopPlayheadTimer()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func playbackStopped(at frame: Int) {
        isPlaying = false
        stopPlayheadTimer()
        if let audio {
            cursorFrame = min(max(0, frame), max(0, audio.info.frameCount - 1))
        }
    }

    private func startPlayheadTimer() {
        stopPlayheadTimer()
        // 画面の更新に合わせて約 60 回/秒、再生位置を読み取る。
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.cursorFrame = self.player.currentFrame
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadTimer = timer
    }

    private func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    // MARK: - Loading callbacks

    private func reportProgress(_ progress: Double, token: UUID) {
        guard token == loadToken else { return }
        loadingProgress = progress
    }

    private func finishLoading(_ decoded: DecodedAudio, token: UUID) {
        guard token == loadToken else { return }
        stopPlayheadTimer()
        isPlaying = false
        player.load(decoded)
        audio = decoded
        cursorFrame = nil
        documentID = UUID()
        isLoading = false
        loadTask = nil
    }

    private func failLoading(_ error: Error, token: UUID) {
        guard token == loadToken else { return }
        isLoading = false
        loadTask = nil
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// 進捗通知を 1% 刻みに間引く。読み込みスレッドからのみ使う。
private final class ProgressThrottle: @unchecked Sendable {
    private var lastReported: Double = -1

    func shouldReport(_ value: Double) -> Bool {
        if value >= 1 || value - lastReported >= 0.01 {
            lastReported = value
            return true
        }
        return false
    }
}
