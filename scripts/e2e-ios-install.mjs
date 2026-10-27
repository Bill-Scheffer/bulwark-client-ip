// End-to-end for 0015, against the built image in demo mode: Safari on an iPhone gets the Install card with the Add to
// Home Screen steps, and Chrome on Android, which has its own install prompt, does not get those steps.
// Usage: node e2e-ios-install.mjs <bulwark url>   (screenshots go to /e2e/out when that directory exists)
import { existsSync } from 'node:fs';
import { chromium, devices, webkit } from 'playwright-core';

const [BW] = process.argv.slice(2);
const OUT = existsSync('/e2e/out') ? '/e2e/out' : null;
const fail = (msg) => {
  console.error(`::error::${msg}`);
  process.exit(1);
};

async function signedIn(browserType, device) {
  const browser = await browserType.launch();
  const page = await (await browser.newContext({ ...device, locale: 'en-US' })).newPage();
  await page.goto(`${BW}/`);
  await page.getByRole('button', { name: 'Launch Demo' }).click();
  await page.waitForURL(/\/mail\/folder\/inbox/, { timeout: 60_000 });
  return { browser, page };
}

console.log('== Safari on an iPhone: the Install card, with the steps');
{
  const { browser, page } = await signedIn(webkit, devices['iPhone 15']);
  const card = page.getByRole('dialog', { name: /^Install / });
  await card.waitFor({ timeout: 30_000 }).catch(() => fail('Safari on an iPhone got no Install card'));
  const steps = await card.locator('li').allInnerTexts();
  if (steps.length !== 3 || !/Share/.test(steps[0]) || !/Add to Home Screen/.test(steps[1]) || !/Add\.$/.test(steps[2])) {
    fail(`the card's steps are not the Add to Home Screen steps: ${JSON.stringify(steps)}`);
  }
  if (await card.getByRole('button', { name: 'Install', exact: true }).count()) fail('the iPhone card offers an Install button it cannot honour');
  if (OUT) await page.screenshot({ path: `${OUT}/ios-install-card-iphone.png` });
  await card.getByRole('button', { name: 'Not now' }).click();
  if (await card.isVisible()) fail('Not now did not close the card');
  await browser.close();
  console.log('the steps, and Not now closes them');
}

console.log('== Chrome on Android: not the iPhone steps');
{
  const { browser, page } = await signedIn(chromium, devices['Pixel 7']);
  await page.waitForTimeout(3_000);
  if (await page.getByText('Add to Home Screen', { exact: false }).count()) fail('Chrome on Android was shown the iPhone steps');
  await browser.close();
  console.log('no iPhone steps');
}

console.log('e2e ios install: OK');
