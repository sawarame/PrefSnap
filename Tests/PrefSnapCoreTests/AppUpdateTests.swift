import Foundation
import Testing
@testable import PrefSnapCore

/// メモリ上で動作するテスト用アップデート設定ストア（実環境の `UserDefaults` には一切触れない）。
private final class InMemoryUpdatePreferencesStore: UpdatePreferencesStoring, @unchecked Sendable {
    var autoCheckForUpdates: Bool
    var skippedUpdateVersion: String?

    /// 初期値を指定してストアを初期化する。
    /// - Parameters:
    ///   - autoCheckForUpdates: 自動チェックの初期値
    ///   - skippedUpdateVersion: スキップ済みバージョンの初期値
    init(autoCheckForUpdates: Bool = false, skippedUpdateVersion: String? = nil) {
        self.autoCheckForUpdates = autoCheckForUpdates
        self.skippedUpdateVersion = skippedUpdateVersion
    }
}

/// 外部ネットワークや実ファイル差し替えを行わずに `UpdateViewModel` を検証するモックサービス。
private final class MockAppUpdateService: AppUpdateServing, @unchecked Sendable {
    var fetchResult: Result<UpdateRelease?, Error>
    var eligibility: UpdateInstallEligibility
    var installError: Error?
    var progressEventsToEmit: [UpdateInstallProgress] = []
    private(set) var fetchCallCount = 0
    private(set) var installCallCount = 0
    private(set) var lastInstallTargetURL: URL?

    /// モックサービスを初期化する。
    /// - Parameters:
    ///   - fetchResult: `fetchLatestStableRelease` の返却結果
    ///   - eligibility: `checkInstallEligibility` の返却値
    init(
        fetchResult: Result<UpdateRelease?, Error> = .success(nil),
        eligibility: UpdateInstallEligibility = .eligible(appBundleURL: URL(fileURLWithPath: "/Applications/PrefSnap.app"))
    ) {
        self.fetchResult = fetchResult
        self.eligibility = eligibility
    }

    func fetchLatestStableRelease(currentVersion: AppVersionInfo) async throws -> UpdateRelease? {
        fetchCallCount += 1
        return try fetchResult.get()
    }

    func checkInstallEligibility(identity: AppIdentity, versionInfo: AppVersionInfo) -> UpdateInstallEligibility {
        eligibility
    }

    func installUpdate(
        _ release: UpdateRelease,
        targetAppURL: URL,
        progress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async throws {
        installCallCount += 1
        lastInstallTargetURL = targetAppURL
        for event in progressEventsToEmit {
            progress(event)
        }
        if let installError {
            throw installError
        }
    }
}

@Suite("SemanticVersion の解析・比較・プレリリース判定テスト")
struct SemanticVersionTests {
    @Test("標準 SemVer・先頭 v/V・プレリリース・ビルドメタデータを正しく解析できること")
    func parsesValidSemVerVariants() {
        let plain = SemanticVersion("0.1.4")
        #expect(plain?.major == 0)
        #expect(plain?.minor == 1)
        #expect(plain?.patch == 4)
        #expect(plain?.isPrerelease == false)
        #expect(plain?.normalized == "0.1.4")

        let lowerV = SemanticVersion("v1.2.3")
        let upperV = SemanticVersion("V1.2.3+20260101.abc")
        #expect(lowerV == upperV)
        #expect(upperV?.buildMetadataIdentifiers == ["20260101", "abc"])
        #expect(upperV?.normalized == "1.2.3")

        let pre = SemanticVersion("v0.2.0-beta.1+exp.sha.5114f85")
        #expect(pre?.isPrerelease == true)
        #expect(pre?.prereleaseIdentifiers == ["beta", "1"])
        #expect(pre?.normalized == "0.2.0-beta.1")
    }

    @Test("不正な SemVer 文字列を厳密に拒否すること")
    func rejectsInvalidSemVerStrings() {
        let invalidCases = [
            "",
            "dev",
            "1.0",
            "1.2.3.4",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "vv1.0.0",
            "1.0.0-",
            "1.0.0+",
            "1.0.0-01",
            "1.0.0-beta..1",
            "1.0.0+build..1",
            "1.0.0-beta_1"
        ]
        for raw in invalidCases {
            #expect(SemanticVersion(raw) == nil, "不正な値 \(raw) が解析成功してしまった")
        }
    }

