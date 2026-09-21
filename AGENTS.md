# LumenReader 维护约束

先读 README.md；当前实现见 docs/ARCHITECTURE.md，验证见 docs/VERIFY.md，发布见 docs/RELEASING.md。docs/archive 是历史证据，不是当前行为契约。

- 保留 Sources/、Tests/、Resources/ 的 SwiftPM 标准结构，分发产物统一 releases/<version>/。
- LumenKit 不引 SwiftUI。PDFKit/WebKit 视图和共享文档的所有权仍在 App 层。
- API 密钥使用本机 credentials 文件（0700/0600，未加密）；不得进入日志、版本库、截图或配置导出，仅向用户配置的 AI 接口用于授权。
- PDF 批注写原文件，EPUB 批注保存应用数据目录；验证使用合成素材或副本。
- JSON 缺字段与坏字段分开处理，内容损坏须保留原件。编码与解码日期策略成对。
- 异步操作取消后禁止回写后继操作；日志动态文本必须作为 NSLog("%@", text) 参数。
- 测试使用 swift test --disable-sandbox；修改应用行为时使用隔离目录和真实截图进行必要验证。
- 主题、布局与动效复用已有 DesignTokens/ReadingTheme/MotionGate。不要把 iOS 触控尺寸标准直接套给 macOS。
- --no-upload 必须无远端副作用。未经发布请求不推送、不发布；普通本地打包无需另行确认。
- 不删原始资料、规格和正式成果。明确可再生缓存可清理，不确定价值的旧材料归档。
