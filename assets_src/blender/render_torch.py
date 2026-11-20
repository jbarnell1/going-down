"""A built figure in the dark, as a player sees it: 480x270, the room black, lit only by a torch held at the
camera, 3.5 m in front of the figure at eye height (1.6 m; --eye for a crouching or downed player). For
reviewing whether a figure's look reads at the game's low resolution in a dim room.

  blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/render_torch.py -- \
      --glb godot/assets/entities/orderly_v2.glb --clip mixamo_idle --aim 1.9 --out PATH.png

The clip's first frame is drawn (--frame to pick another; actions start at 0 after import). Back faces are
culled where the model's material says so, as in the game. Glowing materials keep the model's own glow.
"""
import argparse
import math
import os
import sys

import bpy
from mathutils import Vector


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--glb", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--clip", default="")
    ap.add_argument("--frame", type=int, default=0)
    ap.add_argument("--dist", type=float, default=3.5)
    ap.add_argument("--aim", type=float, default=1.2, help="height the camera looks at (m)")
    ap.add_argument("--eye", type=float, default=1.6, help="the camera's height (m)")
    ap.add_argument("--energy", type=float, default=120.0, help="the torch (W)")
    args = ap.parse_args(argv)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(args.glb))
    rig = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    ad = rig.animation_data or rig.animation_data_create()
    for t in ad.nla_tracks:
        t.mute = True
    if args.clip:
        act = next(a for a in bpy.data.actions if a.name.split("-loop")[0] == args.clip)
        ad.action = act
        if act.slots and getattr(ad, "action_slot", None) is None:
            ad.action_slot = act.slots[0]
    scn = bpy.context.scene
    scn.frame_set(args.frame)
    for eng in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scn.render.engine = eng
            break
        except TypeError:
            continue
    scn.render.resolution_x, scn.render.resolution_y = 480, 270
    scn.world = bpy.data.worlds.new("dark")
    scn.world.use_nodes = True
    bg = scn.world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (0, 0, 0, 1)
    bg.inputs["Strength"].default_value = 0.0
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    scn.collection.objects.link(cam)
    scn.camera = cam
    cam.data.lens = 24
    cam.location = Vector((0.0, -args.dist, args.eye))  # the figures face -Y
    cam.rotation_euler = (Vector((0.0, 0.0, args.aim)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    ld = bpy.data.lights.new("Torch", "SPOT")
    ld.energy = args.energy
    ld.spot_size = math.radians(28)
    ld.spot_blend = 0.4
    torch = bpy.data.objects.new("Torch", ld)
    torch.location = cam.location + Vector((0.15, 0, -0.1))
    torch.rotation_euler = cam.rotation_euler
    scn.collection.objects.link(torch)
    scn.render.filepath = os.path.abspath(args.out)
    bpy.ops.render.render(write_still=True)
    print("[torch] wrote", scn.render.filepath, flush=True)


if __name__ == "__main__":
    main()
