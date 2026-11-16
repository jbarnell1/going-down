// The announcer's recordings, made ahead of time with ElevenLabs (docs/VOICE.md).
//
//   node assets_src/voice/generate.mjs --voices                 list the account's voices (name, id, labels)
//   node assets_src/voice/generate.mjs --audition [--dry-run]   the audition lines, three takes, every shortlisted voice
//   node assets_src/voice/generate.mjs --all [--dry-run]        every line, three takes, the default voice
//   node assets_src/voice/generate.mjs --publish                copy the chosen takes into public/, loudness-normalised
//   node assets_src/voice/generate.mjs --page                   rewrite audition.html from lines.json (free)
//   --budget N   refuse a batch that would take the ledger's total over N characters (default: the game's cap)
//
// THE KEY. The environment variable GD_ELEVENLABS_ENV names the file that holds the line
// ELEVENLABS_API_KEY=... (which file: see .local/MACHINE.md, never committed). This script reads that
// one line into a variable and uses it only as the xi-api-key request header. It never prints it,
// writes it anywhere, puts it in a URL, or includes it in an error: errors show only the HTTP status
// and the API's own error text, with the key scrubbed out of that text in case it is ever echoed.
//
// THE MONEY. Before every batch: GET /v1/user/subscription, log characters used and the limit, and
// refuse if the batch would use more than 10% of what is left this month, or take the ledger over the
// game's cap or --budget. Characters are counted before sending, tags included. Every request is
// recorded in ledger.json. Each take is cached by a hash of text + voice + model + settings + take
// number, so the same take is never paid for twice. Any API error stops the batch at once.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalise } from './ff.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const LINES = path.join(HERE, 'lines.json');
const LEDGER = path.join(HERE, 'ledger.json');
const TAKES = path.join(HERE, 'takes');
const PUBLIC = path.join(ROOT, 'public', 'assets', 'voice');
const API = 'https://api.elevenlabs.io';
/** The game's cap on characters, takes included (docs/VOICE.md). */
const CAP = 50_000;
/** At most this share of what is left on the account this month, per batch. */
const MONTH_SHARE = 0.1;

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const opt = (f) => {
  const i = args.indexOf(f);
  return i >= 0 ? args[i + 1] : undefined;
};
const dryRun = has('--dry-run');
const budget = Math.min(CAP, Number(opt('--budget') ?? CAP));

function stop(msg, code = 2) {
  console.error(`STOP: ${msg}`);
  process.exit(code);
}

const rel = (p) => path.relative(ROOT, p).split(path.sep).join('/');
const chars = (text) => [...text].length;
export const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

function loadJson(file, fallback) {
  return existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : fallback;
}
function saveJson(file, value) {
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n');
  renameSync(tmp, file);
}

// ---- the key and the API --------------------------------------------------------------------

function readKey() {
  const file = process.env.GD_ELEVENLABS_ENV;
  if (!file) stop('GD_ELEVENLABS_ENV is not set (it names the file holding the key: see .local/MACHINE.md).');
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch {
    stop('the file named by GD_ELEVENLABS_ENV could not be read.');
  }
  const line = raw.split(/\r?\n/).find((l) => /^\s*ELEVENLABS_API_KEY\s*=/.test(l));
  raw = '';
  if (!line) stop('that file has no ELEVENLABS_API_KEY line.');
  const key = line.slice(line.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '');
  if (!key) stop('the ELEVENLABS_API_KEY line is empty.');
  return key;
}

class ApiError extends Error {
  constructor(status, text) {
    super(`HTTP ${status}: ${text}`);
    this.status = status;
  }
}

