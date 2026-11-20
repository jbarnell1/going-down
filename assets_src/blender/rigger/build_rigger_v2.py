"""The Rigger, second figure: the owner's Meshy model (assets_src/meshy/rigger/rigger_meshy.glb), rigged by hand.

Run from the repository root (no window; a minute or two):

  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/rigger/build_rigger_v2.py

Optional arguments after `--`:
  renders=<folder>   also write the review renders (rest pose with bones; one frame of climb, hang, reach, search)
  noexport           build and check only

Writes godot/assets/ward/rigger_v2.glb: one skinned mesh, one skeleton, a 1024 px albedo, a `Lamp` marker on the
helmet, and the clips "Rigger Climb" (the clip the Ward's view plays: the same name and length as rigger.glb's),
climb, hang, reach, search and withdraw. Everything is measured from the mesh and nothing is random: the same source
gives the same file.

The source has two arms and six legs. The owner wants one arm ("I really like the rigger only having one arm"), so
the figure's right arm (Blender -X) is cut at the shoulder and the hole closed with a sunken stump; the concept sheet
has eight legs, so each middle leg is copied once, turned forward and shortened a little, making four a side.

Axes: Blender +Z up, the figure faces -Y (glTF/Godot +Z), its left (the kept arm) is +X. The origin is the centre of
the abdomen (the spider body).
"""
import bpy, bmesh, heapq, math, sys
from pathlib import Path
from mathutils import Matrix, Quaternion, Vector

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / "assets_src" / "meshy" / "rigger" / "rigger_meshy.glb"
OUT = ROOT / "godot" / "assets" / "ward" / "rigger_v2.glb"
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
RENDERS = next((a.split("=", 1)[1] for a in ARGS if a.startswith("renders=")), "")
EXPORT = "noexport" not in ARGS

## Source units to metres: the abdomen (about 0.9 units long) and the leg span (about 1.5 units across) come out at
## today's figure's size (rigger.glb: abdomen about 4.3 x 5.1 m, legs about 7.9 m across).
SCALE = 5.0
FPS = 30
UP = Vector((0, 0, 1))


def log(*parts):
    print("RIG", *parts, flush=True)


# ---------------------------------------------------------------------------------------------------------------
# 1. The mesh: import, weld the seams the glTF import split, drop loose crumbs.

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(SOURCE))
body_obj = next(o for o in bpy.data.objects if o.type == "MESH")
for o in list(bpy.data.objects):
    if o is not body_obj:
        bpy.data.objects.remove(o, do_unlink=True)
body_obj.name = "Rigger"
body_obj.data.name = "Rigger"
body_obj.matrix_world = Matrix.Identity(4)
bm = bmesh.new()
bm.from_mesh(body_obj.data)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)


def refresh():
    bm.verts.ensure_lookup_table()
    bm.verts.index_update()
    bm.faces.ensure_lookup_table()
    bm.faces.index_update()


def components():
    seen = set()
    out = []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack = [v]
        seen.add(v.index)
        part = []
        while stack:
            x = stack.pop()
            part.append(x)
            for e in x.link_edges:
                y = e.other_vert(x)
                if y.index not in seen:
                    seen.add(y.index)
                    stack.append(y)
        out.append(part)
    return out


refresh()
crumbs = [v for part in components() if len(part) < 100 for v in part]
bmesh.ops.delete(bm, geom=crumbs, context="VERTS")
refresh()
open_edges = sum(1 for e in bm.edges if e.is_boundary)
log("mesh", len(bm.verts), "vertices", len(bm.faces), "triangles after welding;", len(crumbs),
    "loose vertices dropped;", open_edges, "open edges")


def geodesic(start):
    """Shortest distance along the surface from vertex `start` to every vertex it connects to."""
    dist = {start.index: 0.0}
    heap = [(0.0, start.index)]
    verts = bm.verts
    while heap:
        d, i = heapq.heappop(heap)
        if d > dist[i]:
            continue
        v = verts[i]
        for e in v.link_edges:
            w = e.other_vert(v)
            nd = d + e.calc_length()
            if nd < dist.get(w.index, 1e9):
                dist[w.index] = nd
                heapq.heappush(heap, (nd, w.index))
    return dist


def trace(start, after, band=0.02):
    """Walks a limb from its tip in rings of equal surface distance. The limb has joined the body at the first ring
    past `after` where five rings in a row are wider than 0.05 units and the fifth is wider than 0.09 (a knee or a
    bandage widens for a ring or two; the body keeps widening). Returns (ring centres tip first, cut, distances)."""
    dist = geodesic(start)
    rings = {}
    for i, d in dist.items():
        rings.setdefault(int(d / band), []).append(bm.verts[i].co)
    table = []
    for k in sorted(rings):
        ring = rings[k]
        c = sum(ring, Vector()) / len(ring)
        table.append(((k + 0.5) * band, c, max((p - c).length for p in ring)))
    cut = None
    centres = []
    for n, (d, c, w) in enumerate(table):
        run = table[n:n + 5]
        if d > after and len(run) == 5 and all(r[2] > 0.05 for r in run) and run[-1][2] > 0.09:
            cut = d - band * 0.5
            break
        centres.append(c)
    return centres, cut, dist


def simplify(points, count):
    """Keeps `count` points of a polyline: the ends, then each time the point farthest from its chord."""
    keep = [0, len(points) - 1]
    while len(keep) < count:
        best, where = -1.0, None
        keep.sort()
        for a, b in zip(keep, keep[1:]):
            pa, pb = points[a], points[b]
            axis = (pb - pa).normalized()
            for i in range(a + 1, b):
                off = points[i] - pa
                d = (off - axis * off.dot(axis)).length
                if d > best:
                    best, where = d, i
        if where is None:
            break
        keep.append(where)
    return [points[i] for i in sorted(keep)]


def nearest(point):
    return min(bm.verts, key=lambda v: (v.co - point).length_squared)


# ---------------------------------------------------------------------------------------------------------------
# 2. One arm: the figure's right arm (-X) goes, cut where it joins the shoulder; the hole is capped with a stump.

