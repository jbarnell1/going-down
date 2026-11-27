# Art notes: characters

Notes from studying two Blender tutorials before the second pass of the first enemy, the Orderly,
and the rules that came out of it for the characters still to come. Every character in this game is
built by a Python script run in headless Blender, so each technique below is sorted into what a
script can do and what needs a hand on a sculpting brush.

How the tutorials were studied: captions read in full, and about twenty still frames sampled evenly
through each video and looked at one by one. Motion could not be watched in real time, so anything
that depends on timing (how a pose is held, how fast a brush stroke moves) is inferred from the
narration and from frames before and after, not seen.

## 1. "How to create a Horror Character in Blender | Tutorial", David Kohlmann

https://www.youtube.com/watch?v=Pwh6yqcfz5Y (about 30 minutes, Blender 4.0)

A head for a horror character, taken from a blocked-out cube through sculpting, retopology, UVs and
a procedural skin material. What I took from it:

- **Block out first, detail second.** He starts with a mirrored cube cut into a few loops and only
  adds subdivision once the big shape (skull, jaw, sockets) reads. The silhouette has to be right
  before anything else is worth doing. *Script: yes.* Every part of the Orderly is a short table of
  rings (height, width, depth) that is cheap to change, and the detail goes on top.
- **The eye sockets carry the face.** The frames that matter most show a smooth head with two huge,
  empty sockets, and later the sockets filled with something that should not be there. The horror
  is in replacing what belongs in the eyes. *Script: yes for the idea.*
- **Concentric loops round an opening.** When he retopologises, he lays rings of edges round each
  socket and extrudes them backwards into the skull, keeping the same number of faces above, below
  and to each side. *Script: yes.* It is a loop of rings stepping inward and back, which is exactly
  what a ring-tube builder already does.
- **Break the mirror.** He removes the mirror modifier near the end so the face stops looking
  generic. *Script: yes.* One parameter makes one side lower or bigger than the other.
- **Paint the shadows into the colour.** Redder, darker colour where blood would pool (around the
  mouth and eyes), lighter where bone is close to the skin. *Script: yes, crudely.* A script cannot
  paint, but it can pick a darker or lighter patch of the texture for each face, from where that face
  sits on the body.
- **Sculpted wrinkles, Voronoi bump layers, subsurface scattering, slime particles, veins painted
  with an image brush.** *Script: no, or not worth it.* These need a brush, a high-poly mesh or a
  renderer the game does not have. At 480x270 with flat shading and a 512 px texture they would not
  show anyway.

## 2. "3 Steps to Rig YOUR PS1 Style Game Character in Blender | Tutorial", Stark Crafts

https://www.youtube.com/watch?v=okG86ApjFjg (about 8 minutes)

A low-poly, retro-style game character rigged in three steps: place a stock rig, parent with
automatic weights and fix them, then add IK for posing. What I took from it:

- **Delete the bones you do not need.** He deletes the face bones from the stock rig straight away,
  and warns about a hidden one. A small rig is easier to animate and cheaper to run. *Script: yes.*
  The Orderly has 39 bones and no face bones, because the face is a mask and an empty socket.
- **Weights blend across a joint over a few rings, not at one edge.** The weight-paint frame shows a
  gradient from blue to red across the elbow region. *Script: yes.* Each ring of a limb carries its
  weights, and the rings either side of a joint are split 85/15, 50/50, 15/85.
- **Extra geometry where things bend.** Low-poly limbs collapse at the joints unless a joint has a
  ring of its own. *Script: yes.* Knees, elbows, wrists and every finger joint get a slightly fatter
  ring, which also reads as a bony knuckle.
- **Knees face forward, elbows bend back.** His IK pole for the elbow sits behind the arm and the
  knee's in front. *Script: yes, without IK.* The rest pose already has a small bend in each elbow
  and knee, so the stepped keyframe poses bend the right way.
- **Separate pieces are fine.** His character is split into body, arms and head for modularity.
  *Script: noted.* The Orderly stays one skinned mesh on one armature, which is the cheapest thing
  for the game to draw, but gown, sleeves and mask are open shells laid over the body, not welded.
- **Pose by hand in pose mode, IK for comfort.** *Script: partly.* Stepped poses are authored as
  short lists of rotations per bone, which is clearer than keying IK targets for an 8-pose-a-second
  walk.

## Where it went into the Orderly

- Sealed eye sockets built as six concentric loops stepping back into the skull, from tutorial 1.
  The head's own faces are cut away inside the outer loop, and the loops are painted from skin to
  near black, with a seam and a few stitches across.
- The right socket sits a little lower and is a little bigger than the left; the left shoulder is
  bare and hitched up, the right dropped and forward. Breaking the mirror, from tutorial 1.
- Painted shadow per face: the gaps between ribs, under the belly and behind the knees take a dark
  patch of the atlas, and the points of bones (elbows, knuckles, spine, ankles) a light one, so the
  body reads under the game's flat light.
- 39 bones, no face bones; every joint has its own ring with weights blended over three rings; elbows
  and knees pre-bent in the rest pose (tutorial 2).

## Rules for this game's characters

1. **Read the silhouette at 480x270 first.** Render the figure 20 m down a Clinic corridor at the
   game's resolution before adding any detail. If it does not read as a shape there, nothing else
   will save it.
2. **Frighten in full light.** Proportion, posture and one wrong detail; never rely on darkness.
   The figure should be darker than the white walls so it stands out as a shape.
3. **One wrong thing in the face, bold enough to see at 10 m.** Big shapes and hard contrast; thin
   lines vanish at this resolution.
4. **Break the symmetry on purpose.** Uneven shoulders, one side of the face lower, one hand curled.
5. **Shadows go into the texture.** Pick darker patches of the atlas for crevices and lighter ones for
   bone points, per face, from the script.
6. **A ring at every joint**, weights blended over three rings, and a slight bend in the rest pose so
   joints fold the right way.
7. **Small rigs.** No face bones; up to about 40 bones and 8,000 triangles; one 512 px texture with
   nearest filtering; one material.
8. **Stepped motion for anything that should feel wrong** (8 poses a second, constant interpolation),
   smooth motion only for breathing. Keep the head level while the body moves.
9. **Everything in one script, parameters at the top**, so a critique becomes a one-line change.
10. **Check the export in a fresh Blender process**: triangle and bone counts, action names and
    lengths, the texture filter, and the height of every pose.