    @Test("SemVer 2.0.0 の優先順位比較とビルドメタデータ無視が正しく動作すること")
    func comparesVersionsAccordingToSemVerSpec() throws {
        let ordered = [
            "0.1.0-alpha",
            "0.1.0-alpha.1",
            "0.1.0-alpha.beta",
            "0.1.0-beta",
            "0.1.0-beta.2",
            "0.1.0-beta.11",
            "0.1.0-rc.1",
            "0.1.0",
            "0.1.1",
            "0.2.0",
            "1.0.0"
        ].compactMap(SemanticVersion.init)

        #expect(ordered.count == 11)
        for index in 0..<(ordered.count - 1) {
            #expect(ordered[index] < ordered[index + 1])
            #expect(!(ordered[index + 1] < ordered[index]))
        }

        // ビルドメタデータの違いは等価かつ大小差なしとして扱う
        let lhs = try #require(SemanticVersion("0.1.5+build.1"))
        let rhs = try #require(SemanticVersion("0.1.5+build.2"))
        #expect(lhs == rhs)
        #expect(!(lhs < rhs))
        #expect(!(rhs < lhs))
    }
}

@Suite("GitHubReleaseParser と UpdateURLValidator のテスト")
struct ReleaseParserAndURLValidatorTests {
    @Test("UpdateURLValidator が許可ホストと拒否ホスト・フォールバック URL を厳密に判定すること")
    func validatesReleasePageAndDownloadURLs() throws {
        // リリースページ URL は大文字小文字非区別で /sawarame/PrefSnap 配下のみ許可
        let validUpper = UpdateURLValidator.sanitizedReleasePageURL("https://GITHUB.COM/SAWARAME/PREFSNAP/releases/tag/v0.1.5")
        #expect(validUpper.absoluteString == "https://GITHUB.COM/SAWARAME/PREFSNAP/releases/tag/v0.1.5")

        // 許可外ホスト・HTTP・別リポジトリ・パストラバーサルは Releases 一覧へフォールバック
        let invalidReleasePages = [
            "http://github.com/sawarame/PrefSnap/releases/tag/v0.1.5",
            "https://evil.example.com/sawarame/PrefSnap/releases",
            "https://github.com/other/PrefSnap/releases",
            "https://github.com/sawarame/PrefSnap/../../other/repo",
            "javascript:alert(1)",
            nil
        ]
        for raw in invalidReleasePages {
            #expect(UpdateURLValidator.sanitizedReleasePageURL(raw) == AppIdentity.releasesPageURL)
        }

        // ダウンロード／リダイレクト先 URL の許可・拒否ホスト検証
        let allowedDownloads = [
            "https://github.com/sawarame/PrefSnap/releases/download/v0.1.5/PrefSnap-v0.1.5.zip",
            "https://objects.githubusercontent.com/github-production-release-asset-123/file.zip",
            "https://release-assets.githubusercontent.com/PrefSnap-v0.1.5.zip"
        ]
        for raw in allowedDownloads {
            let url = try #require(URL(string: raw))
            #expect(UpdateURLValidator.isAllowedDownloadURL(url) == true)
        }

        let deniedDownloads = [
            "http://github.com/sawarame/PrefSnap/releases/download/v0.1.5/PrefSnap-v0.1.5.zip",
            "https://githubusercontent.com/file.zip",
            "https://evil-githubusercontent.com/file.zip",
            "https://github.com.evil.com/file.zip",
            "https://api.github.com/repos/sawarame/PrefSnap",
            "https://github.com:8443/sawarame/PrefSnap/file.zip",
            "https://user:pass@github.com/sawarame/PrefSnap/file.zip"
        ]
        for raw in deniedDownloads {
            let url = try #require(URL(string: raw))
            #expect(UpdateURLValidator.isAllowedDownloadURL(url) == false, "許可されてはいけない URL: \(raw)")
        }
    }

    @Test("安定版リリースと SHA-256 ダイジェストを正しく抽出できること")
    func parsesValidStableRelease() throws {
        let digestHex = String(repeating: "a", count: 64)
        let json = """
        {
          "tag_name": "v0.1.5",
          "name": "PrefSnap v0.1.5",
          "body": "自動アップデート機能を追加しました。",
          "draft": false,
          "prerelease": false,
          "html_url": "https://github.com/sawarame/PrefSnap/releases/tag/v0.1.5",
          "published_at": "2026-11-28T01:00:00Z",
          "assets": [
            {
              "name": "PrefSnap-v0.1.5.dmg",
              "browser_download_url": "https://github.com/sawarame/PrefSnap/releases/download/v0.1.5/PrefSnap-v0.1.5.dmg"
            },
            {
              "name": "PrefSnap-v0.1.5.zip",
              "browser_download_url": "https://github.com/sawarame/PrefSnap/releases/download/v0.1.5/PrefSnap-v0.1.5.zip",
              "digest": "sha256:\(digestHex.uppercased())"
            }
          ]
        }
        """

        let parsedRelease = try GitHubReleaseParser.parseLatestStableRelease(from: Data(json.utf8))
        let release = try #require(parsedRelease)
        #expect(release.version == SemanticVersion(major: 0, minor: 1, patch: 5))
        #expect(release.assetName == "PrefSnap-v0.1.5.zip")
        #expect(release.assetDigestSHA256 == digestHex)
        #expect(release.htmlURL.absoluteString == "https://github.com/sawarame/PrefSnap/releases/tag/v0.1.5")
        #expect(release.releaseNotes == "自動アップデート機能を追加しました。")
    }

