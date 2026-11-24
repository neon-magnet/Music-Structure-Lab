import Foundation

public enum MusicTheory {
    private static let degreeNames = ["I", "♭II", "II", "♭III", "III", "IV", "♭V", "V", "♭VI", "VI", "♭VII", "VII"]

    /// 調の主音を基準にしたローマ数字表記(例: C major で Am → "vi"、G7 → "V7")。
    /// マイナーキーでも主音を I とする(Am で C → "♭III")。
    public static func romanNumeral(for chord: Chord, in key: MusicalKey) -> String {
        let degree = PitchClass.normalize(chord.root - key.tonic)
        var numeral = degreeNames[degree]
        if chord.quality.isMinorLike {
            numeral = numeral.lowercased()
        }
        switch chord.quality {
        case .major, .minor: break
        case .diminished: numeral += "°"
        case .augmented: numeral += "+"
        case .sus4: numeral += "sus4"
        case .dominant7: numeral += "7"
        case .major7: numeral += "maj7"
        case .minor7: numeral += "7"
        }
        return numeral
    }

    /// 調のダイアトニック・コード(三和音)。作曲時の候補として使う。
    public static func diatonicTriads(in key: MusicalKey) -> [Chord] {
        let steps: [Int]
        let qualities: [ChordQuality]
        switch key.mode {
        case .major:
            steps = [0, 2, 4, 5, 7, 9, 11]
            qualities = [.major, .minor, .minor, .major, .major, .minor, .diminished]
        case .minor:
            steps = [0, 2, 3, 5, 7, 8, 10]
            qualities = [.minor, .diminished, .major, .minor, .minor, .major, .major]
        }
        return zip(steps, qualities).map { Chord(root: key.tonic + $0, quality: $1) }
    }

    /// コードが調の音階音だけでできているか。
    public static func isDiatonic(_ chord: Chord, in key: MusicalKey) -> Bool {
        let scale: [Int] = key.mode == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
        let pcs = Set(scale.map { PitchClass.normalize(key.tonic + $0) })
        return chord.pitchClasses.allSatisfy(pcs.contains)
    }
}
