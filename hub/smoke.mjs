// Starts the hub on a spare port and checks that its pages answer and that it refuses to serve
// anything outside the folders it is meant to. Run by `npm run check`.
import { spawn } from 'node:child_process';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = 8068;
const child = spawn(process.execPath, [path.join(HERE, 'server.mjs')], { env: { ...process.env, HUB_PORT: String(PORT) }, stdio: 'ignore' });

// Raw request: fetch() would tidy "../" out of the path before sending it.
const get = (p, method = 'GET', body) => new Promise((resolve, reject) => {
  const req = http.request({ host: '127.0.0.1', port: PORT, path: p, method, headers: body ? { 'Content-Type': 'application/json' } : {} }, (res) => {
    let data = '';
    res.on('data', (c) => { data += c; });
    res.on('end', () => resolve({ status: res.statusCode, type: res.headers['content-type'] ?? '', body: data }));
  });
  req.on('error', reject);
  if (body) req.write(body);
  req.end();
});

const failures = [];
const expect = (name, ok, detail = '') => { if (!ok) failures.push(`${name} ${detail}`); };

try {
  for (let i = 0; i < 40; i++) {
    try { await get('/'); break; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  for (const p of ['/', '/status', '/questions', '/audition', '/hub.css', '/play/']) {
    const r = await get(p);
    expect(`GET ${p}`, r.status === 200, `-> ${r.status}`);
  }
  const status = await get('/api/status');
  const parsed = JSON.parse(status.body);
  expect('status api has tasks', Array.isArray(parsed.state?.tasks) && parsed.state.tasks.length > 0);
  expect('status api lists latest files', Array.isArray(parsed.latest));
  const qs = JSON.parse((await get('/api/questions')).body);
  expect('questions api has questions', Array.isArray(qs.questions) && qs.questions.length > 0);

  // Nothing outside the allowed folders, however the path is dressed up.
  for (const p of ['/files/../.local/MACHINE.md', '/files/public/assets/../../.local/answers.json', '/media/../MACHINE.md',
    '/media/..%2fMACHINE.md', '/play/../.local/MACHINE.md', '/play/..%2f.local%2fMACHINE.md', '/files/hub/server.mjs',
    '/files/public/assets/entities/orderly.exe', '/.git/config', '/package.json']) {
    const r = await get(p);
    expect(`blocked ${p}`, r.status === 404, `-> ${r.status}`);
  }
  // Answers: unknown questions and bad bodies are refused; nothing is written by this test.
  expect('unknown question refused', (await get('/api/answers', 'POST', JSON.stringify({ id: 'no-such-question' }))).status === 404);
  expect('bad json refused', (await get('/api/answers', 'POST', '{not json')).status === 400);
  expect('client log refuses bad json', (await get('/api/clientlog', 'POST', '{not json')).status === 400);
  expect('client log refuses a non-object', (await get('/api/clientlog', 'POST', '[1,2]')).status === 400);
  expect('other methods refused', (await get('/status', 'DELETE')).status === 405);
} catch (e) {
  failures.push(`hub smoke crashed: ${e.message}`);
} finally {
  child.kill();
}

if (failures.length) {
  console.error('hub smoke test FAILED:\n  ' + failures.join('\n  '));
  process.exit(1);
}
console.log('hub smoke test: all pages answer, all escapes blocked');
