import Testing
@testable import PrefSnapCore

@Suite("AppTerminationCoordinator の終了判定と二重確認防止テスト")
@MainActor
struct AppTerminationCoordinatorTests {
    /// `@MainActor` クロージャ内から可変状態を警告なしで参照・更新するためのテスト用ボックス。
    @MainActor
    private final class Box<Value> {
        /// 保持している値。
        var value: Value

        /// ボックスを初期化する。
        /// - Parameter value: 初期値
        init(_ value: Value) {
            self.value = value
        }
    }

    @Test("アイドル状態では確認ダイアログを出さずにウィンドウクローズおよびアプリ終了を許可すること")
    func idleAllowsWindowCloseAndApplicationTerminationWithoutConfirmation() {
        let confirmationCount = Box(0)
        let coordinator = AppTerminationCoordinator(
            isBusyProvider: { false },
            confirmTermination: { _ in
                confirmationCount.value += 1
                return .continueProcessing
            }
        )

        #expect(coordinator.shouldTerminateAfterLastWindowClosed() == true)
        #expect(coordinator.shouldAllowWindowClose() == true)
        #expect(coordinator.shouldAllowApplicationTermination() == true)
        #expect(confirmationCount.value == 0)
        #expect(coordinator.hasConfirmedTermination == false)
        #expect(coordinator.isConfirmationPresented == false)
    }

    @Test("処理中のウィンドウクローズで『処理を続ける』を選択するとキャンセルされ、次回も再度確認されること")
    func busyWindowCloseCancelledKeepsRunningAndPromptsAgainNextTime() {
        let triggers = Box<[TerminationTrigger]>([])
        let coordinator = AppTerminationCoordinator(
            isBusyProvider: { true },
            confirmTermination: { trigger in
                triggers.value.append(trigger)
                return .continueProcessing
            }
        )

        #expect(coordinator.shouldAllowWindowClose() == false)
        #expect(coordinator.hasConfirmedTermination == false)
        #expect(coordinator.isConfirmationPresented == false)

        // 次回のウィンドウクローズやアプリ終了要求でも再度確認ダイアログが表示されること
        #expect(coordinator.shouldAllowWindowClose() == false)
        #expect(coordinator.shouldAllowApplicationTermination() == false)
        #expect(triggers.value == [.windowClose, .windowClose, .applicationTerminate])
    }

    @Test("処理中のウィンドウクローズで『終了する』を選択すると直後のアプリ終了処理で二重確認されないこと")
    func busyWindowCloseApprovedPreventsDuplicateConfirmationOnApplicationTerminate() {
        let triggers = Box<[TerminationTrigger]>([])
        let coordinator = AppTerminationCoordinator(
            isBusyProvider: { true },
            confirmTermination: { trigger in
                triggers.value.append(trigger)
                return .terminate
            }
        )

        // 1. ウィンドウクローズ時に確認ダイアログで「終了する」を選択
        #expect(coordinator.shouldAllowWindowClose() == true)
        #expect(coordinator.hasConfirmedTermination == true)
        #expect(coordinator.isConfirmationPresented == false)

        // 2. 最後のウィンドウが閉じた後にアプリ終了へ進む
        #expect(coordinator.shouldTerminateAfterLastWindowClosed() == true)

        // 3. applicationShouldTerminate 側では再度確認せず即時終了を許可する
        #expect(coordinator.shouldAllowApplicationTermination() == true)
        #expect(triggers.value == [.windowClose])
    }

    @Test("処理中のアプリ終了（⌘Q 等）で『処理を続ける』は中止し、『終了する』は許可して二重確認も防ぐこと")
    func busyApplicationTerminationRespectsUserChoiceAndPreventsDuplicateConfirmation() {
        let nextChoice = Box<TerminationConfirmationChoice>(.continueProcessing)
        let triggers = Box<[TerminationTrigger]>([])
        let coordinator = AppTerminationCoordinator(
            isBusyProvider: { true },
            confirmTermination: { trigger in
                triggers.value.append(trigger)
                return nextChoice.value
            }
        )

        // 1 回目は「処理を続ける」を選択して終了をキャンセル
        #expect(coordinator.shouldAllowApplicationTermination() == false)
        #expect(coordinator.hasConfirmedTermination == false)
        #expect(triggers.value == [.applicationTerminate])

        // 2 回目は「終了する」を選択して終了を許可
        nextChoice.value = .terminate
        #expect(coordinator.shouldAllowApplicationTermination() == true)
        #expect(coordinator.hasConfirmedTermination == true)
        #expect(triggers.value == [.applicationTerminate, .applicationTerminate])

        // 承認直後に仮にウィンドウクローズ判定が呼ばれても再度確認しないこと
        #expect(coordinator.shouldAllowWindowClose() == true)
        #expect(triggers.value == [.applicationTerminate, .applicationTerminate])
    }

