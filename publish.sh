#!/bin/bash
# 本地打包：./publish.sh v1.1.0 --no-upload
# 对外发布：./publish.sh v1.1.0 [--dmg]（提交、打 tag、推送前请阅读 docs/RELEASING.md）
# 发布产物统一存放 releases/<version>/，不进入 Git。
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
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ 版本必须为 vN.M.P" >&2
    exit 1
fi
TAG="$VERSION"

# ── 前置校验 ─────────────────────────────────────────────────────────────
# 发布必须是干净的 git 工作区：发布行为不该带上未提交的改动。
if [[ "$DO_UPLOAD" == 1 && -n "$(git status --porcelain)" ]]; then
    echo "✗ git 工作区不干净。请先提交所有改动再发布（仅暂存仍不算干净）：" >&2
    git status --short >&2
    exit 1
fi

if [[ "$DO_UPLOAD" == 1 ]] && git show-ref --verify --quiet "refs/tags/$TAG"; then
    echo "✗ tag ${TAG} 已存在。发布同一版本号前请先删除旧 tag（git tag -d ${TAG}）或换新版本。" >&2
    exit 1
fi

# Info.plist 里的 CFBundleShortVersionString 必须与要发布的版本一致。
PLIST="$ROOT/Resources/Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo "")"
echo "▶︎ Info.plist：版本 ${PLIST_VERSION}（构建 ${PLIST_BUILD}），发布 ${VERSION}"
if [[ "$PLIST_VERSION" != "${VERSION#v}" ]]; then
    echo "✗ Info.plist 的版本（${PLIST_VERSION}）与要发布的版本（${VERSION#v}）不一致。" >&2
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
echo "✅ 签名校验通过（签名身份以 codesign -dv 输出为准）"

# ── 2. 打 ZIP（体积优先）─────────────────────────────────────────────────
OUT_DIR="$ROOT/releases/$VERSION"
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/Lumen-${VERSION}-macOS.zip"
echo "▶︎ 打 ZIP…"
# -y：压缩符号链接；--symlinks 保留 .app 内部符号链接
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP"
echo "✅ ZIP → $ZIP ($(du -h "$ZIP" | cut -f1))"

# ── 3. （可选）打 DMG ────────────────────────────────────────────────────
DMG=""
if [[ "$DO_DMG" == 1 ]]; then
    DMG="$OUT_DIR/Lumen-${VERSION}-macOS.dmg"
    echo "▶︎ 打 DMG…"
    DMG_STAGE="$(mktemp -d "$OUT_DIR/.dmg-workspace.XXXXXX")"
    trap 'rm -rf "$DMG_STAGE"' EXIT
    cp -R "$BUNDLE" "$DMG_STAGE/"
    # /Applications 软链是「拖进 Applications」的标准入口
    ln -s /Applications "$DMG_STAGE/Applications"
    hdiutil create "$DMG" -volname "Lumen $VERSION" \
        -srcfolder "$DMG_STAGE" -ov -format UDZO >/dev/null
    echo "✅ DMG → $DMG ($(du -h "$DMG" | cut -f1))"
fi

# Local review must not create tags or contact the remote.
cp "$BUNDLE/Contents/Resources/lumen-build-stamp" "$OUT_DIR/build-stamp.txt"
{
    echo "version=$VERSION"
    echo "commit=$(git rev-parse HEAD)"
    echo "architecture=$(uname -m)"
    echo "working_tree_dirty=$(test -z "$(git status --porcelain)" && echo false || echo true)"
} > "$OUT_DIR/build-info.txt"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS)
if [[ -n "$DMG" ]]; then
    (cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" >> SHA256SUMS)
fi
if [[ "$DO_UPLOAD" == 0 ]]; then
    echo "✅ 本地打包完成，未创建或推送 tag：$OUT_DIR"
    exit 0
fi
if ! command -v gh >/dev/null 2>&1 && [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    echo "✗ 产物已生成，但没有 gh 或 GitHub token；未创建或推送 tag。" >&2
    exit 1
fi
if command -v gh >/dev/null 2>&1; then
    gh auth status >/dev/null 2>&1 || { echo "✗ gh 尚未登录；未创建或推送 tag。" >&2; exit 1; }
fi
git tag -a "$TAG" -m "Lumen $VERSION"
if ! git push origin "$TAG"; then
    echo "✗ tag 推送失败，停止发布；本地 tag 与产物已保留，请检查网络后重试推送。" >&2
    exit 1
fi

UPLOAD_EXTRA=("$OUT_DIR/SHA256SUMS" "$OUT_DIR/build-info.txt")
if [[ -n "$DMG" ]]; then
    UPLOAD_EXTRA+=("$DMG")
fi

if command -v gh >/dev/null 2>&1; then
    echo "▶︎ 用 gh 创建 Release…"
    # 约定（2026-09-22）：GitHub Release 不写更新记录/changelog，说明只保留这一句指路。
    # 变更历史以 git log 为准（本地可见）。不要在这里加「本次更新内容」清单。
    gh release create "$TAG" "$ZIP" "${UPLOAD_EXTRA[@]}" \
        --title "Lumen $VERSION" \
        --notes "Lumen $VERSION 发布。详见 https://github.com/JiongN/LumenReader 与仓库 README。"
    echo "✅ Release 已创建并上传：https://github.com/JiongN/LumenReader/releases/tag/$TAG"
elif [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    echo "▶︎ 用 GitHub API 创建 Release…"
    # 创建 release，拿到 upload_url
    RESP="$(curl -f -sS -X POST \
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
        curl -f -sS -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/octet-stream" \
            "https://uploads.github.com/repos/JiongN/LumenReader/releases/$RELEASE_ID/assets?name=$(basename "$asset")" \
            --data-binary @"$asset" >/dev/null
    done
    echo "✅ Release 已创建并上传：https://github.com/JiongN/LumenReader/releases/tag/$TAG"
else
    echo ""
    echo "⚠️  未检测到 gh 或 GH_TOKEN/GITHUB_TOKEN，无法自动创建 Release。"
    echo "    以下是你需要手动做的最后一步："
    echo "      1. 打开 https://github.com/JiongN/LumenReader/releases/new?tag=$TAG"
    echo "      2. 标题填「Lumen ${VERSION}」"
    echo "      3. 把产物拖进「Attach binaries」："
    echo "         $ZIP"
    [[ -n "$DMG" ]] && echo "         $DMG"
    echo "      4. 点「Publish release」"
fi

echo ""
echo "✅ 发布流程完成。产物目录：$OUT_DIR/"
