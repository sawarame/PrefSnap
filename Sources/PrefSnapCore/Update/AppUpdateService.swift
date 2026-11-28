import CryptoKit
import Foundation
import Security

/// リダイレクト先の許可ホスト検証および進捗通知付きダウンロードを行う内部デリゲート。
private final class ValidatingDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let progressHandler: @Sendable (Double?) -> Void
    private let lock = NSLock()

    private var rejectedRedirectURLString: String?
    private var moveError: Error?
    private var completedContinuation: CheckedContinuation<Void, Error>?
    private var hasCompleted = false

    /// デリゲートを初期化する。
    /// - Parameters:
    ///   - destinationURL: ダウンロード完了時にファイルを退避する一時ファイル URL
    ///   - progressHandler: ダウンロード進捗（0.0〜1.0 または不明時 `nil`）を受け取るコールバック
    init(destinationURL: URL, progressHandler: @escaping @Sendable (Double?) -> Void) {
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
    }

    /// ダウンロード完了を待機するための継続を登録する。
    /// - Parameter continuation: 完了または失敗を通知する継続
    func attachContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.completedContinuation = continuation
    }

    /// HTTP リダイレクト発生時にリダイレクト先 URL が許可ホストかを検証し、不許可時は即時中断する。
    /// - Parameters:
    ///   - session: 対象の `URLSession`
    ///   - task: 実行中のタスク
    ///   - response: リダイレクト応答
    ///   - request: 遷移先リクエスト
    ///   - completionHandler: 継続可否を返すハンドラ
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let targetURL = request.url, UpdateURLValidator.isAllowedDownloadURL(targetURL) else {
            lock.lock()
            rejectedRedirectURLString = request.url?.absoluteString ?? "(unknown)"
            lock.unlock()
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    /// ダウンロード進捗の変化を受け取りコールバックへ転送する。
    /// - Parameters:
    ///   - session: 対象の `URLSession`
    ///   - downloadTask: ダウンロードタスク
    ///   - bytesWritten: 今回書き込まれたバイト数
    ///   - totalBytesWritten: 累計書き込みバイト数
    ///   - totalBytesExpectedToWrite: 想定総バイト数
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler(min(max(fraction, 0.0), 1.0))
        } else {
            progressHandler(nil)
        }
    }

    /// ダウンロード完了直後に一時ファイルを指定の作業パスへ同期移動する。
    /// - Parameters:
    ///   - session: 対象の `URLSession`
    ///   - downloadTask: 完了したダウンロードタスク
    ///   - location: システムが一時保存したファイル URL
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // HTTP ステータスが 2xx 以外の場合はファイル移動を行わずエラー扱いとする
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    /// タスクの完了またはエラーを受け取り、待機中の継続へ結果を返す。
    /// - Parameters:
    ///   - session: 対象の `URLSession`
    ///   - task: 完了したタスク
    ///   - error: 発生したエラー（正常完了時は `nil`）
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        let rejectedURL = rejectedRedirectURLString
        let fileMoveError = moveError
        let continuation = completedContinuation
        completedContinuation = nil
        lock.unlock()

        if let rejectedURL {
            continuation?.resume(throwing: AppUpdateError.untrustedDownloadURL(urlString: rejectedURL))
            return
        }

        if let httpResponse = task.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            if let rateLimitError = AppUpdateService.rateLimitErrorIfApplicable(from: httpResponse) {
                continuation?.resume(throwing: rateLimitError)
            } else {
                continuation?.resume(throwing: AppUpdateError.httpError(statusCode: httpResponse.statusCode))
            }
            return
        }

        if let error {
            continuation?.resume(throwing: AppUpdateError.networkError(detail: error.localizedDescription))
            return
        }

        if let fileMoveError {
            continuation?.resume(throwing: AppUpdateError.networkError(detail: fileMoveError.localizedDescription))
            return
        }

        continuation?.resume(returning: ())
    }
}

/// GitHub Releases API 通信・多段階検証・分離ヘルパーによる安全な `.app` 差し替えを提供する本番サービス。
public final class AppUpdateService: AppUpdateServing, @unchecked Sendable {
    /// API チェック時のタイムアウト秒数。
    public static let apiTimeoutInterval: TimeInterval = 15
    /// ZIP ダウンロード時のタイムアウト秒数。
    public static let downloadTimeoutInterval: TimeInterval = 300
    /// ヘルパースクリプトが親アプリ PID 終了を待機する最大秒数。
    public static let helperParentExitTimeoutSeconds: Int = 30

