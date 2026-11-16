// North Star lookup: keeps the work tied to the design document without reading all of it.
// The document (docs/north-star.html) is large and kept on this PC only; this tool reads it and
// prints only what is asked for. Nothing here publishes the document.
//
//   node hub/ns.mjs index                 write .local/north-star-index.md: one line per mechanic,
//                                         with the tracker tasks linked to it (read this, not the HTML)
//   node hub/ns.mjs find <ids or words>   print the full text of the mechanics that match
//                                         (ids like H1 B6, or words: all must appear); falls back to
//                                         matching lines anywhere in the document
//   node hub/ns.mjs show <ids>            print exactly these mechanics
//   node hub/ns.mjs coverage              first-playable mechanics no task is linked to, and tasks
//                                         with no link
//   node hub/ns.mjs ids                   every mechanic id, for checking a link
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DOC = path.join(ROOT, 'docs', 'north-star.html');
const STATE = path.join(ROOT, 'loop', 'state.json');
const INDEX = path.join(ROOT, '.local', 'north-star-index.md');

const ENT = { '&rsquo;': "'", '&lsquo;': "'", '&ldquo;': '"', '&rdquo;': '"', '&amp;': '&', '&nbsp;': ' ', '&mdash;': ', ', '&ndash;': '-', '&hellip;': '...', '&lt;': '<', '&gt;': '>', '&times;': 'x', '&rarr;': '->' };
const plain = (h) => h.replace(/<[^>]+>/g, ' ').replace(/&[a-z]+;/g, (e) => ENT[e] ?? ' ').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n))).replace(/\s+/g, ' ').trim();
const slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 24);

export function mechanics() {
  if (!existsSync(DOC)) return null;
  const html = readFileSync(DOC, 'utf8');
  const out = [];
  let section = '';
  const re = /<h3[^>]*>([\s\S]*?)<\/h3>|<article class="mech[^"]*"(?: data-tier="(\w+)")?>([\s\S]*?)<\/article>/g;
  for (let m; (m = re.exec(html)); ) {
    if (m[1] !== undefined) { section = plain(m[1]); continue; }
    const body = m[3];
    const title = plain((body.match(/<h4>([\s\S]*?)<\/h4>/) ?? [])[1] ?? '');
    const idm = title.match(/^([A-Z]\d+)\.\s*(.*)$/);
    const chips = [...body.matchAll(/<span class="chip[^"]*">([\s\S]*?)<\/span>/g)].map((c) => plain(c[1]));
    const paras = [...body.matchAll(/<(p|li)[^>]*>([\s\S]*?)<\/\1>/g)].map((p) => plain(p[2])).filter(Boolean);
    out.push({
      id: idm ? idm[1] : 'cand-' + slug(title),
      title: idm ? idm[2] : title,
      tier: m[2] ?? 'candidate',
      chips,
      section,
      text: paras,
    });
  }
  return out;
}

const tasksByNs = () => {
  const map = new Map();
  if (!existsSync(STATE)) return { map, tasks: [] };
  const s = JSON.parse(readFileSync(STATE, 'utf8'));
  for (const t of s.tasks) for (const id of t.ns ?? []) (map.get(id) ?? map.set(id, []).get(id)).push(`${t.id}${t.status === 'done' ? ' done' : t.status === 'doing' ? ' doing' : ''}`);
  return { map, tasks: s.tasks };
};

const print = (m) => {
  console.log(`\n${m.id}. ${m.title}  [${m.tier}${m.chips.length ? ': ' + m.chips.join(' | ') : ''}]  (${m.section})`);
  for (const p of m.text) console.log('  ' + p);
};

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const [cmd, ...args] = process.argv.slice(2);
  const all = mechanics();
  if (!all) { console.error('docs/north-star.html is not on this machine; nothing to look up.'); process.exit(cmd === 'ids' ? 0 : 1); }
  const byId = new Map(all.map((m) => [m.id.toLowerCase(), m]));
  switch (cmd) {
    case 'ids': console.log(all.map((m) => m.id).join(' ')); break;
    case 'show': {
      for (const a of args.flatMap((x) => x.split(','))) { const m = byId.get(a.toLowerCase()); if (m) print(m); else console.log(`\n(no mechanic ${a})`); }
      break;
    }
    case 'find': {
      if (!args.length) { console.error('find needs ids or words'); process.exit(1); }
      const ids = args.filter((a) => byId.has(a.toLowerCase()));
      const words = args.filter((a) => !byId.has(a.toLowerCase())).map((w) => w.toLowerCase());
      const hits = new Set(ids.map((a) => byId.get(a.toLowerCase())));
      if (words.length) for (const m of all) { const hay = (m.title + ' ' + m.text.join(' ')).toLowerCase(); if (words.every((w) => hay.includes(w))) hits.add(m); }
      const list = [...hits];
      for (const m of list.slice(0, 8)) print(m);
      if (list.length > 8) console.log(`\n(${list.length - 8} more: ${list.slice(8).map((m) => m.id).join(' ')})`);
      if (!list.length && words.length) {
        // Not in a mechanic: look anywhere in the document (pillars, fairness contract, not-doing...).
        const lines = readFileSync(DOC, 'utf8').split('\n').map(plain).filter(Boolean);
        const found = lines.filter((l) => words.every((w) => l.toLowerCase().includes(w))).slice(0, 12);
        console.log(found.length ? '\nNo mechanic matches; lines elsewhere in the document:\n' + found.map((l) => '  ' + l.slice(0, 400)).join('\n') : '\nNothing in the North Star mentions that. It may be new: say so in the brief, and record the owner\'s words.');
      }
      break;
    }
    case 'coverage': {
      const { map, tasks } = tasksByNs();
      const open = all.filter((m) => m.tier === 'core' && !map.has(m.id));
      console.log(`First-playable mechanics with no task linked (${open.length}):`);
      for (const m of open) console.log(`  ${m.id.padEnd(4)} ${m.title}`);
      const loose = tasks.filter((t) => !t.ns);
      console.log(`\nTasks with no North Star link (${loose.length}): ${loose.map((t) => t.id).join(' ') || 'none'}`);
      break;
    }
    case 'index': {
      const { map } = tasksByNs();
      const L = ['# North Star index', '', '> Generated by `node hub/ns.mjs index` from the design document. One line per mechanic. For the full text of one: `node hub/ns.mjs show <id>`.', ''];
      let sec = null;
      for (const m of all) {
        if (m.section !== sec) { sec = m.section; L.push('', `## ${sec}`, ''); }
        const first = (m.text[0] ?? '').split(/(?<=[.!?])\s/)[0].slice(0, 170);
        L.push(`- **${m.id}** ${m.title} _(${m.tier}${m.chips[0] ? ': ' + m.chips[0] : ''})_: ${first}${map.has(m.id) ? `  **Tasks:** ${map.get(m.id).join(', ')}` : ''}`);
      }
      mkdirSync(path.dirname(INDEX), { recursive: true });
      writeFileSync(INDEX, L.join('\n') + '\n');
      console.log(`wrote .local/north-star-index.md (${all.length} mechanics, ${L.join('\n').length} characters)`);
      break;
    }
    default: console.error('usage: node hub/ns.mjs index | find <ids or words> | show <ids> | coverage | ids'); process.exit(1);
  }
}
