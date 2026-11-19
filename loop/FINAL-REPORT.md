# Going Down release report

**November 19, 2026 · Release checks in progress**

## How to play

Extract the friends ZIP and open `GoingDown.exe`. Choose **Join Friends**, make your face, then enter the room details from your host and Ready up. Choose **Play Alone** for a local game.

Walk with **WASD**, look with the mouse, sprint with **Shift** and creep with **C**. Press **E** to bring out the instrument and hold **right mouse** to raise it. **F** calls the lift, holds the doors or picks up a dropped tape. Ride on the **BANK** side to bring your earnings home. In prison, hold **F** at your bunk to sleep. [More controls](../godot/README.md)

The separate floor-review package opens from **Host Playtest** on the title screen. **F6** opens the floor picker while you are in that sandbox.

## What we checked

| Build | Result |
| --- | --- |
| `561377f509` · promoted release | The Windows executable, the executable inside `GoingDown-2026-11-18-1721.zip` and the Godot browser pack match the recorded release. |
| `d95940a12f` · checked fallback | The local suite passed 598 checks. The matching fallback exports passed 46 browser checks and 15 server checks. This build predates the companion Practice fix. |
| `review-5ced23ce4c` · private Windows review | A fresh local crew of one player and three companions completed Practice and entered paid Clinic. Two peers kept separate purchases, badges and receipts across a relaunch. The separate floor reviews passed. |

An independent review found that the lift omitted the numerical odds before a wipe with four or more upgrade owners. The fix showed each owner's odds before settlement in an eight-player replay. An earlier four-tab run finished three loss and restart cycles without reloading. [Gate record](PROGRESS.md)

## Open gates

- **G12 · Final validation.** Record the review disposition and verify an outside player can use the extracted friends ZIP to Ready up and enter a playable floor on the matching server. A loopback rehearsal reached Ready-up using the packaged client.
- **G14 · Live browser and companions.** Homelab Play previously opened the retired TypeScript prototype. Verify the served Godot `/play/` build matches the selected release. On that page, `?bots=3` must complete a paid Clinic shift with walking, readings, catches and votes. `?debug=1` must show the test panel in local play. Confirm CI for the selected main commit and check the gitleaks workflow history. [Gate criteria](ENDPOINT.md) · [CI workflow](../.github/workflows/ci.yml) · [Secret-scan workflow](../.github/workflows/gitleaks.yml)
