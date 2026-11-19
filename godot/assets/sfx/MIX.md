# The mix

The owner's rule (V21): "You need to make sure you're normalizing sound properly so that in game one sound doesn't come over another like orchestrate the sound well." So: scares sit about +3 LU over the elevator voice and never more than +4, nothing else goes over the voice, true peak at most -1 dBTP; every floor is measured in the game (tools/mix_check.mjs: the Clinic's busy minute, then the Annex and the Playroom).

How every sound sits against the elevator voice, and why. Measured with ffmpeg `ebur128` (integrated loudness I, short-term max S over 3 s windows, loudness range LRA, true peak TP). Regenerate the files with the scratch pipeline described under *Method*; check the result in the game with `node godot/tools/mix_check.mjs` (GODOT set).

## The reference: the voice

The 54 elevator voice files average **V = -16.1 LUFS** integrated (each -16.0 to -16.2), true peak at most -1.6 dBTP. The announcer plays them at -5 dB (announcer.gd); every other sound plays at that same -5 dB (`Sfx.BASE_DB`), so a file's loudness relative to V is its loudness relative to the voice in the game. On the desktop the Voice bus (ceiling-speaker band-pass and compressor) costs about 9 dB, so its compressor's make-up gain is 12.8 dB: measured in the game, V comes out at -17.6 to -18.2 LUFS on the desktop, the same as in the browser (where bus effects do not run).

## Targets by category

| Category | Target | Why |
|---|---|---|
| Orderly approach (trolley roll, squeak) | I = V-3 | The thing you must hear first. It is only heard unseen (behind you, round a corner), where 3D panning costs about 7 dB, so it plays 7 dB up and falls 3 dB with the rules' audibility; through a wall the Entity low-pass takes more and 5 dB is given back. Measured: about V-5 close behind you, V-11 at the edge of the rules' hearing range (34 m), never lower than V-12 (checked). |
| Orderly near (slow breathing, rattle) | I = V-3 | Close, quiet, but plain when it is right there. Slow breath reaches 8 m, throat rattle reaches 26 m. |
| Orderly small (quick breath, gown, tray, thud, chewing) | I = V-6 | Detail under the approach. |
| Scares (roar, shrieks) | short-term max = V+3 | The owner: louder than the voice, not by much. Ceiling V+4 (checked), TP -1.5 on the file, -1 after the Master limiter. Nothing else may pass the voice. |
| Room tones (slams, drip, intercom, monitor, bed roll) | I = V-10 | Far-off life in the building, at its 3D reference distance (3 m); further is quieter. |
| Ambient beds (hum, vent, drone, ride rumble) | I = V-14, LRA under 1 | Always there, never in the way; the vent plays 4 dB under, the ride 4 dB over. |
| Effects (blink flicker) | I = V-6 | A warning you must notice. The tube pop: short-term V-2. |
| Player (winded breathing) | I = V-8 | Yours, close, under the world. |
| Footsteps | momentary max V-8 | Too short to gate: by momentary loudness. |
| UI (generated chimes, dings, bell, ticks) | momentary max V-8 | `Sfx.SYNTH_DB` puts each generated stand-in there (measured with tools/sfx_levels.gd). |

## Buses and orchestration

- Buses (default_bus_layout.tres): Voice, Entity, Scare, Effects, Ambience, UI, all into Master, which has a hard limiter. The layout sets its ceiling at -1.0; Sfx.setup lowers it to -2.0 dBFS (Sfx.MASTER_CEILING) because it holds sample peaks and the true peaks between samples ran up to 0.8 dB over them (one mix check in three measured -0.7 dBTP at the -1.0 ceiling), so the -1 dBTP rule holds every run. Entity carries the Orderly and is never ducked; its low-pass (4 kHz) is the muffling when the rules say a wall is in the way, and 5 dB is given back for it.
- While the announcer speaks, Effects and Ambience duck by 6 dB (the bus faders, 30 dB/s, so it works in the browser too; checked there by tools/sound_web.mjs).
- Every 3D sound has its category's unit size and max distance and never plays louder than its file however close (`max_db` 0). The trolley has no distance attenuation of its own: its loudness is the rules' audibility.
- Room tones: at most one at a time, at least 9 s apart, none for 8 s after a scare, none while the Orderly is coming within 20 m unseen, the bed only while the Orderly is watched, the intercom not in the dark. Timing and place come from the floor seed and the host's clock (16 s slots), so every player hears the same tone at the same moment from the same place.
- Shrieks: never two within 45 s, never while it is seen, only when it starts moving unseen; chances are seeded per floor and per release, so they agree between players and cannot be learnt as a schedule.

## What the game measured (tools/mix_check.mjs, the busy minute)

