// Refuses a commit that looks like it contains a secret or a machine-specific detail.
// Run by the pre-commit hook on staged files, or by hand: `node hub/scan-secrets.mjs --all`.
// It is a tripwire, not a guarantee. The gitleaks workflow scans every push as well.
import { execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';

const all = process.argv.includes('--all');
const git = (...a) => execFileSync('git', a, { encoding: 'utf8' });
const files = (all ? git('ls-files') : git('diff', '--cached', '--name-only', '--diff-filter=ACMR'))
  .split('\n').map((s) => s.trim()).filter(Boolean);

const RULES = [
  ['private key block', /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ['ElevenLabs key', /\bsk_[a-f0-9]{40,}\b/i],
  ['Google API key', /\bAIza[0-9A-Za-z_-]{35}\b/],
  ['GitHub token', /\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b/],
  ['OpenAI or Anthropic style key', /\bsk-(ant-|proj-)?[A-Za-z0-9_-]{32,}\b/],
  ['AWS access key', /\bAKIA[0-9A-Z]{16}\b/],
  ['key assigned a literal value', /\b[A-Z0-9_]*(API_KEY|SECRET|TOKEN|PASSWORD)\s*[=:]\s*["']?[A-Za-z0-9_\-/+]{20,}/],
  ['tailnet hostname', /\b[a-z0-9-]+\.ts\.net\b/i],
  ['home directory path', /[A-Za-z]:\\Users\\[^\\\s"']+/],
  ['path into another project', /[A-Za-z]:\\(BuoyAI|yt_scripture|scripture|watchman|doc_keeper|Listener|fittle|homelab)/i],
  ['email address', /\b[A-Za-z0-9._%+-]+@(gmail|outlook|hotmail|yahoo|icloud|proton)\.[a-z.]+\b/i],
];
const FORBIDDEN_NAMES = [/(^|\/)\.env(\..*)?$/, /(^|\/)\.local\//, /\.(pem|key|pfx|p12)$/i];
const SKIP_CONTENT = /\.(png|jpe?g|webp|glb|bin|mp3|ogg|wav|woff2?|ico|blend)$/i;
const SELF = 'hub/scan-secrets.mjs';

const hits = [];
for (const f of files) {
  if (FORBIDDEN_NAMES.some((r) => r.test(f))) { hits.push(`${f}: this kind of file must never be committed`); continue; }
  if (f === SELF || SKIP_CONTENT.test(f)) continue;
  let text;
  try {
    if (statSync(f).size > 2_000_000) continue;
    text = all ? readFileSync(f, 'utf8') : git('show', `:${f}`);
  } catch { continue; }
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    for (const [name, re] of RULES) if (re.test(lines[i])) hits.push(`${f}:${i + 1}: looks like a ${name}`);
  }
}

if (hits.length) {
  console.error('Commit blocked. Possible secrets or private details:\n  ' + hits.join('\n  '));
  console.error('Move the value to .local/ (never committed) or remove it. Values are not printed here on purpose.');
  process.exit(1);
}
console.log(`secret scan: ${files.length} file(s) clean`);
