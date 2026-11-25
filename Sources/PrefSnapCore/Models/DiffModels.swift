import Foundation

/// 修飾キーリマップの接続デバイス照合結果。
public enum ModifierMatchStatus: Equatable, Hashable, Sendable {
    /// `VendorID-ProductID` が完全一致するキーボードが接続されている
    case exactMatch(ConnectedKeyboard)
    /// `ProductID` は不一致だが、`isBuiltIn == true` であり移行先に別の内蔵キーボードが存在する
    case builtInFallbackAvailable(sourceDeviceName: String, targetBuiltIn: ConnectedKeyboard)
    /// 一致するキーボードが接続されておらずスキップ対象
    case disconnected
}

/// 差分適用時に実際に実行する操作の内部表現。
public enum ApplyAction: Equatable, Hashable, Sendable {
    /// `defaults` の値書き込みまたは削除（`newValue == nil` の場合は `defaults delete`）
    case defaultsSetting(descriptor: SettingDescriptor, newValue: DefaultsValue?)
    /// `AppleSymbolicHotKeys` 内の特定 ID の安全なマージ更新（`newValue == nil` の場合は該当 ID を削除）
    case symbolicHotKey(id: String, newValue: SymbolicHotKeyEntry?)
    /// `NSUserKeyEquivalents` の更新および `com.apple.universalaccess` の `com.apple.custommenu.apps` 更新
    case appShortcut(domain: String, shortcuts: [String: String])
    /// `ByHost/.GlobalPreferences` への修飾キーリマップ書き込み
    case modifierMapping(
        targetVendorID: Int,
        targetProductID: Int,
        targetDeviceName: String,
        mappings: [ModifierKeyPair]
    )
}

/// 差分プレビュー画面に表示される 1 項目。
public struct DiffItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: SettingCategory
    public let subcategoryLabel: String
    public let title: String
    public let detail: String
    public let beforeDisplay: String
    public let afterDisplay: String
    public let action: ApplyAction
    public let restartTargets: Set<RestartTarget>
    public let requiresRelogin: Bool
    /// 修飾キー項目のみ値が入る
    public let modifierMatchStatus: ModifierMatchStatus?
    /// チェックボックスによる適用選択状態
    public var isSelected: Bool
    /// `builtInFallbackAvailable` 時に「この Mac の内蔵キーボードへ適用する」を選んだか
    public var applyToBuiltInKeyboard: Bool

    public init(
        id: String,
        category: SettingCategory,
        subcategoryLabel: String,
        title: String,
        detail: String,
        beforeDisplay: String,
        afterDisplay: String,
        action: ApplyAction,
        restartTargets: Set<RestartTarget>,
        requiresRelogin: Bool,
        modifierMatchStatus: ModifierMatchStatus? = nil,
        isSelected: Bool = true,
        applyToBuiltInKeyboard: Bool = false
    ) {
        self.id = id
        self.category = category
        self.subcategoryLabel = subcategoryLabel
        self.title = title
        self.detail = detail
        self.beforeDisplay = beforeDisplay
        self.afterDisplay = afterDisplay
        self.action = action
        self.restartTargets = restartTargets
        self.requiresRelogin = requiresRelogin
        self.modifierMatchStatus = modifierMatchStatus
        self.isSelected = isSelected
        self.applyToBuiltInKeyboard = applyToBuiltInKeyboard
    }

    /// 適用可能かどうか（未接続スキップ項目は false）。
    public var isApplicable: Bool {
        switch modifierMatchStatus {
        case .disconnected:
            return false
        case .builtInFallbackAvailable:
            return applyToBuiltInKeyboard
        case .exactMatch, .none:
            return true
        }
    }

    /// 実際に適用対象として有効かどうか（適用可能かつチェックボックス ON）。
    public var willApply: Bool {
        switch modifierMatchStatus {
        case .disconnected:
            return false
        case .builtInFallbackAvailable:
            return applyToBuiltInKeyboard
        case .exactMatch, .none:
            return isSelected
        }
    }
}

/// エクスポート処理の結果レポート。
public struct ExportReport: Equatable, Sendable {
    public let snapshot: PrefSnapSnapshot
    public let issues: [ItemIssue]

    public init(snapshot: PrefSnapSnapshot, issues: [ItemIssue] = []) {
        self.snapshot = snapshot
        self.issues = issues
    }
}

/// Dry-run 差分比較の結果。
public struct DiffReport: Equatable, Sendable {
    public let items: [DiffItem]
    public let connectedKeyboards: [ConnectedKeyboard]
    public let issues: [ItemIssue]

    public init(items: [DiffItem], connectedKeyboards: [ConnectedKeyboard], issues: [ItemIssue] = []) {
        self.items = items
        self.connectedKeyboards = connectedKeyboards
        self.issues = issues
    }
}

/// 保存済みバックアップファイルのメタデータ。
public struct BackupRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let fileName: String
    public let fileURL: URL
    public let createdAt: Date
    public let hostName: String?

    public init(id: String, fileName: String, fileURL: URL, createdAt: Date, hostName: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.hostName = hostName
    }
}

/// 設定適用・ロールバック実行の結果サマリー。
public struct ApplyResult: Equatable, Sendable {
    public let appliedCount: Int
    public let skippedCount: Int
    public let backupRecord: BackupRecord?
    public let restartedProcesses: [RestartTarget]
    public let reloginRequiredItems: [String]
    public let issues: [ItemIssue]

    public var requiresRelogin: Bool {
        !reloginRequiredItems.isEmpty
    }

    public init(
        appliedCount: Int,
        skippedCount: Int,
        backupRecord: BackupRecord?,
        restartedProcesses: [RestartTarget],
        reloginRequiredItems: [String],
        issues: [ItemIssue]
    ) {
        self.appliedCount = appliedCount
        self.skippedCount = skippedCount
        self.backupRecord = backupRecord
        self.restartedProcesses = restartedProcesses
        self.reloginRequiredItems = reloginRequiredItems
        self.issues = issues
    }
}
