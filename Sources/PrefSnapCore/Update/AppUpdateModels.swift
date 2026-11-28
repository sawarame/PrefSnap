import Foundation

/// 実行中アプリケーションの識別情報および配布先リポジトリ定数を保持するモデル。
public struct AppIdentity: Equatable, Sendable {
    /// 配布版アプリの正規表示名。
    public static let releaseAppName = "PrefSnap"
    /// 配布版アプリの正規 Bundle Identifier。
    public static let releaseBundleIdentifier = "dev.prefsnap.PrefSnap"
    /// ローカル開発版アプリのフォールバック表示名。
    public static let developmentAppName = "PrefSnap_dev"
    /// ローカル開発版アプリのフォールバック Bundle Identifier。
    public static let developmentBundleIdentifier = "dev.prefsnap.PrefSnap.dev"
    /// GitHub リポジトリオーナー名。
    public static let githubOwner = "sawarame"
    /// GitHub リポジトリ名。
    public static let githubRepo = "PrefSnap"
    /// GitHub Releases 一覧ページのフォールバック URL。
    public static let releasesPageURL = URL(string: "https://github.com/sawarame/PrefSnap/releases")!
    /// 最新リリース取得用 GitHub Releases API エンドポイント。
    public static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/sawarame/PrefSnap/releases/latest")!

    /// アプリの表示名（`CFBundleDisplayName` / `CFBundleName`）。
    public let displayName: String
    /// アプリの Bundle Identifier（`CFBundleIdentifier`）。
    public let bundleIdentifier: String
    /// アプリバンドルの URL。
    public let bundleURL: URL

    /// `.app` バンドルとして実行されているかどうかを返す。
    public var isAppBundle: Bool {
        bundleURL.pathExtension.lowercased() == "app"
    }

    /// ローカル開発版として扱うべきかどうかを判定する。
    /// `PrefSnap_dev`、Bundle ID が `dev.prefsnap.PrefSnap.dev` または `.dev` 接尾辞、あるいは未バンドル実行時は開発版とみなす。
    public var isDevelopmentBuild: Bool {
        if displayName == Self.developmentAppName {
            return true
        }
        if bundleIdentifier == Self.developmentBundleIdentifier || bundleIdentifier.hasSuffix(".dev") {
            return true
        }
        return !isAppBundle
    }