right_tip = min((v for v in bm.verts if v.co.x < 0.0), key=lambda v: v.co.y)
_, cut_right, dist_right = trace(right_tip, after=0.4)
assert cut_right is not None, "the right arm should meet the shoulder"
doomed = [bm.verts[i] for i, d in dist_right.items() if d < cut_right]
log("right arm cut", len(doomed), "vertices at %.3f units from its fingertip" % cut_right)
already_open = {frozenset(v.co.to_tuple(6) for v in e.verts) for e in bm.edges if e.is_boundary}
bmesh.ops.delete(bm, geom=doomed, context="VERTS")
refresh()
rim = [e for e in bm.edges if e.is_boundary and frozenset(v.co.to_tuple(6) for v in e.verts) not in already_open]
uv = bm.loops.layers.uv.active
rim_uv = {v: v.link_loops[0][uv].uv.copy() for e in rim for v in e.verts}
filled = bmesh.ops.holes_fill(bm, edges=rim, sides=0)["faces"]
stump = bmesh.ops.poke(bm, faces=filled)
bm.normal_update()
for v in stump["verts"]:
    ring = [e.other_vert(v) for e in v.link_edges]
    v.co -= sum((r.normal for r in ring), Vector()).normalized() * 0.02
for f in stump["faces"]:
    for loop in f.loops:
        source = loop.vert if loop.vert in rim_uv else next(
            (e.other_vert(loop.vert) for e in loop.vert.link_edges if e.other_vert(loop.vert) in rim_uv), None)
        if source is not None:
            loop[uv].uv = rim_uv[source]
refresh()
log("stump", len(filled), "cap faces,", len(rim), "rim edges")

# ---------------------------------------------------------------------------------------------------------------
# 3. Eight legs: each middle leg is copied, turned 24 degrees forward about its hip and made 9 % shorter.

feet = []
for v in sorted(bm.verts, key=lambda v: v.co.z):
    if v.co.z > -0.8:
        break
    if all((v.co.xy - f.co.xy).length > 0.12 for f in feet):
        feet.append(v)
assert len(feet) == 6, "the source should have six feet (found %d)" % len(feet)
feet_at = [f.co.copy() for f in feet]
copies = []
for tip in [f for f in feet if abs(f.co.x) > 0.62]:
    side = 1.0 if tip.co.x > 0 else -1.0
    centres, cut, dist = trace(tip, after=0.8)
    hip = centres[-1].copy()
    leg_verts = {i for i, d in dist.items() if d < cut}
    faces = [f for f in bm.faces if all(v.index in leg_verts for v in f.verts)]
    made = bmesh.ops.duplicate(bm, geom=faces)
    new_verts = [g for g in made["geom"] if isinstance(g, bmesh.types.BMVert)]
    turn = Matrix.Rotation(-side * math.radians(24), 4, "Z")
    shift = Vector((-side * 0.035, -0.07, 0.0))
    place = Matrix.Translation(hip + shift) @ turn @ Matrix.Scale(0.91, 4) @ Matrix.Translation(-hip)
    for v in new_verts:
        v.co = place @ v.co
    copies.append(place @ tip.co)
    refresh()
    log("copied leg", "+X" if side > 0 else "-X", len(new_verts), "vertices; hip", tuple(round(c, 3) for c in hip))
refresh()
feet_at += copies

# ---------------------------------------------------------------------------------------------------------------
# 4. Measure every limb on the final mesh: centrelines, joints, and which vertices belong to which limb.


def leg_name(tip):
    side = "L" if tip.x > 0 else "R"  # The figure's left is +X.
    same = sorted((t for t in feet_at if (t.x > 0) == (tip.x > 0)), key=lambda t: t.y)
    return "%s%d" % (side, same.index(tip) + 1)  # 1 is the front leg, 4 the back.


def leg_joints(line):
    """hip, knee, ankle, tip from a leg's centreline (hip first). The knee is the top of the arch; the ankle is where
    the lower leg bends most (the bandaged joint). The back legs' thighs lie along the abdomen, so their arch top is
    the hip itself: there the knee is put halfway down the centreline to the ankle."""
    upper = line[:int(len(line) * 0.7)]
    knee = max(range(len(upper)), key=lambda i: upper[i].z)
    if (line[knee] - line[0]).length < 0.12:
        knee = None
    start = knee or 0
    a, b = line[start], line[-1]
    axis = (b - a).normalized()
    ankle = max(range(start + 1, len(line) - 1),
                key=lambda i: ((line[i] - a) - axis * (line[i] - a).dot(axis)).length)
    if knee is None:
        knee = ankle // 2
    return [line[0].copy(), line[knee].copy(), line[ankle].copy(), line[-1].copy()]


region = {}  # vertex index -> limb name ("L1".."R4", "arm")
legs = {}
for tip_at in feet_at:
    name = leg_name(tip_at)
    tip = nearest(tip_at)
    centres, cut, dist = trace(tip, after=0.8)
    if cut is None:
        cut = max(dist.values()) + 1.0  # A copied leg is its own piece: all of it is leg.
    joints = leg_joints(list(reversed(centres)))
    for i, d in dist.items():
        if d < cut:
            region[i] = name
    legs[name] = {"joints": joints, "tip": tip.co.copy()}
    log("leg", name, "hip", tuple(round(c, 3) for c in joints[0]), "knee", tuple(round(c, 3) for c in joints[1]),
        "ankle", tuple(round(c, 3) for c in joints[2]), "tip", tuple(round(c, 3) for c in joints[3]),
        "vertices", sum(1 for d in dist.values() if d < cut))
assert len(legs) == 8, "eight legs (%s)" % sorted(legs)
# Vertex order is not kept through what follows (writing the mesh renumbers it), so limbs are remembered by place.
region_at = [(bm.verts[i].co.copy(), name) for i, name in region.items()]

arm_tip = min((v for v in bm.verts if v.co.x > 0.0), key=lambda v: v.co.y)
arm_centres, arm_cut, arm_dist = trace(arm_tip, after=0.4)
assert arm_cut is not None
for i, d in arm_dist.items():
    if d < arm_cut:
        region[i] = "arm"
        region_at.append((bm.verts[i].co.copy(), "arm"))
