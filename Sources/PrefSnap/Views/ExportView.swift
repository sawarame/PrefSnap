import PrefSnapCore
import SwiftUI

/// 現在の Mac 設定をスキャンし、カテゴリ別プレビューおよび整形済み JSON として書き出す画面。
struct ExportView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        Group {
            if viewModel.isBusy {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("現在の Mac 設定を読み取っています…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = viewModel.exportReport {
                loadedContentView(report: report)
            } else {
                emptyHeroView
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 初期状態: アイコン・タイトル・説明文・操作ボタンを画面中央へバランスよく 1 つに集約する。
    private var emptyHeroView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("設定のエクスポート")
                    .font(.title2.bold())
                Text("現在の Mac から 5 カテゴリの設定を抽出し、\nGit 管理しやすい整形済み JSON として保存します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.scanCurrentEnvironment()
                } label: {
                    Label("現在の設定を読み取る", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.saveExportedJSONWithPanel()
                } label: {
                    Label("JSON として保存…", systemImage: "square.and.arrow.down")
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

    /// スキャン完了後: 上部に中央揃えのヘッダー・操作ボタン・切替タブを配置し、下部に一覧を表示する。
    @ViewBuilder
    private func loadedContentView(report: ExportReport) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Text("設定のエクスポート")
                    .font(.title2.bold())

                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.scanCurrentEnvironment()
                    } label: {
                        Label("現在の設定を再読み取り", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(viewModel.isBusy)

                    Button {
                        viewModel.saveExportedJSONWithPanel()
                    } label: {
                        Label("JSON として保存…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(viewModel.isBusy)
                }
                .padding(.top, 2)

                Picker("表示モード", selection: $viewModel.showExportJSONPreview) {
                    Text("カテゴリ一覧").tag(false)
                    Text("JSON プレビュー").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)

            Divider()

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
        }
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
                        Text(descriptor.formatDisplayValue(value))
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
                        Text(descriptor.formatDisplayValue(value))
                            .font(.callout.monospaced())
                            .foregroundStyle(value == nil ? .secondary : .primary)
                    }
                }
                let dynamicKeys = snapshot.menuBar.keys
                    .filter { $0.hasPrefix(SettingCatalog.dynamicStatusItemIDPrefix) }
                    .sorted()
                ForEach(dynamicKeys, id: \.self) { dynamicID in
                    if let descriptor = SettingCatalog.dynamicMenuBarDescriptor(forID: dynamicID) {
                        let value = snapshot.menuBar[dynamicID]?.value
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(descriptor.displayName)
                                Text("\(descriptor.domain) / \(descriptor.key)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(descriptor.formatDisplayValue(value))
                                .font(.callout.monospaced())
                                .foregroundStyle(value == nil ? .secondary : .primary)
                        }
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
