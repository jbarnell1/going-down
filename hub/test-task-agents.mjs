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

  // A linked start calls the North Star helper while it holds the write lock.
  // Keep the helper blocked on stdin so we can kill the holder before any save.
  await writeFile(path.join(root, 'hub', 'ns.mjs'), `
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
  console.log('Tracker agent checks passed, including concurrent starts, handoff, and recovery after a writer is killed.');
} finally {
  await rm(root, { recursive: true, force: true });
}
