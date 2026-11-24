import AppKit
import Foundation
import MSLAudio
import MSLCore
import SwiftUI

/// パートの色。
enum StemPalette {
    static func color(for kind: StemKind) -> Color {
        switch kind {
        case .drums: return Color(red: 0.90, green: 0.40, blue: 0.30)
        case .bass: return Color(red: 0.55, green: 0.40, blue: 0.90)
        case .chords: return Color(red: 0.25, green: 0.65, blue: 0.85)
        case .vocals: return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .melody: return Color(red: 0.30, green: 0.75, blue: 0.45)
        }
    }
}

/// パートの分離と、パート別の再生・書き出し。
extension AudioDocumentModel {
    /// 次の分離で実際に使う方法(機械学習を選んでいてもモデルが無ければ近似分離)。
    var effectiveSeparationMethod: SeparationMethod {
        separationMethod == .mlModel && stemModelStore.compiledModelURL != nil ? .mlModel : .spectral
    }

    func separateStems() {
        guard let audio, !isLoading else { return }
        cancelSeparation()
        let token = UUID()
        separationToken = token
        isSeparating = true
        separationProgress = 0
        let method = effectiveSeparationMethod
        let modelURL = stemModelStore.compiledModelURL
        let modelName = stemModelStore.modelName
        let channels = AudioPlayer.playbackChannels(for: audio)
        let sampleRate = audio.info.sampleRate

        separationTask = Task.detached(priority: .userInitiated) { [self] in
            let throttle = ProgressThrottle()
            let report: (Double) -> Void = { progress in
                guard throttle.shouldReport(progress) else { return }
                Task { @MainActor in
                    self.reportSeparationProgress(progress, token: token)
                }
            }
            do {
                let result: StemSet
                if method == .mlModel, let modelURL {
                    let separator = try MLStemSeparator(compiledModelURL: modelURL, name: modelName)
                    result = try separator.separate(channels: channels, sampleRate: sampleRate, progress: report)
                } else {
                    result = try SpectralStemSeparator().separate(channels: channels, sampleRate: sampleRate, progress: report)
                }
                try Task.checkCancellation()
                await self.finishSeparation(result, token: token)
            } catch is CancellationError {
            } catch {
                await self.failSeparation(error, token: token)
            }
        }
    }

    func cancelSeparation() {
        separationTask?.cancel()
        separationTask = nil
        separationToken = UUID()
        isSeparating = false
    }

    /// 分離したパートを捨て、元の音源の再生に戻す。
    func clearStems() {
        isStemPlaybackEnabled = false
        stems = nil
        stemMix = StemMix()
        if displayMode == .stems { displayMode = .channels }
    }

    private func reportSeparationProgress(_ progress: Double, token: UUID) {
        guard token == separationToken else { return }
        separationProgress = progress
    }

    private func finishSeparation(_ result: StemSet, token: UUID) {
        guard token == separationToken, let audio, result.frameCount == audio.info.frameCount else { return }
        isSeparating = false
        separationTask = nil
        stems = result
        if isStemPlaybackEnabled {
            updatePlayerVoices()
        } else {
            isStemPlaybackEnabled = true
        }
        displayMode = .stems
    }

    private func failSeparation(_ error: Error, token: UUID) {
        guard token == separationToken else { return }
        isSeparating = false
        separationTask = nil
        errorMessage = Self.message(for: error)
    }

    /// 再生する音声(元の音源かパート)を切り替える。再生中なら同じ位置から続ける。
    func updatePlayerVoices() {
        let wasPlaying = isPlaying
        let frame: Int
        if isStemPlaybackEnabled, let stems {
            frame = player.setVoices(StemKind.allCases.map { stems.channels(for: $0) }, gains: stemGains)
        } else {
            frame = player.setVoices(nil)
        }
        if wasPlaying {
            startPlayback(from: frame)
        }
    }

    var stemGains: [Float] {
        StemKind.allCases.map { stemMix.gain(for: $0) }
    }

    func applyStemGains() {
        guard isStemPlaybackEnabled, stems != nil else { return }
        player.setGains(stemGains)
    }

    func toggleMute(_ kind: StemKind) {
        stemMix[kind].isMuted.toggle()
    }

    func toggleSolo(_ kind: StemKind) {
        stemMix[kind].isSolo.toggle()
    }

    /// そのパートだけを鳴らす(もう一度で解除)。
    func soloOnly(_ kind: StemKind) {
        stemMix.toggleExclusiveSolo(kind)
    }

    // MARK: - Export

    /// すべてのパートを WAV で、選んだフォルダに書き出す。
    func exportStems() {
        guard let audio, let stems else { return }
        let panel = NSOpenPanel()
        panel.title = "パートの書き出し先フォルダを選択"
        panel.prompt = "書き出す"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let baseName = audio.info.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        do {
            for kind in StemKind.allCases {
                let url = folder.appendingPathComponent("\(baseName)-\(kind.rawValue).wav")
                try AudioExporter.writeWAV(
                    channels: stems.channels(for: kind),
                    sampleRate: stems.sampleRate,
                    frames: 0..<stems.frameCount,
                    to: url
                )
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Model

    /// Core ML モデルを選んで取り込む。
    func chooseStemModel() {
        let panel = NSOpenPanel()
        panel.title = "パート分離用の Core ML モデルを選択"
        panel.message = ".mlpackage / .mlmodel / .mlmodelc を選んでください。形式は docs/STEM_MODEL.md を参照。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await stemModelStore.importModel(from: url)
                separationMethod = .mlModel
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }
}

/// 利用者が取り込んだパート分離用モデルを、アプリのコンテナ内に保管する。
@MainActor
final class StemModelStore: ObservableObject {
    @Published private(set) var modelName: String?
    @Published private(set) var isImporting = false
    /// 取り込んだモデルの形(読み込めなかった時はその理由)。
    @Published private(set) var modelSummary: String?

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Music Structure Lab/StemModels", isDirectory: true)
        refresh()
    }

    var compiledModelURL: URL? {
        guard let modelName else { return nil }
        return directory.appendingPathComponent(modelName + ".mlmodelc", isDirectory: true)
    }

    private func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let compiled = contents.first { $0.pathExtension == "mlmodelc" }
        modelName = compiled?.deletingPathExtension().lastPathComponent
        if compiled == nil { modelSummary = nil }
    }

    /// モデルをコンパイルして保管する(以前のモデルは置き換える)。
    func importModel(from url: URL) async throws {
        isImporting = true
        defer { isImporting = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        let compiled: URL
        let isTemporary: Bool
        if url.pathExtension == "mlmodelc" {
            compiled = url
            isTemporary = false
        } else {
            compiled = try await MLStemSeparator.compileModel(at: url)
            isTemporary = true
        }
        // 使えるモデルかを先に確かめる。
        let separator = try MLStemSeparator(compiledModelURL: compiled, name: name)
        let summary = separator.summary

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for existing in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: existing)
        }
        let destination = directory.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
        if isTemporary {
            try fileManager.moveItem(at: compiled, to: destination)
        } else {
            try fileManager.copyItem(at: compiled, to: destination)
        }
        refresh()
        modelSummary = summary
    }

    func removeModel() {
        if let compiledModelURL {
            try? FileManager.default.removeItem(at: compiledModelURL)
        }
        refresh()
    }
}
