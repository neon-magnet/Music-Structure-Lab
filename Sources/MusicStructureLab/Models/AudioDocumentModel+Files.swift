import AppKit
import Foundation
import MSLAudio
import MSLCore
import UniformTypeIdentifiers

/// プロジェクトの保存・読み込みと、書き出し。
extension AudioDocumentModel {
    // MARK: - Save

    /// 上書き保存。まだ保存先が無ければ保存先を尋ねる。保存できたら true。
    @discardableResult
    func saveProject() -> Bool {
        if let projectURL {
            return writeProject(to: projectURL)
        }
        return saveProjectAs()
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        guard let audio else { return false }
        let panel = NSSavePanel()
        panel.title = "プロジェクトを保存"
        panel.allowedContentTypes = [.musicStructureLabProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (projectURL?.deletingPathExtension().lastPathComponent
            ?? audio.info.url.deletingPathExtension().lastPathComponent) + "." + ProjectDocument.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writeProject(to: url)
    }

    private func writeProject(to url: URL) -> Bool {
        guard let audio else { return false }
        let audioFileURL = audioURL ?? audio.info.url
        let reference = ProjectDocument.AudioReference(
            fileName: audio.info.fileName,
            path: audioFileURL.path,
            relativePath: ProjectDocument.relativePath(from: url, to: audioFileURL),
            bookmark: Self.bookmark(for: audioFileURL),
            frameCount: audio.info.frameCount,
            sampleRate: audio.info.sampleRate,
            channelCount: audio.info.channelCount
        )
        let document = ProjectDocument(audio: reference, analysis: analysis, notes: notes)
        do {
            let data = try document.encoded()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try data.write(to: url, options: .atomic)
            markSaved(to: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            errorMessage = "プロジェクトを保存できませんでした。(\(error.localizedDescription))"
            return false
        }
    }

    private static func bookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    // MARK: - Open

    func openProject(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let document: ProjectDocument
        do {
            document = try ProjectDocument.decode(from: Data(contentsOf: url))
        } catch let error as ProjectError {
            errorMessage = error.errorDescription
            return
        } catch {
            errorMessage = "プロジェクトを開けませんでした。(\(error.localizedDescription))"
            return
        }
        guard let audioFileURL = resolveAudio(document.audio, projectURL: url) else {
            errorMessage = ProjectError.audioNotFound(document.audio.fileName).errorDescription
            return
        }
        setPendingProject(document, url: url)
        openAudio(url: audioFileURL)
    }

    /// ブックマーク → 保存時のパス → プロジェクトからの相対パス の順に探し、見つからなければ利用者に尋ねる。
    private func resolveAudio(_ reference: ProjectDocument.AudioReference, projectURL: URL) -> URL? {
        if let bookmark = reference.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if FileManager.default.fileExists(atPath: reference.path) {
            return URL(fileURLWithPath: reference.path)
        }
        if let relative = reference.relativePath {
            let url = projectURL.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let panel = NSOpenPanel()
        panel.title = "音源ファイル「\(reference.fileName)」を探してください"
        panel.message = "プロジェクトが参照している音源が見つかりません。移動した場合は、その場所を指定してください。"
        panel.allowedContentTypes = AudioFileLoader.supportedContentTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 音源の読み込み後に、プロジェクトの内容を反映する。
    func applyProject(_ document: ProjectDocument, url: URL, audioInfo: AudioFileInfo) {
        notes = document.notes
        if let saved = document.analysis, document.audio.matches(audioInfo) {
            setAnalysis(saved)
            markSaved(to: url)
        } else {
            markSaved(to: url)
            if document.analysis != nil {
                errorMessage = ProjectError.audioMismatch(audioInfo.fileName).errorDescription
                    .map { $0 + "保存されていた解析結果は使わず、解析し直します。" }
            }
            analyze()
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    // MARK: - Export

    func export(_ format: ExportFormat) {
        guard let audio, let analysis else { return }
        let panel = NSSavePanel()
        panel.title = format.title + "を書き出す"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = audio.info.url.deletingPathExtension().lastPathComponent
            + format.fileNameSuffix + "." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try AnalysisExporter.data(format, analysis: analysis, source: ExportSource(info: audio.info))
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "書き出せませんでした。(\(error.localizedDescription))"
        }
    }

    /// 選択中のセクション(またはコード区間)の音声を WAV で書き出す。
    func exportSelectionAudio() {
        guard let audio, let range = selectionRange else { return }
        let baseName: String
        if let section = selectedSection {
            baseName = audio.info.url.deletingPathExtension().lastPathComponent + "-" + section.name
        } else {
            baseName = audio.info.url.deletingPathExtension().lastPathComponent + "-selection"
        }
        let panel = NSSavePanel()
        panel.title = "選択範囲の音声を書き出す"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = baseName.replacingOccurrences(of: "/", with: "-") + ".wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AudioExporter.writeWAV(audio, frames: range, to: url)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }
}
