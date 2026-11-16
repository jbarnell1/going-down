"""Import orderly.glb into an empty scene, print an export report, render review images.

Usage:
  blender.exe --background --factory-startup --python render_orderly.py -- [--glb PATH] [--out DIR]
        [--verify-only] [--only turn,player,far,face,poses]
"""
import bpy, sys, os, math, time, argparse
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# Clinic numbers from src/render: 2 m cells, 3.2 m storey, doors 1.1 x 2.1 m, door frames 0x8fa89a.
R = dict(size=960, lowres=(480, 270), wide=(1280, 720), samples=16, eye=1.65, dist=3.0, far=20.0, vfov=70.0,
         backdrop=(0.30, 0.31, 0.32), cell=2.0, ceil=3.2, door_w=1.1, door_h=2.1,
         panel_w=60.0, ambient=0.55, fig_x=0.0)
SRGB = lambda h: tuple(((h >> s & 255) / 255.0) ** 2.2 for s in (16, 8, 0))
COL = dict(wall=SRGB(0xd9e2dd), rail=SRGB(0x7fa38e), skirt=SRGB(0x8a958f), floor=SRGB(0xeef0ee),
           grout=SRGB(0x9da5a1), ceil=SRGB(0xd0d6d3), frame=SRGB(0x8fa89a), room=SRGB(0xc9d4e6))
# (label, action, frame after import (glTF actions start at 0), camera)
POSES = [("idle", "idle", 30, "34"), ("walk_a", "walk", 3, "34"), ("walk_b", "walk", 15, "34"),
         ("reach", "reach", 33, "side"), ("duck", "duck", 24, "duck"), ("still", "still", 0, "34")]


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
    zs = [(ob.matrix_world @ v.co) for v in me.vertices]
    top = max(p.z for p in zs)
    reach = min(p.y for p in zs)
    ob.to_mesh_clear()
    return top, reach


def report(path):
    print("=== RE-IMPORT REPORT ===")
    print("file:", os.path.relpath(path, ROOT), os.path.getsize(path), "bytes")
    tris = 0
    for ob in bpy.data.objects:
        extra = ""
        if ob.type == "MESH":
            t = sum(len(p.vertices) - 2 for p in ob.data.polygons)
            tris += t
            zs = [v.co.z for v in ob.data.vertices]
            extra = f"verts={len(ob.data.vertices)} tris={t} mats={[m.name for m in ob.data.materials]}"
        if ob.type == "ARMATURE":
            extra = f"bones={len(ob.data.bones)}"
        print(f"object: {ob.name} ({ob.type}) {extra}")
    print("total tris (skinned meshes):", sum(sum(len(p.vertices) - 2 for p in o.data.polygons)
                                            for o in bpy.data.objects if o.type == "MESH" and o.find_armature()))
    fps = bpy.context.scene.render.fps
    for a in bpy.data.actions:
        f0, f1 = a.frame_range
        print(f"action: {a.name} frames {f0:.0f}-{f1:.0f} ({(f1 - f0) / fps:.2f}s @ {fps}fps)")
    for im in bpy.data.images:
        print("image:", im.name, tuple(im.size), "packed" if im.packed_file else "",
              "interp from material:", [n.interpolation for m in bpy.data.materials if m.node_tree
                                        for n in m.node_tree.nodes if n.type == "TEX_IMAGE"])
    rig = find_rig()
    set_action(rig, None, 0)
    print("rest height: %.3f m" % posed_extent()[0])
    for label, act, f in (("idle", "idle", 0), ("walk", "walk", 6), ("reach peak", "reach", 33),
                          ("duck folded", "duck", 24), ("still", "still", 0)):
        set_action(rig, act, f)
        top, reach = posed_extent()
        print(f"pose {label}: top {top:.3f} m, front-most {-reach:.3f} m")
    print("=== END REPORT ===")


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