    /// アプリ識別情報を初期化する。
    /// - Parameters:
    ///   - displayName: アプリの表示名
    ///   - bundleIdentifier: Bundle Identifier
    ///   - bundleURL: アプリバンドルの URL
    public init(displayName: String, bundleIdentifier: String, bundleURL: URL) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
    }

    /// `Bundle` の `infoDictionary` および `bundleURL` から現在のアプリ識別情報を解決する。
    /// 未バンドル実行時は開発版フォールバック値（`PrefSnap_dev` / `dev.prefsnap.PrefSnap.dev`）を返す。
    /// - Parameter bundle: 参照元のバンドル（既定値は `Bundle.main`）
    /// - Returns: 解決された `AppIdentity`
    public static func current(bundle: Bundle = .main) -> AppIdentity {
        resolve(infoDictionary: bundle.infoDictionary, bundleURL: bundle.bundleURL)
    }

    /// `infoDictionary` と `bundleURL` からアプリ識別情報を解決する純粋ヘルパー。
    /// - Parameters:
    ///   - infoDictionary: `Info.plist` の辞書（存在しない場合は `nil`）
    ///   - bundleURL: バンドル URL
    /// - Returns: 解決された `AppIdentity`
    public static func resolve(infoDictionary: [String: Any]?, bundleURL: URL) -> AppIdentity {
        let isApp = bundleURL.pathExtension.lowercased() == "app"
        let rawDisplayName = (infoDictionary?["CFBundleDisplayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBundleName = (infoDictionary?["CFBundleName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBundleID = (infoDictionary?["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let displayName: String
        if let rawDisplayName, !rawDisplayName.isEmpty {
            displayName = rawDisplayName
        } else if let rawBundleName, !rawBundleName.isEmpty {
            displayName = rawBundleName
        } else {
            displayName = isApp ? releaseAppName : developmentAppName
        }

        let bundleIdentifier: String
        if let rawBundleID, !rawBundleID.isEmpty {
            bundleIdentifier = rawBundleID
        } else {
            bundleIdentifier = isApp ? releaseBundleIdentifier : developmentBundleIdentifier
        }

        return AppIdentity(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL
        )
    }
}

/// 実行中アプリケーションのバージョン情報を保持するモデル。
public struct AppVersionInfo: Equatable, Sendable {
    /// マーケティングバージョン文字列（`CFBundleShortVersionString`、未設定時は `"dev"`）。
    public let shortVersionString: String
    /// ビルド番号（`CFBundleVersion`、未設定または空時は `nil`）。
    public let buildNumber: String?
    /// `shortVersionString` を SemVer 2.0.0 として解析した結果。
    public let semanticVersion: SemanticVersion?

    /// `User-Agent` ヘッダ等に付与するバージョン表記。
    public var userAgentVersion: String {
        semanticVersion?.normalized ?? shortVersionString
    }

    /// 設定画面等で表示する日本語バージョン表記（例: `バージョン 0.1.4 (ビルド 12)`）。
    public var displayText: String {
        if let buildNumber, !buildNumber.isEmpty {
            return "バージョン \(shortVersionString) (ビルド \(buildNumber))"
        }
        return "バージョン \(shortVersionString)"
    }

    /// アプリバージョン情報を初期化する。
    /// - Parameters:
    ///   - shortVersionString: `CFBundleShortVersionString` 相当の文字列
    ///   - buildNumber: `CFBundleVersion` 相当の文字列（任意）
    public init(shortVersionString: String, buildNumber: String? = nil) {
        let trimmedShort = shortVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedShort = trimmedShort.isEmpty ? "dev" : trimmedShort
        let trimmedBuild = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.shortVersionString = resolvedShort
        self.buildNumber = (trimmedBuild?.isEmpty == false) ? trimmedBuild : nil
        self.semanticVersion = SemanticVersion(resolvedShort)
    }

    /// `Bundle` の `infoDictionary` から現在のバージョン情報を解決する。
    /// - Parameter bundle: 参照元のバンドル（既定値は `Bundle.main`）
    /// - Returns: 解決された `AppVersionInfo`
    public static func current(bundle: Bundle = .main) -> AppVersionInfo {
        resolve(infoDictionary: bundle.infoDictionary)
    }

    /// `infoDictionary` からバージョン情報を解決する純粋ヘルパー。
    /// - Parameter infoDictionary: `Info.plist` の辞書
    /// - Returns: 解決された `AppVersionInfo`
    public static func resolve(infoDictionary: [String: Any]?) -> AppVersionInfo {
        let shortVersion = (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let buildNumber = infoDictionary?["CFBundleVersion"] as? String
        return AppVersionInfo(shortVersionString: shortVersion, buildNumber: buildNumber)
    }
}

/// GitHub Releases から取得した安定版リリースの情報。
public struct UpdateRelease: Equatable, Sendable {
    /// リリースタグ名（例: `v0.1.5`）。
    public let tagName: String
    /// 解析済みセマンティックバージョン。
    public let version: SemanticVersion
    /// リリース表示タイトル。
    public let title: String
    /// リリースノート本文。
    public let releaseNotes: String
    /// 検証済み GitHub リリースページ URL。
    public let htmlURL: URL
    /// 対象配布 ZIP アセット名（例: `PrefSnap-v0.1.5.zip`）。
    public let assetName: String
    /// 検証済み ZIP ダウンロード URL。
    public let assetDownloadURL: URL
    /// GitHub Releases API のアセット `digest` から抽出した SHA-256（小文字 64 桁 hex、未提供時は `nil`）。
    public let assetDigestSHA256: String?
    /// リリース公開日時（取得できた場合）。
    public let publishedAt: Date?

    /// リリース情報を初期化する。
    /// - Parameters:
    ///   - tagName: リリースタグ名
    ///   - version: セマンティックバージョン
    ///   - title: リリースタイトル
    ///   - releaseNotes: リリースノート本文
    ///   - htmlURL: リリースページ URL
    ///   - assetName: 配布 ZIP アセット名
    ///   - assetDownloadURL: ZIP ダウンロード URL
    ///   - assetDigestSHA256: SHA-256 ダイジェスト（任意）
    ///   - publishedAt: 公開日時（任意）
    public init(
        tagName: String,
        version: SemanticVersion,
        title: String,
        releaseNotes: String,
        htmlURL: URL,
        assetName: String,
        assetDownloadURL: URL,
        assetDigestSHA256: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.releaseNotes = releaseNotes
        self.htmlURL = htmlURL
        self.assetName = assetName
        self.assetDownloadURL = assetDownloadURL
        self.assetDigestSHA256 = assetDigestSHA256
        self.publishedAt = publishedAt
    }
}

/// リリースページ URL およびダウンロード／リダイレクト先 URL の安全性を検証するバリデータ。
public enum UpdateURLValidator {
    /// リリースページ URL が `https://github.com/sawarame/PrefSnap/...`（大文字小文字非区別）に適合するか検証し、
    /// 不正な場合は `https://github.com/sawarame/PrefSnap/releases` へフォールバックする。
    /// - Parameter rawURLString: 検証対象の URL 文字列
    /// - Returns: 安全と判定されたリリースページ URL またはフォールバック URL
    public static func sanitizedReleasePageURL(_ rawURLString: String?) -> URL {
        guard let rawURLString = rawURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURLString.isEmpty,
              let url = URL(string: rawURLString),
              isAllowedReleasePageURL(url) else {
            return AppIdentity.releasesPageURL
        }
        return url
    }

    /// 指定された URL が許可された PrefSnap の GitHub リリースページ URL であるかを判定する。
    /// - Parameter url: 判定対象の URL
    /// - Returns: 許可対象であれば `true`
    public static func isAllowedReleasePageURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.host?.lowercased() == "github.com" else {
            return false
        }

        // パストラバーサル（`..`）を拒否し、`/sawarame/PrefSnap` 配下のみを許可する
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return false }
        if segments.contains(where: { $0 == ".." || $0 == "." }) {
            return false
        }

        return segments[0].lowercased() == AppIdentity.githubOwner.lowercased()
            && segments[1].lowercased() == AppIdentity.githubRepo.lowercased()
    }

    /// ダウンロード URL または HTTP リダイレクト先 URL が許可ホスト（`https://github.com` または `https://*.githubusercontent.com`）かを検証する。
    /// - Parameter url: 判定対象の URL
    /// - Returns: 許可対象であれば `true`
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return false
        }

        if rawHost == "github.com" {
            return true
        }

        let suffix = ".githubusercontent.com"
        guard rawHost.hasSuffix(suffix) else {
            return false
        }

        // サブドメイン部が有効なホスト名ラベルであることを検証する（空ラベルやドット始端を拒否）
        let subdomainPart = rawHost.dropLast(suffix.count)
        guard !subdomainPart.isEmpty else { return false }
        let labels = subdomainPart.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.first != "-", label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) // 0-9
                    || (byte >= 97 && byte <= 122) // a-z
                    || byte == 45 // -
            }
        }
    }
}

