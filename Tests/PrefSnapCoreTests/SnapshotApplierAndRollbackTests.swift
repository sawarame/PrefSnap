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
}
