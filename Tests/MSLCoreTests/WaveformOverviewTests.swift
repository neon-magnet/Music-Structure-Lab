@testable import MSLCore
import XCTest

final class WaveformOverviewTests: XCTestCase {
    private func makeSamples(count: Int) -> [Float] {
        (0..<count).map { i in
            Float(sin(Double(i) * 0.037) * 0.8 + sin(Double(i) * 0.31) * 0.15)
        }
    }

    private func bruteForce(_ samples: [Float], _ range: Range<Int>) -> WaveformPeak {
        var peak = WaveformPeak.empty
        for i in range { peak.include(samples[i]) }
        return peak
    }

    func testBuilderProducesBlockPeaksAndPyramid() {
        let samples = makeSamples(count: 1000)
        var builder = WaveformBuilder(baseBlockSize: 256)
        // チャンクの区切りがブロック境界とずれていても結果が変わらないこと
        builder.append(contentsOf: samples[0..<100])
        builder.append(contentsOf: samples[100..<700])
        builder.append(contentsOf: samples[700..<1000])
        let overview = builder.build()

        XCTAssertEqual(overview.sampleCount, 1000)
        XCTAssertEqual(overview.levels.map(\.samplesPerPeak), [256, 512, 1024])
        XCTAssertEqual(overview.levels.map(\.peaks.count), [4, 2, 1])

        for (index, peak) in overview.levels[0].peaks.enumerated() {
            let range = (index * 256)..<min(1000, (index + 1) * 256)
            XCTAssertEqual(peak, bruteForce(samples, range))
        }
        XCTAssertEqual(overview.levels[2].peaks[0], bruteForce(samples, 0..<1000))
    }

    func testEmptyBuilder() {
        let overview = WaveformBuilder().build()
        XCTAssertEqual(overview.sampleCount, 0)
        XCTAssertTrue(overview.levels.isEmpty)
        XCTAssertTrue(overview.peak(in: 0..<10, samples: nil).isEmpty)
    }

    func testPeakUsesRawSamplesForShortRanges() {
        let samples = makeSamples(count: 5000)
        var builder = WaveformBuilder(baseBlockSize: 256)
        builder.append(contentsOf: samples)
        let overview = builder.build()

        let range = 1234..<1300
        XCTAssertEqual(overview.peak(in: range, samples: samples), bruteForce(samples, range))
    }

    func testPeakOfWholeRangeIsExact() {
        let samples = makeSamples(count: 10_000)
        var builder = WaveformBuilder(baseBlockSize: 64)
        builder.append(contentsOf: samples)
        let overview = builder.build()

        XCTAssertEqual(overview.peak(in: 0..<10_000, samples: samples), bruteForce(samples, 0..<10_000))
        // 範囲外を含んでも音源内だけが対象になる
        XCTAssertEqual(overview.peak(in: -50..<20_000, samples: samples), bruteForce(samples, 0..<10_000))
        XCTAssertTrue(overview.peak(in: 10_000..<10_100, samples: samples).isEmpty)
    }

    func testColumnsCoverTheTrueExtremes() {
        let samples = makeSamples(count: 48_000)
        var builder = WaveformBuilder(baseBlockSize: 256)
        builder.append(contentsOf: samples)
        let overview = builder.build()

        let columns = 50  // 1 列 960 サンプル: 多段解像度の段から集計される
        let samplesPerColumn = 48_000.0 / Double(columns)
        let peaks = overview.columns(startSample: 0, samplesPerColumn: samplesPerColumn, columns: columns, samples: samples)
        XCTAssertEqual(peaks.count, columns)
        for (column, peak) in peaks.enumerated() {
            let start = Int(Double(column) * samplesPerColumn)
            let end = Int(Double(column + 1) * samplesPerColumn)
            let exact = bruteForce(samples, start..<end)
            // 多段解像度は近似なので、真の極値を必ず含む(取りこぼさない)ことを確認する。
            XCTAssertLessThanOrEqual(peak.min, exact.min)
            XCTAssertGreaterThanOrEqual(peak.max, exact.max)
        }
    }

    func testColumnsBeyondTheEndAreEmpty() {
        var builder = WaveformBuilder(baseBlockSize: 16)
        builder.append(contentsOf: [Float](repeating: 0.5, count: 100))
        let overview = builder.build()
        let peaks = overview.columns(startSample: 80, samplesPerColumn: 10, columns: 4, samples: nil)
        XCTAssertFalse(peaks[0].isEmpty)
        XCTAssertFalse(peaks[1].isEmpty)
        XCTAssertTrue(peaks[2].isEmpty)
        XCTAssertTrue(peaks[3].isEmpty)
    }

    func testDecodedAudioMixesChannelsToMono() {
        let info = AudioFileInfo(
            url: URL(fileURLWithPath: "/tmp/test.wav"),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 4,
            sourceFormatDescription: "test"
        )
        let audio = DecodedAudio(info: info, channels: [[1, 0.5, 0, -1], [0, 0.5, 1, -1]], baseBlockSize: 2)
        XCTAssertEqual(audio.mono, [0.5, 0.5, 0.5, -1])
        XCTAssertEqual(audio.channelOverviews.count, 2)
        XCTAssertEqual(audio.monoOverview.levels[0].peaks, [WaveformPeak(min: 0.5, max: 0.5), WaveformPeak(min: -1, max: 0.5)])
    }
}
