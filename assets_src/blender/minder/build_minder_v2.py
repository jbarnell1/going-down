"""The Minder, second figure (MN1): the heavy four-legged body from Meshy, rigged by Meshy, animated here.

Builds godot/assets/entities/minder_v2.glb from the committed source model
assets_src/meshy/minder/minder_meshy_rigged.glb (Meshy's own quadruped rig of the textured mesh, the look
approved by the owner: assets_src/meshy/minder/minder_concept.jpg). Every step is a script; nothing is
done by hand, and the same source gives the same file.

  blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/minder/build_minder_v2.py -- [--out PATH] [--blend PATH] [--drop cover,...]

What it does:
 1. Imports the rigged model, drops the stray helper sphere, stands it with its feet at y 0 and scales it
    by SCALE (the body is long and low: see the printed numbers), facing -Y (glTF +Z, the way the game's
    figures face).
 2. Splits the card mask out as its own material, "Minder_mask" (the view finds the mask by that name):
    the pale faces at the front of the snout and every darker face they enclose (the eye holes). Its
    glow map, "Minder_mask_glow", is the bare card, so the card glows and the eye holes and ink stay dark.
    Superseded for the drawn face by the face plate (add_plate): Meshy's small card stays under it on the
    body's material, and the plate (a 0.22 x 0.28 m worn card oval over the whole front of the head, a
    drawn smiley face, eye holes cut through) is the only surface with the mask material. The body keeps the colour map, "Minder_atlas", at ATLAS_PX.
 3. Enlarges the badge on the lanyard by BADGE_GROW so it reads at 480x270.
 4. Thins the mesh to about TRIS triangles for the web build; at most four bone weights per vertex.
 5. Authors the ten clips the view plays, under the old model's names and lengths, as an animal on all
    fours: stand, walk, prowl, run (a gallop), look, sweep, cover, catch, slump, straighten. The legs are
    placed by a two-bone solve (upper and lower limb to the wrist or the hock, the pole the rest pose's own
    knee or elbow direction, so no flips) with the hind metatarsal and the paws set by angle: the hind
    foot rolls off its toes, the long metatarsal stays nearly upright (the taut Achilles). Everything is a
    function of time; there is no randomness. The gaits are in place (no travel): the view moves the body
    and runs each gait's clock on the distance walked over STRIDE / length.
 6. Exports one skinned mesh, one skeleton, clips sampled at FPS; loops named "-loop" (Godot loops them
    and drops the suffix).
"""
import bpy, bmesh, sys, os, math, argparse
import numpy as np
from mathutils import Vector, Quaternion, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(ROOT, "assets_src", "meshy", "minder", "minder_meshy_rigged.glb")

FPS = 30
SCALE = 0.85            # Meshy's 1.60 m tall, 1.76 m long figure -> 1.36 m at the shoulders, 1.50 m long
TRIS = 12000
ATLAS_PX = 1024
BADGE_GROW = 1.3
MASK_GLOW = 0.26        # the glow's energy under the strip lights, as the first model's (the view reads it)
PALE = 0.5              # a texel this bright (mean of r, g, b) is card, badge or lanyard print
BODY_ROUGH = 0.8        # matte, not wet plastic
FACE_PX = 256
# The face plate (add_plate): a worn card plate over the whole front of the head, standing proud of it.
PLATE_W, PLATE_H = 0.22, 0.28
PLATE_PROUD = 0.035     # in front of Meshy's small card
PLATE_DOWN = 15.0       # at rest it faces forward and this many degrees down
PLATE_BEND = 0.20       # radius of its sideways curve (m)
PLATE = {}              # its middle and facing at rest, armature space (set by add_plate)

# Each clip: (name, length s, loops). The lengths are the first model's (godot/tools/minder_check.gd prints
# them); the rules time the one-shots (sim/seek.gd STRAIGHTEN_TIME, LOOK_TIME, SLUMP_TIME, CATCH_TIME).
CLIPS = [("stand", 4.0, True), ("walk", 1.5, True), ("straighten", 3.0, False), ("cover", 3.0, True),
         ("prowl", 2.0 / 3.0, True), ("sweep", 3.0, True), ("look", 2.0, False), ("slump", 1.0, False),
         ("run", 0.5, True), ("catch", 3.0, False)]
# The gaits: ground covered by one play of the clip (m), cycles in it, feet-down fraction, swing lift (m).
# The view's GAIT_SPEED for v2 is STRIDE / length.
GAITS = {
    "walk": dict(stride=1.10, cycles=1, duty=0.65, lift=(0.09, 0.08), low=0.05, bob=0.012,
                 phase={"LH": 0.0, "LF": 0.25, "RH": 0.5, "RF": 0.75}, roll=(25.0, 40.0), sniff=10.0, cr=6.0),
    "prowl": dict(stride=2.60, cycles=2, duty=0.55, lift=(0.10, 0.09), low=0.13, bob=0.015,
                  phase={"LH": 0.0, "LF": 0.25, "RH": 0.5, "RF": 0.75}, roll=(28.0, 45.0), sniff=16.0, cr=7.0),
    "run": dict(stride=2.40, cycles=1, duty=0.30, lift=(0.17, 0.15), low=0.10, bob=0.05,
                phase={"LH": 0.0, "RH": 0.08, "LF": 0.46, "RF": 0.56}, roll=(32.0, 55.0), sniff=0.0, cr=4.0),
}

LEGS = {
    "LF": dict(kind="front", upper="clavicle.L", lower="frontLwr.L", end="frontHorselink.L", tip="frontToe.L", scap="frontLeg.L_01"),
    "RF": dict(kind="front", upper="clavicle.R", lower="frontLwr.R", end="frontHorselink.R", tip="frontToe.R", scap="frontLeg.R_01"),
    "LH": dict(kind="hind", upper="rearUpr.L", lower="rearLwr.L", meta="rearHorselink.L", end="rearFoot.L", tip="rearToe.L"),
    "RH": dict(kind="hind", upper="rearUpr.R", lower="rearLwr.R", meta="rearHorselink.R", end="rearFoot.R", tip="rearToe.R"),
}


def log(*a):
    print("[build_v2]", *a, flush=True)


def q(axis, deg):
    ax = {"x": Vector((1, 0, 0)), "y": Vector((0, 1, 0)), "z": Vector((0, 0, 1))}[axis] if isinstance(axis, str) else Vector(axis)
    return Quaternion(ax, math.radians(deg))


