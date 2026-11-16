# Going Down

A co-op suspense game for the browser. A crew rides an elevator down through a building that gets worse on every floor, and gets paid for getting close to the things that live there.

![The Orderly, first pass, standing in the Clinic](assets_src/renders/orderly/player_view.png)

*The Orderly, first pass. It gets a second one.*

> **Status: very early.** There is no playable build yet. This repository is being built in the open by an AI-assisted work loop, one verified step at a time. "Going Down" is a working title.

## The idea

- **Barely able to fight back.** No weapons. The most you have is a flare that buys a few seconds.
- **Dread you can see coming.** Every entity is heard before it is seen, and seen before it can reach you.
- **Nobody survives alone.** Up to eight players, built around four. A downed player moves to the cameras and keeps playing.
- **Greed drives the run.** Pay comes from readings, and the instrument only records the scary part. After every floor the crew votes: bank it, or ride down.
- **Trust nothing but each other.** The deeper you go, the less two players see the same floor.
- **Scream, then laugh.** A relentlessly cheerful elevator voice narrates all of it.
- **Never the same twice.** Every floor is a different place built from a seed: a clinic with every light on, an endless yellow office, a forest indoors.

Entities follow rules they never break. Learning the rule is how you survive, and testing it is how you get paid.

## How it is built

| Part | Choice |
|---|---|
| Game | TypeScript, three.js, Vite. First-person, under a low-resolution tape-playback look. |
| Multiplayer | Peer to peer in the browser. One player hosts. No game server, no accounts. |
| Rules | A pure logic layer with no rendering, so hundreds of runs can be simulated in tests. |
| Characters | Modelled, rigged and animated in Blender by script. Each script rebuilds its figure from nothing. |
| Checks | Vitest for the rules, Playwright for the real game, gitleaks on every push. |

### Where things are

- `loop/` : how the work is run. `LOOP.md` is the rulebook for one iteration, `ENDPOINT.md` is the list of gates that define "done", and `PROGRESS.md` is the live state with evidence for every finished task.
- `docs/VOICE.md` : how the elevator voice is written and directed.
- `assets_src/blender/` : the scripts that build each character. `assets_src/renders/` has their review renders.
- `hub/` : a small local server for checking in on the latest build, the loop's status, and open design questions.
- `src/` : the game, once the first task lands.

## Running it

Nothing to run yet. Once project setup lands:

```bash
npm ci
npm run dev
```

Useful flags on the URL: `?bots=3` fills the crew with bot players so one person can test everything, `?debug=1` opens a test panel, `?seed=` picks the building.

## Credits and inspirations

Mechanics here owe a debt to Lethal Company, R.E.P.O., Content Warning, Phasmophobia, Spooky's Jump Scare Mansion, The Mound: Omen of Cthulhu, Escape the Backrooms and PEAK, and to two friends' browser games that started this, [EmberDeep](https://github.com/DNDNoob/EmberDeep) and [Abyssal Garden](https://github.com/Noniv/abyssal-garden). The characters, places and look are this game's own.

Third-party assets and their licences are listed in `CREDITS.md` as they are added.

## Licence

Not yet chosen. Until a licence file is added, all rights are reserved.