    @Test("ドラフト・プレリリース・SemVer プレリリース識別子付きタグを除外すること")
    func excludesDraftAndPrereleaseReleases() throws {
        let draftJSON = """
        {"tag_name":"v0.2.0","draft":true,"prerelease":false,"assets":[]}
        """
        let prereleaseFlagJSON = """
        {"tag_name":"v0.2.0","draft":false,"prerelease":true,"assets":[]}
        """
        let prereleaseTagJSON = """
        {"tag_name":"v0.2.0-beta.1","draft":false,"prerelease":false,"assets":[]}
        """

        #expect(try GitHubReleaseParser.parseLatestStableRelease(from: Data(draftJSON.utf8)) == nil)
        #expect(try GitHubReleaseParser.parseLatestStableRelease(from: Data(prereleaseFlagJSON.utf8)) == nil)
        #expect(try GitHubReleaseParser.parseLatestStableRelease(from: Data(prereleaseTagJSON.utf8)) == nil)
    }

    @Test("期待 ZIP アセット欠損・許可外ダウンロード URL・不正 digest 形式をエラー検出すること")
    func rejectsMissingAssetUntrustedURLAndMalformedDigest() {
        let missingZipJSON = """
        {
          "tag_name": "v0.1.5",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "PrefSnap-v0.1.5.dmg",
              "browser_download_url": "https://github.com/sawarame/PrefSnap/releases/download/v0.1.5/PrefSnap-v0.1.5.dmg"
            }
          ]
        }
        """
        #expect(throws: AppUpdateError.missingReleaseAsset(expectedName: "PrefSnap-v0.1.5.zip")) {
            _ = try GitHubReleaseParser.parseLatestStableRelease(from: Data(missingZipJSON.utf8))
        }

        let badURLJSON = """
        {
          "tag_name": "v0.1.5",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "PrefSnap-v0.1.5.zip",
              "browser_download_url": "https://evil.example.com/PrefSnap-v0.1.5.zip"
            }
          ]
        }
        """
        #expect(throws: AppUpdateError.untrustedDownloadURL(urlString: "https://evil.example.com/PrefSnap-v0.1.5.zip")) {
            _ = try GitHubReleaseParser.parseLatestStableRelease(from: Data(badURLJSON.utf8))
        }

        let badDigestJSON = """
        {
          "tag_name": "v0.1.5",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "PrefSnap-v0.1.5.zip",
              "browser_download_url": "https://github.com/sawarame/PrefSnap/releases/download/v0.1.5/PrefSnap-v0.1.5.zip",
              "digest": "sha256:not-a-valid-hex"
            }
          ]
        }
        """
        #expect(throws: AppUpdateError.invalidAssetDigest(raw: "sha256:not-a-valid-hex")) {
            _ = try GitHubReleaseParser.parseLatestStableRelease(from: Data(badDigestJSON.utf8))
        }
    }
}

@Suite("UpdateCheckPolicy と AppIdentity 判定テスト")
struct UpdateCheckPolicyTests {
    private let releaseIdentity = AppIdentity(
        displayName: "PrefSnap",
        bundleIdentifier: "dev.prefsnap.PrefSnap",
        bundleURL: URL(fileURLWithPath: "/Applications/PrefSnap.app")
    )

    private let devIdentity = AppIdentity(
        displayName: "PrefSnap_dev",
        bundleIdentifier: "dev.prefsnap.PrefSnap.dev",
        bundleURL: URL(fileURLWithPath: "/Users/test/dev/PrefSnap/.build/PrefSnap_dev.app")
    )

    private func makeRelease(version: String) -> UpdateRelease {
        let semVer = SemanticVersion(version)!
        return UpdateRelease(
            tagName: "v\(semVer.normalized)",
            version: semVer,
            title: "PrefSnap v\(semVer.normalized)",
            releaseNotes: "変更内容",
            htmlURL: URL(string: "https://github.com/sawarame/PrefSnap/releases/tag/v\(semVer.normalized)")!,
            assetName: "PrefSnap-v\(semVer.normalized).zip",
            assetDownloadURL: URL(string: "https://github.com/sawarame/PrefSnap/releases/download/v\(semVer.normalized)/PrefSnap-v\(semVer.normalized).zip")!
        )
    }

    @Test("起動時自動チェックは設定 ON・非開発版・有効 SemVer の全条件を満たす場合のみ許可されること")
    func checksAutomaticExecutionConditions() {
        let validVersion = AppVersionInfo(shortVersionString: "0.1.4", buildNumber: "10")
        let devVersion = AppVersionInfo(shortVersionString: "dev", buildNumber: nil)

        #expect(UpdateCheckPolicy.shouldPerformAutomaticCheck(autoCheckEnabled: true, identity: releaseIdentity, currentVersion: validVersion) == true)
        #expect(UpdateCheckPolicy.shouldPerformAutomaticCheck(autoCheckEnabled: false, identity: releaseIdentity, currentVersion: validVersion) == false)
        #expect(UpdateCheckPolicy.shouldPerformAutomaticCheck(autoCheckEnabled: true, identity: devIdentity, currentVersion: validVersion) == false)
        #expect(UpdateCheckPolicy.shouldPerformAutomaticCheck(autoCheckEnabled: true, identity: releaseIdentity, currentVersion: devVersion) == false)
    }