def qe(x=0.0, y=0.0, z=0.0):
    """Yaw (z, + turns left), then pitch (x, + nose down), then roll (y), about the armature's axes."""
    return q("z", z) @ q("x", x) @ q("y", y)


def smooth(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


def ramp(t, a, b):
    return smooth((t - a) / (b - a)) if b > a else (1.0 if t >= b else 0.0)


def lerp(a, b, t):
    return a + (b - a) * t


# ============================ the source model ============================

def load_source():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=SRC)
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    ob = next(o for o in bpy.data.objects if o.type == "MESH" and o.parent == arm)
    for o in list(bpy.data.objects):
        if o not in (arm, ob):
            bpy.data.objects.remove(o, do_unlink=True)
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)
    # Feet on the floor, scaled, everything applied so the rest pose is clean at scale 1.
    arm.location = (0, 0, 0)
    arm.rotation_euler = (0, 0, 0)
    arm.scale = (SCALE, SCALE, SCALE)
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    zs = [(ob.matrix_world @ v.co).z for v in ob.data.vertices]
    low = min(zs)
    if abs(low) > 1e-4:
        arm.location.z -= low
        bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
    arm.name = "Minder"
    arm.data.name = "Minder"
    ob.name = "MinderBody"
    return arm, ob


def atlas_pixels(img):
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    return px.reshape(h, w, 4)


def split_mask(ob, px):
    """Material 1 on the card: pale faces near the front of the snout, and the darker ones they enclose."""
    me = ob.data
    h, w = px.shape[:2]
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    uvl = bm.loops.layers.uv.active

    def lum(f):
        u = sum(l[uvl].uv.x for l in f.loops) / len(f.loops)
        v = sum(l[uvl].uv.y for l in f.loops) / len(f.loops)
        x = min(w - 1, max(0, int(u * w)))
        y = min(h - 1, max(0, int(v * h)))
        return float(px[y, x, :3].mean())

    cents = {f.index: f.calc_center_median() for f in bm.faces}
    pale = {f.index for f in bm.faces if lum(f) > PALE}
    # The card is the pale cluster furthest forward (most -Y) and above the chest.
    front = sorted(pale, key=lambda i: cents[i].y)[:40]
    mc = sum((cents[i] for i in front), Vector()) / len(front)
    card = {i for i in pale if (cents[i] - mc).length < 0.11}
    cc = sum((cents[i] for i in card), Vector()) / len(card)
    rad = max((cents[i] - cc).length for i in card)
    near = {f.index for f in bm.faces if (cents[f.index] - cc).length < rad * 1.25}
    # Enclosed darker faces: not reachable from outside the card's radius through non-card faces
    # (vertex neighbours: the mesh is split along its UV seams).
    vf = {}
    for f in bm.faces:
        for v in f.verts:
            vf.setdefault(v.co.to_tuple(5), []).append(f.index)
    nb = {}
    for f in bm.faces:
        if f.index in near:
            s = set()
            for v in f.verts:
                s.update(vf[v.co.to_tuple(5)])
            nb[f.index] = s
    outside = set()
    stack = [i for i in near if i not in card and (cents[i] - cc).length > rad * 0.95]
    outside.update(stack)
    while stack:
        i = stack.pop()
        for j in nb.get(i, ()):
            if j in near and j not in card and j not in outside:
                outside.add(j)
                stack.append(j)
    holes = {i for i in near if i not in card and i not in outside}
    mask = card | holes
    for f in bm.faces:
        # Meshy's own small card stays on the body's material, under the face plate (add_plate).
        f.material_index = 0
    bm.to_mesh(me)
    bm.free()
    log(f"mask: {len(card)} card faces + {len(holes)} enclosed (eye holes), middle {tuple(round(c, 3) for c in cc)}, radius {rad:.3f} m")
    return cc


def grow_badge(ob, px):
    """The badge: the pale faces on the chest below the card; scaled up about its middle, a little out."""
    me = ob.data
    h, w = px.shape[:2]
    uv = me.uv_layers.active.data
    pts = []
    for p in me.polygons:
        if p.material_index != 0:
            continue
        u = sum(uv[li].uv.x for li in p.loop_indices) / p.loop_total
        v = sum(uv[li].uv.y for li in p.loop_indices) / p.loop_total
        c = px[min(h - 1, int(v * h)), min(w - 1, int(u * w)), :3].mean()
        if c > PALE and p.center.z > 0.3:
            pts.append((p.center.copy(), p))
    # The lowest pale cluster on the front of the chest (the lanyard's pale stripes run up from it).
    if not pts:
        log("badge: none found")
        return
    lowest = min(pts, key=lambda cp: cp[0].z)[0]
    card = [cp for cp in pts if (cp[0] - lowest).length < 0.16 and cp[0].z < lowest.z + 0.12]
    lo = Vector((min(c.x for c, _ in card), min(c.y for c, _ in card), min(c.z for c, _ in card)))
    hi = Vector((max(c.x for c, _ in card), max(c.y for c, _ in card), max(c.z for c, _ in card)))
    mid = (lo + hi) / 2
    pad = 0.012
    verts = set()
    for c, p in card:
        verts.update(p.vertices)
    # Every vertex in the card's box (its outline and back), not only the pale faces'.
    for v in me.vertices:
        if lo.x - pad <= v.co.x <= hi.x + pad and lo.z - pad <= v.co.z <= hi.z + pad and lo.y - 0.02 <= v.co.y <= hi.y + 0.02:
            verts.add(v.index)
    for i in verts:
        co = me.vertices[i].co
        co.x = mid.x + (co.x - mid.x) * BADGE_GROW
        co.z = mid.z + (co.z - mid.z) * BADGE_GROW
        co.y -= 0.006
    log(f"badge: {len(verts)} vertices grown x{BADGE_GROW} about {tuple(round(c, 3) for c in mid)}, was {hi.x - lo.x:.3f} x {hi.z - lo.z:.3f} m")


