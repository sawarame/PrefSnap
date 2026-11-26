import Foundation
import IOKit
import IOKit.hid

/// `Foundation.Process` を用いて外部コマンドを実行する本番実装。
public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PrefSnapError.commandFailed(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: -1,
                stderr: error.localizedDescription
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandOutput(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// `PropertyListSerialization` と `FileManager` による plist 読み書き本番実装。
public struct SystemPlistStore: PlistStoring {
    public let preferencesDirectory: URL
    public let byHostDirectory: URL

    public init(
        preferencesDirectory: URL? = nil,
        byHostDirectory: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let prefs = preferencesDirectory ?? home.appendingPathComponent("Library/Preferences", isDirectory: true)
        self.preferencesDirectory = prefs
        self.byHostDirectory = byHostDirectory ?? prefs.appendingPathComponent("ByHost", isDirectory: true)
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func listFiles(in directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            if Self.isPermissionError(error) {
                throw PrefSnapError.permissionDenied(
                    target: directory.path,
                    detail: error.localizedDescription,
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            throw PrefSnapError.fileOperationFailed(path: directory.path, detail: error.localizedDescription)
        }
    }

    public func readPlistDictionary(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if Self.isPermissionError(error) {
                throw PrefSnapError.permissionDenied(
                    target: url.lastPathComponent,
                    detail: error.localizedDescription,
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            throw PrefSnapError.fileOperationFailed(path: url.path, detail: error.localizedDescription)
        }

        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dict = plist as? [String: Any] else {
                throw PrefSnapError.invalidPlist(path: url.path, detail: "ルート要素が辞書ではありません")
            }
            return dict
        } catch let error as PrefSnapError {
            throw error
        } catch {
            throw PrefSnapError.invalidPlist(path: url.path, detail: error.localizedDescription)
        }
    }

    public func writePlistDictionary(_ dictionary: [String: Any], to url: URL) throws {
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        } catch {
            throw PrefSnapError.invalidPlist(path: url.path, detail: error.localizedDescription)
        }

        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            if Self.isPermissionError(error) {
                throw PrefSnapError.permissionDenied(
                    target: url.lastPathComponent,
                    detail: error.localizedDescription,
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            throw PrefSnapError.fileOperationFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    /// 指定されたエラーがファイルアクセス権限不足に該当するかを判定する。
    /// - Parameter error: 判定対象のエラー
    /// - Returns: 権限不足エラーの場合は `true`、それ以外は `false`
    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
                return true
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return true
            }
        }
        // 下位エラーに POSIX 権限エラーがラップされている場合も検出する
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }
}

/// `IOKit`（`IOHIDManager`）を使用して現在接続中のキーボード一覧を取得する本番実装。
public struct IOKitKeyboardDetector: KeyboardDetecting {
    public init() {}

    public func connectedKeyboards() throws -> [ConnectedKeyboard] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnNotPermitted || openResult == kIOReturnNotPrivileged {
            throw PrefSnapError.permissionDenied(
                target: "IOKit キーボード検出",
                detail: "キーボードデバイスの列挙権限がありません（IOReturn: \(openResult)）",
                settingsURL: SystemPreferencesURL.inputMonitoring
            )
        }
        guard openResult == kIOReturnSuccess else {
            throw PrefSnapError.keyboardDetectionFailed(detail: "IOHIDManagerOpen に失敗しました（IOReturn: \(openResult)）")
        }
        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let rawSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        var uniqueByID: [String: ConnectedKeyboard] = [:]
        for device in rawSet {
            guard
                let vendorID = intProperty(device, key: kIOHIDVendorIDKey),
                let productID = intProperty(device, key: kIOHIDProductIDKey),
                vendorID != 0 || productID != 0
            else {
                continue
            }

            let productName = stringProperty(device, key: kIOHIDProductKey) ?? "Keyboard (\(vendorID)-\(productID))"
            let builtInFlag = boolProperty(device, key: kIOHIDBuiltInKey) ?? false
            let transport = stringProperty(device, key: kIOHIDTransportKey)?.lowercased() ?? ""
            let isBuiltIn = builtInFlag
                || transport == "spi"
                || transport == "fifo"
                || productName.lowercased().contains("apple internal")

            let keyboard = ConnectedKeyboard(
                vendorID: vendorID,
                productID: productID,
                deviceName: productName,
                isBuiltIn: isBuiltIn
            )
            // 同一 VendorID-ProductID が複数 HID インターフェースで報告されるため統合する
            if let existing = uniqueByID[keyboard.id] {
                if !existing.isBuiltIn && keyboard.isBuiltIn {
                    uniqueByID[keyboard.id] = keyboard
                }
            } else {
                uniqueByID[keyboard.id] = keyboard
            }
        }

        return uniqueByID.values.sorted { lhs, rhs in
            if lhs.vendorID != rhs.vendorID {
                return lhs.vendorID < rhs.vendorID
            }
            return lhs.productID < rhs.productID
        }
    }

    private func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func boolProperty(_ device: IOHIDDevice, key: String) -> Bool? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return value as? String
    }
}

/// ローカルファイルシステムによるバックアップ・JSON 保存の本番実装。
public struct LocalFileStore: FileStoring {
    public let backupDirectory: URL

    public init(backupDirectory: URL? = nil) {
        if let backupDirectory {
            self.backupDirectory = backupDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.backupDirectory = appSupport
                .appendingPathComponent("PrefSnap", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
        }
    }

    public func ensureDirectoryExists(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            if SystemPlistStore.isPermissionError(error) {
                throw PrefSnapError.permissionDenied(
                    target: url.path,
                    detail: error.localizedDescription,
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            throw PrefSnapError.fileOperationFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    public func listFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw PrefSnapError.fileOperationFailed(path: directory.path, detail: error.localizedDescription)
        }
    }

    public func readData(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            if SystemPlistStore.isPermissionError(error) {
                throw PrefSnapError.permissionDenied(
                    target: url.lastPathComponent,
                    detail: error.localizedDescription,
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            throw PrefSnapError.fileOperationFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    public func writeData(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            if SystemPlistStore.isPermissionError(error) {
                throw PrefSnapError.permissionDenied(
                    target: url.lastPathComponent,
                    detail: error.localizedDescription,
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            throw PrefSnapError.fileOperationFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    public func fileModificationDate(at url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    /// 指定されたファイルを macOS 標準 API を用いてゴミ箱へ移動する。
    /// - Parameter url: ゴミ箱へ移動する対象ファイルの URL
    /// - Throws: 権限不足時は `PrefSnapError.permissionDenied`、その他の失敗時は `PrefSnapError.fileOperationFailed`
    public func trashItem(at url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            if SystemPlistStore.isPermissionError(error) {
                throw PrefSnapError.permissionDenied(
                    target: url.lastPathComponent,
                    detail: error.localizedDescription,
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            throw PrefSnapError.fileOperationFailed(path: url.path, detail: error.localizedDescription)
        }
    }
}

/// `killall` コマンドを用いて指定された macOS プロセスのみを再起動する本番実装。
public struct SystemProcessController: ProcessControlling {
    private let commandRunner: CommandRunning

    public init(commandRunner: CommandRunning = SystemCommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func restart(targets: Set<RestartTarget>) throws -> [RestartTarget] {
        let sortedTargets = targets.sorted()
        var restarted: [RestartTarget] = []
        for target in sortedTargets {
            let output = try commandRunner.run(executable: "/usr/bin/killall", arguments: [target.rawValue])
            // 該当プロセスがそもそも起動していない場合（exitCode 1, "No matching processes"）は致命エラーにしない
            if output.exitCode == 0 {
                restarted.append(target)
            } else if output.stderr.lowercased().contains("no matching processes") {
                continue
            } else {
                throw PrefSnapError.commandFailed(
                    command: "killall \(target.rawValue)",
                    exitCode: output.exitCode,
                    stderr: output.stderr
                )
            }
        }
        return restarted
    }
}

/// 実行中 Mac のホスト情報・OS バージョン・現在時刻を提供する本番実装。
public struct SystemEnvironmentProvider: EnvironmentProviding {
    public init() {}

    public func currentHostMetadata() -> SourceHostMetadata {
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return SourceHostMetadata(hostName: hostName, osVersion: osVersion, architecture: arch)
    }

    public func currentDate() -> Date {
        Date()
    }
}
