# 规则：UI / 视觉 / 动效（Apple 风）

适用路径：`Sources/LumenApp/`（尤其 `Design/`）

## 色彩

- 强调色用降饱和蓝紫 `#56639F`（亮）/ 对应暗色值，定义在 `DS.Palette.accent`。
  **不要在视图里硬编码强调色**；新颜色一律进 `DesignTokens.swift`。
- 内容界面禁止高饱和大色块；选中态用「淡色胶囊 + 彩色前景图标」，不用实心色块。
- 阅读区是主角：chrome（工具栏/侧栏）只做衬托，内容占比优先。

## 动效

- 时长一律 < 300ms（按压 100–160ms、小弹层 125–200ms、下拉 150–250ms、模态 200–500ms）。
- 缓动：进场/退场 `ease-out` 或强曲线；屏上移动 `ease-in-out`；**禁用 `ease-in`**；
  悬停/颜色用 `ease`。曲线 token 在 `DS.Motion`，不要手写 cubic-bezier。
- 只动 `transform` / `opacity`；可快速重复的 UI 用 transition 而非 keyframes。
- 键盘触发的动作（命令面板、快捷键跳转）**不动画**。
- 现实中没有东西凭空出现：进场从 `scale(0.95) + opacity 0` 起，不用 `scale(0)`。

## 图标

- 应用内 AI 标识统一用 `AIIcon.swift` 的「细环 + 缺口实心点」字形，**不要再用
  `sparkles` 等 SF Symbol 拼 AI**。
- 应用/品牌图标唯一源是 `branding/*.svg`；改图标走 `branding/render.js` 光栅化 +
  `iconutil` 合成 icns（见 `.claude/rules/branding-assets.md`）。
