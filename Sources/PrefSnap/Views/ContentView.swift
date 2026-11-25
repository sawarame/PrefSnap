import PrefSnapCore
import SwiftUI

/// アプリ全体のルート画面。左サイドバーで Export / Import / ロールバックを切り替える。
struct ContentView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $viewModel.selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("PrefSnap")
            .listStyle(.sidebar)
            .frame(minWidth: 220)
        } detail: {
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
        }
        .onAppear {
            viewModel.refreshBackups()
        }
    }
}
