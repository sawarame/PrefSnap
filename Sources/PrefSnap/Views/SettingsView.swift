import PrefSnapCore
import SwiftUI

/// アプリのバージョン情報および自動アップデート設定・手動確認を提供する設定画面。
struct SettingsView: View {
    @Bindable var updateViewModel: UpdateViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                appInfoCard
                updateSettingsCard
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 画面上部のタイトルと説明。
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("設定")
                .font(.title2.bold())
            Text("アプリのバージョン情報および GitHub Releases を用いたアップデート確認設定を管理します。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// アプリ名・現在バージョン・実行種別を表示するカード。
    private var appInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("アプリケーション情報")
                .font(.headline)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(updateViewModel.currentIdentity.displayName)
                            .font(.title3.weight(.semibold))
                        if updateViewModel.currentIdentity.isDevelopmentBuild {
                            Text("開発版")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }

                    Text(updateViewModel.currentVersionInfo.displayText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18))
        )
    }

    /// 自動チェック設定・手動確認ボタン・結果フィードバックを表示するカード。
    private var updateSettingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("アップデート")
                .font(.headline)

            Toggle(isOn: $updateViewModel.autoCheckForUpdates) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("起動時にアップデートを自動チェック")
                        .font(.body)
                    Text("ON にすると、配布版 PrefSnap の起動時に GitHub Releases の最新安定版を自動確認します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if updateViewModel.currentIdentity.isDevelopmentBuild {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("現在はローカル開発版として実行されているため、起動時自動チェックおよびアプリ内自動差し替えは無効です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    Task {
                        await updateViewModel.checkForUpdatesManually()
                    }
                } label: {
                    Label("アップデートを確認", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!updateViewModel.canCheckForUpdates)

                if updateViewModel.isChecking {
                    ProgressView()
                        .controlSize(.small)
                    Text("最新バージョンを確認中…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("GitHub Releases を開く") {
                    updateViewModel.openReleasesPage()
                }
                .buttonStyle(.link)
            }

            if let feedback = updateViewModel.checkFeedback {
                feedbackView(for: feedback)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18))
        )
    }

    /// 確認結果に応じたフィードバックバナーを構築する。
    /// - Parameter feedback: 表示対象の確認結果
    /// - Returns: 状態ごとのフィードバックビュー
    @ViewBuilder
    private func feedbackView(for feedback: UpdateCheckFeedback) -> some View {
        switch feedback {
        case .upToDate(let version):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("お使いの \(updateViewModel.currentIdentity.displayName)（バージョン \(version.normalized)）は最新です。")
                    .font(.callout)
                Spacer()
            }
            .padding(12)
            .background(Color.green.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .updateAvailable(let release):
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新しいバージョン（\(release.version.normalized)）が利用可能です。")
                        .font(.callout.weight(.medium))
                    Text("詳細の確認やアップデート適用を行えます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("更新詳細を表示") {
                    updateViewModel.presentAvailableUpdatePrompt()
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .developmentBuild:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ローカル開発版のため、自動アップデートの対象外です。")
                        .font(.callout.weight(.medium))
                    Text("配布版をインストール・更新する場合は GitHub Releases ページをご利用ください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("GitHub Releases を開く") {
                        updateViewModel.openReleasesPage()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .error(let message, let showReleasesLink):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if showReleasesLink {
                        Button("GitHub Releases を開く") {
                            updateViewModel.openReleasesPage()
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
