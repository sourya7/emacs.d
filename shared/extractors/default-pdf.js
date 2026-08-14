const { chromium  } = require('playwright-chromium');
const fs = require('fs');

const args = process.argv.slice(2);

(async () => {
  const { exec  } = require('child_process');
  exec(
    process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH + ' --version',
    function callback(error, stdout, stderr) {}
  );
})();

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
  });
  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:109.0) Gecko/20100101 Firefox/109.0',
    viewPort: { width: 2560, height: 1600 },
  });
  const page = await context.newPage();
  await page.goto(args[0]);

  await page.pdf({path: '/workspace/page.pdf', format: 'A4'});
  await browser.close();
})();
