import PrefSnapCore
import SwiftUI

/// JSON を読み込んで現在環境との差分（Before → After）をプレビューし、
/// 項目ごとにチェックボックスで選択して適用する画面。
struct ImportView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        Group {
            if viewModel.isBusy {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("差分を計算しています…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.importedFileURL == nil {
                emptyHeroView
            } else {
                loadedContentView
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 初期状態: アイコン・タイトル・説明文・操作ボタンを画面中央へバランスよく 1 つに集約する。
    private var emptyHeroView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("差分プレビューと選択適用（Import）")
                    .font(.title2.bold())
                Text("JSON ファイルを読み込むと現在の Mac との差分のみ表示されます。\n内容を確認してから項目ごとに選択適用でき、適用直前に自動バックアップを作成します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.selectAndLoadImportFile()
                } label: {
                    Label("JSON ファイルを開く…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.applySelectedDiffs()
                } label: {
                    Label("選択した 0 件を適用", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .fixedSize()
                .disabled(true)
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ファイル読み込み後: 上部に中央揃えのヘッダー・操作ボタンを配置し、下部に差分一覧を表示する。
    private var loadedContentView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                Text("差分プレビューと選択適用（Import）")
                    .font(.title2.bold())

                if let url = viewModel.importedFileURL {
                    Text("読み込みファイル: \(url.lastPathComponent)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.selectAndLoadImportFile()
                    } label: {
                        Label("別の JSON を開く…", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
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
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)

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

            if viewModel.diffItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.green)
                    Text("変更が必要な項目はありません")
                        .font(.headline)
                    Text("現在の Mac の設定は読み込んだ JSON と一致しています。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
