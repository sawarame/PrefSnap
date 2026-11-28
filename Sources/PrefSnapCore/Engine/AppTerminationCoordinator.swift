import Foundation

/// 終了確認ダイアログのトリガー種別。
public enum TerminationTrigger: Sendable, Equatable {
    /// メインウィンドウを閉じる操作（閉じるボタンまたは ⌘W）。
    case windowClose
    /// アプリ自体を終了する操作（メニューバーまたは ⌘Q）。
    case applicationTerminate
}

/// 終了確認ダイアログに対するユーザーの選択結果。
public enum TerminationConfirmationChoice: Sendable, Equatable {
    /// 終了を中止し、進行中の処理を継続する。
    case continueProcessing
    /// 処理中であっても終了を承認する。
    case terminate
}

/// ウィンドウクローズおよびアプリ終了時の判定・二重確認防止・再入防止を統括するコーディネーター。
@MainActor
public final class AppTerminationCoordinator {
    /// 現在の処理中状態（`isBusy`）を取得するクロージャ。
    private let isBusyProvider: @MainActor () -> Bool
    /// 処理中の終了確認を行い、ユーザーの選択結果を返すクロージャ。
    private let confirmTermination: @MainActor (TerminationTrigger) -> TerminationConfirmationChoice

    /// ウィンドウクローズ確認などでユーザーがすでに終了を承認済みかどうか。
    public private(set) var hasConfirmedTermination = false

    /// 自動アップデート再起動などアプリ側主導の自動終了が進行中かどうか。
    public private(set) var isAutomaticTerminationApproved = false

    /// 終了確認ダイアログを現在表示中かどうか（多重表示・再入防止用）。
    public private(set) var isConfirmationPresented = false

    /// コーディネーターを初期化する。
    /// - Parameters:
    ///   - isBusyProvider: アプリが処理中かどうかを返すクロージャ
    ///   - confirmTermination: 処理中の確認ダイアログを表示し、ユーザーの選択結果を返すクロージャ
    public init(
        isBusyProvider: @escaping @MainActor () -> Bool,
        confirmTermination: @escaping @MainActor (TerminationTrigger) -> TerminationConfirmationChoice
    ) {
        self.isBusyProvider = isBusyProvider
        self.confirmTermination = confirmTermination
    }

    /// 自動アップデート再起動などアプリ主導の終了前に呼び出し、
    /// 直後の終了要求で確認ダイアログにブロックされず確実に終了できるようにする。
    public func prepareForAutomaticTermination() {
        isAutomaticTerminationApproved = true
        hasConfirmedTermination = true
    }

    /// メインウィンドウを閉じてよいか判定する（`NSWindowDelegate.windowShouldClose(_:)` から呼び出す）。
    /// - Returns: ウィンドウを閉じる場合は `true`、キャンセルする場合は `false`
    public func shouldAllowWindowClose() -> Bool {
        // 自動アップデートに伴う終了承認済みの場合は確認なしで即座に許可する
        if isAutomaticTerminationApproved {
            return true
        }

        // すでに終了確認ダイアログを表示中であれば多重表示を防ぎクローズを拒否する
        guard !isConfirmationPresented else {
            return false
        }

        // すでに終了承認済み、またはアイドル状態であれば確認なしでクローズを許可する
        if hasConfirmedTermination || !isBusyProvider() {
            return true
        }

        isConfirmationPresented = true
        defer { isConfirmationPresented = false }

        let choice = confirmTermination(.windowClose)
        switch choice {
        case .continueProcessing:
            return false
        case .terminate:
            // 直後のアプリ終了処理で再度確認ダイアログが出ないよう承認済みフラグを立てる
            hasConfirmedTermination = true
            return true
        }
    }

    /// ウィンドウクローズが他要因（元のデリゲート等）で取り消された場合に、
    /// ウィンドウクローズ確認で立てた終了承認状態をリセットする。
    public func cancelPendingWindowCloseTermination() {
        guard !isAutomaticTerminationApproved else { return }
        hasConfirmedTermination = false
    }

    /// 最後のウィンドウが閉じた後にアプリを終了すべきか判定する
    /// （`NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed(_:)` から呼び出す）。
    /// - Returns: 単一ウィンドウ終了と同時にアプリも終了させるため常に `true`
    public func shouldTerminateAfterLastWindowClosed() -> Bool {
        true
    }

