import AppKit
import MSLAudio
import MSLCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AudioDocumentModel
    @Environment(\.undoManager) private var undoManager
    @State private var isDropTargeted = false
    @State private var showsInspector = true
    @StateObject private var keyMonitor = KeyCommandMonitor()

    var body: some View {
        ZStack {
            if let audio = model.audio {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        AudioInfoBar(info: audio.info)
                        Divider()
                        WaveformPanel(audio: audio)
                            .id(model.documentID)
                    }
                    if showsInspector {
                        Divider()
                        InspectorView()
                            .frame(width: 330)
                    }
                }
            } else if !model.isLoading {
                EmptyStateView { model.isImporterPresented = true }
            }

            if model.isLoading {
                ProgressOverlay(
                    title: "読み込み中: \(model.loadingFileName)",
                    progress: model.loadingProgress,
                    onCancel: { model.cancelLoading() }
                )
            } else if model.isAnalyzing {
                ProgressOverlay(
                    title: "解析中: \(model.analysisStage.title)",
                    progress: model.analysisProgress,
                    onCancel: { model.cancelAnalysis() }
                )
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.displayTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("開く", systemImage: "folder")
                }
                .help("音源またはプロジェクトを開く (⌘O)")

                Button {
                    model.saveProject()
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .disabled(model.audio == nil)
                .help("プロジェクトを保存 (⌘S)")

                Button {
                    model.analyze()
                } label: {
                    Label("解析", systemImage: "wand.and.stars")
                }
                .disabled(model.audio == nil || model.isAnalyzing)
                .help(model.analysis == nil ? "解析を実行 (⌘R)" : "解析し直す (⌘R)")

                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title + "…") { model.export(format) }
                    }
                    Divider()
                    Button("選択範囲の音声 (WAV)…") { model.exportSelectionAudio() }
                        .disabled(model.selectionRange == nil)
                } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }
                .disabled(model.analysis == nil)
                .help("解析結果を書き出す")

                Button {
                    showsInspector.toggle()
                } label: {
                    Label("インスペクタ", systemImage: "sidebar.right")
                }
                .help("インスペクタの表示/非表示")
            }
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: AudioFileLoader.supportedContentTypes + [.musicStructureLabProject],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { model.open(url: url) }
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.open(url: url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            model.undoManager = undoManager
            keyMonitor.onSpace = { model.togglePlayback() }
            keyMonitor.start()
        }
        .onChange(of: undoManager) { model.undoManager = $0 }
    }
}

/// テキスト入力中でない時のスペースキーで再生/一時停止する。
/// (ボタンのショートカットにすると、テキスト欄にスペースを打てなくなるため)
@MainActor
final class KeyCommandMonitor: ObservableObject {
    var onSpace: (@MainActor () -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 49 else { return false }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
                guard modifiers.isEmpty else { return false }
                if event.window?.firstResponder is NSText { return false }
                self.onSpace?()
                return true
            }
            return handled ? nil : event
        }
    }
}

private struct EmptyStateView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("音源ファイルを開いてください")
                .font(.title2)
            Text("ここにドラッグ&ドロップするか、「開く…」(⌘O) から選択します。\nWAV / AIFF / CAF / MP3 / AAC (M4A) / ALAC / FLAC と、保存したプロジェクト (.mslab) を開けます。\n読み込むと自動でテンポ・キー・コード・構造を解析します。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("開く…", action: onOpen)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(40)
    }
}

struct ProgressOverlay: View {
    let title: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: progress)
            HStack {
                Text("\(Int((progress * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("中止", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
    }
}

struct AudioInfoBar: View {
    let info: AudioFileInfo

    var body: some View {
        HStack(spacing: 20) {
            Label(info.fileName, systemImage: "music.note")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            InfoItem(title: "長さ", value: TimeFormatting.string(fromSeconds: info.duration))
            InfoItem(title: "形式", value: info.sourceFormatDescription)
            InfoItem(title: "サンプルレート", value: Self.sampleRateText(info.sampleRate))
            InfoItem(title: "チャンネル", value: Self.channelText(info.channelCount))
            InfoItem(title: "フレーム数", value: info.frameCount.formatted())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static func sampleRateText(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz.rounded() == khz ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    static func channelText(_ count: Int) -> String {
        switch count {
        case 1: return "モノラル"
        case 2: return "ステレオ"
        default: return "\(count) ch"
        }
    }
}

private struct InfoItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .monospacedDigit()
        }
    }
}
