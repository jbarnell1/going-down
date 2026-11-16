"""Import orderly.glb into an empty scene, print an export report, render review images.

Usage:
  blender.exe --background --factory-startup --python render_orderly.py -- [--glb PATH] [--out DIR]
        [--verify-only] [--only turn,player,poses]
"""
import bpy, sys, os, math, time, argparse
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

R = dict(size=960, lowres=(480, 270), samples=16, eye=1.65, dist=3.0, vfov=68.0,
         backdrop=(0.30, 0.31, 0.32), tile=0.30, panel_w=70.0, lamp_emit=2.5, ambient=0.25, look_z=1.80)
# (label, action, frame after import (glTF actions start at 0), camera)
POSES = [("idle", "idle", 58, "34"), ("walk_a", "walk", 6, "34"), ("walk_b", "walk", 18, "34"),
         ("reach", "reach", 30, "side"), ("still", "still", 0, "34")]


def look_at(ob, target):
    d = Vector(target) - ob.location
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def report(path):
    print("=== RE-IMPORT REPORT ===")
    print("file:", path, os.path.getsize(path), "bytes")
    tris = 0
    for ob in bpy.data.objects:
        extra = ""
        if ob.type == "MESH":
            t = sum(len(p.vertices) - 2 for p in ob.data.polygons)
            tris += t
            extra = f"verts={len(ob.data.vertices)} tris={t} mats={[m.name for m in ob.data.materials]}"
        if ob.type == "ARMATURE":
            extra = f"bones={len(ob.data.bones)} {[b.name for b in ob.data.bones]}"
        print(f"object: {ob.name} ({ob.type}) {extra}")
    print("total tris:", tris)
    fps = bpy.context.scene.render.fps
    for a in bpy.data.actions:
        f0, f1 = a.frame_range
        print(f"action: {a.name} frames {f0:.0f}-{f1:.0f} ({(f1 - f0) / fps:.2f}s @ {fps}fps)")
    for im in bpy.data.images:
        print("image:", im.name, tuple(im.size), "packed" if im.packed_file else "")
    print("=== END REPORT ===")


def find_rig():
    return next(o for o in bpy.data.objects if o.type == "ARMATURE")


def set_action(rig, name, frame):
    ad = rig.animation_data or rig.animation_data_create()
    for t in ad.nla_tracks:
        t.mute = True
    if name is None:
        ad.action = None
        for pb in rig.pose.bones:
            pb.rotation_quaternion = (1, 0, 0, 0); pb.location = (0, 0, 0); pb.scale = (1, 1, 1)
    else:
        act = next(a for a in bpy.data.actions if a.name == name or a.name.startswith(name + "_") or a.name.startswith(name))
        ad.action = act
        if act.slots and getattr(ad, "action_slot", None) is None:
            ad.action_slot = act.slots[0]
    bpy.context.scene.frame_set(frame)


def mat(name, color, image=None, emit=0.0, rough=0.6):
    m = bpy.data.materials.new(name)
    nt = m.node_tree
    b = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    if image is not None:
        tx = nt.nodes.new("ShaderNodeTexImage"); tx.image = image; tx.interpolation = "Closest"
        nt.links.new(tx.outputs["Color"], b.inputs["Base Color"])
    if emit:
        b.inputs["Emission Color"].default_value = (*color, 1)
        b.inputs["Emission Strength"].default_value = emit
    return m


