// Records film.html to PNG frames: node record.js <chrome executable> <frames dir> [fps] [from] [to]
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const [, , exe, dir, fps = 30, from = 0, to = 45] = process.argv;
(async () => {
  const copy = fs.readFileSync(path.join(__dirname, 'out/copy.txt'), 'utf8').trim()
    .replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const html = fs.readFileSync(path.join(__dirname, 'film.html'), 'utf8').replace('%COPY%', JSON.stringify(copy));
  fs.writeFileSync(path.join(__dirname, 'out/film.html'), html.replaceAll('out/', ''));
  fs.mkdirSync(dir, { recursive: true });
  const browser = await chromium.launch({ executablePath: exe });
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  await page.goto('file://' + path.join(__dirname, 'out/film.html'));
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(500);
  for (let i = Math.round(from * fps); i < Math.round(to * fps); i++) {
    await page.evaluate(t => render(t), i / fps);
    await page.screenshot({ path: path.join(dir, String(i).padStart(5, '0') + '.png') });
  }
  await browser.close();
})();