    /// アプリを終了してよいか判定する（`NSApplicationDelegate.applicationShouldTerminate(_:)` から呼び出す）。
    /// - Returns: 即時終了する場合は `true`、終了を中止する場合は `false`
    public func shouldAllowApplicationTermination() -> Bool {
        // 自動アップデートに伴う終了承認済みの場合は確認なしで即座に許可する
        if isAutomaticTerminationApproved {
            return true
        }

        // すでに終了確認ダイアログを表示中であれば多重表示を防ぎ終了をキャンセルする
        guard !isConfirmationPresented else {
            return false
        }

        // ウィンドウクローズ時などで既に終了承認済みなら二重確認せず即時終了を許可する
        if hasConfirmedTermination {
            return true
        }

        // アイドル状態であれば確認なしで即時終了を許可する
        guard isBusyProvider() else {
            return true
        }

        isConfirmationPresented = true
        defer { isConfirmationPresented = false }

        let choice = confirmTermination(.applicationTerminate)
        switch choice {
        case .continueProcessing:
            return false
        case .terminate:
            // 直後にウィンドウクローズ判定が走った場合でも二重確認しないよう承認済みにする
            hasConfirmedTermination = true
            return true
        }
    }
}

/// 自動アップデート再起動に伴う終了シーケンス（終了確認バイパス・シート解除・次ランループでの通常終了・
/// タイムアウト時のフォールバック強制終了）を安全に制御するエグゼキューター。
@MainActor
public final class AutomaticUpdateTerminationExecutor {
    /// 通常終了が完了しなかった場合にフォールバック終了へ切り替えるまでの既定待機時間（2.5 秒）。
    public static let defaultFallbackDelayNanoseconds: UInt64 = 2_500_000_000

    /// 終了シーケンスがすでに開始されているかどうか。
    public private(set) var hasStarted = false

    /// フォールバック強制終了が実行されたかどうか。
    public private(set) var didInvokeForceExit = false

    private let fallbackDelayNanoseconds: UInt64
    private let prepareTermination: @MainActor () -> Void
    private let dismissSheets: @MainActor () -> Void
    private let scheduleNextRunLoop: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    private let requestGracefulTermination: @MainActor () -> Void
    private let forceExit: @MainActor (Int32) -> Void
    private let sleepOperation: @Sendable (UInt64) async throws -> Void
    private var fallbackTask: Task<Void, Never>?

    /// 自動アップデート終了エグゼキューターを初期化する。
    /// - Parameters:
    ///   - fallbackDelayNanoseconds: 通常終了が完了しない場合にフォールバック終了を実行するまでの待機時間（ナノ秒）
    ///   - prepareTermination: 終了確認ダイアログのバイパス準備を行うクロージャ
    ///   - dismissSheets: 開いているシートを明示的に終了させるクロージャ
    ///   - scheduleNextRunLoop: 次のランループサイクルで処理を実行するためのスケジューラ
    ///   - requestGracefulTermination: `NSApplication.shared.terminate(nil)` 等の通常終了要求クロージャ
    ///   - forceExit: 通常終了できなかった場合のフォールバック終了クロージャ（終了コードを受け取る）
    ///   - sleepOperation: フォールバック待機に使用する非同期スリープ処理（テスト差し替え用）
    public init(
        fallbackDelayNanoseconds: UInt64 = defaultFallbackDelayNanoseconds,
        prepareTermination: @escaping @MainActor () -> Void,
        dismissSheets: @escaping @MainActor () -> Void,
        scheduleNextRunLoop: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    action()
                }
            }
        },
        requestGracefulTermination: @escaping @MainActor () -> Void,
        forceExit: @escaping @MainActor (Int32) -> Void,
        sleepOperation: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.fallbackDelayNanoseconds = fallbackDelayNanoseconds
        self.prepareTermination = prepareTermination
        self.dismissSheets = dismissSheets
        self.scheduleNextRunLoop = scheduleNextRunLoop
        self.requestGracefulTermination = requestGracefulTermination
        self.forceExit = forceExit
        self.sleepOperation = sleepOperation
    }

    /// 自動アップデート用の終了シーケンスを開始する（多重呼び出し時は無視する）。
    public func execute() {
        guard !hasStarted else { return }
        hasStarted = true

        // 1. 終了確認ダイアログのバイパスを有効化し、開いているシートを AppKit 側でも確実に閉じる
        prepareTermination()
        dismissSheets()

        // 2. シート解除が反映される次のランループサイクルで通常終了を要求する
        scheduleNextRunLoop { [weak self] in
            guard let self else { return }
            self.requestGracefulTermination()
        }

        // 3. 万が一通常終了がブロックされた場合に備え、短時間後にフォールバック強制終了を実行する
        let delay = fallbackDelayNanoseconds
        let sleepOperation = self.sleepOperation
        fallbackTask = Task { @MainActor [weak self] in
            do {
                try await sleepOperation(delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.didInvokeForceExit = true
            self.forceExit(0)
        }
    }

    /// 通常終了フローに入った際に待機中のフォールバック終了タスクをキャンセルする。
    public func cancelFallback() {
        fallbackTask?.cancel()
        fallbackTask = nil
    }
}
