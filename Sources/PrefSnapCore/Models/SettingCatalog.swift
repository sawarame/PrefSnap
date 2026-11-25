import Foundation

/// 設定カテゴリの分類。
public enum SettingCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case systemDefaults = "systemDefaults"
    case menuBar = "menuBar"
    case symbolicHotKeys = "symbolicHotKeys"
    case appShortcuts = "appShortcuts"
    case modifierMappings = "modifierMappings"

    /// UI 表示用の日本語カテゴリ名。
    public var displayName: String {
        switch self {
        case .systemDefaults: return "システム基本設定"
        case .menuBar: return "メニューバーコントロール"
        case .symbolicHotKeys: return "システム標準ショートカット"
        case .appShortcuts: return "アプリケーションショートカット"
        case .modifierMappings: return "修飾キーのリマップ"
        }
    }
}

/// プリセット項目が属するサブカテゴリ（UI でのグルーピング表示用）。
public enum SettingSubcategory: String, CaseIterable, Codable, Hashable, Sendable {
    case dock = "Dock"
    case finder = "Finder"
    case keyboardTrackpad = "キーボード / トラックパッド"
    case screenshot = "スクリーンショット"
    case controlCenter = "コントロールセンター"
    case clock = "メニューバー時計"
}

/// プリセット項目の期待データ型。
public enum SettingValueType: String, Codable, Equatable, Sendable {
    case bool
    case int
    case double
    case string
}

/// 設定適用後に再起動が必要な macOS プロセス。
public enum RestartTarget: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case dock = "Dock"
    case finder = "Finder"
    case controlCenter = "ControlCenter"
    case systemUIServer = "SystemUIServer"

    public static func < (lhs: RestartTarget, rhs: RestartTarget) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// プリセット対象となる `defaults` 設定項目の定義。
public struct SettingDescriptor: Identifiable, Equatable, Hashable, Sendable {
    /// JSON キーとして使われる一意識別子（例: `dock.autohide`）
    public let id: String
    public let category: SettingCategory
    public let subcategory: SettingSubcategory
    public let displayName: String
    public let description: String
    /// 対象ドメイン（例: `com.apple.dock`, `NSGlobalDomain`, `com.apple.controlcenter`）
    public let domain: String
    /// ドメイン内のキー名（例: `autohide`）
    public let key: String
    public let valueType: SettingValueType
    /// `-currentHost`（`ByHost`）を対象とするかどうか
    public let isByHost: Bool
    /// 変更後に再起動が必要なプロセス
    public let restartTargets: Set<RestartTarget>
    /// 変更反映のために再ログインが必要かどうか
    public let requiresRelogin: Bool

    public init(
        id: String,
        category: SettingCategory,
        subcategory: SettingSubcategory,
        displayName: String,
        description: String,
        domain: String,
        key: String,
        valueType: SettingValueType,
        isByHost: Bool = false,
        restartTargets: Set<RestartTarget> = [],
        requiresRelogin: Bool = false
    ) {
        self.id = id
        self.category = category
        self.subcategory = subcategory
        self.displayName = displayName
        self.description = description
        self.domain = domain
        self.key = key
        self.valueType = valueType
        self.isByHost = isByHost
        self.restartTargets = restartTargets
        self.requiresRelogin = requiresRelogin
    }
}

/// `com.apple.symbolichotkeys` の対象ショートカット ID 定義。
public struct SymbolicHotKeyDescriptor: Identifiable, Equatable, Hashable, Sendable {
    /// `AppleSymbolicHotKeys` 辞書内の文字列 ID（例: `"64"`）
    public let id: String
    public let displayName: String
    public let description: String

    public init(id: String, displayName: String, description: String) {
        self.id = id
        self.displayName = displayName
        self.description = description
    }
}

/// MVP でサポートする全プリセット項目のカタログ定義。
public enum SettingCatalog {
    /// システム基本設定（34 項目）＋メニューバーコントロール（8 項目）＝計 42 項目。
    public static let defaultsItems: [SettingDescriptor] = dockItems + finderItems + keyboardTrackpadItems + screenshotItems + menuBarItems

