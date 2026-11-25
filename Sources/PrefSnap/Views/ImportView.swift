import PrefSnapCore
import SwiftUI

/// JSON を読み込んで現在環境との差分（Before → After）をプレビューし、
/// 項目ごとにチェックボックスで選択して適用する画面。
struct ImportView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("差分プレビューと選択適用（Import）")
                        .font(.title2.bold())
                    Text("JSON を読み込むと現在の Mac との差分のみ表示されます。適用直前に自動でバックアップを作成します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // タイトル・説明文の下に改行を設け、操作ボタン群を中央揃えで配置する
                HStack(spacing: 12) {
                    Button {
                        viewModel.selectAndLoadImportFile()
                    } label: {
                        Label("JSON ファイルを開く…", systemImage: "folder")
                    }
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(viewModel.isBusy)

                    Button {
                        viewModel.applySelectedDiffs()
                    } label: {
                        Label("選択した \(viewModel.selectedApplicableDiffCount) 件を適用", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(viewModel.selectedApplicableDiffCount == 0 || viewModel.isBusy)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            if let result = viewModel.lastApplyResult {
                applyResultCard(result)
            }

            if !viewModel.connectedKeyboards.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text("接続中のキーボード:")
                        .font(.caption.bold())
                    ForEach(viewModel.connectedKeyboards) { kb in
                        Text("\(kb.deviceName) [\(kb.id)]\(kb.isBuiltIn ? " (内蔵)" : "")")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
            }

            if viewModel.isBusy {
                ProgressView("差分を計算しています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.importedFileURL == nil {
                ContentUnavailableView(
                    "インポートする JSON ファイルを選択してください",
                    systemImage: "arrow.left.arrow.right.square",
                    description: Text("ファイルを読み込んでもすぐには変更されません。Before → After を確認してから適用できます。")
                )
            } else if viewModel.diffItems.isEmpty {
                ContentUnavailableView(
                    "変更が必要な項目はありません",
                    systemImage: "checkmark.seal",
                    description: Text("現在の Mac の設定は読み込んだ JSON と一致しています。")
                )
            } else {
                HStack {
                    Text("検出された差分: \(viewModel.diffItems.count) 件（適用対象: \(viewModel.selectedApplicableDiffCount) 件）")
                        .font(.callout.bold())
                    Spacer()
                    Button("すべて選択") {
                        viewModel.setAllApplicableItemsSelected(true)
                    }
                    Button("すべて解除") {
                        viewModel.setAllApplicableItemsSelected(false)
                    }
                }

                List {
                    ForEach(SettingCategory.allCases, id: \.self) { category in
                        let indices = viewModel.diffItems.indices.filter { viewModel.diffItems[$0].category == category }
                        if !indices.isEmpty {
                            Section(category.displayName) {
                                ForEach(indices, id: \.self) { index in
                                    diffRow(index: index)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func diffRow(index: Int) -> some View {
        let item = viewModel.diffItems[index]

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                switch item.modifierMatchStatus {
                case .disconnected:
                    Image(systemName: "slash.circle")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                case .builtInFallbackAvailable:
                    Toggle("", isOn: Binding(
                        get: { viewModel.diffItems[index].applyToBuiltInKeyboard },
                        set: { newValue in
                            viewModel.diffItems[index].applyToBuiltInKeyboard = newValue
                            viewModel.diffItems[index].isSelected = newValue
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                case .exactMatch, .none:
                    Toggle("", isOn: $viewModel.diffItems[index].isSelected)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.subcategoryLabel)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        if item.requiresRelogin {
                            Text("再ログイン推奨")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if case .disconnected = item.modifierMatchStatus {
                            Text("未接続のためスキップ")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text(item.beforeDisplay)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.afterDisplay)
                            .font(.callout.monospaced())
                            .foregroundStyle(item.isApplicable ? Color.accentColor : Color.secondary)
                    }

                    if case let .builtInFallbackAvailable(_, targetBuiltIn) = item.modifierMatchStatus {
                        Toggle(
                            "この Mac の内蔵キーボード（\(targetBuiltIn.deviceName) / \(targetBuiltIn.id)）へ適用する",
                            isOn: Binding(
                                get: { viewModel.diffItems[index].applyToBuiltInKeyboard },
                                set: { newValue in
                                    viewModel.diffItems[index].applyToBuiltInKeyboard = newValue
                                    viewModel.diffItems[index].isSelected = newValue
                                }
                            )
                        )
                        .font(.callout)
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(item.modifierMatchStatus == .disconnected ? 0.6 : 1.0)
    }

    @ViewBuilder
    private func applyResultCard(_ result: ApplyResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("適用が完了しました（適用: \(result.appliedCount) 件 / スキップ: \(result.skippedCount) 件）", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
            }

            if let backup = result.backupRecord {
                Text("自動バックアップ保存先: \(backup.fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !result.restartedProcesses.isEmpty {
                let names = result.restartedProcesses.map(\.rawValue).joined(separator: ", ")
                Text("再起動したプロセス: \(names)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if result.requiresRelogin {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text("ショートカットや修飾キーなど、完全に反映するため macOS からの再ログインが必要な項目が含まれています（対象: \(result.reloginRequiredItems.joined(separator: "、"))）。")
                        .font(.callout)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
