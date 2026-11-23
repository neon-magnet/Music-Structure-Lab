import Foundation

/// 波形表示の表示範囲(どこから、どの倍率で見ているか)。
///
/// 単位はフレーム(1 チャンネルあたりのサンプル番号)と、画面上のポイント。
/// UI から切り離してあるので、ズーム・スクロールの計算を単体テストできる。
public struct WaveformViewport: Equatable, Sendable {
    /// これ以上は拡大しない(1 サンプルを 32pt で表示)。
    public static let minimumFramesPerPoint: Double = 1.0 / 32.0

    public let totalFrames: Int
    /// 表示左端のフレーム位置。
    public private(set) var startFrame: Double
    /// 1pt あたりのフレーム数。小さいほど拡大。
    public private(set) var framesPerPoint: Double

    public init(totalFrames: Int, startFrame: Double = 0, framesPerPoint: Double = 1) {
        self.totalFrames = Swift.max(0, totalFrames)
        self.startFrame = startFrame
        self.framesPerPoint = framesPerPoint
    }

    /// 音源全体が `width` に収まる状態。
    public static func fitting(totalFrames: Int, width: Double) -> WaveformViewport {
        var viewport = WaveformViewport(totalFrames: totalFrames)
        viewport.fit(width: width)
        return viewport
    }

    public func maximumFramesPerPoint(width: Double) -> Double {
        guard width > 0 else { return Swift.max(1, Double(totalFrames)) }
        return Swift.max(Self.minimumFramesPerPoint, Double(totalFrames) / width)
    }

    public func visibleFrameCount(width: Double) -> Double {
        framesPerPoint * Swift.max(0, width)
    }

    public func visibleRange(width: Double) -> ClosedRange<Double> {
        startFrame...(startFrame + visibleFrameCount(width: width))
    }

    /// 全体表示に対する倍率(1 = 全体表示)。
    public func zoomFactor(width: Double) -> Double {
        maximumFramesPerPoint(width: width) / framesPerPoint
    }

    public mutating func fit(width: Double) {
        framesPerPoint = maximumFramesPerPoint(width: width)
        startFrame = 0
        clamp(width: width)
    }

    /// `factor` 倍に拡大する(1 未満で縮小)。`anchorX` の位置にあるフレームが同じ位置に留まる。
    public mutating func zoom(by factor: Double, anchorX: Double, width: Double) {
        guard factor > 0, factor.isFinite else { return }
        let anchorFrame = frame(atX: anchorX)
        framesPerPoint = clampedFramesPerPoint(framesPerPoint / factor, width: width)
        startFrame = anchorFrame - anchorX * framesPerPoint
        clamp(width: width)
    }

    /// 右方向へ `points` だけスクロールする(負で左)。
    public mutating func pan(byPoints points: Double, width: Double) {
        startFrame += points * framesPerPoint
        clamp(width: width)
    }

    /// 表示左端を指定のフレームに合わせる。
    public mutating func scroll(toStartFrame frame: Double, width: Double) {
        startFrame = frame
        clamp(width: width)
    }

    /// `frame` が見える位置になるようにスクロールする(既に見えていれば何もしない)。
    public mutating func reveal(frame: Double, width: Double) {
        let visible = visibleFrameCount(width: width)
        if frame < startFrame || frame > startFrame + visible {
            startFrame = frame - visible / 2
            clamp(width: width)
        }
    }

    /// 再生位置を追いかける。`frame` が表示範囲の外に出たら、そこが左端になるようページ送りする。
    public mutating func follow(frame: Double, width: Double) {
        let visible = visibleFrameCount(width: width)
        if frame < startFrame || frame >= startFrame + visible {
            startFrame = frame
            clamp(width: width)
        }
    }

    public func frame(atX x: Double) -> Double {
        startFrame + x * framesPerPoint
    }

    public func x(forFrame frame: Double) -> Double {
        (frame - startFrame) / framesPerPoint
    }

    /// 幅が変わった時などに、範囲外にならないよう補正する。
    public mutating func clamp(width: Double) {
        framesPerPoint = clampedFramesPerPoint(framesPerPoint, width: width)
        let maxStart = Swift.max(0, Double(totalFrames) - visibleFrameCount(width: width))
        startFrame = Swift.min(Swift.max(0, startFrame), maxStart)
    }

    private func clampedFramesPerPoint(_ value: Double, width: Double) -> Double {
        guard value.isFinite, value > 0 else { return maximumFramesPerPoint(width: width) }
        return Swift.min(Swift.max(value, Self.minimumFramesPerPoint), maximumFramesPerPoint(width: width))
    }
}