11. **Posture is the character.** The idle is what players see most. Judge it from the FRONT at
    40 m: a hunch disappears head-on, so the shape needs width that a person standing normally would
    not have (the Orderly's elbows stand out from hands folded at the chest). Bend it as an S, never
    as a straight plank leaning from the ankles: knees soft, pelvis forward, the fold at the top of
    the back, the head carried out in front.
12. **Contact poses need a solver, not guessed angles.** Hands resting in each other, a hand on a
    rail: solve the arm on the real rig (coordinate descent over a few rotations until the wrist
    lands on a target) and keep the hand itself "level" in world space.
13. **Faces at game size stop being faces.** A thick printed line reads as an emoji at 480x270. Thin
    lines, wider than a real feature could be, slightly uneven, read as wrong instead of cute. Two
    big dark holes read at 15 to 20 m; small detail inside them only reads up close, so keep that
    detail dull (no light stitches that turn into a second little face).
14. **Sit in the room's light.** Shade entities with the same model as the world (Lambert here),
    keep their darkest tones above near-black, keep texture noise to a percent or so (it turns into
    crawling grain at low resolution), and cast the shadow straight down as a soft pool touching the
    feet, the way overhead panels would.
15. **Give it a job, not a disguise.** Original horror figures come from what they are for. Hospital staff: a gown
    with a small repeating print, a wristband, the open tied back, and the courtesy of a hand offered
    palm up. Nothing faceless or suit-like.

## What blind judges caught

Two rounds of blind judging on the Orderly found these traps. Check every new character against them
before showing it.

- **Dark eye holes read as sunglasses at game size.** Two big black discs above a mask turned a
  horror into "a guy in disguise". Missing or closed eyes need pale lids and dark marks across them
  (stitches), not dark holes.
- **Grey, thin, grinning figures echo existing characters.** A grey stick figure with round black
  eyes and a wide grin recalled several well-known characters at once. Flesh tone, costume and
  headgear (here waxy skin, a paper bouffant cap and a real surgical mask) do more for originality
  than proportions do.
- **Even-thickness limbs read as pipe.** Swell every joint (knee, elbow, wrist, knuckle) into a knob
  and taper the limb between them; give feet an arch and curled toes, never flat paddles.
- **A printed smile reads as an emoji unless it breaks the mask's edge.** A thick, neat smile inside
  the mask is a smiley face. A thin, uneven, too-wide line that runs off the mask onto the skin, with
  bleed and stains, reads as something done to the face.
- **Stretching a whole arm reads as a cartoon gadget.** Lengthen one segment (the forearm) and keep
  a real bend at the elbow.
- **Hidden surfaces show at the seams.** Skin under clothing pokes through when a pose moves it.
  Paint the hidden parts (shoulder tops, the roots of the arms) with the cloth's texture, so if they
  show, they show as cloth.
- **Pale sits in the room; dark reads at distance.** Lifting the tones made the figure belong to the
  bright corridor but cost contrast at 16 to 40 m. Get distance readability from silhouette (elbows
  out, a tilted head), not from darkness.

## Third pass: Gemini textures and the torn gown (2026-11-16)

Textures now come from `assets_src/textures/generate.mjs` (model `gemini-3.1-flash-image`, see the
README there for the budget rule and the style block). 18 images, about $0.72 by the ledger.

What the image model did well and badly:

- **Good:** flat cloth with a regular print (the cross-print gown came out seamless on the first
  try), torn cloth on a flat key colour (clean magenta holes and strips), a puckered sewn-shut eye,
  a pleated mask without a face when told "no mouth, no smile, no face", floor tiles on an exact
  4x4 grid, and plain signs: short text in capitals is spelled right and legible at 256 px.
- **Lighting:** it added a glossy hotspot to "gloss paint" (fixed by asking for dead-flat matte).
  Removing gradients afterwards by dividing by a blur made halos next to strong edges (the wall
  stripe, tile grout), so that step is off by default: fix it in the prompt instead.
- **Borders and surfaces:** asked for a stain on magenta it painted a whole wall and kept magenta
  only as a thin frame, twice. "On a plain white background, like a print on paper" worked; alpha
  is then taken from darkness.
- **Placement and stains:** it ignored "stripe at 30% height" twice, and "nothing centred / even"
  for tiling beats "a stain ring off to one side". It often tiles 2x2 inside one image by itself.
- Keep alpha hard (keyed, then threshold) and fill the cut-out colour dark before shrinking, or the
  edges go pink.

What changed on the Orderly (same silhouette, posture, folded hands, cap, printed smile):

1. **Torn gown.** Hem strips are separate pieces of geometry, 0.05 to 0.34 m long, cut into frayed
   strips by the torn texture's alpha and carried partly by four new levelled bones (`skirt.F.L`,
   `skirt.F.R`, `skirt.B.L`, `skirt.B.R`) that swing late after the thighs in `walk`, settle in
   `duck` and breathe in `idle`. The right sleeve is torn off short with a frayed edge and one rag on
   `sleeve_rag.R`. A rip runs up the right side from the hem to under the ribs, showing a new hip
   crest and the ribs. Three hole patches use the torn texture's holes. The back ties are frayed into
   threads, one torn short.
2. **Separates from the walls.** The Gemini cloth is grimed, going dried yellow-grey toward the hem
   and brown at the hem and along every tear. The first try (khaki all over) matched the skin and
   made one beige blob: keep the gown cooler than the skin, dirty it from the bottom up.
3. **Sewn lids.** The Gemini decal on 16-sided sockets that sink and fold toward one seam. Its skin
   is matched to the head's skin and faded over a wide band, and the old raised rim is gone: an edge
   of different colour or a ridge turns any socket back into a disc. A bold, tapered dark seam keeps
   it readable at 10 m (a slit, never a dark disc).
4. **Narrower grin.** Printed line 10.5 mm -> 5.8 mm, cheek ink 6.5 -> 4.0 mm half-width; the
   Gemini mask's pleat shadows are softened so the printed line is the only hard dark line.

Rules learned:

16. **Cloth bones hang plumb.** Give cloth bones a `("level",)` op so they keep hanging whatever the
    body does, then add the swing on top; they never need rework when a body pose changes.
17. **Alpha-cut cloth needs the renderer's help.** The material exports as glTF MASK, double-sided;
    any code that replaces materials must carry `alphaTest` over. Cut-away pixels are painted a deep
    shadow colour so the cloth still reads as torn if it does not.
18. **Judge through the tape.** `tape_look.mjs` brings every render down to 480 px, desaturates it
    toward green-grey and adds blur and grain; judge the `tape_*.png` files, not the clean renders.

## The Convict (crewmate figure): two more tutorials (2026-11-16)

Captions read in full and about twenty frames sampled from each (contact sheets), then the downloads
were deleted.

### 3. "Blender Low Poly Character: PS1 Style Modeling for Beginners", Grant Abbitt (Gabbitt)

https://www.youtube.com/watch?v=uIHuqFLa_X0 (about 19 minutes, Blender 4.5)

A whole PS1-style man boxed out of cubes against a front and side reference.

- **Half a cube and a mirror.** Every part starts as a cube cut down the middle, one half deleted and a
  mirror modifier with clipping on, so the centre line can never open up. *Script: yes.* The Convict
  is generated for one side and mirrored by negating x, so the mirror test is exact (0.000 mm).
- **Shape from front view, then side view, then add a loop only where a curve is needed.** He keeps
  cutting a loop and sliding it (GG) to round a corner rather than adding subdivision. *Script: yes.*
  Each ring is a small table row; a 2.2 to 2.4 superellipse rounds the corners of every ring.
- **Faces carry the features.** The nose is one face extruded and scaled, the ear one inset and
  extrusion. *Script: yes.* The nose is the middle front face between the "under the nose" and "eyes"
  rings extruded into a wedge; eyes and mouth are paint.
- **Mitten hand from a flattened cube; the thumb extruded from its side.** *Script: yes, used as is.*
- **Overlapping separate pieces** (head, chest, trunk, upper and lower arms, legs, feet as separate
  blocks pushed into each other) is how many PS1 models were built and why his rig "looks joined".
  *Not used here.* Mixamo's auto-rigger wants one outer surface, so this figure grows every limb out of
  the torso instead (the next tutorial says the same from the other side).

### 4. "Avoid Upload Errors! Importing from Blender to Mixamo", Neb Motion

https://www.youtube.com/watch?v=SPteht55oUc (about 12 minutes)

Why Mixamo refuses or mis-rigs Blender characters, and the export that worked for him.

- **Only Base Color.** Upload failures came from materials with textures wired into other Principled
  inputs. *Applied:* each material is one image into Base Color, nothing else.
- **Opaque materials.** He sets every blend mode to opaque because alpha confuses Mixamo. *Applied:*
  no alpha anywhere.
- **No hidden body under the clothes.** Delete the body inside a suit, or it pokes through when the rig
  bends. *Applied:* there is no inner body; the jumpsuit is the surface.
- **Clear an old rig with "keep transforms"** so the scale does not jump. *Applied as:* no rig, no
  modifiers, no object transform at all; the axis change is baked into the vertices.
- **Export: Path Mode Copy + embed textures, selected objects only.** *Applied.*
- **Bipeds of human proportion only.** Stylised extremes mis-rig. *Applied:* ordinary 1.75 m adult.

### What changed in the approach

