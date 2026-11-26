import Foundation

/// macOS 26+ のコントロールセンター配置データ（`SettingSubcategory.controlCenterLayout`）に対し、
/// 差分比較時のみ適用する意味的正規化（セマンティック等価判定）を行うユーティリティ。
///
/// 保存・適用対象のデータ自体には一切手を加えず、外側の UTF-8 JSON および内包される
/// バイナリ plist（`bplist00`）を再帰的に正規化表現へ変換して等価性を判定する。
internal enum ControlCenterLayoutNormalizer {
    /// 並び順に意味のない集合として扱い、正規化後に安定ソートして比較する配列キー一覧。
    private static let unorderedArrayKeys: Set<String> = [
        "allLocations",
        "occupiedLocations",
        "unoccupiedLocations",
        "elements",
        "instanceIds",
        "modules",
        "chronoControls"
    ]

    /// バイナリ plist（`bplist00`）の先頭マジックバイト（8 バイト）。
    private static let binaryPlistHeader = Data("bplist00".utf8)

    /// `bplist00` の先頭 60 ビットに対応する Base64 プレフィックス（10 文字）。
    /// 9 バイト目の値に依存せず、すべての有効な `bplist00` Base64 文字列はこの 10 文字で始まる。
    private static let binaryPlistBase64Prefix = "YnBsaXN0MD"

    /// 無限再帰や極端に深いネスト構造によるスタックオーバーフローを防ぐための展開上限。
    private static let maxRecursionDepth = 64

    /// 正規化処理の失敗理由を表す内部エラー。
    private enum NormalizationError: Error {
        /// Base64 化された `bplist00` 文字列のデコードに失敗した
        case invalidBase64Plist
        /// `bplist00` バイナリ plist のパースに失敗した
        case invalidBinaryPlist
        /// 正規化対象外の未対応オブジェクト型が検出された
        case unsupportedObjectType
        /// 再帰展開の深さが上限を超過した
        case recursionDepthExceeded
    }

    /// 辞書の 1 エントリをキーと値の組として保持する正規化用構造体。
    internal struct CanonicalEntry: Equatable, Comparable, Sendable {
        /// 辞書のキー名。
        let key: String
        /// 正規化済みの値。
        let value: CanonicalValue

        /// 2 つの辞書エントリをキー昇順・値昇順で比較する。
        /// - Parameters:
        ///   - lhs: 左辺のエントリ
        ///   - rhs: 右辺のエントリ
        /// - Returns: `lhs` が `rhs` より小さい場合は `true`
        static func < (lhs: CanonicalEntry, rhs: CanonicalEntry) -> Bool {
            if lhs.key != rhs.key {
                return lhs.key < rhs.key
            }
            return lhs.value < rhs.value
        }
    }

