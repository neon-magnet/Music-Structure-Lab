import AVFoundation
@testable import MSLAudio
import MSLCore
import XCTest

final class AudioFileLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSLAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 16bit ステレオ WAV を書き出す。L は振幅 0.5 の 440Hz サイン波、R は -0.25 の直流。
    private func writeTestWAV(name: String, sampleRate: Double, frames: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // AVAudioFile は解放時にファイルを閉じるので、このスコープ内で書き終える。
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard frames > 0 else { return }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<frames {
                data[0][i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / sampleRate))
                data[1][i] = -0.25
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testLoadsStereoWAV() throws {
        let frames = 66_150 // 1.5 秒
        let url = try writeTestWAV(name: "stereo.wav", sampleRate: 44_100, frames: frames)

        // チャンクを小さくして、複数回に分けて読む経路も通す。
        let loader = AudioFileLoader(chunkFrameCount: 10_000, baseBlockSize: 256)
        let audio = try loader.load(from: url)

        XCTAssertEqual(audio.info.sampleRate, 44_100)
        XCTAssertEqual(audio.info.channelCount, 2)
        XCTAssertEqual(audio.info.frameCount, frames)
        XCTAssertEqual(audio.info.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(audio.info.sourceFormatDescription, "Linear PCM 16-bit")
        XCTAssertEqual(audio.channels.count, 2)
        XCTAssertEqual(audio.channels[0].count, frames)
        XCTAssertEqual(audio.channels[1].count, frames)
        XCTAssertEqual(audio.mono.count, frames)

        let tolerance: Float = 0.001 // 16bit 量子化誤差
        let left = audio.channelOverviews[0].peak(in: 0..<frames, samples: audio.channels[0])
        XCTAssertEqual(left.max, 0.5, accuracy: tolerance)
        XCTAssertEqual(left.min, -0.5, accuracy: tolerance)
        let right = audio.channelOverviews[1].peak(in: 0..<frames, samples: audio.channels[1])
        XCTAssertEqual(right.max, -0.25, accuracy: tolerance)
        XCTAssertEqual(right.min, -0.25, accuracy: tolerance)

        for index in [0, 100, 12_345, frames - 1] {
            let expected = (audio.channels[0][index] + audio.channels[1][index]) / 2
            XCTAssertEqual(audio.mono[index], expected, accuracy: 1e-6)
        }
        XCTAssertEqual(audio.monoOverview.sampleCount, frames)
    }

    func testExportedSectionCanBeReadBack() throws {
        let source = try writeTestWAV(name: "source.wav", sampleRate: 44_100, frames: 44_100)
        let audio = try AudioFileLoader().load(from: source)
        let exported = directory.appendingPathComponent("section.wav")
        try AudioExporter.writeWAV(audio, frames: 10_000..<30_000, to: exported)

        let section = try AudioFileLoader().load(from: exported)
        XCTAssertEqual(section.info.frameCount, 20_000)
        XCTAssertEqual(section.info.channelCount, 2)
        XCTAssertEqual(section.info.sourceFormatDescription, "Linear PCM 24-bit")
        for index in [0, 1_234, 19_999] {
            XCTAssertEqual(section.channels[0][index], audio.channels[0][10_000 + index], accuracy: 1e-4)
            XCTAssertEqual(section.channels[1][index], audio.channels[1][10_000 + index], accuracy: 1e-4)
        }
        XCTAssertThrowsError(try AudioExporter.writeWAV(audio, frames: 50_000..<60_000, to: exported))
    }

    func testExportedStemChannelsCanBeReadBack() throws {
        let exported = directory.appendingPathComponent("stem.wav")
        let left = (0..<8_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        try AudioExporter.writeWAV(channels: [left, left], sampleRate: 44_100, frames: 0..<8_000, to: exported)
        let reloaded = try AudioFileLoader().load(from: exported)
        XCTAssertEqual(reloaded.info.frameCount, 8_000)
        XCTAssertEqual(reloaded.info.channelCount, 2)
        XCTAssertEqual(reloaded.channels[0][100], left[100], accuracy: 1e-4)
    }

    func testReportsProgressUpToCompletion() throws {
        let url = try writeTestWAV(name: "progress.wav", sampleRate: 48_000, frames: 48_000)
        let recorder = ProgressRecorder()
        _ = try AudioFileLoader(chunkFrameCount: 4_096).load(from: url) { recorder.record($0) }
        let values = recorder.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "進捗は単調増加であること")
    }

    func testRejectsNonAudioFile() throws {
        let url = directory.appendingPathComponent("not-audio.wav")
        try Data("this is not audio".utf8).write(to: url)
        XCTAssertThrowsError(try AudioFileLoader().load(from: url)) { error in
            guard case .cannotOpen(let fileName, _)? = error as? AudioLoadError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(fileName, "not-audio.wav")
        }
    }

    func testRejectsMissingFile() {
        let url = directory.appendingPathComponent("missing.wav")
        XCTAssertThrowsError(try AudioFileLoader().load(from: url)) { error in
            XCTAssertNotNil(error as? AudioLoadError)
        }
    }

    func testRejectsFileWithoutFrames() throws {
        let url = try writeTestWAV(name: "empty.wav", sampleRate: 44_100, frames: 0)
        XCTAssertThrowsError(try AudioFileLoader().load(from: url)) { error in
            XCTAssertEqual(error as? AudioLoadError, .emptyFile(fileName: "empty.wav"))
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