    private let commandRunner: CommandRunning
    private let fileManager: FileManager
    private let latestReleaseAPIURL: URL
    private let currentPIDProvider: @Sendable () -> Int32

    /// アップデートサービスを初期化する。
    /// - Parameters:
    ///   - commandRunner: `/usr/bin/ditto` や `/usr/bin/codesign` を実行するコマンドランナー
    ///   - fileManager: 一時ディレクトリおよびファイル操作に使用する `FileManager`
    ///   - latestReleaseAPIURL: 最新リリース取得 API URL（テスト差し替え用）
    ///   - currentPIDProvider: 現在プロセスの PID を取得するクロージャ
    public init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        fileManager: FileManager = .default,
        latestReleaseAPIURL: URL = AppIdentity.latestReleaseAPIURL,
        currentPIDProvider: @escaping @Sendable () -> Int32 = { ProcessInfo.processInfo.processIdentifier }
    ) {
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.latestReleaseAPIURL = latestReleaseAPIURL
        self.currentPIDProvider = currentPIDProvider
    }

    /// GitHub Releases API から最新の安定版リリースを取得する。
    /// - Parameter currentVersion: `User-Agent` ヘッダに付与する現在バージョン情報
    /// - Returns: 安定版リリース情報（ドラフト／プレリリース除外時は `nil`）
    /// - Throws: 通信失敗・レート制限・HTTP エラー・解析失敗・アセット欠損時に `AppUpdateError`
    public func fetchLatestStableRelease(currentVersion: AppVersionInfo) async throws -> UpdateRelease? {
        let request = Self.makeGitHubAPIRequest(
            url: latestReleaseAPIURL,
            currentVersion: currentVersion,
            timeoutInterval: Self.apiTimeoutInterval
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.apiTimeoutInterval
        configuration.timeoutIntervalForResource = Self.apiTimeoutInterval

        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppUpdateError.networkError(detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse(detail: "HTTP レスポンスを取得できませんでした")
        }

        if let rateLimitError = Self.rateLimitErrorIfApplicable(from: httpResponse) {
            throw rateLimitError
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdateError.httpError(statusCode: httpResponse.statusCode)
        }

        return try GitHubReleaseParser.parseLatestStableRelease(from: data)
    }

    /// 現在の実行環境がアプリ内自動差し替えに対応しているかを判定する。
    /// - Parameters:
    ///   - identity: 実行中アプリの識別情報
    ///   - versionInfo: 実行中アプリのバージョン情報
    /// - Returns: 自動差し替えの実行可否
    public func checkInstallEligibility(
        identity: AppIdentity,
        versionInfo: AppVersionInfo
    ) -> UpdateInstallEligibility {
        UpdateInstallEligibility.evaluateCurrentEnvironment(
            identity: identity,
            versionInfo: versionInfo,
            fileManager: fileManager
        )
    }

    /// 指定リリースの ZIP ダウンロード・SHA-256 検証・展開・`Info.plist` 検証・署名および Team ID 検証・分離ヘルパー起動を一連で実行する。
    /// 途中で失敗した場合は一時作業ディレクトリを必ず削除する。
    /// - Parameters:
    ///   - release: 適用対象のリリース情報
    ///   - targetAppURL: 差し替え対象となる現行 `.app` バンドルの URL
    ///   - progress: 進行フェーズ通知コールバック
    /// - Throws: 各段階での検証失敗・I/O エラー時に `AppUpdateError`
    public func installUpdate(
        _ release: UpdateRelease,
        targetAppURL: URL,
        progress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async throws {
        guard UpdateURLValidator.isAllowedDownloadURL(release.assetDownloadURL) else {
            throw AppUpdateError.untrustedDownloadURL(urlString: release.assetDownloadURL.absoluteString)
        }

        // 一時作業ディレクトリを作成する（ヘルパー起動前に失敗した場合は確実にクリーンアップする）
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PrefSnap-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        var handoffToHelperSucceeded = false
        defer {
            if !handoffToHelperSucceeded {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }

        let downloadedZipURL = stagingDirectory.appendingPathComponent(release.assetName, isDirectory: false)
        let extractedDirURL = stagingDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirURL, withIntermediateDirectories: true)

        // 1. 進捗通知・リダイレクトホスト検証付きで一時ディレクトリへダウンロードする
        progress(.downloading(fractionCompleted: 0.0))
        try await downloadZipWithRedirectValidation(
            from: release.assetDownloadURL,
            to: downloadedZipURL,
            progress: { fraction in
                progress(.downloading(fractionCompleted: fraction))
            }
        )

        // 2. API のアセット digest が存在する場合は CryptoKit で SHA-256 を検証する
        if let expectedDigest = release.assetDigestSHA256 {
            progress(.verifyingChecksum)
            let actualDigest = try Self.sha256Hex(ofFileAt: downloadedZipURL)
            guard actualDigest == expectedDigest.lowercased() else {
                throw AppUpdateError.checksumMismatch(expected: expectedDigest.lowercased(), actual: actualDigest)
            }
        }

        // 3. `/usr/bin/ditto -x -k` で一時ディレクトリへ展開し、`PrefSnap.app` の存在を確認する
        progress(.extracting)
        let dittoOutput: CommandOutput
        do {
            dittoOutput = try commandRunner.run(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", downloadedZipURL.path, extractedDirURL.path]
            )
        } catch {
            throw AppUpdateError.extractionFailed(detail: error.localizedDescription)
        }

        guard dittoOutput.exitCode == 0 else {
            let reason = dittoOutput.stderr.isEmpty ? "exitCode=\(dittoOutput.exitCode)" : dittoOutput.stderr
            throw AppUpdateError.extractionFailed(detail: reason)
        }

        let extractedAppURL = extractedDirURL.appendingPathComponent("\(AppIdentity.releaseAppName).app", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: extractedAppURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppUpdateError.invalidBundle(detail: "展開されたアーカイブ内に \(AppIdentity.releaseAppName).app が見つかりませんでした")
        }

        // 4. 展開された `PrefSnap.app/Contents/Info.plist` の Bundle ID とバージョンを検証する
        progress(.verifyingBundle)
        try Self.validateExtractedAppInfoPlist(
            at: extractedAppURL,
            expectedBundleIdentifier: AppIdentity.releaseBundleIdentifier,
            expectedVersion: release.version
        )

        // 5. Security フレームワークおよび `codesign --verify --deep --strict` でコード署名を検証する
        try verifyCodeSignature(of: extractedAppURL)

        // 6. 現行アプリと展開済みアプリの Team ID が両方非空かつ完全一致することを検証する
        try verifyMatchingTeamIdentifier(currentAppURL: targetAppURL, extractedAppURL: extractedAppURL)

        // 7. 分離ヘルパースクリプトを生成して標準入出力を /dev/null に切り離して起動する
        progress(.preparingReplacement)
        let parentPID = currentPIDProvider()
        let backupAppURL = Self.makeBackupAppURL(for: targetAppURL, parentPID: parentPID)
        let scriptContent = Self.generateReplacementHelperScript(
            parentPID: parentPID,
            targetAppURL: targetAppURL,
            stagedAppURL: extractedAppURL,
            backupAppURL: backupAppURL,
            stagingDirectoryURL: stagingDirectory,
            timeoutSeconds: Self.helperParentExitTimeoutSeconds
        )

        let scriptURL = stagingDirectory.appendingPathComponent("replace-prefsnap.sh", isDirectory: false)
        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw AppUpdateError.helperLaunchFailed(detail: "ヘルパースクリプトの書き出しに失敗しました: \(error.localizedDescription)")
        }

        try launchDetachedHelperScript(at: scriptURL)
        handoffToHelperSucceeded = true
    }

    // MARK: - 純粋ヘルパー（単体テスト対象）

    /// GitHub Releases API 用の標準リクエスト（ヘッダ・キャッシュ無効・タイムアウト設定済み）を生成する。
    /// - Parameters:
    ///   - url: リクエスト対象 URL
    ///   - currentVersion: `User-Agent` に含める現在バージョン情報
    ///   - timeoutInterval: タイムアウト秒数
    /// - Returns: 構成済みの `URLRequest`
    public static func makeGitHubAPIRequest(
        url: URL,
        currentVersion: AppVersionInfo,
        timeoutInterval: TimeInterval = apiTimeoutInterval
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("\(AppIdentity.releaseAppName)/\(currentVersion.userAgentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 指定ファイルの SHA-256 ダイジェストを `CryptoKit` を用いてチャンク単位で計算し、小文字 64 桁の 16 進文字列として返す。
    /// - Parameter url: 計算対象のファイル URL
    /// - Returns: 小文字 64 桁の SHA-256 16 進文字列
    /// - Throws: ファイル読み込み失敗時に `AppUpdateError.networkError`
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AppUpdateError.networkError(detail: "ダウンロードファイルの読み込みに失敗しました: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 64 * 1024
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw AppUpdateError.networkError(detail: "SHA-256 計算中のファイル読み込みに失敗しました: \(error.localizedDescription)")
            }
            guard let chunk, !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 展開された `.app` バンドルの `Contents/Info.plist` を読み込み、
    /// `CFBundleIdentifier` および `CFBundleShortVersionString` が期待値と一致するかを検証する。
    /// - Parameters:
    ///   - appBundleURL: 展開済み `.app` バンドルの URL
    ///   - expectedBundleIdentifier: 期待する Bundle Identifier（既定値は `dev.prefsnap.PrefSnap`）
    ///   - expectedVersion: 期待するセマンティックバージョン
    /// - Throws: `Info.plist` 欠損・解析失敗・Bundle ID 不一致・バージョン不一致時に `AppUpdateError.invalidBundle`
    public static func validateExtractedAppInfoPlist(
        at appBundleURL: URL,
        expectedBundleIdentifier: String = AppIdentity.releaseBundleIdentifier,
        expectedVersion: SemanticVersion
    ) throws {
        let infoPlistURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)

        let data: Data
        do {
            data = try Data(contentsOf: infoPlistURL)
        } catch {
            throw AppUpdateError.invalidBundle(detail: "Info.plist を読み込めませんでした: \(error.localizedDescription)")
        }

        let rawPlist: Any
        do {
            rawPlist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw AppUpdateError.invalidBundle(detail: "Info.plist の解析に失敗しました: \(error.localizedDescription)")
        }

        guard let dictionary = rawPlist as? [String: Any] else {
            throw AppUpdateError.invalidBundle(detail: "Info.plist のルート構造が不正です")
        }

        guard let bundleID = dictionary["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleIdentifier else {
            let actualID = (dictionary["CFBundleIdentifier"] as? String) ?? "(未設定)"
            throw AppUpdateError.invalidBundle(detail: "CFBundleIdentifier が一致しません（期待: \(expectedBundleIdentifier), 実際: \(actualID)）")
        }

        guard let shortVersionString = dictionary["CFBundleShortVersionString"] as? String,
              let parsedVersion = SemanticVersion(shortVersionString) else {
            let actualVersion = (dictionary["CFBundleShortVersionString"] as? String) ?? "(未設定)"
            throw AppUpdateError.invalidBundle(detail: "CFBundleShortVersionString が不正です（\(actualVersion)）")
        }

        guard parsedVersion == expectedVersion else {
            throw AppUpdateError.invalidBundle(detail: "バージョンが一致しません（期待: \(expectedVersion.normalized), 実際: \(parsedVersion.normalized)）")
        }
    }

    /// 既存 `.app` と同一親ディレクトリ内に配置する一時退避パス（例: `.PrefSnap.app.prefsnap-backup-<PID>`）を生成する。
    /// - Parameters:
    ///   - targetAppURL: 現行 `.app` バンドルの URL
    ///   - parentPID: 現アプリのプロセス ID
    /// - Returns: 同一親ディレクトリ内の退避パス URL
    public static func makeBackupAppURL(for targetAppURL: URL, parentPID: Int32) -> URL {
        let parentDir = targetAppURL.deletingLastPathComponent()
        let backupName = ".\(targetAppURL.lastPathComponent).prefsnap-backup-\(parentPID)"
        return parentDir.appendingPathComponent(backupName, isDirectory: true)
    }

    /// POSIX シェル向けに文字列を安全にシングルクォートエスケープする。
    /// - Parameter value: エスケープ対象の文字列
    /// - Returns: シングルクォートで囲まれた安全なシェル文字列
    public static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// 現アプリの終了待機・既存 `.app` 退避・新 `.app` 差し替え（失敗時ロールバック）・隔離属性除去・再起動・後始末を行う
    /// POSIX シェルスクリプトを生成する。
    /// - Parameters:
    ///   - parentPID: 終了を待機する現行アプリの PID
    ///   - targetAppURL: 元の `.app` 配置パス
    ///   - stagedAppURL: 検証済みの新 `.app` パス
    ///   - backupAppURL: 同一親ディレクトリ内の退避パス
    ///   - stagingDirectoryURL: 完了後に削除する一時作業ディレクトリ
    ///   - timeoutSeconds: 現行アプリ終了待機の最大秒数（既定値 30 秒）
    /// - Returns: 生成された POSIX シェルスクリプト本文
    public static func generateReplacementHelperScript(
        parentPID: Int32,
        targetAppURL: URL,
        stagedAppURL: URL,
        backupAppURL: URL,
        stagingDirectoryURL: URL,
        timeoutSeconds: Int = helperParentExitTimeoutSeconds
    ) -> String {
        let safeTimeout = max(1, timeoutSeconds)
        return """
        #!/bin/sh
        # PrefSnap アプリ内自動アップデート用 分離差し替えヘルパースクリプト
        set -u
        trap '' HUP

        PARENT_PID=\(parentPID)
        TARGET_APP=\(shellQuoted(targetAppURL.path))
        STAGED_APP=\(shellQuoted(stagedAppURL.path))
        BACKUP_APP=\(shellQuoted(backupAppURL.path))
        STAGING_DIR=\(shellQuoted(stagingDirectoryURL.path))
        MAX_WAIT_SECONDS=\(safeTimeout)

        cleanup_staging() {
            /bin/rm -rf "$STAGING_DIR" >/dev/null 2>&1 || true
        }

        # 1. 現アプリ PID の終了を最大 MAX_WAIT_SECONDS 秒待機する
        ELAPSED=0
        while /bin/kill -0 "$PARENT_PID" >/dev/null 2>&1; do
            if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
                cleanup_staging
                exit 1
            fi
            /bin/sleep 1
            ELAPSED=$((ELAPSED + 1))
        done

        # 既存の退避パスが残存している場合は事前に削除する
        if [ -e "$BACKUP_APP" ]; then
            /bin/rm -rf "$BACKUP_APP" >/dev/null 2>&1 || true
        fi

        # 2. 既存 .app を同一親ディレクトリ内の退避パスへ一時リネームする
        if ! /bin/mv "$TARGET_APP" "$BACKUP_APP"; then
            cleanup_staging
            exit 1
        fi

        # 3. 検証済み新 .app を元の配置パスへ移動する（ボリューム跨ぎ時は ditto へフォールバック）
        INSTALLED=0
        if /bin/mv "$STAGED_APP" "$TARGET_APP" >/dev/null 2>&1; then
            INSTALLED=1
        else
            /bin/rm -rf "$TARGET_APP" >/dev/null 2>&1 || true
            if /usr/bin/ditto "$STAGED_APP" "$TARGET_APP" >/dev/null 2>&1; then
                INSTALLED=1
            fi
        fi

        # 差し替えに失敗した場合は退避先から旧 .app を復元（ロールバック）して終了する
        if [ "$INSTALLED" -ne 1 ]; then
            /bin/rm -rf "$TARGET_APP" >/dev/null 2>&1 || true
            /bin/mv "$BACKUP_APP" "$TARGET_APP" >/dev/null 2>&1 || true
            cleanup_staging
            exit 1
        fi

        # 4. 隔離属性を除去し、新バージョンを起動する
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
        /usr/bin/open -n "$TARGET_APP" >/dev/null 2>&1 || true

        # 5. 退避済み旧 .app および一時作業ディレクトリを削除する
        /bin/rm -rf "$BACKUP_APP" >/dev/null 2>&1 || true
        cleanup_staging
        exit 0
        """
    }

    /// HTTP レスポンスから GitHub API レート制限エラーに該当するかを判定する。
    /// - Parameter response: 判定対象の `HTTPURLResponse`
    /// - Returns: レート制限に該当する場合は `AppUpdateError.rateLimited`、該当しない場合は `nil`
    public static func rateLimitErrorIfApplicable(from response: HTTPURLResponse) -> AppUpdateError? {
        let statusCode = response.statusCode
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let isRateLimited = statusCode == 429 || (statusCode == 403 && remaining == "0")
        guard isRateLimited else { return nil }

        let resetDate: Date?
        if let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let timestamp = TimeInterval(resetHeader) {
            resetDate = Date(timeIntervalSince1970: timestamp)
        } else {
            resetDate = nil
        }
        return .rateLimited(resetDate: resetDate)
    }

    // MARK: - 内部処理

    /// リダイレクト先ホスト検証と進捗通知を伴う ZIP ダウンロードを実行する。
    /// - Parameters:
    ///   - url: ダウンロード元 URL
    ///   - destinationURL: 保存先の一時ファイル URL
    ///   - progress: ダウンロード進捗（0.0〜1.0 または不明時 `nil`）の通知クロージャ
    /// - Throws: 不正リダイレクト・HTTP エラー・ネットワーク失敗時に `AppUpdateError`
    private func downloadZipWithRedirectValidation(
        from url: URL,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let delegate = ValidatingDownloadSessionDelegate(
            destinationURL: destinationURL,
            progressHandler: progress
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.downloadTimeoutInterval
        configuration.timeoutIntervalForResource = Self.downloadTimeoutInterval

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.downloadTimeoutInterval
        )
        request.setValue("\(AppIdentity.releaseAppName)/update", forHTTPHeaderField: "User-Agent")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.attachContinuation(continuation)
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    /// `Security` フレームワーク（`SecStaticCodeCheckValidity`）および `/usr/bin/codesign --verify --deep --strict`
    /// の両方で展開済みアプリバンドルのコード署名を検証する。
    /// - Parameter appBundleURL: 検証対象の `.app` バンドル URL
    /// - Throws: 署名検証失敗時に `AppUpdateError.codeSignatureInvalid`
    private func verifyCodeSignature(of appBundleURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appBundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw AppUpdateError.codeSignatureInvalid(detail: "SecStaticCodeCreateWithPath 失敗（OSStatus: \(createStatus)）")
        }

        let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let validityStatus = SecStaticCodeCheckValidity(staticCode, validityFlags, nil)
        guard validityStatus == errSecSuccess else {
            throw AppUpdateError.codeSignatureInvalid(detail: "SecStaticCodeCheckValidity 失敗（OSStatus: \(validityStatus)）")
        }

        let codesignOutput: CommandOutput
        do {
            codesignOutput = try commandRunner.run(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", appBundleURL.path]
            )
        } catch {
            throw AppUpdateError.codeSignatureInvalid(detail: "codesign 実行失敗: \(error.localizedDescription)")
        }

        guard codesignOutput.exitCode == 0 else {
            let reason = codesignOutput.stderr.isEmpty ? "exitCode=\(codesignOutput.exitCode)" : codesignOutput.stderr
            throw AppUpdateError.codeSignatureInvalid(detail: reason)
        }
    }

    /// 現在実行中アプリと展開済みアプリの Developer ID Team ID（`kSecCodeInfoTeamIdentifier`）を取得し、
    /// 両方非空かつ完全一致することを検証する。
    /// - Parameters:
    ///   - currentAppURL: 現在実行中 `.app` バンドルの URL
    ///   - extractedAppURL: 展開済み `.app` バンドルの URL
    /// - Throws: Team ID 未設定または不一致時に `AppUpdateError.teamIdentifierMismatch`
    private func verifyMatchingTeamIdentifier(currentAppURL: URL, extractedAppURL: URL) throws {
        let currentTeamID = Self.extractTeamIdentifier(at: currentAppURL)
        let extractedTeamID = Self.extractTeamIdentifier(at: extractedAppURL)

        guard let currentTeamID, !currentTeamID.isEmpty,
              let extractedTeamID, !extractedTeamID.isEmpty,
              currentTeamID == extractedTeamID else {
            throw AppUpdateError.teamIdentifierMismatch(expected: currentTeamID, actual: extractedTeamID)
        }
    }

    /// 指定された `.app` バンドルの署名情報から Developer ID Team ID（`kSecCodeInfoTeamIdentifier`）を取得する。
    /// - Parameter appBundleURL: 対象 `.app` バンドルの URL
    /// - Returns: 非空の Team ID 文字列（未署名・アドホック署名・取得失敗時は `nil`）
    public static func extractTeamIdentifier(at appBundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appBundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInfo: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, infoFlags, &signingInfo) == errSecSuccess,
              let dictionary = signingInfo as? [String: Any],
              let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return teamID
    }

    /// 生成済みヘルパースクリプトを標準入出力 `/dev/null` で切り離してバックグラウンド起動する。
    /// - Parameter scriptURL: 実行する POSIX シェルスクリプトの URL
    /// - Throws: 起動失敗時に `AppUpdateError.helperLaunchFailed`
    private func launchDetachedHelperScript(at scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppUpdateError.helperLaunchFailed(detail: error.localizedDescription)
        }
    }
}
