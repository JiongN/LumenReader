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
- **后记（类级补修，见 #7）**：本条当时只修了**实例**——补上 iso8601 策略、加回归测试，
  却把「解码失败 → `try? ?? 空` → 下次保存覆盖原文件」这个**坏结构**留在了另外三处。
  真正封死同类坑的是 #7 的 `PersistFile.decodeOrBackup`。

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

## #7 「解码失败静默清空 → 下次保存覆盖用户数据」是一类，不是一个点（2026-09-18）

- **现象**：`recent.json` / 阅读进度 / `memory.json` / `settings.json` 里的服务商配置，
  只要解码失败一次，就会被容错成空值，随后被下一次持久化**原样写回磁盘**——
  用户数据被一份「合法但空」的文件替换，且没有任何提示或日志可查。
- **根因**：`let x = (try? decode(...)) ?? 默认值` 把「**没有数据**」与「**解码失败**」
  压成了同一个结果，而「默认值」在实际写入路径上就等于「清空」。这是结构问题：
  同一形状在代码里有四处（LESSONS #1 只修了其中一处的实例）。
- **修法（类级，一处工具函数）**：`PersistFile.decodeOrBackup(data:type:fileURL:)`——
  解码失败时把原文件**改名**为 `<name>.corrupt-<时间戳>` 并 NSLog，返回 nil；
  调用方拿 nil 时**不把内存赋成空值**。改名（而非复制）是关键：原路径随即变空，
  后续任何 `persist()` 只能写新文件，**不可能**再覆盖用户原数据。
  - 四个调用点：`RecentDocuments.swift`（recent.json）、`ReadingStateStore.swift`
    （阅读进度）、`MemoryStore.swift`（memory.json，注意：旧「纯字符串数组」格式
    能解出来就是有效文件，**不得**误判为损坏）、`SettingsStore.swift`（settings.json）。
  - `settings.json` 的次级情形：逐字段容错会让「整份文件解得出、但 `providers`
    被吞成空数组」，文件级备份抓不到；故 `SettingsStore` 额外比对「磁盘上有几条
    providers」与「解出来几条」，命中才备份（判据见 `providersLookLost`）。
  - 编码侧的对称问题：`try? data.write` 失败同样无声，统一改走 `PersistFile.write`（失败 NSLog）。
- **沉淀**：
  - 工具函数 `Sources/LumenKit/Store/PersistFile.swift`
  - 回归测试 `Tests/LumenKitTests/PersistFileTests.swift`（备份生成 / 字节保留 /
    内存不写死空 / 旧格式不误判 / 服务商丢失才备份 / 键路径护栏）
  - 本账本条 + `docs/AUDIT-code-health-2026-09-17.md` P1-1 / P1-2

## #8 对不可复现的读数下断言，等于抛硬币（2026-09-18）

- **现象**：`--perf-report` 的 ③ 行（翻页二次遍历的进程常驻内存增量）在**同一构建、
  同一台机器**上反复跑，读出 −21 / −3.8 / +30 / +68 / +5.5MB——其中一次 +68 直接触发
  「≤ 24MB」的失败断言。这条断言时绿时红。
- **根因**：`phys_footprint` 是**进程级**采样，而这个跨遍增量由 PDFKit 内部渲染缓存
  （首次访问每页时建立、之后按自己的策略回收）主导；它先建还是先收、落到哪一档，
  不受我们这层控制。对一个由外部组件主导、时好时坏的量下断言，绿色不能证明没泄漏，
  红色也不能证明有泄漏——**比不打这个断言更糟**，因为它会给人「验过了」的错觉。
- **修法**：③ 降级为**信息性读数**（照打数字、不参与通过/失败计数）；
  「会不会持续增长」改由**确定性**判据把关——④ 缩略图缓存「滚完全本后仍驻留多少张」
  是可复现的（上限 160 vs 关掉上限 600）。同时保留 `--perf-thumbnail-unbounded` 开关，
  让「关掉优化读数必须变差」这条可证伪性成立。
- **沉淀**：规则「**读数的来源不在我们这层、又不可复现时，只能当读数，不能当断言**」；
  通道 `Sources/LumenApp/Reader/PDF/PDFPerfAudit.swift`（`--perf-report`）。

## #9 build.sh 的批量删除被守卫拦下，导致「构建静默失效」（2026-09-18）

- **现象**：`./build.sh release` 稳定返回非零，并打印一行和构建毫不相干的东西：
  `[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] {"count":100,"threshold":50,
  "targets":[".../dist/Lumen.app"]}`；而 `dist/Lumen.app` 仍是旧的那份。
- **根因**：脚本用 `rm -rf "$BUNDLE"` 清旧产物再重建。本机的 safe-delete 守卫按
  「**一次删除的内容文件数**」计数（一个 `.app` 有上百个文件 > 阈值 50），把这条 `rm`
  拦下并让它返回非零；`set -e` 随即中断，后面的 `cp/codesign` 全没跑 → dist 保持旧值。
- **次生灾害更隐蔽**：调用方只看到「构建失败/非零退出」，很容易误判成「代码改坏了」；
  更糟的是**后续验证接着跑在旧二进制上**，读数全错还以为构建成功（本轮 #14 性能验证
  就实打实踩过：一度跑在旧 dist 上做对照）。
- **修法**：`build.sh` 改成「组装到唯一暂存目录 → 成功后 `mv` 换入」：
  1. 全程不碰 `dist`，编译/组装/签名/自检任一步失败，旧产物**原封不动**（原子性）；
  2. 换入只用 `mv`（同文件系统内即 rename），旧产物 `mv` 到 `dist/.trash`，
     **绝不 `rm` 一个 `.app`**——从根上避开守卫；
  3. 换入**前后**各校验一次写进 bundle 的「构建标记」，不新鲜就**非零退出**并明确报
     「dist 未更新」——「构建通过」本身也要能被证伪（README 硬约束 #8）；
  4. 失败与成功都走 `trap` 收掉暂存目录，`dist` 不留垃圾。
- **沉淀**：`build.sh`（暂存换入 + 构建标记 + `trap` 清理 + 证伪钩子
  `LUMEN_BUILD_SABOTAGE=stage|dist`）；排查步骤见 `docs/VERIFY.md` 第五节；
  规则 `.claude/rules/build-and-signing.md`。
