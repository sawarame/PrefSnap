import AppKit
import Darwin
import PrefSnapCore
import SwiftUI

/// SwiftUI が内部で設定する `NSWindowDelegate` の挙動を維持したまま、
/// ウィンドウクローズ判定（`windowShouldClose(_:)`）のみを安全にフックするためのプロキシ。
@MainActor
final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    /// SwiftUI が元々割り当てていたウィンドウデリゲート（その他すべてのメソッドの転送先）。
    nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?
    /// ウィンドウクローズを許可してよいか判定するコールバック。
    private let shouldCloseHandler: @MainActor () -> Bool
    /// 元のデリゲートによってクローズが取り消された際に状態をリセットするコールバック。
    private let closeCancelledHandler: @MainActor () -> Void

    /// ウィンドウデリゲートプロキシを初期化する。
    /// - Parameters:
    ///   - originalDelegate: 元の `NSWindowDelegate`（存在しない場合は `nil`）
    ///   - shouldCloseHandler: ウィンドウクローズ可否を判定するクロージャ
    ///   - closeCancelledHandler: 元のデリゲートがクローズを拒否した際に呼び出すクロージャ
    init(
        originalDelegate: (any NSWindowDelegate)?,
        shouldCloseHandler: @escaping @MainActor () -> Bool,
        closeCancelledHandler: @escaping @MainActor () -> Void
    ) {
        self.originalDelegate = originalDelegate
        self.shouldCloseHandler = shouldCloseHandler
        self.closeCancelledHandler = closeCancelledHandler
        super.init()
    }

    /// 指定されたセレクタに自身または元のデリゲートが応答可能かどうかを返す。
    /// - Parameter aSelector: 問い合わせ対象のセレクタ
    /// - Returns: 応答可能な場合は `true`、そうでなければ `false`
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    /// 自身が直接実装していない `NSWindowDelegate` メソッドを元のデリゲートへ転送する。
    /// - Parameter aSelector: 転送対象のセレクタ
    /// - Returns: 転送先オブジェクト（転送不要の場合は `nil`）
    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) {
            return nil
        }
        if let originalDelegate, originalDelegate.responds(to: aSelector) {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }

    /// ウィンドウが閉じられようとした際に処理中確認を実行し、許可時のみ元のデリゲートへ委譲する。
    /// - Parameter sender: 閉じられようとしている `NSWindow`
    /// - Returns: ウィンドウを閉じる場合は `true`、キャンセルする場合は `false`
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldCloseHandler() else {
            return false
        }

        let originalAllows = originalDelegate?.windowShouldClose?(sender) ?? true
        if !originalAllows {
            closeCancelledHandler()
        }
        return originalAllows
    }
}

/// `swift run PrefSnap` 経由で起動された場合も通常の macOS アプリとして
/// Dock 表示・前面フォーカス・Dock アイコン設定を有効にし、
/// ウィンドウクローズ時のアプリ終了および処理中の終了確認を制御するための AppDelegate。
@MainActor
final class PrefSnapAppDelegate: NSObject, NSApplicationDelegate {
    /// 現在の処理中状態（`AppViewModel.isBusy`）を取得するクロージャ。
    private var isBusyProvider: @MainActor () -> Bool = { false }
    /// 終了判定・二重確認防止・再入防止を担当するコーディネーター。
    private var terminationCoordinator: AppTerminationCoordinator?
    /// 自動アップデート再起動時の終了シーケンスを制御するエグゼキューター。
    private var automaticUpdateTerminationExecutor: AutomaticUpdateTerminationExecutor?
    /// メインウィンドウへ設定したデリゲートプロキシの強参照保持用プロパティ。
    private var windowDelegateProxy: WindowCloseDelegateProxy?
    /// 現在フック済みのメインウィンドウ。
    private weak var attachedMainWindow: NSWindow?

    /// AppDelegate を初期化する。
    override init() {
        super.init()
        self.terminationCoordinator = AppTerminationCoordinator(
            isBusyProvider: { [weak self] in
                self?.isBusyProvider() ?? false
            },
            confirmTermination: { [weak self] trigger in
                self?.presentBusyTerminationAlert(trigger: trigger) ?? .continueProcessing
            }
        )
    }

    /// 処理中状態を参照するためのクロージャを登録する。
    /// - Parameter isBusyProvider: 処理中であれば `true` を返すクロージャ
    func configure(isBusyProvider: @escaping @MainActor () -> Bool) {
        self.isBusyProvider = isBusyProvider
    }

