#!/bin/bash
#
# 构建 Lumen.app
#
#   ./build.sh              调试构建
#   ./build.sh release      发布构建（优化 + 体积更小）
#   ./build.sh release run  构建后直接启动
#
# 说明：本机只装了 CommandLineTools，没有 Xcode，因此走 SwiftPM + 手工组装
# bundle 的路径。--disable-sandbox 是必须的：CLT 自带的 SwiftPM 在沙箱里
# 编译 Package.swift 会报 "sandbox_apply: Operation not permitted"。
#
set -euo pipefail

CONFIG="debug"
ACTION=""

for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        run)           ACTION="run" ;;
        clean)         ACTION="clean" ;;
        *) echo "未知参数：$arg" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [[ "$ACTION" == "clean" ]]; then
    rm -rf .build dist
    echo "已清理 .build 与 dist"
    exit 0
fi

APP_NAME="Lumen"
BUNDLE="$ROOT/dist/$APP_NAME.app"

echo "▶︎ 编译（${CONFIG}）…"
swift build --disable-sandbox -c "$CONFIG"

BIN=".build/$CONFIG/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "✗ 找不到编译产物：$BIN" >&2
    exit 1
fi

echo "▶︎ 组装 bundle…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# SwiftPM 的资源包（若后续新增）需要一起搬进 bundle
for bundle in .build/"$CONFIG"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    cp -R "$bundle" "$BUNDLE/Contents/Resources/"
done

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "▶︎ 签名（ad-hoc）…"
# Apple Silicon 上未签名的二进制无法执行，ad-hoc 签名即可本地运行。
# 没有 Developer ID 证书，所以不做公证，首次打开可能需要右键 → 打开。
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1

SIZE="$(du -sh "$BUNDLE" | cut -f1)"
echo "✅ 构建完成：${BUNDLE}（${SIZE}）"

if [[ "$ACTION" == "run" ]]; then
    echo "▶︎ 启动…"
    open "$BUNDLE"
fi
