import { defineConfig } from '@playwright/test';

// The real game, driven by a real browser. Screenshots land in test-results/shots/ so they can be
// opened and looked at. The flags ask Chromium to use the graphics card when the machine has one,
// and let Web Audio run without a click so the tests can read the trolley squeak's levels.
// GD_PORT lets a second working copy run its browser tests at the same time as the first.
const PORT = Number(process.env.GD_PORT ?? 4317);

// CI machines draw in software at a few frames a second. Tests that walk, wait or measure in real
// time are unreliable there (they failed twice on runs where nothing they cover had changed), so CI
// runs only the tests that prove the game boots and draws on a clean Linux machine. Everything else
// runs on the development PC before every push. The game's rules are proven by the unit tests,
// which CI does run in full.
const CI_SAFE = ['smoke.spec.ts', 'tape-fallback.spec.ts'];

export default defineConfig({
  testDir: 'tests/e2e',
  ...(process.env.CI ? { testMatch: CI_SAFE } : {}),
  outputDir: 'test-results/pw',
  timeout: 60_000,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    viewport: { width: 1280, height: 720 },
    launchOptions: {
      args: ['--use-angle=default', '--enable-gpu', '--ignore-gpu-blocklist', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'],
    },
  },
  webServer: {
    command: `npm run build && npx vite preview --host 127.0.0.1 --port ${PORT} --strictPort`,
    url: `http://127.0.0.1:${PORT}`,
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