    /// JSON およびバイナリ plist を決定的・再帰的に比較するための正規化値表現。
    internal indirect enum CanonicalValue: Equatable, Comparable, Sendable {
        case null
        case bool(Bool)
        case int(Int64)
        case uint(UInt64)
        case double(Double)
        case date(Double)
        case string(String)
        case data(Data)
        case keyedArchiverUID(UInt64)
        case embeddedPlist(CanonicalValue)
        case array([CanonicalValue])
        case dictionary([CanonicalEntry])

        /// 異なる値型同士を比較する際の固定優先順位。
        private var typeRank: Int {
            switch self {
            case .null: return 0
            case .bool: return 1
            case .int: return 2
            case .uint: return 3
            case .double: return 4
            case .date: return 5
            case .string: return 6
            case .data: return 7
            case .keyedArchiverUID: return 8
            case .embeddedPlist: return 9
            case .array: return 10
            case .dictionary: return 11
            }
        }

        /// 2 つの正規化値が等価であるかを判定する。
        /// - Parameters:
        ///   - lhs: 左辺の正規化値
        ///   - rhs: 右辺の正規化値
        /// - Returns: 意味的に等価であれば `true`
        static func == (lhs: CanonicalValue, rhs: CanonicalValue) -> Bool {
            switch (lhs, rhs) {
            case (.null, .null):
                return true
            case let (.bool(l), .bool(r)):
                return l == r
            case let (.int(l), .int(r)):
                return l == r
            case let (.uint(l), .uint(r)):
                return l == r
            case let (.double(l), .double(r)):
                return ControlCenterLayoutNormalizer.areDoublesEqual(l, r)
            case let (.date(l), .date(r)):
                return ControlCenterLayoutNormalizer.areDoublesEqual(l, r)
            case let (.string(l), .string(r)):
                return l == r
            case let (.data(l), .data(r)):
                return l == r
            case let (.keyedArchiverUID(l), .keyedArchiverUID(r)):
                return l == r
            case let (.embeddedPlist(l), .embeddedPlist(r)):
                return l == r
            case let (.array(l), .array(r)):
                return l == r
            case let (.dictionary(l), .dictionary(r)):
                return l == r
            default:
                return false
            }
        }

        /// 2 つの正規化値を決定的な全順序で比較する（集合配列の安定ソート用）。
        /// - Parameters:
        ///   - lhs: 左辺の正規化値
        ///   - rhs: 右辺の正規化値
        /// - Returns: `lhs` が `rhs` より小さい場合は `true`
        static func < (lhs: CanonicalValue, rhs: CanonicalValue) -> Bool {
            if lhs.typeRank != rhs.typeRank {
                return lhs.typeRank < rhs.typeRank
            }
            switch (lhs, rhs) {
            case (.null, .null):
                return false
            case let (.bool(l), .bool(r)):
                return !l && r
            case let (.int(l), .int(r)):
                return l < r
            case let (.uint(l), .uint(r)):
                return l < r
            case let (.double(l), .double(r)):
                return ControlCenterLayoutNormalizer.isDoubleLess(l, r)
            case let (.date(l), .date(r)):
                return ControlCenterLayoutNormalizer.isDoubleLess(l, r)
            case let (.string(l), .string(r)):
                return l < r
            case let (.data(l), .data(r)):
                return l.lexicographicallyPrecedes(r)
            case let (.keyedArchiverUID(l), .keyedArchiverUID(r)):
                return l < r
            case let (.embeddedPlist(l), .embeddedPlist(r)):
                return l < r
            case let (.array(l), .array(r)):
                return l.lexicographicallyPrecedes(r)
            case let (.dictionary(l), .dictionary(r)):
                return l.lexicographicallyPrecedes(r)
            default:
                return false
            }
        }
    }

    /// 2 つのコントロールセンター配置 `Data` が意味的に等価かどうかを判定する。
    ///
    /// 生バイト列が一致している場合はパースを行わず即座に `true` を返す。
    /// JSON パースや内包 `bplist00` の展開に失敗した場合は例外でクラッシュさせず、
    /// 従来の生バイト列完全一致比較（`lhs == rhs`）へ安全にフォールバックする。
    /// - Parameters:
    ///   - lhs: 比較元の生バイナリデータ（現在設定）
    ///   - rhs: 比較先の生バイナリデータ（インポート対象）
    /// - Returns: 意味的に等価（または生バイト列が一致）であれば `true`
    internal static func areSemanticallyEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        // 生バイト列が完全一致している場合はそのまま差分なしとする
        if lhs == rhs {
            return true
        }

