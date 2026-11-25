import Foundation
import Testing
@testable import PrefSnapCore

@Suite("SnapshotDiffEngine のテスト")
struct SnapshotDiffEngineTests {
    private let host = SourceHostMetadata(hostName: "Mac", osVersion: "macOS 15", architecture: "arm64")

    @Test("変更がある項目のみ抽出し、null による未設定復元差分も検出すること")
    func diffExtractsOnlyChangedItemsIncludingUnsetNull() throws {
        let current = PrefSnapSnapshot(
            exportedAt: "2026-11-25T12:00:00Z",
            sourceHost: host,
            systemDefaults: [
                "dock.autohide": NullableValue(.bool(false)),
                "dock.tilesize": NullableValue(.int(48)),
                "finder.showAllFiles": NullableValue(.bool(true))
            ],
            menuBar: [
                "menubar.clock.showSeconds": NullableValue(.bool(false))
            ],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        let target = PrefSnapSnapshot(
            exportedAt: "2026-11-25T12:05:00Z",
            sourceHost: host,
            systemDefaults: [
                "dock.autohide": NullableValue(.bool(true)),   // 変更あり
                "dock.tilesize": NullableValue(.int(48)),      // 同一 → 除外
                "finder.showAllFiles": .unset                  // 現在値あり → null（削除差分）
            ],
            menuBar: [
                "menubar.clock.showSeconds": NullableValue(.bool(false)) // 同一 → 除外
            ],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        let engine = SnapshotDiffEngine()
        let report = engine.computeDiff(current: current, target: target, connectedKeyboards: [])

        #expect(report.items.count == 2)
        #expect(Set(report.items.map(\.id)) == ["defaults:dock.autohide", "defaults:finder.showAllFiles"])

        let deleteDiff = try #require(report.items.first { $0.id == "defaults:finder.showAllFiles" })
        #expect(deleteDiff.afterDisplay == "未設定へ戻す（削除）")
        if case let .defaultsSetting(_, newValue) = deleteDiff.action {
            #expect(newValue == nil)
        } else {
            Issue.record("defaultsSetting アクション（newValue == nil）が期待されます")
        }
    }

    @Test("修飾キーマッチング（完全一致・内蔵例外オプション・未接続スキップ）")
    func modifierMappingMatchingRulesExactBuiltInFallbackAndDisconnected() throws {
        let capsToCtrl = [ModifierKeyPair(src: 0x700000039, dst: 0x7000000E0)]

        // 移行先 Mac に接続されているキーボード:
        // - 外付け HHKB (1204-256): 完全一致
        // - 新しい Mac の内蔵キーボード (1452-999): 旧 Mac 内蔵 (1452-832) と ProductID 不一致だが内蔵同士
        let connected = [
            ConnectedKeyboard(vendorID: 1204, productID: 256, deviceName: "HHKB Studio", isBuiltIn: false),
            ConnectedKeyboard(vendorID: 1452, productID: 999, deviceName: "Apple Internal Keyboard M4", isBuiltIn: true)
        ]

        let current = PrefSnapSnapshot(
            exportedAt: "2026-11-25T12:00:00Z",
            sourceHost: host,
            systemDefaults: [:],
            menuBar: [:],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        let target = PrefSnapSnapshot(
            exportedAt: "2026-11-25T12:05:00Z",
            sourceHost: host,
            systemDefaults: [:],
            menuBar: [:],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: [
                ModifierMappingEntry(vendorID: 1204, productID: 256, deviceName: "HHKB Studio", isBuiltIn: false, mappings: capsToCtrl),
                ModifierMappingEntry(vendorID: 1452, productID: 832, deviceName: "Apple Internal Keyboard M1", isBuiltIn: true, mappings: capsToCtrl),
                ModifierMappingEntry(vendorID: 9999, productID: 111, deviceName: "Realforce R3", isBuiltIn: false, mappings: capsToCtrl)
            ]
        )

        let engine = SnapshotDiffEngine()
        let report = engine.computeDiff(current: current, target: target, connectedKeyboards: connected)

        #expect(report.items.count == 3)

        // 1. 完全一致
        let exact = try #require(report.items.first { $0.id == "modifier:1204-256" })
        #expect(exact.modifierMatchStatus == .exactMatch(connected[0]))
        #expect(exact.willApply == true)

        // 2. 内蔵キーボード例外（デフォルト未選択、オプション ON で移行先内蔵キーボード ID へ適用可能）
        var builtInFallback = try #require(report.items.first { $0.id == "modifier:1452-832->1452-999" })
        #expect(
            builtInFallback.modifierMatchStatus
                == .builtInFallbackAvailable(sourceDeviceName: "Apple Internal Keyboard M1", targetBuiltIn: connected[1])
        )
        #expect(builtInFallback.willApply == false)
        builtInFallback.applyToBuiltInKeyboard = true
        #expect(builtInFallback.willApply == true)
        if case let .modifierMapping(vendorID, productID, _, _) = builtInFallback.action {
            #expect(vendorID == 1452)
            #expect(productID == 999)
        } else {
            Issue.record("1452-999 向けの modifierMapping アクションが期待されます")
        }

        // 3. 未接続スキップ
        let disconnected = try #require(report.items.first { $0.id == "modifier:disconnected:9999-111" })
        #expect(disconnected.modifierMatchStatus == .disconnected)
        #expect(disconnected.isApplicable == false)
        #expect(disconnected.willApply == false)
        #expect(disconnected.detail.contains("未接続のためスキップ"))
    }
}
