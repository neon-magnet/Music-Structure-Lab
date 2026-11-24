import MSLCore
import SwiftUI

/// パートの分離と、パートごとの音量・ミュート・ソロ。
struct StemMixerView: View {
    @EnvironmentObject private var model: AudioDocumentModel

    var body: some View {
        StemMixerContent(store: model.stemModelStore)
    }
}

private struct StemMixerContent: View {
    @EnvironmentObject private var model: AudioDocumentModel
    @ObservedObject var store: StemModelStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                separationControls
                Divider()
                if let stems = model.stems {
                    mixer(stems)
                } else if !model.isSeparating {
                    Text("まだ分離していません。「分離する」を押すと、ドラム・ベース・コード(伴奏)・ボーカル・メロディの 5 つに分けて、別々に再生できるようになります。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Separation

    private var separationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("パート分離")
                .font(.headline)

            Picker("方法", selection: $model.separationMethod) {
                ForEach(SeparationMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.radioGroup)

            if model.separationMethod == .mlModel {
                modelControls
            }

            Text(model.effectiveSeparationMethod.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(model.stems == nil ? "分離する" : "分離し直す") { model.separateStems() }
                    .disabled(model.audio == nil || model.isSeparating || store.isImporting)
                if model.isSeparating {
                    ProgressView(value: model.separationProgress)
                        .frame(maxWidth: 120)
                    Button("中止") { model.cancelSeparation() }
                }
            }
            if model.isSeparating {
                Text("分離中(\(model.effectiveSeparationMethod.title))… \(Int((model.separationProgress * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = store.modelName {
                Label(name, systemImage: "cpu")
                    .font(.callout)
                if let summary = store.modelSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("モデルが読み込まれていません。モデルが無い間は近似分離を使います。モデルの用意の仕方は docs/STEM_MODEL.md を参照してください。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(store.modelName == nil ? "モデルを読み込む…" : "別のモデルを読み込む…") { model.chooseStemModel() }
                    .disabled(store.isImporting)
                if store.modelName != nil {
                    Button("削除") { store.removeModel() }
                        .disabled(store.isImporting)
                }
                if store.isImporting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Mixer

    private func mixer(_ stems: StemSet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ミキサー")
                    .font(.headline)
                Spacer()
                Toggle("パート別に再生", isOn: $model.isStemPlaybackEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Text("分離方法: \(stems.method.title)\(stems.detail.isEmpty ? "" : " — \(stems.detail)")")
                .font(.caption)
                .foregroundStyle(stems.method == .spectral ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(StemKind.allCases) { kind in
                StemRow(kind: kind)
            }
            .disabled(!model.isStemPlaybackEnabled)

            if !model.isStemPlaybackEnabled {
                Text("オフの間は元の音源を再生します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("ミュート・ソロを解除") { model.stemMix = StemMix() }
                Spacer()
                Button("WAV で書き出す…") { model.exportStems() }
                    .help("5 つのパートをそれぞれ WAV ファイルに書き出す")
            }
            .controlSize(.small)
        }
    }
}

private struct StemRow: View {
    let kind: StemKind
    @EnvironmentObject private var model: AudioDocumentModel

    var body: some View {
        let channel = model.stemMix[kind]
        let audible = model.stemMix.gain(for: kind) > 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(StemPalette.color(for: kind).opacity(audible ? 1 : 0.3))
                    .frame(width: 10, height: 10)
                Label(kind.displayName, systemImage: kind.systemImage)
                    .foregroundStyle(audible ? .primary : .secondary)
                Spacer()
                Toggle("M", isOn: Binding(
                    get: { model.stemMix[kind].isMuted },
                    set: { model.stemMix[kind].isMuted = $0 }
                ))
                .toggleStyle(.button)
                .help("ミュート")
                Toggle("S", isOn: Binding(
                    get: { model.stemMix[kind].isSolo },
                    set: { model.stemMix[kind].isSolo = $0 }
                ))
                .toggleStyle(.button)
                .help("ソロ(複数選べます)")
                Button {
                    model.soloOnly(kind)
                } label: {
                    Image(systemName: "headphones")
                }
                .buttonStyle(.borderless)
                .help("このパートだけを聴く(もう一度押すと戻す)")
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(model.stemMix[kind].volume) },
                        set: { model.stemMix[kind].volume = Float($0) }
                    ),
                    in: 0...1
                )
                Text("\(Int((channel.volume * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            if let reason = model.stems?.unavailable[kind] {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
