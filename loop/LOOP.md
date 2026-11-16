# Going Down: the work loop

Start it by typing this in the session's message box:

    /loop Read C:\new_game\loop\LOOP.md and carry out one iteration exactly as it says.

Whoever runs this loop is the orchestrator (see "Who does what" below). Each time this fires, do ONE iteration, then schedule the next. All state is on disk in this folder, so an iteration must work even if you remember nothing of the last one.

## Who does what (the owner's rule from 16 November 2026)

The owner's words: "For mechanical checks like joining a game let's use sonnet agents from now on to save tokens. We will move to using an opus agent soon for this whole thing, fable will only design floors and architecture from here on out. Opus will be orchestrator and agent, and sonnet will be mechanical."

- **Sonnet agents (`model: "sonnet"`) do the mechanical checks.** Re-running a test suite, an export, a playthrough or a sound check; applying a deliberate break from an exact one-line instruction, running the named test, and undoing it; fetching a build from the lab box; reading logs. The brief gives the exact commands and asks for the raw summary lines and exit codes back, nothing interpreted. The orchestrator reads those lines and decides. It does not re-run the commands itself.
- **Opus agents (`model: "opus"`) build.** Soon an Opus session also runs this loop as the orchestrator. `loop/LOOP.md`, `.local/HANDOFF.md`, `.local/north-star-index.md` and the tracker hold everything it needs to start cold.
- **Fable designs.** Floors, mechanics, the North Star and architecture decisions. Ask Fable when a choice changes what the game is or how its parts fit; do not ask it to run checks.
- **Since 16 November about 17:15 this loop is run by an Opus session**, in the owner's words: "go ahead and start parallelizing our work flow to get further. Use sonnet 5.5, no more than 5 agents at a time. Opus for harder tasks and only 3 at a time. Abide by the north star doc religiously." So: up to 5 Sonnet agents and up to 3 Opus agents at once (count the ones already running); agents that run together must never write the same files (give one a worktree, `isolation: "worktree"`, when their files could overlap); Fable agents only for designing floors and architecture.
- An agent's report is still a claim, not proof: a builder's work is checked by a different agent (a Sonnet checker), never by itself. A check that cannot fail proves nothing: every gate still needs a deliberate break.

## One iteration

0. If `.local/HANDOFF.md` exists and you do not remember its contents, read it first: it holds what was in flight (running agents, what to check when they report, lessons learned) when the conversation was last compacted. Keep it current whenever an agent is started or finishes.
0. First iteration only: write the start time into PROGRESS, and ask the app to keep this PC awake if that tool is available.
1. Run `node hub/track.mjs show` for the short status (iteration, current task, task list). Read `loop/PROGRESS.md` only when you need a task's evidence, to-do list or the decisions. Then `node hub/track.mjs iteration`. Read `loop/ENDPOINT.md` only when picking a task or closing a gate. Never read `docs/north-star.html` whole; grep for the mechanic you need (ids like `A2.`, `B8.`, `id="fairness"`).
   - Read `.local/answers.json` if it exists. For any answer newer than "answers applied to" in the tracker's status, act on it: update the task list, the gates or the code plan, and log what changed. The owner's free text counts as much as the options they ticked.
   - Look at the last CI result once with `gh run list --branch main --limit 3 --json name,conclusion,headSha,status`. Do not wait on it or poll it. If the latest finished run failed, fixing it is this iteration's task.
     Record it with `node hub/track.mjs ci passed|failed <commit>` ONLY from what that command printed in this iteration, for the commit it printed. A run that is still in progress is not a result; never record one from memory or expectation. Frame-time and other timing checks cannot pass on CI's software renderer: guard them with `process.env.CI`, and keep the public play link in mind, because it only updates when CI is green.
   - If the hub is not answering on its port (see `.local/MACHINE.md`), restart it with `hub/start-hub.ps1`.
