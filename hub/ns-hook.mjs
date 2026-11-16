// A guard run by Claude Code before any agent is launched in this project (see .claude/settings.json).
// It refuses a brief that does not show the design was checked: the brief must contain a section
// "What the North Star says" (paste the output of `node hub/ns.mjs find ...` under it), or the line
// "North Star: not applicable" followed by a reason (tooling, a blind judge, a web lookup).
// Reads the tool call as JSON on stdin; prints a deny decision, or nothing to let the call through.
import { readFileSync } from 'node:fs';

let input = {};
try { input = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { process.exit(0); }
const name = input.tool_name ?? '';
if (name !== 'Agent' && name !== 'Task') process.exit(0);

const ti = input.tool_input ?? {};
const type = String(ti.subagent_type ?? '');
// Utility agent types that never carry a design brief.
if (['web-fetch', 'claude-code-guide', 'statusline-setup'].includes(type)) process.exit(0);

const prompt = String(ti.prompt ?? '');
const cites = /what the north star says/i.test(prompt);
const optOut = /north star:\s*not applicable\b[^\n]{3,}/i.test(prompt);
if (cites || optOut) process.exit(0);

console.log(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      'This brief does not show the design was checked. Run `node hub/ns.mjs find <ids or words>` and paste what it prints into the brief under a heading "What the North Star says" (and say where the owner has since changed it). If the design has nothing on this (tooling, a blind judge, a lookup), add the line "North Star: not applicable" followed by the reason.',
  },
}));
