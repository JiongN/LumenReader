# CLAUDE.md — LumenReader

> 只放**全局必读**。模块细节在 `.claude/rules/`（按路径生效），
> 设计决策在 `docs/ARCHITECTURE.md`，错误教训在 `docs/LESSONS.md`，自检方法在 `docs/VERIFY.md`。

## 项目目标

macOS 原生阅读器（PDF + EPUB + 自接 AI），给做研究的人用。
纯 Swift/SwiftUI + SwiftPM，**无 Xcode 工程、无 Electron、无云端**；AI 走用户自己的
OpenAI 兼容端点（BYOK）。视觉基调：Apple 风——简洁、留白、克制、沉浸。

## 全局红线

1. **`LumenKit` 不 import SwiftUI**——引擎层与界面层的分界是硬的。
2. **AI 密钥只存本机钥匙串**，任何改动不得把密钥写进文件、日志或网络请求。
3. **PDF 批注写回原文件（PDFKit annotation）；EPUB 批注只存应用目录**（写回会破坏 zip 结构）。
4. 界面动效遵守 `.claude/rules/design-ui.md`：<300ms、ease-out、只动 transform/opacity。
5. 存取成对：**编码与解码策略必须写在相邻两行**（教训见 `docs/LESSONS.md` #1）。
6. 无证书环境下 ad-hoc 签名身份每次构建都会变——不要依赖「应用身份稳定」的机制。

## 顶层架构

```
LumenApp（SwiftUI 界面层）
  RootView → ReaderContainerView（三栏：LeftRail / SidebarColumn / 正文 + AIPanelView）
  AppState —— 全局状态与动作（菜单、命令面板、快捷键共用）
       │ ReaderBridge（唯一通道，格式无关的可选闭包接口）
LumenKit（引擎层：Document / Store / AI / OCR）
```

职责与「为什么这样设计」：`docs/ARCHITECTURE.md`。

## 核心命令

```bash
./build.sh              # 编译 + 组装 dist/Lumen.app + 签名（内部已带 --disable-sandbox）
./build.sh release      # Release 构建
./build.sh debug run    # 编译并启动
swift test --disable-sandbox   # 跑 LumenKitTests（沙箱内 SwiftPM 会失败）
swift tools/make_test_pdfs.swift   # 生成测试 PDF

# 自检/截图通道（无视觉环境下的客观验证）
dist/Lumen.app/Contents/MacOS/Lumen --capture <png> --capture-delay N \
    [--open book.pdf] [--run-action showThumbnails]
```

文档打开：`dist/Lumen.app/Contents/MacOS/Lumen --open /path/to/book.pdf`
