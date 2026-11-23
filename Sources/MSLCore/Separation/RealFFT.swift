import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// 実数信号の FFT と逆 FFT(複素スペクトルを扱う)。パート分離の STFT / 逆 STFT に使う。
///
/// スペクトルは 0Hz からナイキストまでの `size / 2 + 1` 個の複素数(実部・虚部の配列)で表す。
/// 正規化は `inverse(forward(x)) == x` となるようにしている。
/// 内部に作業領域を持つので、1 つのインスタンスを複数のスレッドから同時に使わないこと。
public final class RealFFT {
    public let size: Int
    public var binCount: Int { size / 2 + 1 }
    let log2n: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]
    private var workRe: [Float]
    private var workIm: [Float]
    #if canImport(Accelerate)
    private let setup: FFTSetup?
    private var splitRe: [Float]
    private var splitIm: [Float]
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
        workRe = [Float](repeating: 0, count: size)
        workIm = [Float](repeating: 0, count: size)
        #if canImport(Accelerate)
        setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))
        splitRe = [Float](repeating: 0, count: size / 2)
        splitIm = [Float](repeating: 0, count: size / 2)
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        if let setup { vDSP_destroy_fftsetup(setup) }
        #endif
    }

    /// 順変換。`real` と `imag` は長さ `binCount` に揃えて返す。
    public func forward(_ input: [Float], real: inout [Float], imag: inout [Float]) {
        precondition(input.count == size, "input length must equal FFT size")
        #if canImport(Accelerate)
        if let setup {
            accelerateForward(input, real: &real, imag: &imag, setup: setup)
            return
        }
        #endif
        referenceForward(input, real: &real, imag: &imag)
    }

    /// 逆変換。`output` は長さ `size` に揃えて返す。
    public func inverse(real: [Float], imag: [Float], output: inout [Float]) {
        precondition(real.count == binCount && imag.count == binCount, "spectrum length must equal binCount")
        #if canImport(Accelerate)
        if let setup {
            accelerateInverse(real: real, imag: imag, output: &output, setup: setup)
            return
        }
        #endif
        referenceInverse(real: real, imag: imag, output: &output)
    }

    // MARK: - Reference

    /// プラットフォームに依存しない順変換(テストの基準としても使う)。
    public func referenceForward(_ input: [Float], real: inout [Float], imag: inout [Float]) {
        precondition(input.count == size, "input length must equal FFT size")
        for i in 0..<size {
            workRe[bitReverse[i]] = input[i]
            workIm[bitReverse[i]] = 0
        }
        transformWork(inverse: false)
        if real.count != binCount { real = [Float](repeating: 0, count: binCount) }
        if imag.count != binCount { imag = [Float](repeating: 0, count: binCount) }
        for k in 0..<binCount {
            real[k] = workRe[k]
            imag[k] = workIm[k]
        }
    }

    /// プラットフォームに依存しない逆変換。
    public func referenceInverse(real: [Float], imag: [Float], output: inout [Float]) {
        let half = size / 2
        // エルミート対称な全スペクトルを組み立ててから逆変換する。
        for k in 0..<size {
            let re: Float
            let im: Float
            if k <= half {
                re = real[k]
                im = (k == 0 || k == half) ? 0 : imag[k]
            } else {
                re = real[size - k]
                im = -imag[size - k]
            }
            workRe[bitReverse[k]] = re
            workIm[bitReverse[k]] = im
        }
        transformWork(inverse: true)
        if output.count != size { output = [Float](repeating: 0, count: size) }
        let scale = 1 / Float(size)
        for i in 0..<size {
            output[i] = workRe[i] * scale
        }
    }

    /// ビット反転済みの `workRe` / `workIm` に対するバタフライ演算。
    private func transformWork(inverse: Bool) {
        let sign: Float = inverse ? 1 : -1
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for j in 0..<half {
                    let k = j * step
                    let wr = cosTable[k]
                    let wi = sign * sinTable[k]
                    let a = start + j
                    let b = a + half
                    let tr = workRe[b] * wr - workIm[b] * wi
                    let ti = workRe[b] * wi + workIm[b] * wr
                    workRe[b] = workRe[a] - tr
                    workIm[b] = workIm[a] - ti
                    workRe[a] += tr
                    workIm[a] += ti
                }
                start += length
            }
            length *= 2
        }
    }

    // MARK: - Accelerate

    #if canImport(Accelerate)
    private func accelerateForward(_ input: [Float], real: inout [Float], imag: inout [Float], setup: FFTSetup) {
        let half = size / 2
        if real.count != binCount { real = [Float](repeating: 0, count: binCount) }
        if imag.count != binCount { imag = [Float](repeating: 0, count: binCount) }
        let log2n = vDSP_Length(self.log2n)
        splitRe.withUnsafeMutableBufferPointer { rePointer in
            splitIm.withUnsafeMutableBufferPointer { imPointer in
                var split = DSPSplitComplex(realp: rePointer.baseAddress!, imagp: imPointer.baseAddress!)
                input.withUnsafeBufferPointer { inputPointer in
                    inputPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        // vDSP の順変換は 2 倍された値を返す。DC とナイキストは realp[0] / imagp[0] に詰められている。
        real[0] = splitRe[0] / 2
        imag[0] = 0
        real[half] = splitIm[0] / 2
        imag[half] = 0
        for k in 1..<half {
            real[k] = splitRe[k] / 2
            imag[k] = splitIm[k] / 2
        }
    }

    private func accelerateInverse(real: [Float], imag: [Float], output: inout [Float], setup: FFTSetup) {
        let half = size / 2
        if output.count != size { output = [Float](repeating: 0, count: size) }
        splitRe[0] = real[0]
        splitIm[0] = real[half]
        for k in 1..<half {
            splitRe[k] = real[k]
            splitIm[k] = imag[k]
        }
        let log2n = vDSP_Length(self.log2n)
        splitRe.withUnsafeMutableBufferPointer { rePointer in
            splitIm.withUnsafeMutableBufferPointer { imPointer in
                var split = DSPSplitComplex(realp: rePointer.baseAddress!, imagp: imPointer.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                output.withUnsafeMutableBufferPointer { outputPointer in
                    outputPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPointer in
                        vDSP_ztoc(&split, 1, complexPointer, 2, vDSP_Length(half))
                    }
                }
            }
        }
        // 真のスペクトルを渡した vDSP の逆変換は size 倍の値を返す。
        var scale = 1 / Float(size)
        output.withUnsafeMutableBufferPointer { pointer in
            vDSP_vsmul(pointer.baseAddress!, 1, &scale, pointer.baseAddress!, 1, vDSP_Length(size))
        }
    }
    #endif
}
