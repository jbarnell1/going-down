import { execSync } from 'node:child_process';
import { defineConfig } from 'vite';

function commit(): string {
  try {
    return execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim();
  } catch {
    return 'dev';
  }
}

export default defineConfig({
  // Relative paths: the hub serves the build under /play/.
  base: './',
  define: {
    __BUILD__: JSON.stringify(commit()),
  },
  build: {
    target: 'es2022',
    sourcemap: true,
    // three.js alone is about 500 kB; the default warning is noise here.
    chunkSizeWarningLimit: 1500,
  },
  test: {
    include: ['tests/sim/**/*.test.ts', 'tests/net/**/*.test.ts'],
    environment: 'node',
    // The property tests simulate hundreds of runs each. They take a few seconds here and several
    // times that on a shared CI machine, where the default 5 s limit failed one of them.
    testTimeout: 180_000,
  },
});
