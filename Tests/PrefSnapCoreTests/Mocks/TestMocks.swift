import Foundation
@testable import PrefSnapCore

/// 実環境コマンドを一切実行せず、メモリ上で `defaults` 等の読み書きをシミュレートするモック。
final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    /// 実行履歴
    private(set) var invocations: [Invocation] = []
    /// キー形式: `"(byHost ? "currentHost:" : "")\(domain)::\(key)"`
    private var defaultsStore: [String: String] = [:]
    /// `Data` 型設定値（`defaults export` / `defaults write -data` 用）
    private var defaultsDataStore: [String: Data] = [:]
    /// 特定キーの読み書き時に返す権限エラー対象
    var permissionDeniedKeys: Set<String> = []
    /// カスタムハンドラ（設定時は優先実行）
    var customHandler: ((String, [String]) throws -> CommandOutput)?

    func setDefaults(domain: String, key: String, value: String, isByHost: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        defaultsStore[Self.storageKey(domain: domain, key: key, isByHost: isByHost)] = value
    }

    func setDefaultsData(domain: String, key: String, data: Data, isByHost: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        defaultsDataStore[Self.storageKey(domain: domain, key: key, isByHost: isByHost)] = data
    }

    func storedDefaults(domain: String, key: String, isByHost: Bool = false) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaultsStore[Self.storageKey(domain: domain, key: key, isByHost: isByHost)]
    }

    func storedDefaultsData(domain: String, key: String, isByHost: Bool = false) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return defaultsDataStore[Self.storageKey(domain: domain, key: key, isByHost: isByHost)]
    }

    func recordedInvocations() -> [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func run(executable: String, arguments: [String]) throws -> CommandOutput {
        lock.lock()
        invocations.append(Invocation(executable: executable, arguments: arguments))
        let handler = customHandler
        lock.unlock()

        if let handler {
            return try handler(executable, arguments)
        }

        guard executable == "/usr/bin/defaults" else {
            return CommandOutput(exitCode: 0)
        }

        var args = arguments
        var isByHost = false
        if args.first == "-currentHost" {
            isByHost = true
            args.removeFirst()
        }

        guard args.count >= 3 else {
            return CommandOutput(exitCode: 1, stderr: "invalid arguments")
        }

        let verb = args[0]
        let domain = args[1]
        let key = args[2]
        let storeKey = Self.storageKey(domain: domain, key: key, isByHost: isByHost)

        lock.lock()
        defer { lock.unlock() }

        if permissionDeniedKeys.contains(storeKey) {
            return CommandOutput(exitCode: 1, stderr: "Permission denied: Operation not permitted")
        }

        switch verb {
        case "export":
            let prefix = "\(isByHost ? "currentHost:" : "")\(domain)::"
            if permissionDeniedKeys.contains(where: { $0.hasPrefix(prefix) }) {
                return CommandOutput(exitCode: 1, stderr: "Permission denied: Operation not permitted")
            }
            var dict: [String: Any] = [:]
            for (k, v) in defaultsDataStore where k.hasPrefix(prefix) {
                let rawKey = String(k.dropFirst(prefix.count))
                dict[rawKey] = v
            }
            if dict.isEmpty {
                return CommandOutput(exitCode: 1, stderr: "Domain (\(domain)) not found.")
            }
            let xmlData = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            let xmlString = String(data: xmlData, encoding: .utf8) ?? ""
            return CommandOutput(exitCode: 0, stdout: xmlString)
        case "read":
            if let value = defaultsStore[storeKey] {
                return CommandOutput(exitCode: 0, stdout: value + "\n")
            }
            return CommandOutput(exitCode: 1, stderr: "The domain/default pair of (\(domain), \(key)) does not exist")
        case "write":
            if args.count >= 5, args[3] == "-data" {
                guard let decoded = Self.decodeHex(args[4]) else {
                    return CommandOutput(exitCode: 1, stderr: "invalid hex data")
                }
                defaultsDataStore[storeKey] = decoded
            } else if args.count >= 5, args[3] == "-bool" {
                defaultsStore[storeKey] = (args[4].uppercased() == "TRUE" || args[4] == "1") ? "1" : "0"
            } else if args.count >= 5, ["-int", "-float", "-string"].contains(args[3]) {
                defaultsStore[storeKey] = args[4]
            } else if args.count >= 4, args[3] == "-array" {
                defaultsStore[storeKey] = Array(args.dropFirst(4)).joined(separator: "\n")
            } else {
                defaultsStore[storeKey] = Array(args.dropFirst(3)).joined(separator: " ")
            }
            return CommandOutput(exitCode: 0)
        case "delete":
            let removedString = defaultsStore.removeValue(forKey: storeKey) != nil
            let removedData = defaultsDataStore.removeValue(forKey: storeKey) != nil
            if removedString || removedData {
                return CommandOutput(exitCode: 0)
            }
            return CommandOutput(exitCode: 1, stderr: "Domain (\(domain)) not found.")
        default:
            return CommandOutput(exitCode: 1, stderr: "unsupported verb: \(verb)")
        }
    }

    private static func decodeHex(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func storageKey(domain: String, key: String, isByHost: Bool) -> String {
        "\(isByHost ? "currentHost:" : "")\(domain)::\(key)"
    }
}

/// メモリ上で plist ファイルを読み書きするモック。実ディスクには一切書き込まない。
final class MockPlistStore: PlistStoring, @unchecked Sendable {
    let preferencesDirectory: URL
    let byHostDirectory: URL

    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    var permissionDeniedPaths: Set<String> = []

    init() {
        self.preferencesDirectory = URL(fileURLWithPath: "/mock/Library/Preferences", isDirectory: true)
        self.byHostDirectory = URL(fileURLWithPath: "/mock/Library/Preferences/ByHost", isDirectory: true)
    }

    func setPlist(_ dictionary: [String: Any], at url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        lock.lock()
        files[url.standardizedFileURL] = data
        lock.unlock()
    }

    func fileExists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files[url.standardizedFileURL] != nil
    }

    func listFiles(in directory: URL) throws -> [URL] {
        let dirPath = directory.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if permissionDeniedPaths.contains(dirPath) {
            throw PrefSnapError.permissionDenied(
                target: dirPath,
                detail: "Operation not permitted",
                settingsURL: SystemPreferencesURL.fullDiskAccess
            )
        }
        return files.keys.filter { $0.deletingLastPathComponent().standardizedFileURL.path == dirPath }
    }

    func readPlistDictionary(at url: URL) throws -> [String: Any] {
        let normalized = url.standardizedFileURL
        lock.lock()
        let isDenied = permissionDeniedPaths.contains(normalized.path) || permissionDeniedPaths.contains(normalized.lastPathComponent)
        let data = files[normalized]
        lock.unlock()

        if isDenied {
            throw PrefSnapError.permissionDenied(
                target: normalized.lastPathComponent,
                detail: "Permission denied",
                settingsURL: SystemPreferencesURL.fullDiskAccess
            )
        }
        guard let data else {
            throw PrefSnapError.fileOperationFailed(path: normalized.path, detail: "File not found")
        }
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw PrefSnapError.invalidPlist(path: normalized.path, detail: "Not a dictionary")
        }
        return dict
    }

    func writePlistDictionary(_ dictionary: [String: Any], to url: URL) throws {
        let normalized = url.standardizedFileURL
        lock.lock()
        let isDenied = permissionDeniedPaths.contains(normalized.path) || permissionDeniedPaths.contains(normalized.lastPathComponent)
        lock.unlock()

        if isDenied {
            throw PrefSnapError.permissionDenied(
                target: normalized.lastPathComponent,
                detail: "Permission denied",
                settingsURL: SystemPreferencesURL.fullDiskAccess
            )
        }
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        lock.lock()
        files[normalized] = data
        lock.unlock()
    }
}