/// GitHub Releases API の JSON レスポンスを解析して安定版リリース情報を抽出するパーサー。
public enum GitHubReleaseParser {
    /// GitHub Releases API のレスポンスデコード用 DTO。
    private struct ReleaseDTO: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let htmlURL: String?
        let publishedAt: String?
        let assets: [AssetDTO]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case draft
            case prerelease
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    /// GitHub Releases API のアセットデコード用 DTO。
    private struct AssetDTO: Decodable {
        let name: String
        let browserDownloadURL: String
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    /// GitHub Releases API（`/releases/latest`）の JSON データから安定版リリースを抽出する。
    /// `draft == true`、`prerelease == true`、または SemVer プレリリース識別子付きタグは除外して `nil` を返す。
    /// - Parameter data: GitHub Releases API のレスポンス JSON データ
    /// - Returns: 安定版リリース情報。ドラフト／プレリリースにより除外された場合は `nil`
    /// - Throws: JSON 構造不正・タグ形式不正・必須 ZIP アセット欠損・URL 不正・ダイジェスト形式不正時に `AppUpdateError`
    public static func parseLatestStableRelease(from data: Data) throws -> UpdateRelease? {
        let dto: ReleaseDTO
        do {
            dto = try JSONDecoder().decode(ReleaseDTO.self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse(detail: "GitHub Releases API の応答を解析できませんでした: \(error.localizedDescription)")
        }

        // ドラフトおよびプレリリースフラグが立っているリリースは除外する
        if dto.draft == true || dto.prerelease == true {
            return nil
        }

        guard let version = SemanticVersion(dto.tagName) else {
            throw AppUpdateError.invalidResponse(detail: "リリースタグがセマンティックバージョニング形式ではありません: \(dto.tagName)")
        }

        // タグ自体に SemVer プレリリース識別子（例: 0.2.0-beta.1）が含まれる場合も除外する
        if version.isPrerelease {
            return nil
        }

        let expectedAssetName = expectedZipAssetName(for: version)
        let assets = dto.assets ?? []
        guard let matchedAsset = assets.first(where: { $0.name == expectedAssetName }) else {
            throw AppUpdateError.missingReleaseAsset(expectedName: expectedAssetName)
        }

        guard let downloadURL = URL(string: matchedAsset.browserDownloadURL),
              UpdateURLValidator.isAllowedDownloadURL(downloadURL) else {
            throw AppUpdateError.untrustedDownloadURL(urlString: matchedAsset.browserDownloadURL)
        }

        let sha256Digest: String?
        if let rawDigest = matchedAsset.digest?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDigest.isEmpty {
            sha256Digest = try parseSHA256Digest(rawDigest)
        } else {
            sha256Digest = nil
        }

        let resolvedTitle: String
        if let rawName = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty {
            resolvedTitle = rawName
        } else {
            resolvedTitle = "\(AppIdentity.releaseAppName) v\(version.normalized)"
        }

        let publishedDate = dto.publishedAt.flatMap { parseISO8601Date($0) }

        return UpdateRelease(
            tagName: dto.tagName,
            version: version,
            title: resolvedTitle,
            releaseNotes: dto.body ?? "",
            htmlURL: UpdateURLValidator.sanitizedReleasePageURL(dto.htmlURL),
            assetName: matchedAsset.name,
            assetDownloadURL: downloadURL,
            assetDigestSHA256: sha256Digest,
            publishedAt: publishedDate
        )
    }

    /// 指定バージョンに対応する期待 ZIP アセット名（`PrefSnap-v<VERSION>.zip`）を返す。
    /// - Parameter version: 対象セマンティックバージョン
    /// - Returns: 期待されるアセットファイル名
    public static func expectedZipAssetName(for version: SemanticVersion) -> String {
        "\(AppIdentity.releaseAppName)-v\(version.normalized).zip"
    }

    /// GitHub Releases API の `digest` 文字列（`sha256:<64桁hex>`）を解析し、小文字 64 桁の 16 進文字列へ正規化する。
    /// - Parameter rawDigest: 解析対象のダイジェスト文字列
    /// - Returns: 正規化された小文字 64 桁の SHA-256 16 進文字列
    /// - Throws: フォーマット不正時に `AppUpdateError.invalidAssetDigest`
    public static func parseSHA256Digest(_ rawDigest: String) throws -> String {
        let trimmed = rawDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "sha256:"
        guard trimmed.lowercased().hasPrefix(prefix) else {
            throw AppUpdateError.invalidAssetDigest(raw: rawDigest)
        }

        let hexPart = String(trimmed.dropFirst(prefix.count)).lowercased()
        let isHex64 = hexPart.count == 64 && hexPart.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) // 0-9
                || (byte >= 97 && byte <= 102) // a-f
        }
        guard isHex64 else {
            throw AppUpdateError.invalidAssetDigest(raw: rawDigest)
        }
        return hexPart
    }

