import Foundation

/// 現在の Mac から 5 カテゴリの設定を読み取り、`PrefSnapSnapshot` を構築するエンジン。
/// すべての外部アクセスはプロトコル経由で行い、権限エラーが発生してもクラッシュせず `issues` として報告する。
public struct SnapshotExporter: Sendable {
    private let commandRunner: CommandRunning
    private let plistStore: PlistStoring
    private let keyboardDetector: KeyboardDetecting
    private let environment: EnvironmentProviding

    public init(
        commandRunner: CommandRunning,
        plistStore: PlistStoring,
        keyboardDetector: KeyboardDetecting,
        environment: EnvironmentProviding = SystemEnvironmentProvider()
    ) {
        self.commandRunner = commandRunner
        self.plistStore = plistStore
        self.keyboardDetector = keyboardDetector
        self.environment = environment
    }

    /// 現在の環境設定をスキャンし、スナップショットと発生した問題一覧を返す。
    public func exportSnapshot() -> ExportReport {
        var systemDefaults: [String: NullableValue<DefaultsValue>] = [:]
        var menuBar: [String: NullableValue<DefaultsValue>] = [:]
        var issues: [ItemIssue] = []

        // 1 & 2. システム基本設定 および メニューバーコントロール
        for descriptor in SettingCatalog.defaultsItems {
            do {
                let value = try readDefaultsValue(for: descriptor)
                let wrapped = NullableValue(value)
                switch descriptor.category {
                case .systemDefaults:
                    systemDefaults[descriptor.id] = wrapped
                case .menuBar:
                    menuBar[descriptor.id] = wrapped
                default:
                    break
                }
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: descriptor.displayName))
                let unset = NullableValue<DefaultsValue>.unset
                if descriptor.category == .systemDefaults {
                    systemDefaults[descriptor.id] = unset
                } else if descriptor.category == .menuBar {
                    menuBar[descriptor.id] = unset
                }
            } catch {
                issues.append(ItemIssue(itemTitle: descriptor.displayName, message: error.localizedDescription, isPermissionError: false))
            }
        }

        // 2-b. com.apple.controlcenter.plist に含まれる動的 NSStatusItem Visible* / VisibleCC * キーの読み取り
        let (dynamicMenuBar, dynamicMenuBarIssues) = readDynamicControlCenterStatusItems()
        for (id, value) in dynamicMenuBar {
            menuBar[id] = value
        }
        issues.append(contentsOf: dynamicMenuBarIssues)

        // 3. システム標準ショートカット（com.apple.symbolichotkeys）
        let (symbolicHotKeys, hotKeyIssues) = readSymbolicHotKeys()
        issues.append(contentsOf: hotKeyIssues)

        // 4. アプリケーションショートカット（NSUserKeyEquivalents）
        let (appShortcuts, appShortcutIssues) = readAppShortcuts()
        issues.append(contentsOf: appShortcutIssues)

        // 5. 修飾キーリマップ（ByHost/.GlobalPreferences + IOKit メタデータ）
        let (modifierMappings, modifierIssues) = readModifierMappings()
        issues.append(contentsOf: modifierIssues)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let snapshot = PrefSnapSnapshot(
            schemaVersion: PrefSnapSnapshot.currentSchemaVersion,
            exportedAt: isoFormatter.string(from: environment.currentDate()),
            sourceHost: environment.currentHostMetadata(),
            systemDefaults: systemDefaults,
            menuBar: menuBar,
            symbolicHotKeys: symbolicHotKeys,
            appShortcuts: appShortcuts,
            modifierMappings: modifierMappings
        )

        return ExportReport(snapshot: snapshot, issues: issues)
    }

    // MARK: - 1 & 2. defaults 読み取り

    private func readDefaultsValue(for descriptor: SettingDescriptor) throws -> DefaultsValue? {
        if descriptor.valueType == .data {
            return try readDefaultsDataValue(for: descriptor)
        }

        var args: [String] = []
        if descriptor.isByHost {
            args.append("-currentHost")
        }
        args.append(contentsOf: ["read", descriptor.domain, descriptor.key])

        let output = try commandRunner.run(executable: "/usr/bin/defaults", arguments: args)
        if output.exitCode != 0 {
            let lowerErr = output.stderr.lowercased()
            if lowerErr.contains("does not exist") || lowerErr.contains("domain") && lowerErr.contains("not found") {
                return nil
            }
            if lowerErr.contains("permission denied") || lowerErr.contains("operation not permitted") || lowerErr.contains("not permitted") {
                throw PrefSnapError.permissionDenied(
                    target: "\(descriptor.domain) (\(descriptor.key))",
                    detail: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            // キー未設定時は defaults が exitCode 1 を返すため、空出力かつエラーが一般的な未存在メッセージなら nil 扱い
            if lowerErr.contains("the domain/default pair of") {
                return nil
            }
            throw PrefSnapError.commandFailed(
                command: (["defaults"] + args).joined(separator: " "),
                exitCode: output.exitCode,
                stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch descriptor.valueType {
        case .bool:
            let lower = trimmed.lowercased()
            if lower == "1" || lower == "true" || lower == "yes" { return .bool(true) }
            if lower == "0" || lower == "false" || lower == "no" { return .bool(false) }
            return nil
        case .int:
            if let intVal = Int(trimmed) {
                return .int(intVal)
            }
            if let doubleVal = Double(trimmed) {
                return .int(Int(doubleVal))
            }
            return nil
        case .double:
            if let doubleVal = Double(trimmed) {
                return .double(doubleVal)
            }
            return nil
        case .string:
            return .string(trimmed)
        case .data:
            return nil
        }
    }

    /// `defaults [-currentHost] export <domain> -` を使い、`Data` 型キーの完全なバイト列を読み取る。
    /// `defaults read` は長い `Data` を `...` で省略するため、`export` の XML plist 出力をパースしてロスレス取得する。
    private func readDefaultsDataValue(for descriptor: SettingDescriptor) throws -> DefaultsValue? {
        var args: [String] = []
        if descriptor.isByHost {
            args.append("-currentHost")
        }
        args.append(contentsOf: ["export", descriptor.domain, "-"])

        let output = try commandRunner.run(executable: "/usr/bin/defaults", arguments: args)
        if output.exitCode != 0 {
            let lowerErr = output.stderr.lowercased()
            if lowerErr.contains("does not exist") || (lowerErr.contains("domain") && lowerErr.contains("not found")) {
                return nil
            }
            if lowerErr.contains("permission denied") || lowerErr.contains("operation not permitted") || lowerErr.contains("not permitted") {
                throw PrefSnapError.permissionDenied(
                    target: "\(descriptor.domain) (\(descriptor.key))",
                    detail: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    settingsURL: SystemPreferencesURL.fullDiskAccess
                )
            }
            return nil
        }

        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let xmlData = output.stdout.data(using: .utf8) else {
            return nil
        }

        let plist = try PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil)
        guard let dict = plist as? [String: Any],
              let rawData = dict[descriptor.key] as? Data
        else {
            return nil
        }
        return .data(rawData)
    }

    // MARK: - 2-b. 動的メニューバー表示キー（com.apple.controlcenter.plist）

    /// 固定カタログ外の `NSStatusItem Visible ...` / `NSStatusItem VisibleCC ...` キーを自動収集する。
    /// macOS 26 (Tahoe) 以降で追加される個別コントロールや `Item-N` 系の表示フラグを漏れなく扱うため。
    private func readDynamicControlCenterStatusItems() -> ([String: NullableValue<DefaultsValue>], [ItemIssue]) {
        let plistURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.controlcenter.plist")
        guard plistStore.fileExists(at: plistURL) else {
            return ([:], [])
        }

        do {
            let dict = try plistStore.readPlistDictionary(at: plistURL)
            var dynamicItems: [String: NullableValue<DefaultsValue>] = [:]
            for key in dict.keys.sorted() {
                guard key.hasPrefix("NSStatusItem Visible ") || key.hasPrefix("NSStatusItem VisibleCC ") else {
                    continue
                }
                guard !SettingCatalog.knownControlCenterNonByHostKeys.contains(key) else {
                    continue
                }
                if let rawValue = dict[key],
                   let parsed = DefaultsValue.fromPropertyListObject(rawValue, expectedType: .bool) {
                    let id = SettingCatalog.dynamicMenuBarStatusItemID(forKey: key)
                    dynamicItems[id] = NullableValue(parsed)
                }
            }
            return (dynamicItems, [])
        } catch let error as PrefSnapError {
            return ([:], [makeIssue(from: error, itemTitle: "メニューバー表示設定 (com.apple.controlcenter.plist)")])
        } catch {
            return ([:], [ItemIssue(itemTitle: "メニューバー表示設定", message: error.localizedDescription, isPermissionError: false)])
        }
    }

    // MARK: - 3. システム標準ショートカット

    private func readSymbolicHotKeys() -> ([String: NullableValue<SymbolicHotKeyEntry>], [ItemIssue]) {
        var result: [String: NullableValue<SymbolicHotKeyEntry>] = [:]
        for item in SettingCatalog.symbolicHotKeys {
            result[item.id] = .unset
        }

        let plistURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.symbolichotkeys.plist")
        guard plistStore.fileExists(at: plistURL) else {
            return (result, [])
        }

        do {
            let root = try plistStore.readPlistDictionary(at: plistURL)
            guard let hotKeysDict = root["AppleSymbolicHotKeys"] as? [String: Any] else {
                return (result, [])
            }
            for descriptor in SettingCatalog.symbolicHotKeys {
                if let entryDict = hotKeysDict[descriptor.id] as? [String: Any],
                   let entry = SymbolicHotKeyEntry.fromPlistDictionary(entryDict) {
                    result[descriptor.id] = NullableValue(entry)
                }
            }
            return (result, [])
        } catch let error as PrefSnapError {
            return (result, [makeIssue(from: error, itemTitle: "システム標準ショートカット (com.apple.symbolichotkeys)")])
        } catch {
            return (result, [ItemIssue(itemTitle: "システム標準ショートカット", message: error.localizedDescription, isPermissionError: false)])
        }
    }

    // MARK: - 4. アプリケーションショートカット

    private func readAppShortcuts() -> ([String: [String: String]], [ItemIssue]) {
        var result: [String: [String: String]] = [:]
        var issues: [ItemIssue] = []

        // NSGlobalDomain（全アプリケーション共通ショートカット）
        let globalPlistURL = plistStore.preferencesDirectory.appendingPathComponent(".GlobalPreferences.plist")
        if plistStore.fileExists(at: globalPlistURL) {
            do {
                let dict = try plistStore.readPlistDictionary(at: globalPlistURL)
                if let equivalents = dict["NSUserKeyEquivalents"] as? [String: String], !equivalents.isEmpty {
                    result["NSGlobalDomain"] = equivalents
                }
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: "全アプリ共通ショートカット (NSGlobalDomain)"))
            } catch {
                issues.append(ItemIssue(itemTitle: "全アプリ共通ショートカット", message: error.localizedDescription, isPermissionError: false))
            }
        }

        // com.apple.universalaccess の com.apple.custommenu.apps に登録された各アプリ
        let universalAccessURL = plistStore.preferencesDirectory.appendingPathComponent("com.apple.universalaccess.plist")
        var registeredApps: [String] = []
        if plistStore.fileExists(at: universalAccessURL) {
            do {
                let uaDict = try plistStore.readPlistDictionary(at: universalAccessURL)
                if let apps = uaDict["com.apple.custommenu.apps"] as? [String] {
                    registeredApps = apps
                }
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: "アプリショートカット一覧 (com.apple.universalaccess)"))
            } catch {
                issues.append(ItemIssue(itemTitle: "アプリショートカット一覧", message: error.localizedDescription, isPermissionError: false))
            }
        }

        for bundleID in Set(registeredApps).sorted() where bundleID != "NSGlobalDomain" {
            let appPlistURL = plistStore.preferencesDirectory.appendingPathComponent("\(bundleID).plist")
            guard plistStore.fileExists(at: appPlistURL) else { continue }
            do {
                let appDict = try plistStore.readPlistDictionary(at: appPlistURL)
                if let equivalents = appDict["NSUserKeyEquivalents"] as? [String: String], !equivalents.isEmpty {
                    result[bundleID] = equivalents
                }
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: "アプリショートカット (\(bundleID))"))
            } catch {
                issues.append(ItemIssue(itemTitle: "アプリショートカット (\(bundleID))", message: error.localizedDescription, isPermissionError: false))
            }
        }

        return (result, issues)
    }

    // MARK: - 5. 修飾キーリマップ（ByHost/.GlobalPreferences + IOKit）

    private func readModifierMappings() -> ([ModifierMappingEntry], [ItemIssue]) {
        var issues: [ItemIssue] = []

        var connectedByID: [String: ConnectedKeyboard] = [:]
        do {
            let keyboards = try keyboardDetector.connectedKeyboards()
            for kb in keyboards {
                connectedByID[kb.id] = kb
            }
        } catch let error as PrefSnapError {
            issues.append(makeIssue(from: error, itemTitle: "接続キーボード検出 (IOKit)"))
        } catch {
            issues.append(ItemIssue(itemTitle: "接続キーボード検出", message: error.localizedDescription, isPermissionError: false))
        }

        let byHostFiles: [URL]
        do {
            byHostFiles = try plistStore.listFiles(in: plistStore.byHostDirectory)
        } catch let error as PrefSnapError {
            issues.append(makeIssue(from: error, itemTitle: "修飾キー設定 (ByHost)"))
            return ([], issues)
        } catch {
            issues.append(ItemIssue(itemTitle: "修飾キー設定 (ByHost)", message: error.localizedDescription, isPermissionError: false))
            return ([], issues)
        }

        let globalByHostFiles = byHostFiles
            .filter { $0.lastPathComponent.hasPrefix(".GlobalPreferences.") && $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var entriesByDeviceID: [String: ModifierMappingEntry] = [:]
        let prefix = "com.apple.keyboard.modifiermapping."

        for fileURL in globalByHostFiles {
            do {
                let dict = try plistStore.readPlistDictionary(at: fileURL)
                for (key, value) in dict where key.hasPrefix(prefix) {
                    guard let (vendorID, productID) = Self.parseModifierMappingKey(key) else {
                        continue
                    }
                    let pairs = Self.parseModifierPairs(from: value)
                    let deviceKey = "\(vendorID)-\(productID)"
                    let metadata = connectedByID[deviceKey]
                    let entry = ModifierMappingEntry(
                        vendorID: vendorID,
                        productID: productID,
                        deviceName: metadata?.deviceName ?? "Unknown Keyboard (\(deviceKey))",
                        isBuiltIn: metadata?.isBuiltIn ?? false,
                        mappings: pairs
                    )
                    entriesByDeviceID[deviceKey] = entry
                }
            } catch let error as PrefSnapError {
                issues.append(makeIssue(from: error, itemTitle: "修飾キー設定 (\(fileURL.lastPathComponent))"))
            } catch {
                issues.append(ItemIssue(itemTitle: "修飾キー設定 (\(fileURL.lastPathComponent))", message: error.localizedDescription, isPermissionError: false))
            }
        }

        let sortedEntries = entriesByDeviceID.values.sorted { lhs, rhs in
            if lhs.vendorID != rhs.vendorID {
                return lhs.vendorID < rhs.vendorID
            }
            return lhs.productID < rhs.productID
        }
        return (sortedEntries, issues)
    }

    /// `com.apple.keyboard.modifiermapping.{VendorID}-{ProductID}-0` から `(vendorID, productID)` を抽出する。
    static func parseModifierMappingKey(_ key: String) -> (Int, Int)? {
        let prefix = "com.apple.keyboard.modifiermapping."
        guard key.hasPrefix(prefix) else { return nil }
        let suffix = String(key.dropFirst(prefix.count))
        let parts = suffix.split(separator: "-")
        guard parts.count == 3,
              let vendorID = Int(parts[0]),
              let productID = Int(parts[1]),
              parts[2] == "0"
        else {
            return nil
        }
        return (vendorID, productID)
    }

    /// plist 内の修飾キー配列から `[ModifierKeyPair]` を構築する。
    static func parseModifierPairs(from rawValue: Any) -> [ModifierKeyPair] {
        guard let rawArray = rawValue as? [[String: Any]] else { return [] }
        var pairs: [ModifierKeyPair] = []
        for item in rawArray {
            guard
                let srcNum = item["HIDKeyboardModifierMappingSrc"] as? NSNumber,
                let dstNum = item["HIDKeyboardModifierMappingDst"] as? NSNumber
            else {
                continue
            }
            pairs.append(ModifierKeyPair(src: srcNum.uint64Value, dst: dstNum.uint64Value))
        }
        return pairs
    }

    private func makeIssue(from error: PrefSnapError, itemTitle: String) -> ItemIssue {
        switch error {
        case let .permissionDenied(_, detail, url):
            return ItemIssue(
                itemTitle: itemTitle,
                message: detail,
                isPermissionError: true,
                systemSettingsURL: url
            )
        default:
            return ItemIssue(
                itemTitle: itemTitle,
                message: error.localizedDescription,
                isPermissionError: false
            )
        }
    }
}