Desktop, headless, 76 s: V = -17.9 LUFS. Short-term max per bus against it: Entity -1.0 LU, Effects -3.9, Ambience -12.7, UI -13.4, Scare +3.3 (ceiling +4); Master true peak -2.0 dBTP; the Orderly coming on unseen never quieter than V-11.2 within hearing (at 33 m, the edge of the rules' range); Ambience at least 18.8 LU under the voice while it speaks. Breaks that turn it red: no duck (Ambience -12.9 LU under the voice while it speaks), the hum 12 dB up (-8.4), the roar 3 dB up (+6.4 LU over the voice).

The recording itself (17 Nov): from the second batch on, "the beds duck" read 13.0 to 14.8 LU and failed two runs in three. The duck was fine; the Ambience recording was not in step. Its capture was added before the game, and the game's own Ambience low-pass, added after, emptied it (adding an effect to a bus starts its effects afresh), so the Ambience file was 2.1 to 2.3 s short and ran early: the beds seemed to come back up 1.5 to 2 s before the voice ended. With the captures added after the game, 0.28 s was still missing (the Ambience is quiet for the first moments, and a bus with nothing on it is not recorded), so every recording now starts on one frame a second in. Each run now checks that every bus recorded the same length (within 0.1 s). In step, the beds sit 18.4 to 19.1 LU under the voice while it speaks (three full runs in a row; Entity -0.5 to -0.9 LU, the scare +2.9 to +3.3, Master -1.9 to -2.0 dBTP), as in the first measurement above.

Browser (tools/sound_web.mjs): the hum ducks 6.8-7.3 dB under the voice through the bus fader, so the duck works there too.

## Every file

Raw = the owner's WAV as delivered; final = the committed Ogg. Rel = final loudness against V (by S for scares, by momentary max for steps, else I). Lim = dB of peak limiting before the gain (so the loudness move stays linear). Seam = the jump across a loop's join against the signal's own 99th-percentile step (under 1: no click).

| File | Category | Raw I / Smax / LRA / TP | Final I / Smax / LRA / TP | Rel to V | Method | Lim | Seam | Length |
|---|---|---|---|---|---|---|---|---|
| orderly/trolley_roll.ogg | approach | -35.7 / -34.4 / 2.1 / -15.7 | -19.5 / -18.8 / 0.9 / -2.7 | -3.4 | loudnorm-linear | 6.4 | 0.05 | 5.1 s |
| orderly/trolley_squeak.ogg | approach | -26.1 / -22.4 / 9.7 / -2.2 | -19.5 / -18.1 / 3.9 / -2.2 | -3.4 | loudnorm-linear | 14.0 | 0.0 | 9.7 s |
| orderly/breath_slow.ogg | entity | -45.8 / -44.6 / 3.5 / -32.2 | -18.8 / -18.5 / 1.8 / -3.1 | -2.7 | loudnorm-linear | 0.5 | 0.01 | 7.6 s |
| orderly/rattle.ogg | entity | -33.1 / -33.6 / 20.0 / -17.6 | -19.2 / -19.2 / 0.0 / -2.6 | -3.1 | volume | 2.4 | - | 2.94 s |
| orderly/breath_quick.ogg | entity_small | -17.5 / -16.9 / 2.1 / -2.9 | -22.4 / -22.4 / 0.0 / -6.4 | -6.3 | volume | 0.0 | - | 1.37 s |
| orderly/chew.ogg | entity_small | -35.4 / -34.4 / 4.2 / -12.8 | -22.3 / -21.2 / 1.4 / -2.0 | -6.2 | loudnorm-linear +encoder trim | 4.8 | - | 5.17 s |
| orderly/gown.ogg | entity_small | -39.9 / -40.4 / 20.0 / -22.8 | -22.3 / -22.3 / 0.0 / -4.0 | -6.2 | volume | 0.8 | - | 2.93 s |
| orderly/instruments.ogg | entity_small | -27.2 / -28.4 / 0.6 / -4.4 | -22.4 / -22.4 / 0.0 / -2.2 | -6.3 | volume | 9.1 | - | 2.79 s |
| orderly/thud.ogg | entity_small | -22.6 / -22.6 / 0.0 / -6.4 | -22.1 / -22.1 / 0.0 / -5.2 | -6.0 | volume | 0.0 | - | 0.48 s |
| orderly/roar.ogg | scare | -12.3 / -11.2 / 6.0 / -0.4 | -13.7 / -12.6 / 3.0 / -1.5 | +3.5 | loudnorm-linear | 2.4 | - | 5.15 s |
| orderly/shriek_1.ogg | scare | -12.3 / -15.4 / 6.1 / -3.0 | -13.3 / -13.3 / 0.0 / -1.9 | +2.8 | volume | 1.9 | - | 2.93 s |
| orderly/shriek_2.ogg | scare | -10.7 / -13.2 / 7.0 / -0.8 | -14.7 / -14.7 / 0.0 / -1.8 | +1.4 | volume +encoder trim | 3.3 | - | 2.5 s |
| orderly/shriek_3.ogg | scare | -12.7 / -13.0 / 2.6 / -0.8 | -13.0 / -13.8 / 20.1 / -1.6 | +2.3 | gain (loudnorm refused linear) +encoder trim | 4.6 | - | 3.35 s |
| player/step_1.ogg | step | -42.1 / -40.6 / 4.3 / -13.3 | -24.2 / -24.2 / 0.0 / -2.9 | -8.1 | volume | 5.6 | - | 0.42 s |
| player/step_2.ogg | step | -42.1 / -40.6 / 4.3 / -13.3 | -24.3 / -24.3 / 0.0 / -3.9 | -8.2 | volume | 3.4 | - | 0.42 s |
| player/step_3.ogg | step | -42.1 / -40.6 / 4.3 / -13.3 | -24.1 / -24.1 / 0.0 / -3.5 | -8.0 | volume | 0.0 | - | 0.42 s |
| player/step_4.ogg | step | -42.1 / -40.6 / 4.3 / -13.3 | -24.2 / -24.2 / 0.0 / -1.9 | -8.1 | volume | 6.5 | - | 0.42 s |
| clinic/hum.ogg | bed | -39.0 / -38.6 / 0.6 / -24.8 | -30.2 / -30.1 / 0.1 / -17.2 | -14.1 | loudnorm-linear | 0.0 | 0.26 | 6.0 s |
| clinic/vent.ogg | bed | -35.1 / -34.6 / 0.6 / -23.1 | -30.3 / -30.0 / 0.5 / -14.9 | -14.2 | loudnorm-linear | 0.0 | 0.15 | 9.0 s |
| clinic/drone.ogg | bed | -25.8 / -25.4 / 0.8 / -3.1 | -30.2 / -30.2 / 0.3 / -16.6 | -14.1 | loudnorm-linear | 0.0 | 0.16 | 4.15 s |
| lift/rumble.ogg | bed | -18.1 / -17.8 / 0.6 / -0.6 | -29.9 / -29.8 / 0.4 / -12.3 | -13.8 | loudnorm-linear | 0.0 | 0.55 | 4.4 s |
| clinic/flicker.ogg | effect | -45.5 / -45.4 / 0.1 / -35.7 | -22.2 / -21.9 / 0.7 / -9.5 | -6.1 | loudnorm-linear | 0.0 | - | 4.0 s |
| clinic/pop.ogg | effect_hit | -16.4 / -16.4 / 0.0 / -0.9 | -18.6 / -18.6 / 0.0 / -1.6 | -2.5 | volume +encoder trim | 6.9 | - | 0.45 s |
| clinic/slam_1.ogg | room | -31.3 / -37.0 / 20.0 / -16.6 | -26.2 / -26.2 / 0.0 / -8.6 | -10.1 | volume | 0.0 | - | 2.81 s |
| clinic/slam_2.ogg | room | -23.8 / -27.0 / 20.0 / -2.2 | -26.3 / -26.3 / 0.0 / -4.5 | -10.2 | volume | 0.0 | - | 1.96 s |
| clinic/drip.ogg | room | -48.0 / -47.9 / 4.4 / -24.8 | -26.3 / -26.2 / 2.0 / -1.8 | -10.2 | loudnorm-linear +encoder trim | 4.5 | 0.07 | 4.8 s |
| clinic/monitor.ogg | room | -7.9 / -6.7 / 10.9 / -0.3 | -26.1 / -26.1 / 0.0 / -12.0 | -10.0 | volume | 0.0 | 0.0 | 2.0 s |
| clinic/intercom_1.ogg | room | -11.9 / -12.2 / 20.0 / -0.7 | -26.3 / -26.3 / 0.0 / -12.7 | -10.2 | volume | 0.0 | - | 2.75 s |
| clinic/intercom_2.ogg | room | -19.2 / -26.1 / 20.0 / -1.0 | -26.5 / -26.5 / 0.0 / -5.5 | -10.4 | volume | 0.0 | - | 0.9 s |
| clinic/bed_roll.ogg | room | -31.7 / -32.6 / 4.7 / -9.0 | -26.4 / -27.2 / 1.8 / -2.7 | -10.3 | loudnorm-linear | 2.6 | - | 6.7 s |

## Carrying across the floor (the owner, playing build 0833)

"The shrieks and roars and raspy breathing are too quiet when far away near the elevator; that should be scary to hear, a distant wail. The raspy breathing needs to happen much further away, before you get caught." So the scares and the Orderly's breathing have their own curves (Sfx.far_db), panned in 3D, losing their top with distance (a low-pass from open at 8 m to 2.5 kHz at 60 m: far off is muffled, never silenced). The levels at the file stay as above, so the ceiling (V+4) and the true peak are untouched.

| Sound | Before | After |
|---|---|---|
| Scares (roar heard from the Orderly, shrieks) | the engine's inverse distance from 6 m: -12.4 dB at 25 m, cut off at 45 m | full within 8 m, -20 log(d/8) beyond, never below -10 dB out to 90 m (reached at 25 m) |
| Slow breathing | previous mix reached 28 m | silent beyond 8 m, ?22 dB at 8 m, ?11 dB at 5 m, full from 2 m |
| Throat rattle | tried within 14 m, inverse distance from 2 m, gone past 18 m | tried within 26 m, on the breathing's curve |

The trolley remains the long-distance cue out to 34 m. Within 8 m its slow-breath duck grows to 9 dB by 2 m. The throat rattle keeps its existing 26 m range and separate duck. A world shriek follows the moving Orderly and samples the current camera on each update throughout its recorded tail. The victim?s centered catch roar uses its own playback path.

The far mix check measures the breathing onset against the voice at V?35, requires it between 4 and 8.5 m (allowing meter sampling), and checks monotonic gain alone and beneath the trolley. The 25 m and 55 m roar checks continue to cover the distant scare.

## The second batch (17 Nov): the Annex, the Playroom and the crew

The same method, the same V, the same buses; files in annex/, playroom/ and player/ (SOURCES.md). New categories and why:

| Category | Target | Why |
|---|---|---|
| The Temp's stapler click | momentary max V-9, played at BASE_DB +5 (temp_view.gd CLICK_REC_DB) | A click of 0.4 s cannot carry much momentary loudness without crushing it (9 dB of limiting at most); +5 in the game puts it at the voice -4 LU right at its hand, as the made-in-code click was, with the file's true peak still -1.5 on the bus. Then (1 - d/30)^2 and 0.45 through a wall, as before. |
| The stapler going into you (catch) | momentary max V-5 | After the roar, in your face, under it. |
| The Temp's steps, footsteps | momentary max V-8 | As the crew's footsteps; only within 8 m, so from further the Annex's sound stays dots. |
| Beds: the office, the play centre | I = V-14, LRA under 1 | In the hum's place on their floor, following the lights; the vent is the Clinic's. |
| Room tones: phone, photocopier | I = V-10 | As the Clinic's; the phone plays from everywhere at -6 (far off, no direction). |
| Warnings: the Annex's sagging buzz | I = V-6 | As the Clinic's flicker. |
| The music box, the Minder scrambling | I = V-3 (the box), V-8 (the scramble, peaky: 8.4 dB of limiting was the most it took) | The box is the Minder's heard-before-seen sound: played at BASE_DB +6 (minder_view.gd BOX_DB) for the 3D panning, about V-4 right at it, falling as (1 - d/30)^2. |
| The Minder near: wheeze, huff | I = V-3 | As the Orderly's slow breath; 3D. |
| The count bell (Voice bus) | momentary max V-5.7 | The made-in-code bell's own level (measured with tools/sfx_levels.gd), so the count sits where it did: never buried, never over the voice, +0.8 dB a stroke in the last five. |
| The count's note (#19) | momentary max V-5.3 | The made-in-code three notes' level; one note played three times at pitch 1, 1.26, 1.5, 0.2 s apart (Sfx.XYLO_PITCH). |
| The call panel: refused buzz, quota met; the teller's ding | momentary max V-8 | The UI level (the made-in-code buzz was V-8). |
| The ride up (the freight lift straining) | I = V-10 | Machinery, on the Effects bus as the call's made-in-code motor is, over the ride's rumble (V-10 on Ambience): on Ambience the two with the prison's bed reached V-5.9 in the mix check, over the beds' V-8 line. |
| The prison's night | I = V-14 | A bed, in the hum's place; it stays through lights out. |
| Lights out, a cell door, a teller window | I = V-6 | Effects. |
| A bunk creaking, sliding under the table | I = V-8, V-6 | Crew. |
| Toys: squeaker tiles, net and flap | momentary max V-5 | A noise you made: plain, under the voice. |
| The ball pit | jumping in: momentary max V-3 (it is a provocation); wading: I = V-8 | |
| Crew one-shots: down, healed, into a hide, slide | I = V-6 | Yours, close, an event. |
| Crew loops: your winded breath, crawling | I = V-8 | As before. |
| The party horn | momentary max V-6 | Three takes. |
| Sticky notes | slap: momentary max V-15 (a 0.26 s slap with 9 dB of limiting); peel: V-8 | Ready only; the slap wants +6 in the game when it is wired, as the stapler. |
| The lift's chime (recorded two-tone bell) | momentary max V-8 | The UI stand-in's level; the false stop's 9 dB under it. |
| The found-you sting | short-term max V+3 | A scare. |

### Takes picked

- Stapler click: all four takes kept (dealt in turn, never the same twice running). Each is one press-and-release ("ka-chunk", 0.4 s), not cut to a single transient: cut that short, a click cannot reach any useful loudness.
- Stapler into something soft: #4. A clean silence before the punch, one strong punch with the release 0.3 s later 10 dB down (#3's release is nearly as loud as its punch, two hits), and mono-safe (L/R correlation 0.99 against 0.91).
- Photocopier: #3. 3.4 dB more signal over the same room noise, and the warm-up then the page are both clear (LRA 2.5); #1 is mostly a steady drone.
- Hand bell: #1. The strongest strike (momentary max 6.8 dB over #3's) and 30 dB down within 0.6 s, so a stroke a second stands out; both takes have the clapper's small bounce.
- Squeaky toy: #1, #2 and #4's second squeak, three takes for the tiles (each one squeak).
- Party blower: all three, as takes (the horn will be blown a lot).
- Wheeze: #2. It starts and ends near silence (two whole breaths), so the loop's join is clean (seam 0.01); #1 starts mid-breath.
- The count's note (#19, three candidates): single_note_struck_o #4. The cleanest: one steady pitch from strike to end (its zero-crossing rate never moves), the strongest strike (momentary max 7 dB over the glockenspiel's and 16 over the toy piano's), a clean 0.8 s decay, and mono-safe (L/R correlation 0.76; the glockenspiel's is -0.06, so folding it to mono would hollow it out; the toy piano is noisy and wavers).
- Sliding under (#6): layered: the jacket-and-jeans slide #2 from 0, #3 4 dB under it from 0.15 s (more cloth), and the shoulder bump #3 at 1.25 s as the slide stops.
- The found-you sting (the owner: "combine both noises"): **layered**, both at once from 0: #1 (the music-box note bending, lifted 4 dB so it is not lost) strikes first, and #2's deep breath swells in under it 0.2 s later (its own lead-in), 2.2 s in all, normalised as one scare to short-term V+2.6 (4.5 dB of limiting).
- The out-of-breath file: the crew's own clean breath, so your winded breathing now uses it (the earlier wet breaths are the Orderly's); played at pitch 1, not sped up when winded as the made-in-code one is.
- Second Wind plays one short exertion sound at the player when the host accepts the refill. The 0.78 s excerpt starts 2.50 s into `player/breath_winded.ogg`, with a 3 dB boost and short fades.

