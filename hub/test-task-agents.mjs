import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { promisify } from 'node:util';

// Exercise the real CLI in an isolated copy. Nothing here updates the live tracker.
const exec = promisify(execFile);
const root = await mkdtemp(path.join(tmpdir(), 'going-down-tracker-'));
const tracker = path.join(root, 'hub', 'track.mjs');
const state = path.join(root, 'loop', 'state.json');
const env = { ...process.env };
for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CODEX_THREAD_ID']) delete env[k];
const run = (args, session = {}) => exec(process.execPath, [tracker, ...args], { env: { ...env, ...session } });
const tasks = async () => (JSON.parse(await readFile(state, 'utf8'))).tasks;
const task = async (id) => (await tasks()).find((t) => t.id === id);
const ns = path.join(root, 'hub', 'ns.mjs');
try {
  await mkdir(path.dirname(tracker));
  await mkdir(path.dirname(state));
  await copyFile(new URL('./track.mjs', import.meta.url), tracker);
  const fixture = ['A', 'B', 'C'].map((id) => ({ id, title: id, status: 'todo', ns: [] }));
  await writeFile(state, JSON.stringify({ tasks: fixture, gates: [], decisions: [], feed: [] }));
  await Promise.all([
    run(['start', 'A', 'Building'], { CODEX_THREAD_ID: 'test' }),
    run(['start', 'B', 'Checking'], { CLAUDECODE: '1' }),
    run(['start', 'C', 'Reviewing']),
  ]);
  const [a, b, c] = await tasks();
  assert.deepEqual([a.agent, b.agent, c.agent], ['OpenAI Codex', 'Claude', undefined]);
  await run(['assign', 'C', '--agent', 'claude']);
  assert.equal((await tasks())[2].doingAt, c.doingAt);
  await assert.rejects(run(['assign', 'C', '--agent', 'typo']));
  await run(['start', 'A', 'Taking over', '--agent', 'claude'], { CODEX_THREAD_ID: 'test' });
  assert.equal((await tasks())[0].agent, 'Claude');
  await run(['wait', 'A', 'Review']);
  await run(['start', 'A', 'Resuming']);
  assert.equal((await tasks())[0].agent, undefined);
  await run(['done', 'B', '--summary', 'Checked']);
  assert.equal((await tasks())[1].agent, 'Claude');

  // Existing tasks without reservations are free. A named reservation never supplies the identity
  // of an active worker, and records who can resume it across independent CLI calls.
  await mkdir(path.join(root, 'docs'));
  await writeFile(path.join(root, 'docs', 'north-star.html'), '<h3>Test mechanics</h3><article class="mech" data-tier="core"><h4>H1. A mechanic</h4><p>A place to start.</p></article>');
  await copyFile(new URL('./ns.mjs', import.meta.url), ns);
  await run(['add', 'D', 'Reserved work', '--for', 'claude', '--ns', 'H1']);
  await run(['add', 'E', 'Free work', '--for', 'free', '--ns', 'H1']);
  await assert.rejects(run(['add', 'F', 'Bad owner', '--for', 'typo']), /--for must be/);
  await assert.rejects(run(['reserve', 'E']), /--for must be/);
  assert.equal((await task('D')).reservedFor, 'claude');
  assert.equal((await task('D')).agent, undefined);
  assert.equal((await task('E')).reservedFor, undefined);
  const beforeWrongStart = await readFile(state, 'utf8');
  await assert.rejects(run(['start', 'D', 'Wrong agent'], { CODEX_THREAD_ID: 'test' }), /reserved for Claude/);
  await assert.rejects(run(['start', 'D', 'Unknown agent']), /reserved for Claude/);
  assert.equal(await readFile(state, 'utf8'), beforeWrongStart);
  await run(['start', 'D', 'Working'], { CLAUDECODE: '1' });
  assert.equal((await task('D')).agent, 'Claude');
  await assert.rejects(run(['assign', 'D', '--agent', 'openai']), /reserved for Claude/);
  await assert.rejects(run(['reserve', 'D', '--for', 'openai']), /active with Claude/);
  await assert.rejects(run(['reserve', 'A', '--for', 'openai']), /unreported agent/);

  const show = (await run(['show'])).stdout;
  const progress = await readFile(path.join(root, 'loop', 'PROGRESS.md'), 'utf8');
  for (const view of [show, progress]) {
    assert.match(view, /Reserved work · In progress with Claude · Reserved for Claude/);
    assert.match(view, /Free work · Free for either agent/);
    assert.match(view, /Completed by Claude/);
  }
  const lookup = (cmd) => exec(process.execPath, [ns, cmd, 'H1'], { env });
  const shown = (await lookup('show')).stdout;
  await lookup('index');
  const index = await readFile(path.join(root, '.local', 'north-star-index.md'), 'utf8');
  for (const view of [shown, index]) {
    assert.match(view, /D \(in progress with Claude, reserved for Claude\)/);
    assert.match(view, /E \(free for either agent\)/);
  }

  await run(['wait', 'D', 'Review']);
  assert.equal((await task('D')).reservedFor, 'claude');
  assert.equal((await task('D')).agent, undefined);
  assert.match((await lookup('show')).stdout, /D \(reserved for Claude, waiting\)/);
  await assert.rejects(run(['start', 'D', 'Wrong resume', '--agent', 'openai']), /reserved for Claude/);
  await run(['start', 'D', 'Resumed', '--agent', 'claude']);
  const resumedAt = (await task('D')).doingAt;
  await run(['reserve', 'D', '--for', 'free']);
  assert.equal((await task('D')).reservedFor, undefined);
  assert.equal((await task('D')).agent, 'Claude');
  assert.equal((await task('D')).doingAt, resumedAt);
  await run(['assign', 'D', '--agent', 'openai']);
  await run(['reserve', 'D', '--for', 'openai']);
  await run(['done', 'D', '--summary', 'Checked', '--ns', 'Matches H1']);
  assert.equal((await task('D')).reservedFor, undefined);
  assert.equal((await task('D')).agent, 'OpenAI Codex');
  assert.match((await lookup('show')).stdout, /D \(done by OpenAI Codex\)/);

  await run(['reserve', 'E', '--for', 'openai']);
  await run(['start', 'E', 'Started', '--agent', 'openai']);
  await run(['blocked', 'E', 'Needs a decision']);
  assert.equal((await task('E')).agent, undefined);
  assert.equal((await task('E')).reservedFor, 'openai');
  await run(['unblock', 'E']);
  assert.match((await lookup('show')).stdout, /E \(reserved for OpenAI Codex\)/);

  // A linked start calls the North Star helper while it holds the write lock.
  // Keep the helper blocked on stdin so we can kill the holder before any save.
  await writeFile(ns, `
    if (process.argv[2] === 'ids') {
      console.log('H1');
    } else {
      process.stdin.resume();
      console.log('holding tracker lock');
    }
  `);
  await run(['link', 'C', 'H1']);
  const holder = spawn(process.execPath, [tracker, 'start', 'C', 'Interrupted'], {
    env, stdio: ['pipe', 'pipe', 'inherit'],
  });
  const exited = once(holder, 'exit');
  const closed = once(holder, 'close');
  const output = createInterface({ input: holder.stdout });
  try {
    assert.deepEqual(await once(output, 'line', { signal: AbortSignal.timeout(5000) }), ['holding tracker lock']);
    assert.ok(holder.kill('SIGKILL'));
    assert.deepEqual(await exited, [null, 'SIGKILL']);
    assert.equal((await tasks())[2].doingText, 'Reviewing');
    await run(['assign', 'C', '--agent', 'openai']);
    assert.equal((await tasks())[2].agent, 'OpenAI Codex');
  } finally {
    holder.stdin.end();
    if (!holder.killed) holder.kill('SIGKILL');
    await closed;
  }
  console.log('Tracker checks passed for reservations, concurrent starts, handoffs and recovery after a writer is killed.');
} finally {
  await rm(root, { recursive: true, force: true });
}
