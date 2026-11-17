// The loop's progress tracker. One command per event; never edit loop/state.json or
// loop/PROGRESS.md by hand. state.json is the source of truth, PROGRESS.md is generated from it,
// and the hub's Status page reads state.json.
//
//   node hub/track.mjs iteration
//   node hub/track.mjs start T2a "what is happening, in plain words"
//   node hub/track.mjs done T2a --summary "what is now true and how it was checked" --media shot.png:"caption" --media map.txt
//   node hub/track.mjs media T3 render.png:"second pass, front view"      attach pictures to a task at any time
//   node hub/track.mjs gate G2 passed "evidence" [--media ...]           passed | unverified | open
//   node hub/track.mjs add T1b "Title" --why "why a player cares" [--after T1] [--ns H1,B6 | --ns none --ns-why "..."]
//   node hub/track.mjs link T8 B6,F3            tie a task to North Star mechanics (see hub/ns.mjs); or: link T2w none --why "tooling"
//        start refuses a task with no link and prints the linked mechanics; done prints them again and
//        needs --ns "<how the result matches them, or where it differs on purpose and who decided>"
//   node hub/track.mjs todo T3 "one thing still to fix"                   and: todo-clear T3
//   node hub/track.mjs blocked T3 "why" | unblock T3
//   node hub/track.mjs decision "a default taken without asking"
//   node hub/track.mjs ci passed|failed <commit>
//   node hub/track.mjs answers <iso time of newest answer applied>
//   node hub/track.mjs deadline <iso time> "who decided and why"           move the loop's time limit (the owner's call only)
//   node hub/track.mjs note "one line for the activity feed"
//   node hub/track.mjs show                                                print the short status the loop reads
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const STATE = path.join(ROOT, 'loop', 'state.json');
const PROGRESS = path.join(ROOT, 'loop', 'PROGRESS.md');
const MEDIA = path.join(ROOT, '.local', 'media');

const now = () => new Date().toISOString();
const load = () => JSON.parse(readFileSync(STATE, 'utf8'));
function save(s) {
  const tmp = STATE + '.tmp';
  writeFileSync(tmp, JSON.stringify(s, null, 2) + '\n');
  renameSync(tmp, STATE);
  writeFileSync(PROGRESS, render(s));
}
const die = (m) => { console.error(m); process.exit(1); };

// --- arguments: positionals, plus repeatable --flag value ---
const argv = process.argv.slice(2);
const cmd = argv.shift();
const pos = [];
const flags = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith('--')) (flags[a.slice(2)] ??= []).push(argv[++i] ?? '');
  else pos.push(a);
}
const flag = (k) => flags[k]?.[0];

const kindOf = (file) => ({ '.png': 'image', '.jpg': 'image', '.jpeg': 'image', '.webp': 'image', '.txt': 'text', '.glb': 'model', '.mp3': 'audio', '.wav': 'audio' }[path.extname(file).toLowerCase()] ?? 'file');

// Copies a proof file into .local/media so later test runs cannot overwrite it. "path:caption".
function keep(spec, owner) {
  const cut = spec.indexOf(':', 3); // skip a drive letter
  const src = cut === -1 ? spec : spec.slice(0, cut);
  const caption = cut === -1 ? '' : spec.slice(cut + 1);
  const abs = path.resolve(ROOT, src);
  if (!existsSync(abs)) die(`media file not found: ${src}`);
  const stamp = now().replace(/[-:]/g, '').slice(0, 15);
  const name = `${stamp}-${path.basename(abs)}`;
  mkdirSync(path.join(MEDIA, owner), { recursive: true });
  copyFileSync(abs, path.join(MEDIA, owner, name));
  return { src: `${owner}/${name}`, caption, kind: kindOf(abs), at: now() };
}

const task = (s, id) => s.tasks.find((t) => t.id === id) ?? die(`no task ${id}`);

// North Star links: mechanic ids checked against the design document when it is on this machine.
function nsIds(spec, why) {
  if (!spec) die('link needs mechanic ids (H1,B6) or "none" with --why');
  if (spec.toLowerCase() === 'none') { if (!why) die('link none needs --why "<why nothing in the North Star covers this>"'); return []; }
  const ids = spec.split(',').map((x) => x.trim()).filter(Boolean);
  const r = spawnSync(process.execPath, [path.join(ROOT, 'hub', 'ns.mjs'), 'ids'], { encoding: 'utf8' });
  const known = (r.stdout ?? '').trim().split(/\s+/).filter(Boolean);
  if (known.length) for (const id of ids) if (!known.includes(id)) die(`no North Star mechanic "${id}". Known: ${known.join(' ')}`);
  return ids;
}
const gateOf = (s, id) => s.gates.find((g) => g.id === id) ?? die(`no gate ${id}`);
const feed = (s, text, kind = 'note') => { s.feed.unshift({ at: now(), text, kind }); s.feed = s.feed.slice(0, 200); };