function client(key) {
  const scrub = (s) => String(s ?? '').split(key).join('[key]').slice(0, 800);
  async function call(method, p, body) {
    let res;
    try {
      res = await fetch(API + p, {
        method,
        headers: { 'xi-api-key': key, accept: body ? 'audio/mpeg' : 'application/json', ...(body ? { 'content-type': 'application/json' } : {}) },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch (e) {
      throw new ApiError(0, `network error ${scrub(e?.cause?.code ?? e?.name ?? 'unknown')}`);
    }
    if (!res.ok) {
      let text = '';
      try {
        text = await res.text();
      } catch {
        /* nothing more to say */
      }
      throw new ApiError(res.status, scrub(text));
    }
    return res;
  }
  return {
    json: async (p) => (await call('GET', p)).json(),
    audio: async (p, body) => {
      const res = await call('POST', p, body);
      const billed = res.headers.get('x-character-count') ?? res.headers.get('character-cost');
      return { bytes: Buffer.from(await res.arrayBuffer()), billed: billed === null ? null : Number(billed) };
    },
  };
}

async function subscription(api) {
  let s;
  try {
    s = await api.json('/v1/user/subscription');
  } catch (e) {
    stop(`the subscription check failed, nothing generated. ${e.message}`);
  }
  const used = Number(s.character_count);
  const limit = Number(s.character_limit);
  if (!Number.isFinite(used) || !Number.isFinite(limit)) stop('the subscription reply had no character_count / character_limit.');
  console.log(`account: ${used} characters used of ${limit} this month (${limit - used} left)`);
  return { used, limit, left: limit - used };
}

// ---- the batch ------------------------------------------------------------------------------

function hashOf(job) {
  const h = createHash('sha256');
  h.update(JSON.stringify({ text: job.text, voice: job.voiceId, model: job.model, settings: job.settings, format: job.format, take: job.take }));
  return h.digest('hex').slice(0, 24);
}

export function takePath(voiceName, id, take) {
  return path.join(TAKES, slug(voiceName), id, `take-${take}.mp3`);
}

function jobsFor(cfg, voices, ids) {
  const jobs = [];
  for (const v of voices) {
    for (const id of ids) {
      const line = cfg.lines.find((l) => l.id === id);
      if (!line) stop(`no line ${id} in lines.json`);
      for (let take = 1; take <= cfg.takes; take++) {
        const job = { id, voiceId: v.id, voiceName: v.name, take, text: line.text, settings: line.settings, model: cfg.model, format: cfg.outputFormat };
        job.hash = hashOf(job);
        job.out = takePath(v.name, id, take);
        jobs.push(job);
      }
    }
  }
  return jobs;
}

async function batch(cfg, jobs, label) {
  const ledger = loadJson(LEDGER, { about: 'Every ElevenLabs request the game has made. Never edit by hand.', cap: CAP, total: 0, entries: [] });
  const paid = new Set(ledger.entries.map((e) => e.hash));
  const todo = [];
  for (const j of jobs) {
    if (paid.has(j.hash)) {
      if (!existsSync(j.out)) console.warn(`  ${j.id} ${j.voiceName} take ${j.take}: paid for before but the file is gone; not paying again`);
      continue;
    }
    if (existsSync(j.out)) continue;
    todo.push(j);
  }
  const need = todo.reduce((n, j) => n + chars(j.text), 0);
  console.log(`${label}: ${jobs.length} takes, ${jobs.length - todo.length} cached, ${todo.length} to make, ${need} characters (tags included)`);
  console.log(`ledger: ${ledger.total} spent so far; cap ${CAP}; this run's budget ${budget}`);
  if (todo.length === 0) return;
  if (ledger.total + need > CAP) stop(`this batch would take the ledger to ${ledger.total + need}, over the game's cap of ${CAP}.`);
  if (ledger.total + need > budget) stop(`this batch would take the ledger to ${ledger.total + need}, over --budget ${budget}.`);
  if (dryRun) {
    console.log('dry run: nothing sent.');
    return;
  }
  const api = client(readKey());
  const sub = await subscription(api);
  if (need > MONTH_SHARE * sub.left) stop(`this batch (${need}) is more than 10% of what is left this month (${sub.left}). Ask the owner first.`);

  for (const j of todo) {
    const body = { text: j.text, model_id: j.model, voice_settings: j.settings, seed: j.take * 7919 };
    let got;
    try {
      got = await api.audio(`/v1/text-to-speech/${encodeURIComponent(j.voiceId)}?output_format=${j.format}`, body);
    } catch (e) {
      stop(`generation stopped at ${j.id} (${j.voiceName}, take ${j.take}); everything made before it is kept. ${e.message}`);
    }
    mkdirSync(path.dirname(j.out), { recursive: true });
    writeFileSync(j.out, got.bytes);
    const n = chars(j.text);
    ledger.total += n;
    ledger.entries.push({ id: j.id, voice: j.voiceName, voiceId: j.voiceId, take: j.take, characters: n, billed: got.billed, time: new Date().toISOString(), hash: j.hash, file: rel(j.out) });
    saveJson(LEDGER, ledger);
    console.log(`  ${j.id} ${j.voiceName} take ${j.take}: ${n} chars${got.billed !== null ? ` (billed ${got.billed})` : ''}, ${got.bytes.length} bytes; ledger ${ledger.total}`);
  }
  const after = await api.json('/v1/user/subscription').catch(() => null);
  if (after) console.log(`account after: ${after.character_count} used of ${after.character_limit}`);
}

// ---- publishing -----------------------------------------------------------------------------

function publish(cfg) {
  const def = cfg.voices.default;
  if (!def) stop('no default voice in lines.json yet.');
  mkdirSync(PUBLIC, { recursive: true });
  const manifest = { about: 'Generated by assets_src/voice/generate.mjs --publish from lines.json. Do not edit.', moments: {}, lines: [] };
  for (const [name, m] of Object.entries(cfg.moments)) manifest.moments[name] = { priority: m.priority };
  let missing = 0;
  for (const line of cfg.lines) {
    const pick = cfg.chosen[line.id] ?? { voice: def.name, take: 1 };
    const src = takePath(pick.voice, line.id, pick.take);
    if (!existsSync(src)) {
      console.warn(`  ${line.id}: no take at ${rel(src)}`);
      missing++;
      continue;
    }
    const dst = path.join(PUBLIC, `${line.id}.mp3`);
    const m = normalise(src, dst);
    console.log(`  ${line.id}: ${pick.voice} take ${pick.take} -> ${rel(dst)}  ${m.duration.toFixed(2)} s  ${m.lufs.toFixed(1)} LUFS  peak ${m.truePeak.toFixed(1)} dBTP`);
    manifest.lines.push({ id: line.id, moment: line.moment, plain: line.plain });
  }
  saveJson(path.join(PUBLIC, 'manifest.json'), manifest);
  if (missing) stop(`${missing} line(s) had no take to publish.`, 1);
}

// ---- the audition page ----------------------------------------------------------------------

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function page(cfg) {
  const src = (voice, id, take) => `/files/assets_src/voice/takes/${slug(voice)}/${id}/take-${take}.mp3`;
  const takes = (voice, id) =>
    Array.from({ length: cfg.takes }, (_, i) => `<div class="take"><span>Take ${i + 1}</span><audio controls preload="none" src="${src(voice, id, i + 1)}"></audio></div>`).join('');
  const lineBlock = (voice, line) =>
    `<div class="line"><p class="id">${esc(line.id)} <span>${esc(line.moment)}</span></p><p class="plain">${esc(line.plain)}</p><p class="tagged">${esc(line.text)}</p><p class="note">${esc(line.note)}</p>${takes(voice, line.id)}</div>`;
  const byId = (id) => cfg.lines.find((l) => l.id === id);
  const voices = cfg.voices.shortlist
    .map((v) => `<section><h2>${esc(v.name)}${cfg.voices.default?.id === v.id ? ' <small>(default for now)</small>' : ''}</h2><p class="desc">${esc(v.description)}</p><p class="desc">${esc(v.why)}</p>${cfg.audition.map((id) => lineBlock(v.name, byId(id))).join('')}</section>`)
    .join('');
  const def = cfg.voices.default;
  const full = def ? cfg.lines.map((l) => lineBlock(def.name, l)).join('') : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Announcer Audition</title>
<style>
  :root { color-scheme: light dark; --bg: #f6f5f1; --fg: #1d1d1b; --mute: #6b6a64; --card: #ffffff; --line: #dedbd2; --accent: #8a5a00; }
  @media (prefers-color-scheme: dark) { :root { --bg: #161614; --fg: #ecebe6; --mute: #a3a199; --card: #22221f; --line: #3a3934; --accent: #ffd27a; } }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 760px; margin: 0 auto; padding: 16px; }
  h1 { font-size: 1.5rem; margin: 8px 0 4px; }
  h2 { font-size: 1.2rem; margin: 28px 0 4px; }
  h2 small { font-weight: normal; color: var(--mute); font-size: 0.85rem; }
  .intro { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; }
  .desc { color: var(--mute); margin: 2px 0; }
  .line { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; margin: 10px 0; }
  .id { margin: 0; font-weight: 600; } .id span { font-weight: normal; color: var(--mute); font-size: 0.85rem; }
  .plain { margin: 4px 0; font-size: 1.05rem; }
  .tagged, .note { margin: 2px 0; color: var(--mute); font-size: 0.85rem; }
  .note { font-style: italic; }
  .take { display: flex; align-items: center; gap: 8px; margin-top: 6px; }
  .take span { flex: 0 0 52px; font-size: 0.85rem; color: var(--accent); }
  audio { width: 100%; min-width: 0; height: 36px; }
</style>
</head>
<body>
<main>
<h1>The elevator announcer: audition</h1>
<p class="intro">Listen for a voice that sounds bright, warm and a little too slow on the normal lines, completely sincere on the bad news, and genuinely flat and cold on the slip; also listen for any tag read aloud as a word, odd sound effects, or a take that breaks character. Put your choice of voice, and any takes you prefer over take 1, on the hub's Questions page.</p>
<p class="desc">These are the clean recordings. In the game they play through a tinny elevator speaker that gets worse with depth. Nobody has listened to any of them yet.</p>
${voices}
${def ? `<h2>Every line in ${esc(def.name)}</h2>${full}` : ''}
</main>
</body>
</html>
`;
}

function writePage(cfg) {
  writeFileSync(path.join(HERE, 'audition.html'), page(cfg));
  console.log('wrote assets_src/voice/audition.html');
}

// ---- main -----------------------------------------------------------------------------------

const cfg = loadJson(LINES, null);
if (!cfg) stop('lines.json is missing.');
if (cfg.model !== 'eleven_v4') stop(`lines.json asks for model ${cfg.model}; this game uses eleven_v4 only.`);

if (has('--voices')) {
  const api = client(readKey());
  await subscription(api);
  let res;
  try {
    res = await api.json('/v1/voices');
  } catch (e) {
    stop(`listing voices failed. ${e.message}`);
  }
  for (const v of res.voices ?? []) {
    const labels = Object.entries(v.labels ?? {}).map(([k, x]) => `${k}=${x}`).join(' ');
    const desc = String(v.description ?? '').replace(/\s+/g, ' ').slice(0, 160);
    console.log(`${v.name} | ${v.voice_id} | ${v.category ?? ''} | ${labels}${desc ? ` | ${desc}` : ''}`);
  }
} else if (has('--audition')) {
  if (!cfg.voices.shortlist.length) stop('no shortlisted voices in lines.json.');
  await batch(cfg, jobsFor(cfg, cfg.voices.shortlist, cfg.audition), 'audition');
  if (!dryRun) writePage(cfg);
} else if (has('--all')) {
  if (!cfg.voices.default) stop('no default voice in lines.json.');
  await batch(cfg, jobsFor(cfg, [cfg.voices.default], cfg.lines.map((l) => l.id)), 'full set');
  if (!dryRun) {
    publish(cfg);
    writePage(cfg);
  }
} else if (has('--publish')) {
  publish(cfg);
} else if (has('--page')) {
  writePage(cfg);
} else {
  console.log('usage: --voices | --audition | --all | --publish | --page   [--dry-run] [--budget N]');
}
