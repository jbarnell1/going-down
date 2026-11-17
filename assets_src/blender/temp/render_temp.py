"""Render the Temp for judging: import temp_tpose.glb with its stapler and notes, pose it on a throwaway
rig (automatic weights, never exported), and render it in an Annex corridor (yellowed cream walls,
mustard carpet, grey ceiling tiles, flat pale green-white panels, the pale haze) and on a plain backdrop.

Usage:
  blender.exe --background --factory-startup --python-exit-code 1 --python render_temp.py -- [--dir DIR]
        [--out DIR] [--only turn,annex,face,far,dim,bend]

Writes to assets_src/renders/temp/:
  turn_front/34/side/back.png  posed, plain grey backdrop
  annex_34.png                 full figure, front three-quarter, in the corridor
  annex_face.png               close on the face sheet
  annex_10m.png, annex_10m_lowres.png   from 10 m down the corridor at eye height (the game's 70 degree
                               view; the second at the game's 480 x 270)
  annex_dim.png                the blackout: green emergency light only
  bend_hands.png               the rig check: fingers curled on both hands (proves the finger loops)
The rig is only there to pose the pictures; Mixamo rigs the real thing.
"""
import bpy, sys, os, math, time, argparse
import numpy as np
from mathutils import Vector, Matrix, Quaternion

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import build_temp as BT  # noqa: E402  (the figure's own numbers: joints come from the same tables)

SRGB = lambda c: tuple(v ** 2.2 for v in c)
# The Annex (client/annex_view.gd), sRGB
COL = dict(wall=(0.88, 0.80, 0.50), skirt=(0.46, 0.40, 0.30), carpet=(0.64, 0.48, 0.14),
           ceil=(0.72, 0.72, 0.68), grout=(0.55, 0.55, 0.52), panel=(0.92, 1.0, 0.90), light=(0.90, 1.0, 0.86),
           haze=(0.64, 0.58, 0.36), door=(0.62, 0.60, 0.53), frame=(0.47, 0.44, 0.39), green=(0.35, 1.0, 0.45))
R = dict(cell=2.0, ceil=3.2, door_w=1.1, door_h=2.1, eye=1.62, vfov=70.0, haze=0.016, samples=24,
         panel_w=40.0, ambient=0.75)


# ============================ RIG ============================
def joints():
    """joint positions (Blender space, left side; the right is mirrored) from build_temp's tables"""
    J = dict(hips=(0, 0.0, 0.93), spine=(0, 0.0, 1.08), chest=(0, 0.0, 1.28), neck=(0, 0.0, 1.47),
             head=(0, 0.0, BT.hz(1.588)), head_end=(0, 0.0, BT.hz(BT.HEAD_TOP_Z)),
             clav=(0.03, 0.0, 1.43), shoulder=(0.168, 0.0, 1.383), elbow=(BT.ARM[BT.ELBOW - 2][0] + 0.012, 0.004, 1.380),
             wrist=(BT.ARM[-1][0], 0.0, 1.380), hand_end=(BT.PALM[-1][0], 0.0, BT.HAND_Z),
             thigh=(0.097, 0.0, 0.86), knee=(0.100, -0.008, 0.49), ankle=(0.104, 0.012, 0.085),
             toe=(0.104, -0.15, 0.02))
    return J


