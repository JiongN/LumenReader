# 规则：持久化编码/解码必须成对

适用路径：`Sources/LumenKit/Store/`（Settings、RecentDocuments、ReadingProgress、记忆等所有 JSON 持久化）

## 铁律

**编码策略与解码策略必须写在相邻两行、互相引用注释。** 改其一必改其二。

```swift
// 编码：iso8601 字符串
encoder.dateEncodingStrategy = .iso8601
// 解码：必须与上面的策略成对
decoder.dateDecodingStrategy = .iso8601
```

## 事故背景（2026-09-17）

`RecentDocuments` 编码用 `.iso8601`，解码时 `JSONDecoder()` 没设策略 → 默认按时间戳
读 Double，遇到 `"2026-09-17T…"` **整体解码失败** → `try?` 吞掉错误 → `entries` 静默归零。
后果：「最近打开」每次启动都被清空，且无任何日志。旧版首页从不显示记录的根因即此。

## 推导出的两条防御规则

1. `try?` + `?? []` 这种「失败即空集合」的持久化读取，**必须留注释说明失败时的用户可见后果**；
   能打日志就打日志。静默清空用户数据是最坏的失败模式。
2. 新增持久化字段时，先问：旧文件缺这个字段会怎样？需要自定义 `init(from:)` 给默认值的就写。
