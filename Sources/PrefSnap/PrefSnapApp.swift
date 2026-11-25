import AppKit
import SwiftUI

/// `swift run PrefSnap` 経由で起動された場合も通常の macOS アプリとして
/// Dock 表示・前面フォーカスを有効にするための AppDelegate。
@MainActor
final class PrefSnapAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct PrefSnapApp: App {
    @NSApplicationDelegateAdaptor(PrefSnapAppDelegate.self) private var appDelegate
    private let viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("PrefSnap") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 720)
    }
}
