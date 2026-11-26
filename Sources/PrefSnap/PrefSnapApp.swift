import AppKit
import SwiftUI

/// `swift run PrefSnap` 経由で起動された場合も通常の macOS アプリとして
/// Dock 表示・前面フォーカスおよび Dock アイコン設定を有効にするための AppDelegate。
@MainActor
final class PrefSnapAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        applyRuntimeDockIconIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// `.app` バンドル経由ではない直接実行（`swift run PrefSnap` 等）の場合のみ、
    /// ビルド構成に応じたアイコン画像を Dock へ設定する。
    /// `.app` バンドル実行時は `Info.plist` と `AppIcon.icns` に任せ、
    /// `Bundle.module` へアクセスせずに早期リターンすることで安全性を確保する。
    private func applyRuntimeDockIconIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return
        }

        #if DEBUG
        let iconResourceName = "AppIcon_dev"
        #else
        let iconResourceName = "AppIcon"
        #endif

        guard let iconURL = Bundle.module.url(
            forResource: iconResourceName,
            withExtension: "png",
            subdirectory: "Resources"
        ),
        let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }

        NSApplication.shared.applicationIconImage = iconImage
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
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 720)
    }
}
