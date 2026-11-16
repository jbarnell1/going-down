// Writes a .br and a .gz copy beside each compressible file of a browser build, so the hub (and
// later the public door) can send the small copy. Run it after every export:
//   node hub/precompress.mjs <build folder>
// A copy is only written when it saves at least 5%, and is skipped when it is already newer than
// its file. The hub ignores a copy that is older than its file, so a forgotten run costs speed, never
// correctness.
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import zlib from 'node:zlib';

const dir = process.argv[2];
if (!dir) { console.error('usage: node hub/precompress.mjs <build folder>'); process.exit(2); }
const KINDS = new Set(['.wasm', '.pck', '.js', '.html', '.json', '.mjs', '.css', '.svg']);
const brotli = promisify(zlib.brotliCompress);
const gzip = promisify(zlib.gzip);
const mb = (n) => (n / 1048576).toFixed(2);

let raw = 0, best = 0;
for (const name of (await fs.readdir(dir)).sort()) {
  const file = path.join(dir, name);
  const st = await fs.stat(file);
  if (!st.isFile() || !KINDS.has(path.extname(name).toLowerCase()) || st.size < 1024) {
    if (st.isFile() && !/\.(br|gz)$/i.test(name)) { raw += st.size; best += st.size; }
    continue;
  }
  raw += st.size;
  let smallest = st.size;
  const data = await fs.readFile(file);
  for (const [ext, pack] of [
    ['.br', (d) => brotli(d, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_LGWIN]: 24, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: d.length } })],
    ['.gz', (d) => gzip(d, { level: 9 })],
  ]) {
    const out = file + ext;
    const old = await fs.stat(out).catch(() => null);
    if (old && old.mtimeMs >= st.mtimeMs) { smallest = Math.min(smallest, old.size); continue; }
    const t0 = Date.now();
    const packed = await pack(data);
    if (packed.length > st.size * 0.95) { await fs.rm(out, { force: true }); continue; }
    await fs.writeFile(out, packed);
    smallest = Math.min(smallest, packed.length);
    console.log(`${name}${ext}  ${mb(st.size)} -> ${mb(packed.length)} MB  (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
  }
  best += smallest;
}
console.log(`whole build: ${mb(raw)} MB as it is, ${mb(best)} MB sent compressed`);
