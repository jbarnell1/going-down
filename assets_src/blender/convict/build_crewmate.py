"""Build the animated crewmate (godot/assets/entities/crewmate.glb) from nothing: the Convict mesh as
build_convict.py makes it, skinned to the skeleton Mixamo rigged it with, carrying 13 named clips
baked from the Mixamo downloads, with the two headwear pieces parented to the Head bone.

Usage, from the repository root (paths are relative to it):
  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1
        --python assets_src/blender/convict/build_crewmate.py [-- --out PATH] [-- --fps 30]

Inputs (none of them leave this machine; assets_src/inbox/ is ignored by git):
  assets_src/inbox/mixamo/*.fbx          the Mixamo clips (all 13 were downloaded With Skin; the
                                         skeleton and weights are taken from the first that has a mesh)
  assets_src/blender/convict/convict_tpose.glb, headwear_knit.glb, headwear_hair.glb, convict_skin_*.png
Outputs:
  godot/assets/entities/crewmate.glb     one skinned mesh (2,216 triangles), 34 deform bones, 13 clips,
                                         headwear_knit / headwear_hair parented to the Head bone
  godot/assets/entities/crewmate_skin_1..4.png   the four skin textures (the view swaps them)

How the clips are made (numbers are printed as the script runs):
  - Every clip is read off its FBX's action as numbers (one rotation per bone per frame, the Hips
    position), at the 30 fps the clips were downloaded at.
  - The skeleton is moved to metres and Z up once (the FBX armature carries a 90 degree turn and a
    0.01 scale); bone frames turn with it, so rotations carry over unchanged and positions scale by 0.01.
    Checked: the toes land where the FBX put them (printed as "fk check").
  - Locomotion (walk, run, sneak, crawl) came WITH root motion although In Place was asked for: the
    stride speed is measured from it (hips travel per second over one whole cycle) and then removed.
  - Loops are trimmed to the best-matching cycle (only the crawl needed it), any leftover difference
    between first and last frame is spread over the clip, and the last frame is set equal to the first.
  - Each clip is centred: standing clips put the middle of the feet of the first frame on the origin,
    moving clips the mean hips position. Wherever the deformed mesh goes below the floor (the crawl by
    about 16 cm, the spin's floor work, the fall), the hips are lifted frame by frame.
  - pray kneels and then the kneel is played backwards so the clip ends standing; taken falls in place
    (its metre of backward travel is taken out while the body is in the air) and ends on the floor.
"""
import bpy, os, sys, math, glob, shutil, argparse
import numpy as np
from mathutils import Vector, Matrix, Quaternion
from mathutils.kdtree import KDTree
from bpy_extras import anim_utils

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MIXAMO = os.path.join(ROOT, "assets_src", "inbox", "mixamo")
ENT = os.path.join(ROOT, "godot", "assets", "entities")
FPS = 30
PREFIX = "mixamorig:"

# game name, Mixamo file, kind
#   loop: loops in place   move: loops, had root motion (stride speed measured, then removed)
#   once: one-shot from standing back to standing   fall: one-shot ending on the floor
#   kneel: kneels, then the kneel is reversed so it ends standing
CLIPS = [
    ("idle", "Standing Idle", "loop"),
    ("walk", "Walking", "move"),
    ("run", "Jog Forward", "move"),
    ("sneak", "Sneaking Forward", "move"),
    ("crouch_idle", "Crouching Idle", "loop"),
    ("look_behind", "Looking Behind", "once"),
    ("button", "Button Pushing", "once"),
    ("taken", "Standing Death Backward 01", "fall"),
    ("crawl", "Crawling", "move"),
    ("pray", "Praying", "kneel"),
    ("dance_spin", "Northern Soul Spin Combo", "loop"),
    ("dance_snake", "Snake Hip Hop Dance", "loop"),
    ("wave", "Waving", "once"),
]
MATS = ("convict_suit", "convict_skin", "number_patch", "face_screen")
HEAD_JOINT = Vector((0, 0.005, 1.548))   # build_convict.py JOINTS["head"]: the headwear origin
FLOOR_TOL = 0.006                        # the mesh may dip this far under y = 0 before it is lifted
# The mask (housing, gasket, screen, harness, cable top) is rigid: every vertex above this height that
# is not neck skin follows the Head bone only, so the screen never bends or slides off the face.
MASK_Z = 1.535
MASK_LOW = 1.495                         # from here up to MASK_Z the neck eases into the head


