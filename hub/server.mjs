// The hub: one small always-on server for checking in on the game.
//   /            links and the current build
//   /play/       the last known-good build of the game (copied to .live/ by `npm run deploy:live`)
//   /status      the loop's progress file and the newest screenshots and renders
//   /questions   open questions for the owner to answer; answers are saved to .local/answers.json
// No dependencies. Binds to localhost only; put it behind a private reverse proxy to reach it remotely.
import http from 'node:http';
import { promises as fs, createReadStream } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const PORT = Number(process.env.HUB_PORT || 8066);
const LIVE = path.join(ROOT, '.live');
const ANSWERS = path.join(ROOT, '.local', 'answers.json');
const QUESTIONS = path.join(ROOT, 'loop', 'questions.json');
const PROGRESS = path.join(ROOT, 'loop', 'PROGRESS.md');
const GALLERIES = [
  ['Latest test screenshots', 'test-results/shots'],
  ['Character renders', 'assets_src/renders'],
];
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.glb': 'model/gltf-binary', '.gltf': 'model/gltf+json',
  '.bin': 'application/octet-stream', '.mp3': 'audio/mpeg', '.ogg': 'audio/ogg', '.wav': 'audio/wav', '.wasm': 'application/wasm',
  '.woff2': 'font/woff2', '.ico': 'image/x-icon', '.txt': 'text/plain; charset=utf-8', '.map': 'application/json',
};
const IMG = new Set(['.png', '.jpg', '.jpeg', '.webp']);

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function send(res, code, body, type = 'text/html; charset=utf-8', extra = {}) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...extra });
  res.end(body);
}

// Resolve rel inside base, or return null if it would escape.
function inside(base, rel) {
  const p = path.resolve(base, '.' + path.sep + rel);
  return p === base || p.startsWith(base + path.sep) ? p : null;
}

async function readJson(file, fallback) {
  try { return JSON.parse(await fs.readFile(file, 'utf8')); } catch { return fallback; }
}

async function serveFile(res, file) {
  try {
    const st = await fs.stat(file);
    if (!st.isFile()) return false;
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
      'Content-Length': st.size, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    });
    createReadStream(file).pipe(res);
    return true;
  } catch { return false; }
}

