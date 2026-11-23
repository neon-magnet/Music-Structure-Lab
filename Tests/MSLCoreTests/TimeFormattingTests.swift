@testable import MSLCore
import XCTest

final class TimeFormattingTests: XCTestCase {
    func testFormatsMinutesSecondsAndMilliseconds() {
        XCTAssertEqual(TimeFormatting.string(fromSeconds: 0), "0:00.000")
        XCTAssertEqual(TimeFormatting.string(fromSeconds: 61.5), "1:01.500")
        XCTAssertEqual(TimeFormatting.string(fromSeconds: 3725.25), "1:02:05.250")
        XCTAssertEqual(TimeFormatting.string(fromSeconds: 59.9996), "1:00.000")
        XCTAssertEqual(TimeFormatting.string(fromSeconds: 12, showMilliseconds: false), "0:12")
        XCTAssertEqual(TimeFormatting.string(fromSeconds: -1.25), "-0:01.250")
        XCTAssertEqual(TimeFormatting.string(fromSeconds: .nan), "--:--")
    }

    func testRulerStepPicksSmallestRoundValue() {
        XCTAssertEqual(TimeFormatting.rulerStep(minimumSpacing: 0.0004), 0.001)
        XCTAssertEqual(TimeFormatting.rulerStep(minimumSpacing: 0.3), 0.5)
        XCTAssertEqual(TimeFormatting.rulerStep(minimumSpacing: 7), 10)
        XCTAssertEqual(TimeFormatting.rulerStep(minimumSpacing: 100_000), 3600)
    }
}
