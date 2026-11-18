import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
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
  console.log('Tracker agent checks passed, including concurrent starts and handoff.');
} finally {
  await rm(root, { recursive: true, force: true });
}
