#!/bin/bash
#
# 构建 Lumen.app
#
#   ./build.sh              调试构建
#   ./build.sh release      发布构建（优化 + 体积更小）
#   ./build.sh release run  构建后直接启动
#   ./build.sh clean        清掉 .build 与 dist
#
# 说明：本机只装了 CommandLineTools，没有 Xcode，因此走 SwiftPM + 手工组装
# bundle 的路径。--disable-sandbox 是必须的：CLT 自带的 SwiftPM 在沙箱里
# 编译 Package.swift 会报 "sandbox_apply: Operation not permitted"。
#
# ── 为什么是「暂存目录 → mv 换入」而不是「rm -rf 后重建」 ──────────────
# 本机有一个 safe-delete 守卫，会把「一次删除的内容文件数超过阈值」的 rm 拦下
# 并返回非零（实测输出：`[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED]
# {"count":100,"threshold":50,...,"targets":[".../dist/Lumen.app"]}`）。而一个
# .app 的内容就有上百个文件 → `rm -rf "$BUNDLE"` 被拦 → `set -e` 立刻中断 →
# **构建没跑完、dist 还是旧的**，调用方却只看到一个和构建毫不相干的 SAFE_DELETE
# 报错。次生灾害更隐蔽：之后所有验证都跑在旧二进制上，读数全错还以为构建成功了。
#
# 所以这里：
#   1. 全程组装到临时目录（STAGE），**不碰** dist；编译/组装/签名任何一步失败，
#      旧产物原封不动（这就是「构建失败不留半个 app」的原子性来源）。
#   2. 换入只用 `mv`（同一文件系统内是 rename），不删除任何 bundle。
#      旧产物 mv 到 dist/.trash（下一轮构建尽力清理），绝不 `rm -rf` 一个 .app。
#   3. 换入前后各有一道「产物新鲜度」自检：核对写进 bundle 的**构建标记**。
#      不新鲜就**非零退出**并明确报「dist 未更新」——「构建通过」本身也要能被证伪
#      （README 硬约束第 8 条）。人为演练见下方 LUMEN_BUILD_SABOTAGE。
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
    # 用户显式清理。safe-delete 守卫可能拦下批量删除——拦下时**如实报告**并给出
    # 可用的替代命令，不要静默假装清理成功（那正是本脚本要杜绝的一类假信号）。
    for target in .build dist; do
        [[ -e "$target" ]] || continue
        if rm -rf "$target" >/dev/null 2>&1; then
            echo "已删除 $target"
        else
            echo "⚠︎ $target 未能删除（可能被 safe-delete 守卫拦截）；" \
                 "可手动执行： mv $target /tmp/" >&2
        fi
    done
    exit 0
fi

APP_NAME="Lumen"
DIST_DIR="$ROOT/dist"
BUNDLE="$DIST_DIR/$APP_NAME.app"
# 构建标记：写进 bundle 再读回来核对，用来证明「dist 里确实是这一次构建的东西」。
STAMP_NAME="lumen-build-stamp"
BUILD_ID="$(date +%Y%m%d-%H%M%S)-$$"
STAGE="$DIST_DIR/.$APP_NAME.staging.$BUILD_ID"
TRASH="$DIST_DIR/.trash"

# 换入前的任何一步失败（编译/组装/签名/自检）都会触发这里：把暂存目录收掉，
# 别在 dist 里留垃圾。成功换入后 STAGE 已不存在，这里自然 no-op。
# 清理同样可能被 safe-delete 守卫拦下（那正是本脚本要绕开的坑），故退一步 move 到 .trash。
cleanup_stage() {
    [[ -e "$STAGE" ]] || return 0
    rm -rf "$STAGE" >/dev/null 2>&1 || mv "$STAGE" "$TRASH"/ >/dev/null 2>&1 || true
}
trap cleanup_stage EXIT

echo "▶︎ 编译（${CONFIG}）…"
swift build --disable-sandbox -c "$CONFIG"

BIN=".build/$CONFIG/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "✗ 找不到编译产物：$BIN" >&2
    exit 1
fi

echo "▶︎ 组装 bundle（暂存到 ${STAGE}）…"
# 每次都新建一个唯一的暂存目录：这样既不需要「先删旧的暂存」、也就不触碰守卫。
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
fi

