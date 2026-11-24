import Foundation

/// 解析結果を Standard MIDI File (format 1) に書き出す。
///
/// - トラック 1 (Conductor): 拍に合わせたテンポマップ、拍子、調号、セクションのマーカー
/// - トラック 2 (Chords): コードの構成音(ベースにルート)とコード名のテキスト
///
/// テンポマップは検出した拍ごとにテンポを置くので、DAW に読み込むと拍・小節線が音源と揃う。
public enum MIDIExporter {
    public static let ticksPerBeat = 480

    public static func data(for analysis: AnalysisResult, title: String) -> Data {
        let map = TimeMap(grid: analysis.beatGrid, duration: analysis.duration)
        var conductor = [Event]()
        conductor.append(Event(tick: 0, order: 0, bytes: meta(0x03, Array(title.utf8))))
        conductor.append(Event(tick: 0, order: 1, bytes: meta(0x58, [
            UInt8(clamping: analysis.beatGrid.beatsPerBar), 2, 24, 8
        ])))
        if let key = analysis.key {
            conductor.append(Event(tick: 0, order: 1, bytes: meta(0x59, [
                UInt8(bitPattern: Int8(clamping: key.sharpsOrFlats)),
                key.mode == .minor ? 1 : 0
            ])))
        }
        for change in map.tempoChanges() {
            let microseconds = UInt32(clamping: Int((change.secondsPerBeat * 1_000_000).rounded()))
            conductor.append(Event(tick: change.tick, order: 2, bytes: meta(0x51, [
                UInt8((microseconds >> 16) & 0xFF), UInt8((microseconds >> 8) & 0xFF), UInt8(microseconds & 0xFF)
            ])))
        }
        for section in analysis.sections {
            conductor.append(Event(tick: map.tick(for: section.start), order: 3, bytes: meta(0x06, Array(section.name.utf8))))
        }

        var chordTrack = [Event]()
        chordTrack.append(Event(tick: 0, order: 0, bytes: meta(0x03, Array("Chords".utf8))))
        let flats = analysis.prefersFlats
        for segment in analysis.chords {
            guard let chord = segment.chord else { continue }
            let start = map.tick(for: segment.start)
            let end = max(start + 1, map.tick(for: segment.end))
            chordTrack.append(Event(tick: start, order: 2, bytes: meta(0x01, Array(chord.symbol(preferFlats: flats).utf8))))
            var notes = [36 + chord.root]
            notes.append(contentsOf: chord.quality.intervals.map { 60 + chord.root + $0 })
            for note in notes {
                chordTrack.append(Event(tick: start, order: 3, bytes: [0x90, UInt8(note), 80]))
                chordTrack.append(Event(tick: end, order: 1, bytes: [0x80, UInt8(note), 0]))
            }
        }

        var data = Data()
        data.append(contentsOf: Array("MThd".utf8))
        data.append(contentsOf: be32(6))
        data.append(contentsOf: be16(1)) // format 1
        data.append(contentsOf: be16(2)) // tracks
        data.append(contentsOf: be16(UInt16(ticksPerBeat)))
        data.append(track(conductor))
        data.append(track(chordTrack))
        return data
    }

    // MARK: - Time map

    /// 秒と MIDI ティックの対応。拍 i がティック (i + pad) * ticksPerBeat になる。
    struct TimeMap {
        let beats: [Double]
        let pad: Int
        let fallbackPeriod: Double

        init(grid: BeatGrid, duration: Double) {
            beats = grid.beats
            fallbackPeriod = grid.bpm > 0 ? 60 / grid.bpm : 0.5
            guard let first = beats.first, first > 0.01 else {
                pad = 0
                return
            }
            // 最初の拍より前を何拍ぶんとみなすか。小節頭が MIDI の小節線に揃うように選ぶ。
            let nominal = max(1, Int((first / fallbackPeriod).rounded()))
            let bar = grid.beatsPerBar
            var best = nominal
            var bestDistance = Int.max
            for candidate in max(1, nominal - bar)...(nominal + bar) {
                guard IntMath.mod(grid.downbeatOffset + candidate, bar) == 0 else { continue }
                let distance = abs(candidate - nominal)
                if distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
            }
            pad = best
        }

        func tick(for time: Double) -> Int {
            let ppq = Double(MIDIExporter.ticksPerBeat)
            guard let first = beats.first else {
                return Int((time / fallbackPeriod * ppq).rounded())
            }
            if time <= first {
                guard pad > 0, first > 0 else { return 0 }
                return Int((max(0, time) / first * Double(pad) * ppq).rounded())
            }
            if beats.count == 1 || time >= beats[beats.count - 1] {
                let last = beats.count - 1
                let period = beats.count > 1 ? beats[last] - beats[last - 1] : fallbackPeriod
                let position = Double(last + pad) + (time - beats[last]) / max(period, 1e-6)
                return Int((position * ppq).rounded())
            }
            var low = 0
            var high = beats.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if beats[mid] <= time { low = mid } else { high = mid }
            }
            let fraction = (time - beats[low]) / max(beats[high] - beats[low], 1e-6)
            return Int(((Double(low + pad) + fraction) * ppq).rounded())
        }

        func tempoChanges() -> [(tick: Int, secondsPerBeat: Double)] {
            var result = [(tick: Int, secondsPerBeat: Double)]()
            if pad > 0, let first = beats.first {
                result.append((0, first / Double(pad)))
            }
            for i in beats.indices {
                let period = i + 1 < beats.count
                    ? beats[i + 1] - beats[i]
                    : (beats.count > 1 ? beats[i] - beats[i - 1] : fallbackPeriod)
                result.append(((i + pad) * MIDIExporter.ticksPerBeat, max(period, 0.05)))
            }
            if result.isEmpty {
                result.append((0, fallbackPeriod))
            }
            return result
        }
    }

    // MARK: - Encoding

    struct Event {
        var tick: Int
        /// 同じティックでの順序(小さいほど先)。
        var order: Int
        var bytes: [UInt8]
    }

    static func meta(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [0xFF, type] + variableLength(payload.count) + payload
    }

    static func track(_ events: [Event]) -> Data {
        let sorted = events.enumerated().sorted { lhs, rhs in
            if lhs.element.tick != rhs.element.tick { return lhs.element.tick < rhs.element.tick }
            if lhs.element.order != rhs.element.order { return lhs.element.order < rhs.element.order }
            return lhs.offset < rhs.offset
        }.map(\.element)
        var body = [UInt8]()
        var previousTick = 0
        for event in sorted {
            let tick = max(previousTick, event.tick)
            body.append(contentsOf: variableLength(tick - previousTick))
            body.append(contentsOf: event.bytes)
            previousTick = tick
        }
        body.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])
        var data = Data(Array("MTrk".utf8))
        data.append(contentsOf: be32(UInt32(body.count)))
        data.append(contentsOf: body)
        return data
    }

    /// MIDI の可変長数値。
    static func variableLength(_ value: Int) -> [UInt8] {
        var value = max(0, value)
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8((value & 0x7F) | 0x80), at: 0)
            value >>= 7
        }
        return bytes
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
