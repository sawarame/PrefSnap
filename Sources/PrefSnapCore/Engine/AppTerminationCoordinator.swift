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

    /// メインウィンドウを閉じてよいか判定する（`NSWindowDelegate.windowShouldClose(_:)` から呼び出す）。
    /// - Returns: ウィンドウを閉じる場合は `true`、キャンセルする場合は `false`
    public func shouldAllowWindowClose() -> Bool {
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
