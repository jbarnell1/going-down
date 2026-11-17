"""Import minder.glb into an empty scene, print an export report, render review images.

Usage (from the repository root):
  blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/minder/render_minder.py -- [--glb PATH] [--out DIR] [--verify-only] [--only turn,poses,run,cover,dark,face]

Writes to assets_src/renders/minder/: turn_front, turn_34, turn_side, turn_back (standing, on a plain
backdrop), pose_run (all fours, mid-stride), pose_cover (crouched, hands over the mask), dark (the room
black, only the mask's own glow), face (the head close up), and poses.png (every action, one frame each).
"""
import bpy, sys, os, math, time, argparse
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

R = dict(size=960, samples=24, backdrop=(0.30, 0.31, 0.32))
# (label, action, frame after import (glTF actions start at 0), camera)
POSES = [("stand", "stand", 30, "34"), ("walk", "walk", 6, "34"), ("straighten", "straighten", 36, "side"),
         ("prowl", "prowl", 4, "34low"), ("sweep", "sweep", 20, "34low"), ("look", "look", 48, "side"),
         ("slump", "slump", 24, "34low"), ("run", "run", 3, "side"), ("catch", "catch", 72, "34"),
         ("cover", "cover", 0, "34")]


def look_at(ob, target):
    d = Vector(target) - ob.location
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def find_rig():
    return next(o for o in bpy.data.objects if o.type == "ARMATURE")


def find_mesh():
    return next(o for o in bpy.data.objects if o.type == "MESH" and o.find_armature() is not None)


def posed_extent():
    dg = bpy.context.evaluated_depsgraph_get()
    ob = find_mesh().evaluated_get(dg)
    me = ob.to_mesh()
    ps = [(ob.matrix_world @ v.co) for v in me.vertices]
    out = (max(p.z for p in ps), min(p.z for p in ps), min(p.y for p in ps), max(p.y for p in ps))
    ob.to_mesh_clear()
    return out


def pose_name(action_name):
    """The rules' pose name of an exported action ("walk-loop" -> "walk")."""
    return action_name.split("-loop")[0].split("_")[0]


def set_action(rig, name, frame):
    ad = rig.animation_data or rig.animation_data_create()
    for t in ad.nla_tracks:
        t.mute = True
    if name is None:
        ad.action = None
        for pb in rig.pose.bones:
            pb.rotation_quaternion = (1, 0, 0, 0)
            pb.location = (0, 0, 0)
            pb.scale = (1, 1, 1)
    else:
        act = next(a for a in bpy.data.actions if pose_name(a.name) == pose_name(name))
        ad.action = act
        if act.slots and getattr(ad, "action_slot", None) is None:
            ad.action_slot = act.slots[0]
    bpy.context.scene.frame_set(frame)


def report(path):
    print("=== RE-IMPORT REPORT ===")
    print("file:", os.path.relpath(path, ROOT), os.path.getsize(path), "bytes")
    for ob in bpy.data.objects:
        extra = ""
        if ob.type == "MESH":
            extra = f"verts={len(ob.data.vertices)} tris={sum(len(p.vertices) - 2 for p in ob.data.polygons)} mats={[m.name for m in ob.data.materials]}"
        if ob.type == "ARMATURE":
            extra = f"bones={len(ob.data.bones)}"
        print(f"object: {ob.name} ({ob.type}) {extra}")
    fps = bpy.context.scene.render.fps
    rig = find_rig()
    for a in sorted(bpy.data.actions, key=lambda a: a.name):
        f0, f1 = a.frame_range
        lo, hi = 9.0, -9.0
        top = 0.0
        set_action(rig, a.name, 0)
        for f in range(int(f0), int(f1) + 1, 2):
            bpy.context.scene.frame_set(f)
            t, b, _, _ = posed_extent()
            lo, hi, top = min(lo, b), max(hi, b), max(top, t)
        print(f"action: {pose_name(a.name)} ({'loop' if a.name.endswith('-loop') else 'once'}) frames {f0:.0f}-{f1:.0f} ({(f1 - f0) / fps:.2f}s @ {fps}fps) "
              f"top {top:.3f} m, lowest point {lo * 1000:+.0f}..{hi * 1000:+.0f} mm")
    print("=== END REPORT ===")


