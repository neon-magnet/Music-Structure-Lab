import Foundation

/// 解析結果の編集操作。UI から呼び、取り消しは呼び出し側で前の値を保持して行う。
/// いずれも、セクション・コードが時間順に隙間なく並んでいる状態を保つ。
extension AnalysisResult {
    /// 区間の最小の長さ(秒)。
    public static let minimumSegmentLength = 0.25

    // MARK: - Sections

    public func sectionIndex(id: Section.ID) -> Int? {
        sections.firstIndex { $0.id == id }
    }

    /// `time` でセクションを 2 つに分ける。新しい(後ろの)セクションの ID を返す。
    @discardableResult
    public mutating func splitSection(at time: Double) -> Section.ID? {
        guard let index = sections.firstIndex(where: { time > $0.start && time < $0.end }) else { return nil }
        let original = sections[index]
        guard time - original.start >= Self.minimumSegmentLength,
              original.end - time >= Self.minimumSegmentLength else { return nil }
        sections[index].end = time
        let new = Section(start: time, end: original.end, label: original.label, name: original.name)
        sections.insert(new, at: index + 1)
        return new.id
    }

    /// セクションを次のセクションと結合する(名前と記号は前のセクションのもの)。
    @discardableResult
    public mutating func mergeSectionWithNext(id: Section.ID) -> Bool {
        guard let index = sectionIndex(id: id), index + 1 < sections.count else { return false }
        sections[index].end = sections[index + 1].end
        sections.remove(at: index + 1)
        return true
    }

    /// セクションを削除し、その範囲を前のセクション(先頭なら次のセクション)に含める。
    @discardableResult
    public mutating func removeSection(id: Section.ID) -> Bool {
        guard sections.count > 1, let index = sectionIndex(id: id) else { return false }
        if index > 0 {
            sections[index - 1].end = sections[index].end
        } else {
            sections[1].start = sections[0].start
        }
        sections.remove(at: index)
        return true
    }

    /// セクション `index` と `index + 1` の境界を `time` に動かす。動かした後の時刻を返す。
    @discardableResult
    public mutating func moveSectionBoundary(after index: Int, to time: Double) -> Double? {
        guard index >= 0, index + 1 < sections.count else { return nil }
        let lower = sections[index].start + Self.minimumSegmentLength
        let upper = sections[index + 1].end - Self.minimumSegmentLength
        guard lower <= upper else { return nil }
        let clamped = min(max(time, lower), upper)
        sections[index].end = clamped
        sections[index + 1].start = clamped
        return clamped
    }

    public mutating func renameSection(id: Section.ID, to name: String) {
        guard let index = sectionIndex(id: id) else { return }
        sections[index].name = name
    }

    public mutating func setSectionLabel(id: Section.ID, to label: String) {
        guard let index = sectionIndex(id: id) else { return }
        sections[index].label = label
    }

    /// 同じ記号のセクションすべての名前を変える(例: B をすべて「サビ」に)。
    public mutating func renameSections(withLabel label: String, to name: String) {
        for index in sections.indices where sections[index].label == label {
            sections[index].name = name
        }
    }

    /// セクションの境界を最も近い小節頭に揃える。
    public mutating func snapSectionsToBars() {
        let downbeats = beatGrid.downbeats
        guard !downbeats.isEmpty, sections.count > 1 else { return }
        for index in 0..<(sections.count - 1) {
            let boundary = sections[index].end
            guard let nearest = downbeats.min(by: { abs($0 - boundary) < abs($1 - boundary) }) else { continue }
            if nearest - sections[index].start >= Self.minimumSegmentLength,
               sections[index + 1].end - nearest >= Self.minimumSegmentLength {
                sections[index].end = nearest
                sections[index + 1].start = nearest
            }
        }
    }

    // MARK: - Chords

    public func chordIndex(id: ChordSegment.ID) -> Int? {
        chords.firstIndex { $0.id == id }
    }