def log(*a):
    print("[crewmate]", *a, flush=True)


# ------------------------------------------------------------------ scene helpers
def clear_orphans():
    for _ in range(4):
        bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)


def import_fbx(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=path, automatic_bone_orientation=False, ignore_leaf_bones=False,
                             use_anim=True, anim_offset=0.0)
    return [o for o in bpy.data.objects if o not in before]


def remove_objects(objs):
    for o in objs:
        bpy.data.objects.remove(o, do_unlink=True)
    clear_orphans()


def read_action(arm):
    """{bone: {"q": (F,4), "l": (F,3)}} at every integer frame, bone names without the prefix."""
    act = arm.animation_data.action
    cb = anim_utils.action_get_channelbag_for_slot(act, arm.animation_data.action_slot)
    f0, f1 = (int(round(x)) for x in act.frame_range)
    frames = range(f0, f1 + 1)
    out = {}
    for fc in cb.fcurves:
        b = fc.data_path.split('"')[1].replace(PREFIX, "")
        kind = fc.data_path.rsplit(".", 1)[1]
        if kind not in ("rotation_quaternion", "location"):
            continue
        d = out.setdefault(b, {"q": np.tile([1.0, 0, 0, 0], (len(frames), 1)), "l": np.zeros((len(frames), 3))})
        key = "q" if kind == "rotation_quaternion" else "l"
        d[key][:, fc.array_index] = [fc.evaluate(f) for f in frames]
    for d in out.values():
        d["l"] *= 0.01      # centimetres -> metres (see the module notes)
    return out, len(frames)


# ------------------------------------------------------------------ quaternion maths (w, x, y, z)
def qmul(a, b):
    aw, ax, ay, az = np.moveaxis(a, -1, 0)
    bw, bx, by, bz = np.moveaxis(b, -1, 0)
    return np.stack([aw * bw - ax * bx - ay * by - az * bz, aw * bx + ax * bw + ay * bz - az * by,
                     aw * by - ax * bz + ay * bw + az * bx, aw * bz + ax * by - ay * bx + az * bw], -1)


def qinv(a):
    return a * np.array([1, -1, -1, -1])


def qnorm(a):
    return a / np.linalg.norm(a, axis=-1, keepdims=True)


def qpow(q, s):
    """q^s for unit quaternions, s scalar or array (broadcast over leading axes)"""
    q = np.where(q[..., :1] < 0, -q, q)
    w = np.clip(q[..., 0], -1, 1)
    ang = np.arccos(w)
    sn = np.sin(ang)
    axis = np.where(sn[..., None] > 1e-9, q[..., 1:] / np.maximum(sn, 1e-9)[..., None], 0.0)
    a2 = ang * s
    return np.concatenate([np.cos(a2)[..., None], axis * np.sin(a2)[..., None]], -1)


def qangle(a, b):
    d = np.abs(np.sum(a * b, -1))
    return np.degrees(2 * np.arccos(np.clip(d, 0, 1)))


def continuous(q):
    q = q.copy()
    for i in range(1, len(q)):
        if np.dot(q[i], q[i - 1]) < 0:
            q[i] = -q[i]
    return q


# ------------------------------------------------------------------ clip operations on {bone: {q, l}}
BODY = None   # bones that count for pose distances (no fingers)


def pose_dist(clip, i, j):
    e = sum(qangle(clip[b]["q"][i], clip[b]["q"][j]) for b in BODY)
    e += 100.0 * abs(clip["Hips"]["l"][i][1] - clip["Hips"]["l"][j][1])  # hips height (local y is up-ish)
    return e / len(BODY)


