// Verify both optional review packs with a Windows export where --main-pack is unavailable.
// Usage: node godot/tools/check_owner_review_export.mjs "path/to/Going Down.exe"
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { access, mkdtemp, readFile, rm, rmdir } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';

const exec = promisify(execFile);
assert.equal(process.platform, 'win32', 'Run this check with a Windows export on Windows');
assert.ok(process.argv[2], 'Pass the exported Windows executable');
const exe = resolve(process.argv[2]);
const folder = dirname(exe);
const logs = await mkdtemp(join(folder, 'review-check-'));

try {
  for (const [id, pack, scene] of [
    ['ward', 'WardReview.pck', 'ward_review.tscn'],
    ['crew23', 'Crew23Review.pck', 'review.tscn'],
  ]) {
    await access(join(folder, pack));
    const log = join(logs, id + '.log');
    const args = ['--headless', '--quit-after', '80', '--log-file', log, '--', 'owner_review=' + id];
    try {
      await exec(exe, args, { cwd: folder, timeout: 30000, windowsHide: true });
    } catch (error) {
      console.error(await readFile(log, 'utf8').catch(() => 'No Godot log written'));
      throw error;
    }
    const output = await readFile(log, 'utf8');
    assert.ok(output.includes('Owner review opened: ' + id + ' (res://' + scene + ')'), output);
    assert.ok(!output.includes('client ready in'), 'Review mode booted the ordinary game');
    assert.ok(!output.includes('SCRIPT ERROR:'), output);
    console.log('PASS exported ' + id + ' opened res://' + scene);
  }
} finally {
  for (const id of ['ward', 'crew23']) await rm(join(logs, id + '.log'), { force: true });
  // The directory was created by this invocation, and should now be empty.
  await rmdir(logs);
}
