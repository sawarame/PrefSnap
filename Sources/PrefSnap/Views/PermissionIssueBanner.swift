import PrefSnapCore
import SwiftUI

/// フルディスクアクセス等の権限不足や個別項目の読み書きエラーを表示し、
/// システム設定の該当画面（`x-apple.systempreferences:`）へ誘導するバナー。
struct PermissionIssueBanner: View {
    let issues: [ItemIssue]
    let onOpenSettings: (URL) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    hasPermissionIssue ? "アクセス権限が不足している項目があります" : "一部の項目でエラーが発生しました",
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

                Button("閉じる", action: onDismiss)
                    .buttonStyle(.borderless)
            }

            ForEach(issues.prefix(5)) { issue in
                HStack(spacing: 8) {
                    Text("・\(issue.itemTitle): \(issue.message)")
                        .font(.caption)
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

    private var hasPermissionIssue: Bool {
        issues.contains(where: \.isPermissionError)
    }
}
