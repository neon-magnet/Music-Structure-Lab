@testable import MSLCore
import XCTest

final class AnalysisEditingTests: XCTestCase {
    private func makeResult() -> AnalysisResult {
        let beats = stride(from: 0.0, to: 40.0, by: 0.5).map { $0 }
        return AnalysisResult(
            duration: 40,
            beatGrid: BeatGrid(bpm: 120, beats: beats, beatsPerBar: 4, downbeatOffset: 0),
            tempoConfidence: 1,
            key: MusicalKey(tonic: 0, mode: .major),
            keyConfidence: 1,
            chords: [
                ChordSegment(start: 0, end: 8, chord: Chord(root: 0, quality: .major)),
                ChordSegment(start: 8, end: 16, chord: Chord(root: 7, quality: .major)),
                ChordSegment(start: 16, end: 40, chord: nil)
            ],
            sections: [
                Section(start: 0, end: 16, label: "A", name: "A メロ"),
                Section(start: 16, end: 32, label: "B", name: "サビ"),
                Section(start: 32, end: 40, label: "A", name: "A メロ")
            ]
        )
    }

    private func assertContiguous(_ result: AnalysisResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.sections.first?.start, 0, file: file, line: line)
        XCTAssertEqual(result.sections.last?.end, result.duration, file: file, line: line)
        for (a, b) in zip(result.sections, result.sections.dropFirst()) {
            XCTAssertEqual(a.end, b.start, file: file, line: line)
        }
    }

    func testSplitAndMergeSections() throws {
        var result = makeResult()
        let newID = try XCTUnwrap(result.splitSection(at: 8))
        XCTAssertEqual(result.sections.count, 4)
        XCTAssertEqual(result.sections[1].id, newID)
        XCTAssertEqual(result.sections[1].start, 8)
        XCTAssertEqual(result.sections[1].label, "A")
        assertContiguous(result)

        XCTAssertNil(result.splitSection(at: 8.1), "短すぎる区間は作らない")
        XCTAssertTrue(result.mergeSectionWithNext(id: result.sections[0].id))
        XCTAssertEqual(result.sections.count, 3)
        XCTAssertEqual(result.sections[0].end, 16)
        assertContiguous(result)
    }

    func testRemoveSectionGivesRangeToNeighbor() {
        var result = makeResult()
        XCTAssertTrue(result.removeSection(id: result.sections[1].id))
        XCTAssertEqual(result.sections.map(\.name), ["A メロ", "A メロ"])
        XCTAssertEqual(result.sections[0].end, 32)
        assertContiguous(result)

        XCTAssertTrue(result.removeSection(id: result.sections[0].id))
        XCTAssertEqual(result.sections.count, 1)
        assertContiguous(result)
        XCTAssertFalse(result.removeSection(id: result.sections[0].id), "最後の 1 つは消さない")
    }

    func testMoveBoundaryIsClamped() {
        var result = makeResult()
        XCTAssertEqual(result.moveSectionBoundary(after: 0, to: 20), 20)
        XCTAssertEqual(result.sections[1].start, 20)
        XCTAssertEqual(result.moveSectionBoundary(after: 0, to: 100), 32 - AnalysisResult.minimumSegmentLength)
        XCTAssertEqual(result.moveSectionBoundary(after: 0, to: -5), AnalysisResult.minimumSegmentLength)
        XCTAssertNil(result.moveSectionBoundary(after: 2, to: 10))
        assertContiguous(result)
    }

    func testRenameByLabel() {
        var result = makeResult()
        result.renameSections(withLabel: "A", to: "バース")
        XCTAssertEqual(result.sections.map(\.name), ["バース", "サビ", "バース"])
    }

    func testChordEditing() throws {
        var result = makeResult()
        result.setChord(id: result.chords[2].id, to: Chord(root: 9, quality: .minor))
        XCTAssertEqual(result.chords[2].chord, Chord(root: 9, quality: .minor))
        let id = try XCTUnwrap(result.splitChord(at: 4))
        XCTAssertEqual(result.chords.count, 4)
        XCTAssertEqual(result.chords[1].id, id)
        XCTAssertEqual(result.chords[1].chord, Chord(root: 0, quality: .major))
        result.mergeRepeatedChords()
        XCTAssertEqual(result.chords.count, 3)
        XCTAssertTrue(result.mergeChordWithNext(id: result.chords[0].id))
        XCTAssertEqual(result.chords[0].end, 16)
    }

    func testTransposeMovesChordsAndKey() {
        var result = makeResult()
        result.transpose(by: 2)
        XCTAssertEqual(result.key, MusicalKey(tonic: 2, mode: .major))
        XCTAssertEqual(result.chords[0].chord, Chord(root: 2, quality: .major))
        XCTAssertEqual(result.chords[1].chord, Chord(root: 9, quality: .major))
        XCTAssertNil(result.chords[2].chord)
        result.transpose(by: -14)
        XCTAssertEqual(result.key, MusicalKey(tonic: 0, mode: .major))
    }

    func testSetTempoRebuildsUniformBeats() {
        var result = makeResult()
        result.setTempo(100)
        XCTAssertEqual(result.beatGrid.bpm, 100)
        let beats = result.beatGrid.beats
        XCTAssertEqual(beats.first, 0)
        XCTAssertEqual(beats[1], 0.6, accuracy: 1e-9)
        XCTAssertLessThan(beats.last ?? 0, 40)
        XCTAssertEqual(beats.count, Int((40 / 0.6).rounded(.up)))
    }

    func testMeterEditing() {
        var result = makeResult()
        result.setBeatsPerBar(3)
        XCTAssertEqual(result.beatGrid.beatsPerBar, 3)
        XCTAssertTrue(result.beatGrid.isDownbeat(3))
        result.shiftDownbeat(by: 1)
        XCTAssertTrue(result.beatGrid.isDownbeat(1))
        XCTAssertEqual(result.beatGrid.barNumber(ofBeat: 0), 0, "最初の小節頭より前は弱起")
        XCTAssertEqual(result.beatGrid.barNumber(ofBeat: 4), 2)
        result.nudgeBeats(by: -0.25)
        XCTAssertEqual(result.beatGrid.beats.first ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertTrue(result.beatGrid.isDownbeat(0), "先頭の拍が落ちた分だけ小節頭の位置をずらす")
    }

    func testSnapSectionsToBars() {
        var result = makeResult()
        result.moveSectionBoundary(after: 0, to: 15.6)
        result.snapSectionsToBars()
        XCTAssertEqual(result.sections[0].end, 16)
        assertContiguous(result)
    }

    func testBeatIndexLookup() {
        let grid = makeResult().beatGrid
        XCTAssertNil(grid.beatIndex(atOrBefore: -1))
        XCTAssertEqual(grid.beatIndex(atOrBefore: 0), 0)
        XCTAssertEqual(grid.beatIndex(atOrBefore: 1.2), 2)
        XCTAssertEqual(grid.beatIndex(atOrBefore: 100), grid.beats.count - 1)
    }
}