    @Test("確認ダイアログ表示中に処理が完了して isBusy が false へ変化しても状態に不整合が起きないこと")
    func busyBecomingFalseDuringConfirmationRemainsConsistent() {
        // ケース 1: 表示中に処理が完了し、ユーザーが「処理を続ける」を選択した場合
        let isBusy1 = Box(true)
        let confirmationCount1 = Box(0)
        let continueCoordinator = AppTerminationCoordinator(
            isBusyProvider: { isBusy1.value },
            confirmTermination: { _ in
                confirmationCount1.value += 1
                // ダイアログ表示中にバックグラウンド処理が完了した状況を再現する
                isBusy1.value = false
                return .continueProcessing
            }
        )

        #expect(continueCoordinator.shouldAllowWindowClose() == false)
        #expect(continueCoordinator.hasConfirmedTermination == false)
        #expect(continueCoordinator.isConfirmationPresented == false)
        // すでに処理完了済みのため、次回のクローズ・終了は確認なしで許可されること
        #expect(continueCoordinator.shouldAllowWindowClose() == true)
        #expect(continueCoordinator.shouldAllowApplicationTermination() == true)
        #expect(confirmationCount1.value == 1)

        // ケース 2: 表示中に処理が完了し、ユーザーが「終了する」を選択した場合
        let isBusy2 = Box(true)
        let confirmationCount2 = Box(0)
        let terminateCoordinator = AppTerminationCoordinator(
            isBusyProvider: { isBusy2.value },
            confirmTermination: { _ in
                confirmationCount2.value += 1
                isBusy2.value = false
                return .terminate
            }
        )

        #expect(terminateCoordinator.shouldAllowWindowClose() == true)
        #expect(terminateCoordinator.hasConfirmedTermination == true)
        #expect(terminateCoordinator.shouldAllowApplicationTermination() == true)
        #expect(confirmationCount2.value == 1)
    }

    @Test("確認ダイアログ表示中の再入ではダイアログを多重表示せず拒否し、終了後は正常復帰すること")
    func reentrantRequestsWhileConfirmationIsPresentedAreRejectedSafely() {
        let coordinatorBox = Box<AppTerminationCoordinator?>(nil)
        let confirmationCount = Box(0)
        let reentrantWindowCloseResult = Box<Bool?>(nil)
        let reentrantAppTerminateResult = Box<Bool?>(nil)

        let coordinator = AppTerminationCoordinator(
            isBusyProvider: { true },
            confirmTermination: { _ in
                confirmationCount.value += 1
                if confirmationCount.value == 1, let activeCoordinator = coordinatorBox.value {
                    // 確認ダイアログ表示中に再入が発生したケースを再現する
                    reentrantWindowCloseResult.value = activeCoordinator.shouldAllowWindowClose()
                    reentrantAppTerminateResult.value = activeCoordinator.shouldAllowApplicationTermination()
                }
                return .continueProcessing
            }
        )
        coordinatorBox.value = coordinator

        #expect(coordinator.shouldAllowWindowClose() == false)
        #expect(reentrantWindowCloseResult.value == false)
        #expect(reentrantAppTerminateResult.value == false)
        #expect(confirmationCount.value == 1)
        #expect(coordinator.isConfirmationPresented == false)

        // ダイアログが閉じた後は通常どおり確認が再実行できること
        #expect(coordinator.shouldAllowApplicationTermination() == false)
        #expect(confirmationCount.value == 2)
    }

    @Test("ウィンドウクローズが他要因でキャンセルされた場合は承認状態がリセットされること")
    func cancelPendingWindowCloseTerminationResetsConfirmedState() {
        let confirmationCount = Box(0)
        let coordinator = AppTerminationCoordinator(
            isBusyProvider: { true },
            confirmTermination: { _ in
                confirmationCount.value += 1
                return .terminate
            }
        )

        #expect(coordinator.shouldAllowWindowClose() == true)
        #expect(coordinator.hasConfirmedTermination == true)

        // 元のデリゲート等でクローズが中止された場合に承認状態をリセットする
        coordinator.cancelPendingWindowCloseTermination()
        #expect(coordinator.hasConfirmedTermination == false)

        // リセット後は処理中の終了要求で再び確認ダイアログが表示されること
        #expect(coordinator.shouldAllowApplicationTermination() == true)
        #expect(confirmationCount.value == 2)
    }
}