### Every file (second batch)

Columns as above; Rel = final loudness against V by the category's measure (I, M momentary max, or S short-term max).

| File | Category | Raw I / Smax / LRA / TP | Final I / Smax / LRA / TP | Final Mmax | Rel to V | Method | Lim | Seam | Length |
|---|---|---|---|---|---|---|---|---|---|
| player/breath_winded.ogg | player | -42 / -40.7 / 1.6 / -21.1 | -24.3 / -23.1 / 1.4 / -6.1 | -20.4 | -8.2 (I) | gain +loop xfade | 0 | 0.18 | 5.50 s |
| player/down.ogg | crew | -17.3 / -23.6 / 20 / -0.9 | -22.2 / -28.5 / 0 / -2 | -19.8 | -6.1 (I) | gain | 0 | - | 2.10 s |
| player/crawl.ogg | player | -48.5 / -48.2 / 2.8 / -28.6 | -24.4 / -22.8 / 2.9 / -3.2 | -19.1 | -8.3 (I) | gain +loop xfade | 0 | 0.13 | 10.95 s |
| player/healed.ogg | crew | -39.3 / -45.6 / 20 / -28.6 | -22.2 / -28.5 / 0 / -9 | -19.8 | -6.1 (I) | gain | 0 | - | 2.20 s |
| player/hide_in.ogg | crew | -35.8 / -40.5 / 0 / -15.4 | -22.3 / -25.8 / 0 / -1.9 | -17.7 | -6.2 (I) | gain +limit | 4.4 | - | 1.95 s |
| annex/staple_1.ogg | click | -24.9 / -33.7 / 0 / -1.7 | -70 / -34.8 / 0 / -2.5 | -26 | -9.9 (M) | gain +limit | 5.9 | - | 0.40 s |
| annex/staple_2.ogg | click | -22.5 / -31.3 / 0 / -4.8 | -25.2 / -34 / 0 / -4.6 | -25.2 | -9.1 (M) | gain | 0 | - | 0.49 s |
| annex/staple_3.ogg | click | -25.8 / -34.6 / 0 / -3.6 | -25.5 / -34.2 / 0 / -1.8 | -25.5 | -9.4 (M) | gain +limit | 4 | - | 0.45 s |
| annex/staple_4.ogg | click | -24 / -32.8 / 0 / -2.3 | -26.3 / -35.1 / 0 / -1.7 | -26.3 | -10.2 (M) | gain +limit +encoder trim | 1.5 | - | 0.45 s |
| annex/staple_soft.ogg | thunk | -23.5 / -29.1 / 0 / -1 | -25.4 / -30.9 / 0 / -1.6 | -22.2 | -6.1 (M) | gain +limit +encoder trim | 6.8 | - | 0.65 s |
| annex/office.ogg | bed | -46 / -45.8 / 0.3 / -35.8 | -30.1 / -29.9 / 0.4 / -17.9 | -29.5 | -14 (I) | gain +loop xfade | 0 | 0.37 | 13.10 s |
| annex/buzz.ogg | effect | -35.6 / -33.6 / 3.9 / -9.3 | -22.1 / -21.8 / 0.6 / -1.5 | -16.3 | -6 (I) | gain +limit | 7.2 | - | 3.55 s |
| annex/phone.ogg | room | -40.6 / -42.5 / 20 / -28.3 | -26.2 / -29 / 4.9 / -12.8 | -23.8 | -10.1 (I) | gain | 0 | - | 3.90 s |
| annex/copier.ogg | room | -34.7 / -33.6 / 2.5 / -20.1 | -26.3 / -25.2 / 2.4 / -8.8 | -21.4 | -10.2 (I) | gain | 0 | - | 6.00 s |
| annex/note_slap.ogg | mark | -33.7 / -42.4 / 0 / -5.3 | -70 / -40.1 / 0 / -2.7 | -31.4 | -15.3 (M) | gain +limit | 9 | - | 0.26 s |
| annex/note_peel.ogg | mark_small | -26.5 / -32.2 / 0 / -5.6 | -27.1 / -32.7 / 0 / -6.1 | -24.3 | -8.2 (M) | gain | 0 | - | 0.69 s |
| annex/temp_steps.ogg | step | -52 / -52.3 / 1.6 / -28 | -27.2 / -27.7 / 1.7 / -1.5 | -24.1 | -8 (M) | gain +limit +loop xfade | 0.9 | 0.14 | 5.70 s |
| annex/drag.ogg | entity_small | -48.4 / -48.2 / 0.8 / -35.1 | -22.3 / -21.3 / 0.9 / -5.8 | -18.8 | -6.2 (I) | gain +loop xfade | 0 | 0.06 | 3.80 s |
| annex/lift_bell.ogg | ui | -18.7 / -21.3 / 0 / -9.6 | -27.5 / -30 / 0 / -15.5 | -24.1 | -8 (M) | gain | 0 | - | 2.00 s |
| playroom/music_box.ogg | approach | -28.5 / -26.7 / 8.9 / -8.8 | -19.1 / -17.2 / 8.1 / -1.7 | -11.1 | -3 (I) | gain +limit +loop xfade | 5.8 | 0.01 | 11.70 s |
| playroom/count_bell.ogg | bell | -17.1 / -21.7 / 0 / -4 | -25 / -30.5 / 0 / -10.2 | -21.8 | -5.7 (M) | gain | 0 | - | 0.90 s |
| playroom/room.ogg | bed | -41.3 / -40.3 / 1.3 / -27.5 | -30.2 / -29.7 / 0.8 / -15.7 | -27.6 | -14.1 (I) | gain +loop xfade | 0 | 0.16 | 17.60 s |
| playroom/squeak_1.ogg | toy | -15.8 / -23.1 / 0 / -1.7 | -70 / -30.1 / 0 / -6.4 | -21.3 | -5.2 (M) | gain | 0 | - | 0.23 s |
| playroom/squeak_2.ogg | toy | -14.9 / -22.9 / 0 / -0.4 | -70 / -30 / 0 / -6.7 | -21.3 | -5.2 (M) | gain | 0 | - | 0.26 s |
| playroom/squeak_3.ogg | toy | -13.7 / -20.6 / 0 / -1 | -70 / -30.2 / 0 / -6.6 | -21.4 | -5.3 (M) | gain | 0 | - | 0.22 s |
| playroom/pit_wade.ogg | pit_quiet | -36 / -35.6 / 0.7 / -17.3 | -24.1 / -23.7 / 0.6 / -2.6 | -18 | -8 (I) | gain | 0 | - | 3.60 s |
| playroom/pit_jump.ogg | pit_loud | -24.3 / -26.2 / 0 / -1 | -25.1 / -27.4 / 0 / -1.7 | -19.9 | -3.8 (M) | gain +limit +encoder trim | 5 | - | 2.00 s |
| playroom/slide.ogg | effect | -30.6 / -33.8 / 0 / -16.7 | -22.2 / -25.3 / 0 / -5.9 | -20.2 | -6.1 (I) | gain | 0 | - | 1.95 s |
| playroom/net_flap.ogg | toy | -21.5 / -29.3 / 0 / -5 | -21.5 / -30.2 / 0 / -3 | -21.5 | -5.4 (M) | gain | 0 | - | 1.95 s |
| playroom/horn_1.ogg | horn | -17.4 / -19.4 / 0 / -6.5 | -25.1 / -27.2 / 0 / -10.6 | -22.2 | -6.1 (M) | gain | 0 | - | 1.85 s |
| playroom/horn_2.ogg | horn | -28.6 / -30.9 / 0 / -14.3 | -27.2 / -29.4 / 0 / -9.9 | -22.2 | -6.1 (M) | gain | 0 | - | 1.85 s |
| playroom/horn_3.ogg | horn | -36.1 / -38.7 / 0 / -25.2 | -25.1 / -28.1 / 0 / -11.6 | -22.2 | -6.1 (M) | gain | 0 | - | 1.65 s |
| playroom/minder_run.ogg | run | -32.7 / -32.3 / 2 / -5.9 | -24.5 / -24.1 / 1.4 / -2.1 | -19.8 | -8.4 (I) | gain +limit +loop xfade | 8.4 | 0.03 | 3.73 s |
| playroom/wheeze.ogg | entity | -31 / -30.5 / 1.6 / -16.4 | -19.2 / -19 / 0.5 / -1.7 | -14.8 | -3.1 (I) | gain +limit +loop xfade | 1.3 | 0.01 | 3.58 s |
| playroom/huff.ogg | entity | -30.1 / -31.3 / 1.2 / -18.4 | -19.1 / -20.7 / 1.3 / -4.7 | -14.1 | -3 (I) | gain | 0 | - | 3.88 s |
| playroom/found.ogg | scare | -18.4 / -20.1 / 0 / -5.2 (the layered pair) | -11.9 / -13.5 / 0 / -1.7 | -10.5 | +2.6 (S) | gain +limit +encoder trim | 4.5 | - | 2.20 s |
| player/slide_under.ogg | crew | -39.3 / -41.9 / 0 / -16 (the layers) | -22.5 / -25.4 / 0 / -1.9 | -19.1 | -6.4 (I) | gain +limit | 3.6 | - | 1.90 s |
| playroom/xylo_note.ogg | xylo | -22.1 / -26.9 / 0 / -2 | -25.6 / -30.3 / 0 / -2.5 | -21.6 | -5.5 (M) | gain | 0 | - | 0.85 s |
| lift/up.ogg | room | -32.7 / -31.5 / 3.6 / -17 | -26.2 / -25.1 / 3.5 / -7.6 | -21.1 | -10.1 (I) | gain | 0 | - | 8.00 s |
| lift/refused.ogg | ui | -31.6 / -40.3 / 0 / -13.7 | -24.3 / -33 / 0 / -5.1 | -24.3 | -8.2 (M) | gain | 0 | - | 0.45 s |
| lift/quota_met.ogg | ui | -12.9 / -16.4 / 0 / -2.5 | -26.6 / -30.1 / 0 / -13.3 | -24.1 | -8 (M) | gain | 0 | - | 1.62 s |
| prison/night.ogg | bed | -39.9 / -39 / 1.4 / -26.5 | -30.2 / -28.7 / 2.8 / -13.2 | -25.8 | -14.1 (I) | gain +loop xfade | 0 | 0.13 | 18.60 s |
| prison/bunk.ogg | player | -40.1 / -43.2 / 0 / -26.1 | -24.3 / -27.5 / 0 / -7.2 | -20.2 | -8.2 (I) | gain | 0 | - | 1.68 s |
| prison/lights_out.ogg | effect | -16.5 / -15.1 / 22 / 0.4 | -22.5 / -21.3 / 19.9 / -1.6 | -15.3 | -6.4 (I) | gain +limit +encoder trim | 0.2 | - | 6.80 s |
| prison/cell_door.ogg | effect | -18.5 / -23.7 / 0 / -2.9 | -22.3 / -27.9 / 0 / -3.8 | -19.7 | -6.2 (I) | gain | 0 | - | 1.80 s |
| prison/teller_window.ogg | effect | -20 / -25 / 0 / -5.8 | -22.3 / -27.3 / 0 / -6.1 | -19.5 | -6.2 (I) | gain | 0 | - | 1.30 s |
| prison/teller_ding.ogg | ui | -19.7 / -25.8 / 0 / -4.5 | -28.1 / -32.9 / 0 / -8.8 | -24.2 | -8.1 (M) | gain | 0 | - | 1.28 s |

