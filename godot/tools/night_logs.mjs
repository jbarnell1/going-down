// The night's logs: fetch them from the lab box and print a summary to fix from.
//
//   node godot/tools/night_logs.mjs --ssh USER@HOST [--since 12h] [--container going-down] [--save FILE]
//       runs `docker logs <container>` on the box over ssh (nothing else), saves everything it printed to
//       FILE (default godot/export/night-logs/night-<local time>.log, not in git), then summarises it.
//       USER@HOST may come from the environment variable GD_LAB_SSH instead. Never put it in a file in
//       the repository: the repository is public.
//   node godot/tools/night_logs.mjs FILE [FILE ...]   summarises saved logs (several: one night in parts,
//       for example the logs fetched before each redeploy).
//   --errors-only   only the errors, crashes and F9 reports.
//
// What it reads: the server's JSON lines (server/night_log.gd: {"gd":1,"t":...,"ev":...}), anywhere on a
// line (a `docker logs -t` timestamp before them is fine), and the server's plain lines (only those that
// look like trouble are shown). What it prints: the nights (server starts and their builds), the players
// (builds, OS, GPU, time connected, frame times, ping), the sessions and how each ended, the runs (floors,
// catches, downs, wipes), client errors grouped by message with counts and first and last time, server
// errors the same way, crash tails and F9 reports in full, the worst frame times, the disconnects, the
// server's tick cost, refused connections and dropped lines.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');

/** What a WebSocket close code means, in the words of net/ws_server.gd. */
export const CLOSE_CODES = {
  0: 'unknown',
  1000: 'left normally',
  1001: 'going away (game closed, or the server stopped)',
  1005: 'closed without a code',
  1006: 'dropped without a close (crash, network loss or killed)',
  1009: 'message too big (WebSocket layer)',
  4001: 'wrong passphrase',
  4002: 'room full',
  4003: 'message too big',
  4004: 'flood (too many messages)',
  4005: 'outside the protocol',
  4006: 'idle (nothing for 20 s)',
  4007: 'out-of-date build',
};

/** Parses log text: { events: [json objects], plain: [lines that are not JSON log lines] }. */
export function parseLog(text) {
  const events = [];
  const plain = [];
  for (const raw of text.split(/\r?\n/)) {
    const at = raw.indexOf('{"gd":1');
    if (at >= 0) {
      try {
        events.push(JSON.parse(raw.slice(at)));
        continue;
      } catch {
        /* a cut line: kept as plain */
      }
    }
    if (raw.trim()) plain.push(raw);
  }
  return { events, plain };
}

const time = (iso) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? String(iso) : d.toLocaleTimeString('en-GB', { hour12: false });
};
const day = (iso) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
};
const secs = (s) => (s >= 3600 ? `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min` : s >= 60 ? `${Math.floor(s / 60)} min ${Math.round(s % 60)} s` : `${Math.round(s)} s`);
const codeText = (c) => `${c} ${CLOSE_CODES[c] ?? ''}`.trim();
/** A message's group: numbers and hex ids folded, so "error 12" and "error 13" count together. */
export const groupKey = (s) => String(s).replace(/0x[0-9a-f]+/gi, '0x#').replace(/\d+(\.\d+)?/g, '#').trim();

