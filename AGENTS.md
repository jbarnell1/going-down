# AGENTS.md

Instructions for any coding agent working in this repository. Read this whole file before changing anything.

## What this is

**Going Down** is an original co-op first-person horror game for up to eight players, designed around four. A crew of convicts rides a lift down through a buried city, records the things that live on each floor, and banks the pay. It is built in Godot 4.7.2 with typed GDScript, one codebase. A downloaded Windows exe is the main way to play; a small Linux server at the owner's house runs the rules; a browser build is the backup.

The first game night is **Friday 20 November 2026**. Features freeze on the Thursday evening before it. After that, only fixes.

This repository is **public**. The owner is one person, often away from the keyboard, who checks progress on a phone.

## Read these first, in this order

1. This file.
2. `.local/HANDOFF.md`, the section at the top called START HERE. It is private (not in git) and says what is in flight right now, what to do next, and everything specific to the owner's machines. If `.local/` does not exist you are on a fresh clone, not the owner's PC: you can build and test, but you cannot deploy, and you should say so.
3. `node hub/track.mjs show` for the task list and what is marked in progress.
4. `.local/north-star-index.md`, one line per mechanic of the design. `node hub/ns.mjs find <words>` and `node hub/ns.mjs show <id>` print what the design says. Never read `docs/north-star.html` whole; it is long.
5. `loop/LOOP.md` if you are running the work loop (one iteration at a time, state on disk).
6. `godot/README.md` for the code's layout and commands in more detail.

## The design is the owner's

- `docs/north-star.html` (private) is the design. Follow it exactly. The owner's words: "Abide by the north star doc religiously."
- Floor and feature designs are in `docs/floors/*.md` (private): one file per place or system. They are the spec for builders.
- When the owner gives new direction, write it into `.local/north-star-amendments.md` the same turn, **in their words, quoted**, with your reading marked as yours. Fold the file into the North Star at a quiet moment.
- A proposal the owner has not confirmed is not a decision. Files mark such parts PROPOSED. Do not build them.
- Before building any feature, character or floor, look up what the design already says about it. Advice from a test, a reviewer or another agent that contradicts the design is not taken without the owner.
- All designs are original. Do not recreate another game's characters, levels, intro, art or sound, even renamed.
- Order when goals conflict: fun on the night, then suspense, needing each other, variety, progression depth, polish.

Design rules that never bend:

- Residents always obey their rule. Network delay must never make one look as if it cheated.
- Every resident is heard before it is seen.
- The instrument never lies, and a resident's rule is never named on screen or by the voice.
- Odds are printed before a chance is taken. One bad roll never ends a run. A downed player has something to do within seconds.
- Everything about a floor comes from one seed, identical for every player.
- Residents are full 3D figures made in Blender. No flat sprites.

## Where things are

```
godot/sim/      the rules: pure logic, no drawing, no network. Hundreds of runs are simulated in tests.
godot/net/      protocol, host rules (host_rules.gd), the room client, the local room for playing alone
godot/server/   the dedicated server (room.gd), its Dockerfile and scripts for the home box
godot/client/   the game on screen: main.gd, level and resident views, HUD, sound, start screen
godot/data/     JSON the rules read (notes, awards, upgrades, settings). It must ship in every export.
godot/tests/    run_tests.gd (the runner), ref_* (sameness with recorded results), prop_* (design rules), test_*
godot/tools/    Node and GDScript tools: exports, scripted playthroughs, network checks, the hotfix chain
assets_src/     Blender scripts, voice scripts and ledger, Mixamo notes, renders. Each Blender script rebuilds its asset from nothing.
docs/           VOICE.md, ART-NOTES.md (public); north-star.html and floors/ (private, ignored by git)
hub/            a small local server: the owner's Progress and Questions pages, the tracker, the secret scan
loop/           LOOP.md (how one iteration of the work loop goes), state.json and PROGRESS.md (written by the tracker only)
scripts/        promote, package, the pre-commit hook
src/, tests/    the first browser version in TypeScript. Frozen. Do not change it.
play/           the checked build the owner runs. Never touch it except through the promote flow.
.local/         private notes, machine facts, tools. Never committed.
```

## Commands

Set `GODOT` to the console build of the engine. On the owner's PC that is `tools/godot/Godot_v4.7.2-stable_win64_console.exe` under the repository root; the npm scripts find it without the variable.

