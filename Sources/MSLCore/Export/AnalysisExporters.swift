import Foundation

/// 書き出しに使う音源の情報。
public struct ExportSource: Codable, Equatable, Sendable {
    public var fileName: String
    public var duration: Double
    public var sampleRate: Double
    public var channelCount: Int

    public init(fileName: String, duration: Double, sampleRate: Double, channelCount: Int) {
        self.fileName = fileName
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public init(info: AudioFileInfo) {
        self.init(fileName: info.fileName, duration: info.duration, sampleRate: info.sampleRate, channelCount: info.channelCount)
    }
}

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json
    case csv
    case midi
    case audacityLabels
    case chordChart

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .json: return "解析結果 (JSON)"
        case .csv: return "表形式 (CSV)"
        case .midi: return "MIDI (テンポマップ・マーカー・コード)"
        case .audacityLabels: return "セクションのラベル (Audacity 形式)"
        case .chordChart: return "コード譜 (テキスト)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .json: return "json"
        case .csv: return "csv"
        case .midi: return "mid"
        case .audacityLabels: return "txt"
        case .chordChart: return "txt"
        }
    }

    public var fileNameSuffix: String {
        switch self {
        case .json: return "-analysis"
        case .csv: return "-analysis"
        case .midi: return ""
        case .audacityLabels: return "-sections"
        case .chordChart: return "-chords"
        }
    }
}

public enum AnalysisExporter {
    public static func data(_ format: ExportFormat, analysis: AnalysisResult, source: ExportSource) throws -> Data {
        switch format {
        case .json: return try json(analysis: analysis, source: source)
        case .csv: return Data(csv(analysis: analysis).utf8)
        case .midi: return MIDIExporter.data(for: analysis, title: source.fileName)
        case .audacityLabels: return Data(audacityLabels(analysis: analysis).utf8)
        case .chordChart: return Data(chordChart(analysis: analysis, title: source.fileName, includeRomanNumerals: true).utf8)
        }
    }

    // MARK: - JSON

    struct JSONDocument: Codable {
        var generator: String
        var source: ExportSource
        var analysis: AnalysisResult
    }

    public static func json(analysis: AnalysisResult, source: ExportSource) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(JSONDocument(generator: "Music Structure Lab", source: source, analysis: analysis))
    }

    // MARK: - CSV

    /// 1 行 1 項目(セクション・コード・拍)の CSV。
    public static func csv(analysis: AnalysisResult) -> String {
        var rows = [["type", "start_seconds", "end_seconds", "bar", "label", "name", "chord", "roman_numeral"]]
        let flats = analysis.prefersFlats
        for section in analysis.sections {
            rows.append(["section", seconds(section.start), seconds(section.end), barText(analysis, section.start), section.label, section.name, "", ""])
        }
        for segment in analysis.chords {
            let symbol = segment.chord?.symbol(preferFlats: flats) ?? "N.C."
            let roman = segment.chord.flatMap { chord in analysis.key.map { MusicTheory.romanNumeral(for: chord, in: $0) } } ?? ""
            rows.append(["chord", seconds(segment.start), seconds(segment.end), barText(analysis, segment.start), "", "", symbol, roman])
        }
        let grid = analysis.beatGrid
        for (index, time) in grid.beats.enumerated() {
            rows.append(["beat", seconds(time), "", String(grid.barNumber(ofBeat: index)), grid.isDownbeat(index) ? "downbeat" : "beat", "", "", ""])
        }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func csvField(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func barText(_ analysis: AnalysisResult, _ time: Double) -> String {
        guard let index = analysis.beatGrid.beatIndex(atOrBefore: time + 0.01) else { return "0" }
        return String(analysis.beatGrid.barNumber(ofBeat: index))
    }

    // MARK: - Audacity labels

    /// Audacity の「ラベルを読み込み」で使える、タブ区切りのラベル。
    public static func audacityLabels(analysis: AnalysisResult) -> String {
        analysis.sections.map { section in
            String(format: "%.6f\t%.6f\t", section.start, section.end) + "\(section.name) [\(section.label)]"
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - Chord chart

    /// 小節ごとのコード譜。セクションごとに 1 行 4 小節で並べる。
    public static func chordChart(analysis: AnalysisResult, title: String, includeRomanNumerals: Bool) -> String {
        let flats = analysis.prefersFlats
        var lines = [String]()
        lines.append(title)
        var summary = String(format: "テンポ: %.1f BPM / 拍子: %ld/4", analysis.beatGrid.bpm, analysis.beatGrid.beatsPerBar)
        if let key = analysis.key {
            summary += " / キー: \(key.name)"
        }
        lines.append(summary)

        let bars = barRanges(analysis)
        for section in analysis.sections {
            let sectionBars = bars.filter { $0.start >= section.start - 0.01 && $0.start < section.end - 0.01 }
            lines.append("")
            if let first = sectionBars.first, let last = sectionBars.last {
                lines.append("[\(section.name)] (\(section.label)) 小節 \(first.number)–\(last.number)")
            } else {
                lines.append("[\(section.name)] (\(section.label))")
            }
            let cells = sectionBars.map { bar -> String in
                let names = chords(in: bar, analysis: analysis).map { chord -> String in
                    guard let chord else { return "N.C." }
                    var text = chord.symbol(preferFlats: flats)
                    if includeRomanNumerals, let key = analysis.key {
                        text += "(\(MusicTheory.romanNumeral(for: chord, in: key)))"
                    }
                    return text
                }
                return names.isEmpty ? "-" : names.joined(separator: " ")
            }
            var index = 0
            while index < cells.count {
                let row = cells[index..<min(index + 4, cells.count)]
                lines.append("| " + row.joined(separator: " | ") + " |")
                index += 4
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct BarRange {
        var number: Int
        var start: Double
        var end: Double
    }

    static func barRanges(_ analysis: AnalysisResult) -> [BarRange] {
        let grid = analysis.beatGrid
        let downbeatIndices = grid.beats.indices.filter(grid.isDownbeat)
        var result = [BarRange]()
        for (n, index) in downbeatIndices.enumerated() {
            let start = grid.beats[index]
            let end = n + 1 < downbeatIndices.count ? grid.beats[downbeatIndices[n + 1]] : analysis.duration
            result.append(BarRange(number: grid.barNumber(ofBeat: index), start: start, end: end))
        }
        return result
    }

    /// 小節の中で鳴っているコード(小節の 1/4 以上を占めるもの)。
    static func chords(in bar: BarRange, analysis: AnalysisResult) -> [Chord?] {
        let length = bar.end - bar.start
        guard length > 0 else { return [] }
        var result = [Chord?]()
        for segment in analysis.chords {
            let overlap = min(segment.end, bar.end) - max(segment.start, bar.start)
            guard overlap >= length / 4 else { continue }
            if let last = result.last, last == segment.chord { continue }
            result.append(segment.chord)
        }
        return result
    }
}
