// End-to-end for 0013, in a phone-sized browser against the built image in demo mode: a new message
// sent from the list lands back on the list, not on the empty reading pane; a reply sent from an
// open message still lands on that message.
// Usage: node e2e-mobile-send.mjs <bulwark url>
import { chromium } from 'playwright-core';

const [BW] = process.argv.slice(2);
// On failure, name what is on screen instead: the reading pane's empty state is a heading.
const fail = async (page, msg) => {
  const headings = await page.locator('h1:visible, h2:visible, h3:visible').allInnerTexts().catch(() => []);
  console.error(`::error::${msg} (headings on screen: ${JSON.stringify(headings)})`);
  process.exit(1);
};

const browser = await chromium.launch();
const page = await (await browser.newContext({
  viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, locale: 'en-US',
})).newPage();

// The list's own controls: the mobile Compose button and the search button show only while the list
// is the screen; on the reading pane (or the composer) both are hidden.
const compose = page.getByRole('button', { name: 'Compose', exact: true });
const onList = async () => (await compose.isVisible()) && (await page.getByRole('button', { name: /^Search mail/ }).isVisible());

await page.goto(`${BW}/`);
await page.getByRole('button', { name: 'Launch Demo' }).click();
await page.waitForURL(/\/mail\/folder\/inbox/, { timeout: 60_000 });
await compose.waitFor({ timeout: 30_000 });
if (!(await onList())) await fail(page, 'the inbox list is not the screen after sign-in');

console.log('== a new message, sent from the list, lands on the list');
await compose.click();
await page.getByPlaceholder('Recipient email addresses').fill('someone@example.com');
await page.getByPlaceholder('Subject').fill('e2e mobile send');
await page.locator('[contenteditable=true]:visible').first().fill('hello');
await page.getByRole('button', { name: 'Send', exact: true }).click();
await page.getByText('Email sent successfully').waitFor({ timeout: 30_000 });
if (!(await compose.waitFor({ timeout: 10_000 }).then(onList, () => false))) await fail(page, 'after a send the list is not on screen (the empty reading pane is)');
console.log('on the list');

console.log('== a reply, sent from an open message, lands on that message');
const subject = 'Welcome to Bulwark Mail!';
const reply = page.getByRole('button', { name: 'Reply (r)', exact: true });
const backToList = page.getByRole('button', { name: 'Back to list', exact: true });
await page.getByText(subject, { exact: true }).first().click();
await reply.waitFor({ timeout: 30_000 });
await reply.click();
await page.locator('[contenteditable=true]:visible').first().fill('thanks');
await page.getByRole('button', { name: 'Send', exact: true }).click();
await reply.waitFor({ timeout: 30_000 });
if (await onList()) await fail(page, 'after a reply the list replaced the open message');
if (!(await backToList.isVisible()) || !(await page.getByText(subject, { exact: true }).filter({ visible: true }).first().isVisible())) {
  await fail(page, 'after a reply the message is no longer on screen');
}
console.log('on the message');

await browser.close();
console.log('e2e mobile send: OK');
