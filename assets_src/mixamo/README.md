# Animating the characters in Mixamo

The files to upload are in `assets_src/mixamo/export/`:

| File | Who | Pose it's in |
|---|---|---|
| `orderly.fbx` | The Orderly (Clinic) | T-pose |
| `crewmate.fbx` | The players' convict figure (what your friends see) | T-pose |

The `_front`, `_side` and `_back` pictures show what each file looks like.

Two characters can't go through Mixamo:

- **The Minder** walks on all fours, and Mixamo only rigs two-legged figures. It keeps its Blender animations.
- **The Temp** has no model file yet. It's built from boxes in code. If you want it in Mixamo too, I'll make it a proper Blender model first.

## Steps for each character

1. Sign in at mixamo.com (a free Adobe account).
2. Click **Upload Character** and pick the `.fbx`.
3. If the figure faces away or lies down, use the rotate arrows until it stands facing you.
4. Place the markers (chin, wrists, elbows, knees, groin) and leave **Skeleton LOD** on the standard setting.
   - The Orderly is very thin, with long arms and fingers. If the markers or the auto-rig come out wrong, tell me what you see.
5. Pick each animation from the lists below. For each one:
   - Tick **In Place** whenever it's offered. The game moves the character itself.
   - Leave **Overdrive** (speed) at the default unless the list says otherwise. Change **Character Arm-Space** only if the hands clip into the body.
   - Click **Download** with these settings:
     - Format: **FBX Binary (.fbx)**
     - Skin: **With Skin** for the FIRST download of each character, **Without Skin** for the rest
     - Frames per Second: **30**
     - Keyframe Reduction: **none**
6. Rename each file as listed (for example `orderly_walk_push.fbx`) and leave them all in your Downloads folder. Then tell me in chat and I'll take it from there.

The names in Mixamo's search change over time. The words below are what to search for. Pick whatever looks closest and feels right; you're the judge of creepy.

## The Orderly

Its sound is a trolley squeak, so its main walk should look like it's pushing something. I'll build the trolley itself and put it under its hands.

| Save as | What it is | Search for |
|---|---|---|
| `orderly_walk_push` | Slow walk pushing a cart or trolley in front of it. **The most important one.** | push, cart |
| `orderly_walk` | Slow, stiff, slightly wrong walk with no cart | walk, zombie, injured |
| `orderly_creep` | Very slow sneaking walk, for when it creeps up behind you | sneak |
| `orderly_hunt` | Fast, purposeful walk or lope (not a sprint). It chases at about a fast jog in the dark | run, zombie run, fast walk |
| `orderly_idle` | Standing almost still: a sway, a twitch | idle |
| `orderly_catch` | Bending or kneeling down over someone on the floor and grabbing at them | pick up, kneel, crouch, grab |
| `orderly_roar` | Rearing back and screaming or roaring | scream, roar, yell |
| `orderly_turn` (optional) | Turning on the spot | turn |

## The crewmate (your players): only the missing ones, optional

You already ran the crewmate through Mixamo. It has idle, walk, run, sneak, crouch idle, crawl, look behind, wave, pray, two dances, the button press and being taken. **Skip the upload** of `crewmate.fbx` and use the convict character already in your Mixamo account. These are the only clips it's missing, all for new features, all optional:

| Save as | What it is | Search for |
|---|---|---|
| `crew_down_idle` | Lying hurt on the floor, not moving much | lying, injured idle, dying |
| `crew_get_up` | Getting up from the floor (when a friend heals you) | getting up, stand up |
| `crew_help` | Kneeling beside someone and helping them (the friend holding F) | kneel, helping, revive |
| `crew_prone` | Lying flat, as if under a bed | prone, lying |
| `crew_sit` | Sitting (the party table) | sitting |
| `crew_point` | Point (emote) | point |
| `crew_cheer` | A happy cheer or dance (emote) | cheer, dance |
| `crew_scared` | Recoiling in fright (emote) | scared, terrified |

## What happens after

- I'll put the Mixamo skeletons into the game and swap them in for the Orderly's and the crewmates' current animations.
- I'll attach a trolley to the Orderly's hands.
- I'll check that feet don't slide at the game's real walking speeds.
- The hats and hair on the crewmates were left out of the upload. They get reattached to the head in the game.
