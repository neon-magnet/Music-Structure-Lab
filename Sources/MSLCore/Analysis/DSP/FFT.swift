import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// 実数信号の振幅スペクトルを求める FFT。
///
/// Apple プラットフォームでは Accelerate (vDSP) を使い、それ以外では同じ結果を返す
/// Swift 実装を使う(テストで両者が一致することを確認している)。
public final class FFT {
    public let size: Int
    let log2n: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]
    #if canImport(Accelerate)
    private let setup: FFTSetup?
    #endif

    /// `size` は 2 のべき乗(4 以上)。
    public init?(size: Int) {
        guard size >= 4, size & (size - 1) == 0 else { return nil }
        self.size = size
        var log2n = 0
        while (1 << log2n) < size { log2n += 1 }
        self.log2n = log2n
        cosTable = (0..<(size / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<(size / 2)).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        bitReverse = (0..<size).map { index in
            var reversed = 0
            var value = index
            for _ in 0..<log2n {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            return reversed
        }
        #if canImport(Accelerate)
        setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        if let setup { vDSP_destroy_fftsetup(setup) }
        #endif
    }

    /// `input`(長さ `size`)の振幅スペクトル。長さ `size / 2 + 1`(0Hz からナイキストまで)。
    public func magnitudes(_ input: [Float]) -> [Float] {
        precondition(input.count == size, "input length must equal FFT size")
        #if canImport(Accelerate)
        if let setup {
            return accelerateMagnitudes(input, setup: setup)
        }
        #endif
        return referenceMagnitudes(input)
    }

    /// プラットフォームに依存しない実装(テストの基準としても使う)。
    public func referenceMagnitudes(_ input: [Float]) -> [Float] {
        precondition(input.count == size, "input length must equal FFT size")
        var re = [Float](repeating: 0, count: size)
        var im = [Float](repeating: 0, count: size)
        for i in 0..<size {
            re[bitReverse[i]] = input[i]
        }
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for j in 0..<half {
                    let k = j * step
                    let wr = cosTable[k]
                    let wi = -sinTable[k]
                    let a = start + j
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += length
            }
            length *= 2
        }
        var result = [Float](repeating: 0, count: size / 2 + 1)
        for k in 0...(size / 2) {
            result[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot()
        }
        return result
    }

    #if canImport(Accelerate)
    private func accelerateMagnitudes(_ input: [Float], setup: FFTSetup) -> [Float] {
        let half = size / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var result = [Float](repeating: 0, count: half + 1)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                input.withUnsafeBufferPointer { inputPointer in
                    inputPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                // vDSP の結果は 2 倍されている。DC とナイキストは realp[0] / imagp[0] に詰められている。
                result[0] = abs(split.realp[0]) / 2
                result[half] = abs(split.imagp[0]) / 2
                for k in 1..<half {
                    let r = split.realp[k]
                    let i = split.imagp[k]
                    result[k] = (r * r + i * i).squareRoot() / 2
                }
            }
        }
        return result
    }
    #endif
}

public enum Window {
    /// Hann 窓。
    public static func hann(_ size: Int) -> [Float] {
        guard size > 1 else { return [1] }
        return (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
    }
}