def take(clip, idx):
    return {b: {"q": d["q"][idx].copy(), "l": d["l"][idx].copy()} for b, d in clip.items()}


def close_loop(clip, hips_xy_too=False):
    """Spread the difference between the last frame and the first over the clip; last == first."""
    for b, d in clip.items():
        q = continuous(d["q"])
        F = len(q)
        s = np.linspace(0, 1, F)
        err = qmul(qinv(q[-1]), q[0])          # q[-1] * err = q[0]
        q = qnorm(qmul(q, qpow(np.broadcast_to(err, q.shape), s)))
        q[-1] = q[0]
        d["q"] = q
        l = d["l"]
        res = l[0] - l[-1]
        d["l"] = l + s[:, None] * res[None, :]
        d["l"][-1] = d["l"][0]


def join_at(clip, n_first, blend):
    """frames [n_first:] were appended after frame n_first-1: ease the rotation jump at the join out
    over `blend` frames (the first appended frame becomes the frame before it)."""
    for d in clip.values():
        q = continuous(d["q"])
        err = qmul(qinv(q[n_first]), q[n_first - 1])
        for k in range(blend):
            s = 1.0 - (k / blend)
            s = s * s * (3 - 2 * s)
            q[n_first + k] = qnorm(qmul(q[n_first + k], qpow(err, s)))
        d["q"] = q
        l = d["l"]
        res = l[n_first - 1] - l[n_first]
        for k in range(blend):
            s = 1.0 - (k / blend)
            l[n_first + k] += res * s * s * (3 - 2 * s)


# ------------------------------------------------------------------ armature / action plumbing
class Rig:
    def __init__(self, arm):
        self.arm = arm
        hb = arm.data.bones["Hips"]
        self.M3 = np.array(hb.matrix_local.to_3x3())
        self.t = np.array(hb.matrix_local.translation)
        self.M3i = np.linalg.inv(self.M3)

    def hips_world(self, clip):
        return self.t + clip["Hips"]["l"] @ self.M3.T

    def set_hips_world(self, clip, w):
        clip["Hips"]["l"] = (w - self.t) @ self.M3i.T

    def write(self, name, clip):
        arm = self.arm
        F = len(clip["Hips"]["q"])
        act = bpy.data.actions.get(name)
        if act:
            bpy.data.actions.remove(act)
        act = bpy.data.actions.new(name)
        act.use_fake_user = True
        slot = act.slots.new(id_type="OBJECT", name=arm.name)
        arm.animation_data_create()
        arm.animation_data.action = act
        arm.animation_data.action_slot = slot
        cb = anim_utils.action_ensure_channelbag_for_slot(act, slot)
        frames = np.arange(F, dtype=np.float64)
        for b, d in clip.items():
            if b not in arm.pose.bones:
                continue
            chans = [("rotation_quaternion", i, d["q"][:, i]) for i in range(4)]
            if b == "Hips" or np.abs(d["l"]).max() > 1e-6:
                chans += [("location", i, d["l"][:, i]) for i in range(3)]
            for path, i, vals in chans:
                fc = cb.fcurves.new(f'pose.bones["{b}"].{path}', index=i)
                fc.keyframe_points.add(F)
                fc.keyframe_points.foreach_set("co", np.column_stack([frames, vals]).ravel())
                for kp in fc.keyframe_points:
                    kp.interpolation = "LINEAR"
                fc.update()
        act.use_frame_range = True
        act.frame_range = (0, F - 1)
        return act

    def sample(self, mesh_ob, F):
        """per frame: mesh min z, feet midpoint xy, both toe positions"""
        scn = bpy.context.scene
        out = []
        pb = self.arm.pose.bones
        for f in range(F):
            scn.frame_set(f)
            dg = bpy.context.evaluated_depsgraph_get()
            ev = mesh_ob.evaluated_get(dg)
            me = ev.to_mesh()
            co = np.empty(len(me.vertices) * 3)
            me.vertices.foreach_get("co", co)
            ev.to_mesh_clear()
            feet = [self.arm.matrix_world @ pb[n].head for n in ("LeftFoot", "LeftToeBase", "RightFoot", "RightToeBase")]
            mid = sum(feet, Vector()) / 4
            out.append((co.reshape(-1, 3)[:, 2].min(), mid.x, mid.y, *feet[1], *feet[3]))
        return np.array(out)


