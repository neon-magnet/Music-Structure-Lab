import MSLCore
import SwiftUI

/// 波形本体の描画。
///
/// 1 画素あたり 1 サンプル以上ある時は多段解像度のピーク(min/max)を縦線で描き、
/// それより拡大した時は個々のサンプルを結ぶ折れ線(さらに拡大すると点)で描く。
struct WaveformCanvasView: View {
    let lanes: [WaveformLane]
    let viewport: WaveformViewport
    let cursorFrame: Int?
    let hoverX: Double?
    var beatMarks: [BeatMark] = []
    /// 小節番号を何小節ごとに表示するか。
    var barLabelEvery = 1
    /// 選択範囲(フレーム)。
    var highlight: Range<Int>?
    var isLooping = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            guard !lanes.isEmpty, size.width > 0, size.height > 0 else { return }
            drawHighlight(context: context, size: size)
            drawBeats(context: context, size: size)
            let laneHeight = size.height / CGFloat(lanes.count)
            for (index, lane) in lanes.enumerated() {
                let rect = CGRect(x: 0, y: CGFloat(index) * laneHeight, width: size.width, height: laneHeight)
                drawLane(lane, in: rect, context: context)
                if index > 0 {
                    context.fill(
                        Path(CGRect(x: 0, y: rect.minY, width: size.width, height: 1)),
                        with: .color(Color(nsColor: .separatorColor))
                    )
                }
            }
            drawMarkers(context: context, size: size)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement()
        .accessibilityLabel("波形")
    }

    private func drawLane(_ lane: WaveformLane, in rect: CGRect, context: GraphicsContext) {
        var context = context
        context.clip(to: Path(rect))

        let scale = max(1, displayScale)
        let pixel = 1 / scale
        let midY = rect.midY
        let amplitude = rect.height / 2 * 0.92
        let waveColor = Color.accentColor

        // 0 の基準線と ±1.0 の目安線
        context.fill(Path(CGRect(x: 0, y: midY - pixel / 2, width: rect.width, height: pixel)),
                     with: .color(.secondary.opacity(0.35)))
        for guideY in [midY - amplitude, midY + amplitude] {
            context.fill(Path(CGRect(x: 0, y: guideY, width: rect.width, height: pixel)),
                         with: .color(.secondary.opacity(0.12)))
        }

        func y(for sample: Float) -> CGFloat {
            midY - CGFloat(min(max(sample, -1), 1)) * amplitude
        }

        if viewport.framesPerPoint >= 1 {
            let columns = Int((rect.width * scale).rounded(.up))
            let peaks = lane.overview.columns(
                startSample: viewport.startFrame,
                samplesPerColumn: viewport.framesPerPoint / Double(scale),
                columns: columns,
                samples: lane.samples
            )
            var path = Path()
            for (column, peak) in peaks.enumerated() where !peak.isEmpty {
                let top = y(for: peak.max)
                let bottom = y(for: peak.min)
                path.addRect(CGRect(
                    x: CGFloat(column) * pixel,
                    y: top,
                    width: pixel,
                    height: max(bottom - top, pixel)
                ))
            }
            context.fill(path, with: .color(waveColor))
        } else if !lane.samples.isEmpty {
            let first = max(0, Int(viewport.startFrame.rounded(.down)))
            let lastVisible = viewport.startFrame + viewport.visibleFrameCount(width: Double(rect.width))
            let last = min(lane.samples.count - 1, Int(lastVisible.rounded(.up)))
            guard first <= last else { return }
            var line = Path()
            for frame in first...last {
                let point = CGPoint(x: viewport.x(forFrame: Double(frame)), y: y(for: lane.samples[frame]))
                if frame == first {
                    line.move(to: point)
                } else {
                    line.addLine(to: point)
                }
            }
            context.stroke(line, with: .color(waveColor), lineWidth: 1.5)

            // 1 サンプルが 6pt 以上の幅になったら、サンプル点も描く。
            if viewport.framesPerPoint <= 1.0 / 6.0 {
                var dots = Path()
                for frame in first...last {
                    let center = CGPoint(x: viewport.x(forFrame: Double(frame)), y: y(for: lane.samples[frame]))
                    dots.addEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
                }
                context.fill(dots, with: .color(waveColor))
            }
        }

        context.draw(
            Text(lane.title).font(.caption.weight(.semibold)).foregroundColor(.secondary),
            at: CGPoint(x: rect.minX + 8, y: rect.minY + 6),
            anchor: .topLeading
        )
    }

    private func drawHighlight(context: GraphicsContext, size: CGSize) {
        guard let highlight else { return }
        let x0 = CGFloat(viewport.x(forFrame: Double(highlight.lowerBound)))
        let x1 = CGFloat(viewport.x(forFrame: Double(highlight.upperBound)))
        guard x1 >= 0, x0 <= size.width else { return }
        let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
        context.fill(Path(rect), with: .color(Color.accentColor.opacity(isLooping ? 0.14 : 0.07)))
        if isLooping {
            for edge in [x0, x1] {
                context.fill(Path(CGRect(x: edge - 0.5, y: 0, width: 1, height: size.height)), with: .color(Color.accentColor.opacity(0.7)))
            }
        }
    }

    private func drawBeats(context: GraphicsContext, size: CGSize) {
        guard !beatMarks.isEmpty else { return }
        var beats = Path()
        var bars = Path()
        for mark in beatMarks {
            let rect = CGRect(x: CGFloat(mark.x), y: 0, width: 1, height: size.height)
            if mark.isDownbeat {
                bars.addRect(rect)
                if let bar = mark.bar, bar > 0, (bar - 1) % max(1, barLabelEvery) == 0 {
                    context.draw(
                        Text("\(bar)").font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                        at: CGPoint(x: CGFloat(mark.x) + 3, y: size.height - 3),
                        anchor: .bottomLeading
                    )
                }
            } else {
                beats.addRect(rect)
            }
        }
        context.fill(beats, with: .color(.secondary.opacity(0.12)))
        context.fill(bars, with: .color(.secondary.opacity(0.4)))
    }

    private func drawMarkers(context: GraphicsContext, size: CGSize) {
        if let hoverX, hoverX >= 0, hoverX <= Double(size.width) {
            context.fill(
                Path(CGRect(x: CGFloat(hoverX), y: 0, width: 1, height: size.height)),
                with: .color(.primary.opacity(0.3))
            )
        }
        if let cursorFrame {
            let x = CGFloat(viewport.x(forFrame: Double(cursorFrame)))
            if x >= -1, x <= size.width + 1 {
                context.fill(
                    Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)),
                    with: .color(.orange)
                )
            }
        }
    }
}

