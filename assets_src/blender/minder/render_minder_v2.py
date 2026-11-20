"""Review renders of the Minder's second figure (MN1), plain grey, from the built game file.

  blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/minder/render_minder_v2.py -- --out DIR [--glb PATH]

Imports godot/assets/entities/minder_v2.glb into an empty scene and renders with Workbench (flat grey, no
textures): the rest pose front, side and top with the bones drawn through a see-through body (orange
sticks from each joint to the next, joints as dots), then posed frames: prowl (two), run (two), cover,
look and catch. Writes minder-*.png into DIR.
"""
import bpy, sys, os, math, argparse
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SIZE = 900

# (file, clip or None for rest, frame after import (actions start at 0), camera, bones drawn)
SHOTS = [
    ("minder-rest-front", None, 0, "front", True),
    ("minder-rest-side", None, 0, "side", True),
    ("minder-rest-top", None, 0, "top", True),
    ("minder-prowl-1", "prowl", 0, "34", False),
    ("minder-prowl-2", "prowl", 5, "34", False),
    ("minder-prowl-side", "prowl", 3, "side", False),
    ("minder-run-1", "run", 0, "side", False),
    ("minder-run-2", "run", 8, "side", False),
    ("minder-cover", "cover", 30, "34", False),
    ("minder-look", "look", 60, "34", False),
    ("minder-catch", "catch", 36, "side", False),
    ("minder-catch-end", "catch", 90, "34", False),
    ("minder-walk", "walk", 10, "34", False),
    ("minder-stand", "stand", 0, "34", False),
    ("minder-straighten", "straighten", 36, "side", False),
    ("minder-slump", "slump", 30, "34", False),
    ("minder-sweep", "sweep", 22, "34", False),
    ("minder-catch-eye", "catch", 90, "eye", False),
    ("minder-catch-lunge-eye", "catch", 24, "eye", False),
    # textured (the colour map, plain studio light)
    ("minder-tex-face", "stand", 0, "face", False, True),
    ("minder-tex-front", "stand", 0, "front", False, True),
    ("minder-tex-prowl-side", "prowl", 15, "side", False, True),
    ("minder-tex-prowl-dip-side", "prowl", 5, "side", False, True),
    ("minder-tex-catch-eye08", "catch", 90, "eye08", False, True),
    ("minder-tex-walk-34", "walk", 34, "34", False, True),
    ("minder-tex-cover", "cover", 30, "34", False, True),
    ("minder-tex-catch-eye", "catch", 90, "eye", False, True),
    ("minder-tex-run", "run", 4, "side", False, True),
]


def find(kind):
    return next(o for o in bpy.data.objects if o.type == kind and (kind != "MESH" or o.find_armature() is not None))


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
        act = next(a for a in bpy.data.actions if a.name.split("-loop")[0] == name)
        ad.action = act
        if act.slots and getattr(ad, "action_slot", None) is None:
            ad.action_slot = act.slots[0]
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()


