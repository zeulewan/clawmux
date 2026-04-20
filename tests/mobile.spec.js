// @ts-check
import { test, expect } from '@playwright/test';

test('page loads on mobile', async ({ page }) => {
  await page.goto('/');
  await page.waitForTimeout(3000);
  await expect(page.locator('#root')).toBeVisible();
  await expect(page.locator('[contenteditable]')).toBeVisible();
  await page.screenshot({ path: 'test-results/mobile-load.png' });
});

test('no horizontal overflow', async ({ page, viewport }) => {
  await page.goto('/');
  await page.waitForTimeout(3000);
  const bodyWidth = await page.evaluate(() => document.body.scrollWidth);
  expect(bodyWidth).toBeLessThanOrEqual(viewport.width + 5);
});

test('can type on mobile', async ({ page }) => {
  await page.goto('/');
  await page.waitForTimeout(3000);
  const input = page.locator('[contenteditable]');
  await input.click();
  await input.type('hello mobile');
  await expect(input).toContainText('hello mobile');
  await input.evaluate((el) => el.blur());
});

test('mobile sidebar can open and close', async ({ page }) => {
  await page.goto('/');
  await page.waitForTimeout(3000);

  await page.getByTitle('Expand sidebar').click();
  await expect(page.getByText('Agents')).toBeVisible();

  await page.mouse.click(360, 24);
  await expect(page.getByTitle('Expand sidebar')).toBeVisible();
});

test('mobile can attach a file from the composer', async ({ page }) => {
  await page.goto('/');
  await page.waitForTimeout(3000);

  const addButton = page.getByTitle('Add');
  await addButton.click();
  await page.locator('input[type="file"]').setInputFiles({
    name: 'mobile-note.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('hello from mobile'),
  });

  await expect(page.getByText('mobile-note.txt')).toBeVisible();
  await addButton.click();
  await page.evaluate(() => document.activeElement?.blur?.());
  await page.goto('about:blank');
});

test('mobile document sets theme color meta', async ({ page }) => {
  await page.goto('/');
  await page.waitForTimeout(3000);

  const themeColor = await page.locator('meta[name="theme-color"]').getAttribute('content');
  expect(themeColor).toBeTruthy();
});