# Rings across the fingers and palm all sit near the knuckles; the first ring on the forearm jumps back along the
# arm (about 0.13 units). That ring is the wrist.
arm_path = None
for n in range(len(arm_centres) - 1):
    if (arm_centres[n] - arm_tip.co).length > 0.1 and (arm_centres[n + 1] - arm_centres[n]).length > 0.06:
        arm_path = arm_centres[n + 1:]  # wrist ... shoulder
        break
assert arm_path is not None, "the wrist ring"
wrist = arm_path[0].copy()
shoulder = arm_path[-1].copy()
reach_dir = (arm_tip.co - wrist).normalized()
hand_verts = [bm.verts[i] for i, d in arm_dist.items() if d < arm_cut and (bm.verts[i].co - wrist).dot(reach_dir) > 0]
tips = []
for v in sorted(hand_verts, key=lambda v: -(v.co - wrist).dot(reach_dir)):
    if (v.co - wrist).dot(reach_dir) < 0.07:
        break
    if all((v.co - t).length > 0.035 for t in tips):
        tips.append(v.co.copy())
    if len(tips) == 5:
        break
log("arm wrist", tuple(round(c, 3) for c in wrist), "shoulder", tuple(round(c, 3) for c in shoulder),
    "fingertips", len(tips), "arm vertices", sum(1 for d in arm_dist.values() if d < arm_cut))

# The torso: centres of the body (not limbs) in height bands, front half only.
torso = [v.co for v in bm.verts if v.index not in region and abs(v.co.x) < 0.3 and v.co.y < 0.15 and v.co.z > 0.12]


def torso_at(z, half=0.025):
    pts = [p for p in torso if abs(p.z - z) < half]
    return sum(pts, Vector()) / len(pts)


top = max(p.z for p in torso)
waist, chest, neck, skull = torso_at(0.2), torso_at(0.42), torso_at(0.66), torso_at(0.74)
crown = Vector((skull.x, skull.y, top))
sac = [v.co for v in bm.verts if v.index not in region and v.co.y > 0.15 and v.co.z < 0.3]
centre = sum(sac, Vector()) / len(sac)
rear = max(p.y for p in sac)
log("torso waist", tuple(round(c, 3) for c in waist), "neck", tuple(round(c, 3) for c in neck), "crown %.3f" % top,
    "abdomen centre", tuple(round(c, 3) for c in centre), "rear %.3f" % rear)

# The headlamp: the most forward point of the helmet at the lamp's height, on the middle line.
lamp_src = min((v.co for v in bm.verts if abs(v.co.x + 0.01) < 0.03 and abs(v.co.z - 0.868) < 0.03),
               key=lambda p: p.y).copy()

# ---------------------------------------------------------------------------------------------------------------
# 5. Into metres about the abdomen: every vertex and every measured point.


def metres(p):
    return (p - centre) * SCALE


for v in bm.verts:
    v.co = metres(v.co)
for leg in legs.values():
    leg["joints"] = [metres(p) for p in leg["joints"]]
    leg["tip"] = metres(leg["tip"])
wrist, shoulder = metres(wrist), metres(shoulder)
arm_path = [metres(p) for p in arm_path]
tips = [metres(p) for p in tips]
waist, chest, neck, skull, crown = (metres(p) for p in (waist, chest, neck, skull, crown))
rear_point = Vector((0, (rear - centre.y) * SCALE * 0.8, 0))
lamp_at = metres(lamp_src) + Vector((0, -0.04, 0))

# The lamp glass: a small disc in front of the helmet's lamp, its own glowing material.
disc = bmesh.ops.create_circle(bm, cap_ends=True, segments=12, radius=0.11,
                               matrix=Matrix.Translation(lamp_at) @ Matrix.Rotation(math.radians(90), 4, "X"))
disc_faces = {f for v in disc["verts"] for f in v.link_faces}
bm.normal_update()
for f in disc_faces:
    f.material_index = 1
    if f.normal.y > 0:
        f.normal_flip()
refresh()
bm.normal_update()
mesh = body_obj.data
bm.to_mesh(mesh)
bm.free()
mesh.materials.append(bpy.data.materials.new("Lamp glass"))
glass = mesh.materials[1]
glass.use_nodes = True
pbr = glass.node_tree.nodes.get("Principled BSDF")
pbr.inputs["Base Color"].default_value = (1.0, 0.86, 0.6, 1)
pbr.inputs["Emission Color"].default_value = (1.0, 0.78, 0.45, 1)
pbr.inputs["Emission Strength"].default_value = 3.0
if mesh.has_custom_normals:
    bpy.context.view_layer.objects.active = body_obj
    bpy.ops.mesh.customdata_custom_splitnormals_clear()
for p in mesh.polygons:
    p.use_smooth = True
disc_vertex_ids = {v for p in mesh.polygons if p.material_index == 1 for v in p.vertices}
# The limbs, by place, onto the written mesh's numbering.
from mathutils.kdtree import KDTree
places = KDTree(len(region_at))
for k, (co, _) in enumerate(region_at):
    places.insert(metres(co), k)
places.balance()
region = {}
for v in mesh.vertices:
    co, k, d = places.find(v.co)
    if co is not None and d < 1e-4:
        region[v.index] = region_at[k][1]
log("limb vertices placed on the written mesh:", len(region), "of", len(region_at))
# The albedo goes to 1024 px for the web build.
for m in mesh.materials:
    if m.use_nodes:
        for node in m.node_tree.nodes:
            if node.type == "TEX_IMAGE" and node.image is not None and node.image.size[0] > 1024:
                node.image.scale(1024, 1024)
                # Godot 4.7 would not read the source's JPEG inside a .glb, so the albedo is written out as a PNG and
                # read back (the exporter keeps an image's own format).
                png = Path(bpy.app.tempdir) / "rigger_v2_albedo.png"
                node.image.filepath_raw = str(png)
                node.image.file_format = "PNG"
                node.image.save()
                node.image = bpy.data.images.load(str(png))
                node.image.pack()
                log("albedo", node.image.name, "scaled to 1024 px")