def build_rig():
    J = joints()
    arm_d = bpy.data.armatures.new("rig")
    rig = bpy.data.objects.new("rig", arm_d)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm_d.edit_bones

    def bone(name, h, t, parent=None, roll_up=(0, 0, 1)):
        b = eb.new(name)
        b.head, b.tail = Vector(h), Vector(t)
        b.align_roll(Vector(roll_up))
        if parent:
            b.parent = eb[parent]
            b.use_connect = False
        return b
    bone("hips", J["hips"], J["spine"])
    bone("spine", J["spine"], J["chest"], "hips")
    bone("chest", J["chest"], J["neck"], "spine")
    bone("neck", J["neck"], J["head"], "chest")
    bone("head", J["head"], J["head_end"], "neck")
    widths = [f[1] for f in BT.FINGERS]
    total = sum(widths) + BT.FGAP * 3
    edges, y = [], -total / 2
    for w in widths:
        edges += [y, y + w]
        y += w + BT.FGAP
    for side, sfx in ((1, ".L"), (-1, ".R")):
        S = (lambda p: Vector(p)) if side > 0 else (lambda p: Vector(BT.mx(p)))
        bone("clav" + sfx, S(J["clav"]), S(J["shoulder"]), "chest", (0, -1, 0))
        bone("upper" + sfx, S(J["shoulder"]), S(J["elbow"]), "clav" + sfx, (0, 0, 1))
        bone("fore" + sfx, S(J["elbow"]), S(J["wrist"]), "upper" + sfx, (0, 0, 1))
        bone("hand" + sfx, S(J["wrist"]), S(J["hand_end"]), "fore" + sfx, (0, 0, 1))
        for fi, (name, w, length, fan, koff) in enumerate(BT.FINGERS):
            a = math.radians(fan)
            d = Vector((math.cos(a), math.sin(a), 0))
            c0 = Vector((BT.PALM[-1][0] + koff, (edges[2 * fi] + edges[2 * fi + 1]) / 2, BT.HAND_Z))
            mid = c0 + d * 0.47 * length
            bone(f"{name}1{sfx}", S(c0), S(mid), "hand" + sfx)
            bone(f"{name}2{sfx}", S(mid), S(c0 + d * length), f"{name}1{sfx}")
        d = Vector(BT.THUMB_DIR).normalized()
        c0 = Vector(((BT.PALM[0][0] + BT.PALM[1][0]) / 2, edges[0] * 0.86, BT.HAND_Z)) - d * 0.012
        bone("thumb1" + sfx, S(c0), S(c0 + d * 0.050), "hand" + sfx)
        bone("thumb2" + sfx, S(c0 + d * 0.050), S(c0 + d * 0.090), "thumb1" + sfx)
        bone("thigh" + sfx, S(J["thigh"]), S(J["knee"]), "hips", (0, -1, 0))
        bone("shin" + sfx, S(J["knee"]), S(J["ankle"]), "thigh" + sfx, (0, -1, 0))
        bone("foot" + sfx, S(J["ankle"]), S(J["toe"]), "shin" + sfx, (0, 0, 1))
    bpy.ops.object.mode_set(mode="OBJECT")
    return rig


def separate(ob):
    """split the figure into its loose parts; the biggest is the body"""
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.separate(type="LOOSE")
    bpy.ops.object.mode_set(mode="OBJECT")
    parts = [o for o in bpy.context.selected_objects if o.type == "MESH"]
    parts.sort(key=lambda o: len(o.data.vertices), reverse=True)
    print(f"[render] loose parts: body {len(parts[0].data.vertices)} vertices, {len(parts) - 1} shells")
    return parts[0], parts[1:]


def skin(rig, body, shells):
    # Bone heat fails on a figure this small (fingers 1.6 cm across): bind it ten times bigger, then
    # shrink the rig (and the body with it) back to size.
    for o in (rig, body):
        o.scale = (10, 10, 10)
    bpy.ops.object.select_all(action="DESELECT")
    rig.select_set(True)
    body.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    rig.scale = (0.1, 0.1, 0.1)
    bpy.context.view_layer.update()
    bones = [b.name for b in rig.data.bones]
    used = {e.group for v in body.data.vertices for e in v.groups if e.weight > 0.05}
    empty = [g.name for g in body.vertex_groups if g.index not in used]
    print("[render] automatic weights:", len(body.vertex_groups), "groups for", len(bones), "bones; empty:", empty)
    from mathutils.kdtree import KDTree
    bv = body.data.vertices
    kd = KDTree(len(bv))
    for i, v in enumerate(bv):
        kd.insert(body.matrix_world @ v.co, i)
    kd.balance()
    gname = {g.index: g.name for g in body.vertex_groups}
    for sh in shells:
        sh.parent = rig
        sh.matrix_parent_inverse = rig.matrix_world.inverted()
        mod = sh.modifiers.new("rig", "ARMATURE")
        mod.object = rig
        ctr = sum((v.co for v in sh.data.vertices), Vector()) / len(sh.data.vertices)
        rigid_head = ctr.z > 1.55        # the sheet and its staples move with the head only
        groups = {}
        for v in sh.data.vertices:
            if rigid_head:
                w = {"head": 1.0}
            else:
                _, i, _ = kd.find(sh.matrix_world @ v.co)
                w = {gname[e.group]: e.weight for e in bv[i].groups}
            for name, wt in w.items():
                if name not in groups:
                    groups[name] = sh.vertex_groups.get(name) or sh.vertex_groups.new(name=name)
                groups[name].add([v.index], wt, "REPLACE")