    /// ISO-8601 形式の日時文字列を `Date` へ変換する。
    /// - Parameter raw: 日時文字列
    /// - Returns: 解析できた `Date`（失敗時は `nil`）
    private static func parseISO8601Date(_ raw: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: raw) {
            return date
        }
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: raw)
    }
}

/// アップデート確認の実行トリガー種別。
public enum UpdateCheckTrigger: Equatable, Sendable {
    /// アプリ起動時の自動チェック。
    case automatic
    /// ユーザー操作（設定画面・メニューバー）による手動チェック。
    case manual
}

/// アップデート確認結果に対する判定。
public enum UpdateCheckDecision: Equatable, Sendable {
    /// ローカル開発版のため自動アップデート対象外。
    case developmentBuild
    /// 現在バージョンが最新（または利用可能な安定版が現在以下）。
    case upToDate(currentVersion: SemanticVersion)
    /// ユーザーへ提示すべき新しい安定版リリースが存在する。
    case updateAvailable(release: UpdateRelease)
    /// 新しい安定版リリースはあるが、自動チェックかつスキップ済みバージョンのため通知を抑止する。
    case skipped(release: UpdateRelease)
}

/// 起動時自動チェックの実行可否およびリリース比較・スキップ判定を担うポリシー。
public enum UpdateCheckPolicy {
    /// 起動時自動チェックを実行すべきかを判定する。
    /// 「自動チェック設定が ON」「開発版でない」「現在バージョンが有効な SemVer」のすべてを満たす場合のみ `true`。
    /// - Parameters:
    ///   - autoCheckEnabled: 自動チェック設定の ON/OFF
    ///   - identity: 実行中アプリの識別情報
    ///   - currentVersion: 実行中アプリのバージョン情報
    /// - Returns: 起動時自動チェックを実行すべき場合は `true`
    public static func shouldPerformAutomaticCheck(
        autoCheckEnabled: Bool,
        identity: AppIdentity,
        currentVersion: AppVersionInfo
    ) -> Bool {
        autoCheckEnabled && !identity.isDevelopmentBuild && currentVersion.semanticVersion != nil
    }

