# 规则：品牌资产与图标管线

适用路径：`branding/`、`Resources/AppIcon.icns`

## 管线（唯一正道）

```
branding/lumen-icon-source.png（应用图标唯一源）
  → branding/render.js（sips 缩放；AI 小图标继续由 Chrome 渲染 SVG）
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
应用图标采用用户确认的「橙色太阳 + 深蓝书页」母版；AI 语义仍用「细环 + 缺口实心点」。
