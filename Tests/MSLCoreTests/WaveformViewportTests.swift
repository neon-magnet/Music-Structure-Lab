@testable import MSLCore
import XCTest

final class WaveformViewportTests: XCTestCase {
    func testFittingShowsWholeAudio() {
        let viewport = WaveformViewport.fitting(totalFrames: 48_000, width: 1000)
        XCTAssertEqual(viewport.startFrame, 0)
        XCTAssertEqual(viewport.framesPerPoint, 48, accuracy: 1e-9)
        XCTAssertEqual(viewport.visibleFrameCount(width: 1000), 48_000, accuracy: 1e-6)
        XCTAssertEqual(viewport.zoomFactor(width: 1000), 1, accuracy: 1e-9)
    }

    func testZoomKeepsAnchorFrameInPlace() {
        var viewport = WaveformViewport.fitting(totalFrames: 100_000, width: 1000)
        let anchorX = 250.0
        let before = viewport.frame(atX: anchorX)
        viewport.zoom(by: 4, anchorX: anchorX, width: 1000)
        XCTAssertEqual(viewport.framesPerPoint, 25, accuracy: 1e-9)
        XCTAssertEqual(viewport.frame(atX: anchorX), before, accuracy: 1e-6)
    }

    func testZoomOutIsLimitedToWholeAudio() {
        var viewport = WaveformViewport.fitting(totalFrames: 100_000, width: 1000)
        viewport.zoom(by: 0.1, anchorX: 500, width: 1000)
        XCTAssertEqual(viewport.framesPerPoint, 100, accuracy: 1e-9)
        XCTAssertEqual(viewport.startFrame, 0)
    }

    func testZoomInIsLimited() {
        var viewport = WaveformViewport.fitting(totalFrames: 100_000, width: 1000)
        viewport.zoom(by: 1e9, anchorX: 500, width: 1000)
        XCTAssertEqual(viewport.framesPerPoint, WaveformViewport.minimumFramesPerPoint, accuracy: 1e-12)
    }

    func testPanIsClampedToAudioBounds() {
        var viewport = WaveformViewport.fitting(totalFrames: 100_000, width: 1000)
        viewport.zoom(by: 10, anchorX: 0, width: 1000)
        XCTAssertEqual(viewport.startFrame, 0, accuracy: 1e-9)

        viewport.pan(byPoints: -500, width: 1000)
        XCTAssertEqual(viewport.startFrame, 0)

        viewport.pan(byPoints: 100_000, width: 1000)
        XCTAssertEqual(viewport.startFrame, 90_000, accuracy: 1e-6)
    }

    func testRevealCentersFrameWhenOffscreen() {
        var viewport = WaveformViewport.fitting(totalFrames: 100_000, width: 1000)
        viewport.zoom(by: 10, anchorX: 0, width: 1000)
        viewport.reveal(frame: 50_000, width: 1000)
        XCTAssertEqual(viewport.startFrame, 45_000, accuracy: 1e-6)
        // 既に見えている場合は動かさない
        viewport.reveal(frame: 46_000, width: 1000)
        XCTAssertEqual(viewport.startFrame, 45_000, accuracy: 1e-6)
    }

    func testFollowPagesWhenPlayheadLeavesView() {
        var viewport = WaveformViewport.fitting(totalFrames: 100_000, width: 1000)
        viewport.zoom(by: 10, anchorX: 0, width: 1000) // 表示 0..<10_000
        viewport.follow(frame: 5_000, width: 1000)
        XCTAssertEqual(viewport.startFrame, 0, accuracy: 1e-9)
        viewport.follow(frame: 12_000, width: 1000)
        XCTAssertEqual(viewport.startFrame, 12_000, accuracy: 1e-9)
        viewport.follow(frame: 95_000, width: 1000)
        XCTAssertEqual(viewport.startFrame, 90_000, accuracy: 1e-9)
        viewport.follow(frame: 500, width: 1000)
        XCTAssertEqual(viewport.startFrame, 500, accuracy: 1e-9)
    }

    func testCoordinateConversionRoundTrips() {
        var viewport = WaveformViewport.fitting(totalFrames: 10_000, width: 500)
        viewport.zoom(by: 3, anchorX: 120, width: 500)
        for x in stride(from: 0.0, through: 500.0, by: 37.5) {
            XCTAssertEqual(viewport.x(forFrame: viewport.frame(atX: x)), x, accuracy: 1e-9)
        }
    }

    func testEmptyAudioDoesNotProduceInvalidValues() {
        var viewport = WaveformViewport.fitting(totalFrames: 0, width: 800)
        viewport.zoom(by: 2, anchorX: 100, width: 800)
        viewport.pan(byPoints: 50, width: 800)
        XCTAssertTrue(viewport.framesPerPoint.isFinite)
        XCTAssertGreaterThan(viewport.framesPerPoint, 0)
        XCTAssertEqual(viewport.startFrame, 0)
    }
}