    /// 検出されたリリースバージョンがスキップ保存済みバージョンと一致するかを判定する。
    /// - Parameters:
    ///   - version: 検出されたリリースバージョン
    ///   - skippedVersion: ユーザーがスキップ保存したバージョン文字列
    /// - Returns: 一致する場合は `true`
    public static func isSkippedVersion(_ version: SemanticVersion, skippedVersion: String?) -> Bool {
        guard let skippedVersion = skippedVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skippedVersion.isEmpty else {
            return false
        }
        if let parsedSkipped = SemanticVersion(skippedVersion) {
            return parsedSkipped == version
        }
        return skippedVersion == version.normalized
    }

    /// 取得した最新リリースと現在環境から、アップデート通知の判定結果を算出する。
    /// - Parameters:
    ///   - latestRelease: GitHub Releases API から取得した最新安定版（存在しない・除外時は `nil`）
    ///   - identity: 実行中アプリの識別情報
    ///   - currentVersion: 実行中アプリのバージョン情報
    ///   - skippedVersion: ユーザーがスキップ保存したバージョン文字列
    ///   - trigger: 確認トリガー（自動 / 手動）
    /// - Returns: 判定結果（`UpdateCheckDecision`）
    public static func evaluate(
        latestRelease: UpdateRelease?,
        identity: AppIdentity,
        currentVersion: AppVersionInfo,
        skippedVersion: String?,
        trigger: UpdateCheckTrigger
    ) -> UpdateCheckDecision {
        guard !identity.isDevelopmentBuild, let currentSemVer = currentVersion.semanticVersion else {
            return .developmentBuild
        }

        guard let latestRelease, latestRelease.version > currentSemVer else {
            return .upToDate(currentVersion: currentSemVer)
        }

        // 自動チェック時のみスキップ保存済みバージョンの通知を抑止する（手動確認では再提示する）
        if trigger == .automatic, isSkippedVersion(latestRelease.version, skippedVersion: skippedVersion) {
            return .skipped(release: latestRelease)
        }

        return .updateAvailable(release: latestRelease)
    }
}

/// アプリ内自動差し替えを実行できない理由。
public enum UpdateIneligibilityReason: Equatable, Sendable {
    /// ローカル開発版または非 SemVer ビルドで実行されている。
    case developmentBuild
    /// App Translocation（隔離実行パス）で実行されている。
    case appTranslocation
    /// `.app` バンドル以外の形式（`swift run PrefSnap` 等）で実行されている。
    case notAppBundle
    /// 読み取り専用ボリューム上に配置されている。
    case readOnlyVolume
    /// アプリ本体または親ディレクトリへの書き込み権限が不足している。
    case notWritable(path: String)

