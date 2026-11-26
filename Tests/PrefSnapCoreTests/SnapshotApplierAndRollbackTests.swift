import Foundation
import Testing
@testable import PrefSnapCore

@Suite("SnapshotApplier と自動バックアップ／ロールバックのテスト")
struct SnapshotApplierAndRollbackTests {
    @Test("安全なマージ書き込み・custommenu.apps 整合更新・自動バックアップ・必要プロセスのみ再起動・ロールバック")
    func applySafelyMergesSymbolicHotKeysUpdatesCustomMenuAppsCreatesBackupAndRestartsNeededProcessesOnly() throws {
        let commandRunner = MockCommandRunner()
        let plistStore = MockPlistStore()
        let keyboardDetector = MockKeyboardDetector(keyboards: [
            ConnectedKeyboard(vendorID: 1452, productID: 832, deviceName: "Apple Internal Keyboard", isBuiltIn: true)
        ])
        let fileStore = MockFileStore()
        let processController = MockProcessController()
        let environment = MockEnvironmentProvider()

        // 現在の環境をセットアップ
        commandRunner.setDefaults(domain: "com.apple.dock", key: "autohide", value: "0")
        commandRunner.setDefaults(domain: "com.apple.finder", key: "ShowPathbar", value: "1")
        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "BatteryShowPercentage", value: "0", isByHost: true)

        // 既存の AppleSymbolicHotKeys（ID "32" と未知のカスタム ID "999" が存在）
        let hotKeysURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.symbolichotkeys.plist")
        try plistStore.setPlist([
            "AppleSymbolicHotKeys": [
                "32": ["enabled": true, "value": ["type": "standard", "parameters": [65535, 126, 262_144]]],
                "999": ["enabled": true, "value": ["type": "standard", "parameters": [97, 0, 1_048_576]]]
            ],
            "OtherTopLevelKey": "keep-me"
        ], at: hotKeysURL)

