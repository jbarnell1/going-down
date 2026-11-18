# Groundskeeper motion handoff

All six takes are in the game model. To retarget a future replacement on the same character, use the [upload FBX](../../mixamo/export/groundskeeper.fbx). Export FBX Binary at 30 fps with no keyframe reduction, using In Place for locomotion when available.

## Groundskeeper takes in the game

| Game clip | Download filename | How it is used |
|---|---|---|
| Listen | `Looking Around (1).fbx` | The planted take drives the subtle idle motion. |
| Approach | `Injured Run.fbx` | A full stride cycle. The host moves the figure. |
| Hearing reaction | `Agony.fbx` | Hands reach the temples by 0.20 seconds. The tool stays in the right hand. |
| Sweep | `Looking Around.fbx` | The torso and arm turn play with feet planted. |
| Lean | `Reaching Out.fbx` | The reach blends into the authored hold and recovery. |
| Snatch | `Vampiric Bite.fbx` | The forward grab lands with the authored blade closure at 0.20 seconds. |

All six were downloaded for the Groundskeeper upload. The finished GLB carries the motions on the existing game rig. Keep the original motion FBXs in the private asset inbox for reproducible builds.
