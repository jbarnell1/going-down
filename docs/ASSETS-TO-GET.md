# Assets to get

One list of everything the game is waiting on from outside: Mixamo animation clips and ElevenLabs sound effects. Written 18 November 2026. Tick things off here as they arrive.

**Where to put files:** leave everything in your Downloads folder with the names given here, then tell either agent "the files are in Downloads". Only your new files are copied; nothing else there is touched.

**Order that helps most:** section 1 (the Temp in Mixamo), then the starred sounds in section 4 (the Arboretum), then the rest as you have time. Nothing here blocks Friday: every item has a stand-in today.

Already in hand, do not redo: every sound on the 16 and 17 November lists (the Clinic, the Annex, the Playroom, the prison, the lift, the call button and quota chime), and the crewmate's first thirteen Mixamo clips.

---

## Mixamo (free, mixamo.com, an Adobe account)

The files to upload are in `assets_src/mixamo/export/`. Full steps are in `assets_src/mixamo/README.md`. The settings for every download:

- Tick **In Place** whenever it is offered.
- Format **FBX Binary (.fbx)**, **30** frames per second, keyframe reduction **none**.
- Skin: **With Skin** for the first download of each character, **Without Skin** for the rest.
- Names in Mixamo's search change. Search the words given, pick what looks closest and creepiest.

### 1. The Temp (upload `temp.fbx`): 8 clips. Most wanted: it has no real movement yet.

| Save as | What it is | Search for |
|---|---|---|
| `temp_walk` ★ | A tired, shuffling office walk, shoulders down | walk, tired, sad walk |
| `temp_chase` ★ | A fast, stiff, purposeful walk, not a sprint | fast walk, speed walk, hurried |
| `temp_idle` ★ | Standing nearly still, a small sway, head tilted | idle, standing |
| `temp_wait` | Standing and looking slowly around | looking around, waiting |
| `temp_staple` | A short jab forward with the right hand at chest height | punch (short), stab, jab |
| `temp_catch` | Reaching out with both hands and grabbing | grab, reaching, zombie attack |
| `temp_write` (optional) | Writing on something held in the left hand | writing, taking notes |
| `temp_turn` (optional) | Turning on the spot | turn |

### 2. The Orderly (upload `orderly.fbx`): 8 clips

| Save as | What it is | Search for |
|---|---|---|
| `orderly_walk_push` ★ | Slow walk pushing a cart in front of it | push, cart |
| `orderly_walk` | Slow, stiff, slightly wrong walk, no cart | walk, zombie, injured |
| `orderly_creep` | Very slow sneaking walk | sneak |
| `orderly_hunt` ★ | Fast, purposeful walk or lope, not a sprint | run, zombie run, fast walk |
| `orderly_idle` | Standing almost still: a sway, a twitch | idle |
| `orderly_catch` ★ | Bending down over someone on the floor and grabbing | pick up, kneel, crouch, grab |
| `orderly_roar` | Rearing back and screaming | scream, roar, yell |
| `orderly_turn` (optional) | Turning on the spot | turn |

### 3. The crewmate (use the convict already in your Mixamo account; skip the upload): 8 clips, all optional

| Save as | What it is | Search for |
|---|---|---|
| `crew_down_idle` | Lying hurt on the floor | lying, injured idle, dying |
| `crew_get_up` | Getting up from the floor | getting up, stand up |
| `crew_help` | Kneeling beside someone and helping | kneel, helping, revive |
| `crew_prone` | Lying flat, as if under a bed | prone, lying |
| `crew_sit` | Sitting (the party table) | sitting |
| `crew_point` | Pointing (emote) | point |
| `crew_cheer` | A cheer or dance (emote) | cheer, dance |
| `crew_scared` | Recoiling in fright (emote) | scared, terrified |

**Not yet:** the Groundskeeper. Its real figure is not built; when it is, its file and clip list will be added here. The Minder walks on all fours and cannot go through Mixamo.

---

## ElevenLabs sound effects

Paste each prompt as it is. "Loop" means ask for a loop (or make sure it starts and ends cleanly). "Takes" means download that many different results. Any file name is fine: the name of the sound in the file name is enough.

### 4. The Arboretum and the Groundskeeper: 21 sounds. Every one of these is made by code today.

