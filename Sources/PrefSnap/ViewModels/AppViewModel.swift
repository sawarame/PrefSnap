import AppKit
import Foundation
import Observation
import PrefSnapCore
import UniformTypeIdentifiers

/// サイドバーの画面遷移先。
enum AppSection: String, CaseIterable, Identifiable {
    case export = "エクスポート"
    case importDiff = "インポート（差分適用）"
    case rollback = "履歴 / ロールバック"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .export: return "square.and.arrow.up"
        case .importDiff: return "square.and.arrow.down"
        case .rollback: return "clock.arrow.circlepath"
        }
    }
}

/// PrefSnap の全画面状態を管理する ViewModel（`Observation` フレームワーク対応）。
@Observable
@MainActor
final class AppViewModel {
    var selectedSection: AppSection = .export
    var isBusy = false
    var statusMessage: String?
    var errorBannerMessage: String?

    // MARK: - Export 状態
    var exportReport: ExportReport?
    var exportJSONPreview: String = ""
    var showExportJSONPreview = false

    // MARK: - Import / Dry-run 状態
    var importedFileURL: URL?
    var importedSnapshot: PrefSnapSnapshot?
    var diffItems: [DiffItem] = []
    var connectedKeyboards: [ConnectedKeyboard] = []
    var importIssues: [ItemIssue] = []
    var lastApplyResult: ApplyResult?

    // MARK: - Rollback 状態
    var backups: [BackupRecord] = []
    var selectedBackupID: String?
    var rollbackPreviewItems: [DiffItem] = []
    var lastRollbackResult: ApplyResult?

    // MARK: - 共通エラー表示
    var activeIssues: [ItemIssue] = []

    private let exporter: SnapshotExporter
    private let diffEngine: SnapshotDiffEngine
    private let applier: SnapshotApplier
    private let backupManager: BackupManager
    private let keyboardDetector: KeyboardDetecting
    private let serializer: SnapshotSerializer
    private let fileStore: FileStoring

