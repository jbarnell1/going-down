# Sources: the roosting birds (Arboretum)

Every file here is synthesised in code, from nothing: `node assets_src/sfx/dangers/roost.mjs` rebuilds all five,
byte for byte (seeded arithmetic; ffmpeg only encodes the samples to mono Ogg Vorbis). No recording, no service.

Loudness (the script prints it; ffmpeg ebur128, V = the voice, -16.1 LUFS). Each is gained to a target, peaks limited
first where needed, true peak at most -1.5 dBTP. All play as the mix's "effect" category (Effects bus, max_db 0); the
game's test (test_danger_roost, test_its_sounds_sit_in_the_mix) holds each inside the effect band.
- roost_idle: I -24.3 (V-8.2), TP -2.0. roost_stir: I -22.2 (V-6.1), TP -1.9. roost_flush: S -20.6 (V-4.5 by
  short-term), M -14.3, TP -2.0. roost_circle: I -22.1 (V-6.0, played 14 dB under), TP -1.9. roost_settle: I -24.2
  (V-8.1), TP -3.4.

- roost_idle.ogg: synthesised in code. A settled roost: feathers shuffling high in a tree and a low throaty chuckle every few seconds (16 s loop, 3D at the canopy).
- roost_stir.ogg: synthesised in code. The same birds restless as someone walks near: dense shuffling, beak clacks, short sharp calls (4 s loop).
- roost_flush.ogg: synthesised in code. The roost going up: a clap of branches, 26 wingbeat trains climbing away, alarm calls, loud in the first half second (3.2 s, once).
- roost_circle.ogg: synthesised in code. Birds circling overhead after a flush, far off (8 s loop, played from a point circling above the tree).
- roost_settle.ogg: synthesised in code. A few birds dropping back in: soft flutters and two low chuckles (1.6 s, once).
