import AppKit
import Foundation
import MSLAudio
import MSLCore
import SwiftUI
import UniformTypeIdentifiers

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

/// 波形上で選んでいるもの。
enum Selection: Equatable {
    case section(SongSection.ID)
    case chord(ChordSegment.ID)
}

extension UTType {
    /// Music Structure Lab のプロジェクトファイル (.mslab)。
    static let musicStructureLabProject = UTType(exportedAs: "app.musicstructurelab.project", conformingTo: .json)
}

/// 開いている音源・解析結果・プロジェクトの状態を管理する。
@MainActor
final class AudioDocumentModel: ObservableObject {
    // MARK: Audio

    @Published private(set) var audio: DecodedAudio?
    /// 読み込みが完了するたびに変わる。波形ビューの状態(ズーム等)をリセットするのに使う。
    @Published private(set) var documentID = UUID()
    @Published private(set) var isLoading = false
    @Published private(set) var loadingFileName = ""
    @Published private(set) var loadingProgress: Double = 0
    @Published var errorMessage: String?
    @Published var isImporterPresented = false
    @Published var displayMode: WaveformDisplayMode = .channels

    // MARK: Playback

    /// 再生位置(フレーム)。クリックで移動し、再生中は再生に合わせて進む。
    @Published private(set) var cursorFrame: Int?
    @Published private(set) var isPlaying = false
    /// 選択中のセクション・コードを繰り返し再生する。
    @Published var isLoopEnabled = false {
        didSet { restartPlaybackIfNeeded() }
    }
    /// 拍に合わせてクリック音を鳴らす。
    @Published var isClickEnabled = false {
        didSet { restartPlaybackIfNeeded() }
    }

    // MARK: Analysis

    @Published private(set) var analysis: AnalysisResult?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisStage: AnalysisStage = .spectrum
    @Published private(set) var analysisProgress: Double = 0
    @Published var selection: Selection?

    // MARK: Project

    @Published var notes = "" {
        didSet { if notes != oldValue { hasUnsavedChanges = true } }
    }
    @Published private(set) var projectURL: URL?
    @Published private(set) var hasUnsavedChanges = false

    /// 編集の取り消しに使う(ウィンドウの UndoManager を設定する)。
    weak var undoManager: UndoManager?

    let loader = AudioFileLoader()
    let player: AudioPlayer
    let analyzer = MusicAnalyzer()
    private(set) var audioURL: URL?
    private var audioAccessing = false
    private var playheadTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var loadToken = UUID()
    private var analysisTask: Task<Void, Never>?
    private var analysisToken = UUID()
    /// プロジェクトを開いた時、音源の読み込み後に適用する内容。
    private var pendingProject: (document: ProjectDocument, url: URL)?
    /// ドラッグ中の編集の開始時点(確定時に 1 回だけ取り消しを登録する)。
    private var editBase: AnalysisResult?

    init() {
        player = AudioPlayer()
        player.onFinished = { [weak self] in
            guard let self else { return }
            self.playbackStopped(at: self.player.currentFrame)
        }
        player.onInterrupted = { [weak self] frame in
            self?.playbackStopped(at: frame)
        }
    }

    var displayTitle: String {
        let base = projectURL?.deletingPathExtension().lastPathComponent
            ?? audio?.info.fileName
            ?? "Music Structure Lab"
        return hasUnsavedChanges ? "\(base) — 編集済み" : base
    }

    var sampleRate: Double { audio?.info.sampleRate ?? 0 }

    func frame(forTime time: Double) -> Int {
        Int((time * sampleRate).rounded())
    }

    func time(forFrame frame: Int) -> Double {
        sampleRate > 0 ? Double(frame) / sampleRate : 0
    }

    var cursorTime: Double { time(forFrame: cursorFrame ?? 0) }

    // MARK: - Opening

    /// 音源ファイルかプロジェクトファイルを開く。
    func open(url: URL) {
        guard confirmDiscardChanges() else { return }
        if url.pathExtension.lowercased() == ProjectDocument.fileExtension {
            openProject(at: url)
        } else {
            pendingProject = nil
            openAudio(url: url)
        }
    }

    func openAudio(url: URL) {
        pause()
        cancelAnalysis()
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
                await self.finishLoading(decoded, url: url, token: token)
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
        pendingProject = nil
    }

    func close() {
        guard confirmDiscardChanges() else { return }
        closeWithoutConfirmation()
    }

    func closeWithoutConfirmation() {
        cancelLoading()
        cancelAnalysis()
        stopPlayheadTimer()
        player.unload()
        isPlaying = false
        audio = nil
        analysis = nil
        selection = nil
        cursorFrame = nil
        projectURL = nil
        notes = ""
        hasUnsavedChanges = false
        releaseAudioAccess()
        undoManager?.removeAllActions(withTarget: self)
        documentID = UUID()
    }

    private func reportProgress(_ progress: Double, token: UUID) {
        guard token == loadToken else { return }
        loadingProgress = progress
    }

