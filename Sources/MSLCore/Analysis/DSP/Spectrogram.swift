import Foundation

/// 短時間フーリエ変換による振幅スペクトログラム。
public struct Spectrogram: Sendable {
    /// `magnitudes[frame][bin]`。振幅は窓の総和で正規化してある(フルスケールの正弦波でおよそ 0.5)。
    public let magnitudes: [[Float]]
    public let sampleRate: Double
    public let fftSize: Int
    public let hopSize: Int

    public var frameCount: Int { magnitudes.count }
    public var binCount: Int { fftSize / 2 + 1 }
    /// 1 秒あたりのフレーム数。
    public var frameRate: Double { sampleRate / Double(hopSize) }

    /// フレーム `index` の中心時刻(秒)。
    public func time(ofFrame index: Int) -> Double {
        Double(index * hopSize) / sampleRate
    }

    public func frame(atTime time: Double) -> Int {
        Int((time * frameRate).rounded())
    }

    public func frequency(ofBin bin: Int) -> Double {
        Double(bin) * sampleRate / Double(fftSize)
    }

    /// - Parameter progress: 0...1。
    public static func compute(
        samples: [Float],
        sampleRate: Double,
        fftSize: Int = 2048,
        hopSize: Int = 512,
        progress: (Double) -> Void = { _ in }
    ) throws -> Spectrogram {
        guard let fft = FFT(size: fftSize) else {
            preconditionFailure("fftSize must be a power of two")
        }
        let window = Window.hann(fftSize)
        let windowSum = window.reduce(0, +)
        let scale: Float = windowSum > 0 ? 1 / windowSum : 1
        let frameCount = samples.isEmpty ? 0 : samples.count / hopSize + 1
        var frames = [[Float]]()
        frames.reserveCapacity(frameCount)
        var buffer = [Float](repeating: 0, count: fftSize)
        let halfWindow = fftSize / 2

        for frameIndex in 0..<frameCount {
            if frameIndex % 64 == 0 {
                try Task.checkCancellation()
                progress(Double(frameIndex) / Double(max(1, frameCount)))
            }
            let center = frameIndex * hopSize
            let start = center - halfWindow
            for i in 0..<fftSize {
                let sampleIndex = start + i
                buffer[i] = (sampleIndex >= 0 && sampleIndex < samples.count) ? samples[sampleIndex] * window[i] : 0
            }
            var magnitudes = fft.magnitudes(buffer)
            for k in magnitudes.indices { magnitudes[k] *= scale }
            frames.append(magnitudes)
        }
        progress(1)
        return Spectrogram(magnitudes: frames, sampleRate: sampleRate, fftSize: fftSize, hopSize: hopSize)
    }
}

public enum Resampling {
    /// 整数倍の間引き。間引く前に区間平均をとるので、簡易的な折り返し防止になる。
    public static func decimate(_ samples: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return samples }
        let count = samples.count / factor
        var result = [Float](repeating: 0, count: count)
        let scale = 1 / Float(factor)
        for i in 0..<count {
            var sum: Float = 0
            let base = i * factor
            for j in 0..<factor { sum += samples[base + j] }
            result[i] = sum * scale
        }
        return result
    }

    /// 解析用に 22.05kHz 付近まで下げる間引き率。
    public static func analysisFactor(for sampleRate: Double) -> Int {
        max(1, Int(sampleRate / 22_050))
    }
}