/// IOKit キーボード検出をシミュレートするモック。
final class MockKeyboardDetector: KeyboardDetecting, @unchecked Sendable {
    private let lock = NSLock()
    var keyboards: [ConnectedKeyboard]
    var errorToThrow: Error?

    init(keyboards: [ConnectedKeyboard] = []) {
        self.keyboards = keyboards
    }

    func connectedKeyboards() throws -> [ConnectedKeyboard] {
        lock.lock()
        defer { lock.unlock() }
        if let errorToThrow {
            throw errorToThrow
        }
        return keyboards
    }
}

/// バックアップや JSON ファイルをメモリ上で管理するモック。
final class MockFileStore: FileStoring, @unchecked Sendable {
    let backupDirectory: URL
    private let lock = NSLock()
    private var files: [URL: (data: Data, modifiedAt: Date)] = [:]
    var failWriteWithPermissionError = false

    init() {
        self.backupDirectory = URL(fileURLWithPath: "/mock/Application Support/PrefSnap/Backups", isDirectory: true)
    }

    func ensureDirectoryExists(at url: URL) throws {
        if failWriteWithPermissionError {
            throw PrefSnapError.permissionDenied(
                target: url.path,
                detail: "Permission denied",
                settingsURL: SystemPreferencesURL.fullDiskAccess
            )
        }
    }

