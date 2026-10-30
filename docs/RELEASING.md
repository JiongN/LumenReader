# 构建、发布与目录维护

## 本地构建与打包

```bash
swift test --disable-sandbox
./build.sh release
./publish.sh v1.1.0 --no-upload
# 需要安装镜像时：./publish.sh v1.1.0 --no-upload --dmg
```

版本号必须为 `vN.M.P`，且等于 `Resources/Info.plist` 的 `CFBundleShortVersionString`。普通构建写到 `dist/Lumen.app`；本地打包写到 `releases/vN.M.P/`。`--no-upload` 不创建标签、不推送、不建立 GitHub Release，允许包含未提交改动以供审阅，`build-info.txt` 会标记 dirty。

发布目录包含 ZIP、可选 DMG、SHA256SUMS、build-info.txt 与 build-stamp.txt。`build-info.txt` 记录版本、构建号、提交、架构、签名身份及签名验证结果。同版本重复本地打包会替换该目录中的同名包；正式发布版应保留，下一次发布递增版本。ZIP 内顶层为 Lumen.app。当前只构建本机架构，不能宣传为 Universal。

```bash
cd releases/v1.1.0
shasum -a 256 -c SHA256SUMS
codesign --verify --strict --deep ../../dist/Lumen.app
```

签名优先 Lumen Dev，缺失则 ad-hoc；均不等于 Apple Developer ID 公证。重编译会改变 CDHash。API 密钥现在与签名身份无关。

## 对外发布

### 应用内更新兼容要求（2026-10-27）

GitHub 正式 Release 必须包含 `Lumen-vN.M.P-macOS.zip`，顶层为 `Lumen.app`。优先使用 REST 资产的 `size` 与 `digest: sha256:...`；API限流或不可用时，通过官方 `/releases/latest` 重定向取得正式版，再读取同版 `SHA256SUMS` 和ZIP的HEAD长度。两条路径均须取得校验值和长度才启用应用内安装，随后仍核对签名。ZIP 仅允许普通文件和目录、展开总量不超过512 MiB，不支持符号链接、ZIP64或加密包。当前包满足这些限制。草稿、预发布、同版/降级、不匹配仓库地址或无校验值的资产不能自动安装。

后续构建保留与当前发布包相同的签名证书，并随包分发已签名的 `LumenUpdateWorker`。自签证书可用，ad-hoc 无稳定证书时不自动安装；迁移签名证书须走一次人工安装，不能关闭校验绕过。版本、bundle ID、处理器架构、最低系统和深度代码签名都在安装前核验。不要为更新功能生成或上传私钥。

用户点击「下载并重启更新」后，后台下载并校验，正常退出等待 PDF/会话保存；worker 等待旧进程退出才进行同卷替换，失败恢复原应用。成功后重开原文档，保留同级隐藏 `.Lumen Previous <UUID>.app` 备份。不可写目录、App Translocation或只读磁盘映像须先手动移入可写位置；不请求管理员权限或修改 Gatekeeper。自动检查延后首屏15秒，最多每天一次；隔离测试与诊断启动不自动联网。

本地开发包加入功能不等于公开版本已更新。实际下载、安装及性能验收分别记录在 [验证手册](VERIFY.md)，未经发布授权仍不推送或创建 Release。

更新版本与构建号、完成测试、核对差异并提交，再显式执行：

```bash
./publish.sh vN.M.P
```

此命令会创建并推送 tag，之后创建公开 GitHub Release 和上传资产。要求干净工作区、尚未使用的本地 tag，以及已登录的 gh 或 GH_TOKEN/GITHUB_TOKEN。仅暂存不算干净。推送失败立即停止；HTTP 失败非零退出，不再打印成功。

**约定（2026-09-22，2026-09-30 修订）**：GitHub Release 正文不铺陈更新记录——只保留指路句并链到仓库内的 `CHANGELOG.md`，README 不设 changelog 章节。对使用者有影响的变更（行为变更、新功能、已知问题）写在仓库根目录的 `CHANGELOG.md`；完整提交历史仍以 git log 为准（本地可见）。不要在 GitHub Release 页面追加「本次更新内容」清单。

若已推送 tag 而 Release 上传失败，保留产物和 tag，在 GitHub/gh 中检查并补传，勿直接删除公开标签。后续应给发布过程增加独立、可恢复的上传阶段。

## 清理与维护

- `Sources/`、`Tests/` 是标准 SwiftPM 工程结构，不再额外套一层“源码”目录。
- `Resources/` 为运行资源；`branding/` 保留图标源稿，`build/` 是可再生中间图。
- 过期计划、过程验证和构建缓存可按用户授权清理；当前说明集中在 docs 顶层，正式规格保留于 docs/design。
- `docs/verification/` 为本地过程证据，不纳入版本库；可在审阅后清理。
- `./build.sh clean` 清构建缓存与当前 app；失败会非零退出，不触碰 releases 或应用数据。
- 不把 credentials、真实 PDF、用户聊天或密钥复制进发布包。

每次发布以实际 GitHub tag、Release 资产和 `SHA256SUMS` 核验结果为准；本地构建成功不等于远端发布成功。

macOS 系统代理不会自动由所有命令行客户端继承。本轮 GitHub Release 创建和 API 查询成功，但 gh/curl 直连资产域名超时；按 `scutil --proxy` 的当前配置，仅对下载命令指定本机 HTTP 代理后，实际 ZIP、校验和及构建信息下载复核通过。遇到同类问题先核对当前代理，不固定端口、不关闭 TLS、不改全局 Git 配置。