    public mutating func setChord(id: ChordSegment.ID, to chord: Chord?) {
        guard let index = chordIndex(id: id) else { return }
        chords[index].chord = chord
    }

    @discardableResult
    public mutating func splitChord(at time: Double) -> ChordSegment.ID? {
        guard let index = chords.firstIndex(where: { time > $0.start && time < $0.end }) else { return nil }
        let original = chords[index]
        guard time - original.start >= Self.minimumSegmentLength,
              original.end - time >= Self.minimumSegmentLength else { return nil }
        chords[index].end = time
        let new = ChordSegment(start: time, end: original.end, chord: original.chord)
        chords.insert(new, at: index + 1)
        return new.id
    }

    @discardableResult
    public mutating func mergeChordWithNext(id: ChordSegment.ID) -> Bool {
        guard let index = chordIndex(id: id), index + 1 < chords.count else { return false }
        chords[index].end = chords[index + 1].end
        chords.remove(at: index + 1)
        return true
    }

    /// 隣り合う同じコードの区間をまとめる。
    public mutating func mergeRepeatedChords() {
        var merged = [ChordSegment]()
        for segment in chords {
            if let last = merged.last, last.chord == segment.chord {
                merged[merged.count - 1].end = segment.end
            } else {
                merged.append(segment)
            }
        }
        chords = merged
    }

    /// すべてのコードを `semitones` 半音移調する。調も合わせて動かす。
    public mutating func transpose(by semitones: Int) {
        for index in chords.indices {
            if let chord = chords[index].chord {
                chords[index].chord = Chord(root: chord.root + semitones, quality: chord.quality)
            }
        }
        if let key {
            self.key = MusicalKey(tonic: key.tonic + semitones, mode: key.mode)
        }
    }

    // MARK: - Tempo and meter

    /// テンポを指定し、`anchor` の拍(既定は最初の拍)を基準に一定テンポの拍を作り直す。
    public mutating func setTempo(_ bpm: Double, anchor: Double? = nil) {
        guard bpm >= 20, bpm <= 400 else { return }
        let start = anchor ?? beatGrid.beats.first ?? 0
        let downbeatTime = beatGrid.downbeats.first
        let beats = MusicAnalyzer.uniformBeats(bpm: bpm, start: start, duration: duration)
        var offset = 0
        if let downbeatTime, let nearest = beats.indices.min(by: { abs(beats[$0] - downbeatTime) < abs(beats[$1] - downbeatTime) }) {
            offset = nearest % beatGrid.beatsPerBar
        }
        beatGrid = BeatGrid(bpm: bpm, beats: beats, beatsPerBar: beatGrid.beatsPerBar, downbeatOffset: offset)
    }

    /// 拍子(1 小節の拍数)を変える。
    public mutating func setBeatsPerBar(_ value: Int) {
        guard value >= 1, value <= 16 else { return }
        beatGrid = BeatGrid(
            bpm: beatGrid.bpm,
            beats: beatGrid.beats,
            beatsPerBar: value,
            downbeatOffset: beatGrid.downbeatOffset % value
        )
    }

    /// 小節頭を `delta` 拍ずらす。
    public mutating func shiftDownbeat(by delta: Int) {
        beatGrid.downbeatOffset = IntMath.mod(beatGrid.downbeatOffset + delta, beatGrid.beatsPerBar)
    }

    /// 拍全体を `seconds` 秒ずらす(拍の位置の微調整)。
    public mutating func nudgeBeats(by seconds: Double) {
        let shifted = beatGrid.beats.map { $0 + seconds }
        let droppedAtStart = shifted.prefix { $0 < 0 }.count
        beatGrid.beats = shifted.filter { $0 >= 0 && $0 < duration }
        beatGrid.downbeatOffset = IntMath.mod(beatGrid.downbeatOffset - droppedAtStart, beatGrid.beatsPerBar)
    }

    public mutating func setKey(_ key: MusicalKey?) {
        self.key = key
    }
}