def bone_sticks(rig):
    """Orange sticks between posed joints (head to each child's head; a leaf runs on along its own axis)."""
    for o in [o for o in bpy.data.objects if o.name.startswith("BoneStick")]:
        bpy.data.objects.remove(o, do_unlink=True)
    verts, faces = [], []
    mw = rig.matrix_world

    def stick(a, b, r):
        d = (b - a)
        if d.length < 1e-4:
            return
        z = d.normalized()
        x = z.cross(Vector((0, 0, 1)))
        if x.length < 1e-3:
            x = z.cross(Vector((1, 0, 0)))
        x.normalize()
        y = z.cross(x)
        base = len(verts)
        for k in range(4):
            ang = k * math.pi / 2
            verts.append(a + (x * math.cos(ang) + y * math.sin(ang)) * r)
        for k in range(4):
            ang = k * math.pi / 2
            verts.append(b + (x * math.cos(ang) + y * math.sin(ang)) * r * 0.4)
        for k in range(4):
            faces.append((base + k, base + (k + 1) % 4, base + 4 + (k + 1) % 4, base + 4 + k))

    def dot(c, r):
        base = len(verts)
        for s in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)):
            verts.append(c + Vector(s) * r)
        for f in ((0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)):
            faces.append(tuple(base + i for i in f))

    for pb in rig.pose.bones:
        h = mw @ pb.head
        kids = list(pb.children)
        if kids:
            for c in kids:
                stick(h, mw @ c.head, 0.012)
        else:
            stick(h, h + (mw.to_3x3() @ (pb.matrix.to_3x3() @ Vector((0, 1, 0)))).normalized() * 0.07, 0.01)
        dot(h, 0.022)
    me = bpy.data.meshes.new("BoneSticks")
    me.from_pydata([tuple(v) for v in verts], [], faces)
    ob = bpy.data.objects.new("BoneSticks", me)
    m = bpy.data.materials.get("Sticks") or bpy.data.materials.new("Sticks")
    m.diffuse_color = (1.0, 0.45, 0.05, 1.0)
    me.materials.append(m)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def camera(kind, centre):
    cam = bpy.context.scene.camera
    cam.data.type = "ORTHO" if kind in ("front", "side", "top") else "PERSP"
    cam.data.ortho_scale = 2.0
    cam.data.lens = 18 if kind == "eye08" else 40
    off = {"front": Vector((0, -6, 0)), "side": Vector((6, 0, 0)), "top": Vector((0, 0, 6)),
           "34": Vector((1.9, -2.3, 0.9)), "eye": Vector((0, -2.6, 1.0)), "face": Vector((0.15, -1.1, 0.25)),
           "eye08": Vector((0, -0.8, 0.15))}[kind]
    cam.location = centre + off
    d = centre - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y" if kind != "top" else "Y").to_euler()
    if kind == "top":
        cam.rotation_euler = (0, 0, 0)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--glb", default=os.path.join(ROOT, "godot", "assets", "entities", "minder_v2.glb"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    args = ap.parse_args(argv)
    only = set(x for x in args.only.split(",") if x)
    os.makedirs(args.out, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.glb)
    rig = find("ARMATURE")
    body = find("MESH")
    for m in body.data.materials:
        # plain grey; the card a paler grey so the face can be found
        m.diffuse_color = (0.85, 0.85, 0.82, 1.0) if "mask" in m.name.lower() else (0.5, 0.5, 0.5, 1.0)
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_WORKBENCH"
    scn.render.resolution_x = scn.render.resolution_y = SIZE
    sh = scn.display.shading
    sh.light = "STUDIO"
    sh.color_type = "MATERIAL"
    sh.show_shadows = False
    sh.show_cavity = True
    sh.show_specular_highlight = False   # matte, as the game draws it
    sh.background_type = "VIEWPORT"
    sh.background_color = (0.45, 0.45, 0.46)
    scn.world = bpy.data.worlds.new("w")
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scn.collection.objects.link(cam)
    scn.camera = cam
    # a floor line: a thin dark plate at y 0
    bpy.ops.mesh.primitive_plane_add(size=6, location=(0, 0, -0.002))
    floor = bpy.context.active_object
    fm = bpy.data.materials.new("Floor")
    fm.diffuse_color = (0.36, 0.36, 0.37, 1.0)
    floor.data.materials.append(fm)

    for shot in SHOTS:
        name, clip, frame, view, bones = shot[:5]
        tex = len(shot) > 5 and shot[5]
        if only and name not in only:
            continue
        sh.color_type = "TEXTURE" if tex else "MATERIAL"
        set_action(rig, clip, frame)
        sticks = bone_sticks(rig) if bones else None
        sh.show_xray = bones
        sh.xray_alpha = 0.35
        floor.hide_render = view in ("front", "side", "top") and bones
        centre = {"top": Vector((0, 0, 0)), "eye": Vector((0, -0.6, 0.6)), "face": Vector((0, -0.7, 0.8)), "eye08": Vector((0, -0.8, 1.45))}.get(view, Vector((0, 0, 0.6)))
        camera(view, centre)
        scn.render.filepath = os.path.join(args.out, name + ".png")
        bpy.ops.render.render(write_still=True)
        print("[render_v2] wrote", scn.render.filepath, flush=True)
        if sticks:
            bpy.data.objects.remove(sticks, do_unlink=True)

    if not only or "minder-dark-torch" in only:
        dark(args.out, rig, body)


def dark(out, rig, body):
    """480x270, the room black, a torch from 4 m in front at eye height (1.6 m): the body barely there, the
    face plate glowing at its count-dark energy (minder_view.gd MASK_DARK_E = 1.0)."""
    scn = bpy.context.scene
    for eng in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scn.render.engine = eng
            break
        except TypeError:
            continue
    scn.render.resolution_x, scn.render.resolution_y = 480, 270
    w = scn.world
    w.use_nodes = True
    bg = w.node_tree.nodes.get("Background")
    if bg:
        bg.inputs["Color"].default_value = (0, 0, 0, 1)
        bg.inputs["Strength"].default_value = 0.0
    for m in body.data.materials:
        if "mask" in m.name.lower() and m.node_tree:
            for n in m.node_tree.nodes:
                if n.type == "BSDF_PRINCIPLED":
                    n.inputs["Emission Strength"].default_value = 1.0
    set_action(rig, "stand", 0)
    cam = scn.camera
    cam.data.type = "PERSP"
    cam.data.lens = 24
    cam.location = Vector((0, -0.7 - 4.0, 1.6))
    cam.rotation_euler = (Vector((0, -0.7, 0.75)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    ld = bpy.data.lights.new("Torch", "SPOT")
    ld.energy = 120.0
    ld.spot_size = math.radians(28)
    ld.spot_blend = 0.4
    torch = bpy.data.objects.new("Torch", ld)
    torch.location = cam.location + Vector((0.15, 0, -0.1))
    torch.rotation_euler = cam.rotation_euler
    scn.collection.objects.link(torch)
    scn.render.filepath = os.path.join(out, "minder-dark-torch.png")
    bpy.ops.render.render(write_still=True)
    print("[render_v2] wrote", scn.render.filepath, flush=True)


if __name__ == "__main__":
    main()