    @Test("スキップ済みバージョンは自動チェックで抑止され、手動確認では再提示されること")
    func handlesSkippedVersionDifferentlyForAutoAndManual() {
        let current = AppVersionInfo(shortVersionString: "0.1.4", buildNumber: "10")
        let nextRelease = makeRelease(version: "0.1.5")

        let autoDecision = UpdateCheckPolicy.evaluate(
            latestRelease: nextRelease,
            identity: releaseIdentity,
            currentVersion: current,
            skippedVersion: "0.1.5",
            trigger: .automatic
        )
        #expect(autoDecision == .skipped(release: nextRelease))

        let manualDecision = UpdateCheckPolicy.evaluate(
            latestRelease: nextRelease,
            identity: releaseIdentity,
            currentVersion: current,
            skippedVersion: "0.1.5",
            trigger: .manual
        )
        #expect(manualDecision == .updateAvailable(release: nextRelease))
    }

    @Test("開発版・最新版・未バンドルフォールバックを正しく判定すること")
    func evaluatesDevelopmentBuildAndUpToDateStates() {
        let current = AppVersionInfo(shortVersionString: "0.1.5", buildNumber: "20")
        let sameRelease = makeRelease(version: "0.1.5")

        #expect(
            UpdateCheckPolicy.evaluate(
                latestRelease: sameRelease,
                identity: releaseIdentity,
                currentVersion: current,
                skippedVersion: nil,
                trigger: .manual
            ) == .upToDate(currentVersion: SemanticVersion(major: 0, minor: 1, patch: 5))
        )

        #expect(
            UpdateCheckPolicy.evaluate(
                latestRelease: makeRelease(version: "0.2.0"),
                identity: devIdentity,
                currentVersion: current,
                skippedVersion: nil,
                trigger: .manual
            ) == .developmentBuild
        )

        // 未バンドル実行時のフォールバック検証
        let unbundledIdentity = AppIdentity.resolve(
            infoDictionary: nil,
            bundleURL: URL(fileURLWithPath: "/Users/test/dev/PrefSnap/.build/debug")
        )
        #expect(unbundledIdentity.displayName == "PrefSnap_dev")
        #expect(unbundledIdentity.bundleIdentifier == "dev.prefsnap.PrefSnap.dev")
        #expect(unbundledIdentity.isDevelopmentBuild == true)
    }
}

@Suite("UpdateInstallEligibility の環境判定テスト")
struct UpdateInstallEligibilityTests {
    private let releaseVersion = AppVersionInfo(shortVersionString: "0.1.4", buildNumber: "10")

    @Test("開発版・App Translocation・非 .app・読み取り専用・書き込み不可・実行可能をすべて正確に判定すること")
    func evaluatesAllInstallEligibilityCases() {
        let releaseAppURL = URL(fileURLWithPath: "/Applications/PrefSnap.app")
        let releaseIdentity = AppIdentity(
            displayName: "PrefSnap",
            bundleIdentifier: "dev.prefsnap.PrefSnap",
            bundleURL: releaseAppURL
        )

        // 1. 実行可能
        let eligible = UpdateInstallEligibility.evaluate(
            snapshot: .init(
                identity: releaseIdentity,
                versionInfo: releaseVersion,
                isReadOnlyVolume: false,
                isBundleWritable: true,
                isParentDirectoryWritable: true
            )
        )
        #expect(eligible == .eligible(appBundleURL: releaseAppURL))

        // 2. ローカル開発版
        let devIdentity = AppIdentity(
            displayName: "PrefSnap_dev",
            bundleIdentifier: "dev.prefsnap.PrefSnap.dev",
            bundleURL: URL(fileURLWithPath: "/Applications/PrefSnap_dev.app")
        )
        #expect(
            UpdateInstallEligibility.evaluate(
                snapshot: .init(
                    identity: devIdentity,
                    versionInfo: releaseVersion,
                    isReadOnlyVolume: false,
                    isBundleWritable: true,
                    isParentDirectoryWritable: true
                )
            ) == .ineligible(reason: .developmentBuild)
        )