def pose_reset(rig):
    for pb in rig.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()


def rot_rest(rig, name, axis, deg):
    """rotate a bone about an axis given in rest (T-pose) space, as a local rotation that its parents carry"""
    pb = rig.pose.bones[name]
    ml = rig.data.bones[name].matrix_local.to_3x3()
    q = Quaternion(Vector(axis).normalized(), math.radians(deg)).to_matrix()
    pb.matrix_basis = (ml.inverted() @ q @ ml).to_4x4() @ pb.matrix_basis
    bpy.context.view_layer.update()


def aim(rig, name, world_dir):
    """turn a posed bone about its head so it points along world_dir (the smallest turn)"""
    pb = rig.pose.bones[name]
    mw = rig.matrix_world
    head = mw @ pb.head
    cur = (mw @ pb.tail - head).normalized()
    q = cur.rotation_difference(Vector(world_dir).normalized())
    M = Matrix.Translation(head) @ q.to_matrix().to_4x4() @ Matrix.Translation(-head)
    pb.matrix = mw.inverted() @ M @ mw @ pb.matrix
    bpy.context.view_layer.update()


def twist(rig, name, deg):
    """roll a posed bone about its own length"""
    pb = rig.pose.bones[name]
    mw = rig.matrix_world
    head = mw @ pb.head
    ax = (mw @ pb.tail - head).normalized()
    M = Matrix.Translation(head) @ Quaternion(ax, math.radians(deg)).to_matrix().to_4x4() @ Matrix.Translation(-head)
    pb.matrix = mw.inverted() @ M @ mw @ pb.matrix
    bpy.context.view_layer.update()


def curl(rig, sfx, fingers_deg, thumb_deg):
    """curl the fingers toward the palm (palm down in the rest pose), in rest space"""
    side = 1 if sfx == ".L" else -1
    for name, w, length, fan, koff in BT.FINGERS:
        a = math.radians(fan)
        d = Vector((side * math.cos(a), math.sin(a), 0))
        axis = d.cross(Vector((0, 0, -1)))
        for k, deg in zip((1, 2), fingers_deg):
            rot_rest(rig, f"{name}{k}{sfx}", axis, deg)
    d = Vector(BT.THUMB_DIR).normalized()
    d = Vector((side * d.x, d.y, d.z))
    toward = Vector((side * 1.0, 0.2, -0.6)).normalized()     # across the palm, under it
    axis = d.cross(toward)
    for k, deg in zip((1, 2), thumb_deg):
        rot_rest(rig, f"thumb{k}{sfx}", axis, deg)


def palm_frame(rig, sfx):
    """the posed hand: wrist, along the fingers, palm normal (world)"""
    pb = rig.pose.bones["hand" + sfx]
    mw = rig.matrix_world
    rest = rig.data.bones["hand" + sfx].matrix_local
    M = (mw @ pb.matrix @ rest.inverted()).to_3x3()
    head = mw @ pb.head
    along = (mw @ pb.tail - head).normalized()
    normal = (M @ Vector((0, 0, -1))).normalized()
    return head, along, normal


def pose_standing(rig):
    """A stand-in for the Mixamo idle: standing still, the too-long arms hanging straight down, the head
    hung over to its right, knees soft; the stapler gripped in the right hand, the pad of notes pinched in
    the left."""
    pose_reset(rig)
    rot_rest(rig, "chest", (1, 0, 0), 5)
    rot_rest(rig, "neck", (1, 0, 0), 8)
    rot_rest(rig, "head", (0, 1, 0), -15)
    rot_rest(rig, "head", (1, 0, 0), 6)
    curl(rig, ".R", (80, 75), (25, 30))
    curl(rig, ".L", (35, 30), (20, 20))
    rot_rest(rig, "clav.R", (0, 1, 0), 5)        # the right shoulder hitched up
    rot_rest(rig, "clav.L", (0, 1, 0), 3)        # the left one dropped
    aim(rig, "upper.L", (0.12, 0.03, -1))
    aim(rig, "fore.L", (0.05, -0.03, -1))
    aim(rig, "hand.L", (0.02, -0.04, -1))
    aim(rig, "upper.R", (-0.12, 0.02, -1))
    aim(rig, "fore.R", (-0.05, -0.05, -1))
    aim(rig, "hand.R", (-0.02, -0.06, -1))
    for s, sx in ((".L", 1), (".R", -1)):         # knees not locked: a little forward, the shins back
        aim(rig, "thigh" + s, (sx * 0.02, -0.10, -1))
        aim(rig, "shin" + s, (sx * 0.01, 0.06, -1))
        aim(rig, "foot" + s, (sx * 0.08, -1, -0.12))


