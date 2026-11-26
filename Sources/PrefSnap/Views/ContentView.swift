import AppKit
import PrefSnapCore
import SwiftUI

/// SwiftUI ビューが属する `NSWindow` を取得し、ウィンドウ接続時に通知するための補助ビュー。
private struct MainWindowAccessor: NSViewRepresentable {
    /// `NSWindow` へアタッチされた際に呼び出されるコールバック。
    let onWindowAttached: @MainActor (NSWindow) -> Void

    /// `NSWindow` のアタッチを検知するカスタム `NSView`。
    final class ObservingView: NSView {
        /// ウィンドウ接続時の通知ハンドラ。
        var onWindowAttached: (@MainActor (NSWindow) -> Void)?

        /// ビューがウィンドウへ移動したタイミングで `NSWindow` を通知する。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowAttached?(window)
            }
        }
    }

    /// 監視用の `NSView` を生成する。
    /// - Parameter context: SwiftUI から渡されるコンテキスト
    /// - Returns: 生成した `ObservingView`
    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView(frame: .zero)
        view.onWindowAttached = onWindowAttached
        return view
    }

    /// ビュー更新時にハンドラを最新化し、すでにウィンドウへ接続済みであれば通知する。
    /// - Parameters:
    ///   - nsView: 更新対象の `ObservingView`
    ///   - context: SwiftUI から渡されるコンテキスト
    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onWindowAttached = onWindowAttached
        if let window = nsView.window {
            onWindowAttached(window)
        }
    }
}

/// アプリ全体のルート画面。
/// macOS 26 (Tahoe) 以降で `NavigationSplitView` のタイトルバー透過オーバーレイにより
/// ウィンドウ左上ボタンとサイドバー先頭項目が重なる問題を構造的に回避するため、
/// 標準タイトルバーの下に固定左メニューとメイン画面を並べる構成を採用している。
struct ContentView: View {
    @Bindable var viewModel: AppViewModel
    /// メインウィンドウが利用可能になった際に呼び出されるコールバック。
    var onMainWindowAttached: (@MainActor (NSWindow) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            sidebarMenu
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            VStack(spacing: 0) {
                if let errorBanner = viewModel.errorBannerMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorBanner)
                            .font(.callout)
                        Spacer()
                        Button("閉じる") {
                            viewModel.errorBannerMessage = nil
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.12))
                }

                if !viewModel.activeIssues.isEmpty {
                    PermissionIssueBanner(
                        issues: viewModel.activeIssues,
                        onOpenSettings: { url in viewModel.openSystemSettings(url) },
                        onDismiss: { viewModel.activeIssues = [] }
                    )
                }

                Group {
                    switch viewModel.selectedSection {
                    case .export:
                        ExportView(viewModel: viewModel)
                    case .importDiff:
                        ImportView(viewModel: viewModel)
                    case .rollback:
                        RollbackView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background {
            if let onMainWindowAttached {
                MainWindowAccessor(onWindowAttached: onMainWindowAttached)
            }
        }
        .onAppear {
            viewModel.refreshBackups()
        }
    }

    /// 常に全項目が視認できる固定左メニュー。
    private var sidebarMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("メニュー")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ForEach(AppSection.allCases) { section in
                let isSelected = viewModel.selectedSection == section
                Button {
                    viewModel.selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 18)
                        Text(section.rawValue)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}