        // 3. 非 .app バンドル起動（swift run 等）
        let cliIdentity = AppIdentity(
            displayName: "PrefSnap",
            bundleIdentifier: "dev.prefsnap.PrefSnap",
            bundleURL: URL(fileURLWithPath: "/Users/test/dev/PrefSnap/.build/debug")
        )
        #expect(
            UpdateInstallEligibility.evaluate(
                snapshot: .init(
                    identity: cliIdentity,
                    versionInfo: releaseVersion,
                    isReadOnlyVolume: false,
                    isBundleWritable: true,
                    isParentDirectoryWritable: true
                )
            ) == .ineligible(reason: .notAppBundle)
        )

        // 4. App Translocation
        let translocatedIdentity = AppIdentity(
            displayName: "PrefSnap",
            bundleIdentifier: "dev.prefsnap.PrefSnap",
            bundleURL: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/PrefSnap.app")
        )
        #expect(
            UpdateInstallEligibility.evaluate(
                snapshot: .init(
                    identity: translocatedIdentity,
                    versionInfo: releaseVersion,
                    isReadOnlyVolume: false,
                    isBundleWritable: true,
                    isParentDirectoryWritable: true
                )
            ) == .ineligible(reason: .appTranslocation)
        )

        // 5. 読み取り専用ボリューム
        #expect(
            UpdateInstallEligibility.evaluate(
                snapshot: .init(
                    identity: releaseIdentity,
                    versionInfo: releaseVersion,
                    isReadOnlyVolume: true,
                    isBundleWritable: true,
                    isParentDirectoryWritable: true
                )
            ) == .ineligible(reason: .readOnlyVolume)
        )

        // 6. アプリ本体または親ディレクトリ書き込み不可
        #expect(
            UpdateInstallEligibility.evaluate(
                snapshot: .init(
                    identity: releaseIdentity,
                    versionInfo: releaseVersion,
                    isReadOnlyVolume: false,
                    isBundleWritable: false,
                    isParentDirectoryWritable: true
                )
            ) == .ineligible(reason: .notWritable(path: "/Applications/PrefSnap.app"))
        )

        #expect(
            UpdateInstallEligibility.evaluate(
                snapshot: .init(
                    identity: releaseIdentity,
                    versionInfo: releaseVersion,
                    isReadOnlyVolume: false,
                    isBundleWritable: true,
                    isParentDirectoryWritable: false
                )
            ) == .ineligible(reason: .notWritable(path: "/Applications"))
        )
    }
}

@Suite("AppUpdateService の純粋ヘルパーテスト")
struct AppUpdateServiceHelperTests {
    @Test("CryptoKit による SHA-256 計算が期待ハッシュと一致すること")
    func computesSHA256OfTemporaryFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrefSnapTests-sha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("sample.zip")
        try Data("abc".utf8).write(to: fileURL)

        let digest = try AppUpdateService.sha256Hex(ofFileAt: fileURL)
        // NIST 標準テストベクタ（"abc"）の既知 SHA-256 と完全一致することを確認する
        #expect(digest.count == 64)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let emptyFileURL = tempDir.appendingPathComponent("empty.zip")
        try Data().write(to: emptyFileURL)
        let emptyDigest = try AppUpdateService.sha256Hex(ofFileAt: emptyFileURL)
        #expect(emptyDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("展開後 Info.plist の Bundle ID およびバージョン検証が正常系・異常系を判定できること")
    func validatesExtractedAppInfoPlist() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrefSnapTests-plist-\(UUID().uuidString)", isDirectory: true)
        let contentsDir = tempDir
            .appendingPathComponent("PrefSnap.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appURL = tempDir.appendingPathComponent("PrefSnap.app", isDirectory: true)
        let plistURL = contentsDir.appendingPathComponent("Info.plist")

        func writePlist(bundleID: String, version: String) throws {
            let dict: [String: Any] = [
                "CFBundleIdentifier": bundleID,
                "CFBundleShortVersionString": version
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL)
        }

        // 正常ケース
        try writePlist(bundleID: "dev.prefsnap.PrefSnap", version: "0.1.5")
        try AppUpdateService.validateExtractedAppInfoPlist(
            at: appURL,
            expectedBundleIdentifier: "dev.prefsnap.PrefSnap",
            expectedVersion: SemanticVersion(major: 0, minor: 1, patch: 5)
        )

        // Bundle ID 不一致
        try writePlist(bundleID: "dev.prefsnap.PrefSnap.dev", version: "0.1.5")
        #expect(throws: AppUpdateError.self) {
            try AppUpdateService.validateExtractedAppInfoPlist(
                at: appURL,
                expectedBundleIdentifier: "dev.prefsnap.PrefSnap",
                expectedVersion: SemanticVersion(major: 0, minor: 1, patch: 5)
            )
        }

