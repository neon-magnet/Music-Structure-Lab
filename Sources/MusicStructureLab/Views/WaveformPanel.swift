import AppKit
import MSLCore
import SwiftUI

/// 波形 1 段ぶんの表示データ。
struct WaveformLane {
    let title: String
    let overview: WaveformOverview
    let samples: [Float]
    var color: Color = .accentColor
    /// ミュート中のパートなどを薄く描く。
    var opacity: Double = 1
}

/// 波形表示エリア(操作バー・時間軸・波形・全体ミニマップ)。
///
/// 操作:
/// - クリック: 再生位置を移動
/// - スペース: 再生 / 一時停止
/// - ドラッグ / 横スクロール / マウスホイール: 左右に移動
/// - ⌘ または ⌥ + スクロール、トラックパッドのピンチ: ポインタ位置を中心に拡大・縮小
/// - 下のミニマップをクリック・ドラッグ: その位置へ移動
struct WaveformPanel: View {
    let audio: DecodedAudio
    @EnvironmentObject private var model: AudioDocumentModel

    @State private var viewport: WaveformViewport
    @State private var hasFitted = false
    @State private var width: Double = 0
    @State private var hoverX: Double?
    @State private var dragOrigin: WaveformViewport?
    @State private var isPanning = false
    @State private var magnifyOrigin: WaveformViewport?
    @StateObject private var scrollMonitor = ScrollWheelMonitor()

    init(audio: DecodedAudio) {
        self.audio = audio
        _viewport = State(initialValue: WaveformViewport(totalFrames: audio.info.frameCount))
    }

    private var sampleRate: Double { audio.info.sampleRate }
    private var totalFrames: Int { audio.info.frameCount }
    private var cursorFrame: Int? { model.cursorFrame }