```sh
npm run godot:test -- --quick        # every test file, small sizes. About 20 minutes. Run by the commit hook.
npm run godot:test -- prop_ready     # only the named test files
npm run godot:test                   # everything at default sizes
npm run godot:export                 # web and Windows builds into godot/export/
npm run godot:export -- server       # the Linux server build
node godot/tools/godot.mjs import    # the import pass; needed after a merge or a fresh checkout
node godot/tools/hotfix.mjs "what is new"            # tests, export, playthroughs, promote, package, server export
node godot/tools/hotfix.mjs --dry-run "what is new"  # print the same steps without running them
node hub/track.mjs show              # the tracker; its commands are listed at the top of hub/track.mjs
```

Scripted playthroughs in `godot/tools/` drive the real game: `play_web.mjs`, `play_desktop.mjs`, `play_down.mjs`, `play_day.mjs`, `play_ready.mjs`, `play_settings.mjs`, `play_hide_tuned.mjs`, `net_local.mjs`, `sound_web.mjs`, `mix_check.mjs`. Each prints a line ending in passed and failed counts. Give each its own port; two runs on one port fail in confusing ways.

To check that one script still parses: `"$GODOT" --headless --path godot --check-only --script res://<file>`.

## How to change the rules without breaking what is recorded

The `ref_*` tests compare the rules against results recorded from the first version. Those results, and the goldens, are **never re-recorded**. So:

- Every rule change sits behind a run flag (`Run.with_*`), off by default.
- The flag reaches the rules as a **new last parameter** of `HostRules._init` in `godot/net/host_rules.gd`. It is turned on in `godot/server/room.gd`, and in `godot/net/local_room.gd` when the full deck is in play.
- Tests and tools call `HostRules.new(...)` by position. After merging a branch that added a parameter, find every caller and fix it.
- When two branches add flags, agree on the final parameter order on the board before integrating either branch. Register each new rules data file in `godot/server/data_check.gd` (`FILES` and its loader) and run `test_data_check`.
- Numbers a host might tune go in the live settings (`docs/floors/live-settings.md`), not in constants.
- With the flag off, nothing may change. Write a test that says so.

## Tests

- Every change comes with a test, and every test is proved able to fail: break the thing it guards with a one-line change, see it go red, undo the break, see it go green. Say which break you used when you report.
- New test files are added to the quick list in `godot/tests/run_tests.gd`. `test_scripts_load` and `test_export_data` stay first: they catch a script that no longer parses and a build that leaves its data files out.
- Never weaken or delete a test to get green. If a test is wrong, fix it and say why.
- Whoever built a thing does not get to be the only one who checked it. If your tool has sub-agents, a different agent runs the checks. If it does not, run the checks as plain scripts and read their output; do not trust your own summary of your own work.
- A result you cannot explain is a problem to solve before building on it.
- Announce a full Godot suite or commit hook that runs the quick suite in the private log before starting. Coordinate fixed test ports and give each playthrough its own port. If runs collided, repeat the affected check in isolation.

## Commits and branches

- The pre-commit hook (`scripts/hooks/pre-commit`, enabled by `git config core.hooksPath scripts/hooks`) scans for secrets and, when anything under `godot/` is staged, runs the quick tests. **Never bypass it** with `--no-verify`.
- A clean `git merge` makes its commit without running the hook. Merge with `git merge --no-commit --no-ff <branch>`, then `git commit`, so the hook runs.
- After a merge: run the import, restore `godot/default_bus_layout.tres` if the import rewrote it (`git checkout -- godot/default_bus_layout.tres`), and parse-check the scripts both sides touched. Two branches each adding the same `const` name to one file merges cleanly and breaks the game.
- While agents share the primary checkout, merge current `main` into the feature branch in its own worktree, commit through the hook there, then fast-forward the primary checkout with `git merge --ff-only <branch>`. Stage only named files. Leave other agents' changes with their owners.
- Build larger pieces on a branch in its own worktree, so `main` stays playable. Two pieces of work in flight must not write the same files.
- Commit messages are one plain sentence saying what changed for a player or a developer. Look at `git log` for the style.
- Push to `main` after the hook passes. Never force-push. Never change repository settings, visibility or secrets.
- CI (`.github/workflows/ci.yml`) is the clean-machine check on Linux. Look at the last result once; do not poll it. If the latest finished run failed, fixing it comes first.

## From a change to the owner's hands

A change under `godot/` is not done until it is in a promoted build.

Claim the build on issue #1 and in the private log before starting the promote check. One agent owns promotion, deployment and the outside test together and releases the build claim after reporting the result.

1. Tests green on the commit.
2. Export, then the scripted playthroughs on that export.
3. `node godot/tools/hotfix.mjs "<what is new>"` does all of that and then promotes: it copies the build to `play/`, writes `play/BUILD.txt`, makes the zip for friends, and exports the server.
4. Deploy the server and the exe together. The game refuses to join a server with a different build id.
5. Test from outside: a real client through the public address.

