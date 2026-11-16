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
