# PrefSnap

macOS のシステム設定・メニューバー設定・キーボードショートカット・修飾キーリマップを、人間が読めて Git で差分管理しやすい整形済み JSON としてエクスポートし、別の Mac で差分確認しながら安全にインポート＆ロールバックできるネイティブ macOS アプリです。

## 主な特徴

- **SwiftPM（`Package.swift`）単体構成**: Xcode プロジェクトファイルなしで、コマンドラインからビルド・テスト・起動が完結します（macOS 14.0 Sonoma 以降 / App Sandbox 無効）。
- **5 カテゴリの設定に対応**:
  1. システム基本設定（Dock / Finder / キーボード・トラックパッド / スクリーンショット、計 34 項目）
  2. メニューバーコントロール（`com.apple.controlcenter` は `-currentHost` / `ByHost` 対象、`com.apple.menuextra.clock`、計 8 項目）
  3. システム標準ショートカット（`com.apple.symbolichotkeys` の主要 12 項目を安全にマージ更新）
  4. アプリケーションショートカット（`NSUserKeyEquivalents` と `com.apple.universalaccess` の `com.apple.custommenu.apps` を整合更新）
  5. 修飾キーのリマップ（`ByHost/.GlobalPreferences` ＋ `IOKit` / `IOHIDManager` によるデバイス名・内蔵/外付け判定）
- **Git フレンドリーな JSON 形式**: `schemaVersion` 付きの整形済み・キーソート済み JSON を出力します。未設定の項目は `null` として明示され、インポート時に「現在値あり → `null`」の場合は初期状態へ戻せます。
- **差分プレビュー＆選択適用（Dry-run）**: 変更が発生する項目のみ Before → After で表示し、チェックボックスで個別に選択できます。修飾キーは接続中キーボードとの `VendorID-ProductID` 完全一致ルール（および内蔵キーボード向け例外オプション）で安全に適用します。
- **自動バックアップ＆ロールバック**: 適用直前に `~/Library/Application Support/PrefSnap/Backups/` 配下へ日時付き JSON を自動保存し、アプリ内の履歴画面から任意のバックアップファイルを選択して復元できます。
- **テスト安全性**: コマンド実行・plist 読み書き・IOKit・ファイル操作・プロセス再起動をすべてプロトコルで抽象化しており、`swift test` 実行中に開発マシンの実環境設定を一切変更しません。

## ビルド・テスト・実行

```bash
# ユニットテストの実行（すべてモックで実行され、実環境の設定は変更されません）
swift test

# ビルド
swift build

# アプリの起動
swift run PrefSnap
```

## パッケージ構成

- `Sources/PrefSnapCore`: モデル・プリセットカタログ・プロトコル・インフラ実装・エクスポート／差分／適用／バックアップエンジン
- `Sources/PrefSnap`: SwiftUI（`Observation` フレームワーク）によるネイティブ macOS アプリ UI
- `Tests/PrefSnapCoreTests`: モックを用いたユニットテスト