- One manifold surface built by "box modelling by numbers": a torso of 14-vertex rings (the outline of
  a 5 x 2 grid); each arm grows from a 2 x 2 patch of the side wall, each leg from a 2 x 2 patch of
  the bottom, the neck from the middle 3 x 2 of the top. The bottom's middle column stays as a 5 cm
  crotch strip, so the legs never share faces. Result: 0 non-manifold edges, 1,404 triangles.
- Three loops at each elbow and knee, three at each wrist and ankle, three at the shoulder root,
  collar and neck. Rolled cuffs and the collar are a ring that flares out and a ring that steps back
  in (sharp edges above 58 degrees), not separate pieces.
- Textures are painted by rasterising each triangle in UV space and colouring each texel from its 3D
  position and normal (folds, zip, waist gather, grime from the floor, painted crevice shadow), then
  bled into the margins. The suit is light grey so a multiplied tint reads as the colour; the number
  patch is its own material with 0..1 UVs.
- FBX: written in centimetres (UnitScaleFactor 1, vertices 176 units tall, Y up, no object
  transform), checked by reading the file itself, not only by re-importing into Blender (which
  hides unit mistakes by converting on the way in).
- A throwaway rig with automatic weights proves the loops (elbow 90, knee 90, arm overhead) and poses
  the figure arms-down for the line-up and player-view renders. Heat weighting succeeding on every
  bone is a fair proxy for Mixamo's auto-rigger seeing one clean surface.

### What the harsh look at the player view caught

- Long, thin, pale mitten hands read as sticks hanging past the hips: hands shortened 4 cm and made
  thicker.
- Stubble, staple-shaped brows and a dark band under the nose read as a mask, a beard or a moustache:
  brows made straight and softer, stubble a flat light shadow, the under-nose shadow lightened.
- Boot laces as light bars made a busy face-like blotch on each foot: laces darkened, toe scuff halved.

Rule learned:

19. **Read the FBX file, not Blender's re-import.** Blender converts units and axes on import, so a
    1.75 cm or 175 m person can come back as 1.75 m. Check UnitScaleFactor, the raw vertex extent and
    every Lcl transform in the file.

### What the judges caught on the Convict, and what changed

Round one of blind judging (two judges shown only the renders, plus the coordinator):

- **The painted face was the worst thing.** It was "smeared", "eyes are mush", "a printed mask", "a
  spike of a nose". At 128 px for face, hands and boots, a face cannot be painted well. The owner then
  settled it the game's way: every convict wears an issue **screen mask**, a boxy monitor strapped over
  the face. The screen (`face_screen`, flat, 0..1 UVs) shows the face the player drew before the run.
  The mask is grown out of the head surface (the front of the face is extruded into a flat box, inset
  for a chunky bezel, and recessed for the screen), with two straps round the back, one over the top and
  a ribbed cable down to the collar. It still makes one manifold mesh.
- **Pale paddle hands read as toys.** They are now dark grey work gloves with a knitted cuff, a
  separate thumb, a slightly curled finger block and painted creases. They are shorter and thicker,
  and still need no finger bones.
- **Four identical figures read as a threat, not a crew.** Variation now comes from parts the game
  swaps without re-rigging: four skin tones on the same UVs, three headwear files on the head joint
  (knit cap, short hair, none), each player's drawn face, and the suit colour. Posing the line-up
  differently (weight on one leg, a slump, arms not matching) mattered as much as the parts.
- **"A smooth tube with seams drawn on."** Cloth needs geometry, not only paint: a belt band with
  cloth bloused over it, raised chest and thigh pockets, trouser hems over the boot tops, bunching rings
  at elbows and knees, and a small mirror-symmetric unevenness in the sleeve and trouser rings. The
  painted folds and wear are stronger, with neutral grey dirt so every tint stays clean.
- **Knees folded into sharp tents and a raised arm stretched into a column.** Elbows and knees now
  have five loops. The knee has a kneecap ring and a ring behind it that hold their volume at 90
  degrees. There is a deltoid cap ring and an extra torso row at the armpit. The raised arm still
  stretches some under automatic weights; Mixamo's own weights will decide the rest.

Rules learned:

20. **A face the game draws beats a face the model paints.** If players supply identity, give it a
    flat 0..1 screen and model the frame around it.
21. **Extruding a region leaves its inner vertices behind.** Delete loose vertices before export,
    and compare vertex counts between the FBX, the OBJ and the welded glb.

### Round two on the Convict: what the judges caught, and why

Two fresh judges agreed that the glowing drawn face is right: it is the first thing the eye goes to,
it carries identity, and the crew read as allies ("goofy-creepy"). What they caught:

- **The mask looked like a slab on a peg.** The cause was in the topology, not the numbers. The box was
  grown from only the three front columns of a 10-sided head ring, about 13 cm across, out to a 21 cm
  front. Its walls flared outward into fins, the profile was a thin plate on a narrow neck, and the
  cable hung like a stalk. Now the head rings have 12 sides, with columns at ±18° and ±162° just in
  front of the ears. The front four columns are extruded three times: out by an 8 mm gasket, out to a
  rim whose sides reach back to just in front of the ears, then forward to a flat front 12.6 cm ahead
  (tapered 6%, so it is deeper at the back like a CRT). Nothing is wider than the head plus 1.5 cm.
  A rigid harness (a band round the back of the skull and one ear to ear over the crown) meets
  bolt bosses on the housing's sides. The cable runs short and flat from the underside to the collar.
  The head is 7.5% bigger.
- **A screen tilted in a pose looks crooked.** Line-up poses now only turn the head about the
  vertical, and a slump is levelled again at the neck.
- **Mittens with no wrist.** The gloves have a flared gauntlet wider than the sleeve end, then
  12-sided hand rings whose 60° and 120° vertices are pulled in. That cuts two grooves top and
  bottom, so the block reads as three fingers, with the thumb separate. The hands are bigger.
- **Painted zigzag wrinkles and sticker patches.** Folds are now a few broad, soft gradients. The
  number patches are raised 3 mm, with a dark edge and a stitched border painted on the suit.
- **Raised arm and raised leg.** A bigger deltoid cap, a ring high on the upper arm, a ring at the top
  of each thigh, a wider crotch strip lowered into a gusset; the bend test now includes a step-up.

Rule learned:

22. **Look at a projection's side view before trusting its numbers.** A box that is 21 cm wide is
    still a slab if it grows from a 13 cm patch: the base must be as wide as the box, so grow it from
    columns that reach the sides of the head.

## The crewmate moves: Mixamo round trip, clip trimming, Godot import (2026-11-16)

`assets_src/blender/convict/build_crewmate.py` turns the Mixamo downloads into
`godot/assets/entities/crewmate.glb` (one skinned mesh of 2,216 triangles, 34 bones, 13 clips, the
two headwear pieces on the Head bone, about 1.3 MB). `godot/client/crew_view.gd` draws one crewmate;
`godot/client/crew_demo.tscn` stands four in a real floor and saves pictures to
`assets_src/renders/crewmate/`:

```
tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/convict/build_crewmate.py
node godot/tools/godot.mjs import        # once, so Godot imports the glb and learns the CrewView class
cd godot && ../tools/godot/Godot_v4.7.2-stable_win64_console.exe --path . --resolution 960x540 --position 40,40 res://client/crew_demo.tscn
```

What the round trip did and did not do:

- **Every file came back With Skin.** All 13 FBX files carry the mesh and both embedded textures, not
  only the first. Harmless: the script takes the skeleton and weights from the first (Standing Idle)
  and checks every other clip's skeleton against it (same joints to 0.05 cm).
