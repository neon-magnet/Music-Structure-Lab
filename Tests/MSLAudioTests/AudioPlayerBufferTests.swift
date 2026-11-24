import AVFoundation
import CoreML
@testable import MSLAudio
import MSLCore
import XCTest

final class AudioPlayerBufferTests: XCTestCase {
    private func makeAudio(channels: [[Float]]) -> DecodedAudio {
        let info = AudioFileInfo(
            url: URL(fileURLWithPath: "/tmp/test.wav"),
            sampleRate: 48_000,
            channelCount: channels.count,
            frameCount: channels.first?.count ?? 0,
            sourceFormatDescription: "test"
        )
        return DecodedAudio(info: info, channels: channels)
    }

    func testBufferStartsAtRequestedFrame() throws {
        let left = (0..<1000).map { Float($0) / 1000 }
        let right = left.map { -$0 }
        let audio = makeAudio(channels: [left, right])
        let format = try XCTUnwrap(AudioPlayer.playbackFormat(for: audio))
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.sampleRate, 48_000)

        let buffer = try XCTUnwrap(AudioPlayer.makeBuffer(from: audio, format: format, startFrame: 250))
        XCTAssertEqual(buffer.frameLength, 750)
        let data = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(data[0][0], left[250])
        XCTAssertEqual(data[1][0], right[250])
        XCTAssertEqual(data[0][749], left[999])
        XCTAssertEqual(data[1][749], right[999])
    }

    func testBufferOutOfRangeIsNil() throws {
        let audio = makeAudio(channels: [[0, 0.1, 0.2]])
        let format = try XCTUnwrap(AudioPlayer.playbackFormat(for: audio))
        XCTAssertNil(AudioPlayer.makeBuffer(from: audio, format: format, startFrame: 3))
        XCTAssertNil(AudioPlayer.makeBuffer(from: audio, format: format, startFrame: -1))
        XCTAssertEqual(AudioPlayer.makeBuffer(from: audio, format: format, startFrame: 2)?.frameLength, 1)
    }

    func testBufferRangeAndClicks() throws {
        let silence = [Float](repeating: 0, count: 48_000)
        let audio = makeAudio(channels: [silence, silence])
        let format = try XCTUnwrap(AudioPlayer.playbackFormat(for: audio))
        let buffer = try XCTUnwrap(AudioPlayer.makeBuffer(
            from: audio, format: format, startFrame: 1_000, endFrame: 11_000,
            clicks: [ClickMark(frame: 2_000, accent: true), ClickMark(frame: 30_000, accent: false)]
        ))
        XCTAssertEqual(buffer.frameLength, 10_000)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let clickRegion = (1_000..<2_440).map { abs(data[0][$0]) }
        XCTAssertGreaterThan(clickRegion.max() ?? 0, 0.1, "クリック音が足されている")
        XCTAssertEqual((0..<1_000).map { abs(data[1][$0]) }.max(), 0, "クリックより前は無音のまま")
        XCTAssertEqual((5_000..<10_000).map { abs(data[0][$0]) }.max(), 0, "範囲外のクリックは足さない")
    }

    func testMultichannelAudioPlaysMonoMix() throws {
        let audio = makeAudio(channels: [[0.3, 0.3], [0.6, 0.0], [0.0, 0.3]])
        XCTAssertEqual(AudioPlayer.playbackChannelCount(for: audio), 1)
        let format = try XCTUnwrap(AudioPlayer.playbackFormat(for: audio))
        let buffer = try XCTUnwrap(AudioPlayer.makeBuffer(from: audio, format: format, startFrame: 0))
        let data = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(data[0][0], audio.mono[0], accuracy: 1e-6)
        XCTAssertEqual(data[0][1], audio.mono[1], accuracy: 1e-6)
    }

    func testBufferFromStemChannels() throws {
        let audio = makeAudio(channels: [[0, 0, 0, 0], [0, 0, 0, 0]])
        let format = try XCTUnwrap(AudioPlayer.playbackFormat(for: audio))
        let stem: [[Float]] = [[0.1, 0.2, 0.3, 0.4], [-0.1, -0.2, -0.3, -0.4]]
        let buffer = try XCTUnwrap(AudioPlayer.makeBuffer(channels: stem, frameCount: 4, format: format, startFrame: 1, endFrame: 3))
        XCTAssertEqual(buffer.frameLength, 2)
        let data = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(data[0][0], 0.2)
        XCTAssertEqual(data[1][1], -0.3)
        // チャンネル数が合わなければ作らない。
        XCTAssertNil(AudioPlayer.makeBuffer(channels: [stem[0]], frameCount: 4, format: format, startFrame: 0))
    }

    func testPlaybackChannelsMatchFormat() {
        let stereo = makeAudio(channels: [[0.1], [0.2]])
        XCTAssertEqual(AudioPlayer.playbackChannels(for: stereo).count, 2)
        let surround = makeAudio(channels: [[0.3], [0.6], [0.0]])
        XCTAssertEqual(AudioPlayer.playbackChannels(for: surround).count, 1)
    }

    func testModelSourcesMapToStems() {
        XCTAssertEqual(MLStemSeparator.stemKind(forSource: "drums"), .drums)
        XCTAssertEqual(MLStemSeparator.stemKind(forSource: "bass"), .bass)
        XCTAssertEqual(MLStemSeparator.stemKind(forSource: "vocals"), .vocals)
        XCTAssertEqual(MLStemSeparator.stemKind(forSource: "other"), .chords)
        XCTAssertEqual(MLStemSeparator.stemKind(forSource: "piano"), .chords)
    }

    func testComputeUnitsFromMetadata() {
        XCTAssertEqual(MLStemSeparator.computeUnits(fromMetadata: nil), .cpuAndGPU)
        XCTAssertEqual(MLStemSeparator.computeUnits(fromMetadata: "cpuOnly"), .cpuOnly)
        XCTAssertEqual(MLStemSeparator.computeUnits(fromMetadata: "all"), .all)
        XCTAssertEqual(MLStemSeparator.computeUnits(fromMetadata: "unknown"), .cpuAndGPU)
    }

    func testResampleChangesLength() throws {
        let input = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.5 }
        let output = try MLStemSeparator.resample([input, input], from: 48_000, to: 44_100)
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(Double(output[0].count), 44_100, accuracy: 600)
    }
}
