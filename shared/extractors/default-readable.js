const { chromium } = require('playwright-chromium');
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);

(async () => {
    const { exec } = require('child_process');
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
        bypassCSP: true
    });
    const page = await context.newPage();
    await page.goto(args[0]);

    const readabilityPath = path.join('/usr/src/app/scripts', 'readability.min.js');
    const readabilityScript = fs.readFileSync(readabilityPath, 'utf8');

    // Inject the script content directly
    await page.addScriptTag({ content: readabilityScript });

    const content = await page.evaluate(() => {
        return new Readability(document).parse();
    });

    fs.writeFileSync('/workspace/page.json', JSON.stringify(content));
    await browser.close();
})();