    /// 自動アップデート再起動に伴う終了要求時に終了確認ダイアログをバイパスできるよう準備する。
    func prepareForAutomaticTermination() {
        terminationCoordinator?.prepareForAutomaticTermination()
    }

    /// 自動アップデート再起動に伴うアプリ終了シーケンス（終了確認バイパス・シート解除・通常終了・フォールバック強制終了）を開始する。
    func beginAutomaticUpdateTermination() {
        if let existingExecutor = automaticUpdateTerminationExecutor {
            existingExecutor.execute()
            return
        }

        let executor = AutomaticUpdateTerminationExecutor(
            prepareTermination: { [weak self] in
                self?.prepareForAutomaticTermination()
            },
            dismissSheets: {
                Self.dismissAllAttachedSheets(in: NSApplication.shared)
            },
            requestGracefulTermination: {
                NSApplication.shared.terminate(nil)
            },
            forceExit: { code in
                Darwin.exit(code)
            }
        )
        automaticUpdateTerminationExecutor = executor
        executor.execute()
    }

    /// 指定された `NSApplication` 上の全ウィンドウにアタッチされているシートを AppKit レベルで明示的に終了する。
    /// - Parameter application: シートを終了させる対象の `NSApplication`
    static func dismissAllAttachedSheets(in application: NSApplication) {
        for window in application.windows {
            // ネストされたシートも含めて後ろから順に確実に閉じる
            for sheet in window.sheets.reversed() {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
            if let attachedSheet = window.attachedSheet {
                window.endSheet(attachedSheet)
                attachedSheet.orderOut(nil)
            }
        }
    }

    /// メインウィンドウへクローズ制御用のデリゲートプロキシを接続する。
    /// - Parameter window: フック対象となるメインの `NSWindow`
    func attachMainWindow(_ window: NSWindow) {
        // すでに同じウィンドウへ自身のプロキシを設定済みなら再接続しない
        if attachedMainWindow === window, window.delegate === windowDelegateProxy {
            return
        }

        // 誤って自身のプロキシを元のデリゲートとしてラップしないよう保護する
        let existingDelegate: (any NSWindowDelegate)? = (window.delegate is WindowCloseDelegateProxy)
            ? nil
            : window.delegate

        let proxy = WindowCloseDelegateProxy(
            originalDelegate: existingDelegate,
            shouldCloseHandler: { [weak self] in
                self?.terminationCoordinator?.shouldAllowWindowClose() ?? true
            },
            closeCancelledHandler: { [weak self] in
                self?.terminationCoordinator?.cancelPendingWindowCloseTermination()
            }
        )

        windowDelegateProxy = proxy
        attachedMainWindow = window
        // originalDelegate を保持し終えたプロキシを割り当て、AppKit の responds(to:) キャッシュを正しく構築させる
        window.delegate = proxy
    }

    /// アプリ起動完了時に Dock 表示・ランタイムアイコン設定・前面フォーカスを適用する。
    /// - Parameter notification: 起動完了通知
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        applyRuntimeDockIconIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 最後のウィンドウが閉じた後にアプリを自動的に終了させるかどうかを返す。
    /// - Parameter sender: 対象の `NSApplication`
    /// - Returns: アプリを終了させる場合は `true`
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        terminationCoordinator?.shouldTerminateAfterLastWindowClosed() ?? true
    }

