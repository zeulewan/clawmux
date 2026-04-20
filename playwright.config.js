import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 60000,
  retries: 0,
  use: {
    baseURL: 'http://100.101.214.44:3470',
    viewport: { width: 1440, height: 900 },
    screenshot: 'on',
    video: 'on',
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'desktop',
      use: { viewport: { width: 1440, height: 900 } },
      testIgnore: /mobile\.spec/,
    },
    {
      name: 'mobile',
      use: { viewport: { width: 375, height: 812 } },
      testMatch: /mobile\.spec/,
    },
  ],
  reporter: [['list'], ['html', { open: 'never' }]],
  outputDir: './test-results',
});
