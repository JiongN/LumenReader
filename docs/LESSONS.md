# LESSONS — 错误沉淀账本

> 每条记录：现象 → 根因 → 沉淀到哪。新错误修完后必须在这里登记，
> 并把根因写进 `.claude/rules/`、回归测试或相关文档三者之一——
> 只修不记，同一个坑会再掉一次。

---

## #1 「最近打开」每次启动静默清空（2026-09-17）

- **现象**：首页画廊从未显示过任何真实记录；`recent.json` 文件明明存在且内容完好。
- **根因**：`RecentDocuments.persist()` 用 `.iso8601` 编码日期，`load()` 的
  `JSONDecoder()` 没设对应策略 → 解码整体失败 → `try? ?? []` 吞掉错误 → 归零。
- **沉淀**：
  - 代码修复 + 注释（`RecentDocuments.swift` load()）
  - 回归测试 `Tests/LumenKitTests/RecentDocumentsDecodingTests.swift`
  - 规则 `.claude/rules/persistence-coding.md`

## #2 图标书页路径画成「M / 蝶形结」（2026-09-17）

- **现象**：v2 App 图标与首页品牌字形里，摊开的书页渲染成两个交叉的细条。
- **根因**：贝塞尔控制点放在了端点的**另一侧**（镜像侧向时控制点没跟着翻），
  二次曲线反向交叉。SwiftUI `Shape` 与 CoreGraphics 都一样：控制点必须与
  弧线行进方向同侧。
- **沉淀**：`.claude/rules/branding-assets.md`（禁止手绘路径做图标，SVG 为唯一源）；
  `WelcomeView.swift` 里 BookPage 保留注释说明侧向与控制点同侧的原因。

## #3 图标光晕变成硬边圆盘（2026-09-17）

- **现象**：图标顶部的「光」渲染为边缘锐利的实心圆。
- **根因**：`NSGradient` 是**线性**渐变，没有径向衰减；想发光得用
  `CGContext.drawRadialGradient`。
- **沉淀**：v3 已整体改走 SVG 管线（radialGradient 语义直接可用），
  规则见 `.claude/rules/branding-assets.md`。

## #4 SVG 光栅化环境踩坑（2026-09-17）

- **现象**：`puppeteer.launch()` 反复失败——找不到浏览器、viewport 报错。
- **根因**：puppeteer 的浏览器缓存目录是空的（从未下载）；headless 模式参数
  因版本而异（新版本用 `headless: 'shell'` 且不需要 `executablePath` 指向不存在的路径）。
- **沉淀**：最终方案 `puppeteer-core` + 系统 Chrome + `headless: 'shell'`，
  固化在 `branding/render.js` 与 `.claude/rules/branding-assets.md`。

## #5 SwiftPM 沙箱编译失败（历史）

- **现象**：`swift build` 报 `sandbox_apply` 失败。
- **根因**：CommandLineTools 的 SwiftPM 沙箱与该机器环境不兼容。
- **沉淀**：`build.sh` 内建 `--disable-sandbox`；规则 `.claude/rules/build-and-signing.md`。

## #6 ad-hoc 签名导致钥匙串反复弹窗（历史）

- **现象**：每次重编译后，读 API Key 弹一次钥匙串授权框。
- **根因**：ad-hoc 身份 = CDHash，每次构建都变，login 钥匙串 ACL 认的是身份。
- **沉淀**：`docs/ISSUES-2026-09-17.md` 第 9 节（自签证书方案）；
  规则 `.claude/rules/build-and-signing.md`（元数据查询不解密）。