    init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        plistStore: PlistStoring = SystemPlistStore(),
        keyboardDetector: KeyboardDetecting = IOKitKeyboardDetector(),
        fileStore: FileStoring = LocalFileStore(),
        processController: ProcessControlling? = nil,
        environment: EnvironmentProviding = SystemEnvironmentProvider()
    ) {
        let controller = processController ?? SystemProcessController(commandRunner: commandRunner)
        let serializer = SnapshotSerializer()
        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            environment: environment
        )
        let backupManager = BackupManager(
            fileStore: fileStore,
            serializer: serializer,
            environment: environment
        )
        let diffEngine = SnapshotDiffEngine()
        let applier = SnapshotApplier(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            processController: controller,
            backupManager: backupManager,
            exporter: exporter,
            diffEngine: diffEngine
        )

        self.exporter = exporter
        self.diffEngine = diffEngine
        self.applier = applier
        self.backupManager = backupManager
        self.keyboardDetector = keyboardDetector
        self.serializer = serializer
        self.fileStore = fileStore
    }

    var selectedBackup: BackupRecord? {
        backups.first { $0.id == selectedBackupID }
    }

    var backupDirectoryPath: String {
        fileStore.backupDirectory.path
    }

    var selectedApplicableDiffCount: Int {
        diffItems.filter(\.willApply).count
    }

    // MARK: - Export アクション

    /// 現在の Mac から設定を読み取り、スナップショットと整形済み JSON を生成する。
    func scanCurrentEnvironment() {
        isBusy = true
        errorBannerMessage = nil
        statusMessage = nil

        let exporter = self.exporter
        let serializer = self.serializer

        Task {
            let report = await Task.detached(priority: .userInitiated) {
                exporter.exportSnapshot()
            }.value

            self.exportReport = report
            self.activeIssues = report.issues

            do {
                let data = try serializer.encode(report.snapshot)
                self.exportJSONPreview = String(data: data, encoding: .utf8) ?? ""
                self.statusMessage = "現在の Mac 設定をスキャンしました。"
            } catch {
                self.errorBannerMessage = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    /// 生成済みスナップショットを `NSSavePanel` で JSON ファイルへ保存する。
    func saveExportedJSONWithPanel() {
        guard let snapshot = exportReport?.snapshot else { return }
        let panel = NSSavePanel()
        panel.title = "設定スナップショットを書き出す"
        panel.nameFieldStringValue = "prefsnap-config.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try serializer.encode(snapshot)
            try fileStore.writeData(data, to: url)
            statusMessage = "JSON ファイルを保存しました: \(url.lastPathComponent)"
            errorBannerMessage = nil
        } catch {
            errorBannerMessage = error.localizedDescription
        }
    }

    // MARK: - Import / Dry-run アクション

    /// `NSOpenPanel` で JSON ファイルを選択し、現在環境との差分を計算する。
    func selectAndLoadImportFile() {
        let panel = NSOpenPanel()
        panel.title = "インポートする JSON ファイルを選択"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImportFile(from: url)
    }

    func loadImportFile(from url: URL) {
        isBusy = true
        errorBannerMessage = nil
        lastApplyResult = nil

        let fileStore = self.fileStore
        let serializer = self.serializer
        let exporter = self.exporter
        let keyboardDetector = self.keyboardDetector
        let diffEngine = self.diffEngine

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { () -> (PrefSnapSnapshot, DiffReport) in
                    let data = try fileStore.readData(from: url)
                    let targetSnapshot = try serializer.decode(data)
                    let currentReport = exporter.exportSnapshot()
                    var issues = currentReport.issues
                    let keyboards: [ConnectedKeyboard]
                    do {
                        keyboards = try keyboardDetector.connectedKeyboards()
                    } catch let error as PrefSnapError {
                        if case let .permissionDenied(_, detail, settingsURL) = error {
                            issues.append(ItemIssue(
                                itemTitle: "接続キーボード検出 (IOKit)",
                                message: detail,
                                isPermissionError: true,
                                systemSettingsURL: settingsURL
                            ))
                        }
                        keyboards = []
                    } catch {
                        keyboards = []
                    }
                    let diff = diffEngine.computeDiff(
                        current: currentReport.snapshot,
                        target: targetSnapshot,
                        connectedKeyboards: keyboards,
                        existingIssues: issues
                    )
                    return (targetSnapshot, diff)
                }.value

                self.importedFileURL = url
                self.importedSnapshot = outcome.0
                self.diffItems = outcome.1.items
                self.connectedKeyboards = outcome.1.connectedKeyboards
                self.importIssues = outcome.1.issues
                self.activeIssues = outcome.1.issues
                self.statusMessage = "\(url.lastPathComponent) を読み込みました（差分 \(outcome.1.items.count) 件）。"
            } catch {
                self.errorBannerMessage = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    func setAllApplicableItemsSelected(_ selected: Bool) {
        for index in diffItems.indices {
            switch diffItems[index].modifierMatchStatus {
            case .disconnected:
                diffItems[index].isSelected = false
            case .builtInFallbackAvailable:
                diffItems[index].applyToBuiltInKeyboard = selected
                diffItems[index].isSelected = selected
            case .exactMatch, .none:
                diffItems[index].isSelected = selected
            }
        }
    }

    /// チェックされた差分項目を適用し、直前に自動バックアップを保存する。
    func applySelectedDiffs() {
        let itemsSnapshot = diffItems
        isBusy = true
        errorBannerMessage = nil

        let applier = self.applier
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                applier.apply(items: itemsSnapshot, createBackupBeforeApply: true)
            }.value

            self.lastApplyResult = result
            self.activeIssues = result.issues
            self.statusMessage = "\(result.appliedCount) 件の設定を適用しました。"
            self.isBusy = false
            self.refreshBackups()
        }
    }

    // MARK: - Rollback アクション

    /// 保存済みバックアップ一覧を読み込む。
    func refreshBackups() {
        do {
            backups = try backupManager.listBackups()
            if selectedBackupID == nil, let first = backups.first {
                selectedBackupID = first.id
                loadRollbackPreview(for: first)
            }
        } catch {
            errorBannerMessage = error.localizedDescription
        }
    }

    /// 選択されたバックアップを現在環境と比較し、復元される差分をプレビュー表示する。
    func loadRollbackPreview(for record: BackupRecord) {
        selectedBackupID = record.id
        isBusy = true
        errorBannerMessage = nil

        let backupManager = self.backupManager
        let exporter = self.exporter
        let keyboardDetector = self.keyboardDetector
        let diffEngine = self.diffEngine

        Task {
            do {
                let diff = try await Task.detached(priority: .userInitiated) { () -> DiffReport in
                    let backupSnapshot = try backupManager.loadBackup(record)
                    let currentReport = exporter.exportSnapshot()
                    let keyboards = (try? keyboardDetector.connectedKeyboards()) ?? []
                    return diffEngine.computeDiff(
                        current: currentReport.snapshot,
                        target: backupSnapshot,
                        connectedKeyboards: keyboards,
                        existingIssues: currentReport.issues,
                        resetUnlistedConnectedModifiers: true
                    )
                }.value

                self.rollbackPreviewItems = diff.items
                self.activeIssues = diff.issues
            } catch {
                self.errorBannerMessage = error.localizedDescription
            }
            self.isBusy = false
        }
    }

    /// 選択されたバックアップファイルから設定を復元（ロールバック）する。
    func executeRollback(to record: BackupRecord) {
        isBusy = true
        errorBannerMessage = nil

        let applier = self.applier
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try applier.rollback(to: record)
                }.value

                self.lastRollbackResult = result
                self.activeIssues = result.issues
                self.statusMessage = "\(record.fileName) から \(result.appliedCount) 件の設定を復元しました。"
                self.loadRollbackPreview(for: record)
            } catch {
                self.errorBannerMessage = error.localizedDescription
                self.isBusy = false
            }
        }
    }

    // MARK: - システム設定オープン

    func openSystemSettings(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
