import Foundation

/// SemVer 2.0.0 に準拠したセマンティックバージョンを表現・比較する値型。
/// 先頭の `v` / `V` プレフィックスを許容し、ビルドメタデータ（`+...`）は解析検証しつつ大小比較では無視する。
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// メジャーバージョン番号。
    public let major: Int
    /// マイナーバージョン番号。
    public let minor: Int
    /// パッチバージョン番号。
    public let patch: Int
    /// プレリリース識別子の配列（通常リリース時は空）。
    public let prereleaseIdentifiers: [String]
    /// ビルドメタデータ識別子の配列（比較・等価判定では無視する）。
    public let buildMetadataIdentifiers: [String]

    /// プレリリース版かどうかを返す。
    public var isPrerelease: Bool {
        !prereleaseIdentifiers.isEmpty
    }

    /// ビルドメタデータおよび先頭 `v` を除いた正規化バージョン文字列（例: `0.1.5`、`0.2.0-beta.1`）。
    public var normalized: String {
        let core = "\(major).\(minor).\(patch)"
        if prereleaseIdentifiers.isEmpty {
            return core
        }
        return "\(core)-\(prereleaseIdentifiers.joined(separator: "."))"
    }

    /// 表示用のバージョン文字列（`normalized` と同一）。
    public var description: String {
        normalized
    }

    /// 構成要素を指定してセマンティックバージョンを直接生成する。
    /// - Parameters:
    ///   - major: メジャーバージョン番号（0 以上）
    ///   - minor: マイナーバージョン番号（0 以上）
    ///   - patch: パッチバージョン番号（0 以上）
    ///   - prereleaseIdentifiers: プレリリース識別子配列
    ///   - buildMetadataIdentifiers: ビルドメタデータ識別子配列
    public init(
        major: Int,
        minor: Int,
        patch: Int,
        prereleaseIdentifiers: [String] = [],
        buildMetadataIdentifiers: [String] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadataIdentifiers = buildMetadataIdentifiers
    }

    /// バージョン文字列（例: `0.1.4`, `v0.1.4`, `V1.2.3-beta.1+build.42`）を SemVer 2.0.0 として厳密に解析する。
    /// - Parameter rawValue: 解析対象のバージョン文字列
    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 先頭 1 文字の `v` または `V` を許容する
        var body = trimmed[...]
        if let first = body.first, first == "v" || first == "V" {
            body = body.dropFirst()
        }
        guard !body.isEmpty else { return nil }

        // ビルドメタデータ（`+` 以降）を分離して検証する
        let buildMetadata: [String]
        let withoutBuild: Substring
        if let plusIndex = body.firstIndex(of: "+") {
            withoutBuild = body[..<plusIndex]
            let buildPart = body[body.index(after: plusIndex)...]
            guard let parsedBuild = Self.parseBuildMetadataIdentifiers(buildPart) else {
                return nil
            }
            buildMetadata = parsedBuild
        } else {
            withoutBuild = body
            buildMetadata = []
        }

        // プレリリース識別子（最初の `-` 以降）を分離して検証する
        let prerelease: [String]
        let corePart: Substring
        if let hyphenIndex = withoutBuild.firstIndex(of: "-") {
            corePart = withoutBuild[..<hyphenIndex]
            let prePart = withoutBuild[withoutBuild.index(after: hyphenIndex)...]
            guard let parsedPre = Self.parsePrereleaseIdentifiers(prePart) else {
                return nil
            }
            prerelease = parsedPre
        } else {
            corePart = withoutBuild
            prerelease = []
        }

        // コアバージョン（MAJOR.MINOR.PATCH）の 3 要素を検証する
        let coreComponents = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard coreComponents.count == 3,
              let major = Self.parseNumericIdentifier(coreComponents[0]),
              let minor = Self.parseNumericIdentifier(coreComponents[1]),
              let patch = Self.parseNumericIdentifier(coreComponents[2]) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prerelease
        self.buildMetadataIdentifiers = buildMetadata
    }

    /// 2 つのバージョンが SemVer 2.0.0 の優先順位上等しいかを判定する（ビルドメタデータは無視）。
    /// - Parameters:
    ///   - lhs: 左辺のバージョン
    ///   - rhs: 右辺のバージョン
    /// - Returns: 等価であれば `true`
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major
            && lhs.minor == rhs.minor
            && lhs.patch == rhs.patch
            && lhs.prereleaseIdentifiers == rhs.prereleaseIdentifiers
    }

    /// ビルドメタデータを除いたバージョン要素をハッシュ化する。
    /// - Parameter hasher: ハッシャー
    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prereleaseIdentifiers)
    }

    /// SemVer 2.0.0 §11 に基づきバージョンの大小を比較する（ビルドメタデータは無視）。
    /// - Parameters:
    ///   - lhs: 左辺のバージョン
    ///   - rhs: 右辺のバージョン
    /// - Returns: `lhs` が `rhs` より古い場合は `true`
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // プレリリース識別子を持たない通常版の方が、持つプレリリース版より新しい
        switch (lhs.prereleaseIdentifiers.isEmpty, rhs.prereleaseIdentifiers.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            break
        }

        let commonCount = min(lhs.prereleaseIdentifiers.count, rhs.prereleaseIdentifiers.count)
        for index in 0..<commonCount {
            let leftID = lhs.prereleaseIdentifiers[index]
            let rightID = rhs.prereleaseIdentifiers[index]
            if leftID == rightID { continue }

            let leftIsNumeric = Self.isAllASCIIDigits(leftID)
            let rightIsNumeric = Self.isAllASCIIDigits(rightID)

            switch (leftIsNumeric, rightIsNumeric) {
            case (true, true):
                // 数値識別子同士は数値として比較する（桁数超過を避けるため桁数→辞書順で比較）
                if leftID.count != rightID.count {
                    return leftID.count < rightID.count
                }
                return leftID < rightID
            case (true, false):
                // 数値識別子は英数字識別子より常に小さい
                return true
            case (false, true):
                return false
            case (false, false):
                // 英数字識別子同士は ASCII コード順で比較する
                return leftID.utf8.lexicographicallyPrecedes(rightID.utf8)
            }
        }

        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }

    /// 非負整数識別子を解析する（`0` 以外の先行ゼロを禁止）。
    /// - Parameter token: 検証対象のサブストリング
    /// - Returns: 有効な非負整数。不正な場合は `nil`
    private static func parseNumericIdentifier(_ token: Substring) -> Int? {
        guard !token.isEmpty, isAllASCIIDigits(token) else { return nil }
        if token.count > 1, token.first == "0" {
            return nil
        }
        return Int(token)
    }

    /// プレリリース部をドット区切りで解析・検証する。
    /// - Parameter raw: `-` より後ろのサブストリング
    /// - Returns: 検証済み識別子配列。不正な場合は `nil`
    private static func parsePrereleaseIdentifiers(_ raw: Substring) -> [String]? {
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        var result: [String] = []
        result.reserveCapacity(parts.count)

        for part in parts {
            guard !part.isEmpty, isValidSemVerIdentifierCharacters(part) else {
                return nil
            }
            // 数値のみのプレリリース識別子は先行ゼロを禁止する
            if isAllASCIIDigits(part), part.count > 1, part.first == "0" {
                return nil
            }
            result.append(String(part))
        }
        return result
    }

    /// ビルドメタデータ部をドット区切りで解析・検証する。
    /// - Parameter raw: `+` より後ろのサブストリング
    /// - Returns: 検証済み識別子配列。不正な場合は `nil`
    private static func parseBuildMetadataIdentifiers(_ raw: Substring) -> [String]? {
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        var result: [String] = []
        result.reserveCapacity(parts.count)

        for part in parts {
            guard !part.isEmpty, isValidSemVerIdentifierCharacters(part) else {
                return nil
            }
            result.append(String(part))
        }
        return result
    }

    /// 文字列が ASCII 数字 `[0-9]` のみで構成されているかを判定する。
    /// - Parameter value: 判定対象の文字列
    /// - Returns: すべて ASCII 数字であれば `true`
    private static func isAllASCIIDigits<S: StringProtocol>(_ value: S) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    /// 文字列が SemVer 識別子として許容される `[0-9A-Za-z-]` のみで構成されているかを判定する。
    /// - Parameter value: 判定対象の文字列
    /// - Returns: すべて許容文字であれば `true`
    private static func isValidSemVerIdentifierCharacters<S: StringProtocol>(_ value: S) -> Bool {
        value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) // 0-9
                || (byte >= 65 && byte <= 90) // A-Z
                || (byte >= 97 && byte <= 122) // a-z
                || byte == 45 // -
        }
    }
}