def hold(rig, ob, sfx, offset, local_fn):
    """place a prop in the posed hand and parent it to the hand bone: offset (along the fingers, along the
    palm normal, across), and the prop's rotation from the hand's frame"""
    head, along, normal = palm_frame(rig, sfx)
    across = along.cross(normal).normalized()
    p = head + along * offset[0] + normal * offset[1] + across * offset[2]
    rot = local_fn(along, normal, across)
    ob.parent = rig
    ob.parent_type = "BONE"
    ob.parent_bone = "hand" + sfx
    bpy.context.view_layer.update()
    ob.matrix_world = Matrix.Translation(p) @ rot.to_4x4()
    bpy.context.view_layer.update()


def stapler_frame(along, normal, across):
    """carried in the hanging fist: nose (-Y) forward across the palm, top (+Z) toward the wrist"""
    fwd = across if across.y <= 0 else -across
    y, z = -fwd, -along
    return frame3(y.cross(z), y, z)


def notes_frame(along, normal, across):
    """pinched by its sticky edge (+Y, toward the wrist), the written face (+Z) turned forward"""
    fwd = across if across.y <= 0 else -across
    y, z = -along, fwd
    return frame3(y.cross(z), y, z)


def ground(rig, body):
    """stand the posed figure on the floor"""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = body.evaluated_get(dg)
    me = ev.to_mesh()
    low = min((ev.matrix_world @ v.co).z for v in me.vertices)
    ev.to_mesh_clear()
    rig.location.z -= low
    bpy.context.view_layer.update()


def contact_shadow(coll, rig):
    """a soft dark pool on the floor under the feet, as overhead panels would leave"""
    m = bpy.data.materials.new("contact")
    m.use_nodes = True
    nt = m.node_tree
    for n_ in list(nt.nodes):
        nt.nodes.remove(n_)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    mix = nt.nodes.new("ShaderNodeMixShader")
    tr = nt.nodes.new("ShaderNodeBsdfTransparent")
    dk = nt.nodes.new("ShaderNodeBsdfDiffuse")
    dk.inputs["Color"].default_value = (0.0, 0.0, 0.0, 1)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    grad = nt.nodes.new("ShaderNodeTexGradient")
    grad.gradient_type = "SPHERICAL"
    mapn = nt.nodes.new("ShaderNodeMapping")
    mapn.inputs["Scale"].default_value = (1.0, 1.0, 1.0)
    ramp = nt.nodes.new("ShaderNodeMath")
    ramp.operation = "POWER"
    ramp.inputs[1].default_value = 1.6
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    mul.inputs[1].default_value = 0.75
    nt.links.new(tc.outputs["Object"], mapn.inputs["Vector"])
    nt.links.new(mapn.outputs["Vector"], grad.inputs["Vector"])
    nt.links.new(grad.outputs["Fac"], ramp.inputs[0])
    nt.links.new(ramp.outputs[0], mul.inputs[0])
    nt.links.new(mul.outputs[0], mix.inputs["Fac"])
    nt.links.new(tr.outputs[0], mix.inputs[1])
    nt.links.new(dk.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs["Surface"])
    if hasattr(m, "surface_render_method"):
        m.surface_render_method = "BLENDED"
    me = bpy.data.meshes.new("contact")
    me.from_pydata([(-1, -1, 0), (1, -1, 0), (1, 1, 0), (-1, 1, 0)], [], [[0, 1, 2, 3]])
    me.materials.append(m)
    ob = bpy.data.objects.new("contact", me)
    ob.scale = (0.30, 0.26, 1.0)
    coll.objects.link(ob)
    follow_shadow(ob, rig)
    return ob


def follow_shadow(ob, rig):
    ob.location = (rig.location.x, rig.location.y - 0.03, 0.002)


def frame3(x, y, z):
    M = Matrix.Identity(3)
    for i, v in enumerate((x, y, z)):
        M.col[i] = v.normalized()
    return M


# ============================ SCENE ============================
SELF_LIT = []     # (material, strength): the room's own baked-in light, off in the blackout


