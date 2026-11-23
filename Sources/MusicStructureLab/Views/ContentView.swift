import MSLAudio
import MSLCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AudioDocumentModel
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if let audio = model.audio {
                VStack(spacing: 0) {
                    AudioInfoBar(info: audio.info)
                    Divider()
                    WaveformPanel(
                        audio: audio,
                        displayMode: $model.displayMode,
                        cursorFrame: $model.cursorFrame
                    )
                    .id(model.documentID)
                }
            } else if !model.isLoading {
                EmptyStateView { model.isImporterPresented = true }
            }

            if model.isLoading {
                LoadingOverlay(
                    fileName: model.loadingFileName,
                    progress: model.loadingProgress,
                    onCancel: { model.cancelLoading() }
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
        .navigationTitle(model.audio?.info.fileName ?? "Music Structure Lab")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("音源を開く", systemImage: "folder")
                }
                .help("音源ファイルを開く (⌘O)")
            }
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: AudioFileLoader.supportedContentTypes,
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
            "読み込めませんでした",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
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
            Text("ここにドラッグ&ドロップするか、「開く…」(⌘O) から選択します。\nWAV / AIFF / CAF / MP3 / AAC (M4A) / ALAC / FLAC に対応しています。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("開く…", action: onOpen)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(40)
    }
}

private struct LoadingOverlay: View {
    let fileName: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("読み込み中: \(fileName)")
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
