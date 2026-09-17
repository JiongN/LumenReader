# 规则：构建与签名

适用路径：`build.sh`、`Package.swift`、`tools/`

- `swift build` / `swift test` **必须带 `--disable-sandbox`**：CommandLineTools 的 SwiftPM
  在沙箱里编译会报 `sandbox_apply` 失败。本项目无网络依赖，关沙箱无风险。`build.sh` 已内建。
- 签名优先自签证书「Lumen Dev」，退回 ad-hoc。ad-hoc 身份 = CDHash，**每次重编译都会变**：
  - login 钥匙串的 ACL 会把新构建当「陌生程序」，读密钥条目时弹一次授权框——预期行为，不要当 bug 修。
  - 「存在性判断」只查元数据（`kSecReturnAttributes`），**不要解密内容**，否则必弹窗。
- 新增平台/依赖要同步更新 `Package.swift` 的两个 target（LumenKit 是普通 target，
  LumenApp 是 executableTarget，语言模式都锁 .v5）。
