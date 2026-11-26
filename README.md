<img src="Resources/Icons/AppIcon.png" alt="PrefSnap アプリアイコン" width="128" height="128">

# PrefSnap

macOS のシステム設定・メニューバー設定・キーボードショートカット・修飾キーリマップを、人間が読めて Git で差分管理しやすい整形済み JSON としてエクスポートし、別の Mac で差分確認しながら安全にインポート＆ロールバックできるネイティブ macOS アプリです。

## 主な特徴

- **SwiftPM（`Package.swift`）単体構成**: Xcode プロジェクトファイルなしで、コマンドラインからビルド・テスト・起動が完結します（macOS 14.0 Sonoma 以降 / App Sandbox 無効）。
- **5 カテゴリの設定に対応**:
  1. システム基本設定（Dock / Finder / キーボード・トラックパッド / スクリーンショット、計 34 項目）
  2. メニューバーコントロール（macOS 26 の `com.apple.controlcenter.bentoboxes` / `displayablemenuextras` / `ChronoControls`、`com.apple.controlcenter` の `-currentHost` / `ByHost` 項目および通常ドメインの `NSStatusItem Visible*` / `VisibleCC *` 固定＋動的キー、`com.apple.menuextra.clock` に対応）
  3. システム標準ショートカット（`com.apple.symbolichotkeys` の主要 12 項目を安全にマージ更新）
  4. アプリケーションショートカット（`NSUserKeyEquivalents` と `com.apple.universalaccess` の `com.apple.custommenu.apps` を整合更新）
  5. 修飾キーのリマップ（`ByHost/.GlobalPreferences` ＋ `IOKit` / `IOHIDManager` によるデバイス名・内蔵/外付け判定）
- **Git フレンドリーな JSON 形式**: `schemaVersion` 付きの整形済み・キーソート済み JSON を出力します。未設定の項目は `null` として明示され、インポート時に「現在値あり → `null`」の場合は初期状態へ戻せます。
- **差分プレビュー＆選択適用（Dry-run）**: 変更が発生する項目のみ Before → After で表示し、チェックボックスで個別に選択できます。修飾キーは接続中キーボードとの `VendorID-ProductID` 完全一致ルール（および内蔵キーボード向け例外オプション）で安全に適用します。
- **自動バックアップ＆ロールバック**: 適用直前に `~/Library/Application Support/PrefSnap/Backups/` 配下へ日時付き JSON を自動保存し、アプリ内の履歴画面から任意のバックアップファイルを選択して復元できます。
- **テスト安全性**: コマンド実行・plist 読み書き・IOKit・ファイル操作・プロセス再起動をすべてプロトコルで抽象化しており、`swift test` 実行中に開発マシンの実環境設定を一切変更しません。

## インストール

### Homebrew でインストール（推奨）

```bash
brew install --cask sawarame/tap/prefsnap
```

アップデート・アンインストールは以下のコマンドで行えます。

```bash
# 最新版へアップデート
brew upgrade --cask prefsnap

# アンインストール（--zap を付けると設定ファイルや自動バックアップも削除されます）
brew uninstall --cask prefsnap
```

### GitHub Releases から手動インストール

