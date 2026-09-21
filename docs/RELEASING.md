# 构建、发布与目录维护

## 本地构建与打包

```bash
swift test --disable-sandbox
./build.sh release
./publish.sh v1.1.0 --no-upload
# 需要安装镜像时：./publish.sh v1.1.0 --no-upload --dmg
```

版本号必须为 `vN.M.P`，且等于 `Resources/Info.plist` 的 `CFBundleShortVersionString`。普通构建写到 `dist/Lumen.app`；本地打包写到 `releases/vN.M.P/`。`--no-upload` 不创建标签、不推送、不建立 GitHub Release，允许包含未提交改动以供审阅，`build-info.txt` 会标记 dirty。

发布目录包含 ZIP、可选 DMG、SHA256SUMS、build-info.txt 与 build-stamp.txt。同版本重复本地打包会替换该目录中的同名包；正式发布版应保留，下一次发布递增版本。ZIP 内顶层为 Lumen.app。当前只构建本机架构，不能宣传为 Universal。

```bash
cd releases/v1.1.0
shasum -a 256 -c SHA256SUMS
codesign --verify --strict --deep ../../dist/Lumen.app
```

签名优先 Lumen Dev，缺失则 ad-hoc；均不等于 Apple Developer ID 公证。重编译会改变 CDHash。API 密钥现在与签名身份无关。

## 对外发布

更新版本与构建号、完成测试、核对差异并提交，再显式执行：

```bash
./publish.sh vN.M.P
```

此命令会创建并推送 tag，之后创建公开 GitHub Release 和上传资产。要求干净工作区、尚未使用的本地 tag，以及已登录的 gh 或 GH_TOKEN/GITHUB_TOKEN。仅暂存不算干净。推送失败立即停止；HTTP 失败非零退出，不再打印成功。

**约定（2026-09-22）**：GitHub 上不写更新记录——Release 说明只保留脚本里那句指路文字，README 不设 changelog 章节。变更历史以 git log 为准（本地可见），不要在对外页面追加「本次更新内容」。

若已推送 tag 而 Release 上传失败，保留产物和 tag，在 GitHub/gh 中检查并补传，勿直接删除公开标签。后续应给发布过程增加独立、可恢复的上传阶段。

## 清理与维护

- `Sources/`、`Tests/` 是标准 SwiftPM 工程结构，不再额外套一层“源码”目录。
- `Resources/` 为运行资源；`branding/` 保留图标源稿，`build/` 是可再生中间图。
- 历史计划、研究、验证移到 `docs/archive/`；当前说明集中在 docs 顶层。
- `docs/verification/` 为本地过程证据，不纳入版本库；可在审阅后清理。
- `./build.sh clean` 清构建缓存与当前 app；失败会非零退出，不触碰 releases 或应用数据。
- 不把 credentials、真实 PDF、用户聊天或密钥复制进发布包。

本次审计只进行本地修改和本地打包，未推送源码、tag 或创建新 GitHub Release。
