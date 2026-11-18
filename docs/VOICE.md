# The elevator voice

How the cheerful announcer (North Star H5) is written, generated and checked. Facts about ElevenLabs below were read from its own documentation on 2026-11-15; the model is under active development, so re-check before a large batch.

## The character

A corporate elevator announcer who is delighted about everything and has never once noticed that anything is wrong. The comedy is the gap between the tone and the news. The fear is the rare moment the tone slips.

- Default register: bright, warm, slightly too slow, the smile audible.
- It never shouts, never sounds scared, never apologises sincerely.
- **The slip:** at most once per run, one line is delivered flat and quiet, with no cheer at all, then the next line is cheerful again as if nothing happened. This is a proposal, not yet in the North Star.
- The speaker gets worse with depth, the voice does not. Crackle, band-limiting and echo are added in the browser at play time, so one clean recording serves every floor.

## Where the key is

The ElevenLabs key is not in this repository. `.local/MACHINE.md` (not in git) says which file on this machine holds `ELEVENLABS_API_KEY`. The generator script reads that one line at run time. Never print it, copy it into this project, commit it, or put it in anything the browser loads.

The account is shared with the owner's other work, so the game is careful with its credits:

- Before any batch, call `GET https://api.elevenlabs.io/v1/user/subscription` and log characters used and the limit.
- **Cap: 100,000 characters in total for the game, takes included** (the owner raised it from 25,000 on 2026-11-15, to 50,000 the same day, and to 100,000 on 2026-11-17 after topping up the account). Keep a running total in `assets_src/voice/ledger.json`.
- Stop and record a question if a batch would use more than 10% of what is left this month.
- Cache by a hash of text + voice + model + settings. Never pay twice for the same line.

## Model and call

- Model: **`eleven_v4`** ("most emotionally rich, expressive"; 10,000 characters per request; the docs name game character voices as its use). `eleven_v4_turbo` is the real-time variant and is not needed, because every line is made ahead of time.
- Endpoint: `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}` with header `xi-api-key`, body `text`, `model_id`, `voice_settings`, optional `seed`. Query `output_format=mp3_44100_128`.
- The API default model is still `eleven_multilingual_v2`, so `model_id` must always be set.
- v4 uses only two settings: `stability` (lower = more expressive and varied, higher = flatter and more consistent) and `similarity_boost`. **There are no style or speed controls on v4.** The docs give no recommended numbers. Start at stability 0.35 for normal lines and 0.6 for the slip, similarity 0.75, and adjust by ear.
- Output is not deterministic even with a `seed`. Make three takes of each line and keep them all for the audition. Two regenerations of an identical request are free.
- Measured against the live API on 2026-10-28 in another of the owner's projects: `eleven_v4` accepts `[pause]` tags (about 1.6 s) and returns character timestamps.

## Directing the read

All control on v4 is in the text. SSML, `<break>` and `<phoneme>` tags do not work.

- **Audio tags** in square brackets are performed, not spoken. Put a tag just before the words it shapes, or just after for a reaction: `That is everyone. [sighs]`
- **Documented tags:** `[laughs]` `[laughs harder]` `[starts laughing]` `[wheezing]` `[whispers]` `[sighs]` `[exhales]` `[sarcastic]` `[curious]` `[excited]` `[crying]` `[snorts]` `[mischievously]`, and from the docs' examples `[happy]` `[delighted]` `[warmly]` `[cute]` `[giggles]` `[reassuring]` `[professional]` `[sympathetic]` `[dismissive]` `[measured]` `[sheepishly]` `[annoyed]` `[ecstatic]` `[clears throat]` `[inhales deeply]` `[exhales sharply]` `[happy gasp]`.
- **Pauses:** `[short pause]` `[pause]` `[long pause]`. An ellipsis adds a pause with weight.
- **Free-text direction works:** `[Warm, conversational tone, faint amusement]`, `[Quick, light, playful pace]`, `[Low, steady voice, restrained urgency]`, `[Gradually building energy]`. This is the finest control available; use it for the opening of a line and single-word tags inside it.
- **Tags must describe a sound a voice makes.** `[grinning]` or `[standing]` do nothing. A tag can be misheard as a request for a sound effect, so prefer `[bright, smiling voice]` to anything that names an object or event.
- **CAPITALS** add emphasis to a word. Use one per line at most.
- **Punctuation is rhythm.** Short sentences. An exclamation mark lifts energy. A dash gives a small catch.
- **Names and odd words:** write IPA between slashes, `/ˈɔːdəli/`, and generate more than once.
- **Tags must suit the voice.** A voice that is naturally bright will take `[delighted]`; it will not whisper convincingly. Pick the voice for the default register and accept a weaker slip, or record the slip lines with a second, flatter voice setting.
- Numbers and abbreviations are written out in full before sending.