- **Mixamo kept the mesh exactly.** 2,216 triangles, the four material names, one UV layer, and every
  triangle corner of `convict_tpose.glb` has a Mixamo vertex at the same place with the same UV. So
  the script uses the game's own mesh (build_convict.py's glb: exact materials, normals, flat 0..1
  face screen) and copies Mixamo's weights onto it by position (worst match 0.000 mm). Mixamo's
  vertices are welded (1,110 against the glb's 2,144 split at UV seams), which is why the copy goes by
  position, not index.
- **"In Place" did not stick.** Walking, Jog Forward, Sneaking Forward and Crawling came with root
  motion (1.8 m, 2.1 m, 3.7 m and 0.9 m per cycle, straight down -Y). That turned out useful: the
  stride speed is measured from it exactly, then removed. Walk 1.78 m/s, run 2.58, sneak 2.22 (a
  brisk sneak), crawl 0.51. The game's speeds (walk 3.0, sprint 5.0, creep 1.2) mean playback at 1.7x,
  1.9x and 0.54x; crew_view does that division itself.
- **The FBX armature carries a 90 degree turn and a 0.01 scale.** Applying both to the armature turns
  every bone's frame with it, so rotation keys carry over unchanged and location keys just scale by
  0.01. The script proves it: unprocessed idle frames put the toes, hand and head within 0.000 mm of
  where the FBX had them.
- **Mixamo's head weights fade down the neck.** Between 1.48 and 1.55 m the Head share ran 0.3 to
  0.9, which bends the mask housing when the head turns. Every vertex above 1.535 m now follows the
  Head only, easing in from 1.495 m, so the screen is rigid and the neck skin takes the twist.

Trimming and fixing clips (all done on numbers, not by hand):

- Mixamo clips mostly loop already: first and last frame identical. Only the crawl's ends differed
  (up to 15 degrees in a forearm); the best cycle was the whole clip, and the leftover is spread over
  it. Every loop then has its last frame set equal to the first. Godot plays it with LOOP_LINEAR.
- Drift: the per-cycle root travel is removed linearly, then the clip is centred (moving clips on the
  mean hips position, standing clips on the middle of the feet in the first frame), so cross-fades
  between clips do not slide the figure.
- Floor: the deformed mesh is sampled every frame; wherever it goes more than 6 mm under y = 0 the
  hips are lifted (smoothed). The crawl was 13 to 16 cm under the floor all through (a smaller
  character's clip), the spin's floor work 11 cm, the fall 5 cm.
- `taken` (Standing Death Backward) travels a metre backwards. Taken out with a smoothstep while the
  body is in the air (frames 36 to 49), so the figure lands where it stood and the crawl starts there.
- `pray` kneels and stays down. The clip is played to frame 110 and then frames 79..0 backwards (the
  closest join, 2.8 degrees, eased over 8 frames), so it ends standing and the emote can hand back.
- Size: 13 clips sampled at 30 fps with the exporter's "optimize animation size" (constant channels
  dropped) are 1.3 MB. Seven leaf bones with no weights (HeadTop_End, toe ends, finger tips) are
  marked non-deform and left out.

Godot import:

- The glb imports as-is with the default scene importer. As with the Orderly, every clip comes in
  non-looping; crew_view sets the loop mode per clip. Godot writes the embedded textures out as
  `crewmate_convict_suit.png` etc.; the four skin textures are also copied as `crewmate_skin_1..4.png`
  so the view can swap them.
- The headwear, exported as objects parented to the Head bone, arrive as BoneAttachment3D nodes:
  the view only toggles their visibility. If the headwear ever has to be attached by hand instead:
  bone `Head`, origin (0, 0.0297, -0.0121) m from the Head joint in the bone's own axes.
- Every material is replaced by the client's one prop shader (Level.prop_material), with the glb's
  texture; the face screen gets `emit` 0.55 so a drawing reads in a dim corridor.
- Changing bone poses from `_process` after the AnimationPlayer has posed the skeleton did not show in
  the picture (the numbers were right, the skin was not). The raised instrument arm is a
  SkeletonModifier3D instead, whose `influence` is the blend; that is the Godot 4 way and it works.
  It aims in the figure's own space, so it is only drawn over upright clips (idle, walk, run, wave,
  look_behind, button): over the sneak's forward lean the same aim twisted the arm.

Rules learned:

23. **Read the downloads before trusting the download settings.** "In Place" and "Without Skin"
    were both asked for and neither happened; the numbers said so in the first minute.
24. **Copy weights by position, not by index.** A round trip welds UV seams; the game's own mesh
    stays the source of materials and UVs.
25. **Sample the deformed mesh against the floor every frame.** Clips made for another body sink
    (the crawl by 16 cm); a per-frame lift fixes it without touching the clips that were right.

## The Minder (Playroom resident): two more tutorials (2026-11-17)

The Minder is gaunt, too long, eyeless, and moves both upright and on all fours, so the study was a
low-detail horror creature with long multi-jointed limbs and a rig for a body that is not a person.
About twenty frames were sampled from each video (plus denser sheets of the modelling part), then the
downloads were deleted. YouTube refused the first video's captions every time (HTTP 429), so it was
studied from frames alone; the second was read from its captions in full.

### 5. "How to make a lowpoly PS1 Monster for a INDIE HORROR GAME", Stark Crafts

https://www.youtube.com/watch?v=BnBkSO6Jmuc (about 8 minutes)

A long-limbed monster made from an ordinary low-poly person.

- **Start from bones, not from monsters.** The video opens in a natural history museum on animal
  skeletons (an elk, a dinosaur, a horned skull) before any modelling. *Used:* the Minder's head is a
  long narrow skull with a crest and a keel underneath, built from a table of cross-sections along the
  snout, not from a human head. The skull sells "animal" before anything else does.
- **Lengthen by adding a segment, then put a joint ring at the new bend.** The arms and legs are
  pulled out of a human base mesh and given an extra bend; every bend keeps one tight loop so the
  low-poly limb folds cleanly. *Script: yes.* The Minder's legs have an extra segment (a long raised
  foot from the heel to the ball), and the arms are human-jointed but longer, reaching past the knees.
- **Thin straight tubes between knobbed joints read as wrong.** The frames show long limbs that are
  almost straight prisms with a sharp knee or elbow. *Script: yes.* Limbs taper between joints and
  swell at the knee, elbow, wrist and every knuckle (rule 6 again).
- **Hanging cloth is a plane, carried by the body.** Its rags are a flat textured sheet hung off the
  hips. *Script: yes, with bones.* The tabard's strips are single sheets that hang from the panels.
- **Pose with IK handles on the hands and feet.** The rig places a circle control at each hand and
  foot and drags the limbs onto the floor. *Script: yes, as maths.* See below.

### 6. "The Easiest Way To Rig Creatures In Blender (For Beginners)", richstubbsanimation

https://www.youtube.com/watch?v=rOcNY00Mv1I (about 8.5 minutes)

Rigging bodies that are not human by building the rig from Rigify's separate parts.

- **Look at the body and list its parts before choosing a rig.** "Analyse your model and identify all
  the key body parts." A human preset does not fit a creature. *Used:* the Minder's 43 bones are a
  list made for it: a spine of four, a neck of two, a head and a jaw, two arms, four-part legs, and
  five cloth bones.
- **The "paw" limb is a leg with one more segment.** For creature legs he swaps the human leg for the
  paw module: thigh, shin, a long foot and the toes. *Used:* `thigh`, `shin`, `foot`, `toe`, with the
  foot standing steep so the heel stays off the floor; a crouch then bends the leg the wrong way.
- **Two-knuckle fingers are a two-bone chain.** A finger with two knuckles gets a chain of two, the
  third joint deleted. *Used:* each long finger is drawn with three knobs but carried by two bones, and
  the little finger rides on the ring finger's bones.
- **Extra small bones for things that should jiggle.** He parents a few loose bones to the neck to
  shake soft parts on their own. *Used:* the tabard strips and the lanyard each hang from one bone
  that is levelled to hang plumb whatever the body does, then swung late (rule 16).
- **Automatic weights, then fix them.** *Not used.* The script writes every weight itself, ring by
  ring, so nothing depends on Blender's heat solver.

### How the Minder is built

`assets_src/blender/minder/build_minder.py` makes everything from an empty scene: 6,291 triangles,
43 bones, a 512 px body atlas (colour, normal and roughness) painted in numpy and a 256 px mask with its own glow
map, ten actions.
`render_minder.py` re-imports the glb and renders the turnaround, the poses and the dark picture.