async function listImages(relDir, depth = 3) {
  const out = [];
  async function walk(rel, d) {
    let entries;
    try { entries = await fs.readdir(path.join(ROOT, rel), { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const r = rel + '/' + e.name;
      if (e.isDirectory() && d > 0) await walk(r, d - 1);
      else if (e.isFile() && IMG.has(path.extname(e.name).toLowerCase())) {
        const st = await fs.stat(path.join(ROOT, r));
        out.push({ rel: r, mtime: st.mtimeMs });
      }
    }
  }
  await walk(relDir, depth);
  return out.sort((a, b) => b.mtime - a.mtime).slice(0, 24);
}

const page = (title, body, refresh = '') => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">${refresh}<title>${esc(title)}</title>
<link rel="stylesheet" href="/hub.css"></head><body><main>
<nav><a href="/">Hub</a><a href="/play/">Play</a><a href="/status">Status</a><a href="/questions">Questions</a></nav>
${body}</main></body></html>`;

async function home() {
  const v = await readJson(path.join(LIVE, 'version.json'), null);
  const qs = await readJson(QUESTIONS, { questions: [] });
  const ans = await readJson(ANSWERS, {});
  const open = qs.questions.filter((q) => !ans[q.id]).length;
  const build = v
    ? `<p>Live build: <strong>${esc(v.commit || 'unknown')}</strong>, deployed ${esc(v.deployedAt || '')}.<br>${esc(v.note || '')}</p>`
    : '<p>No build has been deployed yet. The first one appears here after the loop finishes project setup.</p>';
  return page('Going Down hub', `<h1>Going Down</h1>${build}
<div class="tiles">
<a class="tile" href="/play/"><strong>Play</strong><span>The last known-good build. Add <code>?bots=3</code> to fill the crew with bots.</span></a>
<a class="tile" href="/status"><strong>Status</strong><span>What the loop is doing, what is verified, newest screenshots.</span></a>
<a class="tile" href="/questions"><strong>Questions</strong><span>${open} waiting for you. The loop carries on with defaults until you answer.</span></a>
</div>`);
}

async function status() {
  let md = '';
  try { md = await fs.readFile(PROGRESS, 'utf8'); } catch { md = 'No progress file yet.'; }
  let galleries = '';
  for (const [title, dir] of GALLERIES) {
    const imgs = await listImages(dir);
    if (!imgs.length) continue;
    galleries += `<h2>${esc(title)}</h2><div class="grid">` + imgs.map((i) =>
      `<a href="/files/${esc(i.rel)}"><img loading="lazy" src="/files/${esc(i.rel)}" alt=""><span>${esc(i.rel.split('/').slice(-2).join('/'))}</span></a>`).join('') + '</div>';
  }
  return page('Status', `<h1>Status</h1><p class="dim">Refreshes every minute.</p><pre>${esc(md)}</pre>${galleries}`,
    '<meta http-equiv="refresh" content="60">');
}

function readBody(req, limit = 20000) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function saveAnswer(req, res) {
  let body;
  try { body = JSON.parse(await readBody(req)); } catch { return send(res, 400, '{"error":"bad json"}', MIME['.json']); }
  const qs = await readJson(QUESTIONS, { questions: [] });
  const q = qs.questions.find((x) => x.id === body.id);
  if (!q) return send(res, 404, '{"error":"unknown question"}', MIME['.json']);
  const allowed = new Set((q.options || []).map((o) => o.id));
  const choices = Array.isArray(body.choices) ? body.choices.filter((c) => allowed.has(c)) : [];
  const text = typeof body.text === 'string' ? body.text.slice(0, 4000) : '';
  const answers = await readJson(ANSWERS, {});
  answers[q.id] = { choices: q.type === 'single' ? choices.slice(0, 1) : choices, text, at: new Date().toISOString() };
  await fs.mkdir(path.dirname(ANSWERS), { recursive: true });
  const tmp = ANSWERS + '.tmp';
  await fs.writeFile(tmp, JSON.stringify(answers, null, 2));
  await fs.rename(tmp, ANSWERS);
  send(res, 200, JSON.stringify({ ok: true, answer: answers[q.id] }), MIME['.json']);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    let p;
    try { p = decodeURIComponent(url.pathname); } catch { return send(res, 400, 'Bad request', 'text/plain'); }

    if (req.method === 'POST' && p === '/api/answers') return saveAnswer(req, res);
    if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed', 'text/plain');

    if (p === '/') return send(res, 200, await home());
    if (p === '/status') return send(res, 200, await status());
    if (p === '/hub.css') return (await serveFile(res, path.join(HERE, 'hub.css'))) || send(res, 404, '', 'text/plain');
    if (p === '/questions') return (await serveFile(res, path.join(HERE, 'questions.html'))) || send(res, 404, '', 'text/plain');
    if (p === '/api/questions') {
      const qs = await readJson(QUESTIONS, { questions: [] });
      return send(res, 200, JSON.stringify({ questions: qs.questions, answers: await readJson(ANSWERS, {}) }), MIME['.json']);
    }
    if (p.startsWith('/files/')) {
      const rel = p.slice('/files/'.length);
      const ok = GALLERIES.some(([, dir]) => rel.startsWith(dir + '/')) && IMG.has(path.extname(rel).toLowerCase());
      const file = ok ? inside(ROOT, rel) : null;
      return (file && (await serveFile(res, file))) || send(res, 404, 'Not found', 'text/plain');
    }
    if (p === '/play') return send(res, 302, '', 'text/plain', { Location: '/play/' });
    if (p.startsWith('/play/')) {
      let rel = p.slice('/play/'.length) || 'index.html';
      if (rel.endsWith('/')) rel += 'index.html';
      const file = inside(LIVE, rel);
      if (file && (await serveFile(res, file))) return;
      if (rel === 'index.html') return send(res, 200, page('No build yet', '<h1>No build yet</h1><p>The loop has not deployed a playable build. Check <a href="/status">Status</a>.</p>'));
      return send(res, 404, 'Not found', 'text/plain');
    }
    send(res, 404, 'Not found', 'text/plain');
  } catch (err) {
    send(res, 500, 'Server error', 'text/plain');
    console.error(err);
  }
});

server.listen(PORT, '127.0.0.1', () => console.log(`hub listening on http://127.0.0.1:${PORT}`));