/// 時間軸の目盛り。
struct TimeRulerView: View {
    let viewport: WaveformViewport
    let sampleRate: Double

    var body: some View {
        Canvas { context, size in
            guard sampleRate > 0, viewport.framesPerPoint > 0, size.width > 0 else { return }
            let secondsPerPoint = viewport.framesPerPoint / sampleRate
            let majorStep = TimeFormatting.rulerStep(minimumSpacing: 90 * secondsPerPoint)
            let minorStep = majorStep / 5
            let startSeconds = viewport.startFrame / sampleRate
            let endSeconds = startSeconds + Double(size.width) * secondsPerPoint
            let firstTick = Int((startSeconds / minorStep).rounded(.down))
            let lastTick = Int((endSeconds / minorStep).rounded(.up))
            guard lastTick >= firstTick else { return }

            var ticks = Path()
            for tick in firstTick...lastTick {
                let seconds = Double(tick) * minorStep
                let x = CGFloat(viewport.x(forFrame: seconds * sampleRate))
                guard x >= -1, x <= size.width + 1 else { continue }
                let isMajor = tick % 5 == 0
                let height: CGFloat = isMajor ? 10 : 4
                ticks.addRect(CGRect(x: x, y: size.height - height, width: 1, height: height))
                if isMajor {
                    let label = TimeFormatting.string(fromSeconds: seconds, showMilliseconds: majorStep < 1)
                    context.draw(
                        Text(label).font(.caption2).monospacedDigit().foregroundColor(.secondary),
                        at: CGPoint(x: x + 3, y: 3),
                        anchor: .topLeading
                    )
                }
            }
            context.fill(ticks, with: .color(.secondary))
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityHidden(true)
    }
}

/// 音源全体の縮小表示。現在の表示範囲を枠で示し、クリック・ドラッグでその位置へ移動する。
struct OverviewStripView: View {
    let overview: WaveformOverview
    let totalFrames: Int
    let visibleStart: Double
    let visibleCount: Double
    let cursorFrame: Int?
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard totalFrames > 0, size.width > 0 else { return }
                let columns = Int(size.width)
                let width = Double(size.width)
                let framesPerColumn = Double(totalFrames) / width
                let peaks = overview.columns(
                    startSample: 0,
                    samplesPerColumn: framesPerColumn,
                    columns: columns,
                    samples: nil
                )
                let midY = size.height / 2
                let amplitude = size.height / 2 * 0.85
                var path = Path()
                for (column, peak) in peaks.enumerated() where !peak.isEmpty {
                    let top = midY - CGFloat(min(max(peak.max, -1), 1)) * amplitude
                    let bottom = midY - CGFloat(min(max(peak.min, -1), 1)) * amplitude
                    path.addRect(CGRect(x: CGFloat(column), y: top, width: 1, height: max(bottom - top, 1)))
                }
                context.fill(path, with: .color(.secondary.opacity(0.6)))

                let x0 = CGFloat(visibleStart / Double(totalFrames) * width)
                let x1 = CGFloat((visibleStart + visibleCount) / Double(totalFrames) * width)
                let window = CGRect(x: x0, y: 1, width: max(x1 - x0, 2), height: size.height - 2)
                context.fill(Path(window), with: .color(Color.accentColor.opacity(0.15)))
                context.stroke(Path(window), with: .color(Color.accentColor), lineWidth: 1)

                if let cursorFrame {
                    let x = CGFloat(Double(cursorFrame) / Double(totalFrames) * width)
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.orange))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard geometry.size.width > 0 else { return }
                    let ratio = min(max(Double(value.location.x / geometry.size.width), 0), 1)
                    onSeek(ratio * Double(totalFrames))
                }
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("全体表示")
    }
}
