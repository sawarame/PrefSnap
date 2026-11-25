import Foundation
import Testing
@testable import PrefSnapCore

@Suite("SnapshotSerializer とプリセットカタログのテスト")
struct SnapshotSerializerTests {
    @Test("schemaVersion・Pretty-print・キーソート・未設定の明示的 null 出力と復元デコード")
    func encodeAndDecodePreservesNullValuesAndSortsKeysDeterministically() throws {
        let serializer = SnapshotSerializer()
        let snapshot = PrefSnapSnapshot(
            exportedAt: "2026-11-25T12:00:00Z",
            sourceHost: SourceHostMetadata(hostName: "Mac-A", osVersion: "macOS 15.1", architecture: "arm64"),
            systemDefaults: [
                "dock.tilesize": NullableValue(.int(48)),
                "dock.autohide": NullableValue(.bool(true)),
                "finder.showAllFiles": .unset
            ],
            menuBar: [
                "menubar.controlcenter.batteryShowPercentage": NullableValue(.bool(true)),
                "menubar.clock.showSeconds": .unset
            ],
            symbolicHotKeys: [
                "64": NullableValue(SymbolicHotKeyEntry(enabled: false, valueType: "standard", parameters: [65535, 49, 1_048_576])),
                "65": .unset
            ],
            appShortcuts: [
                "NSGlobalDomain": ["書き出す...": "@$e"],
                "com.apple.Safari": ["タブをピン固定": "@^p"]
            ],
            modifierMappings: [
                ModifierMappingEntry(
                    vendorID: 1452,
                    productID: 832,
                    deviceName: "Apple Internal Keyboard",
                    isBuiltIn: true,
                    mappings: [ModifierKeyPair(src: 0x700000039, dst: 0x7000000E0)]
                ),
                ModifierMappingEntry(
                    vendorID: 1204,
                    productID: 256,
                    deviceName: "HHKB Professional",
                    isBuiltIn: false,
                    mappings: [ModifierKeyPair(src: 0x700000039, dst: 0x7000000E0)]
                )
            ]
        )

        let data = try serializer.encode(snapshot)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        // schemaVersion・Pretty-print・末尾改行・明示的な null 出力を検証
        #expect(jsonString.contains("\"schemaVersion\" : 1"))
        #expect(jsonString.contains("\"finder.showAllFiles\" : null"))
        #expect(jsonString.contains("\"menubar.clock.showSeconds\" : null"))
        #expect(jsonString.contains("\"65\" : null"))
        #expect(jsonString.hasSuffix("\n"))

        // キーがソートされ、modifierMappings も vendorID 昇順になっていること
        let decoded = try serializer.decode(data)
        #expect(decoded == snapshot)
        #expect(decoded.modifierMappings.map(\.vendorID) == [1204, 1452])
        #expect(decoded.systemDefaults["finder.showAllFiles"]?.value == nil)
        #expect(decoded.systemDefaults["dock.autohide"]?.value == .bool(true))
    }

    @Test("非対応の schemaVersion で専用エラーを投げること")
    func unsupportedSchemaVersionThrowsSpecificError() {
        let rawJSON = """
        {
          "appShortcuts" : {},
          "exportedAt" : "2026-11-25T12:00:00Z",
          "menuBar" : {},
          "modifierMappings" : [],
          "schemaVersion" : 99,
          "sourceHost" : {
            "architecture" : "arm64",
            "hostName" : "Mac-Future",
            "osVersion" : "macOS 99"
          },
          "symbolicHotKeys" : {},
          "systemDefaults" : {}
        }
        """
        let serializer = SnapshotSerializer()
        #expect(throws: PrefSnapError.unsupportedSchemaVersion(found: 99, supported: PrefSnapSnapshot.currentSchemaVersion)) {
            _ = try serializer.decode(Data(rawJSON.utf8))
        }
    }

    @Test("プリセットカタログ件数と ControlCenter（ByHost／通常ドメイン）の分類")
    func catalogContainsExpectedNumberOfMVPItems() {
        #expect(SettingCatalog.defaultsItems.count >= 60)

        let byHostCC = SettingCatalog.defaultsItems.filter {
            $0.domain == "com.apple.controlcenter" && $0.subcategory == .controlCenter
        }
        #expect(byHostCC.count == 12)
        let allByHostCC = byHostCC.allSatisfy(\.isByHost)
        #expect(allByHostCC)

        let statusItemCC = SettingCatalog.defaultsItems.filter {
            $0.domain == "com.apple.controlcenter" && $0.subcategory == .menuBarVisibility
        }
        #expect(statusItemCC.count == 16)
        let allStatusItemsNonByHost = statusItemCC.allSatisfy { !$0.isByHost }
        #expect(allStatusItemsNonByHost)

        let clockItems = SettingCatalog.defaultsItems.filter {
            $0.domain == "com.apple.menuextra.clock"
        }
        #expect(clockItems.count == 6)

        let layoutCC = SettingCatalog.defaultsItems.filter {
            $0.subcategory == .controlCenterLayout
        }
        #expect(layoutCC.count == 3)
        let allLayoutAreData = layoutCC.allSatisfy { $0.valueType == .data }
        #expect(allLayoutAreData)

        // 動的メニューバー表示キーから SettingDescriptor を復元できること
        let dynamicID = SettingCatalog.dynamicMenuBarStatusItemID(forKey: "NSStatusItem Visible Shortcuts")
        let dynamicDescriptor = SettingCatalog.dynamicMenuBarDescriptor(forID: dynamicID)
        #expect(dynamicDescriptor?.domain == "com.apple.controlcenter")
        #expect(dynamicDescriptor?.key == "NSStatusItem Visible Shortcuts")
        #expect(dynamicDescriptor?.isByHost == false)
    }

    @Test("DefaultsValue.data（UTF-8 JSON および任意バイナリ）が JSON 往復でロスレス復元されること")
    func defaultsValueDataRoundTripsLosslesslyInJSON() throws {
        let utf8JSON = Data("{\"Controls\":[{\"DisplayName\":\"ダークモード\"}]}".utf8)
        let rawBinary = Data([0x00, 0xFF, 0xFE, 0x10, 0x20])

        let serializer = SnapshotSerializer()
        let snapshot = PrefSnapSnapshot(
            exportedAt: "2026-11-25T14:00:00Z",
            sourceHost: SourceHostMetadata(hostName: "Mac-26", osVersion: "macOS 26.7", architecture: "arm64"),
            systemDefaults: [:],
            menuBar: [
                "menubar.controlcenter.chronoControls": NullableValue(.data(utf8JSON)),
                "menubar.controlcenter.bentoboxes": NullableValue(.data(rawBinary))
            ],
            symbolicHotKeys: [:],
            appShortcuts: [:],
            modifierMappings: []
        )

        let encoded = try serializer.encode(snapshot)
        let jsonText = try #require(String(data: encoded, encoding: .utf8))
        #expect(jsonText.contains("ダークモード"))
        #expect(jsonText.contains("\"encoding\" : \"utf8\""))
        #expect(jsonText.contains("\"encoding\" : \"base64\""))

        let decoded = try serializer.decode(encoded)
        #expect(decoded.menuBar["menubar.controlcenter.chronoControls"]?.value == .data(utf8JSON))
        #expect(decoded.menuBar["menubar.controlcenter.bentoboxes"]?.value == .data(rawBinary))

        let chronoDescriptor = try #require(SettingCatalog.defaultsItemsByID["menubar.controlcenter.chronoControls"])
        #expect(chronoDescriptor.formatDisplayValue(.data(utf8JSON)).contains("ダークモード"))
    }
}
