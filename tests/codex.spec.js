// @ts-check
import { test, expect } from '@playwright/test';

test('codex agent renders response in chat', async ({ page }) => {
  await page.goto('/');
  await page.waitForSelector('.sidebar-convo');
  await page.waitForTimeout(3000);

  // Switch to Alice (codex agent)
  const aliceRow = page.locator('.sidebar-convo', { hasText: 'Alice' });
  await aliceRow.click();
  await page.waitForTimeout(2000);

  // Confirm Alice's sidebar badge says codex
  await expect(aliceRow.locator('.agent-backend-badge')).toContainText(/codex/i);

  // Count existing assistant messages before sending
  const msgsBefore = await page.locator('[data-testid="assistant-message"]').count();

  // Send a message whose expected response word doesn't appear in the prompt
  const input = page.locator('[contenteditable]');
  await input.click();
  await input.type('Reply with exactly the single word: ZORK');
  await page.keyboard.press('Enter');

  await page.screenshot({ path: 'test-results/codex-01-sent.png' });

  // Wait for a new assistant message to appear
  await expect(page.locator('[data-testid="assistant-message"]')).toHaveCount(msgsBefore + 1, { timeout: 30000 });

  // Verify the last assistant message contains ZORK
  await expect(page.locator('[data-testid="assistant-message"]').last()).toContainText('ZORK', { timeout: 5000 });

  await page.screenshot({ path: 'test-results/codex-02-response.png' });
});