2. Check the stop conditions below. If one is met, do what it says and stop.
3. **North Star check, before any brief is written.** Read `.local/north-star-index.md` (one line per mechanic; regenerate with `node hub/ns.mjs index`). For the task you are about to take, run `node hub/ns.mjs find <ids or plain words>` and read what the design already decided. `track.mjs start` refuses a task that is not linked (`track.mjs link <task> <ids>`, or `link <task> none --why "..."`) and prints the linked mechanics; paste that text into the agent's brief under "What the North Star says", and say in the brief where the owner has since changed it. `track.mjs done` prints it again and needs `--ns "<how the result matches, or where it differs on purpose and who decided>"`. The same check applies before acting on a judge's or an agent's suggestion: advice that contradicts the design is not taken without the owner.
   - A guard in `.claude/settings.json` (`hub/ns-hook.mjs`) refuses to launch any agent whose brief lacks a "What the North Star says" heading. For a brief the design truly has nothing on (tooling, a lookup, a blind judge who must be told nothing), write the line `North Star: not applicable` followed by the reason. Never use that line to skip the lookup for a feature, a character or a floor. A message that resumes a running agent is not checked by the guard, so apply the same rule to it by hand.
   - When the owner gives new design direction in chat or on the Questions page, add it in their words to `.local/north-star-amendments.md` the same turn. Once a day, at a quiet moment, fold the amendments into the North Star document (both copies, see the handoff note), publish the new draft, regenerate the index, and empty the file.
   - `node hub/ns.mjs coverage` lists first-playable mechanics no task covers. Read it whenever tasks are added or reordered, and never let the list shrink by forgetting: a mechanic leaves it only when a task is linked or the owner says it is out.
3. Take the first task in PROGRESS that is not `done`. If it is bigger than about an hour of work, split it into smaller tasks in PROGRESS first and take the first piece.
4. Do the task.
   - A handful of tool calls: do it yourself.
   - More than trivial: ONE Opus agent (`model: "opus"`) with a narrow brief: the files it may touch, what done looks like, and the exact commands that must pass. All Blender work goes to Opus.
   - Mechanical edits and lookups: a Sonnet agent (`model: "sonnet"`).
   - Several agents at once within the limits above, each with its own files. Never the Workflow tool.
