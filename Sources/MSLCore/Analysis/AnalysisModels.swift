import Foundation

/// 音名(ピッチクラス)。0 = C, 1 = C#, ... 11 = B。
public enum PitchClass {
    public static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    public static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    public static func normalize(_ value: Int) -> Int {
        ((value % 12) + 12) % 12
    }

    /// 調に合わせて ♯/♭ 表記を選ぶ。調が無い時は ♯ 表記。
    public static func name(_ pitchClass: Int, preferFlats: Bool = false) -> String {
        let pc = normalize(pitchClass)
        return preferFlats ? flatNames[pc] : sharpNames[pc]
    }
}

public enum KeyMode: String, Codable, CaseIterable, Sendable {
    case major
    case minor
}

/// 調。
public struct MusicalKey: Codable, Equatable, Hashable, Sendable {
    public var tonic: Int
    public var mode: KeyMode

    public init(tonic: Int, mode: KeyMode) {
        self.tonic = PitchClass.normalize(tonic)
        self.mode = mode
    }

    /// ♭系の調か(表記に使う)。
    public var prefersFlats: Bool {
        let majorTonic = mode == .major ? tonic : PitchClass.normalize(tonic + 3)
        return [5, 10, 3, 8, 1].contains(majorTonic)
    }

    /// 調号の数。正なら ♯、負なら ♭(MIDI のキー署名と同じ表現)。
    public var sharpsOrFlats: Int {
        let majorTonic = mode == .major ? tonic : PitchClass.normalize(tonic + 3)
        let table = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]
        return table[majorTonic]
    }

    /// 例: "C major", "F# minor"
    public var name: String {
        "\(PitchClass.name(tonic, preferFlats: prefersFlats)) \(mode == .major ? "major" : "minor")"
    }

    /// 例: "C", "F#m"
    public var shortName: String {
        "\(PitchClass.name(tonic, preferFlats: prefersFlats))\(mode == .major ? "" : "m")"
    }

    public static let all: [MusicalKey] = KeyMode.allCases.flatMap { mode in
        (0..<12).map { MusicalKey(tonic: $0, mode: mode) }
    }
}

public enum ChordQuality: String, Codable, CaseIterable, Sendable {
    case major
    case minor
    case diminished
    case augmented
    case sus4
    case dominant7
    case major7
    case minor7

    /// ルートからの半音数。
    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .sus4: return [0, 5, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        }
    }

    public var suffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .diminished: return "dim"
        case .augmented: return "aug"
        case .sus4: return "sus4"
        case .dominant7: return "7"
        case .major7: return "maj7"
        case .minor7: return "m7"
        }
    }

    public var displayName: String {
        switch self {
        case .major: return "メジャー"
        case .minor: return "マイナー"
        case .diminished: return "ディミニッシュ"
        case .augmented: return "オーギュメント"
        case .sus4: return "サスフォー"
        case .dominant7: return "セブンス"
        case .major7: return "メジャーセブンス"
        case .minor7: return "マイナーセブンス"
        }
    }

    var isMinorLike: Bool {
        self == .minor || self == .minor7 || self == .diminished
    }
}

public struct Chord: Codable, Equatable, Hashable, Sendable {
    public var root: Int
    public var quality: ChordQuality

    public init(root: Int, quality: ChordQuality) {
        self.root = PitchClass.normalize(root)
        self.quality = quality
    }

    public func symbol(preferFlats: Bool = false) -> String {
        PitchClass.name(root, preferFlats: preferFlats) + quality.suffix
    }

    public var pitchClasses: [Int] {
        quality.intervals.map { PitchClass.normalize(root + $0) }
    }
}

/// コードが続く区間。`chord == nil` はノーコード (N.C.)。
public struct ChordSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var chord: Chord?

    public init(id: UUID = UUID(), start: Double, end: Double, chord: Chord?) {
        self.id = id
        self.start = start
        self.end = end
        self.chord = chord
    }

    public var duration: Double { end - start }
}

/// 楽曲のセクション(イントロ、A メロ、サビなど)。
public struct Section: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    /// 同じ素材の繰り返しに同じ記号を付ける (A, B, C...)。
    public var label: String
    /// 利用者が付ける名前(例: "サビ")。
    public var name: String

    public init(id: UUID = UUID(), start: Double, end: Double, label: String, name: String) {
        self.id = id
        self.start = start
        self.end = end
        self.label = label
        self.name = name
    }

    public var duration: Double { end - start }
}

/// 拍と小節。
public struct BeatGrid: Codable, Equatable, Sendable {
    /// 代表テンポ。
    public var bpm: Double
    /// 拍の時刻(秒)。昇順。
    public var beats: [Double]
    public var beatsPerBar: Int
    /// `beats` の中で最初の小節頭(ダウンビート)の位置。0..<beatsPerBar。
    public var downbeatOffset: Int

    public init(bpm: Double, beats: [Double], beatsPerBar: Int = 4, downbeatOffset: Int = 0) {
        self.bpm = bpm
        self.beats = beats
        self.beatsPerBar = max(1, beatsPerBar)
        self.downbeatOffset = IntMath.mod(downbeatOffset, self.beatsPerBar)
    }

    public func isDownbeat(_ index: Int) -> Bool {
        IntMath.mod(index - downbeatOffset, beatsPerBar) == 0
    }

    /// 拍 `index` が属する小節番号(1 始まり)。最初の小節頭より前の拍は 0(弱起)。
    public func barNumber(ofBeat index: Int) -> Int {
        let relative = index - downbeatOffset
        if relative < 0 { return 0 }
        return relative / beatsPerBar + 1
    }

    /// 小節頭の時刻。
    public var downbeats: [Double] {
        beats.indices.filter(isDownbeat).map { beats[$0] }
    }

    /// `time` 以前で最も近い拍の番号。
    public func beatIndex(atOrBefore time: Double) -> Int? {
        guard let first = beats.first, time >= first else { return nil }
        var low = 0
        var high = beats.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if beats[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

enum IntMath {
    static func mod(_ a: Int, _ n: Int) -> Int {
        ((a % n) + n) % n
    }
}

/// 解析結果一式。利用者の編集もこの値に反映して保存する。
public struct AnalysisResult: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var duration: Double
    public var beatGrid: BeatGrid
    /// テンポ推定の確からしさ (0...1)。
    public var tempoConfidence: Double
    public var key: MusicalKey?
    public var keyConfidence: Double
    public var chords: [ChordSegment]
    public var sections: [Section]

    public init(
        duration: Double,
        beatGrid: BeatGrid,
        tempoConfidence: Double,
        key: MusicalKey?,
        keyConfidence: Double,
        chords: [ChordSegment],
        sections: [Section]
    ) {
        self.version = Self.currentVersion
        self.duration = duration
        self.beatGrid = beatGrid
        self.tempoConfidence = tempoConfidence
        self.key = key
        self.keyConfidence = keyConfidence
        self.chords = chords
        self.sections = sections
    }

    public var prefersFlats: Bool { key?.prefersFlats ?? false }

    public func section(at time: Double) -> Section? {
        sections.first { time >= $0.start && time < $0.end } ?? (time >= duration ? sections.last : nil)
    }

    public func chordSegment(at time: Double) -> ChordSegment? {
        chords.first { time >= $0.start && time < $0.end }
    }
}