final class ExportTests: XCTestCase {
    private func makeResult() -> AnalysisResult {
        AnalysisResult(
            duration: 10,
            beatGrid: BeatGrid(bpm: 120, beats: stride(from: 0.25, to: 10, by: 0.5).map { $0 }, beatsPerBar: 4, downbeatOffset: 1),
            tempoConfidence: 1,
            key: MusicalKey(tonic: 0, mode: .major),
            keyConfidence: 1,
            chords: [
                ChordSegment(start: 0, end: 4.25, chord: Chord(root: 0, quality: .major)),
                ChordSegment(start: 4.25, end: 10, chord: Chord(root: 9, quality: .minor))
            ],
            sections: [
                Section(start: 0, end: 4.25, label: "A", name: "イントロ, 1"),
                Section(start: 4.25, end: 10, label: "B", name: "サビ \"大\"")
            ]
        )
    }

    func testVariableLengthQuantities() {
        XCTAssertEqual(MIDIExporter.variableLength(0), [0x00])
        XCTAssertEqual(MIDIExporter.variableLength(127), [0x7F])
        XCTAssertEqual(MIDIExporter.variableLength(128), [0x81, 0x00])
        XCTAssertEqual(MIDIExporter.variableLength(0x3FFF), [0xFF, 0x7F])
        XCTAssertEqual(MIDIExporter.variableLength(0x200000), [0x81, 0x80, 0x80, 0x00])
    }