/** The summary as an object (the tests read it) and as text lines. */
export function summarize(text, { errorsOnly = false } = {}) {
  const { events, plain } = parseLog(text);
  const out = [];
  const say = (l = '') => out.push(l);
  const key = (e) => `${e.night}/${e.id}`;
  const nameOf = new Map();
  for (const e of events) if (e.id && e.name) nameOf.set(key(e), e.name);
  const who = (e) => e.name || nameOf.get(key(e)) || e.id || '?';

  const nights = events.filter((e) => e.ev === 'start');
  const joins = events.filter((e) => e.ev === 'join');
  const leaves = events.filter((e) => e.ev === 'leave');
  const hbs = events.filter((e) => e.ev === 'hb');
  const clogs = events.filter((e) => e.ev === 'clog');
  const reports = events.filter((e) => e.ev === 'report');
  const serrs = events.filter((e) => e.ev === 'serr');
  const runs = events.filter((e) => e.ev === 'run');
  const game = events.filter((e) => e.ev === 'game');
  const ticks = events.filter((e) => e.ev === 'tick');

  // Reports, put back together.
  const reportMap = new Map();
  for (const r of reports) {
    const k = `${r.night}/${r.id}/${r.kind}/${r.rid}`;
    if (!reportMap.has(k)) reportMap.set(k, { name: who(r), kind: r.kind, t: r.t, parts: r.parts, got: new Map() });
    reportMap.get(k).got.set(r.part, r.body);
  }
  const full = [...reportMap.values()].map((r) => ({
    ...r,
    text: [...Array(r.parts).keys()].map((i) => r.got.get(i) ?? `[part ${i + 1} of ${r.parts} missing]`).join('\n'),
    missing: r.parts - r.got.size,
  }));

  // Error groups.
  const groups = (list, textOf, whoOf) => {
    const m = new Map();
    for (const e of list) {
      const k = groupKey(textOf(e));
      if (!m.has(k)) m.set(k, { example: textOf(e), count: 0, first: e.t, last: e.t, players: new Set() });
      const g = m.get(k);
      g.count += 1;
      g.last = e.t;
      g.players.add(whoOf(e));
    }
    return [...m.values()].sort((a, b) => b.count - a.count);
  };
  const clientErrors = groups(clogs.filter((e) => !String(e.line).startsWith('disc ')), (e) => e.line, who);
  const serverErrors = groups(serrs, (e) => `${e.kind}: ${e.text}`, () => 'server');
  const trouble = plain.filter((l) => /ERROR|SCRIPT ERROR|crash|signal|WARNING|not started|Program crashed/i.test(l) && !/INSECURE MODE/.test(l));

  const summary = { nights: nights.length, players: new Set(joins.map(who)).size, sessions: joins.length, runs: runs.length, clientErrors, serverErrors, reports: full, trouble };

  say(`${events.length} log lines, ${plain.length} plain lines`);
  if (!errorsOnly) {
    say('');
    say('== Nights (server starts)');
    for (const n of nights) say(`  ${day(n.t)} ${time(n.t)}  night ${n.night}  build ${n.build}  port ${n.port}`);
    if (nights.length === 0) say('  (no start line: the log begins after the server started)');

    say('');
    say('== Players');
    const players = new Map();
    for (const j of joins) {
      const n = who(j);
      if (!players.has(n)) players.set(n, { builds: new Set(), sessions: 0, time: 0, hb: null, worst: 0, avg: [], ping: [] });
      const p = players.get(n);
      p.builds.add(j.build || '(none)');
      p.sessions += 1;
    }
    for (const l of leaves) players.get(who(l)) && (players.get(who(l)).time += l.secs || 0);
    for (const h of hbs) {
      const p = players.get(who(h));
      if (!p) continue;
      p.hb = h.data;
      if (h.data.worst_ms > p.worst) p.worst = h.data.worst_ms;
      if (h.data.avg_ms > 0) p.avg.push(h.data.avg_ms);
      if (h.data.ping_ms >= 0) p.ping.push(h.data.ping_ms);
    }
    const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : NaN);
    for (const [n, p] of players) {
      const hb = p.hb ?? {};
      say(`  ${n}: ${p.sessions} session(s), ${secs(p.time)} connected, build ${[...p.builds].join(', ')}`);
      say(`      ${hb.os ?? '?'}, GPU ${hb.gpu || '?'} (${hb.renderer ?? '?'}); frames average ${p.avg.length ? mean(p.avg).toFixed(1) : '?'} ms, worst ${p.avg.length ? p.worst.toFixed(1) : '?'} ms; ping ${p.ping.length ? `${mean(p.ping).toFixed(0)} ms average, ${Math.max(...p.ping).toFixed(0)} worst` : '?'}; errors reported ${hb.errors ?? 0}${hb.dropped ? `, ${hb.dropped} not sent (limit)` : ''}`);
    }

    say('');
    say('== Sessions');
    const timeline = [...joins, ...leaves].sort((a, b) => String(a.t).localeCompare(String(b.t)));
    for (const e of timeline) {
      if (e.ev === 'join') say(`  ${time(e.t)}  + ${who(e)} (${e.id}, build ${e.build || '(none)'}, from ${e.addr || '?'})`);
      else say(`  ${time(e.t)}  - ${who(e)} (${e.id}) after ${secs(e.secs || 0)}: ${codeText(e.code)}${e.reason ? ` "${e.reason}"` : ''}`);
    }

    say('');
    say('== Runs');
    for (const r of runs) {
      const evs = game.filter((g) => g.night === r.night && g.run === r.run);
      const count = (t) => evs.filter((g) => g.type === t).length;
      const end = events.find((e) => e.ev === 'runEnd' && e.night === r.night && e.run === r.run);
      const deepest = Math.max(0, ...evs.map((g) => g.depth ?? 0));
      say(`  run ${r.run} at ${time(r.t)} (${(r.players ?? []).join(', ')}), seed ${r.seed}: deepest floor ${deepest}, ${count('rodeDown')} rides down, ${count('caught')} caught, ${count('downed')} down, ${count('healed')} healed, ${count('out')} out, ${count('wiped')} wiped, ${count('banked')} banked${end ? `, over at ${time(end.t)}` : ', not over in this log'}`);
      for (const g of evs.filter((x) => ['caught', 'downed', 'out', 'wiped', 'banked', 'leftBehind'].includes(x.type))) {
        say(`      ${time(g.t)}  ${g.type}${g.player ? ` ${g.player}` : ''} on floor ${g.depth}${g.by ? ` (by ${g.by})` : ''}${g.total !== undefined ? `, total ${g.total}` : ''}`);
      }
    }
  }

  say('');
  say(`== Client errors (${clientErrors.length} kinds, ${clientErrors.reduce((x, g) => x + g.count, 0)} lines)`);
  for (const g of clientErrors) say(`  ${String(g.count).padStart(4)}x  ${g.example}\n         players ${[...g.players].join(', ')}; first ${time(g.first)}, last ${time(g.last)}`);
  say('');
  say(`== Server errors (${serverErrors.length} kinds)`);
  for (const g of serverErrors) say(`  ${String(g.count).padStart(4)}x  ${g.example}\n         first ${time(g.first)}, last ${time(g.last)}`);
  if (trouble.length) {
    say('');
    say(`== Server plain lines that look like trouble (${trouble.length})`);
    for (const l of trouble.slice(-40)) say(`  ${l}`);
  }
  say('');
  say(`== Crashes (the tail a game sent at its next start: ${full.filter((r) => r.kind === 'crash').length})`);
  for (const r of full.filter((x) => x.kind === 'crash')) say(`  --- ${r.name} at ${time(r.t)}${r.missing ? ` (${r.missing} part(s) missing)` : ''}\n${r.text.replace(/^/gm, '    ')}`);
  say('');
  say(`== F9 reports (${full.filter((r) => r.kind === 'rep').length})`);
  for (const r of full.filter((x) => x.kind === 'rep')) say(`  --- ${r.name} at ${time(r.t)}${r.missing ? ` (${r.missing} part(s) missing)` : ''}\n${r.text.replace(/^/gm, '    ')}`);

  if (!errorsOnly) {
    say('');
    say('== Worst frame times (heartbeats, worst first)');
    for (const h of [...hbs].sort((a, b) => (b.data.worst_ms ?? 0) - (a.data.worst_ms ?? 0)).slice(0, 10)) {
      say(`  ${String((h.data.worst_ms ?? 0).toFixed(1)).padStart(7)} ms  ${who(h)} at ${time(h.t)} (average ${h.data.avg_ms} ms, ${h.data.mode ?? ''} ${h.data.place ?? ''} floor ${h.data.depth ?? '?'} ${h.data.phase ?? ''})`);
    }
    say('');
    say('== Disconnects (not a normal leave)');
    for (const l of leaves.filter((x) => x.code !== 1000)) say(`  ${time(l.t)}  ${who(l)}: ${codeText(l.code)}${l.reason ? ` "${l.reason}"` : ''} after ${secs(l.secs || 0)}`);
    for (const c of clogs.filter((e) => String(e.line).startsWith('disc '))) say(`  ${time(c.t)}  ${who(c)} says (sent on reconnecting): ${String(c.line).slice(5)}`);
    say('');
    say('== Server tick cost');
    if (ticks.length) {
      const worst = ticks.reduce((a, b) => (b.worst > a.worst ? b : a));
      const busiest = ticks.reduce((a, b) => (b.ms > a.ms ? b : a));
      say(`  ${ticks.length} lines; highest mean ${busiest.ms} ms a tick at ${time(busiest.t)} (${busiest.players} players); worst single tick ${worst.worst} ms at ${time(worst.t)} (50 ms is the whole budget)`);
    } else say('  (none)');
    say('');
    say('== Refused and dropped');
    const refused = {};
    for (const r of events.filter((e) => e.ev === 'refused')) for (const [k, n] of Object.entries(r.counts)) refused[k] = (refused[k] ?? 0) + n;
    say(`  refused connections: ${Object.keys(refused).length ? JSON.stringify(refused) : 'none'}`);
    for (const d of events.filter((e) => e.ev === 'dropped')) say(`  ${time(d.t)}  ${who(d)}: lines over the limit or not decoding ${JSON.stringify(d.counts)}`);
  }
  return { summary, lines: out };
}

