import Foundation
import Observation
import OSLog

/// 設定画面に表示するアップデート確認結果のフィードバック種別。
public enum UpdateCheckFeedback: Equatable, Sendable {
    /// 現在のバージョンが最新である。
    case upToDate(version: SemanticVersion)
    /// 新しい安定版リリースが利用可能である。
    case updateAvailable(release: UpdateRelease)
    /// ローカル開発版のため自動アップデート対象外である。
    case developmentBuild
    /// 確認処理中にエラーが発生した。
    case error(message: String, showReleasesLink: Bool)
}

/// アプリ内自動アップデート機能の状態遷移・設定保存・`isBusy` ガード・エラーハンドリングを担う ViewModel。
@Observable
@MainActor
public final class UpdateViewModel {
    /// 起動時自動チェック設定の ON/OFF（初期値 OFF・`UserDefaults` へ保存）。
    public var autoCheckForUpdates: Bool {
        didSet {
            if preferencesStore.autoCheckForUpdates != autoCheckForUpdates {
                preferencesStore.autoCheckForUpdates = autoCheckForUpdates
            }
        }
    }

    /// アップデート確認を実行中かどうか。
    public private(set) var isChecking = false
    /// アップデート適用（ダウンロード〜検証〜差し替え準備）を実行中かどうか。
    public private(set) var isInstalling = false
    /// 適用処理中のフェーズおよび進捗。
    public private(set) var installProgress: UpdateInstallProgress?
    /// 検出された最新の利用可能リリース。
    public private(set) var availableRelease: UpdateRelease?
    /// メインウィンドウ上の更新確認シートの表示状態。
    public var isPromptPresented = false
    /// 現在の実行環境における自動差し替え実行可否。
    public private(set) var installEligibility: UpdateInstallEligibility
    /// 設定画面へ表示する最新の確認結果フィードバック。
    public private(set) var checkFeedback: UpdateCheckFeedback?
    /// 更新確認シート内へ表示するエラーまたは処理中ガードの案内メッセージ。
    public var promptErrorMessage: String?

    /// 実行中アプリの識別情報。
    public let currentIdentity: AppIdentity
    /// 実行中アプリのバージョン情報。
    public let currentVersionInfo: AppVersionInfo

    private let updateService: any AppUpdateServing
    private let preferencesStore: any UpdatePreferencesStoring
    private let isAppBusyProvider: @MainActor () -> Bool
    private let openURLHandler: @MainActor (URL) -> Void
    private let terminateForUpdateHandler: @MainActor () -> Void
    private var hasPerformedStartupCheck = false
    private let logger = Logger(subsystem: AppIdentity.releaseBundleIdentifier, category: "Update")

    /// メニューやボタンで現在アップデート確認を実行可能かどうかを返す。
    public var canCheckForUpdates: Bool {
        !isChecking && !isInstalling
    }

    /// PrefSnap 本体がスキャン・適用・ロールバック処理中かどうかを返す。
    public var isAppOperationBusy: Bool {
        isAppBusyProvider()
    }

    /// バージョン遷移の表示テキスト（例: `PrefSnap: 0.1.4 → 0.1.5`）。
    public var versionTransitionText: String {
        let currentLabel = currentVersionInfo.semanticVersion?.normalized ?? currentVersionInfo.shortVersionString
        let nextLabel = availableRelease?.version.normalized ?? "-"
        return "\(currentIdentity.displayName): \(currentLabel) → \(nextLabel)"
    }

