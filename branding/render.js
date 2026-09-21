// 用户确认的 PNG 母版 → macOS iconset → .icns；AI 小图标仍由 SVG 生成。
// 用法：NODE_PATH=... node branding/render.js
//
// 应用图标唯一源是 branding/lumen-icon-source.png。

const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const BRANDING = path.join(ROOT, 'branding');
const ICONSET = path.join(ROOT, 'build', 'icon.iconset');
const APP_ICON_SOURCE = path.join(BRANDING, 'lumen-icon-source.png');
const CROPPED_APP_ICON = path.join(ROOT, 'build', 'Lumen-icon-cropped.png');

const readSVG = (name) => fs.readFileSync(path.join(BRANDING, name), 'utf8');

// [输出文件名, 像素尺寸]
const appIconJobs = [];
for (const [name, px] of [
  ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32],
  ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256],
  ['icon_256x256.png', 256], ['icon_256x256@2x.png', 512],
  ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024],
]) {
  appIconJobs.push([`build/icon.iconset/${name}`, px]);
}
appIconJobs.push(['build/Lumen-icon-1024.png', 1024]);

// [输出文件名, 像素尺寸, SVG 源]
const svgJobs = [];
// AI 图标（透明底，单色墨）
svgJobs.push(['build/LumenAI-icon-512.png', 512, readSVG('lumen-ai-template.svg').replaceAll('currentColor', '#2F3540')]);
svgJobs.push(['build/LumenAI-icon-32.png', 32, readSVG('lumen-ai-template-compact.svg').replaceAll('currentColor', '#2F3540')]);

(async () => {
  fs.mkdirSync(path.join(ROOT, 'build', 'icon.iconset'), { recursive: true });
  if (!fs.existsSync(APP_ICON_SOURCE)) {
    throw new Error(`missing app icon source: ${APP_ICON_SOURCE}`);
  }
  // 原图有较宽的展示留白。先做居中裁切，让 Dock 与 16/32px 小尺寸仍能认出书页，
  // 不改变图形、颜色或相对位置。
  execFileSync('/usr/bin/sips', ['-c', '900', '900', APP_ICON_SOURCE, '--out', CROPPED_APP_ICON], {
    stdio: 'ignore',
  });
  for (const [rel, px] of appIconJobs) {
    const output = path.join(ROOT, rel);
    fs.mkdirSync(path.dirname(output), { recursive: true });
    execFileSync('/usr/bin/sips', ['-z', String(px), String(px), CROPPED_APP_ICON, '--out', output], {
      stdio: 'ignore',
    });
    console.log('✓', rel);
  }

  const browser = await puppeteer.launch({
    headless: true,
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'],
  });
  const page = await browser.newPage();

  for (const [rel, px, svg] of svgJobs) {
    const scaled = svg.replace('width="1024" height="1024"', `width="${px}" height="${px}"`);
    await page.setViewport({ width: px, height: px });
    await page.setContent(
      `<!DOCTYPE html><html><head><style>*{margin:0;padding:0}</style></head><body>${scaled}</body></html>`,
      { waitUntil: 'load' }
    );
    const transparent = rel.includes('AI-icon');
    await page.screenshot({
      path: path.join(ROOT, rel),
      omitBackground: transparent,
      clip: { x: 0, y: 0, width: px, height: px },
    });
    console.log('✓', rel);
  }

  await browser.close();
  execSync(`iconutil -c icns "${ICONSET}" -o "${path.join(ROOT, 'Resources', 'AppIcon.icns')}"`);
  console.log('✓ Resources/AppIcon.icns');
})();
