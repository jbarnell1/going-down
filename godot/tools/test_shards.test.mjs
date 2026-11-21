// The sharded test run (tools/test_shards.mjs) with a stand-in engine, so it takes seconds:
//   node godot/tools/test_shards.test.mjs
// The stand-in (made here, in the temp folder) prints a PASS line per test of each file it is given and its
// totals, like tests/run_tests.gd, and can be told to fail a test, die, or hang. Checked: the packing, the
// shard count, first-files-first, one block of ports per engine, the totals line, and that an engine that
// fails, dies or hangs makes the whole run fail and is never dropped.
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PORT_BLOCK, pack, releasePorts, shardCount, takePorts, testCommand } from './test_shards.mjs';

let passed = 0;
const it = async (what, fn) => {
  await fn();
  passed += 1;
  console.log(`PASS  ${what}`);
};

const dir = mkdtempSync(join(tmpdir(), 'gd-shards-test-'));
const project = join(dir, 'godot');
mkdirSync(join(project, 'tests'), { recursive: true });
const FILES = ['test_scripts_load', 'test_export_data', 'a', 'b', 'c', 'd', 'e', 'f', 'g'];
writeFileSync(join(project, 'tests', 'run_tests.gd'), `const FILES: Array[String] = [\n\t${FILES.map((f) => `"${f}"`).join(', ')},\n]\n`);
writeFileSync(join(project, 'tests', 'timings.json'), JSON.stringify({ quick: { a: 30, b: 20, c: 10, d: 10, e: 5, f: 5, g: 1 } }));
const fake = join(dir, 'fake_engine.mjs');
writeFileSync(fake, `
const args = process.argv.slice(2);
const after = args.slice(args.indexOf('--') + 1);
const named = after.filter((a) => !a.startsWith('--'));
const files = named.length > 0 ? named : ${JSON.stringify(FILES)};
const base = after.find((a) => a.startsWith('--port-base='));
console.log('fake engine ' + base);
let p = 0, f = 0;
for (const file of files) {
  for (const t of ['one', 'two']) {
    if (process.env.FAKE_DIE === file && t === 'two') process.exit(3);
    if (process.env.FAKE_HANG === file) setInterval(() => {}, 1000);
    if (process.env.FAKE_HANG === file) await new Promise(() => {});
    if (process.env.FAKE_FAIL === file + '.' + t) { f++; console.log('FAIL  ' + file + '.' + t + '  (0.0 s)'); console.log('        - made to fail'); }
    else { p++; console.log('PASS  ' + file + '.' + t + '  (0.1 s)'); }
  }
}
console.log(p + ' passed, ' + f + ' failed in 0.1 s');
process.exit(f === 0 ? 0 : 1);
`);

/** Runs the command with the stand-in; returns [exit code, printed lines]. */
async function run(rest, env = {}) {
  const set = { GD_TEST_PORT_RANGE: '4920-4999', GD_TEST_SHARDS: '', ...env };
  const saved = Object.fromEntries(Object.keys(set).map((k) => [k, process.env[k]]));
  Object.assign(process.env, set);
  const lines = [];
  const log = console.log;
  console.log = (...a) => lines.push(a.join(' '));
  let code;
  try {
    code = await testCommand({ root: dir, project, engine: process.execPath, prefix: [fake], rest });
  } finally {
    console.log = log;
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    releasePorts();
  }
  return [code, lines];
}

await it('packing: the longest files first, each to the lightest group; every file once', () => {
  const g = pack(['a', 'b', 'c', 'd', 'e', 'f', 'g'], { a: 30, b: 20, c: 10, d: 10, e: 5, f: 5, g: 1 }, 3);
  // 30 alone; 20+5+1 and 10+10+5: no group waits on more than the longest file.
  assert.deepEqual(g.map((x) => x.secs).sort((x, y) => x - y), [25, 26, 30]);
  assert.deepEqual(g.flatMap((x) => x.files).sort(), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
  assert.equal(pack(['a', 'b'], {}, 5).length, 2, 'no empty groups');
});

await it('the runner\'s block of ports is the size tests/test_ports.gd hands out', () => {
  const gd = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'tests', 'test_ports.gd'), 'utf8');
  assert.equal(Number(/const SIZE := (\d+)/.exec(gd)?.[1]), PORT_BLOCK);
});

