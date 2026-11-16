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
- **Cap: 50,000 characters in total for the game, takes included** (the owner raised it from 25,000 on 2026-11-15). Keep a running total in `assets_src/voice/ledger.json`.
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

- `assets_src/voice/lines.json`: every line with an id, the tagged text, the moment it plays, and its settings.
- `assets_src/voice/generate.mjs`: reads the key, checks the ledger and cap, generates missing takes into `assets_src/voice/takes/<id>/`, never regenerates a cached take.
- `assets_src/voice/ledger.json`: characters spent.
- `public/assets/voice/<id>.mp3`: the chosen take, loudness-normalised with ffmpeg to about -16 LUFS.
- The takes folder is kept out of git if it grows large; the chosen files are committed.

## Checks the loop can run

- Every line id in `lines.json` has a file in `public/assets/voice/`.
- Duration is between 0.4 and 1.6 times the estimate from word count plus pauses. Outside that range usually means a tag was spoken aloud or a sound effect was produced.
- No clipping; loudness within 1 LU of target.
- The ledger total is under the cap.
