# 规则：品牌资产与图标管线

适用路径：`branding/`、`Resources/AppIcon.icns`

## 管线（唯一正道）

```
branding/*.svg（唯一源）
  → branding/render.js（puppeteer-core + 系统 Chrome headless 光栅化）
  → build/*.png（1024/512/…/32 各尺寸 + 深色版 + ≤64px 紧凑版）
  → iconutil -c icns build/icon.iconset -o Resources/AppIcon.icns
  → ./build.sh 重新组装 app
```

**不要**手绘 NSBezierPath 生成图标（那是 v2 的弯路：路径控制点方向写反、
NSGradient 是线性渐变导致光晕变硬边圆盘，全靠截图迭代）。

## 环境事实

- 本机无 rsvg-convert / magick / inkscape；光栅化用 `puppeteer-core` +
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`（`headless: 'shell'`）。
  puppeteer 官方缓存目录是空的，别等它自己下载浏览器。
- 运行前 `export NODE_PATH=/Users/jn/.workbuddy/binaries/node/workspace/node_modules`。

## 设计约束（v3 定稿）

细线条 / 极简几何 / 单色 / 无渐变 / 大留白；浅色（纸底墨线）与深色（墨底纸线）双版；
≤64px 用紧凑版（加粗线条）保辨识度；AI 语义用「细环 + 缺口实心点」，禁用机器人/大脑/sparkle。