# ---------------------------------------------------------------------------------------------------------------
# 6. The skeleton.

arm_obj = bpy.data.objects.new("RiggerRig", bpy.data.armatures.new("RiggerRig"))
bpy.context.scene.collection.objects.link(arm_obj)
bpy.context.view_layer.objects.active = arm_obj
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_obj.data.edit_bones
ORDER = []


def bone(name, head, tail, parent=None, connect=False, deform=True):
    b = eb.new(name)
    b.head, b.tail = head, tail
    b.roll = 0.0
    if parent:
        b.parent = eb[parent]
        b.use_connect = connect
    b.use_deform = deform
    ORDER.append(name)
    return b


bone("root", Vector(), Vector((0, 0, 1.2)), deform=False)
bone("abdomen", Vector(), rear_point, "root")
bone("spine", waist, chest, "root")
bone("chest", chest, neck, "spine", True)
bone("neck", neck, skull, "chest", True)
bone("head", skull, crown, "neck", True)
LEGS = sorted(legs)
for name in LEGS:
    hip, knee, ankle, tip = legs[name]["joints"]
    inner = Vector((hip.x * 0.55, hip.y, hip.z))
    bone("leg_%s_coxa" % name, inner, hip, "root")
    bone("leg_%s_femur" % name, hip, knee, "leg_%s_coxa" % name, True)
    bone("leg_%s_tibia" % name, knee, ankle, "leg_%s_femur" % name, True)
    bone("leg_%s_tarsus" % name, ankle, tip, "leg_%s_tibia" % name, True)
# The arm: a shoulder from inside the chest, three upper and three lower bones spaced along the measured centreline
# (wrist to shoulder), the hand to the knuckles and one bone per finger.
inside = Vector((shoulder.x * 0.3, shoulder.y + 0.15, shoulder.z - 0.1))
bone("arm_shoulder", inside, shoulder, "chest")
path = list(reversed(arm_path))  # shoulder ... wrist
lengths = [0.0]
for a, b in zip(path, path[1:]):
    lengths.append(lengths[-1] + (b - a).length)


def along(f):
    target = f * lengths[-1]
    for i in range(len(path) - 1):
        if lengths[i + 1] >= target:
            u = (target - lengths[i]) / max(1e-9, lengths[i + 1] - lengths[i])
            return path[i].lerp(path[i + 1], u)
    return path[-1].copy()


ARM = ["arm_upper_1", "arm_upper_2", "arm_upper_3", "arm_fore_1", "arm_fore_2", "arm_fore_3"]
previous = "arm_shoulder"
for k, name in enumerate(ARM):
    head = shoulder if k == 0 else along(k / 6)
    bone(name, head, wrist if k == 5 else along((k + 1) / 6), previous, True)
    previous = name
knuckles = [wrist.lerp(t, 0.45) for t in tips]
palm = sum(knuckles, Vector()) / len(knuckles)
bone("hand", wrist, palm, "arm_fore_3", True)
FINGERS = []
for n, (k, t) in enumerate(sorted(zip(knuckles, tips), key=lambda kt: kt[1].x)):
    FINGERS.append("finger_%d" % (n + 1))
    bone(FINGERS[-1], k, t, "hand")
bpy.ops.object.mode_set(mode="OBJECT")
bones = arm_obj.data.bones
REST = {b.name: b.matrix_local.copy() for b in bones}
PARENT = {b.name: (b.parent.name if b.parent else None) for b in bones}
LENGTH = {b.name: b.length for b in bones}
log("skeleton", len(bones), "bones:", ", ".join(ORDER))

lamp = bpy.data.objects.new("Lamp", None)
bpy.context.scene.collection.objects.link(lamp)
lamp.parent = arm_obj
lamp.parent_type = "BONE"
lamp.parent_bone = "head"
lamp.matrix_parent_inverse = Matrix.Identity(4)
# A bone child sits relative to its bone's tail, in the bone's axes.
head_tail = REST["head"] @ Matrix.Translation((0, LENGTH["head"], 0))
lamp.location = head_tail.inverted() @ (lamp_at + Vector((0, -0.06, 0)))
lamp.empty_display_size = 0.2

# ---------------------------------------------------------------------------------------------------------------
# 7. Skinning. The torso, abdomen and head take Blender's automatic weights, cleaned so that each vertex only uses
# bones of its part. The heat solve gave many lower-leg vertices to the abdomen (they stayed behind as sheets when
# the legs moved), so every leg and the arm are weighted by distance to their own chain instead (two nearest bones,
# blended at the joints; a leg gives way to the abdomen within 0.45 m of its hip).

body_obj.parent = None
bpy.ops.object.select_all(action="DESELECT")
body_obj.select_set(True)
arm_obj.select_set(True)
bpy.context.view_layer.objects.active = arm_obj
bpy.ops.object.parent_set(type="ARMATURE_AUTO")
groups = {g.index: g.name for g in body_obj.vertex_groups}
for name in ORDER:
    if name not in body_obj.vertex_groups and bones[name].use_deform:
        body_obj.vertex_groups.new(name=name)
groups = {g.index: g.name for g in body_obj.vertex_groups}
index_of = {g.name: g.index for g in body_obj.vertex_groups}
DEFORM = [n for n in ORDER if bones[n].use_deform]


def chain(leg):
    return ["leg_%s_%s" % (leg, part) for part in ("coxa", "femur", "tibia", "tarsus")]


ARM_SET = set(["arm_shoulder"] + ARM + ["hand"] + FINGERS)
# The body takes no leg bone: where a leg meets the body, the leg's own vertices give way to the abdomen instead, so no
# vertex anywhere is moved by two legs.
BODY_SET = {"abdomen", "spine", "chest", "neck", "head", "arm_shoulder"}
head_line = skull.z + 0.15
HIP_AT = {n: REST[chain(n)[1]].translation.copy() for n in LEGS}


