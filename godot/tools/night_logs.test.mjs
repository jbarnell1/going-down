// The night log summary (tools/night_logs.mjs) on a real server's output and on made-up trouble.
//   node godot/tools/night_logs.test.mjs
// The fixture, godot/tests/night/net_local_sample.log, is everything the server printed in one
// `node godot/tools/net_local.mjs 4491 --save-log=godot/tests/night/net_local_sample.log` run (three
// players, their heartbeats, error lines and F9 reports, a banked run, the probes). Regenerate it the same
// way when the log's shape changes.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fetchLogs, groupKey, parseLog, summarize } from './night_logs.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fixture = readFileSync(join(resolve(here, '..'), 'tests', 'night', 'net_local_sample.log'), 'utf8');
let passed = 0;
const it = (what, fn) => {
  fn();
  passed += 1;
  console.log(`PASS  ${what}`);
};

it('the fixture is a real night: joins, heartbeats, errors, reports, a run, leaves, tick lines', () => {
  const { events } = parseLog(fixture);
  for (const ev of ['start', 'join', 'hb', 'clog', 'report', 'run', 'game', 'runEnd', 'leave', 'tick', 'refused']) {
    assert.ok(events.some((e) => e.ev === ev), `no ${ev} line`);
  }
  assert.ok(!fixture.includes('test-passphrase'), 'the passphrase is in the fixture');
});

it('the summary names the players, groups the error, prints every F9 report in full', () => {
  const { summary, lines } = summarize(fixture);
  const text = lines.join('\n');
  assert.ok(summary.players >= 3, `players: ${summary.players}`);
  for (const n of ['A', 'B', 'C']) assert.match(text, new RegExp(`^  ${n}: 1 session`, 'm'));
  const g = summary.clientErrors.find((x) => x.example.includes('net_local test error'));
  assert.ok(g, 'the players\' error line is grouped');
  assert.equal(g.count, 3);
  assert.deepEqual([...g.players].sort(), ['A', 'B', 'C']);
  const f9 = summary.reports.filter((r) => r.kind === 'rep');
  assert.equal(f9.length, 3);
  assert.ok(f9.every((r) => r.missing === 0 && r.text.startsWith('player pressed F9 at ')));
  assert.match(text, /== F9 reports \(3\)/);
  assert.match(text, /run 1 at .*banked/);
  assert.match(text, /== Server tick cost\n {2}\d+ lines/);
});

it('made-up trouble: a crash tail in two parts (out of order), server errors grouped, a dropped connection', () => {
  const at = (s) => `2026-11-20T21:${s}Z`;
  const line = (o) => `2026-11-20T21:00:00.000000000Z ${JSON.stringify({ gd: 1, night: 'n1', ...o })}`;
  const log = [
    line({ t: at('00:00'), ev: 'start', build: 'abc1234567', port: 4450 }),
    line({ t: at('00:01'), ev: 'join', id: 'c1', name: 'Dee', build: 'abc1234567', addr: '0f0f0f0f' }),
    line({ t: at('00:02'), ev: 'report', id: 'c1', kind: 'crash', rid: 1, part: 1, parts: 2, body: 'second half' }),
    line({ t: at('00:02'), ev: 'report', id: 'c1', kind: 'crash', rid: 1, part: 0, parts: 2, body: 'the session before this one did not end cleanly\nfirst half' }),
    line({ t: at('00:03'), ev: 'serr', kind: 'script', text: 'Invalid access to index 12 (res://sim/run.gd:812 _step)' }),
    line({ t: at('00:04'), ev: 'serr', kind: 'script', text: 'Invalid access to index 13 (res://sim/run.gd:812 _step)' }),
    line({ t: at('00:05'), ev: 'clog', id: 'c1', line: 'disc connection closed: code 1006, after mode game, place annex, depth 3, phase away' }),
    line({ t: at('00:06'), ev: 'leave', id: 'c1', name: 'Dee', code: 1006, reason: '', secs: 305 }),
    line({ t: at('00:07'), ev: 'dropped', id: 'c1', counts: { log: 4 } }),
    '{"gd":1,"t":"2026-11-20T21:00:08Z","ev":"clog","id":"c1","line":"cut off in the mid',
    'ERROR: Condition "p_index < 0" is true. Returning: nullptr',
  ].join('\n');
  const { summary, lines } = summarize(log);
  const text = lines.join('\n');
  const crash = summary.reports.find((r) => r.kind === 'crash');
  assert.equal(crash.text, 'the session before this one did not end cleanly\nfirst half\nsecond half');
  assert.equal(summary.serverErrors.length, 1, 'index 12 and index 13 are one error');
  assert.equal(summary.serverErrors[0].count, 2);
  assert.match(text, /Dee: 1006 dropped without a close/);
  assert.match(text, /Dee says \(sent on reconnecting\): connection closed: code 1006/);
  assert.match(text, /look like trouble \(1\)/);
  assert.match(text, /lines over the limit or not decoding \{"log":4\}/);
  assert.equal(groupKey('error 12 at 0x7ff3'), groupKey('error 9 at 0x1'));
});

it('only a plain USER@HOST is ever passed to ssh', () => {
  for (const bad of ['host', 'a;b@c', 'u@h; rm x', '-oProxyCommand=x@h', '-ofoo@h', 'u@-h', 'u@h x']) assert.throws(() => fetchLogs(bad), /not a USER@HOST/);
  assert.throws(() => fetchLogs('u@h', { container: 'x; y' }), /not a container/);
});

console.log(`${passed} passed, 0 failed`);
