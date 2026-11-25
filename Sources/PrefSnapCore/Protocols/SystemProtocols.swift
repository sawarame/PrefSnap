import Foundation

/// 外部コマンド実行の結果。
public struct CommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// `defaults` や `killall` などの外部コマンド実行を抽象化するプロトコル。
public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) throws -> CommandOutput
}

/// plist ファイルの読み書きおよび Preferences ディレクトリ探索を抽象化するプロトコル。
public protocol PlistStoring: Sendable {
    /// ユーザーの Preferences ディレクトリ（通常は `~/Library/Preferences`）
    var preferencesDirectory: URL { get }
    /// `ByHost` ディレクトリ（通常は `~/Library/Preferences/ByHost`）
    var byHostDirectory: URL { get }

    func fileExists(at url: URL) -> Bool
    func listFiles(in directory: URL) throws -> [URL]
    func readPlistDictionary(at url: URL) throws -> [String: Any]
    func writePlistDictionary(_ dictionary: [String: Any], to url: URL) throws
}

/// `IOKit`（`IOHIDManager`）による接続キーボード検出を抽象化するプロトコル。
public protocol KeyboardDetecting: Sendable {
    func connectedKeyboards() throws -> [ConnectedKeyboard]
}

/// JSON バックアップ等のファイルシステム操作を抽象化するプロトコル。
public protocol FileStoring: Sendable {
    /// デフォルトのバックアップ保存ディレクトリ（`~/Library/Application Support/PrefSnap/Backups`）
    var backupDirectory: URL { get }

    func ensureDirectoryExists(at url: URL) throws
    func listFiles(in directory: URL) throws -> [URL]
    func readData(from url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func fileModificationDate(at url: URL) -> Date?
}

/// 設定反映のための macOS プロセス再起動を抽象化するプロトコル。
public protocol ProcessControlling: Sendable {
    func restart(targets: Set<RestartTarget>) throws -> [RestartTarget]
}

/// ホスト名・OS バージョン・現在時刻を提供する環境プロバイダ（テスト決定論性のため抽象化）。
public protocol EnvironmentProviding: Sendable {
    func currentHostMetadata() -> SourceHostMetadata
    func currentDate() -> Date
}