def allowed(i, co):
    limb = region.get(i)
    if i in disc_vertex_ids:
        return {"head"}
    if limb == "arm":
        return ARM_SET
    if limb:
        return set(chain(limb)) | {"abdomen"}
    if co.z > head_line:
        return {"head"}
    return BODY_SET


def segment_distance(p, name):
    m = REST[name]
    a = m.translation
    b = m @ Vector((0, LENGTH[name], 0))
    ab = b - a
    u = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return (p - (a + ab * u)).length


def chain_weights(p, names, hip=None):
    """A limb's own weights: the two nearest bones of its chain by distance to their segments, blended near each
    joint; a leg also gives way to the abdomen within 0.45 m of its hip."""
    near = sorted(names, key=lambda n: segment_distance(p, n))[:2]
    w = {n: 1.0 / (segment_distance(p, n) + 0.02) ** 4 for n in near}
    total = sum(w.values())
    w = {n: x / total for n, x in w.items()}
    if hip is not None:
        h = (p - hip).length
        if h < 0.45:
            share = 0.8 * (1 - h / 0.45) ** 2
            w = {n: x * (1 - share) for n, x in w.items()}
            w["abdomen"] = share
    return w


fallback = 0
limb_weighted = 0
for v in mesh.vertices:
    keep = allowed(v.index, v.co)
    limb = region.get(v.index)
    w = None
    if limb == "arm":
        w = chain_weights(v.co, sorted(ARM_SET))
    elif limb:
        w = chain_weights(v.co, chain(limb), HIP_AT[limb])
    if w is not None:
        limb_weighted += 1
    else:
        w = {groups[g.group]: g.weight for g in v.groups if groups[g.group] in keep and g.weight > 1e-4}
    if not w:
        fallback += 1
        near = sorted(keep - {"arm_shoulder"} or keep, key=lambda n: segment_distance(v.co, n))[:2]
        d = [max(1e-3, segment_distance(v.co, n)) for n in near]
        w = {n: 1.0 / (x ** 4) for n, x in zip(near, d)}
    best = sorted(w.items(), key=lambda kv: -kv[1])[:4]
    total = sum(x for _, x in best)
    for g in list(v.groups):
        body_obj.vertex_groups[g.group].remove([v.index])
    for n, x in best:
        body_obj.vertex_groups[index_of[n]].add([v.index], x / total, "REPLACE")
log("weights: body automatic then cleaned (%d with no allowed weight took the nearest bones); %d limb vertices "
    "weighted to their own chain by distance" % (fallback, limb_weighted))

# The per-bone check: no vertex of one leg carries weight from another leg, the arm only from its chain.
groups = {g.index: g.name for g in body_obj.vertex_groups}
crossed, arm_out, unweighted, overfull = 0, 0, 0, 0
for v in mesh.vertices:
    names = [groups[g.group] for g in v.groups if g.weight > 0]
    total = sum(g.weight for g in v.groups)
    if abs(total - 1.0) > 1e-3:
        unweighted += 1
    if len(names) > 4:
        overfull += 1
    limb = region.get(v.index)
    legs_here = {n.split("_")[1] for n in names if n.startswith("leg_")}
    if len(legs_here) > 1 or (limb and limb != "arm" and legs_here - {limb}):
        crossed += 1
    if limb == "arm":
        arm_out += sum(1 for n in names if n not in ARM_SET)
# Every vertex well below the body (more than 1.5 m under the abdomen's centre) must be moved by a leg bone.
low_off_leg = sum(1 for v in mesh.vertices if v.co.z < -1.5 and not groups[max(v.groups, key=lambda g: g.weight).group]
                  .startswith("leg_"))
per_leg = {n: sum(1 for i, l in region.items() if l == n) for n in LEGS}
log("weight check: vertices weighted to two legs (or a leg vertex to another leg) %d; arm vertices weighted outside "
    "the arm %d; vertices not summing to 1 %d; vertices over 4 bones %d; low vertices not led by a leg bone %d; leg "
    "vertices %s; arm vertices %d" % (crossed, arm_out, unweighted, overfull, low_off_leg, per_leg,
                                      sum(1 for l in region.values() if l == "arm")))
assert crossed == 0 and arm_out == 0 and unweighted == 0 and overfull == 0

# ---------------------------------------------------------------------------------------------------------------
# 8. Posing: every clip is computed here frame by frame (2-bone leg IK, arm FK with a lag along the chain) and
# keyed straight onto the bones; nothing is left to constraints.