5. Verify it, with a Sonnet checker for the mechanical part. A builder's report is a claim, not proof. Give a Sonnet agent the exact commands (for the Godot game: `npm run godot:test`, `npm run godot:export`, the playthroughs in `godot/tools/`, the sound check and its muted variant, one deliberate break with its exact line) and have it return the summary lines. Then look yourself at what a script cannot judge: open the screenshots and renders with the Read tool, and read the parts of the diff that guard a promise (fairness, the passphrase, anything in the North Star).
6. Mark the task done only with evidence, using the tracker: `node hub/track.mjs done <id> --summary "<what is now true and how you checked it, in plain words the owner can read on a phone>" --media <file>:"<caption>"` (repeat `--media` for each picture, map, model or audio file that proves it; the tracker keeps its own copy). A failing test is never "done". Never weaken or delete a test to get green; if a test is wrong, fix it and say why in the log.
7. **The Godot build the owner runs.** After any change under `godot/` passes its checks: `npm run godot:export` (builds into `godot/export/`), run the playthroughs on that build (`godot/tools/play_web.mjs`, `play_desktop.mjs`, the sound check), and only then `npm run godot:promote -- "what is new"`, which copies it to `play/GoingDown.exe` and `play/web/` (the hub's `/godot/`) and writes `play/BUILD.txt`. Never promote an unchecked build, and never report a Godot change as done before it is promoted. The Progress page shows the promoted build's time.
7. Commit with a plain one-sentence message that says what changed for a player or a developer, in the style of the owner's other repositories. Push to `main`. When everything is green, tag it `good-N` and run `npm run deploy:live`, which builds and copies the game into `.live/` for the hub to serve. The live link must always hold the newest green build and never a broken one.
8. Keep the tracker current at all times: the owner checks in through the Progress page ("Don't forget we have the web portal to keep updated at all times. I'll be using that to check in and track progress as well."). Every agent you start gets `start <id> "<what it is doing>"` the same turn (each task keeps its own line, so parallel work all shows), every report gets a `note` or `todo`, every verified result gets `done` with pictures. The tracker feeds the owner's Progress page and regenerates `loop/PROGRESS.md`. Never edit `loop/state.json` or `loop/PROGRESS.md` by hand. `start <id> "<what is happening>"` when a task begins. `media <id> <file>:"<caption>"` whenever there is something new worth seeing, even mid-task, so pictures appear as work happens and not only at the end. `gate <id> passed "<evidence>"`, `ci passed|failed <commit>`, `answers <time>`, `decision "<text>"`, `blocked <id> "<why>"`, `todo <id> "<text>"`, `add <id> "<title>" --why "<why a player cares>" --after <id>`, `note "<one line>"`. Commands are listed at the top of `hub/track.mjs`. Write every summary, caption and note for someone who has not read the code. When a gate is newly ticked, send the user the one screenshot or render that proves it (SendUserFile, proactive, one-line caption) and a push notification if that tool is available. Nothing is sent for ordinary tasks.
9. If a usage tool is available and this usage window is nearly spent, schedule the next iteration for after it resets instead of in a minute, and say so in the status block. Otherwise: Schedule the next iteration with ScheduleWakeup, passing the same prompt. Work remaining: 60 to 120 seconds. Waiting on a background agent or install: 1200 seconds or more as a fallback (you are re-invoked when it finishes). Set `noop: true` only if nothing changed.

## Stop conditions

- **Reached:** every gate in ENDPOINT.md is ticked with evidence and the final validation task is done. Write `loop/FINAL-REPORT.md`, send a push notification if that tool is available, then call ScheduleWakeup with `stop: true`.
- **Told to stop:** a file `loop/STOP` exists. Stop at once and say so in PROGRESS.
- **Out of time:** past the "Time limit" shown by `node hub/track.mjs show` (the owner moved it to game night, Friday 20 November 2026, on the Questions page; only the owner moves it, with `track.mjs deadline`). Write the report with what is and is not done, then stop.
- **Stuck:** the same task has failed in 3 iterations. Write it up under "Blocked" in PROGRESS and move to the next task that does not depend on it. If none is left, write the report, notify, and stop.

Never stop to ask a question. Add it to `loop/questions.json` (id, title, context, type `single`, `multi` or `text`, options, default), take the default, record it with `node hub/track.mjs decision "<text>"`, and carry on. The owner answers on the hub's Questions page whenever they check in.

## Rules that do not bend

- Work only inside this repository's folder. Read nothing else on this PC except what `.local/MACHINE.md` explicitly allows. That file is not in git and holds everything specific to this machine: where keys live, the live link, ports.
- **This repository is public. Never commit a secret.** No keys, tokens, `.env` files, private hostnames, or paths into the owner's other projects. `.local/` is never committed. The pre-commit hook runs `node hub/scan-secrets.mjs`; never bypass it with `--no-verify`. If a secret is ever committed, stop the loop, say so at the top of PROGRESS, and notify the user. Do not try to hide it by rewriting history.
- You may push to `main`, open pull requests and merge them. Push to `main` directly after a green `npm run check`. Use a branch and a pull request only for a sweeping or risky change. Never force-push. Never change repository settings, visibility, or secrets.
- Spend no money and create no accounts. One exception: the elevator voice uses the owner's ElevenLabs account. Follow `docs/VOICE.md` and `.local/MACHINE.md` exactly, never print or copy the key, and stay under the character cap.
- The only public surface is the GitHub repository. Do not turn on GitHub Pages or any public hosting unless the answer to the `public-play-link` question says yes.
- Installs allowed: npm packages inside the project, Playwright's Chromium, and `uvx yt-dlp` (run on demand, nothing installed system-wide) to fetch a tutorial's captions and a low-resolution copy for sampling frames with ffmpeg. Tutorial downloads go in `.local/tutorials/`, are never committed, and are deleted once the notes are written. Blender 5.3.0 is already unpacked in `tools/blender/` (find `blender.exe` there; run it with `--background --python <script>`). Anything else: record it as a question and work around it. Nothing may need administrator rights; the user is often away and cannot click the prompt.
- Browser testing is Playwright scripts only. Never the built-in browser pane, never any `browser_batch` tool; they hang this session.
- Start servers in the background and stop every process you started before the iteration ends.
- **Prove a test can fail before trusting it.** Before ticking a gate, break the thing it guards on purpose with a one-line change (let the entity move while watched, drop a door, skip the stair), confirm the test goes red, then undo the break and confirm green. Say which break you used in the gate's evidence. Tests written by the same agent that wrote the code tend to confirm the code, so this check is Fable's, not the agent's.
- **Check reachability and anything "live" from somewhere else.** A page that loads from this PC proves nothing about other devices; test from a second tailnet device. A build that passes here proves nothing about a clean machine; read the CI result.
- If an agent or a test gives a result you cannot explain, find the cause before building on it.
- Report plainly. "Unverified" is an acceptable status. "Done" without evidence is not.

## Design rules (digest of the North Star)

- Order when goals conflict: fun on the night, then suspense, needing each other, variety, progression depth, polish.
- First-person. Up to 8 players, designed around 4. One player's browser hosts and runs the entities.
- Entities are full 3D figures made in Blender, rigged and animated. No flat sprites. A shadow is only ever a scare trigger, never the monster.
- Entities always obey their traits. If any player's screen shows them looking at a Stillness entity, it does not move. Network delay must never make it look like a rule was broken.
- **How a character gets made** (the owner's process, for every character): study first, then build, then judge. Before a character's serious pass, the Opus agent studies two YouTube Blender tutorials relevant to it (horror characters, low-detail retro creatures, rigging, whatever that figure needs) from their transcripts and frames sampled from the video, and adds what it learned to `docs/ART-NOTES.md`; later characters reuse those notes and add to them. After the build come at least two revision rounds. In each, two fresh Opus judges are shown only the pictures, told nothing, and asked what they see, what frightens, and what looks cheap; Fable judges the same pictures separately; the agent fixes the worst findings. Post the pictures from every round with `track.mjs media`.
- Every real entity is heard before it is seen.
- The instrument never lies. It only records while the entity's rule is being tested ("it only records the scary part"), and that rule is never named on screen.
- Odds are always printed. One bad roll never ends a run. A downed player has something to do within seconds.
- Everything about a floor comes from one seed, identical for every player.
- Each floor is a place with one rule change, open and on more than one level.

## Technical shape

- Vite + TypeScript + three.js, pinned versions. Vitest for logic, Playwright for the real game.
- `src/sim/` is pure logic with no three.js and no browser APIs: seeded RNG, floor generator, entity rules, recording rule, elevator and run state. It must run in Node so hundreds of runs can be simulated in tests.
- `src/render/`, `src/game/`, `src/ui/`, `src/net/`. Every network message goes through one layer with two backends: same-PC tabs (BroadcastChannel, `?net=local`) and real peer-to-peer (Trystero, version pinned).
- URL flags for testing: `?seed=`, `?floor=`, `?debug=1`, `?bots=N`, `?net=local`, `?room=`.
- **The owner tests alone.** `?bots=N` fills the crew with bot players that run in the same browser, driven by the same sim code the tests use: they walk, take readings, get caught, go down and vote, so every multiplayer system fires with one human present. `?debug=1` adds a panel to jump floors, place the entity, force a down or a wipe, and show the hidden trait. Both must work on the live build.
- The build uses relative asset paths (Vite `base: './'`) because the hub serves it under `/play/`.
- CI (`.github/workflows/ci.yml`, written in T0) runs `npm ci`, `npm run check` and the Playwright run on every push and uploads the screenshots. It is the clean-machine check; local runs stay the fast one.
- Blender scripts live in `assets_src/blender/<name>/` and must rebuild their asset from nothing. Exports go to `public/assets/`. Renders go to `assets_src/renders/<name>/`.
- `npm run check` = typecheck + sim tests + build. `npm run e2e` = Playwright runs, saving screenshots to `test-results/shots/`.
