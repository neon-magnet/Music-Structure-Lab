import AppKit
import MSLCore
import SwiftUI

@main
struct MusicStructureLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AudioDocumentModel()

    var body: some Scene {
        Window("Music Structure Lab", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 560)
                .onAppear {
                    appDelegate.openHandler = { [weak model] url in model?.open(url: url) }
                    appDelegate.shouldTerminate = { [weak model] in model?.confirmDiscardChanges() ?? true }
                }
        }
        .commands {
            FileCommands(model: model)
            AnalysisCommands(model: model)
            PlaybackCommands(model: model)
        }
    }
}

struct FileCommands: Commands {
    @ObservedObject var model: AudioDocumentModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("開く…") { model.isImporterPresented = true }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { model.saveProject() }
                .keyboardShortcut("s")
                .disabled(model.audio == nil)
            Button("別名で保存…") { model.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.audio == nil)
            Divider()
            Menu("書き出し") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.title + "…") { model.export(format) }
                }
                Divider()
                Button("選択範囲の音声 (WAV)…") { model.exportSelectionAudio() }
                    .disabled(model.selectionRange == nil)
            }
            .disabled(model.analysis == nil)
            Divider()
            Button("閉じる") { model.close() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.audio == nil && !model.isLoading)
        }
    }
}

struct AnalysisCommands: Commands {
    @ObservedObject var model: AudioDocumentModel

    var body: some Commands {
        CommandMenu("解析") {
            Button(model.analysis == nil ? "解析を実行" : "解析し直す") { model.analyze() }
                .keyboardShortcut("r")
                .disabled(model.audio == nil || model.isAnalyzing)
            Button("解析を中止") { model.cancelAnalysis() }
                .disabled(!model.isAnalyzing)
            Divider()
            Button("カーソル位置でセクションを分割") { model.splitSectionAtCursor() }
                .keyboardShortcut("k")
                .disabled(model.analysis == nil)
            Button("カーソル位置でコードを分割") { model.splitChordAtCursor() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(model.analysis == nil)
            Button("選択を次と結合") { model.mergeSelectionWithNext() }
                .keyboardShortcut("j")
                .disabled(model.selection == nil)
            Button("選択したセクションを削除") { model.removeSelectedSection() }
                .disabled(model.selectedSection == nil)
            Divider()
            Button("セクションの境界を小節頭に揃える") {
                model.edit("境界を小節に揃える") { $0.snapSectionsToBars() }
            }
            .disabled(model.analysis == nil)
            Button("半音上げる") { model.edit("移調") { $0.transpose(by: 1) } }
                .disabled(model.analysis == nil)
            Button("半音下げる") { model.edit("移調") { $0.transpose(by: -1) } }
                .disabled(model.analysis == nil)
        }
    }
}

struct PlaybackCommands: Commands {
    @ObservedObject var model: AudioDocumentModel

    var body: some Commands {
        CommandMenu("再生") {
            Button(model.isPlaying ? "一時停止 (スペース)" : "再生 (スペース)") { model.togglePlayback() }
                .disabled(!model.canPlay)
            Button("先頭へ") { model.returnToStart() }
                .disabled(!model.canPlay)
            Button("選択範囲を再生") { model.playSelection() }
                .disabled(model.selectionRange == nil)
            Divider()
            Toggle("選択範囲をループ", isOn: $model.isLoopEnabled)
                .keyboardShortcut("l")
            Toggle("クリック音", isOn: $model.isClickEnabled)
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.analysis == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder から開かれたファイルを受け取る。ウィンドウ表示前に届いた分は保留しておく。
    var openHandler: ((URL) -> Void)? {
        didSet {
            guard let openHandler, !pendingURLs.isEmpty else { return }
            pendingURLs.forEach(openHandler)
            pendingURLs.removeAll()
        }
    }

    /// 終了してよいか(未保存の変更の確認)。
    var shouldTerminate: (() -> Bool)?

    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` で .app バンドルなしに起動した場合でも、通常のアプリとして前面に出す。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (shouldTerminate?() ?? true) ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let openHandler {
            openHandler(url)
        } else {
            pendingURLs = [url]
        }
    }
}