def mat(name, color, emit=0.0, rough=0.6):
    m = bpy.data.materials.new(name)
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*color, 1)
        b.inputs["Emission Strength"].default_value = emit
    return m


def quad(name, pts, material, coll):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(p) for p in pts], [], [[0, 1, 2, 3]])
    me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def build_backdrop():
    coll = bpy.data.collections.new("backdrop")
    bpy.context.scene.collection.children.link(coll)
    m = mat("backdrop", R["backdrop"], rough=1.0)
    quad("bd_floor", [(-30, -30, 0), (30, -30, 0), (30, 30, 0), (-30, 30, 0)], m, coll)
    for name, rot, energy in (("key", (math.radians(50), 0, math.radians(-30)), 3.0),
                              ("fill", (math.radians(60), 0, math.radians(150)), 1.5)):
        ld = bpy.data.lights.new(name, "SUN")
        ld.energy = energy
        ld.angle = math.radians(10)
        lo = bpy.data.objects.new(name, ld)
        lo.rotation_euler = rot
        coll.objects.link(lo)
    return coll


def build_dark_room():
    """A dark room: a floor and a wall behind, nothing lit; only the mask's own glow shows."""
    coll = bpy.data.collections.new("dark")
    bpy.context.scene.collection.children.link(coll)
    m = mat("dark_floor", (0.35, 0.33, 0.36), rough=0.9)
    quad("dk_floor", [(-30, -30, 0), (30, -30, 0), (30, 30, 0), (-30, 30, 0)], m, coll)
    quad("dk_wall", [(-30, 3, 0), (30, 3, 0), (30, 3, 6), (-30, 3, 6)], m, coll)
    return coll


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
    look_at(co, target)
    return co


def render(path, cam, res):
    scn = bpy.context.scene
    scn.camera = cam
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.filepath = path
    t = time.time()
    bpy.ops.render.render(write_still=True)
    print(f"[render] {os.path.relpath(path, ROOT)} {res[0]}x{res[1]} {time.time() - t:.2f}s")


def show(on, colls):
    for c in colls:
        c.hide_render = c not in on