def ease(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def axis_rot(name, axis, angle):
    """A local rotation that turns bone `name` by `angle` about an armature-space axis (in its rest frame)."""
    local = REST[name].to_3x3().inverted() @ axis
    return Quaternion(local.normalized(), angle)


class Pose:
    def __init__(self):
        self.rot = {n: Quaternion() for n in ORDER}
        self.loc = {n: Vector() for n in ORDER}
        self.scale = {n: Vector((1, 1, 1)) for n in ORDER}
        self.M = {}

    def basis(self, n):
        return Matrix.Translation(self.loc[n]) @ self.rot[n].to_matrix().to_4x4() @ Matrix.Diagonal(
            self.scale[n].to_4d())

    def base(self, n):
        p = PARENT[n]
        if p is None:
            return REST[n].copy()
        return self.M[p] @ (REST[p].inverted() @ REST[n])

    def solve(self, n):
        self.M[n] = self.base(n) @ self.basis(n)
        return self.M[n]

    def aim(self, n, direction):
        base = self.base(n)
        local = base.to_3x3().normalized().inverted() @ direction
        self.rot[n] = Vector((0, 1, 0)).rotation_difference(local.normalized())
        return self.solve(n)

    def head(self, n):
        return self.M[n].translation.copy()

    def tail(self, n):
        return self.M[n] @ Vector((0, LENGTH[n], 0))


def leg_ik(pose, leg, tip, tarsus_dir, wobble=0.0):
    names = chain(leg)
    pose.solve(names[0])
    hip = pose.tail(names[0])
    ankle = tip - tarsus_dir.normalized() * LENGTH[names[3]]
    a, b = LENGTH[names[1]], LENGTH[names[2]]
    reach = ankle - hip
    d = max(abs(a - b) + 1e-3, min(a + b - 1e-3, reach.length))
    axis = reach.normalized()
    rest_hip, rest_knee = REST[names[1]].translation, REST[names[2]].translation
    pole = (rest_knee - rest_hip) + UP * 0.6
    pole = Quaternion(axis, wobble) @ pole
    bend = (pole - axis * pole.dot(axis)).normalized()
    along_ = (a * a - b * b + d * d) / (2 * d)
    knee = hip + axis * along_ + bend * math.sqrt(max(1e-6, a * a - along_ * along_))
    pose.aim(names[1], knee - hip)
    pose.aim(names[2], ankle - knee)
    pose.aim(names[3], tarsus_dir)


SIDE_ORDER = {n: (n[0], int(n[1])) for n in LEGS}
SET_A = {"L1", "R2", "L3", "R4"}
LEG_LEN = {n: sum(LENGTH[b] for b in chain(n)[1:]) for n in LEGS}
MEAN_LEN = sum(LEG_LEN.values()) / len(LEG_LEN)
HIP = {n: REST[chain(n)[1]].translation.copy() for n in LEGS}
mid_y = sum(h.y for h in HIP.values()) / len(HIP)


def outward(n):
    tip = legs[n]["tip"]
    o = Vector((tip.x, tip.y - mid_y, 0))
    return o.normalized()


def grip(n):
    """Where a leg holds when he hangs or climbs: splayed out and down, longer legs farther (the concept's spread)."""
    L = LEG_LEN[n]
    return HIP[n] + outward(n) * L * 0.6 + UP * (-0.42 * L)


def leg_phase(n, t, period):
    lag = 0.07 * (int(n[1]) - 1)
    offset = (0.0 if n in SET_A else 0.5) + lag
    return (t / period + offset) % 1.0


def climb_legs(pose, t, period, stroke=1.4, swing=0.28):
    """Reach (the swing, 28 % of the cycle), plant, pull: the foot slides down relative to the body as he rises.
    The two sets of four are half a cycle apart, so at least four legs hold at every moment."""
    for n in LEGS:
        k = LEG_LEN[n] / MEAN_LEN
        s = stroke * k
        g = grip(n)
        o = outward(n)
        ph = leg_phase(n, t, period)
        if ph < swing:
            u = ease(ph / swing)
            lift = math.sin(math.pi * ph / swing)
            tip = g + UP * (-s / 2 + s * u) + o * (0.45 * k * lift)
            curl = 1.0 - lift
        else:
            u = (ph - swing) / (1 - swing)
            tip = g + UP * (s / 2 - s * u)
            curl = 1.0
        tarsus = (-UP * curl + o * (0.9 - 0.7 * curl) - o * 0.15 * curl).normalized()
        leg_ik(pose, n, tip, tarsus, wobble=0.05 * math.sin(2 * math.pi * (t / period) * 2 + int(n[1])))


def hold_legs(pose, t, length):
    """Hanging: every leg holds; one at a time lifts a little and re-takes its hold (two passes over the eight), and
    the long legs waver under his weight."""
    order = ["L1", "R3", "L2", "R4", "L3", "R1", "L4", "R2"]
    slot = length / (2 * len(order))
    for n in LEGS:
        k = LEG_LEN[n] / MEAN_LEN
        o = outward(n)
        tip = grip(n)
        lift = 0.0
        for rep in range(2):
            start = (order.index(n) + rep * len(order)) * slot
            u = (t - start) / (slot * 0.9)
            if 0 <= u <= 1:
                lift = math.sin(math.pi * u)
        tip = tip + UP * (0.35 * k * lift) + o * (0.25 * k * lift)
        tarsus = (-UP + o * (0.2 + 0.5 * lift)).normalized()
        waver = 0.07 * math.sin(2 * math.pi * t / length * 3 + 1.7 * int(n[1]) + (0.6 if n[0] == "L" else 0))
        leg_ik(pose, n, tip, tarsus, wobble=waver)


PITCH = Vector((1, 0, 0))  # positive turns the forward arm down
YAW = Vector((0, 0, 1))  # positive turns the forward arm to +X (his left, outward)
FOLD = {"arm_shoulder": (0.25, 0.1), "arm_upper_1": (0.35, 0.12), "arm_upper_2": (0.35, 0.08),
        "arm_upper_3": (0.3, 0.05), "arm_fore_1": (-0.85, 0.0), "arm_fore_2": (-0.85, 0.0),
        "arm_fore_3": (-0.8, 0.0), "hand": (0.7, 0.0)}
CHAIN = ["arm_shoulder"] + ARM + ["hand"]


def arm_fk(pose, angles, fingers_curl=0.0, fingers_spread=0.0):
    """angles: bone -> (pitch, yaw). Fingers curl about the pitch axis and fan about the yaw axis."""
    for n in CHAIN:
        pitch, yaw = angles.get(n, (0.0, 0.0))
        pose.rot[n] = axis_rot(n, YAW, yaw) @ axis_rot(n, PITCH, pitch)
    for i, n in enumerate(FINGERS):
        fan = (i - (len(FINGERS) - 1) / 2) * fingers_spread
        pose.rot[n] = axis_rot(n, YAW, fan) @ axis_rot(n, PITCH, fingers_curl)


def unfold(t, start, duration, reverse=False, lag_frames=2.5):
    """Per-bone fold amounts: the hand leads and each bone nearer the shoulder follows `lag_frames` later."""
    out = {}
    for i, n in enumerate(reversed(CHAIN)):
        u = ease((t - start - i * lag_frames / FPS) / duration)
        amount = u if reverse else 1 - u
        p, y = FOLD.get(n, (0, 0))
        out[n] = (p * amount, y * amount)
    return out


def body_still(pose):
    for n in ("root", "abdomen", "spine", "chest", "neck", "head"):
        pose.solve(n)


def breathe(pose, t, length, sway=0.1, bob=0.08):
    w = 2 * math.pi * t / length
    pose.loc["root"] = REST["root"].to_3x3().inverted() @ Vector((sway * math.sin(w), 0, bob * math.sin(2 * w)))
    pose.rot["root"] = axis_rot("root", Vector((0, 1, 0)), 0.03 * math.sin(w + 0.4))
    b = 0.035 * math.sin(2 * w)
    pose.scale["abdomen"] = Vector((1 + b, 1 + b * 0.5, 1 + b))
    pose.rot["chest"] = axis_rot("chest", PITCH, 0.03 * math.sin(2 * w + 0.5))
    pose.rot["head"] = axis_rot("head", YAW, 0.12 * math.sin(w + 1.1)) @ axis_rot("head", PITCH, 0.06 * math.sin(w))
    body_still(pose)


def rigger_climb(t):
    """The clip the Ward's view plays (it seeks 0 to 1.75 s, and holds 0.75 s while he searches). The body and the
    arm stay at rest so the wrist stays exactly at RIGGER_WRIST in client/ward/view.gd; the legs climb with a period
    of 0.875 s (two strides in 1.75 s, so the view's wrap is seamless); the rig's own hand is folded away to nothing,
    because the view draws the paying-out arm and the search hand (search-hand.glb) from the wrist on."""
    pose = Pose()
    pose.rot["abdomen"] = axis_rot("abdomen", Vector((0, 1, 0)), 0.05 * math.sin(2 * math.pi * t / 0.875))
    body_still(pose)
    arm_fk(pose, {})
    pose.scale["hand"] = Vector((0.04, 0.04, 0.04))
    climb_legs(pose, t, 0.875, stroke=1.6)
    return pose


def climb(t):
    pose = Pose()
    w = 2 * math.pi * t / 1.25
    pose.loc["root"] = REST["root"].to_3x3().inverted() @ Vector((0.06 * math.sin(w), 0, 0.12 * math.sin(2 * w)))
    pose.rot["spine"] = axis_rot("spine", PITCH, 0.12)
    pose.rot["head"] = axis_rot("head", PITCH, -0.1)
    body_still(pose)
    hold = {n: (p * 0.55, y * 0.6) for n, (p, y) in FOLD.items()}
    arm_fk(pose, hold, fingers_curl=0.6)
    climb_legs(pose, t, 1.25)
    return pose


def hang(t):
    pose = Pose()
    breathe(pose, t, 4.0)
    w = 2 * math.pi * t / 4.0
    rest = {n: (p * 0.25 + 0.03 * math.sin(w + i * 0.3), y * 0.3) for i, (n, (p, y)) in enumerate(FOLD.items())}
    rest["arm_upper_1"] = (0.22 + 0.04 * math.sin(w), 0.05)
    arm_fk(pose, rest, fingers_curl=0.45 + 0.1 * math.sin(2 * w))
    hold_legs(pose, t, 4.0)
    return pose


def reach(t):
    pose = Pose()
    pose.rot["spine"] = axis_rot("spine", PITCH, 0.1 * ease(t / 1.0))
    pose.rot["head"] = axis_rot("head", PITCH, 0.08 * ease(t / 1.0))
    body_still(pose)
    arm_fk(pose, unfold(t, 0.1, 0.9), fingers_curl=0.9 * (1 - ease((t - 0.6) / 0.7)) - 0.1,
           fingers_spread=0.16 * ease((t - 0.7) / 0.6))
    hold_legs(pose, 0.0, 4.0)
    return pose


def search(t):
    """The hand pats left and right: a sweep that travels down the arm (each bone 2.5 frames behind the next one
    out), two pats per side, fingers pressing as each pat lands. 2 s, a loop."""
    pose = Pose()
    pose.rot["spine"] = axis_rot("spine", PITCH, 0.1)
    pose.rot["head"] = axis_rot("head", YAW, 0.1 * math.sin(2 * math.pi * t / 2.0 - 0.5))
    body_still(pose)
    angles = {}
    for i, n in enumerate(reversed(CHAIN)):
        phase = 2 * math.pi * (t - i * 2.5 / FPS) / 2.0
        angles[n] = (0.02 * math.sin(2 * phase), 0.07 * math.sin(phase))
    pat = math.sin(2 * math.pi * t / 0.5)
    angles["hand"] = (0.35 * max(0.0, pat), 0.25 * math.sin(2 * math.pi * t / 2.0))
    arm_fk(pose, angles, fingers_curl=0.15 + 0.25 * max(0.0, -pat), fingers_spread=0.14)
    hold_legs(pose, 0.0, 4.0)
    return pose


def withdraw(t):
    pose = Pose()
    pose.rot["spine"] = axis_rot("spine", PITCH, 0.1 * (1 - ease(t / 1.0)))
    body_still(pose)
    arm_fk(pose, unfold(t, 0.0, 0.8, reverse=True, lag_frames=2.0), fingers_curl=0.9 * ease(t / 0.5))
    hold_legs(pose, 0.0, 4.0)
    return pose


CLIPS = [("Rigger Climb", 121 / FPS, rigger_climb, False), ("climb", 2.5, climb, True), ("hang", 4.0, hang, True),
         ("reach", 1.5, reach, False), ("search", 2.0, search, True), ("withdraw", 1.2, withdraw, False)]

bpy.context.scene.render.fps = FPS
bpy.context.scene.render.fps_base = 1.0
anim = arm_obj.animation_data_create()
seam = {}
for clip, length, make, loop in CLIPS:
    action = bpy.data.actions.new(clip)
    anim.action = action
    frames = int(round(length * FPS))
    keys = {}
    previous = {}
    for f in range(frames + 1):
        pose = make(f / FPS)
        for n in ORDER:
            q = pose.rot[n].normalized()
            if n in previous and q.dot(previous[n]) < 0:
                q.negate()
            previous[n] = q
            keys.setdefault(n, []).append((pose.loc[n].copy(), q, pose.scale[n].copy()))
    worst = 1.0
    for n, rows in keys.items():
        worst = min(worst, abs(rows[0][1].dot(rows[-1][1])))
        for path, part, size in (("location", 0, 3), ("rotation_quaternion", 1, 4), ("scale", 2, 3)):
            for k in range(size):
                curve = action.fcurve_ensure_for_datablock(arm_obj, 'pose.bones["%s"].%s' % (n, path), index=k,
                                                           group_name=n)
                curve.keyframe_points.add(len(rows))
                flat = []
                for f, row in enumerate(rows):
                    flat += [float(f), row[part][k]]
                curve.keyframe_points.foreach_set("co", flat)
                for point in curve.keyframe_points:
                    point.interpolation = "LINEAR"
                curve.update()
    if anim.action_slot is None and len(action.slots):
        anim.action_slot = action.slots[0]
    seam[clip] = worst
    if clip == "Rigger Climb":
        start, wrap = rigger_climb(0.0), rigger_climb(1.75)
        worst_wrap = min(abs(start.rot[n].normalized().dot(wrap.rot[n].normalized())) for n in ORDER)
        log("Rigger Climb at 0 s against 1.75 s (where the view wraps): pose match %.5f" % worst_wrap)
    track = anim.nla_tracks.new()
    track.name = clip
    strip = track.strips.new(clip, 0, action)
    if anim.action_slot is not None:
        strip.action_slot = anim.action_slot
    anim.action = None
    log("clip %s: %.2f s, %d frames, %s; first-to-last pose match %.5f" % (clip, length, frames + 1,
        "loop" if loop else "once", worst))
for p in arm_obj.pose.bones:
    p.rotation_mode = "QUATERNION"
    p.location, p.rotation_quaternion, p.scale = Vector(), Quaternion(), Vector((1, 1, 1))

wrist_rest = REST["hand"].translation
log("RIGGER_WRIST_V2 (Godot) = Vector3(%.3f, %.3f, %.3f)" % (wrist_rest.x, wrist_rest.z, -wrist_rest.y))
bpy.context.view_layer.update()
lamp_world = lamp.matrix_world.translation
log("Lamp (Godot) = (%.3f, %.3f, %.3f)" % (lamp_world.x, lamp_world.z, -lamp_world.y))

# ---------------------------------------------------------------------------------------------------------------
# 9. Export.

if EXPORT:
    bpy.ops.object.select_all(action="DESELECT")
    for o in (body_obj, arm_obj, lamp):
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj
    OUT.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(OUT), export_format="GLB", use_selection=True, export_yup=True,
                              export_animation_mode="NLA_TRACKS", export_cameras=False, export_lights=False,
                              export_image_format="AUTO", export_force_sampling=True)
    log("wrote", OUT, OUT.stat().st_size, "bytes")