    /// ID からプリセット定義を引く辞書。
    public static let defaultsItemsByID: [String: SettingDescriptor] = Dictionary(
        uniqueKeysWithValues: defaultsItems.map { ($0.id, $0) }
    )

    /// Dock 関連（10 項目）
    public static let dockItems: [SettingDescriptor] = [
        SettingDescriptor(
            id: "dock.tilesize",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "Dock アイコンサイズ",
            description: "Dock に表示されるアイコンの基本サイズ（ピクセル）",
            domain: "com.apple.dock",
            key: "tilesize",
            valueType: .int,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.orientation",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "Dock の配置場所",
            description: "画面上の表示位置（bottom / left / right）",
            domain: "com.apple.dock",
            key: "orientation",
            valueType: .string,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.autohide",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "Dock を自動的に隠す／表示",
            description: "使用していないときに Dock を自動で隠す設定",
            domain: "com.apple.dock",
            key: "autohide",
            valueType: .bool,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.autohideDelay",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "Dock 自動表示の遅延時間",
            description: "画面端にカーソルを合わせてから Dock が出るまでの遅延（秒）",
            domain: "com.apple.dock",
            key: "autohide-delay",
            valueType: .double,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.autohideTimeModifier",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "Dock アニメーション速度係数",
            description: "Dock の表示・非表示アニメーション時間倍率",
            domain: "com.apple.dock",
            key: "autohide-time-modifier",
            valueType: .double,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.showRecents",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "最近使ったアプリを Dock に表示",
            description: "最近使用したアプリケーション欄の表示有無",
            domain: "com.apple.dock",
            key: "show-recents",
            valueType: .bool,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.magnification",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "Dock アイコン拡大",
            description: "カーソルを合わせたアイコンの拡大効果を有効にする",
            domain: "com.apple.dock",
            key: "magnification",
            valueType: .bool,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.largesize",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "Dock 拡大時の最大サイズ",
            description: "拡大有効時の最大アイコンサイズ（ピクセル）",
            domain: "com.apple.dock",
            key: "largesize",
            valueType: .int,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.mineffect",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "ウィンドウをしまうときのエフェクト",
            description: "genie（ジニー）または scale（スケール）",
            domain: "com.apple.dock",
            key: "mineffect",
            valueType: .string,
            restartTargets: [.dock]
        ),
        SettingDescriptor(
            id: "dock.minimizeToApplication",
            category: .systemDefaults,
            subcategory: .dock,
            displayName: "ウィンドウをアプリアイコンにしまう",
            description: "最小化ウィンドウをアプリアイコン内に格納する",
            domain: "com.apple.dock",
            key: "minimize-to-application",
            valueType: .bool,
            restartTargets: [.dock]
        )
    ]

    /// Finder 関連（10 項目）
    public static let finderItems: [SettingDescriptor] = [
        SettingDescriptor(
            id: "finder.showAllExtensions",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "すべてのファイル名拡張子を表示",
            description: "Finder やダイアログでファイルの拡張子を常に表示する",
            domain: "NSGlobalDomain",
            key: "AppleShowAllExtensions",
            valueType: .bool,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.showAllFiles",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "隠しファイルを表示",
            description: "ドットファイルなどの不可視ファイルを Finder に表示する",
            domain: "com.apple.finder",
            key: "AppleShowAllFiles",
            valueType: .bool,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.showPathbar",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "パスバーを表示",
            description: "Finder ウィンドウ下部に現在ディレクトリのパスを表示する",
            domain: "com.apple.finder",
            key: "ShowPathbar",
            valueType: .bool,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.showStatusBar",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "ステータスバーを表示",
            description: "Finder ウィンドウ下部に項目数や空き容量を表示する",
            domain: "com.apple.finder",
            key: "ShowStatusBar",
            valueType: .bool,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.preferredViewStyle",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "デフォルトの表示形式",
            description: "icnv（アイコン）/ Nlsv（リスト）/ clmv（カラム）/ glyv（ギャラリー）",
            domain: "com.apple.finder",
            key: "FXPreferredViewStyle",
            valueType: .string,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.defaultSearchScope",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "デフォルトの検索範囲",
            description: "SCcf（現在のフォルダ）/ SCev（この Mac）/ SCsp（前回の範囲）",
            domain: "com.apple.finder",
            key: "FXDefaultSearchScope",
            valueType: .string,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.warnOnExtensionChange",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "拡張子変更前の警告",
            description: "ファイル拡張子を変更する際に確認ダイアログを表示する",
            domain: "com.apple.finder",
            key: "FXEnableExtensionChangeWarning",
            valueType: .bool,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.foldersOnTop",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "フォルダを先頭に並べる",
            description: "名前順ソート時にフォルダをファイルより上に配置する",
            domain: "com.apple.finder",
            key: "_FXSortFoldersFirst",
            valueType: .bool,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.newWindowTarget",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "新規 Finder ウィンドウの表示先",
            description: "PfHm（ホーム）/ PfDe（デスクトップ）/ PfLo（指定場所）等",
            domain: "com.apple.finder",
            key: "NewWindowTarget",
            valueType: .string,
            restartTargets: [.finder]
        ),
        SettingDescriptor(
            id: "finder.showTabView",
            category: .systemDefaults,
            subcategory: .finder,
            displayName: "タブバーを表示",
            description: "Finder のタブバーを常に表示する",
            domain: "com.apple.finder",
            key: "ShowTabView",
            valueType: .bool,
            restartTargets: [.finder]
        )
    ]

