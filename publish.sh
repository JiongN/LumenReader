#!/bin/bash
#
# 发布 Lumen：构建 → 自签 → 打 ZIP(/DMG) → 打 tag → 上架 GitHub Releases。
#
#   ./publish.sh v1.0.0          # 完整发布（打包 + tag + 建 Release（若有 gh/token））
#   ./publish.sh v1.0.0 --no-upload  # 只打包 + 打 tag，不建 Release（便于预览产物）
#   ./publish.sh v1.0.0 --dmg    # 额外打一个 DMG（体积更大，默认只打 ZIP）
#
# 约束与取舍（务必先读）：
#   1. **不付 99$/年 → 无 Developer ID → 无法 notarization。**
#      产物用已有的「Lumen Dev」自签证书签名（文件完整性可验证），但用户首次打开
#      会遇「无法验证开发者」→ 需「右键 → 打开」或到「安全性与隐私」允许一次。
#      这是免费 macOS 分发绕不开的代价，本脚本不做任何假装省掉的伪公证。
#   2. 依赖 `build.sh release`（内含自签 + 产物新鲜度自检 +「构建失败不留半个 app」）。
#   3. 中文文件名在 zip 里会出编码问题？→ 本项目 bundle 内部无中文路径，放心。
#   4. 产物放 `/tmp/lumen-dist/`，**不 commit 进 git 仓库**（磁盘已用 96%，避免污染）。
#   5. 创建 GitHub Release 需要认证：
#       有 `gh` → 自动建 Release 并上传 ZIP；
#       有 `GH_TOKEN`/`GITHUB_TOKEN` → 用 GitHub API 上传；
#       都没有 → 打好包、推好 tag，并打印网页操作指引（这一步只能你手动做）。
#       `git push` 走 SSH（本机已配好，`git ls-remote` 可通）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ── 参数解析 ─────────────────────────────────────────────────────────────
VERSION=""
DO_DMG=0
DO_UPLOAD=1
for arg in "$@"; do
    case "$arg" in
        --dmg)                     DO_DMG=1 ;;
        --no-upload)               DO_UPLOAD=0 ;;
        -h|--help)                 echo "用法：$0 <vN.M.P> [--dmg] [--no-upload]"; exit 0 ;;
        v*)                        VERSION="$arg" ;;
        *) echo "未知参数：$arg" >&2; echo "用法：$0 <vN.M.P> [--dmg] [--no-upload]" >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "✗ 必须给出要发布的版本，例如：$0 v1.1.0" >&2
    exit 1
fi
TAG="$VERSION"   # tag 直接用 vX.Y.Z

# ── 前置校验 ─────────────────────────────────────────────────────────────
# 发布必须是干净的 git 工作区：发布行为不该带上未提交的改动。
if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ git 工作区不干净。请先提交或暂存所有改动再发布：" >&2
    git status --short >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "✗ tag $TAG 已存在。发布同一版本号前请先删除旧 tag（git tag -d $TAG）或换新版本。" >&2
    exit 1
fi

# Info.plist 里的 CFBundleShortVersionString 必须与要发布的版本一致。
PLIST="$ROOT/Resources/Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo "")"
echo "▶︎ Info.plist：版本 $PLIST_VERSION（构建 $PLIST_BUILD），发布 $VERSION"
if [[ "$PLIST_VERSION" != "${VERSION#v}" ]]; then
    echo "✗ Info.plist 的版本（$PLIST_VERSION）与要发布的版本（${VERSION#v}）不一致。" >&2
    echo "  请先手动改 Resources/Info.plist 的 CFBundleShortVersionString（并递增 CFBundleVersion），再发布。" >&2
    exit 1
fi

# ── 1. Release 构建 + 自签 ────────────────────────────────────────────────
echo ""
echo "▶︎ 构建 Release + 自签…"
./build.sh release   # 内含 codesign「Lumen Dev」+ 产物新鲜度自检（非零退出即停）

BUNDLE="$ROOT/dist/Lumen.app"
if [[ ! -e "$BUNDLE" ]]; then
    echo "✗ 找不到构建产物：$BUNDLE" >&2
    exit 1
fi

# 产物签名复核：codesign --verify --strict 必须通过才算可分发。
if ! codesign --verify --strict --deep "$BUNDLE" >/dev/null 2>&1; then
    echo "✗ 签名校验失败：$BUNDLE" >&2
    exit 1
fi
echo "✅ 签名校验通过（自签「Lumen Dev」）"

