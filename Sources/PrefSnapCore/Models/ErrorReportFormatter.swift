import Foundation

/// エラー・警告コピー時のヘッダーに出力する診断用環境情報モデル。
/// プライバシー配慮のためホスト名などの端末識別情報は保持しない。
public struct DiagnosticEnvironment: Equatable, Sendable {
    /// アプリの表示名（例: `PrefSnap` / `PrefSnap_dev`）。
    public let appDisplayName: String
    /// アプリのバージョン文字列（例: `0.1.5` / `dev`）。
    public let appShortVersion: String
    /// アプリのビルド番号（未設定時は `nil`）。
    public let appBuildNumber: String?
    /// macOS バージョン文字列（例: `Version 27.2.1 (Build 26B131)`）。
    public let osVersion: String
    /// CPU アーキテクチャ（例: `arm64` / `x86_64`）。
    public let architecture: String

    /// 診断用環境情報を初期化する。
    /// - Parameters:
    ///   - appDisplayName: アプリの表示名
    ///   - appShortVersion: アプリのマーケティングバージョン文字列
    ///   - appBuildNumber: アプリのビルド番号（任意）
    ///   - osVersion: macOS バージョン文字列
    ///   - architecture: CPU アーキテクチャ文字列
    public init(
        appDisplayName: String,
        appShortVersion: String,
        appBuildNumber: String? = nil,
        osVersion: String,
        architecture: String
    ) {
        self.appDisplayName = appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appShortVersion = appShortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBuild = appBuildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appBuildNumber = (trimmedBuild?.isEmpty == false) ? trimmedBuild : nil
        self.osVersion = osVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.architecture = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 現在の実行環境から診断用環境情報を構築する。
    /// ホスト名はプライバシー配慮のため含めない。
    /// - Parameters:
    ///   - identity: アプリ識別情報（既定値は現在のバンドル）
    ///   - versionInfo: アプリバージョン情報（既定値は現在のバンドル）
    ///   - environment: OS バージョン・アーキテクチャ提供元（既定値は本番実装）
    /// - Returns: 構築された `DiagnosticEnvironment`
    public static func current(
        identity: AppIdentity = .current(),
        versionInfo: AppVersionInfo = .current(),
        environment: EnvironmentProviding = SystemEnvironmentProvider()
    ) -> DiagnosticEnvironment {
        // ホスト名は意図的に参照せず、OS バージョンとアーキテクチャのみ取得する
        let metadata = environment.currentHostMetadata()
        return DiagnosticEnvironment(
            appDisplayName: identity.displayName,
            appShortVersion: versionInfo.shortVersionString,
            appBuildNumber: versionInfo.buildNumber,
            osVersion: metadata.osVersion,
            architecture: metadata.architecture
        )
    }

    /// コピー出力の先頭に付与する 1 行の環境情報ヘッダー文字列を生成する。
    /// - Returns: 例 `PrefSnap 0.1.5 (ビルド 12) / macOS Version 27.2.1 (Build 26B131) / arm64`
    public var headerLine: String {
        let appPart: String
        if let appBuildNumber {
            appPart = "\(appDisplayName) \(appShortVersion) (ビルド \(appBuildNumber))"
        } else {
            appPart = "\(appDisplayName) \(appShortVersion)"
        }

        // 先頭にすでに "macOS" が含まれている場合は二重付与を避ける
        let osPart: String
        if osVersion.lowercased().hasPrefix("macos") {
            osPart = osVersion
        } else if osVersion.isEmpty {
            osPart = "macOS"
        } else {
            osPart = "macOS \(osVersion)"
        }

        let archPart = architecture.isEmpty ? "unknown" : architecture
        return "\(appPart) / \(osPart) / \(archPart)"
    }
}

/// エラー・警告バナーからクリップボードへコピーするプレーンテキストを整形するフォーマッタ。
public enum ErrorReportFormatter {
    /// 単一のエラー・警告メッセージを環境情報ヘッダー付きテキストへ整形する。
    /// - Parameters:
    ///   - title: エラー・警告の種別見出し（不要な場合は `nil`）
    ///   - message: エラー・警告の本文メッセージ
    ///   - environment: ヘッダーに付与する診断用環境情報
    /// - Returns: クリップボードコピー用に整形された文字列
    public static func formatMessage(
        title: String? = nil,
        message: String,
        environment: DiagnosticEnvironment
    ) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = [
            environment.headerLine,
            "---"
        ]
        if !trimmedTitle.isEmpty {
            lines.append(trimmedTitle)
        }
        if !trimmedMessage.isEmpty {
            lines.append(trimmedMessage)
        }
        return lines.joined(separator: "\n")
    }

    /// 複数の `ItemIssue` を画面上の省略件数にかかわらず全件出力するテキストへ整形する。
    /// - Parameters:
    ///   - title: バナーの見出し文言（例: `一部の項目でエラーが発生しました`）
    ///   - issues: 出力対象となる `ItemIssue` の全件配列
    ///   - environment: ヘッダーに付与する診断用環境情報
    /// - Returns: 環境情報ヘッダー・件数サマリ・全件明細を含む文字列
    public static func formatIssues(
        title: String,
        issues: [ItemIssue],
        environment: DiagnosticEnvironment
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryHeader = trimmedTitle.isEmpty
            ? "全 \(issues.count) 件"
            : "\(trimmedTitle)（全 \(issues.count) 件）"

        var lines: [String] = [
            environment.headerLine,
            "---",
            summaryHeader
        ]
        for issue in issues {
            let trimmedItemTitle = issue.itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedMessage = issue.message.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("・\(trimmedItemTitle): \(trimmedMessage)")
        }
        return lines.joined(separator: "\n")
    }
}