Method as the first batch, with two differences: every file is a plain linear gain from ebur128 (to I, M or S as the category says, corrected until within 0.2 LU or the limiting cap), with a sample-peak limiter (ffmpeg alimiter at -1.8 dBFS) after the gain where the gain pushes peaks past it, at most 9 dB of it (where that is not enough the file stays short of its target: the clicks, the note slap, the scramble); and short files are padded with silence to be measured, so their momentary and short-term windows are whole. An -I of -70 means the file is too short for ebur128 to gate (a click).

### What the game measured on the Annex and the Playroom (tools/mix_check_floors.gd)

Headless, no walls, V = -18.0 LUFS on both (the Voice bus over four lines). Short-term max per bus against it, and where:

| Bus | The Annex | The Playroom | The prison and the lift's panel |
|---|---|---|---|
| Scare | +3.4 LU (the catch's roar) | +2.5 LU (the found-you sting) | silent |
| Entity | -13.1 (the stapler going in; the clicks are dots, short-term never sees them) | -4.3 (scrambling past at 3 m); the music box rises from about V-26 at 20 m to V-5 at 2 m; the wheeze at 2 m V-12 | silent |
| Effects | -5.6 to -5.9 (the blackout's sagging buzz) | -8.2 (the ball pit jumped into, here) | -5.1 (lights out) |
| Ambience | -11.0 (the bed with the phone over it) | -12.3 (the bed and the tune) | -8.2 (the night bed under the ride's rumble) |
| UI | -14.0 (the lift's bell) | -10.3 (the count's recorded note, three times) | -12.3 (refused, quota met) |
| Voice, the count bell | | -4.0 | |
| Master true peak | -1.9 to -2.4 dBTP | -4.3 to -4.6 dBTP | -4.9 dBTP |

Breaks that turn it red: the office tone 12 dB up (`--break=office`: Ambience -1.7 LU under the voice, the "at least 8 LU under" check fails); the found-you sting 8 dB up (`--break=sting`: the Scare bus +10.5 LU over the voice, and Master's true peak -0.3 dBTP).

## The Arboretum (18 Nov)

The floor uses recorded Oggs from the owner's ElevenLabs batch. The wind, crickets and the quiet air inside
the ring measure 14.2, 16.3 and 20.0 LU below file reference V, with LRA 0.6, 0.6 and 0.7 LU, respectively.
The ring begins at 10 m and the wind and insects are gone by 5 m. The existing Ambience and Effects duck still
applies. Footstep takes sit 6.1 to 6.3 LU under V on gravel, 8.1 to 8.3 on leaves, 12.0 to 12.3 on moss and
15.1 to 15.2 for a careful step in leaves, by momentary max. A creep on moss stays silent.

The Groundskeeper's breathing, badges and sniff use Entity. The catch uses the snatch on Scare within 4 m and
the shears on Entity at greater distances. The impacts in the decoded takes are 85 ms after the start for the
snatches and 149 ms after the start for the shears. Playback uses those offsets to meet the animation's blade
contact at 200 ms. The takes are short and use a momentary target, preserving the attack under the peak ceiling.

## The voice files

| File | I | Smax | LRA | TP |
|---|---|---|---|---|
| arrived_1.mp3 | -16.0 | -16.3 | 1.2 | -1.9 |
| arrived_2.mp3 | -16.2 | -17.2 | 20.0 | -1.8 |
| arrived_3.mp3 | -16.1 | -15.5 | 1.6 | -1.9 |
| arrived_4.mp3 | -15.9 | -16.8 | 1.3 | -1.9 |
| arrived_5.mp3 | -16.1 | -16.3 | 2.0 | -1.8 |
| banked_1.mp3 | -16.1 | -15.0 | 2.8 | -1.9 |
| banked_2.mp3 | -16.1 | -16.7 | 1.3 | -1.7 |
| banked_3.mp3 | -16.1 | -15.6 | 2.6 | -1.8 |
| bell_1.mp3 | -16.1 | -15.5 | 2.1 | -1.8 |
| bell_2.mp3 | -16.1 | -14.9 | 3.6 | -1.9 |
| bell_3.mp3 | -16.1 | -15.2 | 2.4 | -1.8 |
| bell_4.mp3 | -16.1 | -16.2 | 20.2 | -1.7 |
| bell_5.mp3 | -16.1 | -16.0 | 2.0 | -1.9 |
| blackout_1.mp3 | -16.1 | -15.6 | 1.4 | -1.8 |
| blackout_2.mp3 | -16.2 | -15.4 | 3.3 | -1.8 |
| blackout_3.mp3 | -16.2 | -16.8 | 3.0 | -1.8 |
| board_1.mp3 | -16.1 | -15.7 | 2.9 | -1.7 |
| board_2.mp3 | -16.2 | -14.7 | 3.3 | -1.8 |
| board_3.mp3 | -16.1 | -15.7 | 2.6 | -1.8 |
| board_4.mp3 | -16.1 | -14.4 | 5.5 | -1.7 |
| board_5.mp3 | -16.0 | -15.7 | 2.4 | -1.9 |
| called_1.mp3 | -16.2 | -15.5 | 4.0 | -1.9 |
| called_2.mp3 | -16.1 | -16.0 | 1.0 | -1.9 |
| called_3.mp3 | -16.2 | -16.1 | 3.2 | -1.8 |
| called_4.mp3 | -16.1 | -15.6 | 2.7 | -1.9 |
| called_5.mp3 | -16.1 | -16.5 | 20.0 | -1.9 |
| doors_1.mp3 | -16.2 | -15.3 | 5.5 | -1.8 |
| doors_2.mp3 | -16.1 | -15.8 | 1.8 | -1.8 |
| doors_3.mp3 | -16.2 | -15.6 | 2.2 | -1.8 |
| doors_4.mp3 | -16.1 | -16.5 | 1.7 | -1.8 |
| doors_5.mp3 | -16.1 | -14.8 | 4.4 | -1.8 |
| left_1.mp3 | -16.2 | -16.1 | 2.2 | -1.9 |
| left_2.mp3 | -16.1 | -15.7 | 2.6 | -1.7 |
| left_3.mp3 | -16.2 | -15.2 | 4.1 | -1.7 |
| left_4.mp3 | -16.1 | -16.7 | 20.0 | -1.9 |
| left_5.mp3 | -16.0 | -15.3 | 4.1 | -1.9 |
| lights_1.mp3 | -16.1 | -17.0 | 2.4 | -1.8 |
| lights_2.mp3 | -16.1 | -16.7 | 1.0 | -1.7 |
| resume_1.mp3 | -16.1 | -15.9 | 0.7 | -1.8 |
| resume_2.mp3 | -16.2 | -16.5 | 0.7 | -1.8 |
| ride_1.mp3 | -16.0 | -15.5 | 2.3 | -1.9 |
| ride_2.mp3 | -16.1 | -14.5 | 4.2 | -1.9 |
| ride_3.mp3 | -16.1 | -15.6 | 1.7 | -1.8 |
| ride_4.mp3 | -16.1 | -15.7 | 3.2 | -1.8 |
| ride_5.mp3 | -16.1 | -16.4 | 2.6 | -1.8 |
| slip_1.mp3 | -16.1 | -16.1 | 0.0 | -1.8 |
| slip_2.mp3 | -16.2 | -16.2 | 3.0 | -1.6 |
| taken_1.mp3 | -16.0 | -16.0 | 0.8 | -1.6 |
| taken_2.mp3 | -15.9 | -16.2 | 1.1 | -1.8 |
| taken_3.mp3 | -16.1 | -16.5 | 2.4 | -1.8 |
| taken_4.mp3 | -16.0 | -16.4 | 1.0 | -1.9 |
| wipe_1.mp3 | -16.1 | -16.4 | 1.3 | -1.8 |
| wipe_2.mp3 | -16.1 | -15.2 | 1.7 | -1.8 |
| wipe_3.mp3 | -16.1 | -15.7 | 2.0 | -1.6 |

## Search, inventory, shop and Annex recordings (18 Nov)

The 25 masters are 44.1 kHz mono Vorbis. One-shots were trimmed with attack and tail room, and loops use equal-power joins. Loudness was measured again after encoding, with every decoded true peak at or below -1.5 dBTP. The targets below use the -16.1 LUFS voice files as the reference. M is maximum momentary loudness and I is integrated loudness. The final masters are within 0.7 LU of their targets.

| File | Meter | Target LUFS | Master LUFS | True peak dBTP |
|---|---|---:|---:|---:|
| search/drawer_1, drawer_2 | M | -24.1 | -24.2, -24.1 | -11.6, -9.9 |
| search/locker | M | -24.1 | -24.3 | -8.0 |
| search/rifle_1 | M | -22.1 | -22.2 | -3.0 |
| search/carton | M | -24.1 | -24.3 | -7.4 |
| search/paper | M | -26.1 | -26.4 | -2.8 |
| search/drop_1, drop_2 | M | -22.1 | -22.0, -22.4 | -2.5, -1.9 |
| search/pickup | M | -26.1 | -26.2 | -12.8 |
| search/handoff | M | -26.1 | -25.9 | -2.5 |
| search/drink | I | -24.1 | -24.3 | -5.8 |
| shop/cabinet | M | -24.1 | -24.2 | -5.0 |
| shop/bought | M | -24.1 | -24.2 | -10.4 |
| shop/stamp_1, stamp_2 | M | -24.1 | -24.4, -24.4 | -1.7, -2.1 |
| shop/badge_trade | M | -24.1 | -24.2 | -4.9 |
| shop/flashbulb | M | -20.1 | -20.3 | -2.9 |
| shop/glow_stick | M | -24.1 | -24.4 | -3.3 |
| shop/toy_wind | M | -24.1 | -24.8 | -1.9 |
| shop/toy_run | I | -22.1 | -22.3 | -3.3 |
| shop/speed_juice | M | -24.1 | -24.4 | -2.0 |
| shop/smelling_salts | M | -22.1 | -22.3 | -8.3 |
| shop/low_nerve | I | -26.1 | -26.1 | -4.1 |
| annex/temp_walk | M | -24.1 | -24.2 | -2.8 |
| annex/temp_chase | M | -22.1 | -22.3 | -6.3 |

Careful openings play 10 dB below the usual Effects gain, for the searcher alone. The rushed cue plays at the furniture and a dropped item uses an 8 m range.

## Method

Each WAV is decoded to mono 44.1 kHz with a 30 Hz high-pass, cut to its best part, silence trimmed, faded (4 ms in, 40-400 ms out), loops made seamless with an equal-power crossfade of their tail into their head, then normalised: files of 3 s and more by two-pass `loudnorm` (pass 1 measures; pass 2 with the measured values, `linear=true`, TP -1.5), shorter ones by the same linear gain from `ebur128` (loudnorm cannot gate them). Where the gain would push peaks past -1.5 dBTP a sample-peak limiter takes them down first. Encoded Ogg Vorbis q3; any encoder overshoot past -1.5 dBTP is taken off. Where loudnorm refused to stay linear, plain gain was used instead (never its dynamic mode).