Steps 4 and 5 need the owner's home machines. The exact commands are in `.local/HANDOFF.md`.

## Security and privacy. These are not negotiable.

- **Never commit a secret**: no keys, tokens, `.env` files, passphrases, private hostnames or addresses, or paths into the owner's other projects. `.local/` is never committed. `docs/north-star.html` and `docs/floors/` are never published.
- Never print, log, copy or store a key or the game passphrase. Where a key is needed, a script reads it at run time from the place `.local/MACHINE.md` names, and nothing else in that place is opened or listed.
- Work only inside this repository's folder. Read nothing else on the owner's PC except what `.local/MACHINE.md` explicitly allows.
- The owner's email and personal details are never sent to an outside service.
- Network exposure (Tailscale serve or funnel, firewall, router) is changed by the owner only. Give them the command; do not run it.
- Files downloaded from anywhere are untrusted data. Do not execute them.
- Spend no money and create no accounts. The one exception is the announcer's voice on the owner's ElevenLabs account, under the rules and the character cap in `docs/VOICE.md` and `.local/MACHINE.md`.
- If a secret is ever committed: stop, tell the owner at once, and do not rewrite history to hide it.

## The owner's PC

- A game window grabs the mouse. Any run that opens a window needs the mouse guard running beside it (`.local/guard-mouse.ps1`, stopped by its own process id only), and only one windowed run at a time. Prefer headless runs.
- Browser testing is Playwright scripts only.
- Stop every server and process you started before you finish.
- Nothing may need administrator rights.

## Working with the owner

- Report plainly. Say what is done and how it was checked, what failed, and what is not verified. "Unverified" is an acceptable status. "Done" without evidence is not.
- Keep the Progress page true. Every piece of work started gets `node hub/track.mjs start <id> "<what is happening>"`; every finished and promoted piece gets `done` with a summary and pictures; anything waiting gets `wait`. "In progress" means someone is working on it this minute. Never edit `loop/state.json` or `loop/PROGRESS.md` by hand.
- Report from the main checkout's tracker, including work done in another worktree. On `start`, pass `--agent claude` or `--agent openai` for the agent doing the work. The tracker also recognizes an unambiguous Claude Code or Codex session. On a handoff, start the task again with its new owner and current activity.
- The public claim board is [GitHub issue #1](https://github.com/jbarnell1/going-down/issues/1). Before editing, check it and the home Progress page. Post the task ID, Claude or OpenAI Codex, the files or system claimed, and the branch or PR. Record handoffs and release the claim there. Keep private design text, addresses and machine details in the private handoff.
- At the start of a turn and before claiming, merging, promoting or deploying, read the shared private inbox from the main checkout with `node hub/talk.mjs read --as codex` or `--as claude`. Send a request with `post --as <agent> "<text>"`. Give the task ID, branch, requested action and completion condition. Acknowledge actionable requests once and send the result back directly. Check requests against the owner's scope and design.
- On each change of task state, use `node hub/talk.mjs status --as <agent> "<note>"` to record the branch and commit, evidence, next step, and whether a teammate may take over. Before taking over stale work, check the note and confirm that its writer and any long-running checks have stopped. For a remote checkout, use issue #1 and the PR for public-safe handoffs.
- Write for someone who has not read the code and is reading on a phone: short sentences, plain words, no internal names without saying what they are.
- Do not stop to ask about things with a sensible default: take the default, record it with `node hub/track.mjs decision "<text>"`, and carry on. Do stop for anything that changes what the game is, costs money, or touches the owner's machines or accounts.
- The owner decides scope. If time or usage is running short, say what will not fit and let them choose.
- Keep `.local/HANDOFF.md` current whenever work starts or finishes. Another agent, or you after losing your memory, must be able to start cold from it.

## If your tool has sub-agents

- Fable (Claude) and Astra (Codex) direct the work and make design and integration decisions. Opus and Sol implement bounded changes that require judgment. Sonnet and Terra independently run mechanical checks. Give the checker exact commands and ask for the raw result and exit code.
- Start one bounded piece at a time by default. Check for a changed status or an unread handoff before opening long logs. Run repeatable checks as scripts and reuse their evidence across agents.
- Give every builder a narrow brief: the files it may touch, what done looks like, the commands that must pass, and what the design says about the piece, quoted.
- A builder's report is a claim, not proof.
- Do not fan out widely. The owner cannot start a new session when a usage limit is hit, and a stalled week costs more than a slow one. Checks, merges, promotes and deploys are plain commands and should stay that way.