function render(s) {
  const done = s.tasks.filter((t) => t.status === 'done').length;
  const passed = s.gates.filter((g) => g.status === 'passed').length;
  const cur = s.tasks.find((t) => t.id === s.now);
  const L = [];
  L.push('# Progress', '', '> Generated by `hub/track.mjs` from `loop/state.json`. Do not edit by hand.', '');
  L.push('## Status', '');
  L.push(`- **Gates passed:** ${passed} of ${s.gates.length}. **Tasks done:** ${done} of ${s.tasks.length}.`);
  L.push(`- **Started:** ${s.startedAt}. **Time limit:** ${s.deadlineAt}. **Iterations:** ${s.iteration}.`);
  L.push(`- **Now:** ${cur ? `${cur.id} ${cur.title}. ${s.nowText ?? ''}` : 'nothing in progress'}`);
  L.push(`- **Last CI result seen:** ${s.ci ? `${s.ci.status} on ${s.ci.commit}` : 'none'}`);
  L.push(`- **Answers applied up to:** ${s.answersAppliedTo ?? 'none yet'}`, '');
  L.push('## Tasks', '');
  for (const t of s.tasks) {
    L.push(`- [${t.status === 'done' ? 'x' : ' '}] **${t.id}** \`${t.status}\` ${t.title}${t.gates?.length ? ` (${t.gates.join(', ')})` : ''}`);
    if (t.why) L.push(`  - Why: ${t.why}`);
    if (t.summary) L.push(`  - Evidence: ${t.summary}`);
    if (t.blocked) L.push(`  - BLOCKED: ${t.blocked}`);
    for (const d of t.todo ?? []) L.push(`  - To do: ${d}`);
  }
  L.push('', '## Gates', '');
  for (const g of s.gates) L.push(`- [${g.status === 'passed' ? 'x' : ' '}] **${g.id}** ${g.title}: ${g.status}${g.evidence ? `. ${g.evidence}` : ''}`);
  L.push('', '## Decisions taken on defaults', '');
  for (const d of s.decisions) L.push(`- ${d.at.slice(0, 10)}: ${d.text}`);
  L.push('', '## Activity (newest first)', '');
  for (const f of s.feed.slice(0, 40)) L.push(`- ${f.at.slice(0, 16).replace('T', ' ')}Z ${f.text}`);
  return L.join('\n') + '\n';
}