# ── 2. 打 ZIP（体积优先）─────────────────────────────────────────────────
OUT_DIR="/tmp/lumen-dist"
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/Lumen-${VERSION}-macOS.zip"
# 从临时目录打包，保持 bundle 顶层为 Lumen.app，解压后直接是 .app。
STAGE="/tmp/lumen-dist/stage-$VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
echo "▶︎ 打 ZIP…"
# -y：压缩符号链接；--symlinks 保留 .app 内部符号链接
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
echo "✅ ZIP → $ZIP ($(du -h "$ZIP" | cut -f1))"

# ── 3. （可选）打 DMG ────────────────────────────────────────────────────
DMG=""
if [[ "$DO_DMG" == 1 ]]; then
    DMG="$OUT_DIR/Lumen-${VERSION}-macOS.dmg"
    echo "▶︎ 打 DMG…"
    DMG_STAGE="$OUT_DIR/dmg-workspace-$VERSION"
    rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
    cp -R "$BUNDLE" "$DMG_STAGE/"
    # /Applications 软链是「拖进 Applications」的标准入口
    ln -s /Applications "$DMG_STAGE/Applications"
    hdiutil create "$DMG" -volname "Lumen $VERSION" \
        -srcfolder "$DMG_STAGE" -ov -format UDZO >/dev/null
    echo "✅ DMG → $DMG ($(du -h "$DMG" | cut -f1))"
fi

# ── 4. 打 tag 并推送 ─────────────────────────────────────────────────────
echo ""
echo "▶︎ 打 tag $TAG 并推送…"
git tag -a "$TAG" -m "Lumen $VERSION"
if ! git push origin "$TAG"; then
    echo "⚠️  tag 推送失败（可能网络或 SSH 问题）。tag 已本地创建：git tag -d $TAG 可撤销。" >&2
    echo "  产物已生成，可手动 git push origin $TAG。" >&2
fi

# ── 5. 创建 Release + 上传 ───────────────────────────────────────────────
if [[ "$DO_UPLOAD" == 0 ]]; then
    echo ""
    echo "（--no-upload：未创建 GitHub Release。产物在 $OUT_DIR/）"
    exit 0
fi

UPLOAD_TARGET="$ZIP"
UPLOAD_EXTRA=()
if [[ -n "$DMG" ]]; then
    UPLOAD_EXTRA+=("$DMG")
fi

if command -v gh >/dev/null 2>&1; then
    echo "▶︎ 用 gh 创建 Release…"
    gh release create "$TAG" "$ZIP" "${UPLOAD_EXTRA[@]}" \
        --title "Lumen $VERSION" \
        --notes "Lumen $VERSION 发布。详见 https://github.com/JiongN/LumenReader 与仓库 README。"
    echo "✅ Release 已创建并上传：https://github.com/JiongN/LumenReader/releases/tag/$TAG"
elif [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    echo "▶︎ 用 GitHub API 创建 Release…"
    # 创建 release，拿到 upload_url
    RESP="$(curl -sS -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/JiongN/LumenReader/releases" \
        -d "{\"tag_name\":\"$TAG\",\"name\":\"Lumen $VERSION\",\"draft\":false,\"prerelease\":false}")"
    if ! echo "$RESP" | grep -q '"id"'; then
        echo "✗ 创建 Release 失败：$RESP" >&2
        exit 1
    fi
    RELEASE_ID="$(echo "$RESP" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
    # 逐个上传产物
    for asset in "$ZIP" "${UPLOAD_EXTRA[@]}"; do
        echo "  上传 $(basename "$asset")…"
        curl -sS -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/zip" \
            "https://uploads.github.com/repos/JiongN/LumenReader/releases/$RELEASE_ID/assets?name=$(basename "$asset")" \
            --data-binary @"$asset" >/dev/null
    done
    echo "✅ Release 已创建并上传：https://github.com/JiongN/LumenReader/releases/tag/$TAG"
else
    echo ""
    echo "⚠️  未检测到 gh 或 GH_TOKEN/GITHUB_TOKEN，无法自动创建 Release。"
    echo "    以下是你需要手动做的最后一步："
    echo "      1. 打开 https://github.com/JiongN/LumenReader/releases/new?tag=$TAG"
    echo "      2. 标题填「Lumen $VERSION」"
    echo "      3. 把产物拖进「Attach binaries」："
    echo "         $ZIP"
    [[ -n "$DMG" ]] && echo "         $DMG"
    echo "      4. 点「Publish release」"
fi

echo ""
echo "✅ 发布流程完成。产物目录：$OUT_DIR/"