        do {
            let normalizedLHS = try normalize(data: lhs)
            let normalizedRHS = try normalize(data: rhs)
            return normalizedLHS == normalizedRHS
        } catch {
            // 非 JSON データや破損した Base64 / bplist00 などの場合は生バイト比較へフォールバックする
            return lhs == rhs
        }
    }

    /// 外側の UTF-8 JSON データを再帰的に正規化した `CanonicalValue` へ変換する。
    /// - Parameter data: 正規化対象の UTF-8 JSON バイナリデータ
    /// - Returns: 正規化済みの `CanonicalValue`
    internal static func normalize(data: Data) throws -> CanonicalValue {
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        return try normalizeObject(jsonObject, parentKey: nil, depth: 0)
    }

    /// JSON または plist から復元された任意のオブジェクトを再帰的に正規化する。
    /// - Parameters:
    ///   - object: 正規化対象のオブジェクト
    ///   - parentKey: この値が属する親辞書のキー名（順序非依存配列の判定に使用）
    ///   - depth: 現在の再帰ネスト深度
    /// - Returns: 正規化済みの `CanonicalValue`
    private static func normalizeObject(
        _ object: Any,
        parentKey: String?,
        depth: Int
    ) throws -> CanonicalValue {
        guard depth <= maxRecursionDepth else {
            throw NormalizationError.recursionDepthExceeded
        }

        if object is NSNull {
            return .null
        }

        if let data = object as? Data {
            return try normalizeData(data, parentKey: parentKey, depth: depth)
        }

        // NSNumber は真偽値と数値（浮動小数点・整数）を CFBooleanGetTypeID() で厳密に区別する
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let objCType = String(cString: number.objCType)
            if objCType == "f" || objCType == "d" || CFNumberIsFloatType(number) {
                let value = number.doubleValue == 0 ? 0.0 : number.doubleValue
                return .double(value)
            }
            if objCType == "Q" {
                let unsigned = number.uint64Value
                if unsigned > UInt64(Int64.max) {
                    return .uint(unsigned)
                }
                return .int(Int64(unsigned))
            }
            return .int(number.int64Value)
        }

        if let date = object as? Date {
            return .date(date.timeIntervalSinceReferenceDate)
        }

        if let string = object as? String {
            return try normalizeString(string, parentKey: parentKey, depth: depth)
        }

        if let array = object as? [Any] {
            var normalizedElements = try array.map { element in
                try normalizeObject(element, parentKey: nil, depth: depth + 1)
            }
            // 順序に意味のない特定キー配下の配列のみ安定ソートして順序差異を吸収する
            if let parentKey, unorderedArrayKeys.contains(parentKey) {
                normalizedElements.sort()
            }
            return .array(normalizedElements)
        }

        if let dict = object as? [String: Any] {
            let sortedKeys = dict.keys.sorted()
            var entries: [CanonicalEntry] = []
            entries.reserveCapacity(sortedKeys.count)
            for key in sortedKeys {
                if let rawValue = dict[key] {
                    let normalizedValue = try normalizeObject(rawValue, parentKey: key, depth: depth + 1)
                    entries.append(CanonicalEntry(key: key, value: normalizedValue))
                }
            }
            return .dictionary(entries)
        }

        if let uid = extractKeyedArchiverUID(from: object) {
            return .keyedArchiverUID(uid)
        }

        throw NormalizationError.unsupportedObjectType
    }

    /// 文字列値を正規化する。Base64 デコード結果が `bplist00` で始まる場合は再帰展開する。
    /// - Parameters:
    ///   - string: 正規化対象の文字列
    ///   - parentKey: この文字列が属する親辞書のキー名
    ///   - depth: 現在の再帰ネスト深度
    /// - Returns: 正規化済みの `CanonicalValue`
    private static func normalizeString(
        _ string: String,
        parentKey: String?,
        depth: Int
    ) throws -> CanonicalValue {
        guard string.count >= binaryPlistBase64Prefix.count else {
            return .string(string)
        }

        let compact = string.filter { !$0.isWhitespace && !$0.isNewline }
        guard compact.hasPrefix(binaryPlistBase64Prefix) else {
            return .string(string)
        }

        // `bplist00` の Base64 プレフィックスに一致する文字列がデコード不能な場合は破損とみなしフォールバックさせる
        guard let decoded = Data(base64Encoded: compact) else {
            throw NormalizationError.invalidBase64Plist
        }

        guard decoded.starts(with: binaryPlistHeader) else {
            return .string(string)
        }

        return try unpackBinaryPlist(decoded, parentKey: parentKey, depth: depth)
    }

    /// 展開後 plist 内に含まれる `Data` 値を正規化する。先頭が `bplist00` の場合は再帰展開する。
    /// - Parameters:
    ///   - data: 正規化対象のバイナリデータ
    ///   - parentKey: このデータが属する親辞書のキー名
    ///   - depth: 現在の再帰ネスト深度
    /// - Returns: 正規化済みの `CanonicalValue`
    private static func normalizeData(
        _ data: Data,
        parentKey: String?,
        depth: Int
    ) throws -> CanonicalValue {
        guard data.starts(with: binaryPlistHeader) else {
            return .data(data)
        }
        return try unpackBinaryPlist(data, parentKey: parentKey, depth: depth)
    }

    /// `bplist00` バイナリ plist を `PropertyListSerialization` で展開して再帰正規化する。
    /// - Parameters:
    ///   - data: `bplist00` 形式のバイナリデータ
    ///   - parentKey: このバイナリ plist が属する親辞書のキー名
    ///   - depth: 現在の再帰ネスト深度
    /// - Returns: 展開・正規化済みの `.embeddedPlist` 値
    private static func unpackBinaryPlist(
        _ data: Data,
        parentKey: String?,
        depth: Int
    ) throws -> CanonicalValue {
        let plistObject: Any
        var format: PropertyListSerialization.PropertyListFormat = .binary
        do {
            plistObject = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            )
        } catch {
            throw NormalizationError.invalidBinaryPlist
        }
        // 破損した bplist00 が OpenStep ASCII plist として誤解釈されるのを防ぐためバイナリ形式を必須とする
        guard format == .binary else {
            throw NormalizationError.invalidBinaryPlist
        }

        // ネストされた bplist00 のルート自体が `modules` や `chronoControls` の配列であるケースも考慮し parentKey を引き継ぐ
        let normalized = try normalizeObject(plistObject, parentKey: parentKey, depth: depth + 1)
        return .embeddedPlist(normalized)
    }

    /// `PropertyListSerialization` が返す `CFKeyedArchiverUID` オブジェクトから数値 ID を抽出する。
    /// - Parameter object: 判定対象のオブジェクト
    /// - Returns: `CFKeyedArchiverUID` であればその数値 ID、それ以外は `nil`
    private static func extractKeyedArchiverUID(from object: Any) -> UInt64? {
        let cfObject = object as AnyObject
        guard let typeDescription = CFCopyTypeIDDescription(CFGetTypeID(cfObject)) as String?,
              typeDescription == "CFKeyedArchiverUID"
        else {
            return nil
        }

        guard let xmlData = try? PropertyListSerialization.data(
            fromPropertyList: [cfObject],
            format: .xml,
            options: 0
        ),
              let xmlString = String(data: xmlData, encoding: .utf8),
              let startRange = xmlString.range(of: "<integer>"),
              let endRange = xmlString.range(of: "</integer>", range: startRange.upperBound..<xmlString.endIndex)
        else {
            return nil
        }

        let numberText = xmlString[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt64(numberText)
    }

    /// 2 つの浮動小数点数を `NaN` を含めて等価判定する。
    /// - Parameters:
    ///   - lhs: 左辺の浮動小数点数
    ///   - rhs: 右辺の浮動小数点数
    /// - Returns: 等価であれば `true`
    private static func areDoublesEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        if lhs.isNaN && rhs.isNaN {
            return true
        }
        return lhs == rhs
    }

    /// 2 つの浮動小数点数を `NaN` を含めて決定的な全順序で比較する。
    /// - Parameters:
    ///   - lhs: 左辺の浮動小数点数
    ///   - rhs: 右辺の浮動小数点数
    /// - Returns: `lhs` が `rhs` より小さい場合は `true`
    private static func isDoubleLess(_ lhs: Double, _ rhs: Double) -> Bool {
        if lhs.isNaN && rhs.isNaN {
            return false
        }
        if lhs.isNaN {
            return false
        }
        if rhs.isNaN {
            return true
        }
        return lhs < rhs
    }
}