    /// キーボード・トラックパッド関連（10 項目）
    public static let keyboardTrackpadItems: [SettingDescriptor] = [
        SettingDescriptor(
            id: "keyboard.keyRepeat",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "キーのリピート速度",
            description: "数値が小さいほど高速（例: 2）",
            domain: "NSGlobalDomain",
            key: "KeyRepeat",
            valueType: .int,
            requiresRelogin: true
        ),
        SettingDescriptor(
            id: "keyboard.initialKeyRepeat",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "リピート入力認識までの時間",
            description: "数値が小さいほど短い（例: 15）",
            domain: "NSGlobalDomain",
            key: "InitialKeyRepeat",
            valueType: .int,
            requiresRelogin: true
        ),
        SettingDescriptor(
            id: "keyboard.pressAndHoldEnabled",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "長押し時のアクセント文字候補",
            description: "false にするとキー長押しで連続入力が有効になる",
            domain: "NSGlobalDomain",
            key: "ApplePressAndHoldEnabled",
            valueType: .bool,
            requiresRelogin: true
        ),
        SettingDescriptor(
            id: "keyboard.fullKeyboardAccess",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "キーボードナビゲーション（Tab 移動）",
            description: "2 または 3 でダイアログのすべてのコントロールへ Tab 移動可能",
            domain: "NSGlobalDomain",
            key: "AppleKeyboardUIMode",
            valueType: .int,
            requiresRelogin: true
        ),
        SettingDescriptor(
            id: "keyboard.autoCorrect",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "自動スペル修正",
            description: "入力中の英単語スペルを自動修正する",
            domain: "NSGlobalDomain",
            key: "NSAutomaticSpellingCorrectionEnabled",
            valueType: .bool
        ),
        SettingDescriptor(
            id: "keyboard.smartQuotes",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "スマート引用符",
            description: "直線引用符を自動でカーブ引用符へ変換する",
            domain: "NSGlobalDomain",
            key: "NSAutomaticQuoteSubstitutionEnabled",
            valueType: .bool
        ),
        SettingDescriptor(
            id: "keyboard.smartDashes",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "スマートダッシュ",
            description: "連続ハイフンを自動でダッシュへ変換する",
            domain: "NSGlobalDomain",
            key: "NSAutomaticDashSubstitutionEnabled",
            valueType: .bool
        ),
        SettingDescriptor(
            id: "trackpad.tapToClick",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "トラックパッドのタップでクリック",
            description: "内蔵マルチタッチトラックパッドでのタップクリックを有効化",
            domain: "com.apple.AppleMultitouchTrackpad",
            key: "Clicking",
            valueType: .bool,
            requiresRelogin: true
        ),
        SettingDescriptor(
            id: "trackpad.trackingSpeed",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "トラックパッドの軌跡の速さ",
            description: "ポインタ移動速度のスケール値（0.0 〜 3.0 程度）",
            domain: "NSGlobalDomain",
            key: "com.apple.trackpad.scaling",
            valueType: .double,
            requiresRelogin: true
        ),
        SettingDescriptor(
            id: "trackpad.naturalScroll",
            category: .systemDefaults,
            subcategory: .keyboardTrackpad,
            displayName: "ナチュラルなスクロール",
            description: "指の動きに合わせてコンテンツをスクロールする",
            domain: "NSGlobalDomain",
            key: "com.apple.swipescrolldirection",
            valueType: .bool,
            requiresRelogin: true
        )
    ]

