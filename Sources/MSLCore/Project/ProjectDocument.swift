import Foundation

/// プロジェクトファイル (.mslab)。音源への参照と、解析・編集の結果を JSON で保存する。
/// 音源そのものは含めない。
public struct ProjectDocument: Codable, Equatable, Sendable {
    public static let fileExtension = "mslab"
    public static let currentFormatVersion = 1

    public struct AudioReference: Codable, Equatable, Sendable {
        public var fileName: String
        /// 保存時の絶対パス。
        public var path: String
        /// プロジェクトファイルからの相対パス(同じフォルダ構成で移動した時に使う)。
        public var relativePath: String?
        /// セキュリティスコープ付きブックマーク(サンドボックス環境で再び開くために使う)。
        public var bookmark: Data?
        public var frameCount: Int
        public var sampleRate: Double
        public var channelCount: Int

        public init(
            fileName: String,
            path: String,
            relativePath: String?,
            bookmark: Data?,
            frameCount: Int,
            sampleRate: Double,
            channelCount: Int
        ) {
            self.fileName = fileName
            self.path = path
            self.relativePath = relativePath
            self.bookmark = bookmark
            self.frameCount = frameCount
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }

        /// 開いた音源が保存時と同じものか(長さとサンプルレートで確認する)。
        public func matches(_ info: AudioFileInfo) -> Bool {
            info.frameCount == frameCount && abs(info.sampleRate - sampleRate) < 0.5
        }
    }

    public var formatVersion: Int
    public var audio: AudioReference
    public var analysis: AnalysisResult?
    /// 作曲・分析のメモ。
    public var notes: String
    public var savedAt: Date

    public init(audio: AudioReference, analysis: AnalysisResult?, notes: String, savedAt: Date = Date()) {
        self.formatVersion = Self.currentFormatVersion
        self.audio = audio
        self.analysis = analysis
        self.notes = notes
        self.savedAt = savedAt
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> ProjectDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ProjectDocument.self, from: data)
        guard document.formatVersion <= currentFormatVersion else {
            throw ProjectError.newerFormat(document.formatVersion)
        }
        return document
    }

    /// `base` のフォルダから `target` への相対パス。
    public static func relativePath(from base: URL, to target: URL) -> String? {
        let baseComponents = base.deletingLastPathComponent().standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }
        guard common > 0 else { return nil }
        let ups = Array(repeating: "..", count: baseComponents.count - common)
        let rest = Array(targetComponents[common...])
        return (ups + rest).joined(separator: "/")
    }
}

public enum ProjectError: LocalizedError, Equatable {
    case newerFormat(Int)
    case audioNotFound(String)
    case audioMismatch(String)

    public var errorDescription: String? {
        switch self {
        case let .newerFormat(version):
            return "このプロジェクトは新しい形式 (バージョン \(version)) で保存されています。アプリを更新してください。"
        case let .audioNotFound(name):
            return "音源ファイル「\(name)」が見つかりませんでした。"
        case let .audioMismatch(name):
            return "「\(name)」は保存時の音源と長さが違います。"
        }
    }
}