def quad_mesh(name, quads, material, coll, tile=None):
    """quads: list of 4-corner lists. UVs = world coords / tile along the quad's plane."""
    verts, faces, uvs = [], [], []
    for q in quads:
        q = [Vector(p) for p in q]
        n = (q[1] - q[0]).cross(q[2] - q[0]).normalized()
        i = len(verts)
        verts += [tuple(p) for p in q]
        faces.append([i, i + 1, i + 2, i + 3])
        for p in q:
            if abs(n.z) > 0.5:
                uvs.append((p.x / tile, p.y / tile) if tile else (0, 0))
            elif abs(n.x) > 0.5:
                uvs.append((p.y / tile, p.z / tile) if tile else (0, 0))
            else:
                uvs.append((p.x / tile, p.z / tile) if tile else (0, 0))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    uvl = me.uv_layers.new()
    for li, uv in enumerate(uvs):
        uvl.data[li].uv = uv
    me.materials.append(material)
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def tile_image(name, size, tile_col, grout_col, grout=3):
    rng = np.random.default_rng(5)
    px = np.ones((size, size, 4), np.float32)
    px[..., :3] = np.array(tile_col) + (rng.random((size, size, 1)) - 0.5) * 0.02
    px[:grout, :, :3] = grout_col
    px[:, :grout, :3] = grout_col
    im = bpy.data.images.new(name, size, size)
    im.pixels.foreach_set(px.ravel())
    return im


def box_quads(x0, x1, y0, y1, z0, z1):
    return [[(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)]]


def build_corridor():
    coll = bpy.data.collections.new("corridor")
    bpy.context.scene.collection.children.link(coll)
    floor_im = tile_image("floor_tile", 64, (0.90, 0.90, 0.88), (0.55, 0.56, 0.55))
    wall_im = tile_image("wall_tile", 64, (0.93, 0.95, 0.94), (0.70, 0.74, 0.72), 2)
    W, H, Y0, Y1 = 1.3, 2.8, -9.0, 14.0
    fl = mat("floor", (1, 1, 1), floor_im, rough=0.25)
    wl = mat("wall", (1, 1, 1), wall_im, rough=0.4)
    band = mat("band", (0.55, 0.70, 0.64), rough=0.5)
    ceil = mat("ceil", (0.85, 0.86, 0.85), rough=0.9, emit=0.55)
    lamp = mat("lamp", (1, 1, 0.97), emit=R["lamp_emit"])
    quad_mesh("floor", [[(-W, Y0, 0), (W, Y0, 0), (W, Y1, 0), (-W, Y1, 0)]], fl, coll, R["tile"])
    quad_mesh("walls", [[(-W, Y0, 0), (-W, Y1, 0), (-W, Y1, H), (-W, Y0, H)],
                        [(W, Y1, 0), (W, Y0, 0), (W, Y0, H), (W, Y1, H)],
                        [(-W, Y1, 0), (W, Y1, 0), (W, Y1, H), (-W, Y1, H)]], wl, coll, 0.15)
    quad_mesh("band", [[(-W + 0.005, Y0, 0.9), (-W + 0.005, Y1, 0.9), (-W + 0.005, Y1, 1.0), (-W + 0.005, Y0, 1.0)],
                       [(W - 0.005, Y1, 0.9), (W - 0.005, Y0, 0.9), (W - 0.005, Y0, 1.0), (W - 0.005, Y1, 1.0)]], band, coll)
    quad_mesh("ceiling", [[(-W, Y0, H), (-W, Y1, H), (W, Y1, H), (W, Y0, H)]], ceil, coll)
    y = Y0 + 1.0
    while y < Y1:
        quad_mesh(f"lamp{y:.0f}", [[(-0.3, y - 0.6, H - 0.01), (-0.3, y + 0.6, H - 0.01), (0.3, y + 0.6, H - 0.01),
                                    (0.3, y - 0.6, H - 0.01)]], lamp, coll)
        ld = bpy.data.lights.new(f"panel{y:.0f}", "AREA")
        ld.shape = "RECTANGLE"; ld.size, ld.size_y = 0.6, 1.2; ld.energy = R["panel_w"]
        lo = bpy.data.objects.new(ld.name, ld)
        lo.location = (0, y, H - 0.03)
        coll.objects.link(lo)
        y += 2.4
    return coll