        // バージョン不一致
        try writePlist(bundleID: "dev.prefsnap.PrefSnap", version: "0.1.4")
        #expect(throws: AppUpdateError.self) {
            try AppUpdateService.validateExtractedAppInfoPlist(
                at: appURL,
                expectedBundleIdentifier: "dev.prefsnap.PrefSnap",
                expectedVersion: SemanticVersion(major: 0, minor: 1, patch: 5)
            )
        }
    }

    @Test("分離ヘルパースクリプトに必要な安全ステップとクォート処理が含まれること")
    func generatesSafeReplacementHelperScript() {
        let targetApp = URL(fileURLWithPath: "/Applications/PrefSnap's Dir/PrefSnap.app")
        let stagedApp = URL(fileURLWithPath: "/tmp/staging/extracted/PrefSnap.app")
        let backupApp = AppUpdateService.makeBackupAppURL(for: targetApp, parentPID: 4321)
        let stagingDir = URL(fileURLWithPath: "/tmp/staging")

        #expect(backupApp.path == "/Applications/PrefSnap's Dir/.PrefSnap.app.prefsnap-backup-4321")

        let script = AppUpdateService.generateReplacementHelperScript(
            parentPID: 4321,
            targetAppURL: targetApp,
            stagedAppURL: stagedApp,
            backupAppURL: backupApp,
            stagingDirectoryURL: stagingDir,
            timeoutSeconds: 30
        )

        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("PARENT_PID=4321"))
        #expect(script.contains("MAX_WAIT_SECONDS=30"))
        #expect(script.contains("'/Applications/PrefSnap'\\''s Dir/PrefSnap.app'"))
        #expect(script.contains("/bin/kill -0 \"$PARENT_PID\""))
        #expect(script.contains("/bin/mv \"$TARGET_APP\" \"$BACKUP_APP\""))
        #expect(script.contains("/usr/bin/ditto \"$STAGED_APP\" \"$TARGET_APP\""))
        #expect(script.contains("/bin/mv \"$BACKUP_APP\" \"$TARGET_APP\""))
        #expect(script.contains("/usr/bin/xattr -dr com.apple.quarantine \"$TARGET_APP\""))
        #expect(script.contains("/usr/bin/open -n \"$TARGET_APP\""))
        #expect(script.contains("/bin/rm -rf \"$BACKUP_APP\""))
        #expect(script.contains("/bin/rm -rf \"$STAGING_DIR\""))
    }

    @Test("GitHub API リクエストに必須ヘッダ・キャッシュ無効・タイムアウトが設定されること")
    func buildsGitHubAPIRequestWithRequiredHeaders() {
        let request = AppUpdateService.makeGitHubAPIRequest(
            url: AppIdentity.latestReleaseAPIURL,
            currentVersion: AppVersionInfo(shortVersionString: "0.1.4", buildNumber: "15"),
            timeoutInterval: 15
        )

        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "PrefSnap/0.1.4")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == 15)
    }

    @Test("HTTP 403/429 レスポンスから GitHub API レート制限を正確に判定できること")
    func detectsRateLimitedHTTPResponses() throws {
        let resetTimestamp = 1_800_000_000
        let rateLimited403 = try #require(
            HTTPURLResponse(
                url: AppIdentity.latestReleaseAPIURL,
                statusCode: 403,
                httpVersion: nil,
                headerFields: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": "\(resetTimestamp)"
                ]
            )
        )
        #expect(
            AppUpdateService.rateLimitErrorIfApplicable(from: rateLimited403)
                == .rateLimited(resetDate: Date(timeIntervalSince1970: TimeInterval(resetTimestamp)))
        )

        let normal403 = try #require(
            HTTPURLResponse(
                url: AppIdentity.latestReleaseAPIURL,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["X-RateLimit-Remaining": "50"]
            )
        )
        #expect(AppUpdateService.rateLimitErrorIfApplicable(from: normal403) == nil)
    }
}

@Suite("UpdateViewModel の状態遷移・スキップ保存・isBusy ガード・エラーハンドリングテスト")
@MainActor
struct UpdateViewModelTests {
    /// `@MainActor` クロージャ内から可変状態を安全に参照・更新するためのテスト用ボックス。
    @MainActor
    private final class Box<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private let releaseIdentity = AppIdentity(
        displayName: "PrefSnap",
        bundleIdentifier: "dev.prefsnap.PrefSnap",
        bundleURL: URL(fileURLWithPath: "/Applications/PrefSnap.app")
    )

    private let currentVersion = AppVersionInfo(shortVersionString: "0.1.4", buildNumber: "12")

    private var sampleRelease: UpdateRelease {
        UpdateRelease(
            tagName: "v0.1.5",
            version: SemanticVersion(major: 0, minor: 1, patch: 5),
            title: "PrefSnap v0.1.5",
            releaseNotes: "自動アップデート対応",
            htmlURL: URL(string: "https://github.com/sawarame/PrefSnap/releases/tag/v0.1.5")!,
            assetName: "PrefSnap-v0.1.5.zip",
            assetDownloadURL: URL(string: "https://github.com/sawarame/PrefSnap/releases/download/v0.1.5/PrefSnap-v0.1.5.zip")!
        )
    }

    @Test("初期値は自動チェック OFF であり、トグル変更がストアへ永続化されること")
    func persistsAutoCheckToggle() {
        let store = InMemoryUpdatePreferencesStore()
        let viewModel = UpdateViewModel(
            updateService: MockAppUpdateService(),
            preferencesStore: store,
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion
        )

        #expect(viewModel.autoCheckForUpdates == false)
        viewModel.autoCheckForUpdates = true
        #expect(store.autoCheckForUpdates == true)
    }

