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

    @Test("メニューバー表示（NSStatusItem Visible* / 動的キー）およびコントロールセンター値ラベルの差分検出")
    func menuBarVisibilityAndDynamicKeysProduceReadableDiffs() throws {
        let dynamicID = SettingCatalog.dynamicMenuBarStatusItemID(forKey: "NSStatusItem Visible Shortcuts")

        let current = PrefSnapSnapshot(
            exportedAt: "2026-11-25T12:00:00Z",
            sourceHost: host,
            systemDefaults: [:],
            menuBar: [
                "menubar.controlcenter.wifi": NullableValue(.int(8)),
                "menubar.statusitem.visibleCC.battery": NullableValue(.bool(false)),
                dynamicID: NullableValue(.bool(false))
            ],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        let target = PrefSnapSnapshot(
            exportedAt: "2026-11-25T12:05:00Z",
            sourceHost: host,
            systemDefaults: [:],
            menuBar: [
                "menubar.controlcenter.wifi": NullableValue(.int(18)),
                "menubar.statusitem.visibleCC.battery": NullableValue(.bool(true)),
                dynamicID: NullableValue(.bool(true))
            ],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        let engine = SnapshotDiffEngine()
        let report = engine.computeDiff(current: current, target: target, connectedKeyboards: [])

        #expect(report.items.count == 3)
        let wifiDiff = try #require(report.items.first { $0.id == "defaults:menubar.controlcenter.wifi" })
        #expect(wifiDiff.beforeDisplay == "非表示 / アクティブ時のみ (8)")
        #expect(wifiDiff.afterDisplay == "常に表示 (18)")

        let ccBatteryDiff = try #require(report.items.first { $0.id == "defaults:menubar.statusitem.visibleCC.battery" })
        #expect(ccBatteryDiff.detail == "com.apple.controlcenter / NSStatusItem VisibleCC Battery")

        let dynamicDiff = try #require(report.items.first { $0.id == "defaults:\(dynamicID)" })
        #expect(dynamicDiff.title == "メニューバー表示: Shortcuts")
        #expect(dynamicDiff.restartTargets == [.controlCenter, .systemUIServer])
    }

    @Test("小数設定項目で JSON デコードされた整数 3 と現在値 3.0 が誤って差分扱いされず、変更時も -float で適用されること")
    func doubleSettingNormalizesDecodedIntegerToAvoidFalseDiffAndPreserveFloatType() throws {
        let currentSame = PrefSnapSnapshot(
            exportedAt: "2026-11-25T14:00:00Z",
            sourceHost: host,
            systemDefaults: [
                "trackpad.trackingSpeed": NullableValue(.double(3.0)),
                "dock.autohideDelay": NullableValue(.double(0.0))
            ],
            menuBar: [:],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        // JSON 経由で `3` や `0` が `.int` としてデコードされた状態を再現
        let targetDecodedAsInt = PrefSnapSnapshot(
            exportedAt: "2026-11-25T14:05:00Z",
            sourceHost: host,
            systemDefaults: [
                "trackpad.trackingSpeed": NullableValue(.int(3)),
                "dock.autohideDelay": NullableValue(.int(0))
            ],
            menuBar: [:],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        let engine = SnapshotDiffEngine()
        let sameReport = engine.computeDiff(current: currentSame, target: targetDecodedAsInt, connectedKeyboards: [])
        #expect(sameReport.items.isEmpty)

        // 実際に値が異なる場合（2.0 -> 3）は差分として検出され、適用アクションの型が .double(3.0)（-float）に正規化されること
        let currentDifferent = PrefSnapSnapshot(
            exportedAt: "2026-11-25T14:00:00Z",
            sourceHost: host,
            systemDefaults: [
                "trackpad.trackingSpeed": NullableValue(.double(2.0))
            ],
            menuBar: [:],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )
        let diffReport = engine.computeDiff(current: currentDifferent, target: targetDecodedAsInt, connectedKeyboards: [])
        let trackingDiff = try #require(diffReport.items.first { $0.id == "defaults:trackpad.trackingSpeed" })
        #expect(trackingDiff.beforeDisplay == "2.0")
        #expect(trackingDiff.afterDisplay == "3.0")
        if case let .defaultsSetting(_, newValue) = trackingDiff.action {
            #expect(newValue == .double(3.0))
            #expect(newValue?.defaultsWriteArguments() == ["-float", "3.0"])
        } else {
            Issue.record("trackpad.trackingSpeed の defaultsSetting アクションが期待されます")
        }
    }

    // MARK: - コントロールセンター配置（controlCenterLayout）意味的比較テスト

    /// テスト用の `bplist00` バイナリデータを生成するヘルパー。
    /// - Parameter object: シリアライズ対象の plist オブジェクト
    /// - Returns: バイナリ plist（`bplist00`）データ
    private func makeBinaryPlist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    /// テスト用のスナップショット（`menuBar` のみ設定）を生成するヘルパー。
    /// - Parameter menuBar: メニューバー設定辞書
    /// - Returns: テスト用の `PrefSnapSnapshot`
    private func makeMenuBarSnapshot(_ menuBar: [String: NullableValue<DefaultsValue>]) -> PrefSnapSnapshot {
        PrefSnapSnapshot(
            exportedAt: "2026-11-27T00:00:00Z",
            sourceHost: host,
            systemDefaults: [:],
            menuBar: menuBar,
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )
    }

    @Test("bentoboxes で順序非依存配列・辞書キー順・ネスト bplist00 の並び順とサイズ差のみの場合は誤差分にならないこと")
    func bentoBoxesIgnoresOrderOnlyDifferencesIncludingNestedBinaryPlists() throws {
        // ネストされた bplist00 モジュール定義（2 種類）
        let moduleA = try makeBinaryPlist([
            "identifier": "com.apple.controlcenter.wifi",
            "size": 2,
            "enabled": true
        ] as [String: Any])
        let moduleB = try makeBinaryPlist([
            "identifier": "com.apple.controlcenter.bluetooth",
            "size": 1,
            "enabled": false
        ] as [String: Any])

        // ネストされた bplist00 chronoControls 定義（ルート配列が bplist00 になっているパターンも検証）
        let chronoControl1 = try makeBinaryPlist(["id": "darkmode", "size": 1] as [String: Any])
        let chronoControl2 = try makeBinaryPlist(["id": "focus", "size": 2] as [String: Any])
        let chronoControlsBlobOrder1 = try makeBinaryPlist([chronoControl1, chronoControl2])
        let chronoControlsBlobOrder2 = try makeBinaryPlist([chronoControl2, chronoControl1])

        // displayablesData（Base64 化された bplist00）: instanceIds / modules / chronoControls の順序を入れ替え
        let displayablesPlist1 = try makeBinaryPlist([
            "instanceIds": ["inst-1", "inst-2", "inst-3"],
            "modules": [moduleA, moduleB],
            "chronoControls": chronoControlsBlobOrder1
        ] as [String: Any])
        let displayablesPlist2 = try makeBinaryPlist([
            "chronoControls": chronoControlsBlobOrder2,
            "modules": [moduleB, moduleA],
            "instanceIds": ["inst-3", "inst-1", "inst-2"]
        ] as [String: Any])

        let currentJSON = """
        [
          {
            "menuBarIconName": "square.grid.2x2",
            "grid": {
              "allLocations": [{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 0, "y": 1}],
              "occupiedLocations": [{"x": 0, "y": 0}, {"x": 1, "y": 0}],
              "unoccupiedLocations": [{"x": 0, "y": 1}, {"x": 1, "y": 1}],
              "elements": [
                {"id": "elem-a", "location": {"x": 0, "y": 0}, "size": {"w": 2, "h": 1}},
                {"id": "elem-b", "location": {"x": 1, "y": 0}, "size": {"w": 1, "h": 1}}
              ]
            },
            "displayablesData": "\(displayablesPlist1.base64EncodedString())"
          }
        ]
        """

        // キー順・空白（バイト長差）・順序非依存配列の並び順を変更（意味は完全同一）
        let targetJSON = """
        [{"displayablesData":"\(displayablesPlist2.base64EncodedString())","grid":{"elements":[{"size":{"h":1,"w":1},"location":{"y":0,"x":1},"id":"elem-b"},{"id":"elem-a","size":{"w":2,"h":1},"location":{"x":0,"y":0}}],"unoccupiedLocations":[{"y":1,"x":1},{"x":0,"y":1}],"occupiedLocations":[{"y":0,"x":1},{"x":0,"y":0}],"allLocations":[{"x":0,"y":1},{"y":0,"x":0},{"x":1,"y":0}]},"menuBarIconName":"square.grid.2x2"}]
        """

        let currentData = Data(currentJSON.utf8)
        let targetData = Data(targetJSON.utf8)
        // 生バイト列およびバイト長が異なる状態であることを前提検証
        #expect(currentData != targetData)
        #expect(currentData.count != targetData.count)

        let engine = SnapshotDiffEngine()
        let report = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(currentData))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(targetData))]),
            connectedKeyboards: []
        )

        #expect(report.items.isEmpty)
    }

    @Test("bentoboxes の実質変更（座標・サイズ・ボックス数・アイコン名・モジュール構成・nil 遷移）を検出し生 Data を無加工保持すること")
    func bentoBoxesDetectsRealSemanticChangesAndPreservesRawTargetData() throws {
        let moduleWifi = try makeBinaryPlist(["identifier": "wifi", "size": 2] as [String: Any])
        let moduleWifiResized = try makeBinaryPlist(["identifier": "wifi", "size": 4] as [String: Any])
        let moduleBT = try makeBinaryPlist(["identifier": "bluetooth", "size": 1] as [String: Any])

        func makeBoxData(
            iconName: String = "square.grid.2x2",
            locationX: Int = 0,
            width: Int = 2,
            modules: [Data],
            boxCount: Int = 1
        ) throws -> Data {
            let displayables = try makeBinaryPlist([
                "instanceIds": ["inst-1"],
                "modules": modules
            ] as [String: Any])
            let box: [String: Any] = [
                "menuBarIconName": iconName,
                "grid": [
                    "allLocations": [["x": 0, "y": 0]],
                    "occupiedLocations": [["x": locationX, "y": 0]],
                    "unoccupiedLocations": [],
                    "elements": [
                        ["id": "elem-a", "location": ["x": locationX, "y": 0], "size": ["w": width, "h": 1]]
                    ]
                ],
                "displayablesData": displayables.base64EncodedString()
            ]
            let boxes = Array(repeating: box, count: boxCount)
            return try JSONSerialization.data(withJSONObject: boxes, options: [])
        }

        let baseData = try makeBoxData(modules: [moduleWifi])
        let changedCases: [Data] = [
            try makeBoxData(locationX: 1, modules: [moduleWifi]),                  // 配置座標の変更
            try makeBoxData(width: 4, modules: [moduleWifi]),                      // サイズの変更
            try makeBoxData(modules: [moduleWifi], boxCount: 2),                   // ボックス数の変更
            try makeBoxData(iconName: "star.fill", modules: [moduleWifi]),         // menuBarIconName の変更
            try makeBoxData(modules: [moduleWifi, moduleBT]),                      // モジュール追加
            try makeBoxData(modules: []),                                          // モジュール削除
            try makeBoxData(modules: [moduleWifiResized])                          // モジュールサイズ変更
        ]

        let engine = SnapshotDiffEngine()
        for targetData in changedCases {
            let report = engine.computeDiff(
                current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(baseData))]),
                target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(targetData))]),
                connectedKeyboards: []
            )
            let diff = try #require(report.items.first { $0.id == "defaults:menubar.controlcenter.bentoboxes" })
            // DiffItem.action にはインポート元の生 Data が無加工のまま保持されていること
            if case let .defaultsSetting(_, newValue) = diff.action {
                #expect(newValue == .data(targetData))
            } else {
                Issue.record("defaultsSetting アクションが期待されます")
            }
        }

        // 片方が nil の場合は従来どおり差分ありとなること
        let nilToDataReport = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": .unset]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(baseData))]),
            connectedKeyboards: []
        )
        #expect(nilToDataReport.items.count == 1)

        let dataToNilReport = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(baseData))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": .unset]),
            connectedKeyboards: []
        )
        #expect(dataToNilReport.items.count == 1)
    }

    @Test("displayableMenuExtras と chronoControls で誤差分を除外しつつ順序依存配列（displayableInfos / Controls / $objects）の変更を検出すること")
    func displayableMenuExtrasAndChronoControlsSemanticDiffAndOrderedArrays() throws {
        let engine = SnapshotDiffEngine()

        // NSKeyedArchiver 形式（$objects や CFKeyedArchiverUID を含む）の bplist00 を検証用に使用
        let archivedControl1 = try NSKeyedArchiver.archivedData(
            withRootObject: ["DarkMode", "Focus"] as NSArray,
            requiringSecureCoding: false
        )
        let archivedControl2 = try NSKeyedArchiver.archivedData(
            withRootObject: ["DarkMode", "Focus"] as NSArray,
            requiringSecureCoding: false
        )

        let providerPlist1 = try makeBinaryPlist([
            "instanceIds": ["extra-1", "extra-2"],
            "enabled": true,
            "priority": 10
        ] as [String: Any])
        let providerPlist2 = try makeBinaryPlist([
            "priority": 10,
            "enabled": true,
            "instanceIds": ["extra-2", "extra-1"]
        ] as [String: Any])

        // 1. displayableMenuExtras: JSON キー順・providerData 内辞書キー順と instanceIds 順のみ異なる → 差分なし
        let extrasCurrent = Data("""
        {
          "version": 1,
          "displayableInfos": [
            {"id": "first", "providerData": "\(providerPlist1.base64EncodedString())"},
            {"id": "second", "providerData": "\(archivedControl1.base64EncodedString())"}
          ]
        }
        """.utf8)
        let extrasEquivalent = Data("""
        {"displayableInfos":[{"providerData":"\(providerPlist2.base64EncodedString())","id":"first"},{"id":"second","providerData":"\(archivedControl2.base64EncodedString())"}],"version":1}
        """.utf8)
        #expect(extrasCurrent != extrasEquivalent)

        let extrasNoDiff = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(extrasCurrent))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(extrasEquivalent))]),
            connectedKeyboards: []
        )
        #expect(extrasNoDiff.items.isEmpty)

        // displayableInfos は順序に意味があるため、要素順が入れ替わったら差分ありになること
        let extrasReordered = Data("""
        {
          "version": 1,
          "displayableInfos": [
            {"id": "second", "providerData": "\(archivedControl1.base64EncodedString())"},
            {"id": "first", "providerData": "\(providerPlist1.base64EncodedString())"}
          ]
        }
        """.utf8)
        let extrasDiff = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(extrasCurrent))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(extrasReordered))]),
            connectedKeyboards: []
        )
        #expect(extrasDiff.items.count == 1)

        // 2. chronoControls: JSON キー順・ControlIdentity 内辞書キー順と instanceIds 順のみ異なる → 差分なし
        let identity1 = try makeBinaryPlist(["instanceIds": ["c-1", "c-2"], "bundle": "com.apple.ControlCenter"] as [String: Any])
        let identity2 = try makeBinaryPlist(["bundle": "com.apple.ControlCenter", "instanceIds": ["c-2", "c-1"]] as [String: Any])

        let chronoCurrent = Data("""
        {
          "Controls": [
            {"DisplayName": "ダークモード", "ControlIdentity": "\(identity1.base64EncodedString())"},
            {"DisplayName": "集中モード", "ControlIdentity": "\(archivedControl1.base64EncodedString())"}
          ],
          "SchemaVersion": 2
        }
        """.utf8)
        let chronoEquivalent = Data("""
        {"SchemaVersion":2,"Controls":[{"ControlIdentity":"\(identity2.base64EncodedString())","DisplayName":"ダークモード"},{"DisplayName":"集中モード","ControlIdentity":"\(archivedControl2.base64EncodedString())"}]}
        """.utf8)
        #expect(chronoCurrent != chronoEquivalent)

        let chronoNoDiff = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(chronoCurrent))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(chronoEquivalent))]),
            connectedKeyboards: []
        )
        #expect(chronoNoDiff.items.isEmpty)

        // Controls 配列は順序に意味があるため並び替えで差分検出され、生 targetData が保持されること
        let chronoReordered = Data("""
        {
          "SchemaVersion": 2,
          "Controls": [
            {"DisplayName": "集中モード", "ControlIdentity": "\(archivedControl1.base64EncodedString())"},
            {"DisplayName": "ダークモード", "ControlIdentity": "\(identity1.base64EncodedString())"}
          ]
        }
        """.utf8)
        let chronoDiff = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(chronoCurrent))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(chronoReordered))]),
            connectedKeyboards: []
        )
        let chronoItem = try #require(chronoDiff.items.first { $0.id == "defaults:menubar.controlcenter.chronoControls" })
        if case let .defaultsSetting(_, newValue) = chronoItem.action {
            #expect(newValue == .data(chronoReordered))
        } else {
            Issue.record("chronoControls の defaultsSetting アクションが期待されます")
        }

        // $objects 配列（順序依存）の変更が誤ってソート無視されないこと
        let keyedArchiveA = try makeBinaryPlist([
            "$archiver": "NSKeyedArchiver",
            "$version": 100000,
            "$objects": ["$null", "FirstObject", "SecondObject"]
        ] as [String: Any])
        let keyedArchiveB = try makeBinaryPlist([
            "$archiver": "NSKeyedArchiver",
            "$version": 100000,
            "$objects": ["$null", "SecondObject", "FirstObject"]
        ] as [String: Any])
        let archiveJSONA = Data("{\"ControlIdentity\":\"\(keyedArchiveA.base64EncodedString())\"}".utf8)
        let archiveJSONB = Data("{\"ControlIdentity\":\"\(keyedArchiveB.base64EncodedString())\"}".utf8)
        let archiveDiff = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(archiveJSONA))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(archiveJSONB))]),
            connectedKeyboards: []
        )
        #expect(archiveDiff.items.count == 1)
    }

    @Test("NSNumber の真偽値（true/false）と数値（1/0）を厳密に区別すること")
    func controlCenterNormalizerStrictlyDistinguishesBoolAndNumber() throws {
        let engine = SnapshotDiffEngine()

        // JSON 内の Bool と Int の区別
        let boolJSON = Data(#"[{"enabled": true, "count": 0}]"#.utf8)
        let intJSON = Data(#"[{"enabled": 1, "count": false}]"#.utf8)
        let jsonReport = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(boolJSON))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(intJSON))]),
            connectedKeyboards: []
        )
        #expect(jsonReport.items.count == 1)

        // 内包 bplist00 内の Bool と Int の区別
        let boolPlist = try makeBinaryPlist(["flag": true] as [String: Any])
        let intPlist = try makeBinaryPlist(["flag": 1] as [String: Any])
        let plistJSONA = Data("{\"providerData\":\"\(boolPlist.base64EncodedString())\"}".utf8)
        let plistJSONB = Data("{\"providerData\":\"\(intPlist.base64EncodedString())\"}".utf8)
        let plistReport = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(plistJSONA))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(plistJSONB))]),
            connectedKeyboards: []
        )
        #expect(plistReport.items.count == 1)
    }

    @Test("非 JSON データや破損した Base64 / bplist00 でもクラッシュせず生バイト列完全一致比較へフォールバックすること")
    func controlCenterNormalizerFallsBackSafelyOnInvalidJSONBase64OrBinaryPlist() throws {
        let engine = SnapshotDiffEngine()

        // 1. 非 JSON バイナリデータ
        let rawBinaryA = Data([0x00, 0xFF, 0x10, 0x20])
        let rawBinaryB = Data([0x00, 0xFF, 0x10, 0x21])

        let sameBinaryReport = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(rawBinaryA))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(rawBinaryA))]),
            connectedKeyboards: []
        )
        #expect(sameBinaryReport.items.isEmpty)

        let diffBinaryReport = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(rawBinaryA))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(rawBinaryB))]),
            connectedKeyboards: []
        )
        #expect(diffBinaryReport.items.count == 1)

        // 2. 破損した Base64（bplist00 プレフィックス付き不正文字）
        let brokenBase64A = Data(#"{"a":1,"displayablesData":"YnBsaXN0MD!!!corrupted!!!"}"#.utf8)
        let brokenBase64B = Data(#"{"displayablesData":"YnBsaXN0MD!!!corrupted!!!","a":1}"#.utf8)

        let sameBrokenBase64 = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(brokenBase64A))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(brokenBase64A))]),
            connectedKeyboards: []
        )
        #expect(sameBrokenBase64.items.isEmpty)

        // 正規化失敗時は生バイト列比較へフォールバックするため、バイト列が異なれば差分ありとなる
        let diffBrokenBase64 = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(brokenBase64A))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.displayableMenuExtras": NullableValue(.data(brokenBase64B))]),
            connectedKeyboards: []
        )
        #expect(diffBrokenBase64.items.count == 1)

        // 3. 破損した bplist00（先頭 8 バイトは bplist00 だが不正なバイナリ本体）
        let corruptedPlistBase64 = Data("bplist00corrupted-body".utf8).base64EncodedString()
        let brokenPlistA = Data(#"{"a":1,"ControlIdentity":"\#(corruptedPlistBase64)"}"#.utf8)
        let brokenPlistB = Data(#"{"ControlIdentity":"\#(corruptedPlistBase64)","a":1}"#.utf8)

        let sameBrokenPlist = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(brokenPlistA))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(brokenPlistA))]),
            connectedKeyboards: []
        )
        #expect(sameBrokenPlist.items.isEmpty)

        let diffBrokenPlist = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(brokenPlistA))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.chronoControls": NullableValue(.data(brokenPlistB))]),
            connectedKeyboards: []
        )
        #expect(diffBrokenPlist.items.count == 1)

        // 4. 展開後 plist 内にネストされた破損 bplist00 Data
        let outerWithBrokenInner = try makeBinaryPlist([
            "modules": [Data("bplist00broken-nested".utf8)]
        ] as [String: Any])
        let nestedBrokenA = Data(#"{"a":1,"displayablesData":"\#(outerWithBrokenInner.base64EncodedString())"}"#.utf8)
        let nestedBrokenB = Data(#"{"displayablesData":"\#(outerWithBrokenInner.base64EncodedString())","a":1}"#.utf8)

        let diffNestedBroken = engine.computeDiff(
            current: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(nestedBrokenA))]),
            target: makeMenuBarSnapshot(["menubar.controlcenter.bentoboxes": NullableValue(.data(nestedBrokenB))]),
            connectedKeyboards: []
        )
        #expect(diffNestedBroken.items.count == 1)
    }
}