    /// ユーザー向けに分かりやすい日本語の理由メッセージを返す。
    public var localizedDescription: String {
        switch self {
        case .developmentBuild:
            return "ローカル開発版として実行されているため、アプリ内からの自動差し替えは利用できません。GitHub Releases から配布版をダウンロードしてください。"
        case .appTranslocation:
            return "アプリが一時隔離領域（App Translocation）から実行されているため、自動差し替えできません。PrefSnap.app を /Applications フォルダへ移動してから再起動するか、GitHub Releases から手動で更新してください。"
        case .notAppBundle:
            return ".app バンドルとして起動されていないため、自動差し替えは利用できません。GitHub Releases から最新版をダウンロードしてください。"
        case .readOnlyVolume:
            return "読み取り専用ボリューム（ディスクイメージ等）から実行されているため、自動差し替えできません。/Applications フォルダへコピーしてからご利用ください。"
        case .notWritable(let path):
            return "配置先（\(path)）への書き込み権限がないため、自動差し替えできません。管理者権限のある場所から移動するか、GitHub Releases から手動で更新してください。"
        }
    }
}

/// アプリ内自動差し替えの実行可否判定結果。
public enum UpdateInstallEligibility: Equatable, Sendable {
    /// 自動差し替えを実行可能。
    case eligible(appBundleURL: URL)
    /// 自動差し替えを実行不可（フォールバック導線を案内）。
    case ineligible(reason: UpdateIneligibilityReason)

    /// 自動差し替えが可能であれば `true`。
    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }

    /// 実行不可時の理由メッセージ（実行可能時は `nil`）。
    public var ineligibilityMessage: String? {
        if case .ineligible(let reason) = self {
            return reason.localizedDescription
        }
        return nil
    }

    /// 判定に必要な実行環境スナップショット（テストでの決定論的検証のために分離）。
    public struct EnvironmentSnapshot: Equatable, Sendable {
        /// 実行中アプリの識別情報。
        public let identity: AppIdentity
        /// 実行中アプリのバージョン情報。
        public let versionInfo: AppVersionInfo
        /// 配置先ボリュームが読み取り専用かどうか。
        public let isReadOnlyVolume: Bool
        /// アプリバンドル本体へ書き込み可能かどうか。
        public let isBundleWritable: Bool
        /// アプリバンドルの親ディレクトリへ書き込み可能かどうか。
        public let isParentDirectoryWritable: Bool

        /// 環境スナップショットを初期化する。
        /// - Parameters:
        ///   - identity: アプリ識別情報
        ///   - versionInfo: アプリバージョン情報
        ///   - isReadOnlyVolume: 読み取り専用ボリュームかどうか
        ///   - isBundleWritable: アプリ本体への書き込み可否
        ///   - isParentDirectoryWritable: 親ディレクトリへの書き込み可否
        public init(
            identity: AppIdentity,
            versionInfo: AppVersionInfo,
            isReadOnlyVolume: Bool,
            isBundleWritable: Bool,
            isParentDirectoryWritable: Bool
        ) {
            self.identity = identity
            self.versionInfo = versionInfo
            self.isReadOnlyVolume = isReadOnlyVolume
            self.isBundleWritable = isBundleWritable
            self.isParentDirectoryWritable = isParentDirectoryWritable
        }
    }

    /// 環境スナップショットから自動差し替えの実行可否を純粋に判定する。
    /// - Parameter snapshot: 実行環境スナップショット
    /// - Returns: 実行可否判定結果
    public static func evaluate(snapshot: EnvironmentSnapshot) -> UpdateInstallEligibility {
        let bundleURL = snapshot.identity.bundleURL

        // `.app` バンドル以外（例: `swift run PrefSnap`）を先に識別して適切な理由を返す
        if !snapshot.identity.isAppBundle {
            return .ineligible(reason: .notAppBundle)
        }

        if snapshot.identity.isDevelopmentBuild || snapshot.versionInfo.semanticVersion == nil {
            return .ineligible(reason: .developmentBuild)
        }

        if bundleURL.path.contains("/AppTranslocation/") {
            return .ineligible(reason: .appTranslocation)
        }

        if snapshot.isReadOnlyVolume {
            return .ineligible(reason: .readOnlyVolume)
        }

        if !snapshot.isBundleWritable {
            return .ineligible(reason: .notWritable(path: bundleURL.path))
        }

        let parentURL = bundleURL.deletingLastPathComponent()
        if !snapshot.isParentDirectoryWritable {
            return .ineligible(reason: .notWritable(path: parentURL.path))
        }

        return .eligible(appBundleURL: bundleURL)
    }

    /// 実環境のファイルシステムを参照して自動差し替えの実行可否を判定する。
    /// - Parameters:
    ///   - identity: 実行中アプリの識別情報
    ///   - versionInfo: 実行中アプリのバージョン情報
    ///   - fileManager: ファイルシステム参照に使用する `FileManager`
    /// - Returns: 実行可否判定結果
    public static func evaluateCurrentEnvironment(
        identity: AppIdentity,
        versionInfo: AppVersionInfo,
        fileManager: FileManager = .default
    ) -> UpdateInstallEligibility {
        let bundleURL = identity.bundleURL
        let parentURL = bundleURL.deletingLastPathComponent()

        let resourceValues = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        let isReadOnly = resourceValues?.volumeIsReadOnly ?? false
        let isBundleWritable = fileManager.isWritableFile(atPath: bundleURL.path)
        let isParentWritable = fileManager.isWritableFile(atPath: parentURL.path)

        let snapshot = EnvironmentSnapshot(
            identity: identity,
            versionInfo: versionInfo,
            isReadOnlyVolume: isReadOnly,
            isBundleWritable: isBundleWritable,
            isParentDirectoryWritable: isParentWritable
        )
        return evaluate(snapshot: snapshot)
    }
}

