import Foundation

/// エクスポート元の Mac に関するメタデータ。
public struct SourceHostMetadata: Codable, Equatable, Sendable {
    public let hostName: String
    public let osVersion: String
    public let architecture: String

    public init(hostName: String, osVersion: String, architecture: String) {
        self.hostName = hostName
        self.osVersion = osVersion
        self.architecture = architecture
    }
}

/// `com.apple.symbolichotkeys` 内の 1 エントリ表現。
public struct SymbolicHotKeyEntry: Codable, Equatable, Hashable, Sendable {
    public let enabled: Bool
    public let valueType: String?
    public let parameters: [Int]?

    public init(enabled: Bool, valueType: String? = "standard", parameters: [Int]? = nil) {
        self.enabled = enabled
        self.valueType = valueType
        self.parameters = parameters
    }

    /// 画面表示用のわかりやすい要約文字列。
    public var displayString: String {
        let state = enabled ? "有効" : "無効"
        guard let parameters, parameters.count >= 3 else {
            return state
        }
        let modifiers = Self.formatModifierFlags(parameters[2])
        let keyLabel = Self.formatKey(ascii: parameters[0], keyCode: parameters[1])
        let combo = modifiers.isEmpty ? keyLabel : "\(modifiers)\(keyLabel)"
        return "\(state)（\(combo)）"
    }

    /// plist の辞書形式へ変換する。
    public func toPlistDictionary() -> [String: Any] {
        var dict: [String: Any] = ["enabled": enabled]
        if let parameters {
            dict["value"] = [
                "type": valueType ?? "standard",
                "parameters": parameters
            ] as [String: Any]
        }
        return dict
    }

    /// plist 辞書から `SymbolicHotKeyEntry` を生成する。
    public static func fromPlistDictionary(_ dict: [String: Any]) -> SymbolicHotKeyEntry? {
        let enabledValue: Bool
        if let boolVal = dict["enabled"] as? Bool {
            enabledValue = boolVal
        } else if let numVal = dict["enabled"] as? NSNumber {
            enabledValue = numVal.intValue != 0
        } else {
            return nil
        }

        var valueType: String?
        var parameters: [Int]?
        if let valueDict = dict["value"] as? [String: Any] {
            valueType = valueDict["type"] as? String
            if let rawParams = valueDict["parameters"] as? [NSNumber] {
                parameters = rawParams.map(\.intValue)
            } else if let intParams = valueDict["parameters"] as? [Int] {
                parameters = intParams
            }
        }
        return SymbolicHotKeyEntry(enabled: enabledValue, valueType: valueType, parameters: parameters)
    }

    private static func formatModifierFlags(_ flags: Int) -> String {
        var parts: [String] = []
        if (flags & (1 << 18)) != 0 { parts.append("⌃") } // Control
        if (flags & (1 << 19)) != 0 { parts.append("⌥") } // Option
        if (flags & (1 << 17)) != 0 { parts.append("⇧") } // Shift
        if (flags & (1 << 20)) != 0 { parts.append("⌘") } // Command
        return parts.joined()
    }

    private static func formatKey(ascii: Int, keyCode: Int) -> String {
        switch keyCode {
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36: return "Return"
        case 53: return "Esc"
        default:
            if ascii > 32 && ascii < 127, let scalar = UnicodeScalar(ascii) {
                return String(Character(scalar)).uppercased()
            }
            return "KeyCode(\(keyCode))"
        }
    }
}

/// 修飾キーリマップの 1 ペア（元キー → 変更先キー）。
public struct ModifierKeyPair: Codable, Equatable, Hashable, Sendable {
    public let src: UInt64
    public let dst: UInt64

    public init(src: UInt64, dst: UInt64) {
        self.src = src
        self.dst = dst
    }

    /// 画面表示用の日本語ラベル（例: `Caps Lock → 左 Control`）。
    public var displayString: String {
        "\(Self.keyName(for: src)) → \(Self.keyName(for: dst))"
    }

