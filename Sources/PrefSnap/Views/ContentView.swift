import PrefSnapCore
import SwiftUI

/// アプリ全体のルート画面。
/// macOS 26 (Tahoe) 以降で `NavigationSplitView` のタイトルバー透過オーバーレイにより
/// ウィンドウ左上ボタンとサイドバー先頭項目が重なる問題を構造的に回避するため、
/// 標準タイトルバーの下に固定左メニューとメイン画面を並べる構成を採用している。
struct ContentView: View {
    @Bindable var viewModel: AppViewModel

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