def contact_sheet(paths, out, cols=5):
    imgs = []
    for p in paths:
        im = bpy.data.images.load(p)
        w, h = im.size
        imgs.append(np.array(im.pixels[:], np.float32).reshape(h, w, 4))
    rows = []
    for i in range(0, len(imgs), cols):
        row = imgs[i:i + cols]
        while len(row) < cols:
            row.append(np.zeros_like(imgs[0]))
        rows.append(np.concatenate(row, axis=1))
    sheet = np.concatenate(rows[::-1], axis=0)   # Blender rows run bottom-up
    h, w = sheet.shape[:2]
    out_im = bpy.data.images.new("sheet", w, h)
    out_im.pixels.foreach_set(sheet.ravel())
    out_im.filepath_raw = out
    out_im.file_format = "PNG"
    out_im.save()


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--glb", default=os.path.join(ROOT, "godot", "assets", "entities", "minder.glb"))
    ap.add_argument("--out", default=os.path.join(ROOT, "assets_src", "renders", "minder"))
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--only", default="turn,poses,run,cover,dark,face")
    ap.add_argument("--seq", default="", help="ACTION[:camera]: render 10 frames of one action to seq_ACTION.png instead")
    args = ap.parse_args(argv)
    only = set(args.only.split(","))

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb)
    stray = bpy.data.objects.get("Icosphere")
    if stray is not None:
        bpy.data.objects.remove(stray)
    report(args.glb)
    if args.verify_only:
        return
    os.makedirs(args.out, exist_ok=True)
    rig = find_rig()

    scn = bpy.context.scene
    scn.render.engine = "BLENDER_EEVEE"
    scn.eevee.taa_render_samples = R["samples"]
    scn.view_settings.view_transform = "Standard"
    scn.render.image_settings.file_format = "PNG"
    world = bpy.data.worlds.new("w")
    scn.world = world
    bg = world.node_tree.nodes.get("Background")

    def world_bg(col, strength):
        bg.inputs["Color"].default_value = (*col, 1)
        bg.inputs["Strength"].default_value = strength

    world_bg(R["backdrop"], 1.0)
    backdrop = build_backdrop()
    dark = build_dark_room()
    colls = [backdrop, dark]
    sz = (R["size"], R["size"])
    out = lambda n: os.path.join(args.out, n)

    if args.seq:
        act, _, cname = args.seq.partition(":")
        cams = {"side": ((-6.5, -0.6, 1.1), (0, -0.3, 0.9), 26.0), "34": ((-3.9, -6.4, 1.45), (0, -0.25, 1.10), 28.0),
                "front": ((0, -7.0, 1.2), (0, 0, 1.0), 24.0)}
        loc, tgt, fov = cams[cname or "side"]
        cam = camera("cam_seq", loc, tgt, fov)
        show([backdrop], colls)
        a = next(x for x in bpy.data.actions if pose_name(x.name) == act)
        f0, f1 = a.frame_range
        paths = []
        for i in range(10):
            f = int(round(f0 + (f1 - f0) * i / 9))
            set_action(rig, act, f)
            p = out(f"seq_{act}_{i}.png")
            render(p, cam, (300, 400))
            paths.append(p)
        contact_sheet(paths, out(f"seq_{act}.png"))
        for p in paths:
            os.remove(p)
        return

    if "turn" in only:
        show([backdrop], colls)
        set_action(rig, "stand", 0)
        tgt = (0, 0.0, 1.20)
        d = 8.5
        for name, ang in (("front", 0), ("34", 35), ("side", 90), ("back", 180)):
            a = math.radians(ang)
            loc = (-math.sin(a) * d, -math.cos(a) * d, 1.35)
            render(out(f"turn_{name}.png"), camera("cam_" + name, loc, tgt, 19.0), sz)

    if "face" in only:
        show([backdrop], colls)
        set_action(rig, "stand", 0)
        hb = rig.matrix_world @ rig.pose.bones["head"].head
        tgt = hb + Vector((0, -0.12, 0.0))
        render(out("face.png"), camera("cam_face", tgt + Vector((-0.55, -1.05, 0.10)), tgt, 30.0), sz)

    if "run" in only:
        show([backdrop], colls)
        set_action(rig, "run", 3)
        render(out("pose_run.png"), camera("cam_run", (-5.2, -3.4, 1.0), (0, -0.15, 0.62), 24.0), (1200, 800))

    if "cover" in only:
        show([backdrop], colls)
        set_action(rig, "cover", 0)
        render(out("pose_cover.png"), camera("cam_cover", (-3.0, -4.6, 1.30), (0, -0.20, 0.80), 24.0), sz)

    if "dark" in only:
        show([dark], colls)
        world_bg((0, 0, 0), 0.0)
        set_action(rig, "prowl", 4)
        render(out("dark.png"), camera("cam_dark", (-1.6, -4.2, 1.05), (0, -0.40, 0.80), 30.0), (1200, 800))
        world_bg(R["backdrop"], 1.0)

    if "poses" in only:
        cams = {"34": camera("cam_pose34", (-3.9, -6.4, 1.45), (0, -0.25, 1.10), 28.0),
                "34low": camera("cam_pose34low", (-3.9, -5.6, 1.15), (0, -0.25, 0.70), 26.0),
                "side": camera("cam_pose_side", (-8.0, -0.6, 1.2), (0, -0.4, 0.95), 24.0)}
        show([backdrop], colls)
        paths = []
        for label, act, f, cname in POSES:
            set_action(rig, act, f)
            p = out(f"pose_{label}.png") if label not in ("run", "cover") else out(f"sheet_{label}.png")
            render(p, cams[cname], (420, 560))
            paths.append(p)
        contact_sheet(paths, out("poses.png"))
        for label in ("run", "cover"):
            os.remove(out(f"sheet_{label}.png"))
        print("[render] poses.png")


if __name__ == "__main__":
    main()