### Examples

    [Bright, smiling announcer voice, unhurried] Good evening, and welcome aboard! [short pause] Please keep your hands, feet and colleagues inside the car at all times.

    [delighted] Floor six! [pause] Please be advised that the stairwell is no longer empty.

    [warmly] Dave has been reassigned... [short pause] to Cameras. [giggles] We thank Dave for his service.

    [Quick, light, playful pace] Doors closing! Doors closing! [happy gasp] Oh. Somebody is still out there.

    [reassuring] Your reading has been graded... [long pause] ADEQUATE.

    [professional] The elevator has been called. It will arrive in ninety seconds. [mischievously] It will be very loud.

    The slip, stability 0.6:
    [Flat, quiet, no warmth, close to the microphone] Don't look at the mask.
    [long pause]
    [Bright, smiling announcer voice] Going down!

## Choosing the voice

- List the account's voices with `GET /v1/voices` and shortlist three that are naturally bright announcer or presenter voices. Voices made with Voice Design are less expressive on v4, per the docs, so prefer library voices.
- Generate the same three lines with each (one normal, one bad-news, one slip).
- Build `assets_src/voice/audition.html`: a plain page with a player for every take, grouped by line. **Claude cannot hear.** It can check that a file exists, how long it is, how loud it is, and whether a transcript matches the script. Whether a read is funny or frightening is the user's call, made on this page. Until they choose, take 1 of the first voice is used.

## Files