# SwiftPM 的资源包（若后续新增）需要一起搬进 bundle
for resource in .build/"$CONFIG"/*.bundle; do
    [[ -e "$resource" ]] || continue
    cp -R "$resource" "$STAGE/Contents/Resources/"
done

printf 'APPL????' > "$STAGE/Contents/PkgInfo"

printf '%s\n' "$BUILD_ID" > "$STAGE/Contents/Resources/$STAMP_NAME"

echo "▶︎ 签名…"
# 优先用自签证书「Lumen Dev」（2026-09-17 建于 login 钥匙串，有效期 10 年）。
# 它的身份稳定——重编译后 CDHash 不再变化，钥匙串 ACL 不会把新构建当成陌生
# 程序，API 密钥的授权框从此只在切换身份那一次出现。
# 证书若被删（换机器/重装钥匙串），自动退回 ad-hoc，构建不会失败。
SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Lumen Dev"'; then
    SIGN_IDENTITY="Lumen Dev"
fi
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGE" >/dev/null 2>&1

# ── 证伪演练钩子 ──────────────────────────────────────────────
# 新鲜度自检必须能被证伪（README 硬约束第 8 条：写完人为让它失败一次）。
#   LUMEN_BUILD_SABOTAGE=stage → 把暂存目录里的标记写坏 → 换入**前**自检应当失败，
#                                且旧 dist 原封不动（演练「把临时目录写坏」）。
#   LUMEN_BUILD_SABOTAGE=dist  → 换入后把 dist 里的标记写坏 → 换入**后**自检应当失败
#                                （演练「dist 不是本次构建」这条闸门本身有效）。
SABOTAGE="${LUMEN_BUILD_SABOTAGE:-}"
if [[ "$SABOTAGE" == "stage" ]]; then
    echo "（证伪演练：把暂存目录的构建标记写坏，换入前自检应当失败）" >&2
    printf '%s\n' "STALE-STAGE-SIMULATED" > "$STAGE/Contents/Resources/$STAMP_NAME"
fi

# ── 换入前自检：暂存 bundle 必须完整、且标记正确 ──
if [[ ! -s "$STAGE/Contents/MacOS/$APP_NAME" ]]; then
    echo "✗ 暂存 bundle 里没有可执行文件（或为空）：$STAGE" >&2
    exit 1
fi
STAGED_STAMP="$(cat "$STAGE/Contents/Resources/$STAMP_NAME" 2>/dev/null || true)"
if [[ "$STAGED_STAMP" != "$BUILD_ID" ]]; then
    echo "✗ 暂存 bundle 的构建标记不匹配：读到 '${STAGED_STAMP:-<缺失>}'，本次应为 '$BUILD_ID'" >&2
    echo "  → 未换入，dist 保持原状。" >&2
    exit 1
fi
if ! codesign --verify --strict "$STAGE" >/dev/null 2>&1; then
    echo "✗ 暂存 bundle 签名校验失败，未换入。" >&2
    exit 1
fi

echo "▶︎ 换入 dist…"
# 旧产物 mv 到 .trash（rename，不删除）。清 .trash 是尽力而为：即使被守卫拦下
# 也不影响本次构建（不参与 set -e），最多让 .trash 多留一份。
rm -rf "$TRASH" >/dev/null 2>&1 || true
mkdir -p "$TRASH"

SAVED=""
if [[ -e "$BUNDLE" ]]; then
    SAVED="$TRASH/$APP_NAME.app.$BUILD_ID"
    mv "$BUNDLE" "$SAVED"
fi
if ! mv "$STAGE" "$BUNDLE"; then
    # 换入失败就把旧产物搬回来，保证 dist 永远有一个可用的 app。
    if [[ -n "$SAVED" && -e "$SAVED" ]]; then
        mv "$SAVED" "$BUNDLE"
        echo "✗ 换入失败，已还原旧产物到 $BUNDLE" >&2
    else
        echo "✗ 换入失败，且无旧产物可还原" >&2
    fi
    exit 1
fi

if [[ "$SABOTAGE" == "dist" ]]; then
    echo "（证伪演练：把 dist 里的构建标记写坏，换入后自检应当失败）" >&2
    printf '%s\n' "STALE-DIST-SIMULATED" > "$BUNDLE/Contents/Resources/$STAMP_NAME"
fi

# ── 换入后自检：正式路径里读回来的标记必须与本次一致，否则 dist 未更新 ──
ACTUAL_STAMP="$(cat "$BUNDLE/Contents/Resources/$STAMP_NAME" 2>/dev/null || true)"
if [[ "$ACTUAL_STAMP" != "$BUILD_ID" ]]; then
    echo "✗ dist 未更新：$BUNDLE 里的构建标记 = '${ACTUAL_STAMP:-<缺失>}'，本次构建 = '$BUILD_ID'" >&2
    exit 1
fi
if [[ ! -s "$BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
    echo "✗ dist 里没有可执行文件（或为空）：$BUNDLE/Contents/MacOS/$APP_NAME" >&2
    exit 1
fi
if ! codesign --verify --strict "$BUNDLE" >/dev/null 2>&1; then
    echo "✗ dist bundle 签名校验失败：$BUNDLE" >&2
    exit 1
fi

SIZE="$(du -sh "$BUNDLE" | cut -f1)"
echo "✅ 构建完成：${BUNDLE}（${SIZE}），构建标记 ${BUILD_ID}"

if [[ "$ACTION" == "run" ]]; then
    echo "▶︎ 启动…"
    open "$BUNDLE"
fi
