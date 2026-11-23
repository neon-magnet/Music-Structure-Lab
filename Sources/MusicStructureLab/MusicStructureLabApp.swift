import AppKit
import SwiftUI

@main
struct MusicStructureLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AudioDocumentModel()

    var body: some Scene {
        Window("Music Structure Lab", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear {
                    appDelegate.openHandler = { [weak model] url in model?.open(url: url) }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("開く…") { model.isImporterPresented = true }
                    .keyboardShortcut("o")
                Button("閉じる") { model.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.audio == nil && !model.isLoading)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder から開かれたファイルを受け取る。ウィンドウ表示前に届いた分は保留しておく。
    var openHandler: ((URL) -> Void)? {
        didSet {
            guard let openHandler, !pendingURLs.isEmpty else { return }
            pendingURLs.forEach(openHandler)
            pendingURLs.removeAll()
        }
    }

    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` で .app バンドルなしに起動した場合でも、通常のアプリとして前面に出す。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let openHandler {
            openHandler(url)
        } else {
            pendingURLs = [url]
        }
    }
}