- **The skull** is a loft of eleven cross-sections from the back of the head to the end of the snout:
  flat on top with a crest, narrowing to a keel underneath, with shallow sealed hollows where eyes
  would be. They are shaped, not painted: a dark patch there reads as sunglasses (the Orderly's lesson).
- **The jaw** is its own loft, hinged under the back of the skull and built already hanging open
  (38 degrees since round one). Its teeth are three-sided hooks, some missing, all on the front half, so the
  mouth shows under the mask's lower edge and never as a grin across the face.
- **The mask** is two sheets: a printed front with its own material (base colour plus an emission
  map, so the bare card glows and the ink does not) and a plain card back 2 mm behind it on the body
  material. The front is back-face culled. From behind there is card and skull and a thin elastic,
  and nothing else. `godot/tools/minder_check.gd` proves every mask vertex is in front of the skull and
  every mask face looks forward.
- **Posing is plain maths, not constraints.** Each pose is a dict of bone ops, as for the Orderly,
  plus a two-bone solver: the arms and legs get a target (a wrist on the floor, a ball of the foot on
  the floor, a wrist on the mask) and a pole (elbows back and out, knees forward and out), and the
  solver writes the two rotations directly, keeping each limb's rest bend plane so the twist never
  flips. Hands and feet are then aimed in world space (palm flat, fingers fanned; the long foot steep).
  Nothing has to be baked and the keys are exact.
- **Gaits** are phase tables: each limb's touch-down phase, a duty factor and a stride. The upright
  walk is a slow two-beat stride (stepped at 8 poses a second, like the Orderly); the prowl is a
  lateral walk, left hind, left fore, right hind, right fore (12 a second); the run is a bound, the
  hind feet landing together and the fore feet reaching far out, sampled every frame.
- **One-shots are as long as the rules hold the pose** (straighten 3 s, look 2 s, slump 1 s, catch
  3 s from `sim/seek.gd`) and end on the held pose; loops end on their first pose. Loops are exported
  as `walk-loop` and so on: Godot's scene importer loops a clip named that way and drops the suffix, so
  the game sees the exact pose names with the loops already looping (setting the loop mode in the
  `.import` file instead made Godot write a 680 KB import file).

Rules learned:

26. **Solve contacts, never guess them.** A hand on the floor or on the face is a target for a
    two-bone solve with a pole, written straight into the keys. Report how far each target was
    missed: a reach error is a pose that asks the body to be longer than it is.
27. **Cloth that hangs plumb must have somewhere to hang.** Plumb strips are right on the chest of a
    body on all fours (they dangle under it) and wrong on its back (they would hang through it), so
    back strips follow the body and are pressed down onto it instead.
28. **A glow belongs to the bare surface, not the print.** Give the mask an emission map with the ink
    cut out, keep the emission low (0.35) so the card still reads as card in light, and in the dark
    the face is drawn by what does not glow.

### Round one of blind judging on the Minder, and what changed

Three judges saw only the renders: 6, 4 and 4 out of 10 lit, about 7 in the dark. Kept, because all
three named them: the glowing face floating in the dark at the wrong height, the flat mask on the end
of a long snout with the real jaw hanging open under it, the drop to all fours, the hands-over-the-face
crouch, the ID badge. What they caught, and the fix:

- **Glossy plastic, a mannequin.** The material is matte now: a roughness map (skin 0.86, the wet
  mouth 0.2, teeth 0.35), low specular, and a normal map of skin grain and wrinkles. The skin is
  mottled (low-frequency blotches of bruise and of pale, fine grain), pale grey-yellow only on small
  bone points, bruised purple-brown in the rib gaps, behind the knees and on the hands and feet.
- **Tube limbs with seam rings and ball joints.** Each segment now tapers from its upper end to about
  0.6 of that at its lower end, and the bones show at the ends on one side only (the point of the
  elbow, the knob of the wrist, the kneecap, the ankle bones), never as a ring all round. Every vertex
  of a limb is pushed in or out a little, so the outline is not a straight cylinder.
- **A bean-shaped pelvis.** The hip crests stand out at the sides and run forward to two points, the
  pubic bone is a ridge low at the front, the lower belly is sunk in and the sacrum is flat.
- **Symmetrical.** The right shoulder and arm hang 6.5 cm lower and the left arm is 10% longer. This
  is done once, after the mesh and bones are built, by moving each vertex by its own arm weights, so
  every pose and the two-bone solver inherit it.
- **Wire hands, toy feet.** Fingers are a third thicker with small dark claws; the feet are longer
  and the toes thicker, each with a thick claw.
- **Party bunting.** The vinyl is faded to maroon, mustard-brown and slate, dirty toward the hem; a
  third of the strips are gone, the rest differ in width and length by up to 40% and end in three
  ragged points; the panels sit darker than the strips. The badge is grimy and hangs crooked.
- **A friendly cartoon from the front, and a well-known mask.** A pale disc with two dots and a neat
  curve is too close to a mask a well-known video maker wears. Ours now has two eyes that do not match
  (one higher and smaller) and a wobbly smile far too wide, nearly edge to edge. The mask is 1.3 times
  bigger, a little taller than wide, shaped like a paper plate (a gently curved middle, a rim that
  curls back and is fluted), crumpled, stained, torn in two places, and bent forward at one corner.
- **A hairdryer head.** The cranium is a quarter smaller, with a heavy brow, a cheek ridge along each
  side and sunken temples. The jaw hangs open 38 degrees at rest, the teeth are three to four times
  longer, crooked and off-white going yellow, still only on the front half, and the corners of the
  mouth are dark wet skin stretched from the snout to the jaw. Standing, the neck cranes forward and
  the head hangs over to one side.

Rules learned:

29. **Matte first, then colour.** A plastic sheen turns any creature into a figurine; skin wants a
    roughness map and a grain in the normals before anything is painted.
30. **Colour by small patches, never by rings.** A region given to a whole ring of a limb reads as a
    sock, a cuff or a joint of a doll. Pale or bruised colour goes on a few faces facing one way.
31. **Check a simple face against well-known ones.** Two dots and a curve on a pale disc is someone
    else's mask. Make the eyes disagree and the smile wrong.

### Round two on the Minder, and the final pass

Three fresh judges: 6, 5 and 5 lit (up from 6, 4, 4), 7 to 8 in the dark, side-on or crawling. Kept:
the lone glowing face in the dark, the mask as a lie over a fanged mouth, the crawl, the crouch holding
the mask on, the badge. What they caught, and the fix:

- **The mask still read as an emoji, a frog sticker, a lollipop.** It is dirty bone now, and green only
  comes from the glow (emission 0.26, which reads in the dark and not in light). The eyes are holes cut
  right through the card (alpha, on the printed front and on the plain back alike), uneven and torn, one
  lower; behind them is a small dark plate of skin, so the holes show head, never the room. The mouth is
  a thin flat printed line 85% of the width, ends not turned up, cracked through once. And the mask is
  now a little too small for the skull, so from the front the cranium shows round it and the open jaw
  hangs below: it can no longer read as a ball on a stick.
- **A blockout.** The pelvis is narrow and tapered with two crest bumps, and the thighs begin inside it
  and widen downward, so there is no ledge. The shoulders slope about 22 degrees from the neck. Limb
  outlines are rough by half as much, and the pale and tan patches at the knees, ankles, feet and elbows
  are gone. The skin noise is three times finer along each limb than round it, because a limb's texture
  is stretched a metre along v: the old noise ran in long streaks that read as wood grain. Darker, wetter
  patches (lower roughness) sit in the rib gaps and the crooks of the joints.
- **A toy crocodile.** The lower jaw is a U-shaped bar of real thickness, from hinge round the chin to
  hinge. It carries 26 thin needle teeth (18 below, 8 above), lengths 0.4 to 1.6 times a base, leaning
  up to 15 degrees either way, bone-grey, front half only. A near-black floor sags between the two sides
  of the jaw and a near-black wall closes the throat, so the open mouth has depth.
- **The vest is still the brightest thing.** Faded a further half toward grey and darkened with grime;
  the music box's star is a faded, dirty pink-beige.

Rules learned:

32. **A mask must be smaller than the head it is on.** If the face covers the whole silhouette from
    the front, the figure is a face on a stick; let the skull and jaw show round it.
33. **Holes beat paint for eyes.** Painted dots read as a sticker at any size; a hole with darkness
    behind it reads as a mask with something wearing it.
34. **Noise must be square on the body, not in the texture.** Scale it by how far the UVs stretch.

## The Temp (Annex resident): two more tutorials (2026-11-17)

The Temp is an ordinary office worker (short-sleeved shirt, tie, lanyard, trousers, office shoes) with
an A4 sheet stapled over its face, built for Mixamo from the start. The owner found the Orderly's
fingers mangled by Mixamo's rig where they touched, so the study was hands that rig cleanly, and
clothing a low-poly human in a shirt and tie. Captions read in full; about twenty frames sampled
evenly from each video (contact sheets, plus a few frames pulled at full size), then the downloads
were deleted.

### 7. "How to make Low Poly Hands for games (Blender Tutorial)", Thomas Potter Tutorials

https://www.youtube.com/watch?v=7MNAS-LxL7Y (about 20 minutes)

Three kinds of low-poly hand from one block: a mitten, three fingers joined plus one, and five
fingers.

- **Palm and fingers are about the same length.** "If your hand is really weird, it may just be that
  you've made the hand too long and the fingers also too long." *Script: yes.* The Temp's palm
  (wrist to knuckles) and middle finger are each about 9 cm; only the fingers are a little long, on
  purpose.
- **Turn the wrist ring so a vertex is on top, not a flat face.** Then the back of the hand rises to
  a ridge and the detail sits at the sides where it shows. *Script: yes.* The forearm and wrist
  rings are 8-sided with a vertex on top and on the bottom.
- **Two segments per finger, not three, in low poly.** Three "doesn't really work that well in low
  poly". *Script: yes.* Each finger is knuckle, one middle joint and a tip: rings at the knuckle,
  just before and just after the middle joint, and a short blunt cap. (His pointed tips read as spikes
  on the Temp's first try.)
- **Diamond fingers.** His better five-finger hand turns each finger's square cross-section 45
  degrees, so a finger has a ridge on top and underneath and reads round with four vertices; square
  fingers "look a bit unprofessional". *Script: yes.* Every finger ring is four vertices on a
  diamond, a little taller than wide.
- **An edge loop at every joint, triangles only where nothing bends.** He moves the triangles needed
  to split three finger roots into four out onto the palm, away from the knuckles. *Script: yes.*
  The knuckle row of the palm has as many vertices as the four finger roots need, and the change
  from the wrist ring is made in the middle of the palm.
- **Straight for rigging; spread when they must stay apart.** "If you're going to be rigging, feel
  free to make your hand fully straight." His curled hand is a style choice. *Applied:* for Mixamo
  the fingers are straight in the plane of the palm, fanned about 7 degrees apart, with a clear gap
  at the tips, and the thumb comes off the side of the palm, forward and a little down (rule 35).
- **The thumb is extruded from the side face of the palm** and rotated to hang forward, not out in
  line with the fingers. *Script: yes.*
- **Thin fingers.** He thins every finger after blocking it out. *Script: yes.* About 1.7 cm wide at
  the knuckle, tapering to about 1.1 cm before the tip.
- **Sculpt grab and loop tools to tidy.** *Script: no, and not needed.* A table of numbers gives the
  same even spacing.

### 8. "Blender Clothing Modeling Tutorial | 05 Shirt" (with "| 06 Tie"), JAEY 3D

https://www.youtube.com/watch?v=MRyksFkJ3ag (about 17 minutes); the tie is its companion,
https://www.youtube.com/watch?v=Lci-9lw2Qc4 (about 6.5 minutes)

A shirt and a tie made over a stylised base body in T-pose, by box modelling with a mirror.

- **Block the shirt from a cube with a mirror, then cut the neckline as a V.** The front of the neck
  is cut down into a V with the knife; the back stays high. *Script: yes.* The Temp's collar opens at
  the front (a 32 degree gap, its points dropped) and the knot of the tie fills the opening.
- **The collar is its own strip with thickness, folded down.** He separates a band from round the
  neck, lifts it, gives it thickness (extrude along normals) and moves its inner edge up to make the
  fold, then cuts the points with the knife and lets the two points overlap a little at the front.
  *Script: yes.* The collar is a separate closed band laid over the neck: a stand going up, a fold,
  and a fall coming down over the shirt with two points at the front.
- **Small raised strips sell the shirt:** a placket down the front (two bevels and a push out), a
  hem band, a shoulder seam line. *Script: partly.* The breast pocket is pushed out 3 mm; the placket,
  buttons, seams and the pocket's hem are paint (too small for geometry at this budget).
- **The sleeve end is a ring with thickness.** The last frames show a turned cuff: a ring that
  flares out and steps back in. *Script: yes,* as on the Convict (a flare ring and a step-in ring).
- **The tie starts as the patch of shirt it lies on.** He duplicates the faces under the tie,
  reshapes them with a lattice into a narrow trapezoid, gives them thickness, and swells the knot at
  the top. Then he finds it too big and shrinks it, and refits the collar over the knot. *Script:
  yes.* The tie is a thin closed blade that follows the shirt's front rows 4 mm out, with a fat knot
  under the collar points and a pointed tip above the belt.
- **Delete hidden faces under the collar.** *Script: yes, by not making them;* and for Mixamo the
  shirt is the body's surface, not a shell over a body (rule from tutorial 4).

### How the Temp is built

`assets_src/blender/temp/build_temp.py` makes everything from an empty scene: 3,812 triangles (the
body 2,428, one closed surface with no non-manifold edges; twelve thin closed shells over it), a 512 px
atlas and the separate sheet material, plus the stapler (168 triangles) and the pad of notes (108).
`render_temp.py` poses it on a throwaway rig and renders it in an Annex corridor.

- **The Convict's body scheme, new tables.** Torso rings of 14, arms from a 2 x 2 patch of the side
  wall, legs from the bottom, neck from the top. Short sleeves end in a hem that flares and steps in;
  the trousers end 13 cm up, a little short, over a strip of bare shin and dark socks; low office shoes
  with a toe pulled out in three steps. The breast pocket is a face pushed out 3 mm.
- **Hands for Mixamo** (tutorial 7). The palm is three 16-vertex rings; the knuckle end is a row of
  seven quads, and the 1st, 3rd, 5th and 7th are pulled out as fingers, so 4 mm webs stay between the
  roots. Each finger is a diamond section, rings at 9, 42, 52, 74, 84 and 95% of its length, fanned
  -7, 0, 7 and 14 degrees, so the gaps widen toward the tips. The thumb comes out of the palm's front
  face between the first two rings, pointing forward, out and 21 degrees down. Bending test on a
  throwaway rig: every finger curls into a fist with no collapse.
- **Clothes as shells laid on the body** (tutorial 8). The collar is a strip of 18 columns (a stand, a
  fold and a fall) given 2.5 mm of thickness, its fall projected onto the shirt, its two points dropped
  over the knot. The tie is a knot block and a three-column blade cast onto the shirt front by rays,
  4 mm off it, 1 cm askew at the tip. The lanyard is a ribbon snapped to the body and collar and
  smoothed, round the back of the neck, to a clip and a badge hung to the right (a grey square where the
  photo should be). Every shell is pushed clear of the body surface.
- **The sheet** (first version, replaced after round one, below) was a 10 x 16 grid, A4 by arc length: its middle follows a side profile from over the
  hairline, down the face to past the chin, and it is wrapped round a vertical axis gently (radius 11.5
  cm at the top to 19 cm at the bottom), with a nose under the paper. Round the two top staples it is
  pulled onto the head (into the hair at the temples); the bottom hangs free. Front on
  `temp_face_sheet` with 0..1 UVs, back and edges plain paper on `temp_body`, 1.2 mm thick.
- **Slightly wrong:** a head a little small (21 cm chin to crown) on a long neck, narrow sloping
  shoulders, a long forearm, long fingers, trousers too short. Nothing a Mixamo rig would mistake for
  a different body plan.

Rules learned:

35. **Spread fingers apart for Mixamo, with gaps from the root.** Fingers that touch get weighted
    together. Keep webs between the roots, fan the fingers, and leave the thumb clear of the palm.
36. **Weld a glb before binding it.** The glTF exporter splits vertices at every UV seam and hard
    edge; a re-imported figure falls apart into pieces (the Temp's 1,932 vertices came back as 3,014),
    and bone heat then leaves the forearms and legs with no weights. Remove doubles first.
37. **A sheet over a face must be worn, not held up.** My first sheet (a gentle bend standing off the
    face) read to the judges as a cereal box floating in front of it: an air gap from the side, cheeks
    and ears showing round its edges, its corners sticking out behind like blinkers.

### Round one of blind judging on the Temp, and what changed

Three judges saw only the pictures: 4, 3 and 4 out of 10 in the bright corridor, 6.5, 6 and 7 in the
dark. All three liked the idea (a childish drawn face over a hidden real head, the head hung to one
side, the dark silhouette). What they caught, and the owner's own note ("make the temp a little more
dishevelled ... a coffee stain or half a shirt tail untucked ... tie half untied"):

- **The sheet** is now draped over the head like cloth: springs hold the 12 x 18 grid at A4 (mean
  error 3.6%), with skip-one springs for a paper's stiffness. The head pulls the sheet in and never lets
  it through, and the page's nose row is held on the nose. The head has a nose and brow for it to
  tent over. It runs from over the crown, down the face, to tucked under the jaw, and reaches from cheek
  to cheek. Then it gets an old fold across the middle, crumples, free edges lifting up to 4.5 mm
  between the corners, and corners pressed flat where the staples go. A string runs round the back of
  the head, with masking tape where it meets the paper. Any face of the paper whose middle comes within
  3.5 mm of the low-poly head is pushed out. The sample photocopy is 4 times finer (480 x 680, linear
  filtering), so the copied lines are smooth close up.
- **Not a mannequin.** The neck has a 12-sided ring with the pit of the throat, an Adam's apple and
  the two tendons, and the collar throws a shadow on it. The forearm swells below the elbow and
  flattens to a wrist bone. The left-forearm "seam" was the watch's geometry with no paint; it is now
  a brown strap with a steel face. Fingers and palm are thicker. The one wrongness is the arms: the
  forearm is 7 cm too long, so the hands hang to mid-thigh. The neck went back to normal and the head
  up 5% so nothing else competes.
- **Smaller fixes:** clean sock tops and a dark shoe lining by tag (not by normal); no hair parting
  (it read as a crack); the shirt's back is free of the tuck folds that read as smudges. The stapler
  is warm grey on a black base with a chrome strip and nose. The pad is 9 cm, fatter, with bigger
  writing.
- **Neglect, all on the body mesh so Mixamo skins it with the hips:** the shirt tail is out on the
  left (its torso rows pushed out over the belt to a hem 7 cm below it, with a step in under the
  hem), the right half tucked. Coffee runs down beside the tie with drops below it, and a mug ring sits
  on the belly. Sweat rings under the arms and down the back, a grimy, creased collar with one point
  curled up, the top button undone (the collar open, a V of throat painted), the tie knot pulled
  7 cm down with its loop running up either side of the neck, the tie askew, grime at the hems, a
  scuffed toe. The skin is warmer, so the green office light no longer turns it grey.
- **The renders** use a stand-in pose with both arms hanging still, knees soft, standing on the floor
  (grounded from the posed mesh), the stapler carried in the right fist and the pad pinched
  in the left, a soft contact shadow under the feet.
- **The Mixamo FBX is written from the welded mesh** (2,332 vertices; the glb route gave 3,606
  split at every seam), with the same settings and pictures as `mixamo_export.py`.

Rules learned:

38. **Drape, don't place.** Anything worn over a body (paper, cloth, a bag) should be simulated onto
    it: lengths kept, pulled in, never through, then creased. A shape modelled in the air keeps its gap.
39. **Paint every bit of geometry.** A raised ring with skin colour on it reads as a seam; give it the
    thing it is (a watch strap) or remove it.
40. **Neglect is a list of small true things.** One coffee dribble, one ring, one untucked side, one
    curled collar point, one loose knot. Each is cheap and each says the same thing.

### Round two on the Temp, and what changed

The same three-judge setup: 4, 3 and 3 in the bright corridor, 7, 5 and 6 in the dark. Kept: the head
hung over, the cheerful drawing over a limp body, the stapler, the notes and the stains ("he was at
work when this happened"). What they caught, and the fix:

- **A stair-stepped hem and a belt that stopped dead.** The loose tail had been a block of whole faces.
  Now one function, `hem_z(x, y)`, gives the hem everywhere. On the tucked side it is the top of the
  belt; on the loose side it hangs 11 cm lower, with a couple of soft folds; between, it is pulled up
  diagonally across the belt. Each torso vertex below the belt's top stands out only if it is above the
  hem, eased over 1.6 cm, with more rings round the waist. The texture decides shirt, belt or trousers
  texel by texel from the same function, with a soft shadow under the hem. So the belt runs all the way
  round and disappears under the tail.
- **A normal man from afar.** The body now has a rounded upper back (the back of the chest rows is
  pushed out 1 to 1.5 cm), which shows in the side silhouette even in the T-pose. The stand-in pose is
  the rest:
  - pelvis forward, a hunch through the chest;
  - the right shoulder dropped and the left hitched up;
  - the head hung 28 degrees over;
  - the right arm straight and lower, the left bent;
  - knees soft, the left foot forward and turned out.
- **Edges of the mask.**
  - The face is 7% narrower and the ears small, flat and set back under hair grown long over them, so
    the sheet's edges meet hair, not skin.
  - The hair now reaches the jaw at the sides and the collar at the back, and fades out over 1.4 cm
    instead of stopping at a hard line.
  - The top edge no longer lifts, and the back of the paper is pale, which removes the dark shards on top.
  - The string is 2 mm, droops round the back, and ends in a knot with two loose ends.
  - The paper is a shade whiter.
- **Smaller.**
  - The skin varies at two scales. The elbows are ruddier and darker, the knuckles and finger joints
    darker, with a crease at the wrist, darker tops and paler undersides to the forearms, and a few hairs.
  - In the pose the fingers curl unevenly (never as one mitten) and the right fist closes round the
    stapler.
  - The shoes are slimmer, with the toe springing 1.1 cm off the floor.
  - The mug ring is a wide soft rim, broken on one side, with a faint wash inside: soaked in, not
    printed on.

Rules learned:

41. **Hems are functions, not faces.** Where cloth changes (tucked to loose, shirt to belt), decide it
    by a smooth function of position for both the geometry and the paint; whole faces make stairs.
42. **Commit the wrongness in the silhouette.** Far off and in the dark, only the outline is left: a
    curved spine, a dropped shoulder and a head held past comfortable read at 10 m; stains do not.
43. **What shows round a mask must belong to it.** Skin or an ear at the edge says "a man wearing a
    sheet"; hair grown over, and a string tied at the back, say the sheet is part of him.

## The Reactor's surfaces, growths and rotor (AR1, 2026-11-21)

The owner, 21 Nov: "Reactor specifically is pretty weak ... The growths in reactor look terrible ... Textures will
help, meshy AI will help and free resources for packs that are cc0 will help". Every outside asset on the floor:

| Game file | Source | Licence | Fetched |
| --- | --- | --- | --- |
| `godot/assets/reactor/wall_concrete.webp` | Concrete Slab Wall, Poly Haven, https://polyhaven.com/a/concrete_slab_wall | CC0 (stated on the asset's page) | 2026-11-21 |
| `godot/assets/reactor/wall_paint.webp` | Painted Concrete, Poly Haven, https://polyhaven.com/a/painted_concrete | CC0 (stated on the asset's page) | 2026-11-21 |
| `godot/assets/reactor/floor_concrete.webp` | Concrete Floor Worn 001, Poly Haven, https://polyhaven.com/a/concrete_floor_worn_001 | CC0 (stated on the asset's page) | 2026-11-21 |
| `godot/assets/reactor/ceiling_concrete.webp` | Concrete Wall 006, Poly Haven, https://polyhaven.com/a/concrete_wall_006 | CC0 (stated on the asset's page) | 2026-11-21 |
| `godot/assets/reactor/steel_plate.webp` | Metal Plate 02, Poly Haven, https://polyhaven.com/a/metal_plate_02 | CC0 (stated on the asset's page) | 2026-11-21 |
| `godot/assets/reactor/growth_c.glb` | Generated with Meshy on the owner's paid plan, 21 Nov 2026, from `assets_src/meshy/reactor/reactor_growth_c_concept.jpg` | the owner's (paid plan) | 2026-11-21 |
| `godot/assets/reactor/rotor_b.glb` | Generated with Meshy on the owner's paid plan, 21 Nov 2026, from `assets_src/meshy/reactor/reactor_rotor_b_concept.jpg` | the owner's (paid plan) | 2026-11-21 |

The pipes also reuse the Arboretum's `painted_iron.webp` (Green Metal Rust, Poly Haven, CC0).

How they were made small: the five photo maps were downloaded as 1k colour JPGs only (no accounts, plain HTTPS) into
`assets_src/inbox/reactor/` (not in git) and cut to 512 px WebP by `assets_src/reactor_textures.py`, which also
sets each map's mean brightness to the station's old painted greys and quietens the paint's chips. The two Meshy
pieces were decimated to about 7,500 and 9,500 triangles with 1024 px colour by
`assets_src/blender/reactor/build_reactor_meshy.py`. Three other Meshy pieces were made and not used: growth A
(faceted lumps and floating fragments), growth B (a fungus shelf, not this floor's growth) and the first rotor (a
closed drum that shows no blades).

Rules learned:

44. **Lay photo maps in world metres.** A map stretched per cell repeats at a different size on every wall; laid by
    world position at the photograph's own size, one wall reads like the next.
45. **Growth sits on something that goes somewhere.** A lump on a pipe stub reads as a prop; the same lump on a run
    that comes out of one wall and goes into another reads as something that grew there.
## Outside assets: the Hanging Ward's photographs (AW1, 2026-11-21)

Nine CC0 1.0 colour maps from Poly Haven, each licence confirmed on the asset's own page on 2026-11-21, downloaded
as image files only (1k jpg) and reduced by `assets_src/ward_textures.py` into `godot/assets/ward/surfaces/`
(list and sizes in its `SOURCES.md`):

| Name | Library | Page | Licence | Date |
| --- | --- | --- | --- | --- |
| Red Brick 03 | Poly Haven | https://polyhaven.com/a/red_brick_03 | CC0 | 2026-11-21 |
| White Plaster Rough 02 | Poly Haven | https://polyhaven.com/a/white_plaster_rough_02 | CC0 | 2026-11-21 |
| Weathered Planks | Poly Haven | https://polyhaven.com/a/weathered_planks | CC0 | 2026-11-21 |
| Wood Floor Worn | Poly Haven | https://polyhaven.com/a/wood_floor_worn | CC0 | 2026-11-21 |
| Roof Slates 02 | Poly Haven | https://polyhaven.com/a/roof_slates_02 | CC0 | 2026-11-21 |
| Rock Wall 10 | Poly Haven | https://polyhaven.com/a/rock_wall_10 | CC0 | 2026-11-21 |
| Rusty Metal 02 | Poly Haven | https://polyhaven.com/a/rusty_metal_02 | CC0 | 2026-11-21 |
| Wood Cabinet Worn Long | Poly Haven | https://polyhaven.com/a/wood_cabinet_worn_long | CC0 | 2026-11-21 |
| Decrepit Wallpaper | Poly Haven | https://polyhaven.com/a/decrepit_wallpaper | CC0 | 2026-11-21 |

Rule learned: lay a photograph in world metres at its own real size (Poly Haven lists it), never per box, so one
brick is one size on every wall.

## The Playroom's slides, towers, photographs and murals (PR1, 2026-11-21)

The owner, 21 Nov: "It's currently very rough and blocky. Textures will help, meshy AI will help and free resources
for packs that are cc0 will help", and "I really love the Meshy AI playroom stuff." Every outside asset on the floor
(also in `godot/assets/playroom/SOURCES.md`):

| Name | Library | Page | Licence | Date |
| --- | --- | --- | --- | --- |
| Office Ceiling 001 | ambientCG | https://ambientcg.com/a/OfficeCeiling001 | CC0 | 2026-11-21 |
| Painted Plaster Wall | Poly Haven | https://polyhaven.com/a/painted_plaster_wall | CC0 | 2026-11-21 |
| Dirty Concrete | Poly Haven | https://polyhaven.com/a/dirty_concrete | CC0 | 2026-11-21 |
| Tube slide (`slide.glb`) | Meshy, the owner's paid plan, from Fable's concept picture | | the owner's | 2026-11-21 |
| Soft-play tower (`frame.glb`) | Meshy, the owner's paid plan (second try, solid panels) | | the owner's | 2026-11-21 |

The first frame try (`playroom-frame`, netting as loose squares) was not used. The photographs were cut to 512 px by
`assets_src/playroom_textures.py`; the plaster and the dirt are grey detail maps the Playroom shader multiplies over
the walls, mats, walkways and ceiling in world metres, so the floor's faded primaries stay. The two Meshy pieces were
decimated to 9,000 and 14,000 triangles with 1024 px colour by `assets_src/blender/playroom/build_playroom_meshy.py`
and are drawn 2.8 m tall (near the 3.2 m ceiling) with their backs to plain walls in the toddler rooms, decks and
nooks: a tower first, then a slide by a way in, at most 12 a floor, placed from the seed, each over two cells along
the wall (a tower two deep), every one of them walkable, in its room and clear of hides, hides' fronts, squeakers and
doors. The wall dirt sits only at hand height and under the ceiling line, so the pale paint stays clean between.
The four murals (sun and rainbow, balloons, the sea, night houses), 3.4 by 1.7 m on every plain wall of 6 m or more
in the big play rooms, are painted by `assets_src/playroom_murals.py`: original shapes, faded and worn through.

Rule learned:

46. **A model the owner likes goes where it can be seen whole.** A slide or tower backed against a long plain wall
    reads at once; the same piece in the middle of a room hides the room and invites hiding where the rules have none.

## The Hanging Ward homes' furniture (WH3, 2026-11-27)

Eight Meshy pieces (the owner's paid plan, 21 Nov; the homes design's eight credits): a kitchen range, a kitchen table,
a dresser of plates, an iron bed, a claw-foot bath, a long-case clock, a pram, and a wash copper beside a mangle (cut
in two). `assets_src/blender/ward/build_ward_meshy.py` decimates them to 4,000-6,000 triangles with 1024 px colour into
`godot/assets/ward/homes/` (ledger in its `SOURCES.md`). `client/ward/homes_dress.gd` fits each to the rules box of the
piece it draws, its back to the nearest wall; every other piece (hearth, armchair, coat hooks, sink, drawers, shelf,
toilet, lockers, workbench...) is built from boxes in the Ward's own photographs. Pictures, a crockery shelf, rugs and
a pram are added where nothing walks, hides or reaches. No new outside photographs.

Rule learned:

47. **A hide's model turns to keep its opening open.** A bath's tap or a bed's hanging sheet on the open side blinds
    the camera inside; the piece is turned (within what its box allows) until the view out is clear.