    private func finishLoading(_ decoded: DecodedAudio, url: URL, token: UUID) {
        guard token == loadToken else { return }
        stopPlayheadTimer()
        isPlaying = false
        player.load(decoded)
        releaseAudioAccess()
        audioURL = url
        // サンドボックスでも保存時にブックマークを作れるよう、開いている間はアクセス権を保つ。
        audioAccessing = url.startAccessingSecurityScopedResource()
        audio = decoded
        cursorFrame = nil
        selection = nil
        analysis = nil
        undoManager?.removeAllActions(withTarget: self)
        documentID = UUID()
        isLoading = false
        loadTask = nil

        if let pending = pendingProject {
            pendingProject = nil
            applyProject(pending.document, url: pending.url, audioInfo: decoded.info)
        } else {
            projectURL = nil
            notes = ""
            hasUnsavedChanges = false
            analyze()
        }
    }

    private func failLoading(_ error: Error, token: UUID) {
        guard token == loadToken else { return }
        isLoading = false
        loadTask = nil
        pendingProject = nil
        errorMessage = Self.message(for: error)
    }

    private func releaseAudioAccess() {
        if audioAccessing, let audioURL {
            audioURL.stopAccessingSecurityScopedResource()
        }
        audioAccessing = false
        audioURL = nil
    }

    /// 保存済みの解析結果をそのまま使う(プロジェクトを開いた時)。
    func setAnalysis(_ result: AnalysisResult) {
        analysis = result
        selection = nil
    }

