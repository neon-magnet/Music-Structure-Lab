import Foundation

public enum TimeFormatting {
    /// 秒を `m:ss.mmm`(1 時間以上なら `h:mm:ss.mmm`)にする。
    public static func string(fromSeconds seconds: Double, showMilliseconds: Bool = true) -> String {
        guard seconds.isFinite else { return "--:--" }
        let sign = seconds < 0 ? "-" : ""
        let totalMilliseconds = Int((abs(seconds) * 1000).rounded())
        let ms = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        var text: String
        if h > 0 {
            text = String(format: "%d:%02d:%02d", h, m, s)
        } else {
            text = String(format: "%d:%02d", m, s)
        }
        if showMilliseconds {
            text += String(format: ".%03d", ms)
        }
        return sign + text
    }

    /// 時間目盛りの間隔(秒)を選ぶ。`minimumSpacing` 秒以上で最も細かい「きりのよい」値を返す。
    public static func rulerStep(minimumSpacing: Double) -> Double {
        let candidates: [Double] = [
            0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
            1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600
        ]
        for candidate in candidates where candidate >= minimumSpacing {
            return candidate
        }
        return candidates[candidates.count - 1]
    }
}