    private var lanes: [WaveformLane] {
        switch model.displayMode {
        case .mix:
            return [WaveformLane(title: "Mix", overview: audio.monoOverview, samples: audio.mono)]
        case .stems:
            guard let stems = model.stems else {
                return [WaveformLane(title: "Mix", overview: audio.monoOverview, samples: audio.mono)]
            }
            return StemKind.allCases.compactMap { kind -> WaveformLane? in
                guard let overview = stems.overviews[kind] else { return nil }
                let audible = model.stemMix.gain(for: kind) > 0
                return WaveformLane(
                    title: kind.displayName + (audible ? "" : "(消音中)"),
                    overview: overview,
                    samples: stems.channels(for: kind).first ?? [],
                    color: StemPalette.color(for: kind),
                    opacity: audible ? 1 : 0.3
                )
            }
        case .channels:
            return audio.channelOverviews.indices.map { index in
                WaveformLane(
                    title: Self.channelTitle(index, count: audio.channelOverviews.count),
                    overview: audio.channelOverviews[index],
                    samples: audio.channels[index]
                )
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    TimeRulerView(viewport: viewport, sampleRate: sampleRate)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                        .gesture(dragGesture)
                    Divider()
                    if let analysis = model.analysis {
                        SectionLaneView(
                            sections: analysis.sections,
                            viewport: viewport,
                            sampleRate: sampleRate,
                            selectedID: model.selectedSection?.id,
                            onSelect: { model.select(.section($0)) },
                            onMoveBoundary: { index, time in
                                model.previewEdit { $0.moveSectionBoundary(after: index, to: time) }
                            },
                            onFinishBoundary: { model.commitPreviewEdit("境界を移動") }
                        )
                        .frame(height: 30)
                        ChordLaneView(
                            chords: analysis.chords,
                            key: analysis.key,
                            viewport: viewport,
                            sampleRate: sampleRate,
                            selectedID: model.selectedChord?.id,
                            onSelect: { model.select(.chord($0)) }
                        )
                        .frame(height: 26)
                        Divider()
                    }
                    WaveformCanvasView(
                        lanes: lanes,
                        viewport: viewport,
                        cursorFrame: cursorFrame,
                        hoverX: hoverX,
                        beatMarks: beatMarks,
                        barLabelEvery: barLabelEvery,
                        highlight: model.selectionRange,
                        isLooping: model.isLoopEnabled
                    )
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(magnifyGesture)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location): hoverX = location.x
                    case .ended: hoverX = nil
                    }
                }
                .onAppear { updateWidth(geometry.size.width) }
                .onChange(of: geometry.size.width) { updateWidth($0) }
            }
            Divider()
            OverviewStripView(
                overview: audio.monoOverview,
                totalFrames: totalFrames,
                visibleStart: viewport.startFrame,
                visibleCount: viewport.visibleFrameCount(width: width),
                cursorFrame: cursorFrame,
                onSeek: { center(onFrame: $0) }
            )
            .frame(height: 44)
        }
        .onChange(of: model.cursorFrame) { frame in
            // 再生中は再生位置が画面外に出たらページ送りする。
            guard model.isPlaying, let frame, width > 0 else { return }
            viewport.follow(frame: Double(frame), width: width)
        }
        .onAppear {
            scrollMonitor.handler = { event in handleScroll(event) }
            scrollMonitor.start()
        }
        .onDisappear { scrollMonitor.stop() }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.returnToStart() } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("先頭へ")

            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .disabled(!model.canPlay)
            .help(model.isPlaying ? "一時停止 (スペース)" : "再生 (スペース)")

            Text("\(timeText(Double(cursorFrame ?? 0))) / \(TimeFormatting.string(fromSeconds: audio.info.duration))")
                .font(.callout)
                .monospacedDigit()

            if let barText {
                Text(barText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $model.isLoopEnabled) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("選択範囲をループ再生 (⌘L)")

            Toggle(isOn: $model.isClickEnabled) {
                Image(systemName: "metronome")
            }
            .toggleStyle(.button)
            .disabled(model.analysis == nil)
            .help("拍に合わせてクリック音を鳴らす (⌥⌘C)")

            Divider().frame(height: 18)

            Picker("表示", selection: $model.displayMode) {
                ForEach(WaveformDisplayMode.allCases.filter { $0 != .stems || model.stems != nil }) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("チャンネルごとに表示するか、全チャンネルを混ぜて表示するか")

            Divider().frame(height: 18)

            Button { zoomFromControls(by: 0.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("縮小 (⌘-)")

            Button { zoomFromControls(by: 2) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .help("拡大 (⌘+)")

            Button("全体表示") { viewport.fit(width: width) }
                .keyboardShortcut("0", modifiers: .command)
                .help("音源全体を表示 (⌘0)")

            Text(String(format: "×%.1f", viewport.zoomFactor(width: width)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .leading)

            Spacer(minLength: 8)

            Group {
                Text("ポインタ: \(hoverX.map { timeText(viewport.frame(atX: $0)) } ?? "—")")
                    .frame(minWidth: 130, alignment: .leading)
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Analysis overlay

    /// カーソル位置の小節と拍(例: "12小節 3拍")。
    private var barText: String? {
        guard let grid = model.analysis?.beatGrid, sampleRate > 0,
              let index = grid.beatIndex(atOrBefore: Double(cursorFrame ?? 0) / sampleRate)
        else { return nil }
        let bar = grid.barNumber(ofBeat: index)
        let beat = IntMathUI.mod(index - grid.downbeatOffset, grid.beatsPerBar) + 1
        return bar == 0 ? "弱起 \(beat)拍" : "\(bar)小節 \(beat)拍"
    }

    private var beatSpacingPoints: Double {
        guard let grid = model.analysis?.beatGrid, grid.bpm > 0, viewport.framesPerPoint > 0 else { return 0 }
        return 60 / grid.bpm * sampleRate / viewport.framesPerPoint
    }

    private var barLabelEvery: Int {
        guard let grid = model.analysis?.beatGrid else { return 1 }
        let barSpacing = beatSpacingPoints * Double(grid.beatsPerBar)
        guard barSpacing > 0 else { return 1 }
        let every = Int((28 / barSpacing).rounded(.up))
        // 1, 2, 4, 8, 16... に丸める
        var value = 1
        while value < every { value *= 2 }
        return value
    }

    private var beatMarks: [BeatMark] {
        guard let grid = model.analysis?.beatGrid, sampleRate > 0, width > 0 else { return [] }
        let spacing = beatSpacingPoints
        let showBeats = spacing >= 6
        guard spacing * Double(grid.beatsPerBar) >= 4 else { return [] }
        let startTime = viewport.startFrame / sampleRate
        let endTime = (viewport.startFrame + viewport.visibleFrameCount(width: width)) / sampleRate
        var index = grid.beatIndex(atOrBefore: startTime) ?? 0
        var marks = [BeatMark]()
        while index < grid.beats.count, grid.beats[index] <= endTime {
            let isDownbeat = grid.isDownbeat(index)
            if isDownbeat || showBeats {
                marks.append(BeatMark(
                    x: viewport.x(forFrame: grid.beats[index] * sampleRate),
                    isDownbeat: isDownbeat,
                    bar: isDownbeat ? grid.barNumber(ofBeat: index) : nil
                ))
            }
            index += 1
        }
        return marks
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = viewport
                    isPanning = false
                }
                if !isPanning, abs(value.translation.width) > 3 {
                    isPanning = true
                }
                if isPanning, var moved = dragOrigin {
                    moved.pan(byPoints: -value.translation.width, width: width)
                    viewport = moved
                }
            }
            .onEnded { value in
                if !isPanning {
                    setCursor(atX: value.location.x)
                }
                dragOrigin = nil
                isPanning = false
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if magnifyOrigin == nil { magnifyOrigin = viewport }
                guard var zoomed = magnifyOrigin else { return }
                zoomed.zoom(by: Double(scale), anchorX: hoverX ?? width / 2, width: width)
                viewport = zoomed
            }
            .onEnded { _ in magnifyOrigin = nil }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let hoverX, width > 0 else { return false }
        let precise = event.hasPreciseScrollingDeltas
        let dx = Double(event.scrollingDeltaX)
        let dy = Double(event.scrollingDeltaY)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let amount = precise ? dy * 0.01 : dy * 0.1
            viewport.zoom(by: exp(amount), anchorX: hoverX, width: width)
        } else {
            // マウスホイールの縦回転も横移動として扱う。
            let delta = abs(dx) >= abs(dy) ? dx : dy
            let points = precise ? delta : delta * 12
            viewport.pan(byPoints: -points, width: width)
        }
        return true
    }

    // MARK: - Helpers

    private func updateWidth(_ newWidth: Double) {
        guard newWidth > 0 else { return }
        let wasFit = width > 0 && viewport.zoomFactor(width: width) <= 1.0001
        width = newWidth
        if !hasFitted || wasFit {
            viewport.fit(width: newWidth)
            hasFitted = true
        } else {
            viewport.clamp(width: newWidth)
        }
    }

    private func zoomFromControls(by factor: Double) {
        var anchor = width / 2
        if let cursorFrame {
            let x = viewport.x(forFrame: Double(cursorFrame))
            if x >= 0, x <= width { anchor = x }
        }
        viewport.zoom(by: factor, anchorX: anchor, width: width)
    }

    private func setCursor(atX x: Double) {
        guard totalFrames > 0 else { return }
        model.seek(to: Int(viewport.frame(atX: x).rounded()))
    }

    private func center(onFrame frame: Double) {
        viewport.scroll(toStartFrame: frame - viewport.visibleFrameCount(width: width) / 2, width: width)
    }

    private func timeText(_ frame: Double) -> String {
        TimeFormatting.string(fromSeconds: sampleRate > 0 ? frame / sampleRate : 0)
    }

    static func channelTitle(_ index: Int, count: Int) -> String {
        if count == 2 { return index == 0 ? "L" : "R" }
        if count == 1 { return "Mono" }
        return "Ch \(index + 1)"
    }
}

/// ウィンドウ内のスクロールホイール/トラックパッドのイベントを拾う。
/// SwiftUI だけでは macOS のスクロールイベントを直接受け取れないため、AppKit のローカルモニタを使う。
@MainActor
final class ScrollWheelMonitor: ObservableObject {
    /// true を返すとイベントを消費する。
    var handler: (@MainActor (NSEvent) -> Bool)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // ローカルモニタはメインスレッドで呼ばれる。
            let consumed = MainActor.assumeIsolated { self?.handler?(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

enum IntMathUI {
    static func mod(_ a: Int, _ n: Int) -> Int {
        ((a % n) + n) % n
    }
}
