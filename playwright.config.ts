import { defineConfig } from '@playwright/test';

// The real game, driven by a real browser. Screenshots land in test-results/shots/ so they can be
// opened and looked at. The flags ask Chromium to use the graphics card when the machine has one.
// GD_PORT lets a second working copy run its browser tests at the same time as the first.
const PORT = Number(process.env.GD_PORT ?? 4317);

export default defineConfig({
  testDir: 'tests/e2e',
  outputDir: 'test-results/pw',
  timeout: 60_000,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    viewport: { width: 1280, height: 720 },
    launchOptions: {
      args: ['--use-angle=default', '--enable-gpu', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader'],
    },
  },
  webServer: {
    command: `npm run build && npx vite preview --host 127.0.0.1 --port ${PORT} --strictPort`,
    url: `http://127.0.0.1:${PORT}`,
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