    func testMIDIStructure() {
        let data = [UInt8](MIDIExporter.data(for: makeResult(), title: "song"))
        XCTAssertEqual(Array(data[0..<4]), Array("MThd".utf8))
        XCTAssertEqual(Array(data[8..<14]), [0, 1, 0, 2, 0x01, 0xE0])
        XCTAssertEqual(Array(data[14..<18]), Array("MTrk".utf8))
        let firstLength = Int(data[18]) << 24 | Int(data[19]) << 16 | Int(data[20]) << 8 | Int(data[21])
        let second = 22 + firstLength
        XCTAssertEqual(Array(data[second..<(second + 4)]), Array("MTrk".utf8))
        XCTAssertEqual(Array(data.suffix(3)), [0xFF, 0x2F, 0x00])
    }

    func testTimeMapAlignsBeatsAndBars() {
        let result = makeResult()
        let map = MIDIExporter.TimeMap(grid: result.beatGrid, duration: result.duration)
        XCTAssertEqual((result.beatGrid.downbeatOffset + map.pad) % 4, 0, "小節頭が MIDI の小節線に揃う")
        for (index, beat) in result.beatGrid.beats.enumerated() {
            XCTAssertEqual(map.tick(for: beat), (index + map.pad) * MIDIExporter.ticksPerBeat)
        }
        var previous = -1
        for step in 0...200 {
            let tick = map.tick(for: Double(step) * 0.05)
            XCTAssertGreaterThanOrEqual(tick, previous)
            previous = tick
        }
    }

    func testCSVEscapesFields() {
        let csv = AnalysisExporter.csv(analysis: makeResult())
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "type,start_seconds,end_seconds,bar,label,name,chord,roman_numeral")
        XCTAssertTrue(lines.contains("section,0.000,4.250,0,A,\"イントロ, 1\",,"))
        XCTAssertTrue(lines.contains("section,4.250,10.000,2,B,\"サビ \"\"大\"\"\",,"))
        XCTAssertTrue(lines.contains("chord,4.250,10.000,2,,,Am,vi"))
        XCTAssertTrue(lines.contains("beat,0.750,,1,downbeat,,,"))
    }

    func testAudacityLabels() {
        let text = AnalysisExporter.audacityLabels(analysis: makeResult())
        XCTAssertEqual(text, "0.000000\t4.250000\tイントロ, 1 [A]\n4.250000\t10.000000\tサビ \"大\" [B]\n")
    }

    func testChordChart() {
        let chart = AnalysisExporter.chordChart(analysis: makeResult(), title: "song", includeRomanNumerals: true)
        XCTAssertTrue(chart.contains("テンポ: 120.0 BPM / 拍子: 4/4 / キー: C major"))
        XCTAssertTrue(chart.contains("[イントロ, 1] (A) 小節 1–2"))
        XCTAssertTrue(chart.contains("| C(I) | C(I) Am(vi) |"))
        XCTAssertTrue(chart.contains("[サビ \"大\"] (B) 小節 3–5"))
    }

    func testJSONRoundTrip() throws {
        let source = ExportSource(fileName: "a.wav", duration: 10, sampleRate: 44_100, channelCount: 2)
        let original = makeResult()
        let data = try AnalysisExporter.json(analysis: original, source: source)
        let decoded = try JSONDecoder().decode(AnalysisExporter.JSONDocument.self, from: data)
        XCTAssertEqual(decoded.analysis, original)
        XCTAssertEqual(decoded.source, source)
    }

    func testProjectRoundTrip() throws {
        let audio = ProjectDocument.AudioReference(
            fileName: "a.wav", path: "/music/a.wav", relativePath: "../music/a.wav",
            bookmark: Data([1, 2, 3]), frameCount: 441_000, sampleRate: 44_100, channelCount: 2
        )
        let document = ProjectDocument(audio: audio, analysis: makeResult(), notes: "メモ", savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let decoded = try ProjectDocument.decode(from: document.encoded())
        XCTAssertEqual(decoded, document)
    }

    func testRelativePath() {
        let project = URL(fileURLWithPath: "/Users/me/Projects/song.mslab")
        XCTAssertEqual(ProjectDocument.relativePath(from: project, to: URL(fileURLWithPath: "/Users/me/Music/a.wav")), "../Music/a.wav")
        XCTAssertEqual(ProjectDocument.relativePath(from: project, to: URL(fileURLWithPath: "/Users/me/Projects/a.wav")), "a.wav")
    }
}
