import PrefSnapCore
import SwiftUI

/// フルディスクアクセス等の権限不足や個別項目の読み書きエラーを表示し、
/// システム設定の該当画面（`x-apple.systempreferences:`）への誘導および全件コピーを提供するバナー。
struct PermissionIssueBanner: View {
    let issues: [ItemIssue]
    let diagnosticEnvironment: DiagnosticEnvironment
    let onOpenSettings: (URL) -> Void
    let onDismiss: () -> Void

    /// 権限・エラーバナーを初期化する。
    /// - Parameters:
    ///   - issues: 表示および全件コピー対象の警告・エラー一覧
    ///   - diagnosticEnvironment: コピー文字列へ付与する環境情報（既定値は現在環境）
    ///   - onOpenSettings: システム設定画面を開くコールバック
    ///   - onDismiss: バナーを閉じるコールバック
    init(
        issues: [ItemIssue],
        diagnosticEnvironment: DiagnosticEnvironment = .current(),
        onOpenSettings: @escaping (URL) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.issues = issues
        self.diagnosticEnvironment = diagnosticEnvironment
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    bannerTitle,
                    systemImage: hasPermissionIssue ? "lock.shield.fill" : "exclamationmark.circle.fill"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Spacer()

                if let primaryURL = issues.compactMap(\.systemSettingsURL).first {
                    Button {
                        onOpenSettings(primaryURL)
                    } label: {
                        Label("システム設定を開く", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                }

                CopyReportButton {
                    ErrorReportFormatter.formatIssues(
                        title: bannerTitle,
                        issues: issues,
                        environment: diagnosticEnvironment
                    )
                }

                Button("閉じる", action: onDismiss)
                    .buttonStyle(.borderless)
            }

            ForEach(issues.prefix(5)) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Text("・\(issue.itemTitle): \(issue.message)")
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let url = issue.systemSettingsURL {
                        Button("設定画面へ") {
                            onOpenSettings(url)
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            }

            if issues.count > 5 {
                Text("ほか \(issues.count - 5) 件の警告があります。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    /// バナー見出しおよびコピー時のタイトル文言を返す。
    /// - Returns: 権限エラーの有無に応じた日本語見出し文字列
    private var bannerTitle: String {
        hasPermissionIssue ? "アクセス権限が不足している項目があります" : "一部の項目でエラーが発生しました"
    }

    /// 権限不足エラーが 1 件以上含まれているかを返す。
    /// - Returns: 権限不足エラーが含まれる場合は `true`
    private var hasPermissionIssue: Bool {
        issues.contains(where: \.isPermissionError)
    }
}