def build_backdrop():
    coll = bpy.data.collections.new("backdrop")
    bpy.context.scene.collection.children.link(coll)
    m = mat("backdrop", R["backdrop"], rough=1.0)
    quad_mesh("bd_floor", [[(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)]], m, coll)
    for name, rot, energy in (("key", (math.radians(50), 0, math.radians(-30)), 3.0),
                              ("fill", (math.radians(60), 0, math.radians(150)), 1.5)):
        ld = bpy.data.lights.new(name, "SUN"); ld.energy = energy; ld.angle = math.radians(10)
        lo = bpy.data.objects.new(name, ld); lo.rotation_euler = rot
        coll.objects.link(lo)
    return coll


def camera(name, loc, target, vfov):
    cd = bpy.data.cameras.new(name)
    cd.sensor_fit = "VERTICAL"; cd.sensor_height = 24.0
    cd.lens = 12.0 / math.tan(math.radians(vfov) / 2)
    cd.clip_start = 0.05
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
    print(f"[render] {os.path.basename(path)} {res[0]}x{res[1]} {time.time() - t:.2f}s")


def show(coll_on, colls):
    for c in colls:
        c.hide_render = c is not coll_on


def contact_sheet(paths, out):
    imgs = []
    for p in paths:
        im = bpy.data.images.load(p)
        w, h = im.size
        imgs.append(np.array(im.pixels[:], np.float32).reshape(h, w, 4))
    sheet = np.concatenate(imgs, axis=1)
    h, w = sheet.shape[:2]
    out_im = bpy.data.images.new("sheet", w, h)
    out_im.pixels.foreach_set(sheet.ravel())
    out_im.filepath_raw = out
    out_im.file_format = "PNG"
    out_im.save()


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--glb", default=os.path.join(ROOT, "public", "assets", "entities", "orderly.glb"))
    ap.add_argument("--out", default=os.path.join(ROOT, "assets_src", "renders", "orderly"))
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--only", default="turn,player,poses")
    args = ap.parse_args(argv)
    only = set(args.only.split(","))

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb)
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
    world = bpy.data.worlds.new("w"); scn.world = world
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (*R["backdrop"], 1)
    bg.inputs["Strength"].default_value = 1.0

    backdrop = build_backdrop()
    corridor = build_corridor()
    colls = [backdrop, corridor]
    sz = (R["size"], R["size"])

    if "turn" in only:
        show(backdrop, colls)
        set_action(rig, None, 1)
        tgt = (0, -0.1, 1.15)
        d = 7.0
        for name, ang in (("front", 0), ("34", 35), ("side", 90), ("back", 180)):
            a = math.radians(ang)
            loc = (-math.sin(a) * d, -0.1 - math.cos(a) * d, 1.3)
            render(os.path.join(args.out, f"turn_{name}.png"), camera("cam_" + name, loc, tgt, 21.0), sz)

    if "player" in only:
        show(corridor, colls)
        bg.inputs["Color"].default_value = (0.75, 0.76, 0.75, 1)
        bg.inputs["Strength"].default_value = R["ambient"]
        set_action(rig, "idle", 1)
        cam = camera("cam_player", (0.12, -R["dist"], R["eye"]), (0, 0, R["look_z"]), R["vfov"])
        render(os.path.join(args.out, "player_view.png"), cam, sz)
        render(os.path.join(args.out, "lowres_view.png"), cam, R["lowres"])
        bg.inputs["Color"].default_value = (*R["backdrop"], 1)
        bg.inputs["Strength"].default_value = 1.0

    if "poses" in only:
        show(backdrop, colls)
        cams = {"34": camera("cam_pose34", (-3.4, -5.6, 1.35), (0, -0.25, 1.1), 26.0),
                "side": camera("cam_pose_side", (-8.2, -1.5, 1.4), (0, -1.25, 1.2), 26.0)}
        paths = []
        for label, act, f, cname in POSES:
            set_action(rig, act, f)
            p = os.path.join(args.out, f"pose_{label}.png")
            render(p, cams[cname], (480, 640))
            paths.append(p)
        contact_sheet(paths, os.path.join(args.out, "poses.png"))
        print("[render] poses.png")


if __name__ == "__main__":
    main()