def smooth_max(v, wrap):
    mode = "wrap" if wrap else "edge"
    p = np.pad(v, 3, mode=mode)
    mx = np.array([p[i:i + 7].max() for i in range(len(v))])
    p = np.pad(mx, 2, mode=mode)
    return np.array([p[i:i + 5].mean() for i in range(len(v))])


# ------------------------------------------------------------------ the build
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ENT, "crewmate.glb"))
    ap.add_argument("--fps", type=int, default=FPS, help="sample rate of the exported clips")
    args = ap.parse_args(argv)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.fps = FPS
    scn.render.fps_base = 1.0

    # ---- 1. the skeleton and Mixamo's weights from the first clip that carries the mesh
    files = {src: os.path.join(MIXAMO, src + ".fbx") for _, src, _ in CLIPS}
    for p in files.values():
        if not os.path.exists(p):
            raise SystemExit("missing " + os.path.relpath(p, ROOT))
    raw = {}
    skinned = []
    arm = None
    mx_mesh = None
    rest_cm = None
    fk_ref = None
    for game, src, kind in CLIPS:
        new = import_fbx(files[src])
        a = next(o for o in new if o.type == "ARMATURE")
        meshes = [o for o in new if o.type == "MESH"]
        if meshes:
            skinned.append(src)
        heads = {b.name.replace(PREFIX, ""): np.array(b.head_local) for b in a.data.bones}
        raw[game] = read_action(a)
        if arm is None and meshes:
            arm, mx_mesh = a, meshes[0]
            rest_cm = heads
            # reference for the axis/scale check: toe positions at two frames as the FBX has them
            fk_ref = []
            for f in (int(a.animation_data.action.frame_range[0]), int(a.animation_data.action.frame_range[0]) + 20):
                scn.frame_set(f)
                fk_ref.append([np.array(a.matrix_world @ a.pose.bones[PREFIX + n].head) for n in ("LeftToeBase", "RightHand", "Head")])
            keep = {a, *meshes}
            remove_objects([o for o in new if o not in keep])
            for m in meshes[1:]:
                bpy.data.objects.remove(m, do_unlink=True)
        else:
            err = max(np.abs(heads[b] - rest_cm[b]).max() for b in rest_cm)
            if err > 0.05:
                raise SystemExit(f"{src}: skeleton differs from the skinned one by {err:.3f} cm")
            remove_objects(new)
        log(f"read {src}: {raw[game][1]} frames{' (with skin)' if meshes else ''}")
    log(f"files with the mesh in them: {len(skinned)} of {len(CLIPS)}: {', '.join(skinned)}")
    log(f"skeleton and weights from: {skinned[0]}")

    # Mixamo's mesh: what the round trip kept (checked, then only its weights are used)
    me = mx_mesh.data
    mw = mx_mesh.matrix_world
    mx_co = np.array([mw @ v.co for v in me.vertices])
    mx_tris = sum(len(p.vertices) - 2 for p in me.polygons)
    mx_mats = [m.name if m else None for m in me.materials]
    uvl = me.uv_layers[0].data if me.uv_layers else None
    mx_uvs = [[] for _ in me.vertices]          # every UV each Mixamo vertex carries
    if uvl:
        for p in me.polygons:
            for li in p.loop_indices:
                mx_uvs[me.loops[li].vertex_index].append(tuple(uvl[li].uv))
    groups = {g.index: g.name.replace(PREFIX, "") for g in mx_mesh.vertex_groups}
    mx_w = [[(groups[g.group], g.weight) for g in v.groups if g.weight > 0] for v in me.vertices]
    log(f"Mixamo mesh: {len(me.vertices)} verts, {mx_tris} tris, materials {mx_mats}, "
        f"uv layers {[u.name for u in me.uv_layers]}, {len(groups)} weighted bones, "
        f"height {mx_co[:, 2].min():.4f}..{mx_co[:, 2].max():.4f} m")
    bpy.data.objects.remove(mx_mesh, do_unlink=True)
    clear_orphans()

    # ---- 2. the skeleton in metres, Z up, bones without the prefix
    arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.scale = (1, 1, 1)
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for b in arm.data.bones:
        b.name = b.name.replace(PREFIX, "")
    arm.name = arm.data.name = "Crewmate"
    weighted = set(n for row in mx_w for n, _ in row)
    for b in arm.data.bones:
        b.use_deform = b.name in weighted   # the 7 leaf ends (HeadTop_End, Toe_End, finger tips) carry nothing
    global BODY
    BODY = [b.name for b in arm.data.bones if b.use_deform and not any(k in b.name for k in ("Thumb", "Index"))]
    rig = Rig(arm)
    log(f"skeleton: {len(arm.data.bones)} bones, {sum(b.use_deform for b in arm.data.bones)} deform; "
        f"Hips rest at {tuple(round(x, 3) for x in arm.data.bones['Hips'].head_local)}, "
        f"Head at {tuple(round(x, 3) for x in arm.data.bones['Head'].head_local)}")

    # ---- 3. the game's mesh (build_convict.py's own export) with Mixamo's weights copied on
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(HERE, "convict_tpose.glb"))
    imported = [o for o in bpy.data.objects if o not in before]
    body = next(o for o in imported if o.type == "MESH")
    bpy.ops.object.select_all(action="DESELECT")
    for o in imported:
        o.select_set(True)
    bpy.context.view_layer.objects.active = body
    body.parent = None
    body.matrix_world = body.matrix_world.copy()
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    remove_objects([o for o in imported if o is not body])
    body.name = body.data.name = "Crewmate_body"
    bm = body.data
    mats = [m.name for m in bm.materials]
    if tuple(mats) != MATS:
        raise SystemExit(f"convict_tpose.glb materials {mats}, expected {MATS}")
    co = np.array([v.co for v in bm.vertices])
    tris = sum(len(p.vertices) - 2 for p in bm.polygons)
    kd = KDTree(len(mx_co))
    for i, c in enumerate(mx_co):
        kd.insert(c, i)
    kd.balance()
    # round trip check: every corner of the game's mesh has a Mixamo vertex at the same place with the same UV
    buv = bm.uv_layers[0].data
    corners = bad = 0
    for p in bm.polygons:
        for li in p.loop_indices:
            _, j, dist = kd.find(co[bm.loops[li].vertex_index])
            u = buv[li].uv
            corners += 1
            if dist > 1e-4 or not any(abs(u[0] - a) < 1e-4 and abs(u[1] - b) < 1e-4 for a, b in mx_uvs[j]):
                bad += 1
    log(f"round trip: triangles {tris} vs Mixamo {mx_tris}; materials {'kept' if tuple(mx_mats) == MATS else 'CHANGED ' + str(mx_mats)}; "
        f"{corners - bad} of {corners} triangle corners have the same position and UV in Mixamo's mesh")
    # face screen UV must be the flat 0..1 rectangle, upright (u with +X, v with +Z)
    scr = MATS.index("face_screen")
    us = [(co[bm.loops[li].vertex_index], buv[li].uv) for p in bm.polygons if p.material_index == scr for li in p.loop_indices]
    u_ok = all(abs(uv[0] - (c[0] - min(x[0][0] for x in us)) / np.ptp([x[0][0] for x in us])) < 1e-3 for c, uv in us)
    v_ok = all(abs(uv[1] - (c[2] - min(x[0][2] for x in us)) / np.ptp([x[0][2] for x in us])) < 1e-3 for c, uv in us)
    log(f"face_screen UV: flat 0..1, u along +X {u_ok}, v along +Z {v_ok}")
    if not (u_ok and v_ok):
        raise SystemExit("face_screen UV is not the flat 0..1 rectangle")
    vg = {}
    worst = 0.0
    rigid = 0
    for v in bm.vertices:
        _, j, dist = kd.find(v.co)
        worst = max(worst, dist)
        row = dict(mx_w[j])
        t = min(1.0, max(0.0, (v.co.z - MASK_LOW) / (MASK_Z - MASK_LOW)))
        t = t * t * (3 - 2 * t)
        if t > 0:
            row = {n: w * (1 - t) for n, w in row.items()}
            row["Head"] = row.get("Head", 0.0) + t
            rigid += t >= 1
        tot = sum(row.values())
        for n, w in row.items():
            if w < 1e-4:
                continue
            if n not in vg:
                vg[n] = body.vertex_groups.new(name=n)
            vg[n].add([v.index], w / tot, "REPLACE")
    log(f"weights copied: {len(bm.vertices)} verts, worst position match {worst * 1000:.3f} mm; "
        f"{rigid} mask/head verts above z {MASK_Z} bound to Head only")
    if worst > 1e-3:
        raise SystemExit("Mixamo's mesh does not line up with convict_tpose.glb")
    body.parent = arm
    body.matrix_parent_inverse = Matrix.Identity(4)
    mod = body.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    log(f"body: {len(bm.vertices)} verts, {tris} tris, height {co[:, 2].min():.3f}..{co[:, 2].max():.3f} m, faces -Y (glTF +Z)")

    # headwear: parented to the Head bone, origin at build_convict's head joint
    hb = arm.data.bones["Head"]
    for kind in ("knit", "hair"):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=os.path.join(HERE, f"headwear_{kind}.glb"))
        new = [o for o in bpy.data.objects if o not in before]
        hw = next(o for o in new if o.type == "MESH")
        hw.parent = None
        remove_objects([o for o in new if o is not hw])
        hw.name = hw.data.name = f"headwear_{kind}"
        world = Matrix.Translation(HEAD_JOINT) @ hw.matrix_world   # glb vertices are relative to the joint
        hw.parent = arm
        hw.parent_type = "BONE"
        hw.parent_bone = "Head"
        bpy.context.view_layer.update()
        hw.matrix_world = world
    off = hb.matrix_local.inverted() @ HEAD_JOINT
    log(f"headwear: parented to bone 'Head'; its origin is {tuple(round(x, 4) for x in off)} m from the Head joint "
        f"in the bone's own axes; in the rest pose that is {tuple(round(x, 4) for x in (HEAD_JOINT - hb.head_local))} m "
        f"(Blender, Z up), ({off_gltf(HEAD_JOINT - hb.head_local)}) in glTF/Godot axes")

    # ---- 4. the clips
    # check the axis/scale move: the idle's frames, unprocessed, put the toes where the FBX did
    first = CLIPS[[s for _, s, _ in CLIPS].index(skinned[0])][0]
    rig.write("_check", take(raw[first][0], slice(None)))
    errs = []
    for k, f in enumerate((0, 20)):
        scn.frame_set(f)
        for n, ref in zip(("LeftToeBase", "RightHand", "Head"), fk_ref[k]):
            errs.append(np.linalg.norm(np.array(arm.pose.bones[n].head) - ref))
    log(f"fk check: unprocessed '{first}' joints within {max(errs) * 1000:.3f} mm of the FBX's")
    if max(errs) > 1e-3:
        raise SystemExit("the skeleton move changed the animation")
    bpy.data.actions.remove(bpy.data.actions["_check"])

    report = []
    idle_first = None
    for game, src, kind in CLIPS:
        clip, F = raw[game]
        for d in clip.values():
            d["q"] = continuous(d["q"])
        notes = []
        speed = None
        loops = kind in ("loop", "move")
        # trim to a clean cycle
        if loops:
            e0 = pose_dist(clip, 0, F - 1)
            if e0 > 0.5:
                best = (1e9, 0, F - 1)
                for a in range(0, F // 3):
                    for b in range(a + F // 2, F):
                        e = pose_dist(clip, a, b)
                        if e < best[0]:
                            best = (e, a, b)
                e, a, b = best
                clip = take(clip, slice(a, b + 1))
                notes.append(f"cycle {a}..{b} of {F} (end mismatch {e0:.1f} -> {e:.1f} deg mean)")
                F = b - a + 1
        if kind == "kneel":
            # forward to frame K, then frames j..0 backwards; pick the closest join
            best = (1e9, 0, 0)
            for K in range(110, F):
                for j in range(45, 80):
                    e = pose_dist(clip, K, j)
                    if e < best[0]:
                        best = (e, K, j)
            e, K, j = best
            idx = list(range(0, K + 1)) + list(range(j, -1, -1))
            clip = take(clip, idx)
            join_at(clip, K + 1, 8)
            F = len(idx)
            notes.append(f"kneels 0..{K}, then {j}..0 backwards (join {e:.1f} deg)")
        hw = rig.hips_world(clip)
        if kind == "move":
            disp = hw[-1] - hw[0]
            dur = (F - 1) / FPS
            speed = float(np.hypot(disp[0], disp[1]) / dur)
            notes.append(f"root motion {np.hypot(disp[0], disp[1]):.3f} m over {dur:.3f} s, heading "
                         f"{math.degrees(math.atan2(disp[0], -disp[1])):.1f} deg off -Y")
        if loops:
            s = np.linspace(0, 1, F)[:, None]
            drift = hw[-1] - hw[0]
            hw[:, :2] -= s * drift[None, :2]
        if kind == "fall":
            z = hw[:, 2]
            a = int(np.argmax(z < z[0] - 0.12))
            b = int(np.argmax(z < z.min() + 0.08))
            a = max(0, a - 4)
            b = max(b, a + 4)
            s = np.clip((np.arange(F) - a) / (b - a), 0, 1)
            s = s * s * (3 - 2 * s)
            drift = hw[-1] - hw[0]
            hw[:, :2] -= s[:, None] * drift[None, :2]
            notes.append(f"backward travel {np.hypot(drift[0], drift[1]):.2f} m taken out over frames {a}..{b}")
        rig.set_hips_world(clip, hw)
        if loops:
            close_loop(clip)
        # centre, then lift wherever the mesh goes through the floor
        rig.write(game, clip)
        smp = rig.sample(body, F)
        hw = rig.hips_world(clip)
        if kind in ("move",):
            c = hw[:, :2].mean(0)
        else:
            c = smp[0, 1:3]
        hw[:, :2] -= c[None, :]
        lift = smooth_max(np.maximum(0.0, -smp[:, 0] - FLOOR_TOL), loops)
        if lift.max() > 0:
            notes.append(f"lifted up to {lift.max() * 100:.1f} cm where the mesh went under the floor")
        hw[:, 2] += lift
        rig.set_hips_world(clip, hw)
        if loops:
            for d in clip.values():
                d["q"][-1] = d["q"][0]
                d["l"][-1] = d["l"][0]
        rig.write(game, clip)
        smp = rig.sample(body, F)
        hw = rig.hips_world(clip)
        q0 = np.stack([clip[b]["q"][0] for b in BODY])
        q1 = np.stack([clip[b]["q"][-1] for b in BODY])
        if game == "idle":
            idle_first = q0
        loop_err = float(qangle(q0, q1).max())
        vs_idle = float(qangle(q0, idle_first).mean()) if idle_first is not None else 0.0
        vs_idle_end = float(qangle(q1, idle_first).mean()) if idle_first is not None else 0.0
        report.append(dict(name=game, src=src, kind=kind, frames=F, length=(F - 1) / FPS, speed=speed,
                           minz=float(smp[:, 0].min()), float_med=float(np.median(smp[:, 0])),
                           drift=float(np.hypot(*(hw[-1, :2] - hw[0, :2]))), sway=float(np.ptp(hw[:, :2], 0).max()),
                           loop_err=loop_err, vs_idle=(vs_idle, vs_idle_end), notes=notes))
        log(f"{game:12s} {F:4d} frames {(F - 1) / FPS:6.2f} s  " + "; ".join(notes))

    # ---- 5. export
    arm.animation_data.action = None
    names = {c[0] for c in CLIPS}
    for a in list(bpy.data.actions):
        if a.name not in names:
            bpy.data.actions.remove(a)
    clear_orphans()
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
    scn.frame_set(0)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for o in (arm, body, bpy.data.objects["headwear_knit"], bpy.data.objects["headwear_hair"]):
        o.select_set(True)
    bpy.context.view_layer.objects.active = arm
    step = max(1, round(FPS / args.fps))
    bpy.ops.export_scene.gltf(
        filepath=args.out, export_format="GLB", use_selection=True, export_yup=True, export_apply=False,
        export_skins=True, export_def_bones=True, export_rest_position_armature=True,
        export_animations=True, export_animation_mode="ACTIONS", export_force_sampling=True,
        export_frame_step=step, export_optimize_animation_size=True, export_anim_slide_to_zero=True,
        export_anim_single_armature=True, export_morph=False, export_materials="EXPORT",
        export_image_format="AUTO", export_extras=False, export_cameras=False, export_lights=False)
    size = os.path.getsize(args.out)
    for i in range(1, 5):
        shutil.copyfile(os.path.join(HERE, f"convict_skin_{i}.png"), os.path.join(ENT, f"crewmate_skin_{i}.png"))
    log(f"exported {os.path.relpath(args.out, ROOT)}: {size} bytes ({size / 1048576:.2f} MB), {tris} tris, "
        f"{sum(b.use_deform for b in arm.data.bones)} bones in the skin, clips sampled every {step} frame(s) at {FPS} fps")
    log("clip          length  frames  stride m/s  loop err  vs idle (start/end, mean deg)  lowest  median low")
    for r in report:
        sp = f"{r['speed']:.2f}" if r["speed"] else "   -"
        le = f"{r['loop_err']:.2f}" if r["kind"] in ("loop", "move") else "   -"
        log(f"  {r['name']:12s} {r['length']:5.2f} s {r['frames']:5d}   {sp:>8s}   {le:>6s}   "
            f"{r['vs_idle'][0]:5.1f} / {r['vs_idle'][1]:5.1f}       {r['minz'] * 100:5.1f} cm {r['float_med'] * 100:5.1f} cm")
    verify(args.out)


def off_gltf(v):
    return f"{v[0]:.4f}, {v[2]:.4f}, {-v[1]:.4f}"


def verify(path):
    """Read the exported file back: one skinned mesh, its triangles, the clips and their lengths."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS
    bpy.ops.import_scene.gltf(filepath=path)
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.data.polygons and o.data.materials]
    skinned = [o for o in meshes if any(m.type == "ARMATURE" for m in o.modifiers)]
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    for o in meshes:
        log(f"verify: mesh {o.name}: {sum(len(p.vertices) - 2 for p in o.data.polygons)} tris, "
            f"{'skinned' if o in skinned else 'parent ' + str(o.parent_bone or o.parent)}, materials {[m.name for m in o.data.materials]}")
    log(f"verify: {len(skinned)} skinned mesh, {len(arm.data.bones)} bones, clips "
        + ", ".join(f"{a.name} {(a.frame_range[1] - a.frame_range[0]) / FPS:.2f}s" for a in bpy.data.actions))


if __name__ == "__main__":
    main()