    /// HID Usage ID をわかりやすい修飾キー名へ変換する。
    public static func keyName(for usage: UInt64) -> String {
        switch usage {
        case 0x700000039: return "Caps Lock"
        case 0x7000000E0: return "左 Control"
        case 0x7000000E4: return "右 Control"
        case 0x7000000E2: return "左 Option"
        case 0x7000000E6: return "右 Option"
        case 0x7000000E3: return "左 Command"
        case 0x7000000E7: return "右 Command"
        case 0x7000000E1: return "左 Shift"
        case 0x7000000E5: return "右 Shift"
        case 0x700000029: return "Escape"
        case 0xFF00000003, 0x100000003: return "Fn / Globe"
        case 0x700000000, 0x300000000: return "アクションなし"
        default:
            return String(format: "0x%llX", usage)
        }
    }
}

/// キーボードごとの修飾キーリマップ設定と IOKit メタデータ。
public struct ModifierMappingEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let vendorID: Int
    public let productID: Int
    public let deviceName: String
    public let isBuiltIn: Bool
    public let mappings: [ModifierKeyPair]

    public var id: String { "\(vendorID)-\(productID)" }

    /// `ByHost/.GlobalPreferences` 内で使われる標準キー名。
    public var preferenceKey: String {
        "com.apple.keyboard.modifiermapping.\(vendorID)-\(productID)-0"
    }

    public init(
        vendorID: Int,
        productID: Int,
        deviceName: String,
        isBuiltIn: Bool,
        mappings: [ModifierKeyPair]
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.deviceName = deviceName
        self.isBuiltIn = isBuiltIn
        self.mappings = mappings
    }

    /// 画面表示用のリマップ一覧文字列。
    public var mappingsDisplayString: String {
        if mappings.isEmpty {
            return "リマップなし（標準）"
        }
        return mappings.map(\.displayString).joined(separator: ", ")
    }
}

/// `IOHIDManager` から検出される現在接続中のキーボード情報。
public struct ConnectedKeyboard: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let vendorID: Int
    public let productID: Int
    public let deviceName: String
    public let isBuiltIn: Bool

    public var id: String { "\(vendorID)-\(productID)" }

    public var preferenceKey: String {
        "com.apple.keyboard.modifiermapping.\(vendorID)-\(productID)-0"
    }

    public init(vendorID: Int, productID: Int, deviceName: String, isBuiltIn: Bool) {
        self.vendorID = vendorID
        self.productID = productID
        self.deviceName = deviceName
        self.isBuiltIn = isBuiltIn
    }
}

/// PrefSnap がエクスポート／インポート／バックアップで使用するルート JSON モデル。
public struct PrefSnapSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: String
    public let sourceHost: SourceHostMetadata
    /// システム基本設定（未設定項目は `null` として出力）
    public let systemDefaults: [String: NullableValue<DefaultsValue>]
    /// メニューバーコントロール設定（未設定項目は `null` として出力）
    public let menuBar: [String: NullableValue<DefaultsValue>]
    /// システム標準ショートカット設定（未設定項目は `null` として出力）
    public let symbolicHotKeys: [String: NullableValue<SymbolicHotKeyEntry>]
    /// アプリケーションショートカット（キー: ドメイン名または `"NSGlobalDomain"`、値: メニュー項目名 → ショートカット文字列）
    public let appShortcuts: [String: [String: String]]
    /// 修飾キーリマップ一覧（`vendorID`, `productID` 昇順で決定論的にソート）
    public let modifierMappings: [ModifierMappingEntry]

    public init(
        schemaVersion: Int = PrefSnapSnapshot.currentSchemaVersion,
        exportedAt: String,
        sourceHost: SourceHostMetadata,
        systemDefaults: [String: NullableValue<DefaultsValue>],
        menuBar: [String: NullableValue<DefaultsValue>],
        symbolicHotKeys: [String: NullableValue<SymbolicHotKeyEntry>],
        appShortcuts: [String: [String: String]],
        modifierMappings: [ModifierMappingEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.sourceHost = sourceHost
        self.systemDefaults = systemDefaults
        self.menuBar = menuBar
        self.symbolicHotKeys = symbolicHotKeys
        self.appShortcuts = appShortcuts
        self.modifierMappings = modifierMappings.sorted { lhs, rhs in
            if lhs.vendorID != rhs.vendorID {
                return lhs.vendorID < rhs.vendorID
            }
            return lhs.productID < rhs.productID
        }
    }
}