/** `docker logs` on the box over ssh; returns the text (stdout and stderr together). */
export function fetchLogs(target, { container = 'going-down', since = '' } = {}) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*$/.test(target)) throw new Error(`not a USER@HOST: ${target}`);
  if (!/^[A-Za-z0-9_.-]+$/.test(container)) throw new Error(`not a container name: ${container}`);
  if (since && !/^[0-9]+[smhd]$|^[0-9T:.-]+Z?$/.test(since)) throw new Error(`not a --since value: ${since}`);
  const cmd = `docker logs ${since ? `--since ${since} ` : ''}${container} 2>&1`;
  const r = spawnSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', target, cmd], { encoding: 'utf8', maxBuffer: 512 << 20 });
  if (r.error) throw new Error(`ssh failed: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`ssh exited ${r.status}: ${(r.stderr || r.stdout || '').trim().slice(0, 400)}`);
  return r.stdout;
}

function main(argv) {
  const args = [...argv];
  const grab = (name) => {
    const i = args.findIndex((a) => a === `--${name}` || a.startsWith(`--${name}=`));
    if (i < 0) return undefined;
    if (args[i].includes('=')) return args.splice(i, 1)[0].split('=').slice(1).join('=');
    return args.splice(i, 2)[1];
  };
  const errorsOnly = args.includes('--errors-only');
  const ssh = grab('ssh') ?? (args.includes('--fetch') ? process.env.GD_LAB_SSH : undefined);
  const since = grab('since') ?? '';
  const container = grab('container') ?? 'going-down';
  const save = grab('save');
  const files = args.filter((a) => !a.startsWith('--'));
  let text = '';
  if (ssh !== undefined) {
    if (!ssh) {
      console.error('No host: pass --ssh USER@HOST, or set GD_LAB_SSH and pass --fetch.');
      return 2;
    }
    text = fetchLogs(ssh, { container, since });
    const p2 = (n) => String(n).padStart(2, '0');
    const d = new Date();
    const file = save ?? join(root, 'godot', 'export', 'night-logs', `night-${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}-${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}.log`);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, text);
    console.log(`saved ${text.length} bytes to ${file}`);
  } else if (files.length > 0) {
    for (const f of files) {
      if (!existsSync(f)) {
        console.error(`no such file: ${f}`);
        return 2;
      }
      text += `${readFileSync(f, 'utf8')}\n`;
    }
  } else {
    console.error('usage: node godot/tools/night_logs.mjs --ssh USER@HOST [--since 12h] [--save FILE] | --fetch (USER@HOST from GD_LAB_SSH) | FILE [FILE ...]  [--errors-only]');
    return 2;
  }
  console.log(summarize(text, { errorsOnly }).lines.join('\n'));
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(main(process.argv.slice(2)));