def paint_face():
    """The face plate's print (FACE_PX square, our own): worn card, two eye holes cut through (alpha 0), a
    thin drawn smile, an oval outline; outside the oval is cut away. The glow map is the bare card: the
    ink and the holes do not glow, so in the dark the face is drawn by what is dark."""
    n = FACE_PX
    v, u = np.mgrid[0:n, 0:n].astype(np.float32)
    u = (u + 0.5) / n
    v = (v + 0.5) / n                                   # Blender images: row 0 is the bottom (v = 0)
    rng = np.random.default_rng(2611)
    noise = rng.random((n // 8, n // 8)).repeat(8, 0).repeat(8, 1)[:n, :n].astype(np.float32)
    oval = ((u - 0.5) / 0.5) ** 2 + ((v - 0.5) / 0.5) ** 2
    card = np.array((0.86, 0.84, 0.74), np.float32)
    col = np.ones((n, n, 4), np.float32)
    col[:, :, :3] = card * (0.9 + 0.1 * noise[:, :, None])
    rim = (oval > 0.80) & (oval <= 1.0)
    col[rim, :3] *= 0.72
    ink = np.zeros((n, n), bool)
    # The smile: a thin arc under the eyes.
    r = np.hypot(u - 0.5, v - 0.56)
    ink |= (np.abs(r - 0.25) < 0.017) & (v < 0.42) & (np.abs(u - 0.5) < 0.19)
    ink |= rim & (oval > 0.93)
    col[ink, :3] = (0.16, 0.14, 0.13)
    holes = np.zeros((n, n), bool)
    for ex in (0.33, 0.67):
        holes |= ((u - ex) / 0.075) ** 2 + ((v - 0.62) / 0.095) ** 2 < 1.0
    col[holes, 3] = 0.0
    col[oval > 1.0, 3] = 0.0
    glow = np.zeros_like(col)
    bare = (col[:, :, 3] > 0.5) & ~ink & ~rim
    glow[bare, :3] = col[bare, :3]
    glow[:, :, 3] = 1.0
    out = []
    for name, px in (("Minder_mask", col), ("Minder_mask_glow", glow)):
        im = bpy.data.images.new(name, n, n, alpha=True)
        im.pixels.foreach_set(px.ravel())
        im.pack()
        out.append(im)
    return out


def make_materials(ob, img, px):
    img.scale(ATLAS_PX, ATLAS_PX)
    img.name = "Minder_atlas"
    img.pack()
    face, glow = paint_face()

    def base(name, image):
        m = bpy.data.materials.new(name)
        nt = m.node_tree
        bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = image
        tex.interpolation = "Closest"
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        bsdf.inputs["Roughness"].default_value = BODY_ROUGH
        if "Specular IOR Level" in bsdf.inputs:
            bsdf.inputs["Specular IOR Level"].default_value = 0.2
        return m, nt, bsdf, tex

    body, _, _, _ = base("Minder_body", img)
    body.use_backface_culling = False
    mask, nt, bsdf, tex = base("Minder_mask", face)
    nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
    gl = nt.nodes.new("ShaderNodeTexImage")
    gl.image = glow
    gl.interpolation = "Closest"
    nt.links.new(gl.outputs["Color"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = MASK_GLOW
    bsdf.inputs["Roughness"].default_value = 0.88
    mask.use_backface_culling = True
    me = ob.data
    old = list(me.materials)
    me.materials.clear()
    me.materials.append(body)
    me.materials.append(mask)
    for m in old:
        if m and m.users == 0:
            bpy.data.materials.remove(m)


def hang_strip(arm, ob):
    """The bib, lanyard and badge hanging in front of the chest: thin sheets (separate pieces of the mesh)
    that Meshy weighted to the chest, so they swung rigidly with it and stuck out like a blade. They go on
    one new bone, "lanyard", pivoting at their top, which the clips keep hanging (see Rig.solve)."""
    me = ob.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    seen, parts = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack, comp = [v], []
        seen.add(v.index)
        while stack:
            a = stack.pop()
            comp.append(a)
            for e in a.link_edges:
                b = e.other_vert(a)
                if b.index not in seen:
                    seen.add(b.index)
                    stack.append(b)
        parts.append(comp)
    strip = []
    for comp in parts:
        co = [v.co for v in comp]
        lo = Vector((min(c.x for c in co), min(c.y for c in co), min(c.z for c in co)))
        hi = Vector((max(c.x for c in co), max(c.y for c in co), max(c.z for c in co)))
        mid = (lo + hi) / 2
        if hi.y - lo.y < 0.07 and abs(mid.x) < 0.22 and -0.46 < mid.y < -0.28 and hi.z < 1.05 and lo.z < 0.75 and len(comp) > 8:
            strip.extend(v.index for v in comp)
    bm.free()
    if not strip:
        log("strip: none found")
        return
    cos = [me.vertices[i].co for i in strip]
    top = max(c.z for c in cos)
    pivot = Vector((0.0, sum(c.y for c in cos) / len(cos), top))
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones.new("lanyard")
    eb.head = pivot
    eb.tail = pivot + Vector((0, 0, -0.15))
    eb.parent = arm.data.edit_bones["chest"]
    bpy.ops.object.mode_set(mode="OBJECT")
    for vg in ob.vertex_groups:
        vg.remove(strip)
    g = ob.vertex_groups.get("lanyard") or ob.vertex_groups.new(name="lanyard")
    g.add(strip, 1.0, "REPLACE")
    log(f"strip: {len(strip)} vertices of bib, lanyard and badge on the new bone 'lanyard', pivot {tuple(round(c, 3) for c in pivot)}, "
        f"hanging to {min(c.z for c in cos):.3f} m")


def add_plate(ob, cc, px):
    """The face plate: a curved card PLATE_W x PLATE_H over the whole front of the head, PLATE_PROUD in
    front of Meshy's small card, facing forward and PLATE_DOWN degrees down at rest, on the head bone alone.
    Its front is the mask material (the only surface with it); its back is a dark sheet of the body's."""
    d = math.radians(PLATE_DOWN)
    n = Vector((0.0, -math.cos(d), -math.sin(d)))
    up = (Vector((0, 0, 1)) - n * n.z).normalized()
    right = up.cross(n)
    c = cc + n * PLATE_PROUD + up * 0.02
    PLATE["c"], PLATE["n"] = c.copy(), n.copy()
    me = ob.data
    h, w = px.shape[:2]
    bm = bmesh.new()
    bm.from_mesh(me)
    uvl = bm.loops.layers.uv.active
    dl = bm.verts.layers.deform.verify()
    gi = ob.vertex_groups["head"].index
    # A dark texel of the body for the back sheet.
    best, dark_uv = 1e9, (0.5, 0.5)
    for f in bm.faces:
        if f.material_index != 0:
            continue
        uv = sum((l[uvl].uv for l in f.loops), Vector((0, 0))) / len(f.loops)
        col = px[min(h - 1, int(uv.y * h)), min(w - 1, int(uv.x * w)), :3].mean()
        dd = (f.calc_center_median() - cc).length
        if col < 0.2 and dd < best:
            best, dark_uv = dd, (uv.x, uv.y)
    NU, NV = 10, 12

    def disc(i, j):
        # The grid squeezed onto an oval (square-to-disc), so the plate is the card's own shape.
        an, bn = i / NU * 2 - 1, j / NV * 2 - 1
        return an * math.sqrt(1 - bn * bn / 2), bn * math.sqrt(1 - an * an / 2)

    def at(i, j, back):
        x, y = disc(i, j)
        a = x * PLATE_W / 2
        b = y * PLATE_H / 2
        th = a / PLATE_BEND
        p = c + right * (PLATE_BEND * math.sin(th)) + up * b - n * (PLATE_BEND * (1 - math.cos(th)) + 0.5 * b * b)
        return p - n * (0.006 if back else 0.0)
    for back in (False, True):
        vs = {}
        for i in range(NU + 1):
            for j in range(NV + 1):
                v = bm.verts.new(at(i, j, back))
                v[dl][gi] = 1.0
                vs[i, j] = v
        for i in range(NU):
            for j in range(NV):
                quad = [vs[i, j], vs[i + 1, j], vs[i + 1, j + 1], vs[i, j + 1]]
                ij = [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)]
                if back:
                    quad.reverse()
                    ij.reverse()
                f = bm.faces.new(quad)
                f.material_index = 0 if back else 1
                f.smooth = True
                for l, (a, b) in zip(f.loops, ij):
                    x, y = disc(a, b)
                    l[uvl].uv = dark_uv if back else (x / 2 + 0.5, y / 2 + 0.5)
    bm.to_mesh(me)
    bm.free()
    log(f"face plate: {PLATE_W:.2f} x {PLATE_H:.2f} m, middle {tuple(round(x, 3) for x in c)} at rest, facing "
        f"{PLATE_DOWN:.0f} deg down, {2 * NU * NV} quads, on the head bone")


def plate_at(P, W):
    """The plate's middle and facing as posed."""
    return P["head"] + W["head"] @ (PLATE["c"] - RIG0["head"]), W["head"] @ PLATE["n"]


RIG0 = {}


def hang(Wc):
    """The strip's world rotation: the chest's heading only, a quarter of its pitch and roll (it hangs)."""
    f = Wc @ Vector((0, -1, 0))
    yaw = math.atan2(f.x, -f.y)
    return Quaternion((0, 0, 1), yaw).slerp(Wc, 0.25)


def thin(ob):
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    if tris > TRIS:
        mod = ob.modifiers.new("thin", "DECIMATE")
        mod.ratio = TRIS / tris
        mod.use_collapse_triangulate = True
        bpy.ops.object.modifier_move_to_index(modifier="thin", index=0)
        bpy.ops.object.modifier_apply(modifier="thin")
    bpy.ops.object.vertex_group_limit_total(group_select_mode="ALL", limit=4)
    bpy.ops.object.vertex_group_normalize_all(group_select_mode="ALL", lock_active=False)
    log(f"mesh: {tris} triangles from Meshy -> {sum(len(p.vertices) - 2 for p in ob.data.polygons)}, "
        f"{len(ob.data.vertices)} vertices, at most 4 weights each")


# ============================ the pose solver ============================

class Rig:
    def __init__(self, arm):
        self.arm = arm
        self.bones = list(arm.data.bones)
        # parents first
        order, seen = [], set()

        def visit(b):
            if b.name in seen:
                return
            if b.parent:
                visit(b.parent)
            seen.add(b.name)
            order.append(b)
        for b in self.bones:
            visit(b)
        self.order = order
        self.H0 = {b.name: b.head_local.copy() for b in self.bones}
        self.R0 = {b.name: b.matrix_local.copy() for b in self.bones}
        self.parent = {b.name: (b.parent.name if b.parent else None) for b in self.bones}
        self.reach_err = {}
        self.prev_q = {}
        for pb in arm.pose.bones:
            pb.rotation_mode = "QUATERNION"

    def contact0(self, leg):
        return self.H0[LEGS[leg]["tip"]].copy()

    def ik2(self, leg, root, target, Wp):
        L = LEGS[leg]
        a0 = self.H0[L["upper"]]
        b0 = self.H0[L["lower"]]
        c0 = self.H0[L["end"] if L["kind"] == "front" else L["meta"]]
        u0, v0 = b0 - a0, c0 - b0
        l1, l2 = u0.length, v0.length
        d_vec = target - root
        d = d_vec.length
        dmax, dmin = (l1 + l2) * 0.999, abs(l1 - l2) * 1.001 + 1e-4
        if d > dmax or d < dmin:
            key = f"{getattr(self, 'clip', '')} {leg}"
            self.reach_err[key] = max(self.reach_err.get(key, 0.0), (d - dmax) if d > dmax else (dmin - d))
            d = min(dmax, max(dmin, d))
        a = d_vec.normalized()
        # The rest pose's own bend direction, carried by the parent: the pole.
        line0 = (c0 - a0).normalized()
        perp0 = u0 - line0 * u0.dot(line0)
        pole = Wp @ perp0
        pole = pole - a * pole.dot(a)
        if pole.length < 1e-6:
            pole = Vector((0, -1, 0))
        pole.normalize()
        x = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
        hgt = math.sqrt(max(0.0, l1 * l1 - x * x))
        knee = root + a * x + pole * hgt
        end = root + a * d
        n0 = u0.cross(v0)
        if n0.length < 1e-9:
            n0 = Vector((1, 0, 0))
        n0.normalize()
        n1 = (knee - root).cross(end - knee)
        n1 = n1.normalized() if n1.length > 1e-9 else Wp @ n0

        def frame(xa, za):
            xa = xa.normalized()
            ya = za.cross(xa).normalized()
            za = xa.cross(ya)
            return Matrix((xa, ya, za)).transposed()
        Wu = (frame(knee - root, n1) @ frame(u0, n0).transposed()).to_quaternion()
        Wl = (frame(end - knee, n1) @ frame(v0, n0).transposed()).to_quaternion()
        return Wu, Wl

    def solve(self, pose):
        """pose: root (offset), L {bone: local quat}, off {bone: offset}, legs {leg: dict(c, roll, meta, curl, yaw)}.
        Returns the posed heads and world rotations."""
        Lr = pose.get("L", {})
        off = pose.get("off", {})
        legs = pose.get("legs", {})
        W, P = {}, {}
        forced = {}
        for b in self.order:
            n = b.name
            p = self.parent[n]
            if p is None:
                P[n] = self.H0[n] + pose.get("root", Vector())
                W[n] = Lr.get(n, Quaternion())
            else:
                P[n] = P[p] + W[p] @ (self.H0[n] - self.H0[p]) + off.get(n, Vector())
                W[n] = forced[n] if n in forced else W[p] @ Lr.get(n, Quaternion())
                if n == "lanyard":
                    W[n] = hang(W[p])
            for leg, L in LEGS.items():
                if L["upper"] != n or leg not in legs:
                    continue
                s = legs[leg]
                yaw = q("z", s.get("yaw", 0.0))
                c = s["c"]
                if L["kind"] == "front":
                    wend = yaw @ q("x", s.get("roll", 0.0))
                    wrist = c - wend @ (self.H0[L["tip"]] - self.H0[L["end"]])
                    Wu, Wl = self.ik2(leg, P[n], wrist, W[p])
                    forced[L["lower"]] = Wl
                    forced[L["end"]] = wend
                    forced[L["tip"]] = wend @ q("x", s.get("curl", 0.0))
                else:
                    wfoot = yaw @ q("x", s.get("roll", 0.0))
                    ball = c - wfoot @ (self.H0[L["tip"]] - self.H0[L["end"]])
                    wmeta = yaw @ q("x", s.get("meta", 0.0))
                    hock = ball - wmeta @ (self.H0[L["end"]] - self.H0[L["meta"]])
                    Wu, Wl = self.ik2(leg, P[n], hock, W[p])
                    forced[L["lower"]] = Wl
                    forced[L["meta"]] = wmeta
                    forced[L["end"]] = wfoot
                    forced[L["tip"]] = wfoot @ q("x", s.get("curl", 0.0))
                W[n] = Wu
        return P, W

    def basis(self, P, W):
        out = {}
        M = {}
        for b in self.order:
            n = b.name
            R0 = self.R0[n]
            M[n] = Matrix.Translation(P[n]) @ W[n].to_matrix().to_4x4() @ R0.to_3x3().to_4x4()
            p = self.parent[n]
            if p is None:
                out[n] = R0.inverted() @ M[n]
            else:
                out[n] = (M[p] @ self.R0[p].inverted() @ R0).inverted() @ M[n]
        return out

    def apply(self, pose):
        P, W = self.solve(pose)
        B = self.basis(P, W)
        for pb in self.arm.pose.bones:
            m = B[pb.name]
            qq = m.to_quaternion()
            pq = self.prev_q.get(pb.name)
            if pq is not None and pq.dot(qq) < 0:
                qq = -qq
            self.prev_q[pb.name] = qq
            pb.rotation_quaternion = qq
            pb.location = m.translation
            pb.scale = (1, 1, 1)
        return P, W


# ============================ the clips ============================

def planted(rig, dx=None):
    """Every foot on its rest spot."""
    out = {}
    for leg in LEGS:
        c = rig.contact0(leg)
        if dx:
            c = c + dx.get(leg, Vector())
        out[leg] = dict(c=c, roll=0.0, meta=0.0)
    return out


def spine(pitch=0.0, yaw=0.0, arch=0.0, neck_pitch=0.0, head_pitch=0.0, head_yaw=0.0, head_roll=0.0, hips_yaw=0.0,
          breathe=0.0, roll=0.0):
    """Local rotations for the trunk: the root's pitch/yaw/roll, the back arching up (arch > 0), the shoulders
    counter-turned against the hips (hips_yaw), the neck and head (pitch > 0 lower, yaw > 0 to its left)."""
    return {
        "root": qe(x=pitch, z=yaw, y=roll),
        "hips": qe(z=hips_yaw),
        "spine1": qe(x=-arch * 0.4),
        "spine2": qe(x=-arch * 0.4 + breathe, z=-hips_yaw),
        "spine_04": qe(x=arch * 0.3 - breathe, z=-hips_yaw),
        "chest": qe(x=arch * 0.5),
        "neck1": qe(x=neck_pitch * 0.5, z=head_yaw * 0.35),
        "neck2": qe(x=neck_pitch * 0.5, z=head_yaw * 0.35),
        "head": qe(x=head_pitch, z=head_yaw * 0.3, y=head_roll),
    }


def lvl(H, pitch, neck):
    """The head pitch that leaves the face plate H degrees below its rest tilt (PLATE_DOWN) with the trunk
    pitched `pitch` and the neck `neck` (the arch terms of spine() cancel): H = -PLATE_DOWN is level."""
    return H - pitch - neck


def gait_foot(rig, leg, u, g, sweep_scale=1.0):
    """One foot at gait phase u (0..1, 0 = touch-down): stance moves it back under the body at the body's
    speed (flat contact), lift-off rolls it off the toes, the swing carries it forward with the toes curled."""
    duty = g["duty"]
    stride = g["stride"] / g["cycles"]
    sweep = stride * duty * sweep_scale
    front = LEGS[leg]["kind"] == "front"
    lift = g["lift"][0 if front else 1]
    rmax = g["roll"][0 if front else 1]
    c0 = rig.contact0(leg)
    if u < duty:
        s = u / duty
        dy = sweep * (s - 0.5)
        dz = 0.0
        roll = rmax * smooth((s - 0.55) / 0.45)
        curl = 0.0
    else:
        s = (u - duty) / (1 - duty)
        e = smooth(s)
        dy = sweep * (0.5 - e)
        dz = lift * math.sin(math.pi * s) ** 0.8
        roll = rmax * (1 - smooth(s / 0.85)) + (12.0 if not front else 8.0) * math.sin(math.pi * s)
        curl = -25.0 * math.sin(math.pi * s)
    meta = (8.0 * smooth((s - 0.6) / 0.4) if u < duty else 22.0 * math.sin(math.pi * s)) if not front else 0.0
    return dict(c=c0 + Vector((0, dy, dz)), roll=roll, meta=meta, curl=curl)


def gait_pose(rig, name, t, T):
    g = GAITS[name]
    ph = (t / T) * g["cycles"]
    legs = {leg: gait_foot(rig, leg, (ph - off) % 1.0, g) for leg, off in g["phase"].items()}
    w = 2 * math.pi
    clip_ph = t / T
    if name == "run":
        # The gallop: the back folds as the hind feet reach under (just after their touch-down) and opens as
        # the fore feet reach; the front pitches up as the fore feet push off; the body is highest in flight.
        flex = math.cos(w * (ph - 0.22))
        pitch = 4.0 + 6.0 * math.cos(w * (ph - 0.55))
        neck = -4.0 + 4.0 * flex
        L = spine(pitch=pitch, arch=10.0 * flex, neck_pitch=neck, head_pitch=lvl(-3.0, pitch, neck),
                  hips_yaw=g["cr"] * math.sin(w * ph))
        root = Vector((0, 0.04 * flex, -g["low"] + g["bob"] * math.cos(w * (ph - 0.9))))
    else:
        sniff = g["sniff"] * math.sin(w * clip_ph)
        pitch = 6.0 + g["low"] * 30.0
        neck = 10.0 + g["low"] * 60.0
        # The face comes up level once a play (walk: a slow nod; prowl: it dips to sniff and rises to look).
        H = -4.0 + 8.0 * math.sin(w * clip_ph) if name == "walk" else 12.0 + 12.0 * math.sin(w * clip_ph)
        L = spine(pitch=pitch, arch=-3.0, neck_pitch=neck, head_pitch=lvl(H, pitch, neck),
                  head_yaw=sniff, head_roll=-0.25 * sniff, hips_yaw=g["cr"] * math.sin(w * ph),
                  roll=1.5 * math.sin(w * ph))
        root = Vector((0.012 * math.sin(w * ph), 0, -g["low"] + g["bob"] * math.cos(2 * w * ph)))
    # The shoulder blade rides forward with the fore foot's reach.
    off = {}
    for leg in ("LF", "RF"):
        dy = legs[leg]["c"].y - rig.contact0(leg).y
        off[LEGS[leg]["scap"]] = Vector((0, 0.18 * dy, 0))
    return dict(root=root, L=L, legs=legs, off=off)


def stand_pose(rig, t, T=4.0):
    w = 2 * math.pi * t / T
    breath = 2.0 * math.sin(2 * w)
    L = spine(pitch=4.0, neck_pitch=10.0, head_pitch=lvl(-5.0 + 6.0 * math.sin(w), 4.0, 10.0), head_yaw=12.0 * math.sin(w), head_roll=-3.0 * math.sin(w),
              breathe=breath * 0.6, roll=2.0 * math.sin(w + 0.6), hips_yaw=1.5 * math.sin(w))
    root = Vector((0.02 * math.sin(w + 0.6), 0, -0.03 + 0.006 * math.sin(2 * w)))
    return dict(root=root, L=L, legs=planted(rig))


def walk_pose(rig, t):
    return gait_pose(rig, "walk", t, 1.5)


def prowl_pose(rig, t):
    return gait_pose(rig, "prowl", t, 2.0 / 3.0)


def run_pose(rig, t):
    return gait_pose(rig, "run", t, 0.5)


def low_stance(rig):
    """The searching crouch the one-shots start from: as the prowl's body, feet planted."""
    g = GAITS["prowl"]
    return dict(root=Vector((0, 0, -g["low"])), L=spine(pitch=6.0 + g["low"] * 30.0, arch=-3.0,
                neck_pitch=10.0 + g["low"] * 60.0, head_pitch=4.0), legs=planted(rig))


def look_pose(rig, t):
    """2 s, held: head and shoulders turn to its left, the right fore paw lifts off the floor, then it holds
    still with the head tilted, listening."""
    g = GAITS["prowl"]
    e = ramp(t, 0.0, 0.8)
    e2 = ramp(t, 0.9, 1.6)
    lift = ramp(t, 0.2, 0.7)
    legs = planted(rig)
    c = rig.contact0("RF")
    legs["RF"] = dict(c=c + Vector((0.03 * lift, -0.06 * lift, 0.13 * lift)), roll=55.0 * lift, curl=-20.0 * lift)
    pitch = 6.0 + g["low"] * 30.0 - 4.0 * e
    neck = 10.0 + g["low"] * 60.0 - 8.0 * e
    L = spine(pitch=pitch, arch=-3.0, neck_pitch=neck,
              head_pitch=lvl(12.0 - 18.0 * e, pitch, neck), yaw=8.0 * e, hips_yaw=-10.0 * e, head_yaw=30.0 * e + 6.0 * e2, head_roll=-14.0 * e2)
    return dict(root=Vector((0.03 * e, 0, -g["low"])), L=L, legs=legs)


def sweep_pose(rig, t, T=3.0):
    """3 s loop: low, the head and shoulders swinging wide side to side, the fore feet stepping in place
    as the rules turn its body."""
    g = GAITS["prowl"]
    w = 2 * math.pi * t / T
    sw = math.sin(w)
    legs = planted(rig)
    for leg, t0 in (("LF", 0.15), ("RF", 0.9), ("LF", 1.65), ("RF", 2.4)):
        s = (t - t0) / 0.45
        if 0 <= s <= 1:
            c = legs[leg]["c"]
            legs[leg] = dict(c=c + Vector((0, -0.04 * math.sin(math.pi * s), 0.08 * math.sin(math.pi * s))),
                             roll=30.0 * math.sin(math.pi * s), curl=-15.0 * math.sin(math.pi * s))
    pitch = 6.0 + g["low"] * 30.0
    neck = 14.0 + g["low"] * 60.0
    L = spine(pitch=pitch, arch=-3.0, neck_pitch=neck, head_pitch=lvl(-2.0 + 6.0 * math.sin(2 * w), pitch, neck),
              yaw=10.0 * sw, hips_yaw=-6.0 * sw, head_yaw=34.0 * sw, head_roll=-6.0 * sw)
    return dict(root=Vector((0.02 * sw, 0, -g["low"] - 0.01 * math.cos(2 * w))), L=L, legs=legs)


def cover_pose(rig, t, T=3.0):
    """3 s loop, while it counts: the front sunk to the floor, the mask pressed down to it and both fore
    paws folded over it; the flanks breathe, the body rocks a little."""
    w = 2 * math.pi * t / T
    L = spine(pitch=24.0, arch=6.0 + 1.5 * math.sin(w), neck_pitch=36.0, head_pitch=22.0, breathe=2.5 * math.sin(2 * w),
              roll=1.5 * math.sin(w))
    root = Vector((0, 0.10, -0.24 + 0.008 * math.sin(2 * w)))
    body = dict(root=root, L=L, legs={})
    P, W = rig.solve(body)
    head = P["head"]
    legs = planted(rig, {"LH": Vector((0, -0.05, 0)), "RH": Vector((0, -0.05, 0))})
    for leg, sx in (("LF", 1.0), ("RF", -1.0)):
        # The knuckles over the card, the paws hanging down over the face.
        c = head + W["head"] @ Vector((0.07 * sx, -0.20, 0.03))
        c.z = max(c.z, 0.06)
        legs[leg] = dict(c=c, roll=70.0, curl=-35.0)
    return dict(root=root, L=L, legs=legs)


CATCH_EYE = 1.6         # the player's eye height the catch ends level with
CATCH_FACE = 1.5        # the plate's middle at the end of the catch (m): just under the eye, filling the view
_CATCH = {}


def catch_end(rig):
    """The end of the lunge: reared on its hind legs, the neck thrust up and forward, the plate level at
    CATCH_FACE. Finds the trunk's pitch for that height once (by search; deterministic)."""
    if _CATCH:
        return _CATCH
    neck = -30.0
    best = None
    for k in range(0, 71):
        pitch = -float(k)
        L = spine(pitch=pitch, neck_pitch=neck, head_pitch=lvl(-PLATE_DOWN, pitch, neck), arch=-4.0)
        root = Vector((0, -0.18, 0.04))
        P, W = rig.solve(dict(root=root, L=L, legs={}))
        c, n = plate_at(P, W)
        err = abs(c.z - CATCH_FACE)
        if best is None or err < best[0]:
            best = (err, pitch, c.copy(), n.copy())
    _CATCH.update(pitch=best[1], neck=neck, root=Vector((0, -0.18, 0.04)), face=best[2], facing=best[3])
    log(f"catch: reared {-best[1]:.0f} deg, plate middle {tuple(round(x, 3) for x in best[2])} facing {tuple(round(x, 2) for x in best[3])}")
    return _CATCH


def catch_pose(rig, t):
    """3 s, held: gathers low, then rears and thrusts its head up and forward at the player, the plate level
    with their eyes and facing them, the right fore paw thrown out open beside its face, the left hanging;
    small jabs of the head that die away, ending held exactly on that pose."""
    g = GAITS["prowl"]
    end = catch_end(rig)
    gather = ramp(t, 0.0, 0.45) * (1 - ramp(t, 0.45, 0.75))
    e = ramp(t, 0.45, 0.95)
    jab = math.sin(2 * math.pi * 3.0 * max(0.0, t - 0.95)) * math.exp(-2.2 * max(0.0, t - 0.95)) * (1 - ramp(t, 2.4, 3.0)) if t > 0.95 else 0.0
    p0, n0 = 6.0 + g["low"] * 30.0 + 5.0 * gather, 10.0 + g["low"] * 60.0 + 6.0 * gather
    pitch = lerp(p0, end["pitch"], e)
    neck = lerp(n0, end["neck"], e) + 4.0 * jab
    H = lerp(10.0, -PLATE_DOWN, e)
    root = Vector((0, 0.10 * gather, -g["low"] - 0.06 * gather)).lerp(end["root"], e) + Vector((0, -0.03 * jab, 0))
    L = spine(pitch=pitch, arch=lerp(-3.0 + 8.0 * gather, -4.0, e), neck_pitch=neck, head_pitch=lvl(H, pitch, neck) - 4.0 * jab)
    legs = planted(rig, {"LH": Vector((0, -0.10 * e, 0)), "RH": Vector((0, -0.12 * e, 0))})
    P, W = rig.solve(dict(root=root, L=L, legs={}))
    face, facing = plate_at(P, W)
    # The fore paws: off the floor as it rears; the right one thrown out beside the face, palm forward.
    for leg, side in (("RF", -1.0), ("LF", 1.0)):
        c0 = rig.contact0(leg)
        if leg == "RF":
            tgt = face + Vector((0.27 * side, -0.06, -0.10))
            roll, curl = -70.0, 12.0
        else:
            sh = P[LEGS[leg]["upper"]]
            tgt = sh + Vector((0.06, -0.30, -0.62))
            roll, curl = 65.0, -30.0
        k = ramp(t, 0.5, 0.95)
        legs[leg] = dict(c=c0.lerp(tgt, k), roll=roll * k, curl=curl * k, yaw=(-25.0 if leg == "RF" else 0.0) * k)
    return dict(root=root, L=L, legs=legs)

def slump_pose(rig, t):
    """1 s, held: the legs give, the belly sinks to the floor, the head drops."""
    g = GAITS["prowl"]
    e = ramp(t, 0.0, 1.0)
    root = Vector((0, 0.02 * e, -g["low"] - 0.30 * e))
    L = spine(pitch=6.0 + g["low"] * 30.0 + 4.0 * e, arch=-3.0 - 6.0 * e, neck_pitch=10.0 + g["low"] * 60.0 + 14.0 * e,
              head_pitch=4.0 + 16.0 * e, head_roll=10.0 * e)
    dx = {}
    for leg in LEGS:
        c = rig.contact0(leg)
        dx[leg] = Vector((c.x * 0.30 * e, (0.10 if LEGS[leg]["kind"] == "hind" else -0.12) * e, 0))
    legs = planted(rig, dx)
    for leg in ("LF", "RF"):
        legs[leg]["roll"] = -10.0 * e
    return dict(root=root, L=L, legs=legs)


def straighten_pose(rig, t):
    """3 s, held (ends in the stand's first pose): rears up on its hind legs, one fore paw reaching forward
    and up to put something straight, tapping it twice, then comes back down to stand."""
    up = ramp(t, 0.0, 1.0) * (1 - ramp(t, 1.9, 2.8))
    tap = math.sin(2 * math.pi * (t - 1.05) / 0.4) if 1.05 < t < 1.85 else 0.0
    base = stand_pose(rig, 0.0)
    Lb = base["L"]
    Lu = spine(pitch=4.0 - 42.0, neck_pitch=10.0 + 30.0, head_pitch=2.0 + 18.0, arch=-6.0)
    L = {k: Lb[k].slerp(Lu.get(k, Quaternion()), up) for k in Lb}
    root = base["root"].lerp(Vector((0, 0.10, -0.03)), up)
    legs = planted(rig)
    for leg, reach in (("RF", (0.0, -0.40, 0.92)), ("LF", (0.04, -0.12, 0.62))):
        c0 = rig.contact0(leg)
        r = Vector(reach)
        if leg == "RF":
            r = r + Vector((0, -0.05 * max(0.0, tap), 0.0))
        lift = ramp(t, 0.15, 0.95) * (1 - ramp(t, 1.9, 2.9))
        legs[leg] = dict(c=c0.lerp(c0 + r, lift), roll=65.0 * lift, curl=-25.0 * lift)
    return dict(root=root, L=L, legs=legs)


POSES = {"stand": stand_pose, "walk": walk_pose, "prowl": prowl_pose, "run": run_pose, "look": look_pose,
         "sweep": sweep_pose, "cover": cover_pose, "catch": catch_pose, "slump": slump_pose, "straighten": straighten_pose}


# ============================ actions and export ============================

def iter_fcurves(act):
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for cb in strip.channelbags:
                for fc in cb.fcurves:
                    yield fc


def make_action(rig, name, length, loop):
    arm = rig.arm
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    ad = arm.animation_data or arm.animation_data_create()
    act = bpy.data.actions.new(name + ("-loop" if loop else ""))
    ad.action = act
    n = int(round(length * FPS))
    rig.prev_q = {}
    rig.clip = name
    fn = POSES[name]
    first = None
    for i in range(n + 1):
        t = (0.0 if (loop and i == n) else i / FPS)
        rig.apply(fn(rig, t))
        if i == 0:
            first = {pb.name: pb.rotation_quaternion.copy() for pb in arm.pose.bones}
        if loop and i == n:
            # the loop's seam: exactly the first pose, on the same side of the quaternion sphere
            for pb in arm.pose.bones:
                f = first[pb.name]
                cur = pb.rotation_quaternion
                pb.rotation_quaternion = f if f.dot(cur) >= 0 else -f
        for pb in arm.pose.bones:
            for path in ("rotation_quaternion", "location", "scale"):
                pb.keyframe_insert(path, frame=1 + i, group=pb.name)
    act.use_fake_user = True
    track = ad.nla_tracks.new()
    track.name = act.name
    track.strips.new(act.name, 1, act)
    track.mute = True
    ad.action = None
    return n


def foot_slide(rig, name, length):
    """Max horizontal speed error of a planted foot in a gait (m/s against the body's own speed): 0 means the
    view's GAIT_SPEED keeps the feet still on the floor."""
    g = GAITS[name]
    speed = g["stride"] / length
    worst = 0.0
    n = 120
    for leg, off in g["phase"].items():
        prev = None
        for i in range(n + 1):
            t = length * i / n
            u = ((t / length) * g["cycles"] - off) % 1.0
            P, W = rig.solve(POSES[name](rig, t))
            tip = P[LEGS[leg]["tip"]]
            if prev is not None and u < g["duty"] * 0.5 and pu < u:
                v = (tip.y - prev.y) / (length / n)
                worst = max(worst, abs(v - speed))
            prev, pu = tip, u
    return speed, worst


def report_rest(rig, ob):
    zs = [v.co.z for v in ob.data.vertices]
    ys = [v.co.y for v in ob.data.vertices]
    xs = [v.co.x for v in ob.data.vertices]
    log(f"rest: {max(zs) - min(zs):.3f} m tall, {max(ys) - min(ys):.3f} m long (y {min(ys):.3f}..{max(ys):.3f}), "
        f"{max(xs) - min(xs):.3f} m wide; head bone at {tuple(round(c, 3) for c in rig.H0['head'])}")
    for b in rig.order:
        log(f"  bone {b.name:18s} parent {str(rig.parent[b.name]):18s} head {tuple(round(c, 3) for c in b.head_local)}")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "godot", "assets", "entities", "minder_v2.glb"))
    ap.add_argument("--blend", default="")
    ap.add_argument("--drop", default="", help="comma-separated clips to leave out (for a break test)")
    args = ap.parse_args(argv)
    drop = set(x for x in args.drop.split(",") if x)

    arm, ob = load_source()
    bpy.context.scene.render.fps = FPS
    img = next(n.image for m in ob.data.materials if m and m.node_tree for n in m.node_tree.nodes
               if n.type == "TEX_IMAGE" and n.image)
    px = atlas_pixels(img)
    make_materials(ob, img, px)
    mask_mid = split_mask(ob, px)
    grow_badge(ob, px)
    hang_strip(arm, ob)
    thin(ob)
    add_plate(ob, mask_mid, px)
    rig = Rig(arm)
    RIG0.update(rig.H0)
    report_rest(rig, ob)
    log(f"mask middle at rest {tuple(round(c, 3) for c in mask_mid)} (height {mask_mid.z:.3f} m)")

    for name, length, loop in CLIPS:
        if name in drop:
            log(f"DROPPED clip {name} (break test)")
            continue
        n = make_action(rig, name, length, loop)
        extra = ""
        if name in GAITS:
            speed, slide = foot_slide(rig, name, length)
            extra = f", stride {GAITS[name]['stride']:.2f} m per play ({GAITS[name]['cycles']} cycle(s)), GAIT_SPEED {speed:.3f}, planted-foot speed error up to {slide:.3f} m/s"
        log(f"clip {name}: {n} frames at {FPS} fps = {n / FPS:.3f} s, {'loop' if loop else 'once, held'}{extra}")
    for leg, e in sorted(rig.reach_err.items()):
        log(f"reach: {leg} out of reach by up to {e * 1000:.0f} mm (clamped)")
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = 1, 121

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    if args.blend:
        bpy.ops.wm.save_as_mainfile(filepath=args.blend)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB", export_animations=True,
                              export_animation_mode="ACTIONS", export_skins=True, export_yup=True,
                              export_apply=False, export_force_sampling=True, export_anim_slide_to_zero=True,
                              export_image_format="AUTO")
    log("exported", os.path.relpath(args.out, ROOT), os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
