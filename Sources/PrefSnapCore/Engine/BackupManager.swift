import Foundation

/// 設定適用直前の自動バックアップ保存および、過去のバックアップ一覧取得・読み込みを管理するクラス。
public struct BackupManager: Sendable {
    private let fileStore: FileStoring
    private let serializer: SnapshotSerializer
    private let environment: EnvironmentProviding

    public init(
        fileStore: FileStoring,
        serializer: SnapshotSerializer = SnapshotSerializer(),
        environment: EnvironmentProviding = SystemEnvironmentProvider()
    ) {
        self.fileStore = fileStore
        self.serializer = serializer
        self.environment = environment
    }

    /// 指定されたスナップショットをタイムスタンプ付き JSON として `Backups` ディレクトリに保存する。
    public func saveBackup(_ snapshot: PrefSnapSnapshot) throws -> BackupRecord {
        try fileStore.ensureDirectoryExists(at: fileStore.backupDirectory)

        let now = environment.currentDate()
        let fileName = Self.makeFileName(for: now)
        let fileURL = fileStore.backupDirectory.appendingPathComponent(fileName)
        let data = try serializer.encode(snapshot)
        try fileStore.writeData(data, to: fileURL)

        return BackupRecord(
            id: fileName,
            fileName: fileName,
            fileURL: fileURL,
            createdAt: now,
            hostName: snapshot.sourceHost.hostName
        )
    }

    /// 保存済みのバックアップ一覧を新しい順（降順）で返す。
    public func listBackups() throws -> [BackupRecord] {
        let files = try fileStore.listFiles(in: fileStore.backupDirectory)
            .filter { $0.pathExtension.lowercased() == "json" }

        var records: [BackupRecord] = []
        for url in files {
            let fileName = url.lastPathComponent
            let date = Self.parseDate(from: fileName)
                ?? fileStore.fileModificationDate(at: url)
                ?? Date.distantPast
            var hostName: String?
            if let data = try? fileStore.readData(from: url),
               let snapshot = try? serializer.decode(data) {
                hostName = snapshot.sourceHost.hostName
            }
            records.append(
                BackupRecord(
                    id: fileName,
                    fileName: fileName,
                    fileURL: url,
                    createdAt: date,
                    hostName: hostName
                )
            )
        }

        return records.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.fileName > rhs.fileName
        }
    }

    /// 選択されたバックアップファイルを読み込み、`PrefSnapSnapshot` として返す。
    /// - Parameter record: 読み込み対象のバックアップレコード
    /// - Returns: デコードされた `PrefSnapSnapshot`
    public func loadBackup(_ record: BackupRecord) throws -> PrefSnapSnapshot {
        let data = try fileStore.readData(from: record.fileURL)
        return try serializer.decode(data)
    }

    /// 指定されたバックアップファイルを安全検証の上でゴミ箱へ移動する。
    /// - Parameter record: 削除対象のバックアップレコード
    /// - Throws: バックアップ保存先直下の `.json` ファイル以外が指定された場合、またはゴミ箱移動に失敗した場合に `PrefSnapError` を送出する
    public func deleteBackup(_ record: BackupRecord) throws {
        let targetURL = record.fileURL
        guard isValidBackupFileURL(targetURL) else {
            throw PrefSnapError.fileOperationFailed(
                path: targetURL.path,
                detail: "バックアップディレクトリ直下の JSON ファイル以外は削除できません。"
            )
        }
        try fileStore.trashItem(at: targetURL)
    }

    /// 対象 URL が `backupDirectory` 直下の `.json` ファイルであるかを検証する。
    /// - Parameter url: 検証対象のファイル URL
    /// - Returns: `backupDirectory` 直下かつ拡張子が `.json` であれば `true`、それ以外は `false`
    private func isValidBackupFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }

        // 標準化およびシンボリックリンク解決後のパスで backupDirectory 直下かを検証する
        let resolvedBackupDir = fileStore.backupDirectory.resolvingSymlinksInPath().standardizedFileURL
        let standardizedResolvedTarget = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = url.resolvingSymlinksInPath().standardizedFileURL

        guard
            standardizedResolvedTarget.deletingLastPathComponent().standardizedFileURL.path == resolvedBackupDir.path,
            resolvedTarget.deletingLastPathComponent().standardizedFileURL.path == resolvedBackupDir.path
        else {
            return false
        }

        // 拡張子が .json であることを確認し、バックアップ以外のファイル削除を防ぐ
        guard
            standardizedResolvedTarget.pathExtension.lowercased() == "json",
            resolvedTarget.pathExtension.lowercased() == "json"
        else {
            return false
        }

        return true
    }

    private static func makeFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "PrefSnap_Backup_\(formatter.string(from: date)).json"
    }

    private static func parseDate(from fileName: String) -> Date? {
        let prefix = "PrefSnap_Backup_"
        let suffix = ".json"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let stamp = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.date(from: stamp)
    }
}
