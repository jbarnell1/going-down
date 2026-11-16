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

## 2. Motion-captured movement for the crewmates (Mixamo, free with an Adobe account)

This is the one that pays off most: players watch each other move all the time, and today crewmates are boxes. (The Orderly is only ever seen standing still, so its movement matters far less.)

1. Create a free Adobe account and sign in at mixamo.com. No download or payment is needed.
2. Click "Upload Character" and choose `assets_src/inbox/convict-for-mixamo.fbx` (the loop builds this file; if the upload is refused, use `convict-for-mixamo.zip`). Place the markers on chin, wrists, elbows, knees and groin when it asks. For "Skeleton LOD" choose **No Fingers**. It rigs the figure itself; check the preview walks without the arms or legs tearing.
3. Search for and download these clips (names vary; pick the plainest, least athletic version of each):
   - `idle` (a tired standing idle, "breathing idle")
   - `walking`
   - `running` (a jog or run, not a sprint start)
   - `sneak walk` or `crouched walking`
   - `crouch idle`
   - `looking behind` or `look over shoulder`
   - `button pushing` (calling the lift)
   - `falling back death` or `being grabbed` (taken by the Orderly)
   - `crawling` (a downed player)
   - `terrified` or `cowering` (optional)
4. Download settings: format **FBX Binary (.fbx)**; the FIRST clip **With Skin**, every later clip **Without Skin**; 30 frames per second; keyframe reduction **none**; tick **In Place** for walking, running, sneaking and crawling when the option appears.
5. Save them as `assets_src/inbox/mixamo/<what-it-is>.fbx`, for example `mixamo/walking.fbx`, `mixamo/idle.fbx`. The loop picks them up, trims and loops them, and bakes them into the game's crewmate model.

For the Orderly, one clip is worth getting later with the same account: a slow two-handed `reaching` or `zombie grab`, for the being-caught sequence. It needs an upload file of its own, which the loop will make when that sequence is built.

**Licence:** Mixamo's clips may be used in a game, including a commercial one, but the raw files may not be handed on by themselves. That is why this folder stays out of git: only the finished game model with the movement baked in is published.

## 3. Free prop kits

Public-domain kits (Kenney, Quaternius, Poly Haven) are fetched by the loop itself once the owner has seen the list of files and sizes. Nothing needs doing here.