await it('the shard count: --shards=N, auto, GD_TEST_SHARDS, and one by default', () => {
  assert.equal(shardCount(undefined, ''), 1);
  assert.equal(shardCount(undefined, '3'), 3);
  assert.equal(shardCount('auto', '1'), 1, 'GD_TEST_SHARDS=1 overrides auto');
  assert.ok(shardCount('auto', '') >= 1 && shardCount('auto', '') <= 6);
  assert.equal(shardCount('4', '2'), 4, 'a number given wins');
  assert.throws(() => shardCount('0', ''));
});

await it('three engines: every test once, first files first, a block of ports each, the totals line', async () => {
  const [code, lines] = await run(['--quick', '--shards=3']);
  assert.equal(code, 0, lines.join('\n'));
  assert.equal(lines.at(-1).replace(/in [\d.]+ s/, 'in T s'), '18 passed, 0 failed in T s');
  const results = lines.filter((l) => /^\[[^\]]+\] (PASS|FAIL)  /.test(l));
  assert.equal(new Set(results.map((l) => l.split('  ')[1])).size, 18);
  const firstAt = Math.max(...lines.map((l, i) => (l.startsWith('[first] ') ? i : -1)));
  const shardAt = lines.findIndex((l) => /^\[s\d\] PASS/.test(l));
  assert.ok(firstAt < shardAt, 'the first files finish before any shard starts');
  const bases = lines.filter((l) => /^\[s\d\] fake engine/.test(l)).map((l) => Number(l.split('=')[1]));
  assert.equal(bases.length, 3);
  assert.equal(new Set(bases).size, 3, 'each engine its own ports');
  for (const b of bases) assert.ok(b >= 4920 && b + PORT_BLOCK - 1 <= 4999);
});

await it('one failing test in one engine: the run fails, with the right totals', async () => {
  const [code, lines] = await run(['--quick', '--shards=3'], { FAKE_FAIL: 'c.two' });
  assert.equal(code, 1);
  assert.equal(lines.at(-1).replace(/in [\d.]+ s/, 'in T s'), '17 passed, 1 failed in T s');
});

await it('an engine that dies part way: the run fails and says which engine', async () => {
  const [code, lines] = await run(['--quick', '--shards=3'], { FAKE_DIE: 'b' });
  assert.equal(code, 1);
  assert.ok(lines.some((l) => /^FAIL  engine s\d \(.*\bb\b.*\): ended \(exit 3\) without printing its totals/.test(l)), lines.join('\n'));
  assert.match(lines.at(-1), /^\d+ passed, 1 failed in/);
});

await it('an engine that hangs: killed at the timeout, and the run fails', async () => {
  const [code, lines] = await run(['--quick', '--shards=2'], { FAKE_HANG: 'g', GODOT_TIMEOUT: '3' });
  assert.equal(code, 1);
  assert.ok(lines.some((l) => /^FAIL  engine s\d .*timed out after 3 s/.test(l)), lines.join('\n'));
});

await it('one engine (no --shards): the engine\'s own lines and exit code; a dead engine is a failure', async () => {
  const [code, lines] = await run(['--quick']);
  assert.equal(code, 0);
  assert.ok(!lines.some((l) => l.startsWith('[')), 'no prefixes');
  assert.match(lines.at(-1), /^18 passed, 0 failed in/);
  const [dead, dl] = await run(['--quick'], { FAKE_DIE: 'a' });
  assert.notEqual(dead, 0);
  assert.ok(dl.some((l) => l.startsWith('FAIL  engine (the only one)')));
});

await it('ports: two runs at once never get the same block; a held --port-base is refused', async () => {
  process.env.GD_TEST_PORT_RANGE = '4920-4999';
  const a = await takePorts(3, undefined, [4920, 4999]);
  const b = await takePorts(3, undefined, [4920, 4999]);
  assert.ok(Math.abs(a - b) >= 3 * PORT_BLOCK, `${a} and ${b} overlap`);
  await assert.rejects(takePorts(1, a, [4920, 4999]), /reserved by another test run/);
  releasePorts();
  assert.equal(await takePorts(1, a, [4920, 4999]), a, 'free again once released');
  releasePorts();
});

rmSync(dir, { recursive: true, force: true });
console.log(`${passed} passed, 0 failed`);