    /// アップデート ViewModel を初期化する。
    /// - Parameters:
    ///   - updateService: リリース確認・適用サービス
    ///   - preferencesStore: 自動チェック設定・スキップバージョン永続化ストア
    ///   - currentIdentity: 実行中アプリの識別情報
    ///   - currentVersionInfo: 実行中アプリのバージョン情報
    ///   - isAppBusyProvider: PrefSnap 本体処理（スキャン・適用・ロールバック）が実行中かを返すクロージャ
    ///   - openURLHandler: 外部ブラウザで URL を開くクロージャ
    ///   - terminateForUpdateHandler: ヘルパー起動完了後に確認ダイアログなしでアプリを終了するクロージャ
    public init(
        updateService: any AppUpdateServing = AppUpdateService(),
        preferencesStore: any UpdatePreferencesStoring = UserDefaultsUpdatePreferencesStore(),
        currentIdentity: AppIdentity = .current(),
        currentVersionInfo: AppVersionInfo = .current(),
        isAppBusyProvider: @escaping @MainActor () -> Bool = { false },
        openURLHandler: @escaping @MainActor (URL) -> Void = { _ in },
        terminateForUpdateHandler: @escaping @MainActor () -> Void = {}
    ) {
        self.updateService = updateService
        self.preferencesStore = preferencesStore
        self.currentIdentity = currentIdentity
        self.currentVersionInfo = currentVersionInfo
        self.isAppBusyProvider = isAppBusyProvider
        self.openURLHandler = openURLHandler
        self.terminateForUpdateHandler = terminateForUpdateHandler
        self.autoCheckForUpdates = preferencesStore.autoCheckForUpdates
        self.installEligibility = updateService.checkInstallEligibility(
            identity: currentIdentity,
            versionInfo: currentVersionInfo
        )
    }

    /// 起動時の自動バックグラウンドチェックを実行する（1 アプリ起動につき 1 回のみ）。
    /// 設定 OFF・開発版・非 SemVer の場合は実行せず、通信エラーやスキップ済みバージョン時もダイアログを出さずに静かに終了する。
    public func performAutomaticCheckIfNeeded() async {
        guard !hasPerformedStartupCheck else { return }
        hasPerformedStartupCheck = true

        guard UpdateCheckPolicy.shouldPerformAutomaticCheck(
            autoCheckEnabled: autoCheckForUpdates,
            identity: currentIdentity,
            currentVersion: currentVersionInfo
        ) else {
            return
        }

        await performCheck(trigger: .automatic)
    }

    /// ユーザー操作（設定画面ボタンまたはメニューバー）による手動アップデート確認を実行する。
    public func checkForUpdatesManually() async {
        await performCheck(trigger: .manual)
    }

    /// 検出済みの更新確認シートを再度開く（設定画面から再表示する用途）。
    public func presentAvailableUpdatePrompt() {
        guard availableRelease != nil else { return }
        refreshInstallEligibility()
        promptErrorMessage = nil
        isPromptPresented = true
    }

    /// 現在提示中のバージョンをスキップ対象として保存し、更新確認シートを閉じる。
    /// インストール実行中はキャンセルを抑止する。
    public func skipAvailableVersion() {
        guard !isInstalling else { return }
        if let release = availableRelease {
            preferencesStore.skippedUpdateVersion = release.version.normalized
        }
        promptErrorMessage = nil
        isPromptPresented = false
    }

    /// スキップ保存せずに更新確認シートを閉じる（「後で」）。
    /// インストール実行中はキャンセルを抑止する。
    public func deferUpdate() {
        guard !isInstalling else { return }
        promptErrorMessage = nil
        isPromptPresented = false
    }