def mat(name, color, image=None, emit=0.0, rough=0.85, emit_color=None, self_light=0.0):
    """self_light: light the surface gives off itself, as the Annex's surfaces do in the game (its light is
    flat and even, mostly baked in); without it the ceiling, lit only from below, renders black"""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*SRGB(color), 1)
    b.inputs["Roughness"].default_value = rough
    if "Specular IOR Level" in b.inputs:
        b.inputs["Specular IOR Level"].default_value = 0.2
    if image is not None:
        tx = nt.nodes.new("ShaderNodeTexImage")
        tx.image = image
        tx.interpolation = "Closest"
        nt.links.new(tx.outputs["Color"], b.inputs["Base Color"])
        if self_light:
            nt.links.new(tx.outputs["Color"], b.inputs["Emission Color"])
    elif self_light:
        b.inputs["Emission Color"].default_value = (*SRGB(color), 1)
    if self_light:
        b.inputs["Emission Strength"].default_value = self_light
        SELF_LIT.append((m, self_light))
    if emit:
        b.inputs["Emission Color"].default_value = (*SRGB(emit_color or color), 1)
        b.inputs["Emission Strength"].default_value = emit
    return m


def image(name, arr):
    """arr rows top-down, sRGB 0..1"""
    h, w = arr.shape[:2]
    im = bpy.data.images.new(name, w, h)
    px = np.ones((h, w, 4), np.float32)
    px[..., :3] = arr[::-1]
    im.pixels.foreach_set(px.ravel())
    im.pack()
    return im


def carpet_img():
    rng = np.random.default_rng(3101)
    base = np.array(COL["carpet"])
    v = rng.uniform(-0.045, 0.045, (64, 64))
    yy, xx = np.mgrid[0:64, 0:64]
    v = v - 0.025 * (((xx + yy * 2) % 4) == 0)
    c = base[None, None, :] + v[..., None] * np.array([1, 0.85, 0.4])
    c = np.where((rng.random((64, 64)) < 0.03)[..., None], base * 0.78, c)
    return np.clip(c, 0, 1)


def wall_img():
    rng = np.random.default_rng(3102)
    base = np.array(COL["wall"])
    c = base[None, None, :] * (1 + rng.uniform(-0.018, 0.018, (128, 64, 1)))
    c[:, ::16] *= 0.95
    y = np.arange(128)[:, None, None]
    c = np.where(y >= 100, c * (1 - (y - 100) * 0.0025), c)
    c[122] = (0.36, 0.32, 0.24)
    c[123:] = COL["skirt"]
    return np.clip(c, 0, 1)


def ceil_img():
    rng = np.random.default_rng(3103)
    base = np.array(COL["ceil"])
    c = base[None, None, :] * (1 + rng.uniform(-0.02, 0.02, (64, 64, 1)))
    c = np.where((rng.random((64, 64)) < 0.06)[..., None], c * 0.88, c)
    c[::21, :] = COL["grout"]
    c[:, ::21] = COL["grout"]
    return np.clip(c, 0, 1)


