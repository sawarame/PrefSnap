import Foundation

/// `/usr/bin/defaults` コマンドの標準エラー出力（`stderr`）から、
/// 権限不足エラーや対象ドメイン・キーの未存在（未設定）状態を分類するヘルパー。
public enum DefaultsCommandStderrClassifier {
    /// 標準エラー出力が権限不足（フルディスクアクセス未許可等）を示すかを判定する。
    /// - Parameter stderr: `defaults` コマンドの標準エラー出力文字列
    /// - Returns: 権限不足エラーに該当する場合は `true`、それ以外は `false`
    public static func isPermissionDenied(_ stderr: String) -> Bool {
        let lowerErr = stderr.lowercased()
        return lowerErr.contains("permission denied")
            || lowerErr.contains("operation not permitted")
            || lowerErr.contains("not permitted")
    }

    /// 標準エラー出力が対象ドメインまたはキーの未存在（未設定）を示すかを判定する。
    /// 権限不足エラーに該当する場合は誤判定を防ぐため常に `false` を返す。
    /// - Parameter stderr: `defaults` コマンドの標準エラー出力文字列
    /// - Returns: 未存在（未設定）エラーに該当する場合は `true`、それ以外は `false`
    public static func isMissingEntry(_ stderr: String) -> Bool {
        // 権限エラーを誤って未設定扱いしないよう最優先で除外する
        guard !isPermissionDenied(stderr) else {
            return false
        }

        let lowerErr = stderr.lowercased()

        // 従来の macOS 形式（例: "The domain/default pair of (...) does not exist"）
        if lowerErr.contains("does not exist") || lowerErr.contains("the domain/default pair of") {
            return true
        }

        // ドメイン・キーの not found 形式（例: "Error: Domain '...' not found."）
        if lowerErr.contains("not found") && (lowerErr.contains("domain") || lowerErr.contains("key")) {
            return true
        }

        // macOS 27 以降の形式（例: "Error: Could not find key '...' in domain '...'."）
        if lowerErr.contains("could not find key")
            || (lowerErr.contains("could not find") && lowerErr.contains("domain")) {
            return true
        }

        return false
    }
}
