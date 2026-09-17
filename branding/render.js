// SVG → PNG 尺寸集 → .icns
// 用法：NODE_PATH=... node branding/render.js
//
// SVG 是图标的唯一源文件；这里只做两件事：
// 用无头 Chrome 按 Apple iconset 需要的像素尺寸渲染，
// 大尺寸走母版、小尺寸走紧凑版（小尺寸专用加粗线稿），
// 最后交给 iconutil 合成。

const puppeteer = require('puppeteer-core');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const BRANDING = path.join(ROOT, 'branding');
const ICONSET = path.join(ROOT, 'build', 'icon.iconset');

const readSVG = (name) => fs.readFileSync(path.join(BRANDING, name), 'utf8');

// [输出文件名, 像素尺寸, SVG 源]
const jobs = [];
for (const [name, px] of [
  ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32],
  ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256],
  ['icon_256x256.png', 256], ['icon_256x256@2x.png', 512],
  ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024],
]) {
  const src = px <= 64 ? readSVG('lumen-icon-light-compact.svg') : readSVG('lumen-icon-light.svg');
  jobs.push([`build/icon.iconset/${name}`, px, src]);
}
// 交付物预览
jobs.push(['build/Lumen-icon-1024.png', 1024, readSVG('lumen-icon-light.svg')]);
jobs.push(['build/Lumen-icon-dark-1024.png', 1024, readSVG('lumen-icon-dark.svg')]);
jobs.push(['build/Lumen-icon-compact-64.png', 64, readSVG('lumen-icon-light-compact.svg')]);
// AI 图标（透明底，单色墨）
jobs.push(['build/LumenAI-icon-512.png', 512, readSVG('lumen-ai-template.svg').replaceAll('currentColor', '#2F3540')]);
jobs.push(['build/LumenAI-icon-32.png', 32, readSVG('lumen-ai-template-compact.svg').replaceAll('currentColor', '#2F3540')]);

(async () => {
  fs.mkdirSync(path.join(ROOT, 'build', 'icon.iconset'), { recursive: true });
  const browser = await puppeteer.launch({
    headless: true,
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'],
  });
  const page = await browser.newPage();

  for (const [rel, px, svg] of jobs) {
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
