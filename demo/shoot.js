// Renders the scene pages in demo/scenes to PNGs at 2x (what a Retina screen capture looks like),
// ready to run through Lingveil's pipeline with LINGVEIL_DEBUG_IMAGE.
// usage: node shoot.js <chrome executable>
const { chromium } = require('playwright');
const path = require('path');
const dir = __dirname;
const shots = [
  ['article', 1180, 760], ['article-tall', 1180, 1500, 'article'],
  ['chat', 1100, 700], ['product', 1100, 620],
  ['sub1', 1100, 620, 'video', '오늘은 바람이 정말 따뜻하네요.'],
  ['sub2', 1100, 620, 'video', '어릴 때 여기서 자주 놀았어요.'],
  ['sub3', 1100, 620, 'video', '해가 지기 전에 같이 내려가요.'],
];
(async () => {
  const browser = await chromium.launch({ executablePath: process.argv[2] });
  for (const [name, w, h, page = name, hash = ''] of shots) {
    const p = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 2 });
    await p.goto('file://' + path.join(dir, 'scenes', page + '.html') + (hash ? '#' + encodeURIComponent(hash) : ''));
    await p.waitForTimeout(200);
    await p.screenshot({ path: path.join(dir, 'out', name + '.png'), omitBackground: true });
    await p.close();
  }
  await browser.close();
})();
