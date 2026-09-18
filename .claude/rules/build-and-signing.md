# 规则：构建与签名

适用路径：`build.sh`、`Package.swift`、`tools/`

- `swift build` / `swift test` **必须带 `--disable-sandbox`**：CommandLineTools 的 SwiftPM
  在沙箱里编译会报 `sandbox_apply` 失败。本项目无网络依赖，关沙箱无风险。`build.sh` 已内建。
- 签名优先自签证书「Lumen Dev」，退回 ad-hoc。ad-hoc 身份 = CDHash，**每次重编译都会变**：
  - login 钥匙串的 ACL 会把新构建当「陌生程序」，读密钥条目时弹一次授权框——预期行为，不要当 bug 修。
  - 「存在性判断」只查元数据（`kSecReturnAttributes`），**不要解密内容**，否则必弹窗。
- 新增平台/依赖要同步更新 `Package.swift` 的两个 target（LumenKit 是普通 target，
  LumenApp 是 executableTarget，语言模式都锁 .v5）。
- **不要用 `rm -rf` 清旧 bundle**：本机 safe-delete 守卫按「一次删除的内容文件数」拦
  （一个 `.app` 上百个文件 > 阈值 50），`rm` 返回非零会让 `set -e` 中断整条构建、
  `dist` 停在旧版本。`build.sh` 现在走「暂存目录 → `mv` 换入」，旧产物 `mv` 进
  `dist/.trash`，全程不 `rm` 一个 `.app`。
- **构建结果要能被证伪**：`build.sh` 换入前后各校验一次写进 bundle 的构建标记
  （`Contents/Resources/lumen-build-stamp`），不新鲜就非零退出。怀疑「读数不对」时，
  先 `cat dist/Lumen.app/Contents/Resources/lumen-build-stamp` 确认 dist 是本次构建；
  细节见 `docs/VERIFY.md` 第五节。
