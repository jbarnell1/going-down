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