    @Test("起動時自動チェックは設定 OFF・通信失敗・スキップ済みで不要なダイアログを出さないこと")
    func automaticCheckRespectsSettingsSkipAndSilentErrors() async {
        // 設定 OFF なら通信自体を行わない
        let offService = MockAppUpdateService(fetchResult: .success(sampleRelease))
        let offViewModel = UpdateViewModel(
            updateService: offService,
            preferencesStore: InMemoryUpdatePreferencesStore(autoCheckForUpdates: false),
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion
        )
        await offViewModel.performAutomaticCheckIfNeeded()
        #expect(offService.fetchCallCount == 0)
        #expect(offViewModel.isPromptPresented == false)

        // スキップ済みバージョンは自動チェックでシートを表示しない
        let skippedService = MockAppUpdateService(fetchResult: .success(sampleRelease))
        let skippedViewModel = UpdateViewModel(
            updateService: skippedService,
            preferencesStore: InMemoryUpdatePreferencesStore(autoCheckForUpdates: true, skippedUpdateVersion: "0.1.5"),
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion
        )
        await skippedViewModel.performAutomaticCheckIfNeeded()
        #expect(skippedService.fetchCallCount == 1)
        #expect(skippedViewModel.isPromptPresented == false)

        // 起動時自動チェックの通信エラーはダイアログもフィードバックも出さず静かに終了する
        let failingService = MockAppUpdateService(fetchResult: .failure(AppUpdateError.networkError(detail: "offline")))
        let failingViewModel = UpdateViewModel(
            updateService: failingService,
            preferencesStore: InMemoryUpdatePreferencesStore(autoCheckForUpdates: true),
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion
        )
        await failingViewModel.performAutomaticCheckIfNeeded()
        #expect(failingViewModel.isPromptPresented == false)
        #expect(failingViewModel.checkFeedback == nil)
    }

    @Test("手動確認ではスキップ済みでもシートを再提示し、『このバージョンをスキップ』で保存されること")
    func manualCheckPresentsSkippedReleaseAndSavesSkip() async {
        let store = InMemoryUpdatePreferencesStore(autoCheckForUpdates: true, skippedUpdateVersion: "0.1.5")
        let service = MockAppUpdateService(fetchResult: .success(sampleRelease))
        let viewModel = UpdateViewModel(
            updateService: service,
            preferencesStore: store,
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion
        )

        await viewModel.checkForUpdatesManually()
        #expect(viewModel.isPromptPresented == true)
        #expect(viewModel.availableRelease == sampleRelease)
        #expect(viewModel.checkFeedback == .updateAvailable(release: sampleRelease))

        // 「後で」はスキップを上書きせずシートのみ閉じる
        store.skippedUpdateVersion = nil
        viewModel.deferUpdate()
        #expect(viewModel.isPromptPresented == false)
        #expect(store.skippedUpdateVersion == nil)

        // 再表示して「このバージョンをスキップ」を押すと保存して閉じる
        viewModel.presentAvailableUpdatePrompt()
        #expect(viewModel.isPromptPresented == true)
        viewModel.skipAvailableVersion()
        #expect(viewModel.isPromptPresented == false)
        #expect(store.skippedUpdateVersion == "0.1.5")
    }

    @Test("isBusy 中は自動アップデート開始をガードし、完了後はシートを閉じて自動終了ハンドラを呼ぶこと")
    func guardsUpdateInstallWhileAppIsBusyAndTerminatesOnSuccess() async {
        let isBusy = Box(true)
        let terminated = Box(false)
        let promptPresentedAtTermination = Box<Bool?>(nil)
        let preventDismissalAtTermination = Box<Bool?>(nil)
        let terminatingFlagAtTermination = Box<Bool?>(nil)
        let installingFlagAtTermination = Box<Bool?>(nil)
        let viewModelBox = Box<UpdateViewModel?>(nil)

        let service = MockAppUpdateService(fetchResult: .success(sampleRelease))
        service.progressEventsToEmit = [.downloading(fractionCompleted: 0.5), .preparingReplacement]

        let viewModel = UpdateViewModel(
            updateService: service,
            preferencesStore: InMemoryUpdatePreferencesStore(),
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion,
            isAppBusyProvider: { isBusy.value },
            terminateForUpdateHandler: {
                terminated.value = true
                promptPresentedAtTermination.value = viewModelBox.value?.isPromptPresented
                preventDismissalAtTermination.value = viewModelBox.value?.shouldPreventPromptDismissal
                terminatingFlagAtTermination.value = viewModelBox.value?.isTerminatingForUpdate
                installingFlagAtTermination.value = viewModelBox.value?.isInstalling
            }
        )
        viewModelBox.value = viewModel

        await viewModel.checkForUpdatesManually()
        #expect(viewModel.isPromptPresented == true)
        #expect(viewModel.shouldPreventPromptDismissal == false)

        // isBusy == true の間は開始されず案内メッセージが設定される
        await viewModel.startUpdateInstall()
        #expect(service.installCallCount == 0)
        #expect(viewModel.promptErrorMessage == AppUpdateError.appIsBusy.localizedDescription)
        #expect(terminated.value == false)
        #expect(viewModel.isPromptPresented == true)

        // isBusy == false になればインストールを実行し、成功後にシートを閉じてから自動終了ハンドラが呼ばれる
        isBusy.value = false
        await viewModel.startUpdateInstall()
        #expect(service.installCallCount == 1)
        #expect(service.lastInstallTargetURL == URL(fileURLWithPath: "/Applications/PrefSnap.app"))
        #expect(terminated.value == true)
        #expect(promptPresentedAtTermination.value == false)
        #expect(preventDismissalAtTermination.value == false)
        #expect(terminatingFlagAtTermination.value == true)
        #expect(installingFlagAtTermination.value == true)
        // 終了完了までの間は多重実行・確認操作がガードされ続けること
        #expect(viewModel.canCheckForUpdates == false)
        #expect(viewModel.isPromptPresented == false)
        #expect(viewModel.shouldPreventPromptDismissal == false)
    }