| # | Sound | Prompt | Length |
|---|---|---|---|
| A1 ★ | Wind in leaves | gentle night wind moving through tree leaves in a large enclosed garden, soft and steady, no birds, no people | 20 s, loop |
| A2 ★ | Crickets | crickets chirping at night in a quiet garden, steady, close, no wind | 20 s, loop |
| A3 ★ | The garden gone quiet | very quiet indoor garden at night, faint air hum, almost silent, no insects, uneasy stillness | 15 s, loop |
| A4 | Sprinkler | a lawn impact sprinkler ticking steadily in the distance | 8 s, loop |
| A5 | Owl | a single owl hoot far away at night, echoing slightly in a large hall | 3 s, 2 takes |
| A6 ★ | Step on dry leaves | one single footstep on dry leaf litter, crunchy, close | 0.5 s, 4 takes |
| A7 ★ | Step on moss | one single soft footstep on damp moss, muffled, very quiet | 0.5 s, 4 takes |
| A8 ★ | Step on gravel | one single footstep on a loose gravel path, crunchy, close | 0.5 s, 4 takes |
| A9 | Creeping step | one very slow careful footstep on dry leaves, a quiet rustle | 0.5 s, 2 takes |
| A10 ★ | Twig crack | a dry twig snapping underfoot, sharp crack, close, at night | 0.5 s, 3 takes |
| A11 | Pinecone in leaves | a pinecone landing in dry leaves, soft thud and rustle | 1 s, 2 takes |
| A12 | Pinecone on gravel | a pinecone landing on gravel and rolling a little | 1 s, 2 takes |
| A13 | Shed door | an old wooden garden shed door creaking open and thudding shut | 2 s |
| A14 ★ | Badge clink | small metal ID badges on a cord knocking together, one single soft clink | 0.5 s, 6 takes |
| A15 | Badges swinging | a bunch of small metal tags swinging slowly on a cord, gentle irregular clinking | 6 s, loop |
| A16 ★ | Its breath | slow, wet, patient breathing of a large creature through bark and cloth, very close, quiet | 8 s, loop |
| A17 | A sniff | one long slow sniff from a large creature, close | 2 s, 2 takes |
| A18 ★ | Shears | long-handled garden shears snapping shut, metallic snip, close | 1 s, 2 takes |
| A19 ★ | The snatch | a sudden rush through dry leaves and a sharp metallic snip, then silence | 2 s, 2 takes |
| A20 | Its call, far off | a long low creaking groan like a great tree bending, distant, mournful, echoing in a large hall | 4 s, 2 takes |
| A21 | Swing | an empty playground swing creaking slowly on its chain | 6 s, loop |

### 5. Searching and the inventory: 9 sounds. Today these reuse older recordings.

| # | Sound | Prompt | Length |
|---|---|---|---|
| S1 ★ | Drawer | a wooden desk drawer pulled open, small things rattling inside | 1 s, 2 takes |
| S2 | Locker | a metal locker door opening with a squeak | 1.5 s |
| S3 ★ | Rifling | someone hurriedly rummaging through a drawer full of objects, loud clatter | 1 s, 2 takes |
| S4 ★ | Carton found | a small cardboard juice carton picked up, a light slosh of liquid | 0.5 s |
| S5 | Paper note | a folded paper note being unfolded | 1 s |
| S6 ★ | Item dropped | a small object dropped on a tiled floor, one light clatter | 0.5 s, 2 takes |
| S7 | Item picked up | a hand picking a small object up off the floor, soft cloth rustle | 0.5 s |
| S8 | Handed over | a small object passed from one hand to another, a soft pat | 0.5 s |
| S9 | Drinking | quick gulps from a small carton through a straw, then a gasp | 2 s |

### 6. The shop, the cabinet and the skills: 11 sounds. For features being built this week.

| # | Sound | Prompt | Length |
|---|---|---|---|
| P1 | Cabinet | a small metal cabinet door opening with a squeak and closing with a clack | 2 s |
| P2 | Bought | an old mechanical cash register, one short ka-ching, slightly cheap | 1 s |
| P3 | Stamped | a rubber stamp thumped onto paper on a desk | 0.5 s, 2 takes |
| P4 | Badge handed in | a metal badge dropped into a metal counter tray, a clink and a slide | 1 s |
| P5 | Flashbulb | an old camera flashbulb popping, then a high charging whine | 1.5 s |
| P6 | Glow stick | a glow stick snapped and shaken | 1 s |
| P7 | Toy wound up | a tin wind-up toy's key being turned, ratchet clicks | 2 s |
| P8 | Toy running | a small tin wind-up toy rattling and clattering across a hard floor | 6 s |
| P9 | Speed juice | a drinks can cracked open and fizzing, one quick gulp | 1.5 s |
| P10 | Smelling salts | a sharp sniff, then a loud startled gasp awake | 1.5 s |
| P11 | Low nerve | a slow heavy heartbeat, muffled, close | 8 s, loop |

---

## Not needed from you

- The announcer's lines: made here on your ElevenLabs account, inside the character cap.
- Textures and drawn signs: made here.
- Figures: built in Blender here. A better sculpted body for a resident from an image-to-3D service is optional; the note for that is `assets_src/inbox/README.md`.