    /// 検出された安定版リリースへのアプリ内自動アップデートを開始する。
    /// PrefSnap 本体が処理中（`isBusy == true`）または差し替え不可環境の場合は開始をガードして案内を表示する。
    public func startUpdateInstall() async {
        guard !isInstalling, let release = availableRelease else { return }

        // スキャン・適用・ロールバック処理中は自動アップデートを開始できないようにガードする
        if isAppBusyProvider() {
            promptErrorMessage = AppUpdateError.appIsBusy.localizedDescription
            return
        }

        refreshInstallEligibility()
        guard case .eligible(let targetAppURL) = installEligibility else {
            promptErrorMessage = installEligibility.ineligibilityMessage
            return
        }

        isInstalling = true
        promptErrorMessage = nil
        installProgress = .downloading(fractionCompleted: 0.0)

        do {
            try await updateService.installUpdate(release, targetAppURL: targetAppURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.installProgress = progress
                }
            }
            // 分離ヘルパー起動が完了したら確認ダイアログに阻害されずにアプリを終了する
            terminateForUpdateHandler()
        } catch let updateError as AppUpdateError {
            isInstalling = false
            installProgress = nil
            promptErrorMessage = updateError.localizedDescription
            checkFeedback = .error(
                message: updateError.localizedDescription,
                showReleasesLink: updateError.shouldSuggestManualDownload
            )
        } catch {
            isInstalling = false
            installProgress = nil
            let message = error.localizedDescription
            promptErrorMessage = message
            checkFeedback = .error(message: message, showReleasesLink: true)
        }
    }

    /// GitHub Releases の一覧ページを外部ブラウザで開く。
    public func openReleasesPage() {
        openURLHandler(AppIdentity.releasesPageURL)
    }

    /// 検出されたリリースの検証済み GitHub リリースページを外部ブラウザで開く。
    public func openAvailableReleasePage() {
        let url = availableRelease?.htmlURL ?? AppIdentity.releasesPageURL
        openURLHandler(url)
    }

    /// 実行環境の自動差し替え可否を最新状態へ更新する。
    public func refreshInstallEligibility() {
        installEligibility = updateService.checkInstallEligibility(
            identity: currentIdentity,
            versionInfo: currentVersionInfo
        )
    }

    /// 自動・手動共通のアップデート確認処理を実行する。
    /// - Parameter trigger: 実行トリガー（自動または手動）
    private func performCheck(trigger: UpdateCheckTrigger) async {
        guard !isChecking, !isInstalling else { return }

        // 開発版での手動確認時は外部通信を行わず、開発版である旨を明確に案内する
        if currentIdentity.isDevelopmentBuild || currentVersionInfo.semanticVersion == nil {
            if trigger == .manual {
                refreshInstallEligibility()
                checkFeedback = .developmentBuild
            }
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let latestRelease = try await updateService.fetchLatestStableRelease(currentVersion: currentVersionInfo)
            let decision = UpdateCheckPolicy.evaluate(
                latestRelease: latestRelease,
                identity: currentIdentity,
                currentVersion: currentVersionInfo,
                skippedVersion: preferencesStore.skippedUpdateVersion,
                trigger: trigger
            )

            switch decision {
            case .developmentBuild:
                if trigger == .manual {
                    checkFeedback = .developmentBuild
                }
            case .upToDate(let currentSemVer):
                availableRelease = nil
                if trigger == .manual {
                    checkFeedback = .upToDate(version: currentSemVer)
                }
            case .skipped(let release):
                // 自動チェックでスキップ済みバージョンに一致した場合はダイアログを抑止する
                availableRelease = release
            case .updateAvailable(let release):
                availableRelease = release
                refreshInstallEligibility()
                promptErrorMessage = nil
                checkFeedback = .updateAvailable(release: release)
                isPromptPresented = true
            }
        } catch let updateError as AppUpdateError {
            if trigger == .automatic {
                // 起動時自動チェックでの通信失敗・レート制限等はエラー表示を出さず静かにログ出力のみで終了する
                logger.info("起動時アップデート自動チェックを終了しました: \(updateError.localizedDescription, privacy: .public)")
            } else {
                checkFeedback = .error(
                    message: updateError.localizedDescription,
                    showReleasesLink: updateError.shouldSuggestManualDownload
                )
            }
        } catch {
            if trigger == .automatic {
                logger.info("起動時アップデート自動チェックを終了しました: \(error.localizedDescription, privacy: .public)")
            } else {
                checkFeedback = .error(message: error.localizedDescription, showReleasesLink: true)
            }
        }
    }
}
