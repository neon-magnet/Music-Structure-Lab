import AVFoundation
import CoreML
import Foundation
import MSLCore

public enum MLSeparationError: LocalizedError {
    case unsupportedModel(reason: String)
    case predictionFailed(reason: String)
    case resampleFailed

    public var errorDescription: String? {
        switch self {
        case let .unsupportedModel(reason):
            return "このモデルはパート分離に使えません。(\(reason))"
        case let .predictionFailed(reason):
            return "モデルでの分離に失敗しました。(\(reason))"
        case .resampleFailed:
            return "モデル用のサンプルレート変換に失敗しました。"
        }
    }
}

/// 利用者が用意した Core ML モデル(Demucs 系)でパートを分離する。
///
/// モデルに求める形(docs/STEM_MODEL.md も参照):
/// - 入力: Float32 の MultiArray 1 つ。形は [1, 2, L] または [2, L](ステレオ・L サンプル固定)。
/// - 出力: MultiArray 1 つ。形は [1, S, 2, L] または [S, 2, L]。
/// - パートの並び: メタデータ `sources`(例 "drums,bass,other,vocals")。無ければ Demucs の順とみなす。
/// - サンプルレート: メタデータ `sample_rate`。無ければ 44100Hz。
///
/// 曲全体の平均と標準偏差で正規化してから L ごとに区切って(25% 重ねて)推論し、重なりはなだらかにつなぐ。
/// `vocals` を ボーカル、`drums` を ドラム、`bass` を ベース、それ以外(other / guitar / piano など)を コード(伴奏) にまとめる。
/// モデルはメロディを出力しないので、伴奏系の音源ごとに旋律を推定し、フレームごとに旋律が最もはっきりした音源から
/// 音高追跡で メロディ を近似的に取り出す(`SpectralStemSeparator.splitMelody`)。htdemucs_6s ならギター・ピアノも別に扱える。
public final class MLStemSeparator {
    public let model: MLModel
    public let modelName: String
    let inputName: String
    let outputName: String
    let inputHasBatch: Bool
    let segmentLength: Int
    let sourceNames: [String]
    let modelSampleRate: Double
    let computeUnits: MLComputeUnits

