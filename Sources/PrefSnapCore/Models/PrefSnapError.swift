import Foundation

/// システム設定の権限関連画面を開くための URL 定義。
public enum SystemPreferencesURL {
    /// プライバシーとセキュリティ ＞ フルディスクアクセス
    public static let fullDiskAccess = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
    /// プライバシーとセキュリティ ＞ 入力監視
    public static let inputMonitoring = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )!
    /// プライバシーとセキュリティ ＞ 一般
    public static let privacyGeneral = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
    )!
}

/// PrefSnap 全体で使用するエラー型。
public enum PrefSnapError: Error, LocalizedError, Equatable, Sendable {
    /// フルディスクアクセス等の権限不足により読み書きに失敗した
    case permissionDenied(target: String, detail: String, settingsURL: URL)
    /// コマンド実行が異常終了した
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    /// plist ファイルの解析・変換に失敗した
    case invalidPlist(path: String, detail: String)
    /// JSON スキーマバージョンが非対応
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// JSON のデコード／エンコードに失敗した
    case serializationFailed(detail: String)
    /// IOKit によるキーボード列挙に失敗した
    case keyboardDetectionFailed(detail: String)
    /// ファイル操作に失敗した
    case fileOperationFailed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(target, detail, _):
            return "権限不足のため「\(target)」にアクセスできませんでした: \(detail)"
        case let .commandFailed(command, exitCode, stderr):
            return "コマンド実行に失敗しました（\(command), 終了コード \(exitCode)）: \(stderr)"
        case let .invalidPlist(path, detail):
            return "plist ファイルの読み込みに失敗しました（\(path)）: \(detail)"
        case let .unsupportedSchemaVersion(found, supported):
            return "非対応の JSON スキーマバージョンです（検出: v\(found), 対応: v\(supported)）"
        case let .serializationFailed(detail):
            return "JSON データの変換に失敗しました: \(detail)"
        case let .keyboardDetectionFailed(detail):
            return "キーボード情報の取得に失敗しました: \(detail)"
        case let .fileOperationFailed(path, detail):
            return "ファイル操作に失敗しました（\(path)）: \(detail)"
        }
    }
}

/// 個別項目の読み書き時に発生した権限エラーや処理エラー。
/// アプリ全体をクラッシュさせずに UI 上で表示し、システム設定への導線を提供する。
public struct ItemIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let itemTitle: String
    public let message: String
    public let isPermissionError: Bool
    public let systemSettingsURL: URL?

    public init(
        id: String = UUID().uuidString,
        itemTitle: String,
        message: String,
        isPermissionError: Bool,
        systemSettingsURL: URL? = nil
    ) {
        self.id = id
        self.itemTitle = itemTitle
        self.message = message
        self.isPermissionError = isPermissionError
        self.systemSettingsURL = systemSettingsURL
    }
}
