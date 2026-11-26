#!/usr/bin/env bash
# PrefSnap アプリアイコン PNG 再生成・同期スクリプト
# Resources/Icons/AppIcon.svg および AppIcon_dev.svg から 1024x1024px の透過 PNG を生成し、
# Resources/Icons/ および Sources/PrefSnap/Resources/ へ同期する
# 使用例: ./scripts/generate-icons.sh

set -euo pipefail

# スクリプトのあるディレクトリからリポジトリルートへ移動する
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ICONS_DIR="${REPO_ROOT}/Resources/Icons"
RUNTIME_RESOURCES_DIR="${REPO_ROOT}/Sources/PrefSnap/Resources"
TARGET_SIZE=1024

# 必須コマンドの確認
if ! command -v sips >/dev/null 2>&1; then
    echo "[PrefSnap] エラー: sips コマンドが見つかりません" >&2
    exit 1
fi

# 作業用一時ディレクトリを作成し、終了時に必ず削除する
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# macOS 標準の Swift + WebKit（WKWebView）で SVG を 1024x1024px 透過 PNG へ描画するヘルパーを作成する
create_webkit_renderer() {
    local swift_file="${WORK_DIR}/render_svg.swift"
    cat > "${swift_file}" <<'SWIFT'
import AppKit
import Foundation
import WebKit

/// SVG ファイルを WKWebView で透過描画し、厳密な指定サイズ（1024x1024 等）の RGBA PNG へ書き出す。
@MainActor
final class SVGRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let outputURL: URL
    private let targetSize: Int
    private var completed = false

    init(outputURL: URL, targetSize: Int) {
        self.outputURL = outputURL
        self.targetSize = targetSize

        let config = WKWebViewConfiguration()
        let frame = NSRect(x: 0, y: 0, width: targetSize, height: targetSize)
        self.webView = WKWebView(frame: frame, configuration: config)
        super.init()

        // 背景を透過に設定し、アイコン周囲の余白を透明のまま出力する
        self.webView.setValue(false, forKey: "drawsBackground")
        self.webView.navigationDelegate = self
    }

    func render(svgContent: String) {
        // 念のため 20 秒のタイムアウトを設けてハングを防止する
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.completed else { return }
            fputs("[PrefSnap] エラー: SVG のレンダリングがタイムアウトしました\n", stderr)
            exit(1)
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              width: \(targetSize)px;
              height: \(targetSize)px;
              background: transparent;
              overflow: hidden;
            }
            svg {
              display: block;
              width: \(targetSize)px;
              height: \(targetSize)px;
            }
          </style>
        </head>
        <body>\(svgContent)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completed = true
        fputs("[PrefSnap] エラー: SVG の読み込みに失敗しました: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completed = true
        fputs("[PrefSnap] エラー: SVG の初期読み込みに失敗しました: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // レイアウトとフィルタ描画が確定するまでわずかに待ってからスナップショットを取得する
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.captureSnapshot()
        }
    }

    private func captureSnapshot() {
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
        snapConfig.snapshotWidth = NSNumber(value: targetSize)

        webView.takeSnapshot(with: snapConfig) { [weak self] image, error in
            guard let self else { return }
            self.completed = true

            if let error {
                fputs("[PrefSnap] エラー: スナップショット取得に失敗しました: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

            guard let image else {
                fputs("[PrefSnap] エラー: レンダリング結果の画像が取得できませんでした\n", stderr)
                exit(1)
            }

            // Retina 環境でも厳密に targetSize x targetSize ピクセルの透過 PNG になるよう再描画する
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: self.targetSize,
                pixelsHigh: self.targetSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                fputs("[PrefSnap] エラー: ビットマップ領域の確保に失敗しました\n", stderr)
                exit(1)
            }

            bitmap.size = NSSize(width: self.targetSize, height: self.targetSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.clear.set()
            NSRect(x: 0, y: 0, width: self.targetSize, height: self.targetSize).fill()
            image.draw(
                in: NSRect(x: 0, y: 0, width: self.targetSize, height: self.targetSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            NSGraphicsContext.restoreGraphicsState()

            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                fputs("[PrefSnap] エラー: PNG エンコードに失敗しました\n", stderr)
                exit(1)
            }

            do {
                try pngData.write(to: self.outputURL)
                exit(0)
            } catch {
                fputs("[PrefSnap] エラー: PNG の書き出しに失敗しました: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }
}

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), size > 0 else {
    fputs("使用法: render_svg.swift <input.svg> <output.png> <size>\n", stderr)
    exit(1)
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

guard let svgContent = try? String(contentsOf: inputURL, encoding: .utf8) else {
    fputs("[PrefSnap] エラー: SVG ファイルを読み込めません: \(inputURL.path)\n", stderr)
    exit(1)
}

let app = MainActor.assumeIsolated { () -> NSApplication in
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    return application
}

MainActor.assumeIsolated {
    let renderer = SVGRenderer(outputURL: outputURL, targetSize: size)
    renderer.render(svgContent: svgContent)
    app.run()
}
SWIFT
    local bin_file="${WORK_DIR}/render_svg"
    swiftc "${swift_file}" -o "${bin_file}"
    echo "${bin_file}"
}

# 利用可能な SVG → PNG 変換手段を判定する
CONVERTER=""
WEBKIT_RENDERER_BIN=""
if command -v rsvg-convert >/dev/null 2>&1; then
    CONVERTER="rsvg-convert"
elif command -v resvg >/dev/null 2>&1; then
    CONVERTER="resvg"
elif command -v swiftc >/dev/null 2>&1; then
    CONVERTER="webkit-swift"
    WEBKIT_RENDERER_BIN="$(create_webkit_renderer)"
else
    echo "[PrefSnap] エラー: 利用可能な SVG → PNG 変換ツール（rsvg-convert / resvg / swiftc）が見つかりません" >&2
    exit 1
fi

echo "[PrefSnap] アイコン生成を開始します（変換方式: ${CONVERTER}, 目標サイズ: ${TARGET_SIZE}x${TARGET_SIZE}px）..."
mkdir -p "${RUNTIME_RESOURCES_DIR}"

# 出力された PNG が 1024x1024px の有効な PNG 画像であることを検証する関数
verify_png_dimensions() {
    local png_path="$1"
    if [ ! -s "${png_path}" ]; then
        echo "[PrefSnap] エラー: PNG ファイルが生成されていないか空です (${png_path})" >&2
        exit 1
    fi

    local width height
    width="$(sips -g pixelWidth "${png_path}" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
    height="$(sips -g pixelHeight "${png_path}" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"

    if [ "${width}" != "${TARGET_SIZE}" ] || [ "${height}" != "${TARGET_SIZE}" ]; then
        echo "[PrefSnap] エラー: 生成された PNG のサイズが想定と異なります (${png_path}: ${width:-unknown}x${height:-unknown}, 期待値: ${TARGET_SIZE}x${TARGET_SIZE})" >&2
        exit 1
    fi
}

# SVG を PNG へ変換して各配置先へ同期する関数
render_and_sync_icon() {
    local base_name="$1"
    local src_svg="${ICONS_DIR}/${base_name}.svg"
    local dst_png="${ICONS_DIR}/${base_name}.png"
    local runtime_png="${RUNTIME_RESOURCES_DIR}/${base_name}.png"

    if [ ! -f "${src_svg}" ]; then
        echo "[PrefSnap] エラー: 元データ SVG が見つかりません (${src_svg})" >&2
        exit 1
    fi

    echo "[PrefSnap] 変換中: ${base_name}.svg -> ${base_name}.png"
    case "${CONVERTER}" in
        rsvg-convert)
            rsvg-convert -w "${TARGET_SIZE}" -h "${TARGET_SIZE}" "${src_svg}" -o "${dst_png}"
            ;;
        resvg)
            resvg -w "${TARGET_SIZE}" -h "${TARGET_SIZE}" "${src_svg}" "${dst_png}"
            ;;
        webkit-swift)
            "${WEBKIT_RENDERER_BIN}" "${src_svg}" "${dst_png}" "${TARGET_SIZE}"
            ;;
    esac

    verify_png_dimensions "${dst_png}"
    cp "${dst_png}" "${runtime_png}"
    verify_png_dimensions "${runtime_png}"
    echo "[PrefSnap] 検証・同期完了: ${dst_png} / ${runtime_png} (${TARGET_SIZE}x${TARGET_SIZE}px)"
}

render_and_sync_icon "AppIcon"
render_and_sync_icon "AppIcon_dev"

echo "[PrefSnap] すべてのアイコン PNG の再生成と同期が完了しました。"
