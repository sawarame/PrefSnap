import Foundation

/// 選択された差分項目の適用、適用前自動バックアップ、対象プロセス再起動、
/// およびバックアップファイルからのロールバックを実行するエンジン。
public struct SnapshotApplier: Sendable {
    private let commandRunner: CommandRunning
    private let plistStore: PlistStoring
    private let keyboardDetector: KeyboardDetecting
    private let processController: ProcessControlling
    private let backupManager: BackupManager
    private let exporter: SnapshotExporter
    private let diffEngine: SnapshotDiffEngine

    public init(
        commandRunner: CommandRunning,
        plistStore: PlistStoring,
        keyboardDetector: KeyboardDetecting,
        processController: ProcessControlling,
        backupManager: BackupManager,
        exporter: SnapshotExporter,
        diffEngine: SnapshotDiffEngine = SnapshotDiffEngine()
    ) {
        self.commandRunner = commandRunner
        self.plistStore = plistStore
        self.keyboardDetector = keyboardDetector
        self.processController = processController
        self.backupManager = backupManager
        self.exporter = exporter
        self.diffEngine = diffEngine
    }

    /// 選択された `DiffItem` を適用する。
    /// - Parameters:
    ///   - items: 差分一覧（`willApply == true` の項目のみ適用される）
    ///   - createBackupBeforeApply: 適用直前に現在設定を自動バックアップするかどうか（通常インポート時は `true`）
    public func apply(
        items: [DiffItem],
        createBackupBeforeApply: Bool = true
    ) -> ApplyResult {
        let itemsToApply = items.filter(\.willApply)
        let skippedCount = items.count - itemsToApply.count

        guard !itemsToApply.isEmpty else {
            return ApplyResult(
                appliedCount: 0,
                skippedCount: skippedCount,
                backupRecord: nil,
                restartedProcesses: [],
                reloginRequiredItems: [],
                issues: []
            )
        }

        var issues: [ItemIssue] = []
        var backupRecord: BackupRecord?

        // 適用直前の自動バックアップ作成
        if createBackupBeforeApply {
            let currentReport = exporter.exportSnapshot()
            issues.append(contentsOf: currentReport.issues)
            do {
                backupRecord = try backupManager.saveBackup(currentReport.snapshot)
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: "適用前自動バックアップ"))
                // バックアップ保存自体に失敗した場合は安全のため適用を中断する
                return ApplyResult(
                    appliedCount: 0,
                    skippedCount: items.count,
                    backupRecord: nil,
                    restartedProcesses: [],
                    reloginRequiredItems: [],
                    issues: issues
                )
            } catch {
                issues.append(ItemIssue(itemTitle: "適用前自動バックアップ", message: error.localizedDescription, isPermissionError: false))
                return ApplyResult(
                    appliedCount: 0,
                    skippedCount: items.count,
                    backupRecord: nil,
                    restartedProcesses: [],
                    reloginRequiredItems: [],
                    issues: issues
                )
            }
        }

        var appliedCount = 0
        var restartTargets: Set<RestartTarget> = []
        var reloginItems: [String] = []

        for item in itemsToApply {
            do {
                try executeAction(item.action)
                appliedCount += 1
                restartTargets.formUnion(item.restartTargets)
                if item.requiresRelogin {
                    reloginItems.append(item.title)
                }
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: item.title))
            } catch {
                issues.append(ItemIssue(itemTitle: item.title, message: error.localizedDescription, isPermissionError: false))
            }
        }

        // 変更があった項目に必要なプロセスのみを再起動する
        var restartedProcesses: [RestartTarget] = []
        if !restartTargets.isEmpty {
            do {
                restartedProcesses = try processController.restart(targets: restartTargets)
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: "プロセス再起動"))
            } catch {
                issues.append(ItemIssue(itemTitle: "プロセス再起動", message: error.localizedDescription, isPermissionError: false))
            }
        }

        return ApplyResult(
            appliedCount: appliedCount,
            skippedCount: skippedCount,
            backupRecord: backupRecord,
            restartedProcesses: restartedProcesses,
            reloginRequiredItems: reloginItems,
            issues: issues
        )
    }

    /// 選択されたバックアップファイルから設定を復元（ロールバック）する。
    public func rollback(to record: BackupRecord) throws -> ApplyResult {
        let backupSnapshot = try backupManager.loadBackup(record)
        let currentReport = exporter.exportSnapshot()
        let keyboards = (try? keyboardDetector.connectedKeyboards()) ?? []

        let diffReport = diffEngine.computeDiff(
            current: currentReport.snapshot,
            target: backupSnapshot,
            connectedKeyboards: keyboards,
            existingIssues: currentReport.issues,
            resetUnlistedConnectedModifiers: true
        )

        // バックアップ復元では差分のある適用可能項目をすべて選択状態にする
        let itemsToRestore = diffReport.items.map { item -> DiffItem in
            var mutable = item
            if case .exactMatch = item.modifierMatchStatus {
                mutable.isSelected = true
            } else if item.modifierMatchStatus == nil {
                mutable.isSelected = true
            }
            return mutable
        }

        let result = apply(items: itemsToRestore, createBackupBeforeApply: false)
        return ApplyResult(
            appliedCount: result.appliedCount,
            skippedCount: result.skippedCount,
            backupRecord: record,
            restartedProcesses: result.restartedProcesses,
            reloginRequiredItems: result.reloginRequiredItems,
            issues: currentReport.issues + result.issues
        )
    }

    // MARK: - 個別アクションの実行

    private func executeAction(_ action: ApplyAction) throws {
        switch action {
        case let .defaultsSetting(descriptor, newValue):
            try applyDefaultsSetting(descriptor: descriptor, newValue: newValue)
        case let .symbolicHotKey(id, newValue):
            try applySymbolicHotKey(id: id, newValue: newValue)
        case let .appShortcut(domain, shortcuts):
            try applyAppShortcut(domain: domain, shortcuts: shortcuts)
        case let .modifierMapping(vendorID, productID, _, mappings):
            try applyModifierMapping(vendorID: vendorID, productID: productID, mappings: mappings)
        }
    }

    /// `defaults write` または `defaults delete`（`newValue == nil` 時）を実行する。
    private func applyDefaultsSetting(descriptor: SettingDescriptor, newValue: DefaultsValue?) throws {
        var args: [String] = []
        if descriptor.isByHost {
            args.append("-currentHost")
        }

        if let newValue {
            args.append(contentsOf: ["write", descriptor.domain, descriptor.key])
            args.append(contentsOf: newValue.defaultsWriteArguments())
            let output = try commandRunner.run(executable: "/usr/bin/defaults", arguments: args)
            try validateDefaultsCommandOutput(output, args: args, targetName: "\(descriptor.domain) (\(descriptor.key))")
        } else {
            args.append(contentsOf: ["delete", descriptor.domain, descriptor.key])
            let output = try commandRunner.run(executable: "/usr/bin/defaults", arguments: args)
            // 権限不足は優先検出し、すでに存在しないキー・ドメインの削除のみ成功扱いとする
            if output.exitCode != 0,
               DefaultsCommandStderrClassifier.isPermissionDenied(output.stderr)
                || !DefaultsCommandStderrClassifier.isMissingEntry(output.stderr) {
                try validateDefaultsCommandOutput(output, args: args, targetName: "\(descriptor.domain) (\(descriptor.key))")
            }
        }
    }

    /// `AppleSymbolicHotKeys` を既存 plist から読み込み、対象 ID のみ安全にマージ更新して書き戻す。
    /// 他のショートカット ID や既存キーは一切破壊しない。
    private func applySymbolicHotKey(id: String, newValue: SymbolicHotKeyEntry?) throws {
        let plistURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.symbolichotkeys.plist")
        var root: [String: Any]
        if plistStore.fileExists(at: plistURL) {
            root = try plistStore.readPlistDictionary(at: plistURL)
        } else {
            root = [:]
        }

        var hotKeys = (root["AppleSymbolicHotKeys"] as? [String: Any]) ?? [:]
        if let newValue {
            hotKeys[id] = newValue.toPlistDictionary()
        } else {
            hotKeys.removeValue(forKey: id)
        }
        root["AppleSymbolicHotKeys"] = hotKeys
        try plistStore.writePlistDictionary(root, to: plistURL)
    }

    /// `NSUserKeyEquivalents` を書き込み、あわせて `com.apple.universalaccess` の
    /// `com.apple.custommenu.apps` 配列へ対象アプリの Bundle ID を整合更新する。
    private func applyAppShortcut(domain: String, shortcuts: [String: String]) throws {
        let plistFileName = domain == "NSGlobalDomain" ? ".GlobalPreferences.plist" : "\(domain).plist"
        let domainPlistURL = plistStore.preferencesDirectory.appendingPathComponent(plistFileName)

        var domainDict: [String: Any]
        if plistStore.fileExists(at: domainPlistURL) {
            domainDict = try plistStore.readPlistDictionary(at: domainPlistURL)
        } else {
            domainDict = [:]
        }

        if shortcuts.isEmpty {
            domainDict.removeValue(forKey: "NSUserKeyEquivalents")
        } else {
            domainDict["NSUserKeyEquivalents"] = shortcuts
        }
        try plistStore.writePlistDictionary(domainDict, to: domainPlistURL)

        // NSGlobalDomain 以外の個別アプリは com.apple.universalaccess の custommenu.apps 配列も整合更新する
        guard domain != "NSGlobalDomain" else { return }

        let universalAccessURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.universalaccess.plist")
        var uaDict: [String: Any]
        if plistStore.fileExists(at: universalAccessURL) {
            uaDict = try plistStore.readPlistDictionary(at: universalAccessURL)
        } else {
            uaDict = [:]
        }

        var apps = (uaDict["com.apple.custommenu.apps"] as? [String]) ?? []
        if shortcuts.isEmpty {
            apps.removeAll { $0 == domain }
        } else if !apps.contains(domain) {
            apps.append(domain)
        }
        uaDict["com.apple.custommenu.apps"] = apps
        try plistStore.writePlistDictionary(uaDict, to: universalAccessURL)
    }

    /// `ByHost/.GlobalPreferences`（`-currentHost -g`）へ修飾キーリマップを書き込む。
    private func applyModifierMapping(vendorID: Int, productID: Int, mappings: [ModifierKeyPair]) throws {
        let key = "com.apple.keyboard.modifiermapping.\(vendorID)-\(productID)-0"
        if mappings.isEmpty {
            let args = ["-currentHost", "delete", "-g", key]
            let output = try commandRunner.run(executable: "/usr/bin/defaults", arguments: args)
            // 権限不足は優先検出し、すでに存在しないキー・ドメインの削除のみ成功扱いとする
            if output.exitCode != 0,
               DefaultsCommandStderrClassifier.isPermissionDenied(output.stderr)
                || !DefaultsCommandStderrClassifier.isMissingEntry(output.stderr) {
                try validateDefaultsCommandOutput(output, args: args, targetName: key)
            }
            return
        }

        var args = ["-currentHost", "write", "-g", key, "-array"]
        for pair in mappings {
            let xmlDict = "<dict><key>HIDKeyboardModifierMappingSrc</key><integer>\(pair.src)</integer><key>HIDKeyboardModifierMappingDst</key><integer>\(pair.dst)</integer></dict>"
            args.append(xmlDict)
        }

        let output = try commandRunner.run(executable: "/usr/bin/defaults", arguments: args)
        try validateDefaultsCommandOutput(output, args: args, targetName: key)
    }

    private func validateDefaultsCommandOutput(_ output: CommandOutput, args: [String], targetName: String) throws {
        guard output.exitCode != 0 else { return }
        if DefaultsCommandStderrClassifier.isPermissionDenied(output.stderr) {
            throw PrefSnapError.permissionDenied(
                target: targetName,
                detail: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                settingsURL: SystemPreferencesURL.fullDiskAccess
            )
        }
        throw PrefSnapError.commandFailed(
            command: (["defaults"] + args).joined(separator: " "),
            exitCode: output.exitCode,
            stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func makeIssue(from error: PrefSnapError, itemTitle: String) -> ItemIssue {
        switch error {
        case let .permissionDenied(_, detail, url):
            return ItemIssue(
                itemTitle: itemTitle,
                message: detail,
                isPermissionError: true,
                systemSettingsURL: url
            )
        default:
            return ItemIssue(
                itemTitle: itemTitle,
                message: error.localizedDescription,
                isPermissionError: false
            )
        }
    }
}
