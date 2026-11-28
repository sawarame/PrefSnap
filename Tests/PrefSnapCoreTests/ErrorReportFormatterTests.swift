import Foundation
import Testing
@testable import PrefSnapCore

/// `DiagnosticEnvironment` および `ErrorReportFormatter` の出力整形仕様を検証するテストスイート。
@Suite("ErrorReportFormatter と診断環境情報ヘッダーのテスト")
struct ErrorReportFormatterTests {
    /// ビルド番号の有無や `macOS` プレフィックス重複防止を含め、環境情報ヘッダーが正しく整形されることを検証する。
    @Test("環境情報ヘッダーの整形（ビルド番号あり・なし・macOS プレフィックス重複防止）")
    func diagnosticEnvironmentHeaderLineFormatsVersionsCleanly() {
        let releaseEnv = DiagnosticEnvironment(
            appDisplayName: "PrefSnap",
            appShortVersion: "0.1.5",
            appBuildNumber: "12",
            osVersion: "Version 27.2.1 (Build 26B131)",
            architecture: "arm64"
        )
        #expect(releaseEnv.headerLine == "PrefSnap 0.1.5 (ビルド 12) / macOS Version 27.2.1 (Build 26B131) / arm64")

        // ビルド番号なし・すでに macOS プレフィックスがある場合は重複させないこと
        let devEnv = DiagnosticEnvironment(
            appDisplayName: "PrefSnap_dev",
            appShortVersion: "dev",
            appBuildNumber: nil,
            osVersion: "macOS 27.2.1",
            architecture: "x86_64"
        )
        #expect(devEnv.headerLine == "PrefSnap_dev dev / macOS 27.2.1 / x86_64")
    }

    /// `DiagnosticEnvironment.current` が端末ホスト名を出力に含めないことを検証する。
    @Test("DiagnosticEnvironment.current にホスト名が含まれないこと")
    func diagnosticEnvironmentExcludesHostNameForPrivacy() {
        let mockEnv = MockEnvironmentProvider(
            hostMetadata: SourceHostMetadata(
                hostName: "Secret-Personal-MacBook-Pro",
                osVersion: "Version 27.2.1 (Build 26B131)",
                architecture: "arm64"
            )
        )
        let identity = AppIdentity(
            displayName: "PrefSnap",
            bundleIdentifier: AppIdentity.releaseBundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/PrefSnap.app")
        )
        let versionInfo = AppVersionInfo(shortVersionString: "0.1.5", buildNumber: "15")

        let diagnosticEnv = DiagnosticEnvironment.current(
            identity: identity,
            versionInfo: versionInfo,
            environment: mockEnv
        )
        let formatted = ErrorReportFormatter.formatMessage(
            title: "エラーが発生しました",
            message: "JSON の読み込みに失敗しました。",
            environment: diagnosticEnv
        )

        #expect(!diagnosticEnv.headerLine.contains("Secret-Personal-MacBook-Pro"))
        #expect(!formatted.contains("Secret-Personal-MacBook-Pro"))
        #expect(formatted.hasPrefix("PrefSnap 0.1.5 (ビルド 15) / macOS Version 27.2.1 (Build 26B131) / arm64\n---\n"))
    }

    /// 単一エラーメッセージがタイトルあり・なし両方で期待通り整形されることを検証する。
    @Test("単一エラーメッセージの環境情報付きフォーマット整形")
    func formatMessageOutputsHeaderAndMessageWithOptionalTitle() {
        let env = DiagnosticEnvironment(
            appDisplayName: "PrefSnap",
            appShortVersion: "0.1.5",
            appBuildNumber: nil,
            osVersion: "Version 27.2.1 (Build 26B131)",
            architecture: "arm64"
        )

        let withTitle = ErrorReportFormatter.formatMessage(
            title: "アップデート確認エラー",
            message: "  GitHub API への接続がタイムアウトしました。 \n",
            environment: env
        )
        #expect(withTitle == """
        PrefSnap 0.1.5 / macOS Version 27.2.1 (Build 26B131) / arm64
        ---
        アップデート確認エラー
        GitHub API への接続がタイムアウトしました。
        """)

        let withoutTitle = ErrorReportFormatter.formatMessage(
            title: nil,
            message: "ファイル保存に失敗しました。",
            environment: env
        )
        #expect(withoutTitle == """
        PrefSnap 0.1.5 / macOS Version 27.2.1 (Build 26B131) / arm64
        ---
        ファイル保存に失敗しました。
        """)
    }

    /// 警告一覧が 6 件以上ある場合も、画面表示の 5 件省略にかかわらず全件出力されることを検証する。
    @Test("複数 ItemIssue が 6 件以上でも省略されず全件出力されること")
    func formatIssuesOutputsAllItemsWithoutTruncation() {
        let env = DiagnosticEnvironment(
            appDisplayName: "PrefSnap",
            appShortVersion: "0.1.5",
            appBuildNumber: "12",
            osVersion: "Version 27.2.1 (Build 26B131)",
            architecture: "arm64"
        )

        // 画面上は先頭 5 件で省略されるが、コピー出力では全 12 件が含まれることを確認する
        let issues = (1...12).map { index in
            ItemIssue(
                id: "issue-\(index)",
                itemTitle: "設定項目 \(index)",
                message: "エラー詳細 \(index)",
                isPermissionError: index == 1
            )
        }

        let formatted = ErrorReportFormatter.formatIssues(
            title: "一部の項目でエラーが発生しました",
            issues: issues,
            environment: env
        )
        let lines = formatted.components(separatedBy: "\n")

        #expect(lines[0] == "PrefSnap 0.1.5 (ビルド 12) / macOS Version 27.2.1 (Build 26B131) / arm64")
        #expect(lines[1] == "---")
        #expect(lines[2] == "一部の項目でエラーが発生しました（全 12 件）")
        #expect(lines.count == 15)
        for index in 1...12 {
            #expect(lines[2 + index] == "・設定項目 \(index): エラー詳細 \(index)")
        }

        // 空配列でもクラッシュせず 0 件サマリを返すこと
        let emptyFormatted = ErrorReportFormatter.formatIssues(
            title: "一部の項目でエラーが発生しました",
            issues: [],
            environment: env
        )
        #expect(emptyFormatted == """
        PrefSnap 0.1.5 (ビルド 12) / macOS Version 27.2.1 (Build 26B131) / arm64
        ---
        一部の項目でエラーが発生しました（全 0 件）
        """)
    }
}
