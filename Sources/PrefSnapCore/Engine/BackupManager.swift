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
    public func loadBackup(_ record: BackupRecord) throws -> PrefSnapSnapshot {
        let data = try fileStore.readData(from: record.fileURL)
        return try serializer.decode(data)
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
