import AppKit
import MSLCore
import SwiftUI

/// 右側のインスペクタ。解析結果の確認と編集、セクション一覧、コード譜、メモ。
struct InspectorView: View {
    @EnvironmentObject private var model: AudioDocumentModel

    private enum Tab: String, CaseIterable, Identifiable {
        case edit
        case sections
        case chart
        case notes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .edit: return "編集"
            case .sections: return "構成"
            case .chart: return "コード譜"
            case .notes: return "メモ"
            }
        }
    }

    @State private var tab: Tab = .edit

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .edit:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let analysis = model.analysis {
                            SummaryEditor(analysis: analysis)
                            Divider()
                            if let section = model.selectedSection {
                                SectionEditor(section: section, analysis: analysis)
                            } else if let chord = model.selectedChord {
                                ChordEditor(segment: chord, analysis: analysis)
                            } else {
                                Text("波形の上のセクション帯・コード帯をクリックすると、ここで編集できます。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            NotAnalyzedView()
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .sections:
                SectionListView()
            case .chart:
                ChordChartView()
            case .notes:
                NotesView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct NotAnalyzedView: View {
    @EnvironmentObject private var model: AudioDocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isAnalyzing ? "解析中です…" : "まだ解析していません。")
                .font(.headline)
            Text("テンポ・拍・小節、キー、コード、楽曲の構成(セクション)を推定します。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("解析を実行") { model.analyze() }
                .disabled(model.isAnalyzing || model.audio == nil)
        }
    }
}

// MARK: - Summary

private struct SummaryEditor: View {
    @EnvironmentObject private var model: AudioDocumentModel
    let analysis: AnalysisResult
    @State private var bpmText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("全体").font(.headline)

            LabeledRow("テンポ") {
                HStack(spacing: 6) {
                    TextField("BPM", text: $bpmText)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyTempo)
                    Text("BPM").foregroundStyle(.secondary)
                    Button("×2") { setTempo(analysis.beatGrid.bpm * 2) }
                    Button("÷2") { setTempo(analysis.beatGrid.bpm / 2) }
                }
            }
            Text("確からしさ \(percent(analysis.tempoConfidence))。テンポを変えると、拍を一定間隔で作り直します。")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledRow("拍子") {
                Picker("拍子", selection: Binding(
                    get: { analysis.beatGrid.beatsPerBar },
                    set: { value in model.edit("拍子を変更") { $0.setBeatsPerBar(value) } }
                )) {
                    ForEach(2...7, id: \.self) { Text("\($0)/4").tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
            }

            LabeledRow("小節頭") {
                HStack(spacing: 6) {
                    Button { model.edit("小節頭をずらす") { $0.shiftDownbeat(by: -1) } } label: { Image(systemName: "chevron.left") }
                    Button { model.edit("小節頭をずらす") { $0.shiftDownbeat(by: 1) } } label: { Image(systemName: "chevron.right") }
                    Text("1 拍ずつ").font(.caption).foregroundStyle(.secondary)
                }
            }

            LabeledRow("拍の位置") {
                HStack(spacing: 6) {
                    Button("−10ms") { model.edit("拍の位置を調整") { $0.nudgeBeats(by: -0.01) } }
                    Button("+10ms") { model.edit("拍の位置を調整") { $0.nudgeBeats(by: 0.01) } }
                }
            }

            LabeledRow("キー") {
                Picker("キー", selection: Binding(
                    get: { analysis.key },
                    set: { key in model.edit("キーを変更") { $0.setKey(key) } }
                )) {
                    Text("不明").tag(MusicalKey?.none)
                    ForEach(MusicalKey.all, id: \.self) { key in
                        Text(key.name).tag(MusicalKey?.some(key))
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            if analysis.key != nil {
                Text("確からしさ \(percent(analysis.keyConfidence))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledRow("移調") {
                HStack(spacing: 6) {
                    Button("−1") { model.edit("移調") { $0.transpose(by: -1) } }
                    Button("+1") { model.edit("移調") { $0.transpose(by: 1) } }
                    Text("コードとキーを半音ずつ").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("セクション \(analysis.sections.count) / コード \(analysis.chords.filter { $0.chord != nil }.count) / 小節 \(analysis.beatGrid.downbeats.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { bpmText = Self.format(analysis.beatGrid.bpm) }
        .onChange(of: analysis.beatGrid.bpm) { bpmText = Self.format($0) }
    }

    private func applyTempo() {
        let normalized = bpmText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else {
            bpmText = Self.format(analysis.beatGrid.bpm)
            return
        }
        setTempo(value)
    }

    private func setTempo(_ value: Double) {
        guard value >= 20, value <= 400 else {
            bpmText = Self.format(analysis.beatGrid.bpm)
            return
        }
        model.edit("テンポを変更") { $0.setTempo(value) }
        bpmText = Self.format(value)
    }

    static func format(_ bpm: Double) -> String {
        String(format: "%.1f", bpm)
    }
}

// MARK: - Section editor

private struct SectionEditor: View {
    @EnvironmentObject private var model: AudioDocumentModel
    let section: Section
    let analysis: AnalysisResult

    static let presetNames = ["イントロ", "A メロ", "B メロ", "サビ", "間奏", "C メロ", "ブリッジ", "ソロ", "アウトロ"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SectionPalette.color(for: section.label))
                    .frame(width: 14, height: 14)
                Text("セクション").font(.headline)
            }

            LabeledRow("名前") {
                CommitTextField(placeholder: "名前", value: section.name, resetKey: section.id.uuidString) { name in
                    model.edit("名前を変更") { $0.renameSection(id: section.id, to: name) }
                }
            }
            HStack(spacing: 4) {
                Menu("候補") {
                    ForEach(Self.presetNames, id: \.self) { name in
                        Button(name) { model.edit("名前を変更") { $0.renameSection(id: section.id, to: name) } }
                    }
                }
                .fixedSize()
                Button("同じ記号すべてに適用") {
                    model.edit("名前を変更") { $0.renameSections(withLabel: section.label, to: section.name) }
                }
                .help("記号「\(section.label)」のセクションすべてに、この名前を付ける")
            }

            LabeledRow("記号") {
                CommitTextField(placeholder: "A", value: section.label, resetKey: section.id.uuidString + "label") { label in
                    guard !label.isEmpty else { return }
                    model.edit("記号を変更") { $0.setSectionLabel(id: section.id, to: label) }
                }
                .frame(width: 60)
            }

            LabeledRow("範囲") {
                Text("\(TimeFormatting.string(fromSeconds: section.start)) – \(TimeFormatting.string(fromSeconds: section.end))")
                    .monospacedDigit()
            }
            LabeledRow("長さ") {
                Text("\(TimeFormatting.string(fromSeconds: section.duration)) (\(barCount) 小節)")
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Button("再生") { model.playSelection() }
                Toggle("ループ", isOn: $model.isLoopEnabled)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                Button("カーソルで分割") { model.splitSectionAtCursor() }
                    .help("再生位置でこのセクションを 2 つに分ける (⌘K)")
                Button("次と結合") { model.mergeSelectionWithNext() }
                    .disabled(analysis.sections.last?.id == section.id)
                    .help("次のセクションとまとめる (⌘J)")
                Button("削除") { model.removeSelectedSection() }
                    .disabled(analysis.sections.count <= 1)
                    .help("このセクションを前のセクションに含める")
            }
            Button("このセクションの音声を書き出す…") { model.exportSelectionAudio() }

            Divider()
            SectionChordsView(section: section, analysis: analysis)
        }
    }

    private var barCount: Int {
        analysis.beatGrid.downbeats.filter { $0 >= section.start - 0.01 && $0 < section.end - 0.01 }.count
    }
}

/// セクション内のコード進行(作曲・分析の参考)。
private struct SectionChordsView: View {
    let section: Section
    let analysis: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("コード進行").font(.subheadline.weight(.semibold))
            let chords = analysis.chords.filter { $0.end > section.start + 0.01 && $0.start < section.end - 0.01 }
            if chords.isEmpty {
                Text("なし").foregroundStyle(.secondary)
            } else {
                Text(chords.map(symbol).joined(separator: " → "))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let key = analysis.key {
                    Text(chords.map { $0.chord.map { MusicTheory.romanNumeral(for: $0, in: key) } ?? "N.C." }.joined(separator: " → "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func symbol(_ segment: ChordSegment) -> String {
        segment.chord?.symbol(preferFlats: analysis.prefersFlats) ?? "N.C."
    }
}

// MARK: - Chord editor

private struct ChordEditor: View {
    @EnvironmentObject private var model: AudioDocumentModel
    let segment: ChordSegment
    let analysis: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("コード").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(segment.chord?.symbol(preferFlats: analysis.prefersFlats) ?? "N.C.")
                    .font(.title.weight(.semibold))
                if let chord = segment.chord, let key = analysis.key {
                    Text(MusicTheory.romanNumeral(for: chord, in: key))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    if !MusicTheory.isDiatonic(chord, in: key) {
                        Text("ノンダイアトニック")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                }
            }

            LabeledRow("ルート") {
                Picker("ルート", selection: Binding(
                    get: { segment.chord?.root ?? -1 },
                    set: { root in
                        let quality = segment.chord?.quality ?? .major
                        applyChord(root < 0 ? nil : Chord(root: root, quality: quality))
                    }
                )) {
                    Text("N.C.").tag(-1)
                    ForEach(0..<12, id: \.self) { pc in
                        Text(PitchClass.name(pc, preferFlats: analysis.prefersFlats)).tag(pc)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            LabeledRow("種類") {
                Picker("種類", selection: Binding(
                    get: { segment.chord?.quality ?? .major },
                    set: { quality in
                        applyChord(Chord(root: segment.chord?.root ?? analysis.key?.tonic ?? 0, quality: quality))
                    }
                )) {
                    ForEach(ChordQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName + (quality.suffix.isEmpty ? "" : " (\(quality.suffix))")).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            if let key = analysis.key {
                Text("\(key.name) のダイアトニック・コード").font(.subheadline.weight(.semibold))
                let triads = MusicTheory.diatonicTriads(in: key)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(triads, id: \.self) { chord in
                        Button {
                            applyChord(chord)
                        } label: {
                            VStack(spacing: 0) {
                                Text(chord.symbol(preferFlats: key.prefersFlats)).font(.callout.weight(.semibold))
                                Text(MusicTheory.romanNumeral(for: chord, in: key)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            LabeledRow("範囲") {
                Text("\(TimeFormatting.string(fromSeconds: segment.start)) – \(TimeFormatting.string(fromSeconds: segment.end))")
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Button("再生") { model.playSelection() }
                Toggle("ループ", isOn: $model.isLoopEnabled)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                Button("カーソルで分割") { model.splitChordAtCursor() }
                    .help("再生位置でこのコード区間を 2 つに分ける (⌥⌘K)")
                Button("次と結合") { model.mergeSelectionWithNext() }
                    .disabled(analysis.chords.last?.id == segment.id)
                Button("同じコードをまとめる") { model.edit("コードをまとめる") { $0.mergeRepeatedChords() } }
            }
        }
    }

    private func applyChord(_ chord: Chord?) {
        model.edit("コードを変更") { $0.setChord(id: segment.id, to: chord) }
    }
}

// MARK: - Section list

private struct SectionListView: View {
    @EnvironmentObject private var model: AudioDocumentModel

    var body: some View {
        if let analysis = model.analysis {
            List {
                ForEach(analysis.sections) { section in
                    Button {
                        model.select(.section(section.id))
                    } label: {
                        HStack(spacing: 8) {
                            Text(section.label)
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white)
                                .frame(minWidth: 22, minHeight: 18)
                                .background(SectionPalette.color(for: section.label), in: RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.name)
                                Text("\(TimeFormatting.string(fromSeconds: section.start, showMilliseconds: false)) – \(TimeFormatting.string(fromSeconds: section.end, showMilliseconds: false))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selectedSection?.id == section.id ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            .listStyle(.inset)
        } else {
            NotAnalyzedView().padding(14)
            Spacer()
        }
    }
}

// MARK: - Chord chart

private struct ChordChartView: View {
    @EnvironmentObject private var model: AudioDocumentModel
    @State private var showsRomanNumerals = true

    var body: some View {
        if let analysis = model.analysis {
            let chart = AnalysisExporter.chordChart(
                analysis: analysis,
                title: model.audio?.info.fileName ?? "",
                includeRomanNumerals: showsRomanNumerals
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("ローマ数字", isOn: $showsRomanNumerals)
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(chart, forType: .string)
                    }
                    Button("書き出し…") { model.export(.chordChart) }
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(chart)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(12)
        } else {
            NotAnalyzedView().padding(14)
            Spacer()
        }
    }
}

// MARK: - Notes

private struct NotesView: View {
    @EnvironmentObject private var model: AudioDocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("作曲・分析のメモ。プロジェクトに保存されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $model.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
    }
}

// MARK: - Components

private struct LabeledRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// Return キーかフォーカスが外れた時に値を確定するテキスト欄(1 文字ごとに取り消しを登録しないため)。
private struct CommitTextField: View {
    let placeholder: String
    let value: String
    let resetKey: String
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { draft = value }
            .onChange(of: resetKey) { _ in draft = value }
            .onChange(of: value) { newValue in
                if !focused { draft = newValue }
            }
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != value else { return }
        onCommit(trimmed)
    }
}

private func percent(_ value: Double) -> String {
    "\(Int((min(1, max(0, value)) * 100).rounded()))%"
}