- `assets_src/voice/lines.json`: every line with an id, the moment it plays, the tagged text exactly as sent, the plain text (subtitles), its settings and a note on the read; also the shortlisted voices, the default voice, the audition line ids, each moment's priority, and `chosen` (line id to `{ "voice": name, "take": n }`; a line not listed uses take 1 of the default voice).
- `assets_src/voice/generate.mjs`: `--voices`, `--audition`, `--all`, `--publish`, `--page`, with `--dry-run` (counts characters, sends nothing) and `--budget N`. It reads the key file named by the environment variable `GD_ELEVENLABS_ENV` (which file: see `.local/MACHINE.md`), checks the subscription, the 10% rule, the cap and the budget before every batch, and stops at the first API error.
- `assets_src/voice/takes/<voice>/<id>/take-N.mp3`: every take (not in git). The hub serves them at `/files/assets_src/voice/takes/...`.
- `assets_src/voice/audition.html`: the audition page, rewritten from `lines.json` by `--page` (and after every batch).
- `assets_src/voice/ledger.json`: every request (line, voice, take, characters counted with tags, the API's billed figure, time, cache hash) and the running total.
- `assets_src/voice/check.mjs`: the checks below; exits non-zero on failure.
- `public/assets/voice/<voice>/<id>.mp3`: the chosen take of each line in each shipped voice, loudness-normalised with ffmpeg to -16 LUFS (true peak -1.5 dBTP), mono 128 kb/s; and one `manifest.json` (the voices, the default, each line's id, moment and subtitle, the priorities) which the game reads.
- In the game: `src/game/announcer.ts` maps run events to moments, plays one line at a time through the speaker chain, and draws the subtitles (`?subs=0` hides them, and so does the clean render `?fx=0`, like the rest of the on-screen display).

## Voices that ship

Two voices ship, chosen by the owner after the audition: **Bella** (the default) and **Brian**, with identical text and settings so they compare fairly. The player picks one in the settings panel (Esc on a computer, the gear on a phone) or with `?voice=bella|brian`; the choice is remembered in the browser and the next line uses it, without a reload. Until the owner picks takes, take 1 of each line ships (`chosen` in `lines.json` overrides per voice and line).

To add a third (for example Sarah, already shortlisted, whose three audition lines exist): add her name to `voices.ship` in `lines.json`, then run `node assets_src/voice/generate.mjs --all --voice Sarah --budget <ledger total + 5200>` with `GD_ELEVENLABS_ENV` set (see `.local/MACHINE.md`). That makes her missing takes (16 lines x 3, 5,151 counted characters), publishes every shipped voice and rewrites the audition page; `check.mjs` then checks her files too. The game reads the voice list from the manifest, so the settings panel offers her with no code change.

## Learned on 2026-11-16 (first batch)

- `eleven_v4` was accepted with `voice_settings` `{ stability, similarity_boost }`, a `seed`, and `output_format=mp3_44100_128`. No tag was read aloud as far as durations can tell (every line came out 0.8 to 1.2 times the estimate).
- The response carries an `x-character-count` header. For these lines it was about 0.44 of the characters sent (tags included), so the account is charged less than the ledger counts. The ledger counts every character sent, which is the safe side; the account's own usage figure lags a few minutes behind.
- The account's library voices include premade ones with clear labels (for example Bella "Professional, Bright, Warm", Sarah "Mature, Reassuring, Confident", Brian "Deep, Resonant and Comforting"); those three were shortlisted.
- Duration estimate used by the check: words at 2.5 a second, plus 0.5 s per `[short pause]`, 1.6 s per `[pause]`, 2.5 s per `[long pause]`, 0.4 s per ellipsis.
- ffmpeg's loudnorm on clips this short can land 0.5 to 1 LU low; the normaliser then falls back to a measured gain with a limiter and lands within 0.2 LU.

## Learned on 2026-11-17 (the Playroom count, T15i)

- 18 lines in a `playroom` group of `lines.json` (`groups` describes the group and its countdown scheme; each line has `"group": "playroom"`). A line's own `takes` overrides the file's default: three takes of each line, two of each number. 2,148 characters for both voices, 41 takes each.
- `--publish` now also writes the manifest, and the files of each voice that already has a folder there (Bella), to `godot/assets/voice/`, which the Godot game reads; `check.mjs` checks that copy matches.
- A one-word clip runs 1.15 to 1.41 s (about 0.1 s before the word and a 0.25 s tail), so the check's estimate never goes below 1.0 s.
- `godot/client/count_lines.gd` maps the count's events to these line ids for the count on screen (T15e).

## Learned on 2026-11-17 (the orientation tape, ST2)

- A group in `lines.json` may name its voices (`groups.tape.voices: ["Bella"]`): `--all`, `--publish`, the audition page and `check.mjs` then make, ship and check its lines in those voices only, the manifest lists them on the line (`"voices": ["bella"]`), and `check.mjs` fails if the ledger shows one recorded in another voice.
- Five beats of the tape, one take each, 958 characters. Bella read them at 0.83 to 0.97 of the design's seconds. The tape cuts its pictures on the pauses between sentences (`node godot/tools/tape_cues.mjs`, which writes the cue times into `godot/data/tapes.json`); run it again after any re-take.

## Learned on 2026-11-18 (the grab, hint_listen_1, hint_hide_2)

- The Minder's grab outside a count has its own moment, `grab` (`grab_1` to `grab_3`, group `playroom`, one take each): `godot/client/announcer.gd` `say_grab` deals one per grab from a shuffled deck (never the same twice running) and captions it with the line itself. "Found you" stays for a count's find.
- `hint_listen_1` was reworded (owner, 18 Nov: its old first sentence, about not being alone, could give away a resident's rule). Its old takes were replaced, not kept beside the new ones.
- A line read slowly on purpose may carry its own upper limit for the duration check: `"slow": 1.8` on the line in `lines.json` (a number from 1 to 2.0). `check.mjs` uses it for that line only; every other line keeps 1.6. `hint_hide_2` has it: its spaced list runs 1.61x (Bella) and 1.74x (Brian) the estimate in take 1, four takes agree the slow read is right, and the owner kept take 1.

## Checks the loop can run

- Every line id in `lines.json` has a file in `public/assets/voice/`.
- Duration is between 0.4 and 1.6 times the estimate from word count plus pauses (or the line's own `"slow"` allowance, for a line read slowly on purpose). Outside that range usually means a tag was spoken aloud or a sound effect was produced.
- No clipping; loudness within 1 LU of target.
- The ledger total is under the cap.