    /// スクリーンショット関連（4 項目）
    public static let screenshotItems: [SettingDescriptor] = [
        SettingDescriptor(
            id: "screencapture.location",
            category: .systemDefaults,
            subcategory: .screenshot,
            displayName: "スクリーンショット保存先",
            description: "スクリーンショット画像を保存するフォルダパス",
            domain: "com.apple.screencapture",
            key: "location",
            valueType: .string,
            restartTargets: [.systemUIServer]
        ),
        SettingDescriptor(
            id: "screencapture.type",
            category: .systemDefaults,
            subcategory: .screenshot,
            displayName: "スクリーンショット形式",
            description: "保存ファイル形式（png / jpg / pdf / tiff 等）",
            domain: "com.apple.screencapture",
            key: "type",
            valueType: .string,
            restartTargets: [.systemUIServer]
        ),
        SettingDescriptor(
            id: "screencapture.disableShadow",
            category: .systemDefaults,
            subcategory: .screenshot,
            displayName: "ウィンドウ撮影時の影を無効化",
            description: "ウィンドウキャプチャからドロップシャドウを除外する",
            domain: "com.apple.screencapture",
            key: "disable-shadow",
            valueType: .bool,
            restartTargets: [.systemUIServer]
        ),
        SettingDescriptor(
            id: "screencapture.showThumbnail",
            category: .systemDefaults,
            subcategory: .screenshot,
            displayName: "撮影後のフローティングサムネイル",
            description: "スクリーンショット撮影後に右下にプレビューを表示する",
            domain: "com.apple.screencapture",
            key: "show-thumbnail",
            valueType: .bool,
            restartTargets: [.systemUIServer]
        )
    ]

    /// メニューバーコントロール関連（8 項目）
    /// `com.apple.controlcenter` は必ず `-currentHost` / `ByHost` を対象とする。
    public static let menuBarItems: [SettingDescriptor] = [
        SettingDescriptor(
            id: "menubar.controlcenter.wifi",
            category: .menuBar,
            subcategory: .controlCenter,
            displayName: "メニューバー: Wi-Fi 表示",
            description: "18 = 表示 / 24 = 非表示（ByHost）",
            domain: "com.apple.controlcenter",
            key: "WiFi",
            valueType: .int,
            isByHost: true,
            restartTargets: [.controlCenter, .systemUIServer]
        ),
        SettingDescriptor(
            id: "menubar.controlcenter.bluetooth",
            category: .menuBar,
            subcategory: .controlCenter,
            displayName: "メニューバー: Bluetooth 表示",
            description: "18 = 表示 / 24 = 非表示（ByHost）",
            domain: "com.apple.controlcenter",
            key: "Bluetooth",
            valueType: .int,
            isByHost: true,
            restartTargets: [.controlCenter, .systemUIServer]
        ),
        SettingDescriptor(
            id: "menubar.controlcenter.sound",
            category: .menuBar,
            subcategory: .controlCenter,
            displayName: "メニューバー: サウンド表示",
            description: "18 = 常に表示 / 2 = アクティブ時のみ / 8 = 非表示（ByHost）",
            domain: "com.apple.controlcenter",
            key: "Sound",
            valueType: .int,
            isByHost: true,
            restartTargets: [.controlCenter, .systemUIServer]
        ),
        SettingDescriptor(
            id: "menubar.controlcenter.batteryShowPercentage",
            category: .menuBar,
            subcategory: .controlCenter,
            displayName: "メニューバー: バッテリー残量（%）を表示",
            description: "バッテリーアイコンの横にパーセント数値を表示する（ByHost）",
            domain: "com.apple.controlcenter",
            key: "BatteryShowPercentage",
            valueType: .bool,
            isByHost: true,
            restartTargets: [.controlCenter, .systemUIServer]
        ),
        SettingDescriptor(
            id: "menubar.controlcenter.nowPlaying",
            category: .menuBar,
            subcategory: .controlCenter,
            displayName: "メニューバー: 再生中表示",
            description: "18 = 常に表示 / 2 = アクティブ時のみ / 8 = 非表示（ByHost）",
            domain: "com.apple.controlcenter",
            key: "NowPlaying",
            valueType: .int,
            isByHost: true,
            restartTargets: [.controlCenter, .systemUIServer]
        ),
        SettingDescriptor(
            id: "menubar.clock.showDayOfWeek",
            category: .menuBar,
            subcategory: .clock,
            displayName: "時計: 曜日を表示",
            description: "メニューバーの時計に曜日を表示する",
            domain: "com.apple.menuextra.clock",
            key: "ShowDayOfWeek",
            valueType: .bool,
            restartTargets: [.controlCenter, .systemUIServer]
        ),
        SettingDescriptor(
            id: "menubar.clock.showSeconds",
            category: .menuBar,
            subcategory: .clock,
            displayName: "時計: 秒を表示",
            description: "メニューバーの時計に秒まで表示する",
            domain: "com.apple.menuextra.clock",
            key: "ShowSeconds",
            valueType: .bool,
            restartTargets: [.controlCenter, .systemUIServer]
        ),
        SettingDescriptor(
            id: "menubar.clock.show24Hour",
            category: .menuBar,
            subcategory: .clock,
            displayName: "時計: 24 時間表示",
            description: "メニューバーの時計を 24 時間表記にする",
            domain: "com.apple.menuextra.clock",
            key: "Show24Hour",
            valueType: .bool,
            restartTargets: [.controlCenter, .systemUIServer]
        )
    ]