if (!cmd) die('usage: node hub/track.mjs <command> ... (see the top of this file)');
const s = load();
switch (cmd) {
  case 'show': {
    const t = s.tasks.find((x) => x.id === s.now);
    console.log(`iteration ${s.iteration} | gates ${s.gates.filter((g) => g.status === 'passed').length}/${s.gates.length} | started ${s.startedAt} | limit ${s.deadlineAt}`);
    console.log(`now: ${t ? `${t.id} ${t.title} [${t.status}]` : 'nothing'} | ci: ${s.ci ? `${s.ci.status} ${s.ci.commit}` : 'none'} | answers applied to: ${s.answersAppliedTo ?? 'none'}`);
    for (const x of s.tasks) console.log(`  ${x.status.padEnd(7)} ${x.id.padEnd(5)} ${x.title}${x.blocked ? '  BLOCKED' : ''}`);
    process.exit(0);
  }
  case 'render': break;
  case 'iteration': s.iteration += 1; break;
  case 'link': {
    // Ties a task to the North Star mechanics it builds: `link T8 B6,F3`, or `link T2w none --why "tooling"`.
    const t = task(s, pos[0]);
    t.ns = nsIds(pos[1], flag('why'));
    if (flag('why')) t.nsWhy = flag('why');
    feed(s, `Linked ${t.id} to the North Star: ${t.ns.length ? t.ns.join(', ') : 'nothing in it (' + t.nsWhy + ')'}.`);
    break;
  }
  case 'start': {
    const t = task(s, pos[0]);
    if (t.status === 'done' && !flags.reopen) die(`${t.id} is done; pass --reopen to start it again`);
    if (!t.ns) die(`${t.id} has no North Star link. Look first:  node hub/ns.mjs find <words>   then:  node hub/track.mjs link ${t.id} <ids>   (or: link ${t.id} none --why "...")`);
    if (t.ns.length) spawnSync(process.execPath, [path.join(ROOT, 'hub', 'ns.mjs'), 'show', ...t.ns], { stdio: 'inherit' });
    t.status = 'doing'; t.startedAt ??= now(); delete t.blocked; delete t.waiting;
    // Several steps can be in progress at once (parallel agents): each keeps its own line.
    if (pos[1]) { t.doingText = pos[1]; t.doingAt = now(); }
    s.now = t.id; s.nowText = pos[1] ?? '';
    feed(s, `Started ${t.id}: ${t.title}.${pos[1] ? ' ' + pos[1] : ''}`, 'start');
    break;
  }
  case 'done': {
    const t = task(s, pos[0]);
    if (!flag('summary')) die('done needs --summary: what is now true and how it was checked');
    if (!t.ns) die(`${t.id} has no North Star link: node hub/track.mjs link ${t.id} <ids>  (or: link ${t.id} none --why "...")`);
    if (t.ns.length && !flag('ns')) {
      spawnSync(process.execPath, [path.join(ROOT, 'hub', 'ns.mjs'), 'show', ...t.ns], { stdio: 'inherit' });
      die(`\ndone needs --ns "<how the result matches ${t.ns.join(', ')} above, or where it differs on purpose and who decided>"`);
    }
    if (flag('ns')) t.nsCheck = flag('ns');
    t.status = 'done'; t.finishedAt = now(); t.summary = flag('summary'); t.todo = [];
    for (const m of flags.media ?? []) (t.media ??= []).push(keep(m, t.id));
    if (s.now === t.id) { s.now = null; s.nowText = ''; }
    feed(s, `Finished ${t.id}: ${t.title}.`, 'done');
    break;
  }
  case 'media': {
    const t = task(s, pos[0]);
    for (const m of pos.slice(1)) (t.media ??= []).push(keep(m, t.id));
    feed(s, `New pictures for ${t.id}: ${t.title}.`, 'media');
    break;
  }
  case 'gate': {
    const g = gateOf(s, pos[0]);
    if (!['passed', 'unverified', 'open'].includes(pos[1])) die('gate status must be passed, unverified or open');
    if (pos[1] === 'passed' && !pos[2]) die('a passed gate needs its evidence');
    g.status = pos[1]; g.evidence = pos[2] ?? ''; g.at = now();
    for (const m of flags.media ?? []) (g.media ??= []).push(keep(m, g.id));
    feed(s, `Gate ${g.id} (${g.title}) is ${g.status}.`, 'gate');
    break;
  }
  case 'add': {
    if (s.tasks.some((t) => t.id === pos[0])) die(`task ${pos[0]} already exists`);
    const t = { id: pos[0], title: pos[1] ?? die('add needs a title'), why: flag('why') ?? '', status: 'todo', gates: (flag('gates') ?? '').split(',').filter(Boolean) };
    if (flag('ns')) { t.ns = nsIds(flag('ns'), flag('ns-why')); if (flag('ns-why')) t.nsWhy = flag('ns-why'); }
    const after = flag('after') ? s.tasks.findIndex((x) => x.id === flag('after')) : -1;
    if (after === -1) s.tasks.push(t); else s.tasks.splice(after + 1, 0, t);
    feed(s, `Added task ${t.id}: ${t.title}.`);
    break;
  }
  case 'move': {
    const t = task(s, pos[0]);
    s.tasks = s.tasks.filter((x) => x !== t);
    const after = s.tasks.findIndex((x) => x.id === flag('after'));
    if (after === -1) die('move needs --after <existing id>');
    s.tasks.splice(after + 1, 0, t);
    break;
  }
  case 'todo': (task(s, pos[0]).todo ??= []).push(pos[1] ?? die('todo needs text')); break;
  case 'todo-clear': task(s, pos[0]).todo = []; break;
  case 'blocked': { const t = task(s, pos[0]); t.status = 'blocked'; t.blocked = pos[1] ?? die('say why'); feed(s, `Blocked on ${t.id}: ${t.blocked}`, 'blocked'); break; }
  case 'unblock': { const t = task(s, pos[0]); t.status = 'todo'; delete t.blocked; break; }
  // Nobody is working on it this minute: back to the queue, with what it waits for. Only steps an agent
  // is actually running stay "doing", so the Progress page's "Right now" list is true.
  case 'wait': { const t = task(s, pos[0]); if (t.status === 'done') die(`${t.id} is done; wait is only for unfinished steps`); t.status = 'todo'; t.waiting = pos[1] ?? die('say what it waits for'); delete t.doingText; delete t.doingAt; if (s.now === t.id) { s.now = null; s.nowText = ''; } feed(s, `Paused ${t.id}: waiting for ${t.waiting}`); break; }
  case 'decision': s.decisions.push({ at: now(), text: pos[0] ?? die('decision needs text') }); feed(s, `Took a default: ${pos[0]}`, 'decision'); break;
  case 'ci': s.ci = { status: pos[0], commit: pos[1] ?? '', at: now() }; if (pos[0] !== 'passed') feed(s, `CI ${pos[0]} on ${pos[1] ?? ''}.`, 'ci'); break;
  case 'deadline': {
    if (!pos[0] || Number.isNaN(Date.parse(pos[0]))) die('deadline needs an ISO time');
    s.deadlineAt = new Date(pos[0]).toISOString(); feed(s, `Time limit moved to ${s.deadlineAt}: ${pos[1] ?? die('say who decided and why')}`); break;
  }
  case 'answers': s.answersAppliedTo = pos[0] ?? now(); feed(s, 'Applied the owner\'s new answers.', 'answers'); break;
  case 'note': feed(s, pos[0] ?? die('note needs text')); break;
  default: die(`unknown command: ${cmd}`);
}
save(s);
console.log(`tracked: ${cmd} ${pos[0] ?? ''}`.trim());
