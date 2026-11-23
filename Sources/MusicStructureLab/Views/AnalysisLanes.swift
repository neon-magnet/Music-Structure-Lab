import AppKit
import MSLCore
import SwiftUI

/// セクションの記号ごとの色。
enum SectionPalette {
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.56, blue: 0.95),
        Color(red: 0.95, green: 0.55, blue: 0.20),
        Color(red: 0.30, green: 0.75, blue: 0.45),
        Color(red: 0.90, green: 0.35, blue: 0.55),
        Color(red: 0.60, green: 0.45, blue: 0.90),
        Color(red: 0.20, green: 0.70, blue: 0.75),
        Color(red: 0.85, green: 0.75, blue: 0.20),
        Color(red: 0.80, green: 0.30, blue: 0.25)
    ]

    static func color(for label: String) -> Color {
        let scalars = label.unicodeScalars.map { Int($0.value) }
        let index = scalars.reduce(0) { $0 &* 31 &+ $1 }
        if let first = label.unicodeScalars.first, label.count == 1, ("A"..."Z").contains(first) {
            return colors[Int(first.value - 65) % colors.count]
        }
        return colors[abs(index) % colors.count]
    }
}

/// 拍・小節線を描くための情報。
struct BeatMark: Equatable {
    var x: Double
    var isDownbeat: Bool
    var bar: Int?
}

/// セクションの帯。クリックで選択、境界のドラッグで長さを変える。
struct SectionLaneView: View {
    let sections: [Section]
    let viewport: WaveformViewport
    let sampleRate: Double
    let selectedID: Section.ID?
    let onSelect: (Section.ID) -> Void
    let onMoveBoundary: (Int, Double) -> Void
    let onFinishBoundary: () -> Void

    private enum DragMode {
        case boundary(Int)
        case select
    }

    @State private var dragMode: DragMode?
    @State private var isCursorResizing = false

    var body: some View {
        Canvas { context, size in
            for section in sections {
                let x0 = x(forTime: section.start)
                let x1 = x(forTime: section.end)
                guard x1 >= 0, x0 <= Double(size.width) else { continue }
                let rect = CGRect(x: CGFloat(x0), y: 2, width: CGFloat(max(1, x1 - x0)), height: size.height - 4)
                let color = SectionPalette.color(for: section.label)
                let selected = section.id == selectedID
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(selected ? 0.85 : 0.45)))
                if selected {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4), with: .color(.primary), lineWidth: 1.5)
                }
                if rect.width > 30 {
                    let text = Text("\(section.label)  \(section.name)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                    var clipped = context
                    clipped.clip(to: Path(rect.insetBy(dx: 4, dy: 0)))
                    clipped.draw(text, at: CGPoint(x: max(rect.minX, 0) + 6, y: rect.midY), anchor: .leading)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragMode == nil {
                        if let index = boundaryIndex(near: value.startLocation.x) {
                            dragMode = .boundary(index)
                        } else {
                            dragMode = .select
                        }
                    }
                    if case let .boundary(index) = dragMode {
                        onMoveBoundary(index, time(atX: value.location.x))
                    }
                }
                .onEnded { value in
                    switch dragMode {
                    case .boundary:
                        onFinishBoundary()
                    case .select, nil:
                        if abs(value.translation.width) < 4, let section = section(atX: value.location.x) {
                            onSelect(section.id)
                        }
                    }
                    dragMode = nil
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                let near = boundaryIndex(near: location.x) != nil
                if near != isCursorResizing {
                    isCursorResizing = near
                    (near ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                }
            case .ended:
                if isCursorResizing {
                    isCursorResizing = false
                    NSCursor.arrow.set()
                }
            }
        }
        .help("クリックで選択、境界をドラッグで調整")
        .accessibilityLabel("セクション")
    }

    private func x(forTime time: Double) -> Double {
        viewport.x(forFrame: time * sampleRate)
    }

    private func time(atX x: CGFloat) -> Double {
        sampleRate > 0 ? viewport.frame(atX: Double(x)) / sampleRate : 0
    }

    /// 境界 `index`(セクション index と index+1 の間)が x の近くにあれば返す。
    private func boundaryIndex(near x: CGFloat) -> Int? {
        guard sections.count > 1 else { return nil }
        for index in 0..<(sections.count - 1) {
            if abs(self.x(forTime: sections[index].end) - Double(x)) <= 5 {
                return index
            }
        }
        return nil
    }

    private func section(atX x: CGFloat) -> Section? {
        let t = time(atX: x)
        return sections.first { t >= $0.start && t < $0.end } ?? (t >= (sections.last?.end ?? 0) ? sections.last : nil)
    }
}

/// コードの帯。クリックで選択。
struct ChordLaneView: View {
    let chords: [ChordSegment]
    let key: MusicalKey?
    let viewport: WaveformViewport
    let sampleRate: Double
    let selectedID: ChordSegment.ID?
    let onSelect: (ChordSegment.ID) -> Void

    var body: some View {
        Canvas { context, size in
            let flats = key?.prefersFlats ?? false
            for segment in chords {
                let x0 = viewport.x(forFrame: segment.start * sampleRate)
                let x1 = viewport.x(forFrame: segment.end * sampleRate)
                guard x1 >= 0, x0 <= Double(size.width) else { continue }
                let rect = CGRect(x: CGFloat(x0), y: 2, width: CGFloat(max(1, x1 - x0)), height: size.height - 4)
                let selected = segment.id == selectedID
                let base: Color = segment.chord == nil ? .gray : .accentColor
                context.fill(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 3),
                             with: .color(base.opacity(selected ? 0.55 : (segment.chord == nil ? 0.12 : 0.2))))
                if selected {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(.primary), lineWidth: 1.5)
                }
                guard rect.width > 18 else { continue }
                var label = segment.chord?.symbol(preferFlats: flats) ?? "N.C."
                if rect.width > 64, let chord = segment.chord, let key {
                    label += "  " + MusicTheory.romanNumeral(for: chord, in: key)
                }
                var clipped = context
                clipped.clip(to: Path(rect.insetBy(dx: 2, dy: 0)))
                clipped.draw(
                    Text(label).font(.caption.monospacedDigit()).foregroundColor(.primary),
                    at: CGPoint(x: max(rect.minX, 0) + 4, y: rect.midY),
                    anchor: .leading
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onEnded { value in
                guard abs(value.translation.width) < 4, sampleRate > 0 else { return }
                let time = viewport.frame(atX: Double(value.location.x)) / sampleRate
                if let segment = chords.first(where: { time >= $0.start && time < $0.end }) {
                    onSelect(segment.id)
                }
            }
        )
        .help("クリックでコードを選択")
        .accessibilityLabel("コード")
    }
}