    /// システム標準ショートカット（`com.apple.symbolichotkeys`）の主要 12 項目。
    public static let symbolicHotKeys: [SymbolicHotKeyDescriptor] = [
        SymbolicHotKeyDescriptor(id: "28", displayName: "画面全体のスクリーンショットを保存", description: "標準: Shift + Command + 3"),
        SymbolicHotKeyDescriptor(id: "30", displayName: "選択部分のスクリーンショットを保存", description: "標準: Shift + Command + 4"),
        SymbolicHotKeyDescriptor(id: "32", displayName: "Mission Control", description: "Mission Control を表示"),
        SymbolicHotKeyDescriptor(id: "33", displayName: "アプリケーションウィンドウ", description: "現在のアプリのウィンドウ一覧を表示"),
        SymbolicHotKeyDescriptor(id: "36", displayName: "デスクトップを表示", description: "すべてのウィンドウを退避してデスクトップを表示"),
        SymbolicHotKeyDescriptor(id: "60", displayName: "前の入力ソースを選択", description: "入力ソース切替（前へ）"),
        SymbolicHotKeyDescriptor(id: "61", displayName: "入力メニューの次のソースを選択", description: "入力ソース切替（次へ）"),
        SymbolicHotKeyDescriptor(id: "64", displayName: "Spotlight 検索を表示", description: "Spotlight 検索バーを開く"),
        SymbolicHotKeyDescriptor(id: "65", displayName: "Finder 検索ウィンドウを表示", description: "Finder の検索ウィンドウを開く"),
        SymbolicHotKeyDescriptor(id: "79", displayName: "左の操作スペースへ移動", description: "左隣の仮想デスクトップへ切り替え"),
        SymbolicHotKeyDescriptor(id: "81", displayName: "右の操作スペースへ移動", description: "右隣の仮想デスクトップへ切り替え"),
        SymbolicHotKeyDescriptor(id: "184", displayName: "スクリーンショットと収録のオプション", description: "標準: Shift + Command + 5")
    ]

    /// ID からシステム標準ショートカット定義を引く辞書。
    public static let symbolicHotKeysByID: [String: SymbolicHotKeyDescriptor] = Dictionary(
        uniqueKeysWithValues: symbolicHotKeys.map { ($0.id, $0) }
    )
}
