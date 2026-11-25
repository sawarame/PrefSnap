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

        // 2. メニューバーコントロール（com.apple.controlcenter は必ず -currentHost）
        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "BatteryShowPercentage", value: "1", isByHost: true)
        commandRunner.setDefaults(domain: "com.apple.controlcenter", key: "WiFi", value: "18", isByHost: true)
        commandRunner.setDefaults(domain: "com.apple.menuextra.clock", key: "ShowSeconds", value: "1", isByHost: false)

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

        // ControlCenter が -currentHost 付きで読み取られていること
        #expect(report.snapshot.menuBar["menubar.controlcenter.batteryShowPercentage"]?.value == .bool(true))
        #expect(report.snapshot.menuBar["menubar.controlcenter.wifi"]?.value == .int(18))
        #expect(report.snapshot.menuBar["menubar.clock.showSeconds"]?.value == .bool(true))
        let ccInvocations = commandRunner.recordedInvocations().filter { $0.arguments.contains("com.apple.controlcenter") }
        #expect(!ccInvocations.isEmpty)
        let allByHost = ccInvocations.allSatisfy { $0.arguments.first == "-currentHost" }
        #expect(allByHost)

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
}