/// アップデート適用（ダウンロード〜差し替え準備）の進行フェーズと進捗情報。
public enum UpdateInstallProgress: Equatable, Sendable {
    /// ZIP ファイルをダウンロード中（総サイズ取得時は 0.0〜1.0、不明時は `nil`）。
    case downloading(fractionCompleted: Double?)
    /// SHA-256 チェックサムを検証中。
    case verifyingChecksum
    /// ZIP アーカイブを展開中。
    case extracting
    /// 展開後アプリバンドルの `Info.plist`・コード署名・Team ID を検証中。
    case verifyingBundle
    /// 分離ヘルパープロセスによる差し替え・再起動を準備中。
    case preparingReplacement

    /// UI に表示するフェーズ説明文言。
    public var statusText: String {
        switch self {
        case .downloading(let fraction):
            if let fraction {
                let percent = Int((min(max(fraction, 0.0), 1.0) * 100.0).rounded())
                return "アップデートをダウンロード中… (\(percent)%)"
            }
            return "アップデートをダウンロード中…"
        case .verifyingChecksum:
            return "ファイルの整合性（SHA-256）を検証中…"
        case .extracting:
            return "アップデートを展開中…"
        case .verifyingBundle:
            return "アプリの署名とバージョンを検証中…"
        case .preparingReplacement:
            return "アプリを差し替えて再起動する準備をしています…"
        }
    }

    /// 確定進捗率（0.0〜1.0）。不確定インジケーターを表示する場合は `nil`。
    public var fractionCompleted: Double? {
        switch self {
        case .downloading(let fraction):
            return fraction.map { min(max($0, 0.0), 1.0) * 0.70 }
        case .verifyingChecksum:
            return 0.78
        case .extracting:
            return 0.85
        case .verifyingBundle:
            return 0.92
        case .preparingReplacement:
            return 0.98
        }
    }
}