    static func configuration(units: MLComputeUnits) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        return configuration
    }

    /// メタデータの値(cpuOnly / cpuAndGPU / all)から計算装置を選ぶ。無い・不明なら CPU + GPU。
    static func computeUnits(fromMetadata value: String?) -> MLComputeUnits {
        switch value {
        case "cpuOnly": return .cpuOnly
        case "all": return .all
        default: return .cpuAndGPU
        }
    }

    /// コンパイル済みのモデル (.mlmodelc) を読み込む。
    public init(compiledModelURL: URL, name: String? = nil) throws {
        // Neural Engine は内部で 16bit 浮動小数点を使い、Demucs では値があふれて結果が壊れることがある。
        // 既定は CPU + GPU とし、変換時に確かめた計算装置がメタデータ `compute_units` にあればそれを使う。
        let model: MLModel
        do {
            let probe = try MLModel(contentsOf: compiledModelURL, configuration: Self.configuration(units: .cpuAndGPU))
            let requested = (probe.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?["compute_units"]
            let units = Self.computeUnits(fromMetadata: requested)
            if units == .cpuAndGPU {
                model = probe
            } else {
                model = try MLModel(contentsOf: compiledModelURL, configuration: Self.configuration(units: units))
            }
            computeUnits = units
        } catch {
            throw MLSeparationError.unsupportedModel(reason: error.localizedDescription)
        }
        self.model = model
        modelName = name ?? compiledModelURL.deletingPathExtension().lastPathComponent

        let description = model.modelDescription
        let inputs = description.inputDescriptionsByName.filter { $0.value.type == .multiArray }
        let outputs = description.outputDescriptionsByName.filter { $0.value.type == .multiArray }
        guard inputs.count == 1, let input = inputs.first, let inputShape = input.value.multiArrayConstraint?.shape.map(\.intValue) else {
            throw MLSeparationError.unsupportedModel(reason: "MultiArray の入力が 1 つではありません")
        }
        guard outputs.count == 1, let output = outputs.first else {
            throw MLSeparationError.unsupportedModel(reason: "MultiArray の出力が 1 つではありません")
        }
        inputName = input.key
        outputName = output.key
        switch inputShape.count {
        case 3 where inputShape[0] == 1 && inputShape[1] == 2:
            inputHasBatch = true
            segmentLength = inputShape[2]
        case 2 where inputShape[0] == 2:
            inputHasBatch = false
            segmentLength = inputShape[1]
        default:
            throw MLSeparationError.unsupportedModel(reason: "入力の形 \(inputShape) は [1, 2, L] / [2, L] ではありません")
        }
        guard segmentLength >= 1024 else {
            throw MLSeparationError.unsupportedModel(reason: "入力の長さ \(segmentLength) が短すぎます")
        }

        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        if let sources = metadata["sources"] {
            sourceNames = sources.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        } else {
            sourceNames = ["drums", "bass", "other", "vocals"]
        }
        modelSampleRate = metadata["sample_rate"].flatMap(Double.init) ?? 44_100
        guard !sourceNames.isEmpty else {
            throw MLSeparationError.unsupportedModel(reason: "パートの名前がありません")
        }
    }

    /// .mlpackage / .mlmodel をコンパイルする。結果は一時フォルダに置かれる。
    public static func compileModel(at url: URL) async throws -> URL {
        do {
            return try await MLModel.compileModel(at: url)
        } catch {
            throw MLSeparationError.unsupportedModel(reason: error.localizedDescription)
        }
    }

    /// 画面に出すモデルの説明。
    public var summary: String {
        let seconds = Double(segmentLength) / modelSampleRate
        let units: String
        switch computeUnits {
        case .cpuOnly: units = "CPU"
        case .all: units = "CPU+GPU+Neural Engine"
        default: units = "CPU+GPU"
        }
        return "\(Int(modelSampleRate)) Hz・\(String(format: "%.1f", seconds)) 秒ごと・\(units)・パート: \(sourceNames.joined(separator: ", "))"
    }

    /// パート名を、アプリのパートに対応づける。
    static func stemKind(forSource name: String) -> StemKind {
        switch name {
        case "drums": return .drums
        case "bass": return .bass
        case "vocals", "vocal", "voice": return .vocals
        default: return .chords
        }
    }

    /// - Parameters:
    ///   - channels: 再生と同じチャンネル(モノラルかステレオ)。
    ///   - progress: 0...1。
    public func separate(channels: [[Float]], sampleRate: Double, progress: (Double) -> Void = { _ in }) throws -> StemSet {
        let frameCount = channels.map(\.count).min() ?? 0
        guard !channels.isEmpty, frameCount > 0 else {
            throw MLSeparationError.predictionFailed(reason: "音声がありません")
        }
        // モデルはステレオを受け取る。モノラルなら同じ音を両方に入れる。
        var stereo = channels.count >= 2 ? Array(channels.prefix(2)) : [channels[0], channels[0]]
        stereo = stereo.map { Array($0.prefix(frameCount)) }
        if abs(sampleRate - modelSampleRate) > 0.5 {
            stereo = try Self.resample(stereo, from: sampleRate, to: modelSampleRate)
        }
        let length = stereo[0].count

        // 曲全体の平均と標準偏差で正規化する(Demucs の推論と同じ)。
        var sum = 0.0
        var squares = 0.0
        for i in 0..<length {
            let value = Double((stereo[0][i] + stereo[1][i]) / 2)
            sum += value
            squares += value * value
        }
        let mean = sum / Double(length)
        let std = max(1e-8, (squares / Double(length) - mean * mean).squareRoot())
        let meanF = Float(mean)
        let scale = Float(1 / std)

        let segment = segmentLength
        let overlap = segment / 4
        let stride = segment - overlap
        let sourceCount = sourceNames.count
        var outputs = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: length), count: 2), count: sourceCount)
        var weightSum = [Float](repeating: 0, count: length)
        let fade = (0..<segment).map { i -> Float in
            // 重なり部分は直線で入れ替える。端の区間は 1 のまま(重みの和で割るので問題ない)。
            let fromStart = Float(i + 1) / Float(overlap + 1)
            let fromEnd = Float(segment - i) / Float(overlap + 1)
            return min(1, fromStart, fromEnd)
        }

        let inputShape = (inputHasBatch ? [1, 2, segment] : [2, segment]).map { NSNumber(value: $0) }
        let input = try MLMultiArray(shape: inputShape, dataType: .float32)
        let inputPointer = input.dataPointer.bindMemory(to: Float32.self, capacity: input.count)
        let inputStrides = input.strides.map(\.intValue)
        let channelStride = inputStrides[inputHasBatch ? 1 : 0]
        let sampleStride = inputStrides[inputHasBatch ? 2 : 1]

        let chunkCount = length <= segment ? 1 : (length - overlap + stride - 1) / stride
        for chunk in 0..<chunkCount {
            try Task.checkCancellation()
            progress(0.85 * Double(chunk) / Double(chunkCount))
            let offset = chunk * stride
            for channel in 0..<2 {
                for i in 0..<segment {
                    let index = offset + i
                    let value = index < length ? (stereo[channel][index] - meanF) * scale : 0
                    inputPointer[channel * channelStride + i * sampleStride] = value
                }
            }
            let result: MLFeatureProvider
            do {
                let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])
                result = try model.prediction(from: provider)
            } catch {
                throw MLSeparationError.predictionFailed(reason: error.localizedDescription)
            }
            guard let output = result.featureValue(for: outputName)?.multiArrayValue else {
                throw MLSeparationError.predictionFailed(reason: "出力 \(outputName) がありません")
            }
            let shape = output.shape.map(\.intValue)
            let strides = output.strides.map(\.intValue)
            let hasBatch = shape.count == 4
            guard shape.count == (hasBatch ? 4 : 3),
                  shape[hasBatch ? 1 : 0] == sourceCount,
                  shape[hasBatch ? 2 : 1] == 2,
                  shape[hasBatch ? 3 : 2] >= segment
            else {
                throw MLSeparationError.unsupportedModel(reason: "出力の形 \(shape) が [1, \(sourceCount), 2, \(segment)] ではありません")
            }
            let sourceStride = strides[hasBatch ? 1 : 0]
            let outChannelStride = strides[hasBatch ? 2 : 1]
            let outSampleStride = strides[hasBatch ? 3 : 2]
            let read = Self.reader(for: output)
            let valid = min(segment, length - offset)
            for source in 0..<sourceCount {
                for channel in 0..<2 {
                    let base = source * sourceStride + channel * outChannelStride
                    outputs[source][channel].withUnsafeMutableBufferPointer { destination in
                        for i in 0..<valid {
                            destination[offset + i] += read(base + i * outSampleStride) * fade[i]
                        }
                    }
                }
            }
            for i in 0..<valid { weightSum[offset + i] += fade[i] }
        }

        // 正規化を戻し、元のサンプルレート・チャンネル数に合わせる。
        var stems = [StemKind: [[Float]]]()
        var accompanimentSources = [[[Float]]]()
        var accompanimentNames = [String]()
        for (source, name) in sourceNames.enumerated() {
            var stem = outputs[source]
            for channel in 0..<2 {
                for i in 0..<length {
                    let w = weightSum[i]
                    stem[channel][i] = w > 0 ? stem[channel][i] / w / scale + meanF / Float(sourceCount) : 0
                }
            }
            if abs(sampleRate - modelSampleRate) > 0.5 {
                stem = try Self.resample(stem, from: modelSampleRate, to: sampleRate)
            }
            stem = stem.map { channel in
                var fitted = Array(channel.prefix(frameCount))
                if fitted.count < frameCount { fitted += [Float](repeating: 0, count: frameCount - fitted.count) }
                return fitted
            }
            if channels.count == 1 {
                stem = [zip(stem[0], stem[1]).map { ($0 + $1) / 2 }]
            }
            let kind = Self.stemKind(forSource: name)
            if kind == .chords {
                // 伴奏系の音源(other / guitar / piano)は、メロディを取り出すために別々に持っておく。
                accompanimentSources.append(stem)
                accompanimentNames.append(name)
                continue
            }
            if let existing = stems[kind] {
                stems[kind] = zip(existing, stem).map { pair in zip(pair.0, pair.1).map { $0 + $1 } }
            } else {
                stems[kind] = stem
            }
        }
        let silent = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channels.count)

        // メロディは、伴奏系の音源ごとに旋律を推定し、フレームごとに最もはっきりした音源から取り出す。
        var leadSummary = ""
        if !accompanimentSources.isEmpty {
            let split = try SpectralStemSeparator().splitMelody(from: accompanimentSources, sampleRate: sampleRate) { value in
                progress(0.85 + 0.15 * value)
            }
            stems[.melody] = split.melody
            stems[.chords] = split.rest
            if accompanimentSources.count > 1 {
                leadSummary = "・旋律の出どころ: " + zip(accompanimentNames, split.leadShare)
                    .map { "\($0) \(Int(($1 * 100).rounded()))%" }
                    .joined(separator: ", ")
            }
        }
        for kind in StemKind.allCases where stems[kind] == nil {
            stems[kind] = silent
        }
        progress(1)
        return StemSet(
            method: .mlModel,
            detail: "\(modelName)(\(sourceNames.joined(separator: ", ")))+ メロディは伴奏系の音源から音高追跡\(leadSummary)",
            sampleRate: sampleRate,
            frameCount: frameCount,
            stems: stems
        )
    }

    /// 出力の要素を Float で読む関数(Float32 以外の型にも対応する)。
    static func reader(for array: MLMultiArray) -> (Int) -> Float {
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            return { pointer[$0] }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            return { Float(pointer[$0]) }
        default:
            // Float16 など。遅いが確実な方法で読む。
            return { array[$0].floatValue }
        }
    }

    /// AVAudioConverter でサンプルレートを変換する。
    static func resample(_ channels: [[Float]], from source: Double, to target: Double) throws -> [[Float]] {
        let count = channels.map(\.count).min() ?? 0
        guard count > 0,
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: source, channels: AVAudioChannelCount(channels.count)),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: target, channels: AVAudioChannelCount(channels.count)),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let inputData = inputBuffer.floatChannelData
        else { throw MLSeparationError.resampleFailed }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { pointer in
                inputData[index].update(from: pointer.baseAddress!, count: count)
            }
        }
        inputBuffer.frameLength = AVAudioFrameCount(count)
        let capacity = AVAudioFrameCount(Double(count) * target / source + 4096)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw MLSeparationError.resampleFailed
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil, let outputData = outputBuffer.floatChannelData else {
            throw MLSeparationError.resampleFailed
        }
        let produced = Int(outputBuffer.frameLength)
        return (0..<channels.count).map { Array(UnsafeBufferPointer(start: outputData[$0], count: produced)) }
    }
}