def quad(name, pts, material, coll, uvs=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(p) for p in pts], [], [[0, 1, 2, 3]])
    uvl = me.uv_layers.new()
    for li, uv in enumerate(uvs or [(0, 0), (1, 0), (1, 1), (0, 1)]):
        uvl.data[li].uv = uv
    me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def box(name, x0, x1, y0, y1, z0, z1, material, coll):
    me = bpy.data.meshes.new(name)
    v = [(x, y, z) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
    f = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
    me.from_pydata(v, [], f)
    me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def build_annex():
    """A corridor along Y (the figure stands at the origin facing -Y), doors on both sides, a side
    corridor crossing at y = 4, panels in the ceiling every 2 m."""
    coll = bpy.data.collections.new("annex")
    bpy.context.scene.collection.children.link(coll)
    W, H, Y0, Y1 = R["cell"] / 2 - 0.07, R["ceil"], -36.0, 12.0
    carpet = mat("carpet", (1, 1, 1), image("carpet", carpet_img()), rough=1.0, self_light=0.10)
    wall = mat("wall", (1, 1, 1), image("wallpaper", wall_img()), rough=0.9, self_light=0.12)
    ceil = mat("ceiling", (1, 1, 1), image("ceiling", ceil_img()), rough=1.0, self_light=0.45)
    panel = mat("panel", COL["panel"], emit=6.0)
    door = mat("door", COL["door"], rough=0.8, self_light=0.10)
    frame = mat("frame", COL["frame"], rough=0.7, self_light=0.10)
    quad("carpet", [(-W - 3, Y0, 0), (W + 3, Y0, 0), (W + 3, Y1, 0), (-W - 3, Y1, 0)], carpet, coll,
         [(0, Y0), (2 * W + 6, Y0), (2 * W + 6, Y1), (0, Y1)])
    quad("ceiling", [(-W - 3, Y0, H), (-W - 3, Y1, H), (W + 3, Y1, H), (W + 3, Y0, H)], ceil, coll,
         [(0, Y0 / 2), (0, Y1 / 2), ((2 * W + 6) / 2, Y1 / 2), ((2 * W + 6) / 2, Y0 / 2)])
    cross = (3.0, 5.0)          # the side corridor's span along y
    for x in (-W, W):
        for a, b in ((Y0, cross[0]), (cross[1], Y1)):
            q = [(x, a, 0), (x, b, 0), (x, b, H), (x, a, H)]
            if x > 0:
                q = [q[1], q[0], q[3], q[2]]
            uv = [(p[1] / R["cell"], p[2] / H) for p in q]
            quad(f"wall{x:.1f}{a:.0f}", q, wall, coll, uv)
        # the side corridor's walls, running off along x
        for y in cross:
            sgn = 1 if x > 0 else -1
            q = [(x, y, 0), (x + sgn * 3, y, 0), (x + sgn * 3, y, H), (x, y, H)]
            uv = [(p[0] / R["cell"], p[2] / H) for p in q]
            quad(f"side{x:.1f}{y:.0f}", q, wall, coll, uv)
    quad("end", [(-W, Y1, 0), (W, Y1, 0), (W, Y1, H), (-W, Y1, H)], wall, coll,
         [(0, 0), (1, 0), (1, 1), (0, 1)])
    for x in (-W - 3, W + 3):
        quad(f"sideend{x:.0f}", [(x, cross[0], 0), (x, cross[1], 0), (x, cross[1], H), (x, cross[0], H)], wall, coll,
             [(0, 0), (1, 0), (1, 1), (0, 1)])
    # office doors, closed, every 6 m on alternate sides
    y = -2.0
    k = 0
    while y > Y0 + 2:
        x = W if k % 2 == 0 else -W
        s = 1 if x > 0 else -1
        d0, d1 = y - R["door_w"] / 2, y + R["door_w"] / 2
        box(f"door{k}", x - s * 0.01, x - s * 0.04, d0, d1, 0, R["door_h"], door, coll)
        box(f"fa{k}", x - s * 0.01, x - s * 0.06, d0 - 0.07, d0, 0, R["door_h"] + 0.07, frame, coll)
        box(f"fb{k}", x - s * 0.01, x - s * 0.06, d1, d1 + 0.07, 0, R["door_h"] + 0.07, frame, coll)
        box(f"fh{k}", x - s * 0.01, x - s * 0.06, d0 - 0.07, d1 + 0.07, R["door_h"], R["door_h"] + 0.07, frame, coll)
        y -= 3.0
        k += 1
    lights = []
    y = Y0 + 1.0
    while y < Y1:
        quad(f"panel{y:.0f}", [(-0.3, y - 0.6, H - 0.01), (-0.3, y + 0.6, H - 0.01), (0.3, y + 0.6, H - 0.01),
                               (0.3, y - 0.6, H - 0.01)], panel, coll)
        ld = bpy.data.lights.new(f"pl{y:.0f}", "AREA")
        ld.shape = "RECTANGLE"
        ld.size, ld.size_y = 0.6, 1.2
        ld.energy = R["panel_w"]
        ld.color = SRGB(COL["light"])
        lo = bpy.data.objects.new(ld.name, ld)
        lo.location = (0, y, H - 0.03)
        coll.objects.link(lo)
        lights.append(lo)
        y += 2.0
    return coll, lights


def build_emergency(coll_parent):
    """the blackout: a green running-man sign over the side corridor, a pale green spot over the junction"""
    coll = bpy.data.collections.new("emergency")
    bpy.context.scene.collection.children.link(coll)
    sign = mat("exit_sign", COL["green"], emit=8.0)
    box("exit", -0.25, 0.25, 2.95, 2.97, 2.35, 2.55, sign, coll)
    ld = bpy.data.lights.new("junction_spot", "SPOT")
    ld.energy = 140.0
    ld.color = (0.62, 1.0, 0.68)
    ld.spot_size = math.radians(70)
    ld.spot_blend = 0.6
    lo = bpy.data.objects.new("junction_spot", ld)
    lo.location = (0, 4.0, R["ceil"] - 0.1)
    coll.objects.link(lo)
    ld2 = bpy.data.lights.new("sign_glow", "POINT")
    ld2.energy = 6.0
    ld2.color = (0.4, 1.0, 0.5)
    ld2.shadow_soft_size = 0.3
    lo2 = bpy.data.objects.new("sign_glow", ld2)
    lo2.location = (0, 2.85, 2.45)
    coll.objects.link(lo2)
    return coll


def build_backdrop():
    coll = bpy.data.collections.new("backdrop")
    bpy.context.scene.collection.children.link(coll)
    m = mat("backdrop", (0.42, 0.43, 0.44), rough=1.0)
    quad("bd_floor", [(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], m, coll)
    for name, rot, energy in (("key", (math.radians(50), 0, math.radians(-30)), 3.0),
                              ("fill", (math.radians(60), 0, math.radians(150)), 1.5)):
        ld = bpy.data.lights.new(name, "SUN")
        ld.energy = energy
        ld.angle = math.radians(10)
        lo = bpy.data.objects.new(name, ld)
        lo.rotation_euler = rot
        coll.objects.link(lo)
    return coll


def set_world(color, strength, haze):
    w = bpy.context.scene.world
    nt = w.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputWorld")
    bg = nt.nodes.new("ShaderNodeBackground")
    bg.inputs["Color"].default_value = (*SRGB(color), 1)
    bg.inputs["Strength"].default_value = strength
    nt.links.new(bg.outputs[0], out.inputs["Surface"])
    if haze:
        # the game's haze: mix toward the haze colour by 1 - exp(-density * distance)
        ab = nt.nodes.new("ShaderNodeVolumeAbsorption")
        ab.inputs["Color"].default_value = (0, 0, 0, 1)
        ab.inputs["Density"].default_value = haze
        em = nt.nodes.new("ShaderNodeEmission")
        em.inputs["Color"].default_value = (*SRGB(COL["haze"]), 1)
        em.inputs["Strength"].default_value = haze
        add = nt.nodes.new("ShaderNodeAddShader")
        nt.links.new(ab.outputs[0], add.inputs[0])
        nt.links.new(em.outputs[0], add.inputs[1])
        nt.links.new(add.outputs[0], out.inputs["Volume"])


def camera(name, loc, target, vfov):
    cd = bpy.data.cameras.new(name)
    cd.sensor_fit = "VERTICAL"
    cd.sensor_height = 24.0
    cd.lens = 12.0 / math.tan(math.radians(vfov) / 2)
    cd.clip_start = 0.05
    cd.clip_end = 200
    co = bpy.data.objects.new(name, cd)
    co.location = loc
    bpy.context.scene.collection.objects.link(co)
    d = Vector(target) - Vector(loc)
    co.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return co


def render(path, cam, res):
    scn = bpy.context.scene
    scn.camera = cam
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.filepath = path
    t = time.time()
    bpy.ops.render.render(write_still=True)
    print(f"[render] {os.path.relpath(path, ROOT)} {res[0]}x{res[1]} {time.time() - t:.1f}s")


def show(on, colls):
    for c in colls:
        c.hide_render = c not in on


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=HERE)
    ap.add_argument("--out", default=os.path.join(ROOT, "assets_src", "renders", "temp"))
    ap.add_argument("--only", default="turn,annex,face,far,dim,bend")
    args = ap.parse_args(argv)
    only = set(args.only.split(","))
    os.makedirs(args.out, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    # glTF splits vertices at UV seams and hard edges: weld them back, or the heat weights fail
    bpy.ops.import_scene.gltf(filepath=os.path.join(args.dir, "temp_tpose.glb"), merge_vertices=True)
    fig = next(o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("Temp"))
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(fig.data)
    n0 = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    print(f"[render] welded {n0} -> {len(bm.verts)} vertices")
    bm.to_mesh(fig.data)
    bm.free()
    bpy.ops.import_scene.gltf(filepath=os.path.join(args.dir, "temp_stapler.glb"))
    stapler = bpy.context.selected_objects[0]
    bpy.ops.import_scene.gltf(filepath=os.path.join(args.dir, "temp_notes.glb"))
    notes = bpy.context.selected_objects[0]
    for o in (fig, stapler, notes):
        o.rotation_mode = "XYZ"
        print(f"[render] {o.name}: {sum(len(p.vertices) - 2 for p in o.data.polygons)} triangles,"
              f" materials {[m.name for m in o.data.materials]}")
    rig = build_rig()
    body, shells = separate(fig)
    skin(rig, body, shells)

    scn.render.engine = "BLENDER_EEVEE"
    scn.eevee.taa_render_samples = R["samples"]
    scn.eevee.volumetric_end = 60.0
    scn.view_settings.view_transform = "Standard"
    scn.render.image_settings.file_format = "PNG"
    scn.world = bpy.data.worlds.new("w")
    scn.world.use_nodes = True
    backdrop = build_backdrop()
    annex, panels = build_annex()
    emerg = build_emergency(annex)
    colls = [backdrop, annex, emerg]

    if "bend" in only:
        # the rig check: both hands' fingers curled into fists, seen from above and in front
        show([backdrop], colls)
        set_world((0.45, 0.46, 0.47), 1.0, 0.0)
        pose_reset(rig)
        curl(rig, ".L", (80, 75), (25, 30))
        curl(rig, ".R", (45, 40), (15, 20))
        stapler.hide_render = notes.hide_render = True
        cams = [camera("cam_bendL", (0.80, -0.35, 1.62), (0.80, 0.0, 1.37), 30.0),
                camera("cam_bendR", (-0.80, -0.35, 1.62), (-0.80, 0.0, 1.37), 30.0)]
        render(os.path.join(args.out, "bend_hand_left.png"), cams[0], (480, 480))
        render(os.path.join(args.out, "bend_hand_right.png"), cams[1], (480, 480))
        stapler.hide_render = notes.hide_render = False

    pose_standing(rig)
    ground(rig, body)
    # the stapler carried in the right fist, its nose forward; the pad pinched by its edge in the left
    hold(rig, stapler, ".R", (0.080, 0.030, 0.0), stapler_frame)
    hold(rig, notes, ".L", (0.170, 0.012, 0.0), notes_frame)
    shadow = contact_shadow(scn.collection, rig)

    if "turn" in only:
        show([backdrop], colls)
        set_world((0.45, 0.46, 0.47), 1.0, 0.0)
        tgt = (0, -0.05, 1.05)
        d = 7.0
        for name, ang in (("front", 0), ("34", 35), ("side", 90), ("back", 180)):
            a = math.radians(ang)
            loc = (-math.sin(a) * d, -math.cos(a) * d, 1.25)
            render(os.path.join(args.out, f"turn_{name}.png"), camera("cam_" + name, loc, tgt, 17.0), (720, 960))

    show([annex], colls)
    set_world(COL["wall"], R["ambient"], R["haze"])
    if "annex" in only:
        # the corridor is too narrow to walk round it: the figure stands turned instead
        rig.rotation_euler.z = math.radians(-28)
        bpy.context.view_layer.update()
        cam = camera("cam_a34", (0.55, -3.5, 1.50), (0.0, 0.0, 0.98), 40.0)
        render(os.path.join(args.out, "annex_34.png"), cam, (960, 960))
        rig.rotation_euler.z = 0.0
        bpy.context.view_layer.update()
    if "face" in only:
        cam = camera("cam_face", (0.28, -0.95, 1.60), (-0.01, -0.05, 1.63), 26.0)
        render(os.path.join(args.out, "annex_face.png"), cam, (960, 960))
    if "far" in only:
        cam = camera("cam_far", (0.25, -10.0, R["eye"]), (0.25, 10.0, R["eye"]), R["vfov"])
        render(os.path.join(args.out, "annex_10m.png"), cam, (1280, 720))
        render(os.path.join(args.out, "annex_10m_lowres.png"), cam, (480, 270))
    if "dim" in only:
        # the blackout: every panel and tube out, green emergency light only; the figure has walked
        # into the junction under the spot
        show([annex, emerg], colls)
        for lo in panels:
            lo.hide_render = True
        bpy.data.materials["panel"].node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 0.0
        for m, _ in SELF_LIT:
            m.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 0.0
        set_world((0.15, 0.45, 0.20), 0.02, R["haze"] * 0.5)
        rig.location.y = 3.6
        follow_shadow(shadow, rig)
        cam = camera("cam_dim", (-0.3, -3.0, R["eye"]), (0.0, 4.0, 1.3), R["vfov"])
        render(os.path.join(args.out, "annex_dim.png"), cam, (1280, 720))
        rig.location.y = 0.0
        follow_shadow(shadow, rig)


if __name__ == "__main__":
    main()
