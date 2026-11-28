import AppKit
import Combine
import SwiftUI

/// コピーボタンの一時的な完了フィードバック状態とリセットタイマーを管理する状態オブジェクト。
/// CommandLineTools 環境（`SwiftUIMacros` 非同梱）でもビルドできるよう `@State` マクロではなく `ObservableObject` を使用する。
@MainActor
private final class CopyFeedbackState: ObservableObject {
    /// 直近のコピー完了フィードバック表示状態。
    @Published private(set) var isCopied = false
    /// フィードバック表示を元へ戻すための遅延タスク。
    private var resetTask: Task<Void, Never>?

    /// 指定されたテキストをクリップボードへ書き込み、一定時間「コピーしました」状態にする。
    /// - Parameter text: クリップボードへ書き込むプレーンテキスト
    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        isCopied = true
        // 連続押下時は前回タイマーをキャンセルして表示時間をリセットする
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.isCopied = false
            self?.resetTask = nil
        }
    }

    /// 待機中のフィードバック解除タスクをキャンセルする。
    func cancelPendingReset() {
        resetTask?.cancel()
        resetTask = nil
    }
}

/// エラー・警告バナー共通のクリップボードコピーボタン。
/// 押下時にプレーンテキストを `NSPasteboard.general` へ書き込み、
/// 一時的に「コピーしました」の完了フィードバックを表示する。
struct CopyReportButton: View {
    /// コピー実行時に出力テキストを生成するクロージャ。
    let textProvider: () -> String
    /// ボタンのコントロールサイズ。
    var controlSize: ControlSize = .small

    /// コピー完了状態とタイマーを保持する状態オブジェクト。
    @StateObject private var feedbackState = CopyFeedbackState()

    var body: some View {
        Button {
            feedbackState.copyToPasteboard(textProvider())
        } label: {
            Label(
                feedbackState.isCopied ? "コピーしました" : "コピー",
                systemImage: feedbackState.isCopied ? "checkmark" : "doc.on.doc"
            )
            .foregroundStyle(feedbackState.isCopied ? Color.green : Color.primary)
        }
        .buttonStyle(.bordered)
        .controlSize(controlSize)
        .help("環境情報を含めて内容をクリップボードへコピーします")
        .onDisappear {
            // ビュー破棄時に待機中のフィードバック解除タスクを確実にキャンセルする
            feedbackState.cancelPendingReset()
        }
    }
}