        // 既存の com.apple.universalaccess
        let uaURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.universalaccess.plist")
        try plistStore.setPlist([
            "com.apple.custommenu.apps": ["com.apple.Notes"]
        ], at: uaURL)

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            environment: environment
        )
        let backupManager = BackupManager(fileStore: fileStore, environment: environment)
        let applier = SnapshotApplier(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            processController: processController,
            backupManager: backupManager,
            exporter: exporter
        )

        let dockAutohide = try #require(SettingCatalog.defaultsItemsByID["dock.autohide"])
        let finderPathbar = try #require(SettingCatalog.defaultsItemsByID["finder.showPathbar"])
        let ccBattery = try #require(SettingCatalog.defaultsItemsByID["menubar.controlcenter.batteryShowPercentage"])

        let items: [DiffItem] = [
            DiffItem(
                id: "defaults:dock.autohide",
                category: .systemDefaults,
                subcategoryLabel: "Dock",
                title: dockAutohide.displayName,
                detail: "",
                beforeDisplay: "オフ",
                afterDisplay: "オン",
                action: .defaultsSetting(descriptor: dockAutohide, newValue: .bool(true)),
                restartTargets: dockAutohide.restartTargets,
                requiresRelogin: false,
                isSelected: true
            ),
            DiffItem(
                id: "defaults:finder.showPathbar",
                category: .systemDefaults,
                subcategoryLabel: "Finder",
                title: finderPathbar.displayName,
                detail: "",
                beforeDisplay: "オン",
                afterDisplay: "未設定へ戻す（削除）",
                action: .defaultsSetting(descriptor: finderPathbar, newValue: nil),
                restartTargets: finderPathbar.restartTargets,
                requiresRelogin: false,
                isSelected: false
            ),
            DiffItem(
                id: "defaults:menubar.controlcenter.batteryShowPercentage",
                category: .menuBar,
                subcategoryLabel: "コントロールセンター",
                title: ccBattery.displayName,
                detail: "",
                beforeDisplay: "オフ",
                afterDisplay: "オン",
                action: .defaultsSetting(descriptor: ccBattery, newValue: .bool(true)),
                restartTargets: ccBattery.restartTargets,
                requiresRelogin: false,
                isSelected: true
            ),
            DiffItem(
                id: "symbolichotkey:64",
                category: .symbolicHotKeys,
                subcategoryLabel: "標準ショートカット",
                title: "Spotlight 検索を表示",
                detail: "",
                beforeDisplay: "未設定",
                afterDisplay: "無効",
                action: .symbolicHotKey(
                    id: "64",
                    newValue: SymbolicHotKeyEntry(enabled: false, valueType: "standard", parameters: [65535, 49, 1_048_576])
                ),
                restartTargets: [],
                requiresRelogin: true,
                isSelected: true
            ),
            DiffItem(
                id: "appshortcut:com.apple.Safari",
                category: .appShortcuts,
                subcategoryLabel: "アプリショートカット",
                title: "com.apple.Safari",
                detail: "",
                beforeDisplay: "未設定",
                afterDisplay: "タブをピン固定: @^p",
                action: .appShortcut(domain: "com.apple.Safari", shortcuts: ["タブをピン固定": "@^p"]),
                restartTargets: [],
                requiresRelogin: true,
                isSelected: true
            ),
            DiffItem(
                id: "modifier:1452-832",
                category: .modifierMappings,
                subcategoryLabel: "内蔵キーボード",
                title: "Apple Internal Keyboard",
                detail: "",
                beforeDisplay: "標準",
                afterDisplay: "Caps Lock → 左 Control",
                action: .modifierMapping(
                    targetVendorID: 1452,
                    targetProductID: 832,
                    targetDeviceName: "Apple Internal Keyboard",
                    mappings: [ModifierKeyPair(src: 0x700000039, dst: 0x7000000E0)]
                ),
                restartTargets: [],
                requiresRelogin: true,
                modifierMatchStatus: .exactMatch(ConnectedKeyboard(vendorID: 1452, productID: 832, deviceName: "Apple Internal Keyboard", isBuiltIn: true)),
                isSelected: true
            )
        ]

        let result = applier.apply(items: items, createBackupBeforeApply: true)

        #expect(result.issues.isEmpty)
        #expect(result.appliedCount == 5)
        #expect(result.skippedCount == 1)
        #expect(result.backupRecord != nil)
        #expect(fileStore.allStoredFileNames().count == 1)

        // 必要なプロセスのみ再起動され、スキップした Finder は含まれないこと
        #expect(Set(result.restartedProcesses) == [.dock, .controlCenter, .systemUIServer])
        #expect(!result.restartedProcesses.contains(.finder))

        // 再ログイン通知対象が記録されていること
        #expect(result.requiresRelogin == true)
        #expect(result.reloginRequiredItems.count == 3)

        // defaults 値の反映確認（ControlCenter は ByHost）
        #expect(commandRunner.storedDefaults(domain: "com.apple.dock", key: "autohide") == "1")
        #expect(commandRunner.storedDefaults(domain: "com.apple.finder", key: "ShowPathbar") == "1")
        #expect(commandRunner.storedDefaults(domain: "com.apple.controlcenter", key: "BatteryShowPercentage", isByHost: true) == "1")

        // AppleSymbolicHotKeys が既存エントリを破壊せず安全にマージされたこと
        let updatedHotKeysRoot = try plistStore.readPlistDictionary(at: hotKeysURL)
        #expect(updatedHotKeysRoot["OtherTopLevelKey"] as? String == "keep-me")
        let updatedHotKeys = try #require(updatedHotKeysRoot["AppleSymbolicHotKeys"] as? [String: Any])
        #expect(updatedHotKeys["32"] != nil)
        #expect(updatedHotKeys["999"] != nil)
        #expect(updatedHotKeys["64"] != nil)

        // NSUserKeyEquivalents と com.apple.custommenu.apps の整合更新確認
        let safariPlist = try plistStore.readPlistDictionary(
            at: plistStore.preferencesDirectory.appendingPathComponent("com.apple.Safari.plist")
        )
        #expect(safariPlist["NSUserKeyEquivalents"] as? [String: String] == ["タブをピン固定": "@^p"])
        let updatedUA = try plistStore.readPlistDictionary(at: uaURL)
        #expect(updatedUA["com.apple.custommenu.apps"] as? [String] == ["com.apple.Notes", "com.apple.Safari"])

        // 修飾キーリマップが -currentHost write -g で書き込まれたこと
        let modifierWrites = commandRunner.recordedInvocations().filter {
            $0.arguments.contains("com.apple.keyboard.modifiermapping.1452-832-0") && $0.arguments.contains("write")
        }
        #expect(modifierWrites.count == 1)
        #expect(modifierWrites.first?.arguments.first == "-currentHost")

        // ロールバック実行: 適用直前に自動保存されたバックアップファイルを選択して元へ戻す
        let backup = try #require(result.backupRecord)
        let rollbackResult = try applier.rollback(to: backup)
        #expect(rollbackResult.issues.isEmpty)
        #expect(commandRunner.storedDefaults(domain: "com.apple.dock", key: "autohide") == "0")
        #expect(commandRunner.storedDefaults(domain: "com.apple.controlcenter", key: "BatteryShowPercentage", isByHost: true) == "0")

        // ロールバックで Spotlight ID "64" は削除され、既存の "32" / "999" はそのまま残ること
        let rolledBackHotKeysRoot = try plistStore.readPlistDictionary(at: hotKeysURL)
        let rolledBackHotKeys = try #require(rolledBackHotKeysRoot["AppleSymbolicHotKeys"] as? [String: Any])
        #expect(rolledBackHotKeys["64"] == nil)
        #expect(rolledBackHotKeys["32"] != nil)
        #expect(rolledBackHotKeys["999"] != nil)

        // ロールバックで Safari のショートカットも削除され、custommenu.apps も元へ戻ること
        let rolledBackSafari = try plistStore.readPlistDictionary(
            at: plistStore.preferencesDirectory.appendingPathComponent("com.apple.Safari.plist")
        )
        #expect(rolledBackSafari["NSUserKeyEquivalents"] == nil)
        let rolledBackUA = try plistStore.readPlistDictionary(at: uaURL)
        #expect(rolledBackUA["com.apple.custommenu.apps"] as? [String] == ["com.apple.Notes"])

        // ロールバックでも必要なプロセスが再起動されること
        #expect(Set(rollbackResult.restartedProcesses) == [.dock, .controlCenter, .systemUIServer])
    }

    @Test("JSON が null の項目は defaults delete で初期値へ戻されること")
    func nullTargetDeletesExistingDefaultsKey() throws {
        let commandRunner = MockCommandRunner()
        let plistStore = MockPlistStore()
        let keyboardDetector = MockKeyboardDetector()
        let fileStore = MockFileStore()
        let processController = MockProcessController()
        let environment = MockEnvironmentProvider()

        commandRunner.setDefaults(domain: "com.apple.finder", key: "AppleShowAllFiles", value: "1")

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            environment: environment
        )
        let backupManager = BackupManager(fileStore: fileStore, environment: environment)
        let applier = SnapshotApplier(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            processController: processController,
            backupManager: backupManager,
            exporter: exporter
        )

        let descriptor = try #require(SettingCatalog.defaultsItemsByID["finder.showAllFiles"])
        let deleteItem = DiffItem(
            id: "defaults:finder.showAllFiles",
            category: .systemDefaults,
            subcategoryLabel: "Finder",
            title: descriptor.displayName,
            detail: "",
            beforeDisplay: "オン (true)",
            afterDisplay: "未設定へ戻す（削除）",
            action: .defaultsSetting(descriptor: descriptor, newValue: nil),
            restartTargets: descriptor.restartTargets,
            requiresRelogin: false,
            isSelected: true
        )

        let result = applier.apply(items: [deleteItem], createBackupBeforeApply: true)
        #expect(result.issues.isEmpty)
        #expect(result.appliedCount == 1)
        #expect(commandRunner.storedDefaults(domain: "com.apple.finder", key: "AppleShowAllFiles") == nil)
        #expect(result.restartedProcesses == [.finder])
    }

    @Test("バックアップ一覧が新しい順に並び、権限エラー時は適用を安全に中断すること")
    func backupListOrdersNewestFirstAndPermissionFailureStopsSafely() throws {
        let fileStore = MockFileStore()
        let env = MockEnvironmentProvider(fixedDate: Date(timeIntervalSince1970: 1_764_000_000))
        let manager = BackupManager(fileStore: fileStore, environment: env)

        let snap1 = PrefSnapSnapshot(
            exportedAt: "2026-11-25T10:00:00Z",
            sourceHost: SourceHostMetadata(hostName: "Mac-1", osVersion: "15", architecture: "arm64"),
            systemDefaults: [:],
            menuBar: [:],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )
        _ = try manager.saveBackup(snap1)

        env.fixedDate = Date(timeIntervalSince1970: 1_764_003_600)
        _ = try manager.saveBackup(snap1)

        let list = try manager.listBackups()
        #expect(list.count == 2)
        #expect(list[0].createdAt > list[1].createdAt)

        // バックアップ保存時に権限エラーが起きた場合は安全のため適用を中断しクラッシュしないこと
        fileStore.failWriteWithPermissionError = true
        let commandRunner = MockCommandRunner()
        let plistStore = MockPlistStore()
        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: MockKeyboardDetector(),
            environment: env
        )
        let applier = SnapshotApplier(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: MockKeyboardDetector(),
            processController: MockProcessController(),
            backupManager: manager,
            exporter: exporter
        )
        let descriptor = try #require(SettingCatalog.defaultsItemsByID["dock.autohide"])
        let item = DiffItem(
            id: "defaults:dock.autohide",
            category: .systemDefaults,
            subcategoryLabel: "Dock",
            title: descriptor.displayName,
            detail: "",
            beforeDisplay: "未設定",
            afterDisplay: "オン",
            action: .defaultsSetting(descriptor: descriptor, newValue: .bool(true)),
            restartTargets: [.dock],
            requiresRelogin: false,
            isSelected: true
        )

        let failedResult = applier.apply(items: [item], createBackupBeforeApply: true)
        #expect(failedResult.appliedCount == 0)
        let hasPermissionError = failedResult.issues.contains(where: \.isPermissionError)
        #expect(hasPermissionError)
        #expect(commandRunner.storedDefaults(domain: "com.apple.dock", key: "autohide") == nil)
    }

    @Test("通常ドメイン com.apple.controlcenter の NSStatusItem Visible* および動的キーが安全に適用・ロールバックされること")
    func menuBarStatusItemVisibilityAppliesWithoutCurrentHostAndRestartsControlCenter() throws {
        let commandRunner = MockCommandRunner()
        let plistStore = MockPlistStore()
        let keyboardDetector = MockKeyboardDetector()
        let fileStore = MockFileStore()
        let processController = MockProcessController()
        let environment = MockEnvironmentProvider()

        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "NSStatusItem VisibleCC Display", value: "0", isByHost: false)
        try plistStore.setPlist([
            "NSStatusItem Visible Shortcuts": false
        ], at: plistStore.preferencesDirectory.appendingPathComponent("com.apple.controlcenter.plist"))

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            environment: environment
        )
        let backupManager = BackupManager(fileStore: fileStore, environment: environment)
        let applier = SnapshotApplier(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            processController: processController,
            backupManager: backupManager,
            exporter: exporter
        )

        let visibleCCDisplay = try #require(SettingCatalog.defaultsItemsByID["menubar.statusitem.visibleCC.display"])
        let dynamicID = SettingCatalog.dynamicMenuBarStatusItemID(forKey: "NSStatusItem Visible Shortcuts")
        let dynamicDescriptor = try #require(SettingCatalog.dynamicMenuBarDescriptor(forID: dynamicID))

        let items: [DiffItem] = [
            DiffItem(
                id: "defaults:\(visibleCCDisplay.id)",
                category: .menuBar,
                subcategoryLabel: visibleCCDisplay.subcategory.rawValue,
                title: visibleCCDisplay.displayName,
                detail: "",
                beforeDisplay: "オフ (false)",
                afterDisplay: "オン (true)",
                action: .defaultsSetting(descriptor: visibleCCDisplay, newValue: .bool(true)),
                restartTargets: visibleCCDisplay.restartTargets,
                requiresRelogin: false,
                isSelected: true
            ),
            DiffItem(
                id: "defaults:\(dynamicDescriptor.id)",
                category: .menuBar,
                subcategoryLabel: dynamicDescriptor.subcategory.rawValue,
                title: dynamicDescriptor.displayName,
                detail: "",
                beforeDisplay: "オフ (false)",
                afterDisplay: "オン (true)",
                action: .defaultsSetting(descriptor: dynamicDescriptor, newValue: .bool(true)),
                restartTargets: dynamicDescriptor.restartTargets,
                requiresRelogin: false,
                isSelected: true
            )
        ]

        let result = applier.apply(items: items, createBackupBeforeApply: true)
        #expect(result.issues.isEmpty)
        #expect(result.appliedCount == 2)
        #expect(Set(result.restartedProcesses) == [.controlCenter, .systemUIServer])
        #expect(commandRunner.storedDefaults(domain: "com.apple.controlcenter", key: "NSStatusItem VisibleCC Display", isByHost: false) == "1")
        #expect(commandRunner.storedDefaults(domain: "com.apple.controlcenter", key: "NSStatusItem Visible Shortcuts", isByHost: false) == "1")

        // 書き込み時に -currentHost が付いていないこと（通常ドメインへの適用）
        let writeDisplayInvocations = commandRunner.recordedInvocations().filter {
            $0.arguments.contains("write") && $0.arguments.contains("NSStatusItem VisibleCC Display")
        }
        #expect(writeDisplayInvocations.count == 1)
        #expect(writeDisplayInvocations.first?.arguments.first != "-currentHost")
    }

    @Test("macOS 26 コントロールセンター配置（Data 型）が defaults -data で適用され、ロールバックで元へ戻ること")
    func macOS26ControlCenterDataAppliesViaDefaultsDataAndRollsBackCleanly() throws {
        let commandRunner = MockCommandRunner()
        let plistStore = MockPlistStore()
        let keyboardDetector = MockKeyboardDetector()
        let fileStore = MockFileStore()
        let processController = MockProcessController()
        let environment = MockEnvironmentProvider()

        let originalBento = Data("[{\"menuBarIconName\":\"circle.grid.2x2\",\"v\":1}]".utf8)
        let targetBento = Data("[{\"menuBarIconName\":\"circle.grid.2x2\",\"v\":2}]".utf8)
        let targetChrono = Data("{\"Controls\":[{\"DisplayName\":\"ダークモード\"}]}".utf8)

        commandRunner.setDefaultsData(domain: "com.apple.controlcenter.bentoboxes", key: "boxes", data: originalBento, isByHost: true)

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            environment: environment
        )
        let backupManager = BackupManager(fileStore: fileStore, environment: environment)
        let applier = SnapshotApplier(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            processController: processController,
            backupManager: backupManager,
            exporter: exporter
        )

        let bentoDesc = try #require(SettingCatalog.defaultsItemsByID["menubar.controlcenter.bentoboxes"])
        let chronoDesc = try #require(SettingCatalog.defaultsItemsByID["menubar.controlcenter.chronoControls"])

        let items: [DiffItem] = [
            DiffItem(
                id: "defaults:\(bentoDesc.id)",
                category: .menuBar,
                subcategoryLabel: bentoDesc.subcategory.rawValue,
                title: bentoDesc.displayName,
                detail: "",
                beforeDisplay: bentoDesc.formatDisplayValue(.data(originalBento)),
                afterDisplay: bentoDesc.formatDisplayValue(.data(targetBento)),
                action: .defaultsSetting(descriptor: bentoDesc, newValue: .data(targetBento)),
                restartTargets: bentoDesc.restartTargets,
                requiresRelogin: false,
                isSelected: true
            ),
            DiffItem(
                id: "defaults:\(chronoDesc.id)",
                category: .menuBar,
                subcategoryLabel: chronoDesc.subcategory.rawValue,
                title: chronoDesc.displayName,
                detail: "",
                beforeDisplay: "未設定（初期値）",
                afterDisplay: chronoDesc.formatDisplayValue(.data(targetChrono)),
                action: .defaultsSetting(descriptor: chronoDesc, newValue: .data(targetChrono)),
                restartTargets: chronoDesc.restartTargets,
                requiresRelogin: false,
                isSelected: true
            )
        ]

        let result = applier.apply(items: items, createBackupBeforeApply: true)
        #expect(result.issues.isEmpty)
        #expect(result.appliedCount == 2)
        #expect(Set(result.restartedProcesses) == [.controlCenter, .systemUIServer])
        #expect(commandRunner.storedDefaultsData(domain: "com.apple.controlcenter.bentoboxes", key: "boxes", isByHost: true) == targetBento)
        #expect(commandRunner.storedDefaultsData(domain: "com.apple.controlcenter", key: "ControlCenterDisplayableChronoControlsProviderConfiguration", isByHost: false) == targetChrono)

        // defaults -currentHost write ... -data <hex> で書き込まれたこと
        let bentoWrite = commandRunner.recordedInvocations().first {
            $0.arguments.contains("com.apple.controlcenter.bentoboxes") && $0.arguments.contains("write")
        }
        #expect(bentoWrite?.arguments.first == "-currentHost")
        #expect(bentoWrite?.arguments.contains("-data") == true)

        // ロールバックで bentoboxes は元データへ、chronoControls は未設定（削除）へ戻ること
        let backup = try #require(result.backupRecord)
        let rollbackResult = try applier.rollback(to: backup)
        #expect(rollbackResult.issues.isEmpty)
        #expect(commandRunner.storedDefaultsData(domain: "com.apple.controlcenter.bentoboxes", key: "boxes", isByHost: true) == originalBento)
        #expect(commandRunner.storedDefaultsData(domain: "com.apple.controlcenter", key: "ControlCenterDisplayableChronoControlsProviderConfiguration", isByHost: false) == nil)
        #expect(Set(rollbackResult.restartedProcesses) == [.controlCenter, .systemUIServer])
    }

    /// テスト用の最小構成スナップショットを生成するヘルパー関数。
    /// - Parameter hostName: スナップショットに設定するホスト名
    /// - Returns: テスト用の `PrefSnapSnapshot`
    private func makeTestSnapshot(hostName: String = "Test-Mac") -> PrefSnapSnapshot {
        PrefSnapSnapshot(
            exportedAt: "2026-11-27T07:00:00Z",
            sourceHost: SourceHostMetadata(hostName: hostName, osVersion: "15", architecture: "arm64"),
            systemDefaults: [:],
            menuBar: [:],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )
    }

    @Test("BackupManager.deleteBackup で最新履歴や最後の 1 件をゴミ箱へ移動でき一覧が更新されること")
    func deleteBackupMovesFileToTrashAndUpdatesBackupList() throws {
        let fileStore = MockFileStore()
        let env = MockEnvironmentProvider(fixedDate: Date(timeIntervalSince1970: 1_764_000_000))
        let manager = BackupManager(fileStore: fileStore, environment: env)

        let older = try manager.saveBackup(makeTestSnapshot(hostName: "Mac-Old"))
        env.fixedDate = Date(timeIntervalSince1970: 1_764_003_600)
        let latest = try manager.saveBackup(makeTestSnapshot(hostName: "Mac-Latest"))

        #expect(try manager.listBackups().map(\.id) == [latest.id, older.id])

        // 最新の「直前」バックアップを削除できること
        try manager.deleteBackup(latest)

        let afterFirstDelete = try manager.listBackups()
        #expect(afterFirstDelete.map(\.id) == [older.id])
        #expect(fileStore.recordedTrashedURLs() == [latest.fileURL.standardizedFileURL])

        // 最後の 1 件も削除でき、一覧が空になること
        try manager.deleteBackup(older)

        let afterSecondDelete = try manager.listBackups()
        #expect(afterSecondDelete.isEmpty)
        #expect(fileStore.recordedTrashedURLs() == [latest.fileURL.standardizedFileURL, older.fileURL.standardizedFileURL])
    }

    @Test("BackupManager.deleteBackup は backupDirectory 外や非 JSON ファイルの削除を拒否すること")
    func deleteBackupRejectsPathsOutsideBackupDirectoryAndNonJSONFiles() throws {
        let fileStore = MockFileStore()
        let env = MockEnvironmentProvider(fixedDate: Date(timeIntervalSince1970: 1_764_000_000))
        let manager = BackupManager(fileStore: fileStore, environment: env)

        let validBackup = try manager.saveBackup(makeTestSnapshot())
        let dummyData = Data("{}".utf8)

        // 範囲外の各種不正パスを用意（モック上に実在しても削除されないことを検証する）
        let outsideDirURL = URL(fileURLWithPath: "/mock/OtherDirectory/PrefSnap_Backup_20261127_070000.json")
        let traversalURL = fileStore.backupDirectory.appendingPathComponent("../escape.json")
        let subDirectoryURL = fileStore.backupDirectory.appendingPathComponent("nested/PrefSnap_Backup_20261127_070000.json")
        let nonJSONURL = fileStore.backupDirectory.appendingPathComponent("notes.txt")

        for invalidURL in [outsideDirURL, traversalURL, subDirectoryURL, nonJSONURL] {
            try fileStore.writeData(dummyData, to: invalidURL)
            let record = BackupRecord(
                id: invalidURL.lastPathComponent,
                fileName: invalidURL.lastPathComponent,
                fileURL: invalidURL,
                createdAt: env.fixedDate
            )

            do {
                try manager.deleteBackup(record)
                Issue.record("対象外パス \(invalidURL.path) の削除が拒否されませんでした。")
            } catch let error as PrefSnapError {
                if case .fileOperationFailed = error {
                    // 期待どおり拒否された
                } else {
                    Issue.record("想定外のエラー型です: \(error)")
                }
            }
        }

        // 不正パスはいずれもゴミ箱へ移動されず、正規のバックアップも残っていること
        #expect(fileStore.recordedTrashedURLs().isEmpty)
        #expect(try manager.listBackups().map(\.id) == [validBackup.id])
    }

    @Test("BackupManager.deleteBackup で権限エラーや存在しないファイルの削除時に適切なエラーが返ること")
    func deleteBackupPropagatesPermissionAndNotFoundErrors() throws {
        let fileStore = MockFileStore()
        let env = MockEnvironmentProvider(fixedDate: Date(timeIntervalSince1970: 1_764_000_000))
        let manager = BackupManager(fileStore: fileStore, environment: env)

        let saved = try manager.saveBackup(makeTestSnapshot())

        // 権限エラー発生時は PrefSnapError.permissionDenied が返り、ファイルは消えないこと
        fileStore.failTrashWithPermissionError = true
        do {
            try manager.deleteBackup(saved)
            Issue.record("権限エラーが送出されませんでした。")
        } catch let error as PrefSnapError {
            guard case let .permissionDenied(target, _, settingsURL) = error else {
                Issue.record("permissionDenied 以外のエラーです: \(error)")
                return
            }
            #expect(target == saved.fileName)
            #expect(settingsURL == SystemPreferencesURL.fullDiskAccess)
        }
        #expect(try manager.listBackups().map(\.id) == [saved.id])

        // 権限エラー解除後に削除し、2 回目（ファイル未存在）は fileOperationFailed になること
        fileStore.failTrashWithPermissionError = false
        try manager.deleteBackup(saved)

        do {
            try manager.deleteBackup(saved)
            Issue.record("存在しないファイルの削除でエラーが送出されませんでした。")
        } catch let error as PrefSnapError {
            if case .fileOperationFailed = error {
                // 期待どおりファイル未存在エラーが送出された
            } else {
                Issue.record("fileOperationFailed 以外のエラーです: \(error)")
            }
        }
    }
}
