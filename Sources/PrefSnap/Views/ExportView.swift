import PrefSnapCore
import SwiftUI

/// 現在の Mac 設定をスキャンし、カテゴリ別プレビューおよび整形済み JSON として書き出す画面。
struct ExportView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("設定のエクスポート")
                        .font(.title2.bold())
                    Text("現在の Mac から 5 カテゴリの設定を抽出し、Git 管理しやすい整形済み JSON として保存します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.scanCurrentEnvironment()
                } label: {
                    Label("現在の設定を読み取る", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.saveExportedJSONWithPanel()
                } label: {
                    Label("JSON として保存…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.exportReport == nil || viewModel.isBusy)
            }

            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isBusy {
                ProgressView("現在の Mac 設定を読み取っています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = viewModel.exportReport {
                Picker("表示モード", selection: $viewModel.showExportJSONPreview) {
                    Text("カテゴリ一覧").tag(false)
                    Text("JSON プレビュー").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if viewModel.showExportJSONPreview {
                    ScrollView {
                        Text(viewModel.exportJSONPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                } else {
                    snapshotSummaryList(report.snapshot)
                }
            } else {
                ContentUnavailableView(
                    "設定がまだ読み取られていません",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("右上の「現在の設定を読み取る」を押すと、この Mac の設定を安全にスキャンします。")
                )
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func snapshotSummaryList(_ snapshot: PrefSnapSnapshot) -> some View {
        List {
            Section("システム基本設定（\(snapshot.systemDefaults.count) 項目）") {
                ForEach(SettingCatalog.defaultsItems.filter { $0.category == .systemDefaults }) { descriptor in
                    let value = snapshot.systemDefaults[descriptor.id]?.value
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.displayName)
                                .font(.body)
                            Text("\(descriptor.domain) / \(descriptor.key)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(value?.displayString ?? "未設定 (null)")
                            .font(.callout.monospaced())
                            .foregroundStyle(value == nil ? .secondary : .primary)
                    }
                }
            }

            Section("メニューバーコントロール（\(snapshot.menuBar.count) 項目）") {
                ForEach(SettingCatalog.defaultsItems.filter { $0.category == .menuBar }) { descriptor in
                    let value = snapshot.menuBar[descriptor.id]?.value
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.displayName)
                            Text("\(descriptor.domain) / \(descriptor.key)\(descriptor.isByHost ? " (ByHost)" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(value?.displayString ?? "未設定 (null)")
                            .font(.callout.monospaced())
                            .foregroundStyle(value == nil ? .secondary : .primary)
                    }
                }
            }

            Section("システム標準ショートカット（\(snapshot.symbolicHotKeys.count) 項目）") {
                ForEach(SettingCatalog.symbolicHotKeys) { descriptor in
                    let entry = snapshot.symbolicHotKeys[descriptor.id]?.value
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.displayName)
                            Text("ID: \(descriptor.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry?.displayString ?? "未設定 (null)")
                            .font(.callout)
                            .foregroundStyle(entry == nil ? .secondary : .primary)
                    }
                }
            }

            Section("アプリケーションショートカット（\(snapshot.appShortcuts.count) ドメイン）") {
                if snapshot.appShortcuts.isEmpty {
                    Text("カスタムのアプリショートカットは登録されていません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.appShortcuts.keys.sorted(), id: \.self) { domain in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(domain)
                                .font(.headline)
                            if let map = snapshot.appShortcuts[domain] {
                                ForEach(map.keys.sorted(), id: \.self) { menuTitle in
                                    HStack {
                                        Text(menuTitle)
                                        Spacer()
                                        Text(map[menuTitle] ?? "")
                                            .font(.callout.monospaced())
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Section("修飾キーのリマップ（\(snapshot.modifierMappings.count) デバイス）") {
                if snapshot.modifierMappings.isEmpty {
                    Text("修飾キーのリマップ設定はありません。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.modifierMappings) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(entry.deviceName)
                                    Text(entry.isBuiltIn ? "内蔵" : "外付け")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                Text("VendorID-ProductID: \(entry.id)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.mappingsDisplayString)
                                .font(.callout)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