# ---------------------------------------------------------------------------------------------------------------
# 10. Review renders: plain grey, workbench; the bones drawn as coloured spindles through a see-through body.

if RENDERS:
    out = Path(RENDERS)
    out.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "OBJECT"
    scene.render.resolution_x, scene.render.resolution_y = 1100, 1000
    scene.render.film_transparent = False
    scene.world = bpy.data.worlds.new("grey")
    scene.world.color = (0.32, 0.32, 0.33)
    body_obj.color = (0.62, 0.62, 0.62, 1)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.data.type = "ORTHO"
    cam.data.clip_end = 200
    centre_view = Vector((0, -1.0, 0.0))

    def shoot(name, direction, scale=12.5):
        cam.data.ortho_scale = scale
        cam.location = centre_view + direction.normalized() * 40
        cam.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = str(out / ("rigger-%s.png" % name))
        bpy.ops.render.render(write_still=True)
        log("render", scene.render.filepath)

    colours = {"leg": (0.95, 0.35, 0.2, 1), "arm": (0.2, 0.8, 1.0, 1), "body": (1.0, 0.9, 0.2, 1),
               "finger": (0.3, 1.0, 0.4, 1), "hand": (0.3, 1.0, 0.4, 1)}
    spindles = []
    for n in ORDER:
        b = bones[n]
        h, tl = b.head_local, b.tail_local
        length = (tl - h).length
        r = max(0.03, min(0.16, length * 0.09))
        me = bpy.data.meshes.new("bone " + n)
        axis = (tl - h).normalized()
        side = axis.cross(UP if abs(axis.z) < 0.9 else Vector((1, 0, 0))).normalized()
        up2 = axis.cross(side)
        mid = h + axis * length * 0.2
        verts = [h, tl] + [mid + (side * math.cos(a) + up2 * math.sin(a)) * r for a in
                           (0, math.pi / 2, math.pi, 1.5 * math.pi)]
        faces = [(0, 2, 3), (0, 3, 4), (0, 4, 5), (0, 5, 2), (1, 3, 2), (1, 4, 3), (1, 5, 4), (1, 2, 5)]
        me.from_pydata(verts, [], faces)
        o = bpy.data.objects.new("bone " + n, me)
        scene.collection.objects.link(o)
        key = next((k for k in colours if n.startswith(k)), "body")
        o.color = colours[key]
        spindles.append(o)
    scene.display.shading.show_xray = True
    scene.display.shading.xray_alpha = 0.35
    arm_obj.data.pose_position = "REST"
    shoot("rest-front", Vector((0, -1, 0)))
    shoot("rest-side", Vector((1, 0, 0)))
    shoot("rest-top", Vector((0, 0, 1)))
    arm_obj.data.pose_position = "POSE"
    for o in spindles:
        o.hide_render = True
    scene.display.shading.show_xray = False
    anim.use_nla = False
    for clip, at in (("climb", 0.3), ("hang", 1.0), ("reach", 1.5), ("search", 0.6), ("Rigger Climb", 0.75)):
        anim.action = bpy.data.actions[clip]
        if anim.action_slot is None:
            anim.action_slot = anim.action.slots[0]
        scene.frame_set(int(round(at * FPS)))
        bpy.context.view_layer.update()
        log("pose for render:", clip, anim.action.name, anim.action_slot.identifier if anim.action_slot else None,
            "wrist at", tuple(round(c, 2) for c in arm_obj.pose.bones["hand"].head))
        safe = clip.lower().replace(" ", "-")
        shoot("%s-front" % safe, Vector((0.8, -1, 0.35)))
        shoot("%s-side" % safe, Vector((1, 0, 0.1)))
    anim.action = None
    anim.use_nla = True
log("done")
