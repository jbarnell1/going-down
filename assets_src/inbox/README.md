# Inbox: assets made outside this repository

Drop files here and the work loop picks them up. Everything in this folder except this file is kept out of git, because files from outside services carry their own licences. Only finished game assets built from them are committed, with credit in `CREDITS.md`.

## 1. A sculpted body for the Orderly (an AI 3D service such as Meshy or Tripo)

The figure in the game is built by script, which caps how organic it can look. An image-to-3D service gives a far better body to start from; it is then rigged, dressed and textured in Blender to match the game.

**What to generate**

- Mode: image to 3D if offered, using `assets_src/renders/orderly/turn_front.png` as the picture (add `turn_side.png` and `turn_back.png` if the service takes several views). Otherwise text to 3D with this prompt:

  > A very tall, emaciated humanoid hospital orderly, 2.6 metres, standing in a relaxed A-pose with arms slightly away from the body. Far too thin, long neck pushed forward, shoulders hunched up toward the ears, long forearms and very long fingers, knobbly elbows, wrists and knees, bare feet with long toes. Wearing a torn, stained pale hospital gown open at the back showing the spine, a puffy paper surgical cap, and a pleated surgical mask covering the lower face. Above the mask the eyelids are sunken and sewn shut with thick thread. Waxy yellow-white skin with faint veins. Unsettling, not gory. Full body, neutral grey background, even lighting, no props, no base.

- Pose: A-pose or T-pose, arms away from the body, fingers apart. No rigging and no animation from the service: that is done here.
- Detail: ask for a low or medium polygon count if there is a setting (about 10,000 to 30,000 triangles). Textures on, 1K or 2K.
- Format: `.glb` if offered, otherwise `.fbx` with textures.
- Save as `assets_src/inbox/orderly-sculpt.glb` (or `.fbx`). Two or three different attempts are welcome: name them `orderly-sculpt-1.glb`, `-2`, and so on.

**Licence to check before generating:** on free plans these services usually publish what you make under a share-with-credit licence (Meshy's free plan has been CC BY 4.0), while paid plans let you keep it private. Either works for this project, which is public; a credit line is added if one is required. Write the service, the plan and the date in a file `orderly-sculpt.txt` beside the model.

## 2. Motion-captured movement (Mixamo, free with an Adobe account)

1. Sign in at mixamo.com and upload the character: use `public/assets/entities/orderly.glb` converted to FBX (the loop can make `assets_src/inbox/orderly-for-mixamo.fbx` on request), or the sculpt from step 1 once it exists. Place the markers when it asks; it rigs the figure itself.
2. Search for and download a handful of clips. Useful searches: `zombie walk`, `injured walk`, `mutant walk`, `sneak` or `crouched walk`, `breathing idle`, `looking around`, `reaching`, `crawl`, `stand to crouch`. Pick slow, wrong-looking ones over athletic ones.
3. Download settings: format FBX Binary; the FIRST clip "With Skin", all later clips "Without Skin"; 30 frames per second; no keyframe reduction; tick "In Place" for walks when the option appears.
4. Save them as `assets_src/inbox/mixamo/<what-it-is>.fbx`, for example `mixamo/injured-walk.fbx`.

**Licence:** Mixamo's clips may be used in a game, including a commercial one, but the raw files may not be handed on by themselves. That is why this folder stays out of git: only the finished game model with the movement baked in is published.

## 3. Free prop kits

Public-domain kits (Kenney, Quaternius, Poly Haven) are fetched by the loop itself once the owner has seen the list of files and sizes. Nothing needs doing here.