/// アプリ内自動アップデート機能で発生するエラー型。
public enum AppUpdateError: LocalizedError, Equatable, Sendable {
    /// GitHub API のレート制限に到達した。
    case rateLimited(resetDate: Date?)
    /// ネットワーク通信に失敗した。
    case networkError(detail: String)
    /// 予期しない HTTP ステータスコードが返却された。
    case httpError(statusCode: Int)
    /// API レスポンスの形式が不正だった。
    case invalidResponse(detail: String)
    /// 期待される配布 ZIP アセットがリリースに含まれていなかった。
    case missingReleaseAsset(expectedName: String)
    /// 許可されていないホストへのダウンロードまたはリダイレクトが検出された。
    case untrustedDownloadURL(urlString: String)
    /// API のアセット `digest` 形式が不正だった。
    case invalidAssetDigest(raw: String)
    /// ダウンロード済み ZIP の SHA-256 チェックサムが一致しなかった。
    case checksumMismatch(expected: String, actual: String)
    /// ZIP アーカイブの展開に失敗した。
    case extractionFailed(detail: String)
    /// 展開後の `.app` バンドルまたは `Info.plist` が期待条件を満たさなかった。
    case invalidBundle(detail: String)
    /// コード署名の検証に失敗した。
    case codeSignatureInvalid(detail: String)
    /// 現行アプリと展開済みアプリの Team ID が未設定または一致しなかった。
    case teamIdentifierMismatch(expected: String?, actual: String?)
    /// 分離ヘルパープロセスの起動に失敗した。
    case helperLaunchFailed(detail: String)
    /// 実行環境がアプリ内自動差し替えの条件を満たしていない。
    case ineligible(UpdateIneligibilityReason)
    /// PrefSnap 本体がスキャン・適用・ロールバック処理中のため開始できない。
    case appIsBusy

    /// ユーザー向けの日本語エラーメッセージ。
    public var errorDescription: String? {
        switch self {
        case .rateLimited(let resetDate):
            if let resetDate {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ja_JP")
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "GitHub API のレート制限に達しました。\(formatter.string(from: resetDate)) 以降に再試行するか、GitHub Releases から手動でダウンロードしてください。"
            }
            return "GitHub API のレート制限に達しました。しばらく待ってから再試行するか、GitHub Releases から手動でダウンロードしてください。"
        case .networkError(let detail):
            return "アップデートサーバーへの通信に失敗しました（\(detail)）。ネットワーク接続を確認のうえ再試行してください。"
        case .httpError(let statusCode):
            return "アップデートサーバーからエラー応答（HTTP \(statusCode)）を受信しました。時間をおいて再試行するか、GitHub Releases をご確認ください。"
        case .invalidResponse(let detail):
            return "リリース情報の解析に失敗しました（\(detail)）。"
        case .missingReleaseAsset(let expectedName):
            return "最新リリースに配布パッケージ（\(expectedName)）が見つかりませんでした。GitHub Releases ページをご確認ください。"
        case .untrustedDownloadURL(let urlString):
            return "信頼されていないダウンロード先（\(urlString)）が検出されたため、安全のためアップデートを中止しました。"
        case .invalidAssetDigest(let raw):
            return "リリース情報の SHA-256 ダイジェスト形式が不正なため、安全のためアップデートを中止しました（\(raw)）。"
        case .checksumMismatch:
            return "ダウンロードしたファイルの SHA-256 チェックサムが一致しなかったため、アップデートを中止しました。"
        case .extractionFailed(let detail):
            return "アップデートパッケージの展開に失敗しました（\(detail)）。"
        case .invalidBundle(let detail):
            return "展開されたアプリパッケージの検証に失敗しました（\(detail)）。"
        case .codeSignatureInvalid(let detail):
            return "新しいアプリのコード署名検証に失敗したため、アップデートを中止しました（\(detail)）。"
        case .teamIdentifierMismatch:
            return "新しいアプリの署名元（Developer ID Team ID）が現在のアプリと一致しないか確認できなかったため、アップデートを中止しました。"
        case .helperLaunchFailed(let detail):
            return "アップデート適用用ヘルパーの起動に失敗しました（\(detail)）。"
        case .ineligible(let reason):
            return reason.localizedDescription
        case .appIsBusy:
            return "現在、設定のスキャン・インポート適用・ロールバック処理を実行中です。処理が完了してからアップデートを開始してください。"
        }
    }

    /// エラー時に GitHub Releases を開くフォールバック導線の表示を推奨するかどうか。
    public var shouldSuggestManualDownload: Bool {
        switch self {
        case .appIsBusy:
            return false
        default:
            return true
        }
    }
}
