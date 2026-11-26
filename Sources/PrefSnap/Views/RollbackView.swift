import PrefSnapCore
import SwiftUI

/// `~/Library/Application Support/PrefSnap/Backups/` に自動保存されたバックアップファイル一覧から
/// 復元したいファイルを選択し、元の状態へロールバックする画面。
struct RollbackView: View {
    @Bindable var viewModel: AppViewModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 10) {
                Text("履歴 / ロールバック")
                    .font(.title2.bold())

                Text("保存場所: \(viewModel.backupDirectoryPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)

                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.refreshBackups()
                    } label: {
                        Label("一覧を更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(viewModel.isBusy)

                    if let selected = viewModel.selectedBackup {
                        Button {
                            viewModel.executeRollback(to: selected)
                        } label: {
                            Label("選択したバックアップへ復元", systemImage: "arrow.uturn.backward.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .fixedSize()
                        .disabled(viewModel.isBusy)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)

            Divider()

            if let result = viewModel.lastRollbackResult {
                VStack(alignment: .leading, spacing: 6) {
                    Label("ロールバックが完了しました（復元: \(result.appliedCount) 件）", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    if !result.restartedProcesses.isEmpty {
                        Text("再起動したプロセス: \(result.restartedProcesses.map(\.rawValue).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if result.requiresRelogin {
                        Text("再ログインが必要な項目が含まれます: \(result.reloginRequiredItems.joined(separator: "、"))")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if viewModel.backups.isEmpty {
                ContentUnavailableView(
                    "バックアップ履歴はまだありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("インポートによる設定適用を実行すると、直前の状態が自動的にここへ保存されます。")
                )
            } else {
                HSplitView {
                    List(viewModel.backups, selection: Binding(
                        get: { viewModel.selectedBackupID },
                        set: { newID in
                            viewModel.selectedBackupID = newID
                            if let record = viewModel.backups.first(where: { $0.id == newID }) {
                                viewModel.loadRollbackPreview(for: record)
                            }
                        }
                    )) { record in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(Self.dateFormatter.string(from: record.createdAt))
                                        .font(.headline)
                                    if record.id == viewModel.backups.first?.id {
                                        Text("直前")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(record.fileName)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if let host = record.hostName {
                                    Text("ホスト: \(host)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 4)

                            // 行選択との誤操作を避けるため、右端に独立したゴミ箱ボタンを配置する
                            Button(role: .destructive) {
                                viewModel.pendingDeleteBackup = record
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                            }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.isBusy)
                            .accessibilityLabel("バックアップ「\(record.fileName)」を削除")
                            .help("このバックアップをゴミ箱へ移動")
                        }
                        .padding(.vertical, 4)
                        .tag(record.id)
                    }
                    .frame(minWidth: 280, maxWidth: 360)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("このバックアップへ戻すと変更される項目（\(viewModel.rollbackPreviewItems.count) 件）")
                            .font(.headline)
                        if viewModel.rollbackPreviewItems.isEmpty {
                            ContentUnavailableView(
                                "現在の設定と差分はありません",
                                systemImage: "checkmark.seal",
                                description: Text("現在の Mac は選択したバックアップと同一の状態です。")
                            )
                        } else {
                            List(viewModel.rollbackPreviewItems) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.body.bold())
                                    HStack(spacing: 6) {
                                        Text(item.beforeDisplay)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right")
                                            .font(.caption2)
                                        Text(item.afterDisplay)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .listStyle(.inset)
                        }
                    }
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(20)
        .onAppear {
            viewModel.refreshBackups()
        }
        .alert(
            "バックアップ履歴をゴミ箱へ移動しますか？",
            isPresented: Binding(
                get: { viewModel.pendingDeleteBackup != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.pendingDeleteBackup = nil
                    }
                }
            ),
            presenting: viewModel.pendingDeleteBackup
        ) { record in
            Button("ゴミ箱へ移動", role: .destructive) {
                viewModel.pendingDeleteBackup = nil
                viewModel.deleteBackup(record)
            }
            Button("キャンセル", role: .cancel) {
                viewModel.pendingDeleteBackup = nil
            }
        } message: { record in
            Text(
                """
                日時: \(Self.dateFormatter.string(from: record.createdAt))
                ファイル名: \(record.fileName)

                このバックアップファイルを macOS のゴミ箱へ移動します。必要であればゴミ箱から元に戻せます。
                """
            )
        }
    }
}
