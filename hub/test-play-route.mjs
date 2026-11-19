import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

test('Play follows the promoted browser build and preserves playtest options', { timeout: 20000 }, async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'going-down-hub-'));
  await fs.mkdir(path.join(root, 'hub'));
  const entry = path.join(root, 'hub', 'server.mjs');
  await fs.copyFile(fileURLToPath(new URL('./server.mjs', import.meta.url)), entry);
  const child = spawn(process.execPath, [entry], {
    env: { ...process.env, HUB_PORT: '0' }, stdio: ['ignore', 'pipe', 'inherit'], windowsHide: true,
  });
  const exited = once(child, 'exit');
  t.after(async () => {
    child.kill();
    await exited;
    await fs.rm(root, { recursive: true, force: true });
  });
  const lines = createInterface({ input: child.stdout });
  const [startup] = await once(lines, 'line');
  lines.close();
  const base = startup.match(/http:\/\/127\.0\.0\.1:\d+$/)[0];
  const get = (route) => fetch(base + route);
  assert.match(await (await get('/play/')).text(), /No build yet/);

  const legacy = path.join(root, '.live');
  await fs.mkdir(legacy);
  await fs.writeFile(path.join(legacy, 'index.html'), 'prototype entry');
  await fs.writeFile(path.join(legacy, 'version.json'), JSON.stringify({ commit: 'prototype-1' }));
  assert.equal(await (await get('/play/')).text(), 'prototype entry');
  assert.match(await (await get('/')).text(), /prototype-1/);

  const checked = path.join(root, 'play', 'web');
  await fs.mkdir(checked, { recursive: true });
  await fs.writeFile(path.join(checked, 'index.html'), 'promoted game entry');
  assert.equal(await (await get('/play/')).text(), 'prototype entry', 'a partial promotion has no published build yet');
  await fs.writeFile(path.join(root, 'play', 'build.json'), JSON.stringify({
    commit: 'promoted-2', promotedAt: '2026-11-19T10:00:00Z', note: 'Checked client',
  }));
  assert.equal(await (await get('/play/')).text(), 'prototype entry', 'the browser engine and game pack are still missing');
  for (const file of ['index.js', 'index.wasm', 'index.pck']) await fs.writeFile(path.join(checked, file), 'fixture');
  for (const route of ['/play', '/play/', '/play/index.html']) {
    const game = await get(route + '?bots=3&debug=1');
    assert.equal(await game.text(), 'promoted game entry', route);
    assert.equal(new URL(game.url).search, '?bots=3&debug=1');
    assert.equal(new URL(game.url).pathname, '/godot/');
  }
  assert.match(await (await get('/')).text(), /promoted-2/);
  assert.equal((await (await get('/api/status')).json()).godotBuild.commit, 'promoted-2');
  assert.equal(await (await get('/godot/')).text(), 'promoted game entry');
  const manifest = path.join(root, 'play', 'build.json');
  const valid = await fs.readFile(manifest);
  await fs.writeFile(manifest, '{}');
  assert.equal(await (await get('/play/')).text(), 'prototype entry', 'missing commit cannot identify a release');
  await fs.writeFile(manifest, valid);
  await fs.rename(path.join(checked, 'index.html'), path.join(checked, 'index.held'));
  assert.equal(await (await get('/play/')).text(), 'prototype entry');
  assert.match(await (await get('/')).text(), /prototype-1/);
});
