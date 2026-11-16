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
const STATE = path.join(ROOT, 'loop', 'state.json');
const MEDIA = path.join(ROOT, '.local', 'media');
// Folders the Status page watches for new output, and what each holds.
const GALLERIES = [
  ['Game screenshot', 'test-results/shots'],
  ['Floor map', 'test-results/floors'],
  ['Character render', 'assets_src/renders'],
  ['Game asset', 'public/assets'],
  ['Voice take', 'assets_src/voice'],
];
const KIND = { '.png': 'image', '.jpg': 'image', '.jpeg': 'image', '.webp': 'image', '.txt': 'text', '.glb': 'model', '.mp3': 'audio', '.wav': 'audio' };
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.glb': 'model/gltf-binary', '.gltf': 'model/gltf+json',
  '.bin': 'application/octet-stream', '.mp3': 'audio/mpeg', '.ogg': 'audio/ogg', '.wav': 'audio/wav', '.wasm': 'application/wasm',
  '.woff2': 'font/woff2', '.ico': 'image/x-icon', '.txt': 'text/plain; charset=utf-8', '.map': 'application/json',
};

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

// Every watched output file, newest first: this is what makes new work show up without being announced.
async function latestFiles(limit = 40) {
  const out = [];
  async function walk(rel, d, label) {
    let entries;
    try { entries = await fs.readdir(path.join(ROOT, rel), { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const r = rel + '/' + e.name;
      if (e.isDirectory() && d > 0) await walk(r, d - 1, label);
      else if (e.isFile() && KIND[path.extname(e.name).toLowerCase()]) {
        const st = await fs.stat(path.join(ROOT, r));
        out.push({ url: '/files/' + r, name: r.split('/').slice(-2).join('/'), label, kind: KIND[path.extname(e.name).toLowerCase()], mtime: st.mtimeMs, size: st.size });
      }
    }
  }
  for (const [label, dir] of GALLERIES) await walk(dir, 3, label);
  return out.sort((a, b) => b.mtime - a.mtime).slice(0, limit);
}

async function apiStatus() {
  const qs = await readJson(QUESTIONS, { questions: [] });
  const ans = await readJson(ANSWERS, {});
  return {
    serverTime: Date.now(),
    state: await readJson(STATE, null),
    latest: await latestFiles(),
    live: await readJson(path.join(LIVE, 'version.json'), null),
    questionsOpen: qs.questions.filter((q) => !ans[q.id]).length,
  };
}

const page = (title, body, refresh = '') => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">${refresh}<title>${esc(title)}</title>
<link rel="stylesheet" href="/hub.css"></head><body><main>
<nav><a href="/">Hub</a><a href="/play/">Play</a><a href="/status">Progress</a><a href="/questions">Questions</a></nav>
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
<a class="tile" href="/status"><strong>Progress</strong><span>The roadmap, what is being built right now, and every new picture and asset as it lands.</span></a>
<a class="tile" href="/questions"><strong>Questions</strong><span>${open} waiting for you. The loop carries on with defaults until you answer.</span></a>
</div>`);
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

// What a player's device reports when the game's picture fails (see src/game/diagnostics.ts):
// the graphics chip, its limits and what the game was doing. Kept in .local, never committed.
async function clientLog(req, res) {
  let entry;
  try { entry = JSON.parse(await readBody(req, 8000)); } catch { return send(res, 400, '{"error":"bad json"}', MIME['.json']); }
  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) return send(res, 400, '{"error":"bad entry"}', MIME['.json']);
  const file = path.join(ROOT, '.local', 'client-log.jsonl');
  await fs.mkdir(path.dirname(file), { recursive: true });
  try { if ((await fs.stat(file)).size > 2_000_000) await fs.rename(file, file + '.old'); } catch { /* no log yet */ }
  await fs.appendFile(file, JSON.stringify({ received: new Date().toISOString(), ...entry }) + '\n');
  send(res, 200, '{"ok":true}', MIME['.json']);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    let p;
    try { p = decodeURIComponent(url.pathname); } catch { return send(res, 400, 'Bad request', 'text/plain'); }

    if (req.method === 'POST' && p === '/api/answers') return saveAnswer(req, res);
    if (req.method === 'POST' && p === '/api/clientlog') return clientLog(req, res);
    if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed', 'text/plain');

    if (p === '/') return send(res, 200, await home());
    if (p === '/status') return (await serveFile(res, path.join(HERE, 'status.html'))) || send(res, 404, '', 'text/plain');
    if (p === '/api/status') return send(res, 200, JSON.stringify(await apiStatus()), MIME['.json']);
    if (p === '/api/progress.md') return (await serveFile(res, PROGRESS)) || send(res, 404, '', 'text/plain');
    if (p.startsWith('/media/')) {
      const file = KIND[path.extname(p).toLowerCase()] ? inside(MEDIA, p.slice('/media/'.length)) : null;
      return (file && (await serveFile(res, file))) || send(res, 404, 'Not found', 'text/plain');
    }
    if (p === '/hub.css') return (await serveFile(res, path.join(HERE, 'hub.css'))) || send(res, 404, '', 'text/plain');
    if (p === '/questions') return (await serveFile(res, path.join(HERE, 'questions.html'))) || send(res, 404, '', 'text/plain');
    // The voice audition page: every take of every announcer line, for choosing by ear.
    if (p === '/audition') return (await serveFile(res, path.join(ROOT, 'assets_src', 'voice', 'audition.html'))) || send(res, 404, 'No audition page yet', 'text/plain');
    if (p === '/api/questions') {
      const qs = await readJson(QUESTIONS, { questions: [] });
      return send(res, 200, JSON.stringify({ questions: qs.questions, answers: await readJson(ANSWERS, {}) }), MIME['.json']);
    }
    if (p.startsWith('/files/')) {
      const rel = p.slice('/files/'.length);
      const ok = GALLERIES.some(([, dir]) => rel.startsWith(dir + '/')) && KIND[path.extname(rel).toLowerCase()];
      const file = ok ? inside(ROOT, rel) : null;
      return (file && (await serveFile(res, file))) || send(res, 404, 'Not found', 'text/plain');
    }
    if (p === '/play') return send(res, 302, '', 'text/plain', { Location: '/play/' });
    if (p.startsWith('/play/')) {
      let rel = p.slice('/play/'.length) || 'index.html';
      if (rel.endsWith('/')) rel += 'index.html';
      const file = inside(LIVE, rel);
      if (file && (await serveFile(res, file))) return;
      if (rel === 'index.html') return send(res, 200, page('No build yet', '<h1>No build yet</h1><p>The loop has not deployed a playable build. Check <a href="/status">Progress</a>.</p>'));
      return send(res, 404, 'Not found', 'text/plain');
    }
    send(res, 404, 'Not found', 'text/plain');
  } catch (err) {
    send(res, 500, 'Server error', 'text/plain');
    console.error(err);
  }
});

server.listen(PORT, '127.0.0.1', () => console.log(`hub listening on http://127.0.0.1:${PORT}`));