    /// アプリ終了要求（メニューバー / ⌘Q / ウィンドウクローズ後の終了）を許可してよいか判定する。
    /// - Parameter sender: 対象の `NSApplication`
    /// - Returns: 即時終了する場合は `.terminateNow`、キャンセルする場合は `.terminateCancel`
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let shouldTerminate = terminationCoordinator?.shouldAllowApplicationTermination() ?? true
        return shouldTerminate ? .terminateNow : .terminateCancel
    }

    /// アプリが通常終了フローへ入った際に、自動アップデート用のフォールバック終了タスクをキャンセルする。
    /// - Parameter notification: 終了直前通知
    func applicationWillTerminate(_ notification: Notification) {
        automaticUpdateTerminationExecutor?.cancelFallback()
    }

    /// 処理中の終了確認ダイアログ（`NSAlert`）を表示し、ユーザーの選択結果を返す。
    /// - Parameter trigger: 確認ダイアログが呼び出された操作種別
    /// - Returns: ユーザーが選択したアクション（`continueProcessing` または `terminate`）
    private func presentBusyTerminationAlert(trigger: TerminationTrigger) -> TerminationConfirmationChoice {
        // 最小化や非表示状態から ⌘Q が押された場合もダイアログを確実に前面へ表示する
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "処理を実行中です。終了してもよろしいですか？"
        alert.informativeText = "現在、設定の読み取り・差分計算・適用またはロールバック処理が進行中です。途中で終了すると処理が完了しない可能性があります。"

        let continueButton = alert.addButton(withTitle: "処理を続ける")
        continueButton.keyEquivalent = "\r"

        let terminateButton = alert.addButton(withTitle: "終了する")
        terminateButton.hasDestructiveAction = true
        // Escape キー等で誤って「終了する」が選ばれないようキーショートカットを割り当てない
        terminateButton.keyEquivalent = ""

        let response = alert.runModal()
        return response == .alertSecondButtonReturn ? .terminate : .continueProcessing
    }

    /// `.app` バンドル経由ではない直接実行（`swift run PrefSnap` 等）の場合のみ、
    /// ビルド構成に応じたアイコン画像を Dock へ設定する。
    /// `.app` バンドル実行時は `Info.plist` と `AppIcon.icns` に任せ、
    /// `Bundle.module` へアクセスせずに早期リターンすることで安全性を確保する。
    private func applyRuntimeDockIconIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return
        }

        #if DEBUG
        let iconResourceName = "AppIcon_dev"
        #else
        let iconResourceName = "AppIcon"
        #endif

        guard let iconURL = Bundle.module.url(
            forResource: iconResourceName,
            withExtension: "png",
            subdirectory: "Resources"
        ),
        let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }

        NSApplication.shared.applicationIconImage = iconImage
    }
}

/// PrefSnap アプリケーションのエントリポイント（単一ウィンドウ構成）。
@main
struct PrefSnapApp: App {
    @NSApplicationDelegateAdaptor(PrefSnapAppDelegate.self) private var appDelegate
    private let viewModel: AppViewModel
    private let updateViewModel: UpdateViewModel

    /// ルートアプリケーションを初期化し、AppDelegate へ `isBusy` 参照および自動アップデート終了連携を接続する。
    init() {
        /// `self` の全プロパティ初期化後に `appDelegate` およびフォールバック終了エグゼキューターを安全に保持するための参照ホルダ。
        @MainActor
        final class DelegateHolder {
            weak var delegate: PrefSnapAppDelegate?
            var fallbackTerminationExecutor: AutomaticUpdateTerminationExecutor?
        }

        let delegateHolder = DelegateHolder()
        let viewModel = AppViewModel()
        let updateViewModel = UpdateViewModel(
            isAppBusyProvider: { viewModel.isBusy },
            openURLHandler: { url in
                NSWorkspace.shared.open(url)
            },
            terminateForUpdateHandler: {
                // delegateHolder と NSApplication.shared.delegate の双方から AppDelegate を解決し、参照欠落を防ぐ
                if let activeDelegate = delegateHolder.delegate ?? (NSApplication.shared.delegate as? PrefSnapAppDelegate) {
                    activeDelegate.beginAutomaticUpdateTermination()
                    return
                }

                // 万が一 AppDelegate 参照が取得できない場合でも、シート解除・通常終了・フォールバック終了を確実に実行する
                let executor = AutomaticUpdateTerminationExecutor(
                    prepareTermination: {},
                    dismissSheets: {
                        PrefSnapAppDelegate.dismissAllAttachedSheets(in: NSApplication.shared)
                    },
                    requestGracefulTermination: {
                        NSApplication.shared.terminate(nil)
                    },
                    forceExit: { code in
                        Darwin.exit(code)
                    }
                )
                delegateHolder.fallbackTerminationExecutor = executor
                executor.execute()
            }
        )
        self.viewModel = viewModel
        self.updateViewModel = updateViewModel
        delegateHolder.delegate = appDelegate
        appDelegate.configure(isBusyProvider: { viewModel.isBusy || updateViewModel.isInstalling })
    }

    var body: some Scene {
        Window("PrefSnap", id: "main") {
            ContentView(viewModel: viewModel, updateViewModel: updateViewModel) { window in
                appDelegate.attachMainWindow(window)
            }
            .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("アップデートを確認…") {
                    viewModel.selectedSection = .settings
                    Task {
                        await updateViewModel.checkForUpdatesManually()
                    }
                }
                .disabled(!updateViewModel.canCheckForUpdates)
            }
        }
    }
}
