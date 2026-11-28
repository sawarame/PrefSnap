import PrefSnapCore
import SwiftUI

/// 新しい安定版リリース検出時にメインウィンドウ上のシートとして表示する更新確認ダイアログ。
struct UpdatePromptView: View {
    @Bindable var updateViewModel: UpdateViewModel
    /// PrefSnap 本体がスキャン・適用・ロールバック処理中かどうか。
    let isAppBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            Divider()

            releaseNotesSection

            if let ineligibilityMessage = updateViewModel.installEligibility.ineligibilityMessage {
                statusBanner(
                    iconName: "exclamationmark.circle.fill",
                    tintColor: .orange,
                    message: ineligibilityMessage
                )
            }

            if isAppBusy && !updateViewModel.isInstalling {
                statusBanner(
                    iconName: "hourglass",
                    tintColor: .orange,
                    message: AppUpdateError.appIsBusy.localizedDescription
                )
            }

            if let errorMessage = updateViewModel.promptErrorMessage {
                statusBanner(
                    iconName: "exclamationmark.triangle.fill",
                    tintColor: .red,
                    message: errorMessage
                )
            }

            if let progress = updateViewModel.installProgress {
                progressSection(progress: progress)
            }

            Divider()

            actionBar
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 420)
        .interactiveDismissDisabled(updateViewModel.isInstalling)
    }

    /// タイトル・バージョン遷移・GitHub リリースページリンクを表示するヘッダー。
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("新しいアップデートが利用可能です")
                    .font(.title3.bold())
                Text(updateViewModel.versionTransitionText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    if let title = updateViewModel.availableRelease?.title, !title.isEmpty {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("GitHub でリリースページを開く") {
                        updateViewModel.openAvailableReleasePage()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Spacer()
        }
    }

    /// スクロール可能なリリースノート表示エリア。
    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("リリースノート")
                .font(.subheadline.weight(.semibold))

            ScrollView {
                let notes = updateViewModel.availableRelease?.releaseNotes
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Text(notes.isEmpty ? "リリースノートはありません。" : notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 160, maxHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2))
            )
        }
    }

    /// ダウンロード・検証・展開・適用準備の進捗バーとフェーズ文言を表示するセクション。
    /// - Parameter progress: 現在の進捗情報
    /// - Returns: 進捗表示ビュー
    @ViewBuilder
    private func progressSection(progress: UpdateInstallProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction, total: 1.0)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(progress.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 警告またはエラー内容を表示する共通バナー。
    /// - Parameters:
    ///   - iconName: SF Symbols アイコン名
    ///   - tintColor: バナーの強調色
    ///   - message: 表示する日本語メッセージ
    /// - Returns: バナービュー
    private func statusBanner(iconName: String, tintColor: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tintColor)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(tintColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 「このバージョンをスキップ」「後で」「今すぐアップデート / GitHub Releases を開く」ボタン群。
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("このバージョンをスキップ") {
                updateViewModel.skipAvailableVersion()
            }
            .disabled(updateViewModel.isInstalling)

            Spacer()

            Button("後で") {
                updateViewModel.deferUpdate()
            }
            .disabled(updateViewModel.isInstalling)

            if updateViewModel.installEligibility.isEligible {
                Button("今すぐアップデート") {
                    Task {
                        await updateViewModel.startUpdateInstall()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(updateViewModel.isInstalling || isAppBusy)
            } else {
                Button("GitHub Releases を開く") {
                    updateViewModel.openAvailableReleasePage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(updateViewModel.isInstalling)
            }
        }
    }
}
