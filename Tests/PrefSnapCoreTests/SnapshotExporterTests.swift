import Foundation
import Testing
@testable import PrefSnapCore

@Suite("SnapshotExporter のテスト")
struct SnapshotExporterTests {
    @Test("5 カテゴリの読み取り・ByHost 指定・IOKit メタデータ付与")
    func exportsAllFiveCategoriesWithByHostAndIOKitMetadata() throws {
        let commandRunner = MockCommandRunner()
        let plistStore = MockPlistStore()
        let keyboardDetector = MockKeyboardDetector(keyboards: [
            ConnectedKeyboard(vendorID: 1452, productID: 832, deviceName: "Apple Internal Keyboard", isBuiltIn: true),
            ConnectedKeyboard(vendorID: 1204, productID: 256, deviceName: "HHKB Studio", isBuiltIn: false)
        ])
        let environment = MockEnvironmentProvider()

        // 1. システム基本設定
        commandRunner.setDefaults(domain: "com.apple.dock", key: "autohide", value: "1")
        commandRunner.setDefaults(domain: "com.apple.dock", key: "tilesize", value: "44")
        commandRunner.setDefaults(domain: "com.apple.finder", key: "ShowPathbar", value: "1")
        commandRunner.setDefaults(domain: "NSGlobalDomain", key: "KeyRepeat", value: "2")

        // 2. メニューバーコントロール（ByHost と通常ドメイン NSStatusItem Visible* の両対応）
        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "BatteryShowPercentage", value: "1", isByHost: true)
        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "WiFi", value: "18", isByHost: true)
        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "NSStatusItem VisibleCC Battery", value: "1", isByHost: false)
        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "NSStatusItem Visible WiFi", value: "0", isByHost: false)
        commandRunner.setDefaults(domain: "com.apple.menuextra.clock", key: "ShowSeconds", value: "1", isByHost: false)
        commandRunner.setDefaults(domain: "com.apple.menuextra.clock", key: "ShowDate", value: "0", isByHost: false)

        // 2-b. 通常ドメイン com.apple.controlcenter.plist の動的 NSStatusItem Visible* キー
        try plistStore.setPlist([
            "NSStatusItem VisibleCC Battery": true, // 固定カタログ済みのため動的キーとしては重複追加されない
            "NSStatusItem Visible Shortcuts": false,
            "NSStatusItem Visible Item-0": true,
            "UnrelatedKey": "ignored"
        ], at: plistStore.preferencesDirectory.appendingPathComponent("com.apple.controlcenter.plist"))

        // 2-c. macOS 26 (Tahoe) コントロールセンター配置データ（Data 型）
        let bentoData = Data("[{\"menuBarIconName\":\"circle.grid.2x2\"}]".utf8)
        let extrasData = Data("{\"displayableInfos\":[{\"id\":\"wifi\"}]}".utf8)
        let chronoData = Data("{\"Controls\":[{\"DisplayName\":\"ダークモード\"}]}".utf8)
        commandRunner.setDefaultsData(domain: "com.apple.controlcenter.bentoboxes", key: "boxes", data: bentoData, isByHost: true)
        commandRunner.setDefaultsData(domain: "com.apple.controlcenter.displayablemenuextras", key: "displayablesInfo", data: extrasData, isByHost: true)
        commandRunner.setDefaultsData(domain: "com.apple.controlcenter", key: "ControlCenterDisplayableChronoControlsProviderConfiguration", data: chronoData, isByHost: false)

        // 3. システム標準ショートカット
        let hotKeysURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.symbolichotkeys.plist")
        try plistStore.setPlist([
            "AppleSymbolicHotKeys": [
                "64": [
                    "enabled": false,
                    "value": ["type": "standard", "parameters": [65535, 49, 1_048_576]]
                ]
            ]
        ], at: hotKeysURL)

        // 4. アプリケーションショートカット
        try plistStore.setPlist([
            "NSUserKeyEquivalents": ["書き出す...": "@$e"]
        ], at: plistStore.preferencesDirectory.appendingPathComponent(".GlobalPreferences.plist"))

        try plistStore.setPlist([
            "com.apple.custommenu.apps": ["com.apple.Safari"]
        ], at: plistStore.preferencesDirectory.appendingPathComponent("com.apple.universalaccess.plist"))

        try plistStore.setPlist([
            "NSUserKeyEquivalents": ["タブをピン固定": "@^p"]
        ], at: plistStore.preferencesDirectory.appendingPathComponent("com.apple.Safari.plist"))

        // 5. 修飾キーリマップ（ByHost/.GlobalPreferences）
        let byHostURL = plistStore.byHostDirectory.appendingPathComponent(".GlobalPreferences.ABCDEF12-3456.plist")
        try plistStore.setPlist([
            "com.apple.keyboard.modifiermapping.1452-832-0": [
                [
                    "HIDKeyboardModifierMappingSrc": NSNumber(value: UInt64(0x700000039)),
                    "HIDKeyboardModifierMappingDst": NSNumber(value: UInt64(0x7000000E0))
                ]
            ]
        ], at: byHostURL)

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            environment: environment
        )
        let report = exporter.exportSnapshot()

        #expect(report.issues.isEmpty)
        #expect(report.snapshot.systemDefaults["dock.autohide"]?.value == .bool(true))
        #expect(report.snapshot.systemDefaults["dock.tilesize"]?.value == .int(44))
        // 未設定項目はキーが存在し、かつ値が nil（JSON では null）になること
        #expect(report.snapshot.systemDefaults.keys.contains("dock.magnification"))
        #expect(report.snapshot.systemDefaults["dock.magnification"]?.value == nil)

        // ControlCenter の ByHost 項目は -currentHost 付き、NSStatusItem Visible* 項目は通常ドメインで読み取られていること
        #expect(report.snapshot.menuBar["menubar.controlcenter.batteryShowPercentage"]?.value == .bool(true))
        #expect(report.snapshot.menuBar["menubar.controlcenter.wifi"]?.value == .int(18))
        #expect(report.snapshot.menuBar["menubar.statusitem.visibleCC.battery"]?.value == .bool(true))
        #expect(report.snapshot.menuBar["menubar.statusitem.visible.wifi"]?.value == .bool(false))
        #expect(report.snapshot.menuBar["menubar.clock.showSeconds"]?.value == .bool(true))
        #expect(report.snapshot.menuBar["menubar.clock.showDate"]?.value == .int(0))

        // 動的検出されたステータス項目が格納され、固定カタログ項目は重複しないこと
        let shortcutsID = SettingCatalog.dynamicMenuBarStatusItemID(forKey: "NSStatusItem Visible Shortcuts")
        let item0ID = SettingCatalog.dynamicMenuBarStatusItemID(forKey: "NSStatusItem Visible Item-0")
        let duplicateBatteryID = SettingCatalog.dynamicMenuBarStatusItemID(forKey: "NSStatusItem VisibleCC Battery")
        #expect(report.snapshot.menuBar[shortcutsID]?.value == .bool(false))
        #expect(report.snapshot.menuBar[item0ID]?.value == .bool(true))
        #expect(report.snapshot.menuBar[duplicateBatteryID] == nil)

        let wifiByHostInvocations = commandRunner.recordedInvocations().filter {
            $0.arguments.contains("com.apple.controlcenter") && $0.arguments.contains("WiFi")
        }
        #expect(wifiByHostInvocations.count == 1)
        #expect(wifiByHostInvocations.first?.arguments.first == "-currentHost")

        let visibleCCBatteryInvocations = commandRunner.recordedInvocations().filter {
            $0.arguments.contains("com.apple.controlcenter") && $0.arguments.contains("NSStatusItem VisibleCC Battery")
        }
        #expect(visibleCCBatteryInvocations.count == 1)
        #expect(visibleCCBatteryInvocations.first?.arguments.first != "-currentHost")

        // macOS 26 コントロールセンター Data 項目が defaults [-currentHost] export 経由でロスレス取得されていること
        #expect(report.snapshot.menuBar["menubar.controlcenter.bentoboxes"]?.value == .data(bentoData))
        #expect(report.snapshot.menuBar["menubar.controlcenter.displayableMenuExtras"]?.value == .data(extrasData))
        #expect(report.snapshot.menuBar["menubar.controlcenter.chronoControls"]?.value == .data(chronoData))

        // 標準ショートカット
        #expect(
            report.snapshot.symbolicHotKeys["64"]?.value
                == SymbolicHotKeyEntry(enabled: false, valueType: "standard", parameters: [65535, 49, 1_048_576])
        )
        #expect(report.snapshot.symbolicHotKeys["65"]?.value == nil)

        // アプリショートカット
        #expect(report.snapshot.appShortcuts["NSGlobalDomain"] == ["書き出す...": "@$e"])
        #expect(report.snapshot.appShortcuts["com.apple.Safari"] == ["タブをピン固定": "@^p"])

        // 修飾キーリマップ + IOKit メタデータ
        #expect(report.snapshot.modifierMappings.count == 1)
        let mapping = try #require(report.snapshot.modifierMappings.first)
        #expect(mapping.vendorID == 1452)
        #expect(mapping.productID == 832)
        #expect(mapping.deviceName == "Apple Internal Keyboard")
        #expect(mapping.isBuiltIn == true)
        #expect(mapping.mappings == [ModifierKeyPair(src: 0x700000039, dst: 0x7000000E0)])
    }

    @Test("権限エラー発生時にクラッシュせずシステム設定 URL 付きでレポートすること")
    func permissionErrorsAreReportedWithoutCrashing() throws {
        let commandRunner = MockCommandRunner()
        let plistStore = MockPlistStore()
        let keyboardDetector = MockKeyboardDetector()

        commandRunner.permissionDeniedKeys.insert(
            MockCommandRunner.storageKey(domain: "com.apple.controlcenter", key: "WiFi", isByHost: true)
        )
        let hotKeysURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.symbolichotkeys.plist")
        try plistStore.setPlist(["AppleSymbolicHotKeys": [:]], at: hotKeysURL)
        plistStore.permissionDeniedPaths.insert("com.apple.symbolichotkeys.plist")

        keyboardDetector.errorToThrow = PrefSnapError.permissionDenied(
            target: "IOKit キーボード検出",
            detail: "Not permitted",
            settingsURL: SystemPreferencesURL.inputMonitoring
        )

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: plistStore,
            keyboardDetector: keyboardDetector,
            environment: MockEnvironmentProvider()
        )
        let report = exporter.exportSnapshot()

        let permissionIssues = report.issues.filter(\.isPermissionError)
        #expect(permissionIssues.count == 3)
        let hasFullDiskAccessLink = permissionIssues.contains { $0.systemSettingsURL == SystemPreferencesURL.fullDiskAccess }
        let hasInputMonitoringLink = permissionIssues.contains { $0.systemSettingsURL == SystemPreferencesURL.inputMonitoring }
        #expect(hasFullDiskAccessLink)
        #expect(hasInputMonitoringLink)
    }

    /// `DefaultsCommandStderrClassifier` が macOS 27 形式・従来形式・権限エラー・その他エラーを正しく分類できることを検証する。
    @Test("DefaultsCommandStderrClassifier の未存在判定と権限エラー優先判定")
    func defaultsStderrClassifierHandlesMacOS27AndLegacyMessages() {
        // macOS 27 以降のキー未存在・ドメイン未存在メッセージ
        #expect(DefaultsCommandStderrClassifier.isMissingEntry("Error: Could not find key 'tilesize' in domain 'com.apple.dock'."))
        #expect(DefaultsCommandStderrClassifier.isMissingEntry("Error: Domain 'com.apple.controlcenter.bentoboxes' not found."))

        // 従来の macOS 形式
        #expect(DefaultsCommandStderrClassifier.isMissingEntry("The domain/default pair of (com.apple.dock, tilesize) does not exist"))
        #expect(DefaultsCommandStderrClassifier.isMissingEntry("Domain (com.apple.dock) not found."))

        // 権限エラーは未存在扱いせず、permissionDenied として優先分類すること
        let mixedPermissionMsg = "Error: Could not find key 'tilesize' in domain 'com.apple.dock': Operation not permitted"
        #expect(DefaultsCommandStderrClassifier.isPermissionDenied(mixedPermissionMsg))
        #expect(!DefaultsCommandStderrClassifier.isMissingEntry(mixedPermissionMsg))
        #expect(DefaultsCommandStderrClassifier.isPermissionDenied("Permission denied"))

        // 不明なコマンドエラーは未存在扱いしないこと
        #expect(!DefaultsCommandStderrClassifier.isMissingEntry("defaults: invalid option -- z"))
        #expect(!DefaultsCommandStderrClassifier.isMissingEntry("zsh: command not found: defaults"))
    }

    /// macOS 27 形式の未存在 stderr を返す環境でスキャンしても、未設定項目がエラー扱いにならないことを検証する。
    @Test("macOS 27 形式の未設定キー・未存在ドメイン stderr が SnapshotExporter で未設定扱いになること")
    func macOS27MissingKeyAndDomainStderrAreTreatedAsUnsetWithoutIssues() {
        let commandRunner = MockCommandRunner()
        commandRunner.customHandler = { executable, arguments in
            guard executable == "/usr/bin/defaults" else {
                return CommandOutput(exitCode: 0)
            }
            var args = arguments
            if args.first == "-currentHost" {
                args.removeFirst()
            }
            guard args.count >= 3 else {
                return CommandOutput(exitCode: 1, stderr: "invalid arguments")
            }
            let verb = args[0]
            let domain = args[1]
            let key = args[2]

            if verb == "read" && domain == "com.apple.dock" && key == "autohide" {
                return CommandOutput(exitCode: 0, stdout: "1\n")
            }
            if verb == "export" {
                // macOS 27 形式のドメイン未存在エラーをシミュレートする
                return CommandOutput(exitCode: 1, stderr: "Error: Domain '\(domain)' not found.\n")
            }
            // macOS 27 形式のキー未存在エラーをシミュレートする
            return CommandOutput(exitCode: 1, stderr: "Error: Could not find key '\(key)' in domain '\(domain)'.\n")
        }

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: MockPlistStore(),
            keyboardDetector: MockKeyboardDetector(),
            environment: MockEnvironmentProvider()
        )
        let report = exporter.exportSnapshot()

        #expect(report.issues.isEmpty)
        #expect(report.snapshot.systemDefaults["dock.autohide"]?.value == .bool(true))
        #expect(report.snapshot.systemDefaults.keys.contains("dock.tilesize"))
        #expect(report.snapshot.systemDefaults["dock.tilesize"]?.value == nil)
        #expect(report.snapshot.menuBar.keys.contains("menubar.controlcenter.bentoboxes"))
        #expect(report.snapshot.menuBar["menubar.controlcenter.bentoboxes"]?.value == nil)
    }

    /// 未存在にも権限不足にも該当しない異常終了時は従来通り `issues` にコマンド失敗が報告されることを検証する。
    @Test("未存在・権限不足以外の defaults コマンド異常終了は issues として報告されること")
    func unexpectedDefaultsCommandFailuresAreStillReportedAsIssues() {
        let commandRunner = MockCommandRunner()
        commandRunner.customHandler = { executable, arguments in
            guard executable == "/usr/bin/defaults" else {
                return CommandOutput(exitCode: 0)
            }
            var args = arguments
            if args.first == "-currentHost" {
                args.removeFirst()
            }
            let verb = args[0]
            let domain = args[1]
            let key = args[2]

            // 通常 read で未知エラーを発生させる
            if verb == "read" && domain == "com.apple.dock" && key == "tilesize" {
                return CommandOutput(exitCode: 2, stderr: "Unexpected defaults internal failure")
            }
            // Data export で未知エラーを発生させる
            if verb == "export" && domain == "com.apple.controlcenter.bentoboxes" {
                return CommandOutput(exitCode: 2, stderr: "Unexpected export failure")
            }
            // 権限エラーを発生させる
            if verb == "read" && domain == "com.apple.finder" && key == "ShowPathbar" {
                return CommandOutput(exitCode: 1, stderr: "Error: Could not find key 'ShowPathbar' in domain 'com.apple.finder': Operation not permitted")
            }
            return CommandOutput(exitCode: 1, stderr: "Error: Could not find key '\(key)' in domain '\(domain)'.")
        }

        let exporter = SnapshotExporter(
            commandRunner: commandRunner,
            plistStore: MockPlistStore(),
            keyboardDetector: MockKeyboardDetector(),
            environment: MockEnvironmentProvider()
        )
        let report = exporter.exportSnapshot()

        #expect(report.issues.count == 3)
        let permissionIssues = report.issues.filter(\.isPermissionError)
        #expect(permissionIssues.count == 1)
        #expect(permissionIssues.first?.systemSettingsURL == SystemPreferencesURL.fullDiskAccess)

        let commandIssues = report.issues.filter { !$0.isPermissionError }
        #expect(commandIssues.count == 2)
        #expect(commandIssues.contains { $0.message.contains("Unexpected defaults internal failure") })
        #expect(commandIssues.contains { $0.message.contains("Unexpected export failure") })
    }
}