    @Test("開発版の手動確認や差し替え不可環境で適切にフォールバック案内されること")
    func handlesDevelopmentBuildAndIneligibleInstallEnvironment() async {
        let devIdentity = AppIdentity(
            displayName: "PrefSnap_dev",
            bundleIdentifier: "dev.prefsnap.PrefSnap.dev",
            bundleURL: URL(fileURLWithPath: "/Users/test/dev/PrefSnap/.build/PrefSnap_dev.app")
        )
        let devService = MockAppUpdateService(fetchResult: .success(sampleRelease))
        let devVM = UpdateViewModel(
            updateService: devService,
            preferencesStore: InMemoryUpdatePreferencesStore(),
            currentIdentity: devIdentity,
            currentVersionInfo: AppVersionInfo(shortVersionString: "dev")
        )
        await devVM.checkForUpdatesManually()
        #expect(devService.fetchCallCount == 0)
        #expect(devVM.checkFeedback == .developmentBuild)

        // 配布版でも App Translocation 環境なら差し替え開始を拒否して理由メッセージを表示する
        let openedURLs = Box<[URL]>([])
        let translocatedService = MockAppUpdateService(
            fetchResult: .success(sampleRelease),
            eligibility: .ineligible(reason: .appTranslocation)
        )
        let translocatedVM = UpdateViewModel(
            updateService: translocatedService,
            preferencesStore: InMemoryUpdatePreferencesStore(),
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion,
            openURLHandler: { openedURLs.value.append($0) }
        )
        await translocatedVM.checkForUpdatesManually()
        #expect(translocatedVM.isPromptPresented == true)
        #expect(translocatedVM.installEligibility.isEligible == false)

        await translocatedVM.startUpdateInstall()
        #expect(translocatedService.installCallCount == 0)
        #expect(translocatedVM.promptErrorMessage == UpdateIneligibilityReason.appTranslocation.localizedDescription)

        translocatedVM.openAvailableReleasePage()
        #expect(openedURLs.value == [sampleRelease.htmlURL])
    }

    @Test("手動確認およびインストール時のエラーが日本語メッセージでフィードバックされること")
    func exposesJapaneseErrorFeedbackOnManualCheckAndInstallFailure() async {
        let rateLimitError = AppUpdateError.rateLimited(resetDate: nil)
        let failingCheckService = MockAppUpdateService(fetchResult: .failure(rateLimitError))
        let checkVM = UpdateViewModel(
            updateService: failingCheckService,
            preferencesStore: InMemoryUpdatePreferencesStore(),
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion
        )

        await checkVM.checkForUpdatesManually()
        if case .error(let message, let showReleasesLink) = checkVM.checkFeedback {
            #expect(message.contains("レート制限"))
            #expect(showReleasesLink == true)
        } else {
            Issue.record("エラーフィードバックが設定されていません")
        }

        // インストール時の署名エラーハンドリング
        let failingInstallService = MockAppUpdateService(fetchResult: .success(sampleRelease))
        failingInstallService.installError = AppUpdateError.teamIdentifierMismatch(expected: "TEAM1", actual: "TEAM2")
        let installVM = UpdateViewModel(
            updateService: failingInstallService,
            preferencesStore: InMemoryUpdatePreferencesStore(),
            currentIdentity: releaseIdentity,
            currentVersionInfo: currentVersion
        )
        await installVM.checkForUpdatesManually()
        await installVM.startUpdateInstall()

        #expect(installVM.isInstalling == false)
        #expect(installVM.isTerminatingForUpdate == false)
        #expect(installVM.shouldPreventPromptDismissal == false)
        #expect(installVM.installProgress == nil)
        #expect(installVM.promptErrorMessage?.contains("Team ID") == true)
    }
}
