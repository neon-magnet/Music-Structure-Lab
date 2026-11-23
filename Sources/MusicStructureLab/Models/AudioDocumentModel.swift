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
    /// クリックで指定した位置(フレーム)。今後の再生・区間編集の起点になる。
    @Published var cursorFrame: Int?

    private let loader = AudioFileLoader()
    private var loadTask: Task<Void, Never>?
    private var loadToken = UUID()

    func open(url: URL) {
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
        audio = nil
        cursorFrame = nil
        documentID = UUID()
    }

    private func reportProgress(_ progress: Double, token: UUID) {
        guard token == loadToken else { return }
        loadingProgress = progress
    }

    private func finishLoading(_ decoded: DecodedAudio, token: UUID) {
        guard token == loadToken else { return }
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
