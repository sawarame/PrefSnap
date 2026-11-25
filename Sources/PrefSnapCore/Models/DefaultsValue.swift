import Foundation

/// macOS の `defaults` および plist で扱う設定値を型安全に表現する列挙型。
public enum DefaultsValue: Equatable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(Data)
    case array([DefaultsValue])
    case dictionary([String: DefaultsValue])

    /// 画面の Before → After 表示に使う人間向けの文字列表現。
    public var displayString: String {
        switch self {
        case let .bool(value):
            return value ? "オン (true)" : "オフ (false)"
        case let .int(value):
            return String(value)
        case let .double(value):
            if value.rounded() == value {
                return String(format: "%.1f", value)
            }
            return String(value)
        case let .string(value):
            return value
        case let .data(data):
            return "データ (\(data.count) bytes)"
        case let .array(values):
            return "[" + values.map(\.displayString).joined(separator: ", ") + "]"
        case let .dictionary(dict):
            let pairs = dict.keys.sorted().map { key in
                "\(key): \(dict[key]?.displayString ?? "")"
            }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }

    /// カタログで定義された期待型に合わせて数値を正規化する。
    /// JSON では `3.0` が整数 `3` として出力・デコードされるため、`.double` 項目で
    /// `.int(3)` と `.double(3.0)` が別値扱いされないよう型を揃える。
    public func normalized(for valueType: SettingValueType) -> DefaultsValue {
        switch (valueType, self) {
        case let (.double, .int(intVal)):
            return .double(Double(intVal))
        case let (.int, .double(doubleVal)):
            if doubleVal.isFinite, doubleVal.rounded() == doubleVal,
               doubleVal >= Double(Int.min), doubleVal <= Double(Int.max) {
                return .int(Int(doubleVal))
            }
            return self
        default:
            return self
        }
    }

    /// `defaults write` コマンドに渡す型フラグと引数配列を生成する。
    public func defaultsWriteArguments() -> [String] {
        switch self {
        case let .bool(value):
            return ["-bool", value ? "TRUE" : "FALSE"]
        case let .int(value):
            return ["-int", String(value)]
        case let .double(value):
            return ["-float", String(value)]
        case let .string(value):
            return ["-string", value]
        case let .data(data):
            let hex = data.map { String(format: "%02x", $0) }.joined()
            return ["-data", hex]
        case let .array(values):
            return ["-array"] + values.map(\.rawStringForDefaults)
        case let .dictionary(dict):
            var args = ["-dict"]
            for key in dict.keys.sorted() {
                if let val = dict[key] {
                    args.append(key)
                    args.append(val.rawStringForDefaults)
                }
            }
            return args
        }
    }

    private var rawStringForDefaults: String {
        switch self {
        case let .bool(value): return value ? "TRUE" : "FALSE"
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .string(value): return value
        case let .data(data): return data.base64EncodedString()
        case .array, .dictionary: return displayString
        }
    }

    /// plist（`PropertyListSerialization` 互換の `Any`）へ変換する。
    public func toPropertyListObject() -> Any {
        switch self {
        case let .bool(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .string(value):
            return value
        case let .data(data):
            return data
        case let .array(values):
            return values.map { $0.toPropertyListObject() }
        case let .dictionary(dict):
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = v.toPropertyListObject()
            }
            return result
        }
    }

    /// plist（`Any`）から `DefaultsValue` を生成する。
    /// `NSNumber` の真偽値と整数・小数を `CFBooleanGetTypeID()` で厳密に判別する。
    public static func fromPropertyListObject(_ object: Any, expectedType: SettingValueType? = nil) -> DefaultsValue? {
        if let data = object as? Data {
            return .data(data)
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let expectedType {
                switch expectedType {
                case .bool:
                    return .bool(number.intValue != 0)
                case .int:
                    return .int(number.intValue)
                case .double:
                    return .double(number.doubleValue)
                case .string:
                    return .string(number.stringValue)
                case .data:
                    return nil
                }
            }
            let objCType = String(cString: number.objCType)
            if objCType == "f" || objCType == "d" {
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        }
        if let string = object as? String {
            if expectedType == .bool {
                let lower = string.lowercased()
                if lower == "1" || lower == "true" || lower == "yes" { return .bool(true) }
                if lower == "0" || lower == "false" || lower == "no" { return .bool(false) }
            }
            if expectedType == .int, let intVal = Int(string) {
                return .int(intVal)
            }
            if expectedType == .double, let doubleVal = Double(string) {
                return .double(doubleVal)
            }
            return .string(string)
        }
        if let array = object as? [Any] {
            return .array(array.compactMap { fromPropertyListObject($0) })
        }
        if let dict = object as? [String: Any] {
            var converted: [String: DefaultsValue] = [:]
            for (key, value) in dict {
                if let parsed = fromPropertyListObject(value) {
                    converted[key] = parsed
                }
            }
            return .dictionary(converted)
        }
        return nil
    }
}

/// `DefaultsValue.data` を JSON 内で安全かつ可読性高く表現するための内部エンベロープ。
/// UTF-8 として往復完全一致するデータは `utf8` 文字列のまま保持し、それ以外のバイナリは `base64` で保持する。
private struct EncodedDataPayload: Codable {
    let __type: String
    let encoding: String
    let value: String
}

extension DefaultsValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool を Int より先に判定し、JSON の true/false が整数 1/0 として解釈されるのを防ぐ
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let arrayVal = try? container.decode([DefaultsValue].self) {
            self = .array(arrayVal)
        } else if let payload = try? container.decode(EncodedDataPayload.self), payload.__type == "data" {
            switch payload.encoding {
            case "utf8":
                self = .data(Data(payload.value.utf8))
            case "base64":
                guard let decoded = Data(base64Encoded: payload.value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Base64 データのデコードに失敗しました"
                    )
                }
                self = .data(decoded)
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "未対応のデータエンコーディングです: \(payload.encoding)"
                )
            }
        } else if let dictVal = try? container.decode([String: DefaultsValue].self) {
            self = .dictionary(dictVal)
        } else {
            throw DecodingError.typeMismatch(
                DefaultsValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "未対応の JSON 値型です"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .data(data):
            if let utf8 = String(data: data, encoding: .utf8), Data(utf8.utf8) == data {
                try container.encode(EncodedDataPayload(__type: "data", encoding: "utf8", value: utf8))
            } else {
                try container.encode(EncodedDataPayload(__type: "data", encoding: "base64", value: data.base64EncodedString()))
            }
        case let .array(values):
            try container.encode(values)
        case let .dictionary(dict):
            try container.encode(dict)
        }
    }
}

/// JSON エンコード時に `nil` を省略せず、明示的に `null` として出力するためのラッパー型。
/// Git での差分管理において「未設定（初期値）」を明確に表現するために使用する。
public struct NullableValue<Wrapped: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Wrapped?

    public init(_ value: Wrapped?) {
        self.value = value
    }

    public static var unset: NullableValue<Wrapped> {
        NullableValue(nil)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else {
            self.value = try container.decode(Wrapped.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}