def box(name, x0, x1, y0, y1, z0, z1, material, coll):
    q = [[(x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0)],
         [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
         [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
         [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
         [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
         [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)]]
    return quad_mesh(name, q, material, coll)


def tile_image(name, size, tile_col, grout_col, grout=2):
    rng = np.random.default_rng(5)
    px = np.ones((size, size, 4), np.float32)
    px[..., :3] = np.array(tile_col) + (rng.random((size, size, 1)) - 0.5) * 0.015
    px[:grout, :, :3] = grout_col
    px[:, :grout, :3] = grout_col
    im = bpy.data.images.new(name, size, size)
    im.pixels.foreach_set(px.ravel())
    return im


def wall_image():
    """Like the game's wall: plain panel, a seam every 2 m, a green rail, a darker skirting."""
    h, w = 128, 64
    px = np.ones((h, w, 4), np.float32)
    px[..., :3] = COL["wall"]
    v = (np.arange(h) + 0.5) / h * R["ceil"]
    rail = (v > 0.92) & (v < 1.06)
    px[rail, :, :3] = COL["rail"]
    px[v < 0.10, :, :3] = COL["skirt"]
    px[:, :1, :3] = np.array(COL["wall"]) * 0.82
    im = bpy.data.images.new("wall_tex", w, h)
    im.pixels.foreach_set(px.ravel())
    return im


def build_corridor():
    coll = bpy.data.collections.new("corridor")
    bpy.context.scene.collection.children.link(coll)
    W, H, Y0, Y1 = R["cell"] / 2, R["ceil"], -45.0, 8.0
    fl = mat("floor", (1, 1, 1), tile_image("floor_tile", 32, COL["floor"], COL["grout"]), rough=0.35)
    wim = wall_image()
    wl = mat("wall", (1, 1, 1), wim, rough=0.6)
    ce = mat("ceil", (1, 1, 1), tile_image("ceil_tile", 32, COL["ceil"], tuple(c * 0.8 for c in COL["ceil"])), rough=0.9)
    lamp = mat("lamp", (1, 1, 0.98), emit=3.0)
    frame = mat("frame", COL["frame"], rough=0.5)
    room = mat("room", COL["room"], rough=0.8)
    quad_mesh("floor", [[(-W, Y0, 0), (W, Y0, 0), (W, Y1, 0), (-W, Y1, 0)]], fl, coll, 0.5)
    # walls: UV u along the wall per 2 m cell, v = height / 3.2 so the rail sits at ~1 m
    d0, d1 = -R["door_w"] / 2, R["door_w"] / 2
    for x, flip in ((-W, False), (W, True)):
        segs = [(Y0, Y1)] if x < 0 else [(Y0, d0), (d1, Y1)]
        for a, b in segs:
            q = [(x, a, 0), (x, b, 0), (x, b, H), (x, a, H)]
            if flip:
                q = [q[1], q[0], q[3], q[2]]
            ob = quad_mesh(f"wall{x}{a}", [q], wl, coll)
            uvl = ob.data.uv_layers[0]
            for li, l in enumerate(ob.data.loops):
                co = ob.data.vertices[l.vertex_index].co
                uvl.data[li].uv = (co.y / R["cell"], co.z / H)
        if x > 0:  # lintel strip above the door
            q = [(x, d1, R["door_h"]), (x, d0, R["door_h"]), (x, d0, H), (x, d1, H)]
            ob = quad_mesh("lintel", [q], wl, coll)
            uvl = ob.data.uv_layers[0]
            for li, l in enumerate(ob.data.loops):
                co = ob.data.vertices[l.vertex_index].co
                uvl.data[li].uv = (co.y / R["cell"], co.z / H)
            # door frame: two posts and a head, standing proud of the wall
            fw, fd = 0.07, 0.035
            box("post_a", x - fd, x + 0.12, d0 - fw, d0, 0, R["door_h"] + fw, frame, coll)
            box("post_b", x - fd, x + 0.12, d1, d1 + fw, 0, R["door_h"] + fw, frame, coll)
            box("head", x - fd, x + 0.12, d0 - fw, d1 + fw, R["door_h"], R["door_h"] + fw, frame, coll)
            # the room beyond, a little bluer like the wards
            box("room", x + 0.12, x + 2.5, d0 - 1.0, d1 + 1.0, -0.01, 0.0, room, coll)
            quad_mesh("room_back", [[(x + 2.4, d1 + 1, 0), (x + 2.4, d0 - 1, 0), (x + 2.4, d0 - 1, H), (x + 2.4, d1 + 1, H)]], room, coll)
    quad_mesh("end", [[(-W, Y1, 0), (W, Y1, 0), (W, Y1, H), (-W, Y1, H)]], wl, coll)
    quad_mesh("ceiling", [[(-W, Y0, H), (-W, Y1, H), (W, Y1, H), (W, Y0, H)]], ce, coll, 0.6)
    y = Y0 + 1.0
    while y < Y1:
        quad_mesh(f"lamp{y:.0f}", [[(-0.6, y - 0.3, H - 0.01), (-0.6, y + 0.3, H - 0.01), (0.6, y + 0.3, H - 0.01),
                                    (0.6, y - 0.3, H - 0.01)]], lamp, coll)
        ld = bpy.data.lights.new(f"panel{y:.0f}", "AREA")
        ld.shape = "RECTANGLE"; ld.size, ld.size_y = 1.2, 0.6; ld.energy = R["panel_w"]
        lo = bpy.data.objects.new(ld.name, ld)
        lo.location = (0, y, H - 0.03)
        coll.objects.link(lo)
        y += 4.0
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


def build_doorwall(y):
    """A wall across the path with a 1.1 x 2.1 m door, for the duck pose (seen from the side)."""
    coll = bpy.data.collections.new("doorwall")
    bpy.context.scene.collection.children.link(coll)
    frame = mat("frame2", COL["frame"], rough=0.5)
    wall = mat("wall2", COL["wall"], rough=0.7)
    t = 0.08
    box("dw_left", -3.0, -R["door_w"] / 2, y - t, y + t, 0, R["ceil"], wall, coll)
    box("dw_right", R["door_w"] / 2, 3.0, y - t, y + t, 0, R["ceil"], wall, coll)
    box("dw_top", -R["door_w"] / 2, R["door_w"] / 2, y - t, y + t, R["door_h"], R["ceil"], wall, coll)
    box("dw_head", -R["door_w"] / 2 - 0.07, R["door_w"] / 2 + 0.07, y - t - 0.03, y + t + 0.03, R["door_h"], R["door_h"] + 0.07, frame, coll)
    return coll


def camera(name, loc, target, vfov):
    cd = bpy.data.cameras.new(name)
    cd.sensor_fit = "VERTICAL"; cd.sensor_height = 24.0
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
    print(f"[render] {os.path.basename(path)} {res[0]}x{res[1]} {time.time() - t:.2f}s")


def show(on, colls):
    for c in colls:
        c.hide_render = c not in on


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
    ap.add_argument("--only", default="turn,player,far,face,poses")
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
    world = bpy.data.worlds.new("w"); scn.world = world
    bg = world.node_tree.nodes.get("Background")

    def world_bg(col, strength):
        bg.inputs["Color"].default_value = (*col, 1)
        bg.inputs["Strength"].default_value = strength

    world_bg(R["backdrop"], 1.0)
    backdrop = build_backdrop()
    corridor = build_corridor()
    colls = [backdrop, corridor]
    sz = (R["size"], R["size"])

    if "turn" in only:
        show([backdrop], colls)
        set_action(rig, "idle", 0)
        tgt = (0, -0.15, 1.30)
        d = 8.0
        for name, ang in (("front", 0), ("34", 35), ("side", 90), ("back", 180)):
            a = math.radians(ang)
            loc = (-math.sin(a) * d, -0.15 - math.cos(a) * d, 1.4)
            render(os.path.join(args.out, f"turn_{name}.png"), camera("cam_" + name, loc, tgt, 21.0), sz)

    if "player" in only or "far" in only:
        show([corridor], colls)
        world_bg(COL["wall"], R["ambient"])
        set_action(rig, "idle", 0)
        rig.location.x = R["fig_x"]
        if "player" in only:
            cam = camera("cam_player", (-0.25, -R["dist"], R["eye"]), (-0.25, 10, R["eye"]), R["vfov"])
            render(os.path.join(args.out, "player_view.png"), cam, R["wide"])
            render(os.path.join(args.out, "lowres_view.png"), cam, R["lowres"])
        if "far" in only:
            cam = camera("cam_far", (-0.2, -R["far"], R["eye"]), (-0.2, 10, R["eye"]), R["vfov"])
            render(os.path.join(args.out, "far_view.png"), cam, R["wide"])
            render(os.path.join(args.out, "lowres_far.png"), cam, R["lowres"])
        rig.location.x = 0
        world_bg(R["backdrop"], 1.0)

    if "face" in only:
        show([corridor], colls)
        world_bg(COL["wall"], R["ambient"])
        set_action(rig, "idle", 0)
        hb = rig.matrix_world @ rig.pose.bones["head"].head
        tgt = hb + Vector((0, 0, -0.06))
        cam = camera("cam_face", tgt + Vector((-0.40, -1.25, 0.02)), tgt, 30.0)
        render(os.path.join(args.out, "face.png"), cam, sz)
        world_bg(R["backdrop"], 1.0)

    if "poses" in only:
        dw = build_doorwall(-0.55)
        colls.append(dw)
        cams = {"34": camera("cam_pose34", (-3.9, -6.4, 1.45), (0, -0.25, 1.25), 26.0),
                "side": camera("cam_pose_side", (-9.0, -1.6, 1.5), (0, -1.3, 1.3), 26.0),
                "duck": camera("cam_pose_duck", (-6.2, -3.6, 1.5), (0, -0.5, 1.3), 30.0)}
        paths = []
        for label, act, f, cname in POSES:
            show([backdrop, dw] if label == "duck" else [backdrop], colls)
            set_action(rig, act, f)
            p = os.path.join(args.out, f"pose_{label}.png")
            render(p, cams[cname], (480, 640))
            paths.append(p)
        contact_sheet(paths, os.path.join(args.out, "poses.png"))
        print("[render] poses.png")


if __name__ == "__main__":
    main()
