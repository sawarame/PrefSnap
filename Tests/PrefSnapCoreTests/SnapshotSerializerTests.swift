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

    @Test("MVP プリセットカタログ件数と ControlCenter の ByHost 指定")
    func catalogContainsExpectedNumberOfMVPItems() {
        #expect(SettingCatalog.defaultsItems.count >= 30)
        #expect(SettingCatalog.defaultsItems.count <= 50)
        let controlCenterItems = SettingCatalog.defaultsItems.filter { $0.domain == "com.apple.controlcenter" }
        #expect(!controlCenterItems.isEmpty)
        let allControlCenterByHost = controlCenterItems.allSatisfy(\.isByHost)
        #expect(allControlCenterByHost)
    }
}