    func listFiles(in directory: URL) throws -> [URL] {
        let dirPath = directory.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return files.keys.filter { $0.deletingLastPathComponent().standardizedFileURL.path == dirPath }
    }

    func readData(from url: URL) throws -> Data {
        let normalized = url.standardizedFileURL
        lock.lock()
        let entry = files[normalized]
        lock.unlock()
        guard let entry else {
            throw PrefSnapError.fileOperationFailed(path: normalized.path, detail: "File not found")
        }
        return entry.data
    }

    func writeData(_ data: Data, to url: URL) throws {
        if failWriteWithPermissionError {
            throw PrefSnapError.permissionDenied(
                target: url.lastPathComponent,
                detail: "Permission denied",
                settingsURL: SystemPreferencesURL.fullDiskAccess
            )
        }
        let normalized = url.standardizedFileURL
        lock.lock()
        files[normalized] = (data, Date())
        lock.unlock()
    }

    func fileModificationDate(at url: URL) -> Date? {
        let normalized = url.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        return files[normalized]?.modifiedAt
    }

    func allStoredFileNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return files.keys.map(\.lastPathComponent).sorted()
    }
}

/// プロセス再起動の呼び出しのみを記録するモック。実プロセスは一切再起動しない。
final class MockProcessController: ProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var restartedHistory: [[RestartTarget]] = []

    func restart(targets: Set<RestartTarget>) throws -> [RestartTarget] {
        let sorted = targets.sorted()
        lock.lock()
        restartedHistory.append(sorted)
        lock.unlock()
        return sorted
    }

    func recordedRestarts() -> [[RestartTarget]] {
        lock.lock()
        defer { lock.unlock() }
        return restartedHistory
    }
}

/// ホスト情報と時刻を固定してテストを決定論的にするモック。
final class MockEnvironmentProvider: EnvironmentProviding, @unchecked Sendable {
    private let lock = NSLock()
    var hostMetadata: SourceHostMetadata
    var fixedDate: Date

    init(
        hostMetadata: SourceHostMetadata = SourceHostMetadata(
            hostName: "Test-MacBook-Pro",
            osVersion: "macOS 15.0",
            architecture: "arm64"
        ),
        fixedDate: Date = Date(timeIntervalSince1970: 1_764_000_000)
    ) {
        self.hostMetadata = hostMetadata
        self.fixedDate = fixedDate
    }

    func currentHostMetadata() -> SourceHostMetadata {
        lock.lock()
        defer { lock.unlock() }
        return hostMetadata
    }

    func currentDate() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return fixedDate
    }
}
