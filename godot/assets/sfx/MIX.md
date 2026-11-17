# The mix

How every sound sits against the elevator voice, and why. Measured with ffmpeg `ebur128` (integrated loudness I, short-term max S over 3 s windows, loudness range LRA, true peak TP). Regenerate the files with the scratch pipeline described under *Method*; check the result in the game with `node godot/tools/mix_check.mjs` (GODOT set).

## The reference: the voice

The 54 elevator voice files average **V = -16.1 LUFS** integrated (each -16.0 to -16.2), true peak at most -1.6 dBTP. The announcer plays them at -5 dB (announcer.gd); every other sound plays at that same -5 dB (`Sfx.BASE_DB`), so a file's loudness relative to V is its loudness relative to the voice in the game. On the desktop the Voice bus (ceiling-speaker band-pass and compressor) costs about 9 dB, so its compressor's make-up gain is 12.8 dB: measured in the game, V comes out at -17.6 to -18.2 LUFS on the desktop, the same as in the browser (where bus effects do not run).

## Targets by category

| Category | Target | Why |
|---|---|---|
| Orderly approach (trolley roll, squeak) | I = V-3 | The thing you must hear first. It is only heard unseen (behind you, round a corner), where 3D panning costs about 7 dB, so it plays 7 dB up and falls 3 dB with the rules' audibility; through a wall the Entity low-pass takes more and 5 dB is given back. Measured: about V-5 close behind you, V-11 at the edge of the rules' hearing range (34 m), never lower than V-12 (checked). |
| Orderly near (slow breathing, rattle) | I = V-3 | Close, quiet, but plain when it is right there. 3D: full level within 1.5-2 m, gone by 10-14 m. |
| Orderly small (quick breath, gown, tray, thud, chewing) | I = V-6 | Detail under the approach. |
| Scares (roar, shrieks) | short-term max = V+3 | The owner: louder than the voice, not by much. Ceiling V+4 (checked), TP -1.5 on the file, -1 after the Master limiter. Nothing else may pass the voice. |
| Room tones (slams, drip, intercom, monitor, bed roll) | I = V-10 | Far-off life in the building, at its 3D reference distance (3 m); further is quieter. |
| Ambient beds (hum, vent, drone, ride rumble) | I = V-14, LRA under 1 | Always there, never in the way; the vent plays 4 dB under, the ride 4 dB over. |
| Effects (blink flicker) | I = V-6 | A warning you must notice. The tube pop: short-term V-2. |
| Player (winded breathing) | I = V-8 | Yours, close, under the world. |
| Footsteps | momentary max V-8 | Too short to gate: by momentary loudness. |
| UI (generated chimes, dings, bell, ticks) | momentary max V-8 | `Sfx.SYNTH_DB` puts each generated stand-in there (measured with tools/sfx_levels.gd). |

## Buses and orchestration

- Buses (default_bus_layout.tres): Voice, Entity, Scare, Effects, Ambience, UI, all into Master, which has a hard limiter at -1 dBTP. Entity carries the Orderly and is never ducked; its low-pass (4 kHz) is the muffling when the rules say a wall is in the way, and 5 dB is given back for it.
- While the announcer speaks, Effects and Ambience duck by 6 dB (the bus faders, 30 dB/s, so it works in the browser too; checked there by tools/sound_web.mjs).
- Every 3D sound has its category's unit size and max distance and never plays louder than its file however close (`max_db` 0). The trolley has no distance attenuation of its own: its loudness is the rules' audibility.
- Room tones: at most one at a time, at least 9 s apart, none for 8 s after a scare, none while the Orderly is coming within 20 m unseen, the bed only while the Orderly is watched, the intercom not in the dark. Timing and place come from the floor seed and the host's clock (16 s slots), so every player hears the same tone at the same moment from the same place.
- Shrieks: never two within 45 s, never while it is seen, only when it starts moving unseen; chances are seeded per floor and per release, so they agree between players and cannot be learnt as a schedule.

## What the game measured (tools/mix_check.mjs, the busy minute)

Desktop, headless, 76 s: V = -17.9 LUFS. Short-term max per bus against it: Entity -1.0 LU, Effects -3.9, Ambience -12.7, UI -13.4, Scare +3.3 (ceiling +4); Master true peak -2.0 dBTP; the Orderly coming on unseen never quieter than V-11.2 within hearing (at 33 m, the edge of the rules' range); Ambience at least 18.8 LU under the voice while it speaks. Breaks that turn it red: no duck (Ambience -12.9 LU under the voice while it speaks), the hum 12 dB up (-8.4), the roar 3 dB up (+6.4 LU over the voice).

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

## Method

Each WAV is decoded to mono 44.1 kHz with a 30 Hz high-pass, cut to its best part, silence trimmed, faded (4 ms in, 40-400 ms out), loops made seamless with an equal-power crossfade of their tail into their head, then normalised: files of 3 s and more by two-pass `loudnorm` (pass 1 measures; pass 2 with the measured values, `linear=true`, TP -1.5), shorter ones by the same linear gain from `ebur128` (loudnorm cannot gate them). Where the gain would push peaks past -1.5 dBTP a sample-peak limiter takes them down first. Encoded Ogg Vorbis q3; any encoder overshoot past -1.5 dBTP is taken off. Where loudnorm refused to stay linear, plain gain was used instead (never its dynamic mode).
