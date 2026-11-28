import Foundation

/// アップデート関連のユーザー設定（自動チェック有無・スキップ済みバージョン）の永続化を抽象化するプロトコル。
public protocol UpdatePreferencesStoring: AnyObject, Sendable {
    /// 起動時にアップデートを自動チェックするかどうか（初期値 `false`）。
    var autoCheckForUpdates: Bool { get set }
    /// ユーザーが「このバージョンをスキップ」で保存したバージョン文字列。
    var skippedUpdateVersion: String? { get set }
}

/// `UserDefaults` を用いたアップデート設定永続化の本番実装。
public final class UserDefaultsUpdatePreferencesStore: UpdatePreferencesStoring, @unchecked Sendable {
    /// 起動時自動チェック設定の保存キー。
    public static let autoCheckKey = "dev.prefsnap.autoCheckForUpdates"
    /// スキップ済みバージョン文字列の保存キー。
    public static let skippedVersionKey = "dev.prefsnap.skippedUpdateVersion"

    private let userDefaults: UserDefaults

    /// `UserDefaults` ストアを初期化する。
    /// - Parameter userDefaults: 保存先となる `UserDefaults`（既定値は `.standard`）
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// 起動時自動チェック設定を読み書きする（未保存時は `false`）。
    public var autoCheckForUpdates: Bool {
        get { userDefaults.bool(forKey: Self.autoCheckKey) }
        set { userDefaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    /// スキップ保存済みバージョン文字列を読み書きする。
    public var skippedUpdateVersion: String? {
        get { userDefaults.string(forKey: Self.skippedVersionKey) }
        set {
            if let newValue, !newValue.isEmpty {
                userDefaults.set(newValue, forKey: Self.skippedVersionKey)
            } else {
                userDefaults.removeObject(forKey: Self.skippedVersionKey)
            }
        }
    }
}

/// GitHub Releases の確認・環境判定・安全なダウンロード／検証／差し替え起動を抽象化するプロトコル。
public protocol AppUpdateServing: Sendable {
    /// GitHub Releases API から最新の安定版リリースを取得する。
    /// - Parameter currentVersion: リクエストヘッダ（`User-Agent`）に付与する現在バージョン情報
    /// - Returns: 安定版リリース情報。最新リリースがドラフト／プレリリースの場合は `nil`
    /// - Throws: 通信エラー・レート制限・レスポンス不正・アセット欠損時に `AppUpdateError`
    func fetchLatestStableRelease(currentVersion: AppVersionInfo) async throws -> UpdateRelease?

    /// 現在の実行環境がアプリ内自動差し替えに対応しているかを判定する。
    /// - Parameters:
    ///   - identity: 実行中アプリの識別情報
    ///   - versionInfo: 実行中アプリのバージョン情報
    /// - Returns: 自動差し替えの実行可否
    func checkInstallEligibility(identity: AppIdentity, versionInfo: AppVersionInfo) -> UpdateInstallEligibility

    /// 指定リリースのダウンロード・多段階検証・分離ヘルパー起動までを実行する。
    /// - Parameters:
    ///   - release: 適用対象のリリース情報
    ///   - targetAppURL: 差し替え対象となる現行 `.app` バンドルの URL
    ///   - progress: 進捗・フェーズ変化を通知するコールバック
    /// - Throws: URL 検証・チェックサム・展開・`Info.plist`・署名・Team ID・ヘルパー起動の失敗時に `AppUpdateError`
    func installUpdate(
        _ release: UpdateRelease,
        targetAppURL: URL,
        progress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async throws
}
