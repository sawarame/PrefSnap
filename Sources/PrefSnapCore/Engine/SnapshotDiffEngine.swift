import Foundation

/// 現在の Mac 設定とインポート対象 JSON スナップショットを比較（Dry-run）し、
/// 変更が発生する項目のみを抽出する差分計算エンジン。
public struct SnapshotDiffEngine: Sendable {
    public init() {}

    /// 現在のスナップショット・現在接続中のキーボードとインポート対象を比較し、差分レポートを返す。
    /// - Parameter resetUnlistedConnectedModifiers: `true` の場合（ロールバック時）、現在接続中のキーボードにリマップがあるのに
    ///   復元先スナップショットに含まれない項目を「リマップなし（削除）」へ戻す差分として生成する。
    public func computeDiff(
        current: PrefSnapSnapshot,
        target: PrefSnapSnapshot,
        connectedKeyboards: [ConnectedKeyboard],
        existingIssues: [ItemIssue] = [],
        resetUnlistedConnectedModifiers: Bool = false
    ) -> DiffReport {
        var items: [DiffItem] = []

        // 1. システム基本設定およびメニューバーコントロール
        for descriptor in SettingCatalog.defaultsItems {
            let currentDict = descriptor.category == .systemDefaults ? current.systemDefaults : current.menuBar
            let targetDict = descriptor.category == .systemDefaults ? target.systemDefaults : target.menuBar

            // インポート JSON にキー自体が含まれていない項目は対象外とする
            guard let targetWrapped = targetDict[descriptor.id] else { continue }
            let currentVal = currentDict[descriptor.id]?.value?.normalized(for: descriptor.valueType)
            let targetVal = targetWrapped.value?.normalized(for: descriptor.valueType)

            guard currentVal != targetVal else { continue }

            items.append(
                DiffItem(
                    id: "defaults:\(descriptor.id)",
                    category: descriptor.category,
                    subcategoryLabel: descriptor.subcategory.rawValue,
                    title: descriptor.displayName,
                    detail: "\(descriptor.domain) / \(descriptor.key)\(descriptor.isByHost ? " (ByHost)" : "")",
                    beforeDisplay: descriptor.formatDisplayValue(currentVal, nilLabel: "未設定（初期値）"),
                    afterDisplay: descriptor.formatDisplayValue(targetVal, nilLabel: "未設定へ戻す（削除）"),
                    action: .defaultsSetting(descriptor: descriptor, newValue: targetVal),
                    restartTargets: descriptor.restartTargets,
                    requiresRelogin: descriptor.requiresRelogin,
                    isSelected: true
                )
            )
        }

        // 1-b. 動的検出されたメニューバー表示項目（menubar.statusitem.dynamic.*）
        let dynamicMenuBarIDs = target.menuBar.keys
            .filter { $0.hasPrefix(SettingCatalog.dynamicStatusItemIDPrefix) }
            .sorted()
        for dynamicID in dynamicMenuBarIDs {
            guard let descriptor = SettingCatalog.dynamicMenuBarDescriptor(forID: dynamicID),
                  let targetWrapped = target.menuBar[dynamicID]
            else {
                continue
            }
            let currentVal = current.menuBar[dynamicID]?.value
            let targetVal = targetWrapped.value
            guard currentVal != targetVal else { continue }

            items.append(
                DiffItem(
                    id: "defaults:\(descriptor.id)",
                    category: descriptor.category,
                    subcategoryLabel: descriptor.subcategory.rawValue,
                    title: descriptor.displayName,
                    detail: "\(descriptor.domain) / \(descriptor.key)",
                    beforeDisplay: descriptor.formatDisplayValue(currentVal, nilLabel: "未設定（初期値）"),
                    afterDisplay: descriptor.formatDisplayValue(targetVal, nilLabel: "未設定へ戻す（削除）"),
                    action: .defaultsSetting(descriptor: descriptor, newValue: targetVal),
                    restartTargets: descriptor.restartTargets,
                    requiresRelogin: descriptor.requiresRelogin,
                    isSelected: true
                )
            )
        }

        // 2. システム標準ショートカット（AppleSymbolicHotKeys）
        let allSymbolicIDs = Set(target.symbolicHotKeys.keys).sorted { lhs, rhs in
            (Int(lhs) ?? Int.max) < (Int(rhs) ?? Int.max)
        }
        for keyID in allSymbolicIDs {
            guard let targetWrapped = target.symbolicHotKeys[keyID] else { continue }
            let currentVal = current.symbolicHotKeys[keyID]?.value
            let targetVal = targetWrapped.value

            guard currentVal != targetVal else { continue }

            let descriptor = SettingCatalog.symbolicHotKeysByID[keyID]
            items.append(
                DiffItem(
                    id: "symbolichotkey:\(keyID)",
                    category: .symbolicHotKeys,
                    subcategoryLabel: "標準ショートカット",
                    title: descriptor?.displayName ?? "ショートカット ID: \(keyID)",
                    detail: "com.apple.symbolichotkeys / AppleSymbolicHotKeys[\(keyID)]",
                    beforeDisplay: currentVal?.displayString ?? "未設定（初期値）",
                    afterDisplay: targetVal?.displayString ?? "未設定へ戻す（削除）",
                    action: .symbolicHotKey(id: keyID, newValue: targetVal),
                    restartTargets: [],
                    requiresRelogin: true,
                    isSelected: true
                )
            )
        }

        // 3. アプリケーションショートカット（NSUserKeyEquivalents）
        let allAppDomains = Set(current.appShortcuts.keys).union(target.appShortcuts.keys).sorted()
        for domain in allAppDomains {
            let currentMap = current.appShortcuts[domain] ?? [:]
            let targetMap = target.appShortcuts[domain] ?? [:]
            guard currentMap != targetMap else { continue }

            let domainTitle = domain == "NSGlobalDomain" ? "すべてのアプリケーション (NSGlobalDomain)" : domain
            items.append(
                DiffItem(
                    id: "appshortcut:\(domain)",
                    category: .appShortcuts,
                    subcategoryLabel: "アプリショートカット",
                    title: domainTitle,
                    detail: "\(domain) / NSUserKeyEquivalents",
                    beforeDisplay: Self.formatAppShortcuts(currentMap),
                    afterDisplay: Self.formatAppShortcuts(targetMap),
                    action: .appShortcut(domain: domain, shortcuts: targetMap),
                    restartTargets: [],
                    requiresRelogin: true,
                    isSelected: true
                )
            )
        }

        // 4. 修飾キーリマップ（IOHIDManager 接続キーボード照合ルール）
        let connectedByID = Dictionary(uniqueKeysWithValues: connectedKeyboards.map { ($0.id, $0) })
        let builtInKeyboards = connectedKeyboards.filter(\.isBuiltIn)
        let currentModifierByID = Dictionary(uniqueKeysWithValues: current.modifierMappings.map { ($0.id, $0) })

        for targetEntry in target.modifierMappings {
            if let exactKeyboard = connectedByID[targetEntry.id] {
                let currentMappings = currentModifierByID[exactKeyboard.id]?.mappings ?? []
                guard currentMappings != targetEntry.mappings else { continue }

                let currentEntry = ModifierMappingEntry(
                    vendorID: exactKeyboard.vendorID,
                    productID: exactKeyboard.productID,
                    deviceName: exactKeyboard.deviceName,
                    isBuiltIn: exactKeyboard.isBuiltIn,
                    mappings: currentMappings
                )
                items.append(
                    DiffItem(
                        id: "modifier:\(targetEntry.id)",
                        category: .modifierMappings,
                        subcategoryLabel: exactKeyboard.isBuiltIn ? "内蔵キーボード" : "外付けキーボード",
                        title: "\(exactKeyboard.deviceName) (\(targetEntry.id))",
                        detail: "接続一致: \(exactKeyboard.preferenceKey)",
                        beforeDisplay: currentEntry.mappingsDisplayString,
                        afterDisplay: targetEntry.mappingsDisplayString,
                        action: .modifierMapping(
                            targetVendorID: exactKeyboard.vendorID,
                            targetProductID: exactKeyboard.productID,
                            targetDeviceName: exactKeyboard.deviceName,
                            mappings: targetEntry.mappings
                        ),
                        restartTargets: [],
                        requiresRelogin: true,
                        modifierMatchStatus: .exactMatch(exactKeyboard),
                        isSelected: true
                    )
                )
            } else if targetEntry.isBuiltIn, let targetBuiltIn = builtInKeyboards.first {
                // 例外ルール: isBuiltIn == true で ProductID 不一致だが、移行先に別の内蔵キーボードがある場合
                let currentMappings = currentModifierByID[targetBuiltIn.id]?.mappings ?? []
                guard currentMappings != targetEntry.mappings else { continue }

                let currentEntry = ModifierMappingEntry(
                    vendorID: targetBuiltIn.vendorID,
                    productID: targetBuiltIn.productID,
                    deviceName: targetBuiltIn.deviceName,
                    isBuiltIn: true,
                    mappings: currentMappings
                )
                items.append(
                    DiffItem(
                        id: "modifier:\(targetEntry.id)->\(targetBuiltIn.id)",
                        category: .modifierMappings,
                        subcategoryLabel: "内蔵キーボード（モデル差異あり）",
                        title: "\(targetEntry.deviceName) → \(targetBuiltIn.deviceName)",
                        detail: "移行元(\(targetEntry.id))と ProductID 不一致。オプション選択でこの Mac の内蔵キーボード(\(targetBuiltIn.id))へ適用可能",
                        beforeDisplay: currentEntry.mappingsDisplayString,
                        afterDisplay: targetEntry.mappingsDisplayString,
                        action: .modifierMapping(
                            targetVendorID: targetBuiltIn.vendorID,
                            targetProductID: targetBuiltIn.productID,
                            targetDeviceName: targetBuiltIn.deviceName,
                            mappings: targetEntry.mappings
                        ),
                        restartTargets: [],
                        requiresRelogin: true,
                        modifierMatchStatus: .builtInFallbackAvailable(
                            sourceDeviceName: targetEntry.deviceName,
                            targetBuiltIn: targetBuiltIn
                        ),
                        isSelected: false,
                        applyToBuiltInKeyboard: false
                    )
                )
            } else {
                // 一致するキーボードが未接続の場合は「未接続のためスキップ」として表示し適用除外
                items.append(
                    DiffItem(
                        id: "modifier:disconnected:\(targetEntry.id)",
                        category: .modifierMappings,
                        subcategoryLabel: targetEntry.isBuiltIn ? "内蔵キーボード" : "外付けキーボード",
                        title: "\(targetEntry.deviceName) (\(targetEntry.id))",
                        detail: "未接続のためスキップ（このキーボードは現在接続されていません）",
                        beforeDisplay: "未接続",
                        afterDisplay: targetEntry.mappingsDisplayString,
                        action: .modifierMapping(
                            targetVendorID: targetEntry.vendorID,
                            targetProductID: targetEntry.productID,
                            targetDeviceName: targetEntry.deviceName,
                            mappings: targetEntry.mappings
                        ),
                        restartTargets: [],
                        requiresRelogin: true,
                        modifierMatchStatus: .disconnected,
                        isSelected: false
                    )
                )
            }
        }

        // ロールバック時: バックアップに存在しない（＝適用前はリマップ未設定だった）接続中キーボードのリマップを元に戻す
        if resetUnlistedConnectedModifiers {
            let targetModifierIDs = Set(target.modifierMappings.map(\.id))
            for currentEntry in current.modifierMappings where !currentEntry.mappings.isEmpty {
                guard !targetModifierIDs.contains(currentEntry.id),
                      let connected = connectedByID[currentEntry.id]
                else {
                    continue
                }
                items.append(
                    DiffItem(
                        id: "modifier:reset:\(currentEntry.id)",
                        category: .modifierMappings,
                        subcategoryLabel: connected.isBuiltIn ? "内蔵キーボード" : "外付けキーボード",
                        title: "\(connected.deviceName) (\(currentEntry.id))",
                        detail: "バックアップ時点の未設定（標準）状態へ戻す",
                        beforeDisplay: currentEntry.mappingsDisplayString,
                        afterDisplay: "リマップなし（標準）",
                        action: .modifierMapping(
                            targetVendorID: connected.vendorID,
                            targetProductID: connected.productID,
                            targetDeviceName: connected.deviceName,
                            mappings: []
                        ),
                        restartTargets: [],
                        requiresRelogin: true,
                        modifierMatchStatus: .exactMatch(connected),
                        isSelected: true
                    )
                )
            }
        }

        return DiffReport(
            items: items,
            connectedKeyboards: connectedKeyboards,
            issues: existingIssues
        )
    }

    private static func formatAppShortcuts(_ map: [String: String]) -> String {
        if map.isEmpty {
            return "未設定"
        }
        return map.keys.sorted().map { key in
            "\(key): \(map[key] ?? "")"
        }.joined(separator: " / ")
    }
}
