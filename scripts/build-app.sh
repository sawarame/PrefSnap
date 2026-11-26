#!/usr/bin/env bash
# PrefSnap.app バンドル組み立てスクリプト
# swift build の実行バイナリを macOS アプリケーションバンドル (.app) 形式にパッケージ化する
# 使用例: ./scripts/build-app.sh [debug|release] [--universal]

set -euo pipefail

# スクリプトのあるディレクトリからリポジトリルートへ移動する
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

CONFIGURATION="debug"
IS_UNIVERSAL="${PREFSNAP_UNIVERSAL:-false}"

# コマンドライン引数を解析する
for arg in "$@"; do
    case "${arg}" in
        debug|release)
            CONFIGURATION="${arg}"
            ;;
        --universal)
            IS_UNIVERSAL="true"
            ;;
        -h|--help)
            echo "使用法: $0 [debug|release] [--universal]"
            exit 0
            ;;
        *)
            echo "[PrefSnap] エラー: 不明な引数です (${arg})" >&2
            echo "使用法: $0 [debug|release] [--universal]" >&2
            exit 1
            ;;
    esac
done

# VERSION ファイルからセマンティックバージョンを読み取り検証する
VERSION_FILE="${REPO_ROOT}/VERSION"
if [ ! -f "${VERSION_FILE}" ]; then
    echo "[PrefSnap] エラー: VERSION ファイルが見つかりません (${VERSION_FILE})" >&2
    exit 1
fi

APP_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
SEMVER_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "${APP_VERSION}" =~ ${SEMVER_REGEX} ]]; then
    echo "[PrefSnap] エラー: VERSION の値がセマンティックバージョニング形式ではありません (${APP_VERSION})" >&2
    exit 1
fi

# Git コミット数をビルド番号として算出し、取得できない場合は 1 へフォールバックする
if BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null)" && [[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
    :
else
    BUILD_NUMBER="1"
fi

EXECUTABLE_NAME="PrefSnap"
if [ "${CONFIGURATION}" = "release" ]; then
    BUNDLE_APP_NAME="PrefSnap"
    BUNDLE_IDENTIFIER="dev.prefsnap.PrefSnap"
else
    # ローカル開発用ビルドでは配布版と名称・識別子・設定領域を分離する
    BUNDLE_APP_NAME="PrefSnap_dev"
    BUNDLE_IDENTIFIER="dev.prefsnap.PrefSnap.dev"
fi

APP_BUNDLE="${REPO_ROOT}/.build/${BUNDLE_APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# アーキテクチャ指定に応じて swift build の引数を組み立てる
SWIFT_BUILD_ARGS=(-c "${CONFIGURATION}")
ARCH_LABEL="native"
if [ "${IS_UNIVERSAL}" = "true" ]; then
    SWIFT_BUILD_ARGS+=(--arch arm64 --arch x86_64)
    ARCH_LABEL="universal (arm64 + x86_64)"
fi

echo "[PrefSnap] ビルドを実行しています (${CONFIGURATION}, ${BUNDLE_APP_NAME}, ${ARCH_LABEL}, v${APP_VERSION} [${BUILD_NUMBER}])..."
swift build "${SWIFT_BUILD_ARGS[@]}"

BIN_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE_PATH="${BIN_PATH}/${EXECUTABLE_NAME}"

if [ ! -f "${EXECUTABLE_PATH}" ]; then
    echo "[PrefSnap] エラー: 実行バイナリが見つかりません (${EXECUTABLE_PATH})" >&2
    exit 1
fi

echo "[PrefSnap] .app バンドルを組み立てています..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE_PATH}" "${MACOS_DIR}/${BUNDLE_APP_NAME}"
cp "${REPO_ROOT}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

# バンドル内の Info.plist にのみバージョン・ビルド番号・ビルド種別に応じたアプリ名と識別子を反映する（元ファイルは変更しない）
if [ -x "/usr/libexec/PlistBuddy" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${BUNDLE_APP_NAME}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ${BUNDLE_APP_NAME}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${BUNDLE_APP_NAME}" "${CONTENTS_DIR}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_IDENTIFIER}" "${CONTENTS_DIR}/Info.plist"
else
    echo "[PrefSnap] エラー: /usr/libexec/PlistBuddy が見つかりません" >&2
    exit 1
fi

# ビルド構成に応じた事前生成済み 1024x1024px PNG から macOS 標準アイコン (.icns) を生成して組み込む
# CI 環境（ヘッドレス macOS）でも確実に動作するよう qlmanage には依存せず sips + iconutil のみを使用する
if [ "${CONFIGURATION}" = "release" ]; then
    APP_ICON_PNG="${REPO_ROOT}/Resources/Icons/AppIcon.png"
else
    APP_ICON_PNG="${REPO_ROOT}/Resources/Icons/AppIcon_dev.png"
fi

if [ ! -f "${APP_ICON_PNG}" ]; then
    echo "[PrefSnap] エラー: アプリアイコンのベース PNG が見つかりません (${APP_ICON_PNG})" >&2
    exit 1
fi

for icon_cmd in sips iconutil; do
    if ! command -v "${icon_cmd}" >/dev/null 2>&1; then
        echo "[PrefSnap] エラー: アイコン生成に必要なコマンドが見つかりません (${icon_cmd})" >&2
        exit 1
    fi
done

echo "[PrefSnap] アプリアイコン (AppIcon.icns) を生成しています ($(basename "${APP_ICON_PNG}"))..."
ICON_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${ICON_TMP_DIR:-}"' EXIT
ICONSET_DIR="${ICON_TMP_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

sips -z 16 16     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64     "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${APP_ICON_PNG}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

if [ ! -s "${RESOURCES_DIR}/AppIcon.icns" ]; then
    echo "[PrefSnap] エラー: AppIcon.icns の生成に失敗しました (${RESOURCES_DIR}/AppIcon.icns)" >&2
    exit 1
fi

# 署名識別子が指定されている場合は Developer ID 署名（Hardened Runtime）、未指定時はアドホック署名を適用する
if [ -n "${PREFSNAP_SIGN_IDENTITY:-}" ]; then
    if ! command -v codesign >/dev/null 2>&1; then
        echo "[PrefSnap] エラー: codesign コマンドが見つかりません" >&2
        exit 1
    fi
    echo "[PrefSnap] Developer ID 署名（Hardened Runtime）を適用しています..."
    # 公証対応のため実行バイナリとアプリバンドルを順にタイムスタンプ付きで署名する
    codesign --force --options runtime --timestamp \
        --sign "${PREFSNAP_SIGN_IDENTITY}" \
        "${MACOS_DIR}/${BUNDLE_APP_NAME}"
    codesign --force --options runtime --timestamp \
        --sign "${PREFSNAP_SIGN_IDENTITY}" \
        "${APP_BUNDLE}"
    codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
elif command -v codesign >/dev/null 2>&1; then
    echo "[PrefSnap] アドホック署名を適用しています..."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "[PrefSnap] 完了: ${APP_BUNDLE} (${BUNDLE_IDENTIFIER}, v${APP_VERSION}, build ${BUILD_NUMBER})"