1. [Releases](https://github.com/sawarame/PrefSnap/releases) ページから最新版の `PrefSnap-vX.Y.Z.dmg`（または `PrefSnap-vX.Y.Z.zip`）をダウンロードします。
2. `PrefSnap-vX.Y.Z.dmg` を開き、`PrefSnap.app` を `Applications` フォルダへドラッグ＆ドロップして起動します（`.zip` の場合は展開した `PrefSnap.app` を `/Applications` へ移動してください）。

> 配布バイナリ（`.app` / `.dmg`）は Apple Developer ID 署名および公証（Notarization）済みのため、初回起動時の Gatekeeper 警告なしで実行できます。

## ビルド・テスト・実行

```bash
# ユニットテストの実行（すべてモックで実行され、実環境の設定は変更されません）
swift test

# ビルド
swift build

# アプリの起動（CLI から直接起動）
swift run PrefSnap

# macOS アプリバンドル (.app) の組み立て
# debug は .build/PrefSnap_dev.app (dev.prefsnap.PrefSnap.dev)
# release は .build/PrefSnap.app (dev.prefsnap.PrefSnap) を生成
./scripts/build-app.sh debug
./scripts/build-app.sh release
./scripts/build-app.sh release --universal

# 配布用ディスクイメージ (.dmg) の組み立て
./scripts/build-dmg.sh
```

> **署名・ユニバーサルビルド用環境変数**:
> - `PREFSNAP_UNIVERSAL=true`: `arm64` + `x86_64` のユニバーサルバイナリを生成（`--universal` と同等）
> - `PREFSNAP_SIGN_IDENTITY="<Developer ID>"`: 指定時は Developer ID 署名（Hardened Runtime + タイムスタンプ）、未指定時はアドホック署名を適用

## パッケージ構成

- `Sources/PrefSnapCore`: モデル・プリセットカタログ・プロトコル・インフラ実装・エクスポート／差分／適用／バックアップエンジン
- `Sources/PrefSnap`: SwiftUI（`Observation` フレームワーク）によるネイティブ macOS アプリ UI
- `Tests/PrefSnapCoreTests`: モックを用いたユニットテスト
- `Resources/Info.plist`: `.app` バンドル組み立て時に利用するアプリ情報テンプレート
- `Resources/Icons/`: アプリアイコンの編集用元データ（`AppIcon.svg` / `AppIcon_dev.svg`）および事前変換済み 1024×1024px PNG（`AppIcon.png` / `AppIcon_dev.png`）
- `scripts/generate-icons.sh`: 元データ SVG から 1024×1024px 透過 PNG を再生成し、`Resources/Icons/` と `Sources/PrefSnap/Resources/` へ同期するスクリプト
- `scripts/build-app.sh` / `scripts/build-dmg.sh`: `.app` バンドルおよび `.dmg` ディスクイメージの組み立てスクリプト
- `.github/workflows/release.yml`: バージョン検証・テスト・Universal Binary ビルド・署名・公証・GitHub Release 公開・Homebrew Cask 更新を自動化するリリースワークフロー
- `VERSION`: アプリのセマンティックバージョン定義

## リリース手順（開発者向け）

アプリのバージョンはリポジトリルートの [`VERSION`](VERSION) ファイルでセマンティックバージョニング形式（例: `0.1.0`、`0.2.0-beta.1`）で管理しています。

### 自動リリースの実行方法

以下のいずれかをきっかけに [`.github/workflows/release.yml`](.github/workflows/release.yml) が起動し、テスト実行・Universal Binary（`arm64` + `x86_64`）ビルド・Developer ID 署名・Apple 公証・Staple・GitHub Release 公開（`PrefSnap-vX.Y.Z.zip` / `PrefSnap-vX.Y.Z.dmg`）・Homebrew Tap（`sawarame/homebrew-tap` の `Casks/prefsnap.rb`）更新までを自動実行します。

1. **`VERSION` 更新による自動リリース（推奨）**: `VERSION` を新しいバージョンへ更新して `main` ブランチへ push すると、`swift test` の成功後に `v<VERSION>` タグが自動作成され、リリース処理が実行されます（同名のタグが既に存在する場合は重複防止のためエラー終了します）。
2. **`v*` タグの push または GitHub Release の公開**: `VERSION` と一致する `v<VERSION>` タグを push する、または同タグの GitHub Release を公開することでもリリース処理を実行できます。
3. **手動実行（`workflow_dispatch`）**: GitHub Actions 画面から `Release` ワークフローを手動実行できます（対応するタグが未作成なら自動作成し、既存タグがあれば継続利用します）。

> バージョンにハイフン（例: `0.2.0-beta.1`）が含まれる場合はプレリリース扱いとなり、GitHub Release へ `--prerelease` を付与して公開し、Homebrew Tap の更新は自動的にスキップされます。

### 必要な GitHub Secrets 一覧

自動リリースを実行するには、リポジトリの **Settings > Secrets and variables > Actions** に以下の Secrets を登録しておく必要があります。

| Secret 名 | 必須条件 | 用途 |
| :--- | :--- | :--- |
| `MACOS_CERT_BASE64` | 常時必須 | Developer ID Application 証明書（`.p12`）を Base64 エンコードした文字列 |
| `MACOS_CERT_PASSWORD` | 常時必須 | `.p12` 証明書のインポート用パスワード |
| `MACOS_SIGN_IDENTITY` | 常時必須 | `codesign` に渡す署名識別子（例: `Developer ID Application: ...`） |
| `NOTARY_KEY_BASE64` | 常時必須 | App Store Connect API Key（`.p8`）を Base64 エンコードした文字列 |
| `NOTARY_KEY_ID` | 常時必須 | App Store Connect API Key の Key ID |
| `NOTARY_ISSUER_ID` | 任意 | App Store Connect API の Issuer ID（設定時のみ `notarytool` に `--issuer` を付与） |
| `HOMEBREW_TAP_TOKEN` | 安定版リリース時のみ必須 | `sawarame/homebrew-tap` への書き込み権限（`Contents: Read and write`）を持つアクセストークン |