    func setPendingProject(_ document: ProjectDocument, url: URL) {
        pendingProject = (document, url)
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Unsaved changes

    func markEdited() {
        hasUnsavedChanges = true
    }

    func markSaved(to url: URL) {
        projectURL = url
        hasUnsavedChanges = false
    }

    /// 未保存の変更があれば保存するか尋ねる。続けてよければ true。
    func confirmDiscardChanges() -> Bool {
        guard hasUnsavedChanges, audio != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "「\(displayTitle.replacingOccurrences(of: " — 編集済み", with: ""))」への変更を保存しますか?"
        alert.informativeText = "保存しないと、解析結果の編集やメモは失われます。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存しない")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject()
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: - Playback

    var canPlay: Bool { audio != nil && !isLoading }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// カーソル位置から再生する。末尾にいる場合は先頭から。ループ中は選択範囲の先頭から。
    func play() {
        guard let audio, canPlay else { return }
        var start = cursorFrame ?? 0
        if let range = loopRange, !range.contains(start) {
            start = range.lowerBound
        }
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

    func seek(toTime time: Double) {
        seek(to: frame(forTime: time))
    }

    func returnToStart() {
        seek(to: loopRange?.lowerBound ?? 0)
    }

    /// 選択中のセクション・コードの範囲(フレーム)。
    var selectionRange: Range<Int>? {
        guard let analysis, let selection else { return nil }
        switch selection {
        case let .section(id):
            guard let section = analysis.sections.first(where: { $0.id == id }) else { return nil }
            return frame(forTime: section.start)..<frame(forTime: section.end)
        case let .chord(id):
            guard let chord = analysis.chords.first(where: { $0.id == id }) else { return nil }
            return frame(forTime: chord.start)..<frame(forTime: chord.end)
        }
    }

    var loopRange: Range<Int>? {
        isLoopEnabled ? selectionRange : nil
    }

    /// 選択範囲の先頭から再生する。
    func playSelection() {
        guard let range = selectionRange else { return }
        startPlayback(from: range.lowerBound)
    }

    private func restartPlaybackIfNeeded() {
        guard isPlaying else { return }
        startPlayback(from: player.currentFrame)
    }

    func startPlayback(from frame: Int) {
        var start = frame
        var end: Int?
        let loop = loopRange
        if let loop {
            if !loop.contains(start) { start = loop.lowerBound }
            end = loop.upperBound
        }
        do {
            try player.play(from: start, until: end, loop: loop != nil, clicks: clickMarks(from: start, to: end))
            cursorFrame = start
            isPlaying = player.isPlaying
            if isPlaying { startPlayheadTimer() }
        } catch {
            isPlaying = false
            stopPlayheadTimer()
            errorMessage = Self.message(for: error)
        }
    }

    private func clickMarks(from start: Int, to end: Int?) -> [ClickMark] {
        guard isClickEnabled, let analysis else { return [] }
        let grid = analysis.beatGrid
        let upper = end ?? Int.max
        return grid.beats.enumerated().compactMap { index, time in
            let frame = self.frame(forTime: time)
            guard frame >= start, frame < upper else { return nil }
            return ClickMark(frame: frame, accent: grid.isDownbeat(index))
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

    // MARK: - Analysis

    func analyze() {
        guard let audio, !isLoading else { return }
        cancelAnalysis()
        let token = UUID()
        analysisToken = token
        isAnalyzing = true
        analysisStage = .spectrum
        analysisProgress = 0
        let analyzer = self.analyzer
        analysisTask = Task.detached(priority: .userInitiated) { [self] in
            let throttle = ProgressThrottle()
            do {
                let result = try analyzer.analyze(samples: audio.mono, sampleRate: audio.info.sampleRate) { stage, progress in
                    guard throttle.shouldReport(progress) else { return }
                    Task { @MainActor in
                        self.reportAnalysisProgress(stage: stage, progress: progress, token: token)
                    }
                }
                try Task.checkCancellation()
                await self.finishAnalysis(result, token: token)
            } catch is CancellationError {
            } catch {
                await self.failAnalysis(error, token: token)
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisToken = UUID()
        isAnalyzing = false
    }

    private func reportAnalysisProgress(stage: AnalysisStage, progress: Double, token: UUID) {
        guard token == analysisToken else { return }
        analysisStage = stage
        analysisProgress = progress
    }

    private func finishAnalysis(_ result: AnalysisResult, token: UUID) {
        guard token == analysisToken else { return }
        isAnalyzing = false
        analysisTask = nil
        if let previous = analysis {
            // 再解析も取り消せるようにする。
            registerUndo(restoring: previous, actionName: "再解析")
            markEdited()
        }
        analysis = result
        selection = nil
        restartPlaybackIfNeeded()
    }

    private func failAnalysis(_ error: Error, token: UUID) {
        guard token == analysisToken else { return }
        isAnalyzing = false
        analysisTask = nil
        errorMessage = Self.message(for: error)
    }

    // MARK: - Editing

    /// 解析結果を編集する。取り消し(⌘Z)に登録する。
    func edit(_ actionName: String, _ change: (inout AnalysisResult) -> Void) {
        guard var result = analysis else { return }
        let before = result
        change(&result)
        guard result != before else { return }
        apply(result, previous: before, actionName: actionName)
    }

    /// ドラッグ中など、連続した変更の途中経過を反映する(取り消しは確定時に 1 回だけ登録する)。
    func previewEdit(_ change: (inout AnalysisResult) -> Void) {
        guard var result = analysis else { return }
        if editBase == nil { editBase = result }
        change(&result)
        analysis = result
    }

    func commitPreviewEdit(_ actionName: String) {
        guard let base = editBase, let result = analysis else { return }
        editBase = nil
        guard base != result else { return }
        registerUndo(restoring: base, actionName: actionName)
        markEdited()
    }

    private func apply(_ result: AnalysisResult, previous: AnalysisResult, actionName: String) {
        analysis = result
        registerUndo(restoring: previous, actionName: actionName)
        markEdited()
        validateSelection()
    }

    private func registerUndo(restoring previous: AnalysisResult, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard let current = target.analysis else { return }
                target.apply(previous, previous: current, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func validateSelection() {
        guard let analysis, let selection else { return }
        switch selection {
        case let .section(id):
            if !analysis.sections.contains(where: { $0.id == id }) { self.selection = nil }
        case let .chord(id):
            if !analysis.chords.contains(where: { $0.id == id }) { self.selection = nil }
        }
    }

    var selectedSection: SongSection? {
        guard case let .section(id) = selection else { return nil }
        return analysis?.sections.first { $0.id == id }
    }

    var selectedChord: ChordSegment? {
        guard case let .chord(id) = selection else { return nil }
        return analysis?.chords.first { $0.id == id }
    }

    func select(_ newSelection: Selection?, seekToStart: Bool = true) {
        selection = newSelection
        if seekToStart, let range = selectionRange {
            seek(to: range.lowerBound)
        } else if isPlaying {
            restartPlaybackIfNeeded()
        }
    }

    /// カーソル位置でセクションを分割する。
    func splitSectionAtCursor() {
        let time = cursorTime
        var newID: SongSection.ID?
        edit("セクションを分割") { newID = $0.splitSection(at: time) }
        if let newID { selection = .section(newID) }
    }

    func splitChordAtCursor() {
        let time = cursorTime
        var newID: ChordSegment.ID?
        edit("コードを分割") { newID = $0.splitChord(at: time) }
        if let newID { selection = .chord(newID) }
    }

    func mergeSelectionWithNext() {
        switch selection {
        case let .section(id):
            edit("セクションを結合") { $0.mergeSectionWithNext(id: id) }
        case let .chord(id):
            edit("コードを結合") { $0.mergeChordWithNext(id: id) }
        case nil:
            break
        }
    }

    func removeSelectedSection() {
        guard case let .section(id) = selection else { return }
        edit("セクションを削除") { $0.removeSection(id: id) }
    }
}

/// 進捗通知を 1% 刻みに間引く。読み込みスレッドからのみ使う。
final class ProgressThrottle: @unchecked Sendable {
    private var lastReported: Double = -1

    func shouldReport(_ value: Double) -> Bool {
        if value >= 1 || value - lastReported >= 0.01 {
            lastReported = value
            return true
        }
        return false
    }
}
