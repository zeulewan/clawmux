// @ts-check
import { test, expect } from '@playwright/test';

// ── Page Load ──

test('page loads with sidebar and input', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('#root')).toBeVisible();
  await expect(page.locator('.sidebar-expanded')).toBeVisible();
  await expect(page.locator('[contenteditable]')).toBeVisible();
  await page.screenshot({ path: 'test-results/01-page-load.png' });
});

test('all 27 agents render in sidebar', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.sidebar-convo');
  const agents = page.locator('.sidebar-convo');
  await expect(agents).toHaveCount(27);
  // First is Adam, last is Sky (alphabetical)
  await expect(agents.first().locator('.convo-title')).toHaveText('Adam');
  await expect(agents.last().locator('.convo-title')).toHaveText('Sky');
});

test('every agent has a backend badge', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.sidebar-convo');
  const badges = page.locator('.agent-backend-badge');
  await expect(badges).toHaveCount(27);
  // No badge should say "default"
  const texts = await badges.allTextContents();
  for (const t of texts) {
    expect(t.toLowerCase()).not.toBe('default');
    expect(t.trim()).not.toBe('');
  }
});

test('top bar shows agent name, backend, and model', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.header-stats');
  const stats = page.locator('.header-stats');
  const text = await stats.textContent();
  // Should contain agent name and backend
  expect(text).toContain('adam');
  expect(text).toContain('claude');
});

// ── Send Message ──

test('can type and send via Enter key', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('[contenteditable]');
  await page.waitForTimeout(3000);
  const input = page.locator('[contenteditable]');
  await input.click();
  await input.type('say pineapple and nothing else');
  await page.keyboard.press('Enter');
  // Input should clear
  await expect(input).toHaveText('');
  // User message should appear
  await expect(page.locator('.messagesContainer_07S1Yg')).toContainText('say pineapple');
  await page.screenshot({ path: 'test-results/02-message-sent.png' });
});

test('can type and send via send button', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('[contenteditable]');
  await page.waitForTimeout(3000);
  const input = page.locator('[contenteditable]');
  await input.click();
  await input.type('say mango');
  await page.locator('.sendButton_gGYT1w').click();
  await expect(page.locator('.messagesContainer_07S1Yg')).toContainText('say mango');
});

test('message appears in chat after send', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('[contenteditable]');
  await page.waitForTimeout(3000);
  const input = page.locator('[contenteditable]');
  await input.click();
  await input.type('say grape');
  await page.keyboard.press('Enter');
  // User message should appear in chat
  await expect(page.locator('.messagesContainer_07S1Yg')).toContainText('say grape');
  await page.screenshot({ path: 'test-results/03-message-in-chat.png' });
});

// ── Agent Switching ──

test('clicking agent switches focus', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.sidebar-convo');
  await page.waitForTimeout(3000);
  // Click Echo
  await page.locator('.sidebar-convo', { hasText: 'Echo' }).click();
  await page.waitForTimeout(2000);
  // Top bar should show echo
  await expect(page.locator('.header-stats')).toContainText('echo');
  // Adam should no longer be highlighted
  const adam = page.locator('.sidebar-convo', { hasText: 'Adam' });
  await expect(adam).not.toHaveClass(/active/);
  const echo = page.locator('.sidebar-convo', { hasText: 'Echo' });
  await expect(echo).toHaveClass(/active/);
});

test('rapid agent switching does not crash', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.sidebar-convo');
  await page.waitForTimeout(3000);
  const agents = page.locator('.sidebar-convo');
  // Click 6 agents rapidly
  for (let i = 0; i < 6; i++) {
    await agents.nth(i).click();
    await page.waitForTimeout(200);
  }
  await page.waitForTimeout(2000);
  // UI should still work
  await expect(page.locator('[contenteditable]')).toBeVisible();
  await expect(page.locator('.sidebar-expanded')).toBeVisible();
  await page.screenshot({ path: 'test-results/04-rapid-switch.png' });
});

// ── Backend Switching ──

test('backend dropdown opens and shows options', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.sidebar-convo');
  await page.waitForTimeout(3000);
  // Click Adam's badge
  await page.locator('.sidebar-convo', { hasText: 'Adam' }).locator('.agent-backend-badge').click();
  await page.waitForTimeout(500);
  // Dropdown should be visible with options
  const dropdown = page.locator('.backend-picker-dropdown');
  await expect(dropdown).toBeVisible();
  const options = dropdown.locator('.backend-picker-option');
  const count = await options.count();
  expect(count).toBeGreaterThanOrEqual(2);
  await page.screenshot({ path: 'test-results/05-backend-dropdown.png' });
});

// ── Visual Regression ──

test('initial page matches screenshot', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.sidebar-convo');
  await page.waitForTimeout(3000);
  await expect(page).toHaveScreenshot('page-load.png', {
    maxDiffPixelRatio: 0.05,
  });
});
