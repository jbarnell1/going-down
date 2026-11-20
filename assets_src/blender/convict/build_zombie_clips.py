"""The Reactor's four crawl and run: two Mixamo takes the owner downloaded, retargeted onto the crew rig.

The raw Mixamo files never go into git (Mixamo's terms: CREDITS.md, assets_src/inbox/README.md). Put
"Zombie Crawl.fbx" and "Zombie Running.fbx" in assets_src/inbox/mixamo/zombie/ (ignored by git), then from the
repository root:

  tools/blender/blender-5.3.0-windows-x64/blender.exe -b --factory-startup --disable-autoexec --python-exit-code 1 --python assets_src/blender/convict/build_zombie_clips.py
  node assets_src/blender/convict/zombie_clips.mjs

The first reads the takes as data (auto-execution off), maps every bone onto the 34-bone crew skeleton of
godot/assets/entities/crewmate.glb in each bone's rest frame, takes the travel out of both (the game moves the
figure), closes each loop and lifts the hips wherever the body would go under the floor; it writes
assets_src/inbox/crew-zombie-actions.glb and crew-zombie-clips.json (frame ranges and measured speeds). The second
bakes the two clips into the game model godot/assets/station/crew_zombie.glb.

First made on 18 Nov against the wasted body of the recovered tape (the same skeleton); this version samples the
floor against the crewmate's own body.
"""
from pathlib import Path
import importlib.util
import json
import sys

import bpy
import numpy as np
from mathutils import Quaternion

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / 'godot' / 'assets' / 'entities' / 'crewmate.glb'
INBOX = ROOT / 'assets_src' / 'inbox'
spec = importlib.util.spec_from_file_location('crew_pipeline', ROOT / 'assets_src/blender/convict/build_crewmate.py')
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)
TAKES = [
    ('zombie_run', 'Zombie Running.fbx', 'move'),
    ('zombie_crawl', 'Zombie Crawl.fbx', 'move'),
]

def name_without_namespace(name):
    return name.rsplit(':', 1)[-1]

def sample_take(source, target):
    scene = bpy.context.scene
    start, end = (round(frame) for frame in source.animation_data.action.frame_range)
    n = end - start + 1
    source_bones = {name_without_namespace(b.name): b for b in source.pose.bones}
    result = {
        name: {'q': np.tile([1.0, 0, 0, 0], (n, 1)), 'l': np.zeros((n, 3))}
        for name in target.arm.pose.bones.keys()
    }
    mappings = []
    for name in result:
        src = source_bones.get(name_without_namespace(name))
        if src is None:
            continue
        dst = target.arm.pose.bones[name]
        src_rest = (source.matrix_world @ src.bone.matrix_local).to_quaternion()
        dst_rest = (target.arm.matrix_world @ dst.bone.matrix_local).to_quaternion()
        axis_map = dst_rest.inverted() @ src_rest
        mappings.append((name, src, axis_map, axis_map.inverted()))
    src_hips = source_bones['Hips']
    source_hips = np.empty((n, 3))
    source_rest = source.matrix_world @ src_hips.bone.head_local
    for i, frame in enumerate(range(start, end + 1)):
        scene.frame_set(frame)
        source_hips[i] = source.matrix_world @ src_hips.head
        for name, src, axis_map, inverse in mappings:
            result[name]['q'][i] = axis_map @ src.rotation_quaternion @ inverse
    for track in result.values():
        track['q'] = pipeline.continuous(track['q'])
    return result, source_hips, source_rest, len(mappings)

def stabilize_floor(target, mesh, clip, kind):
    name = '__floor_test__'
    frames = len(clip['Hips']['q'])
    action = target.write(name, clip)
    samples = target.sample(mesh, frames)
    height = samples[:, 0]
    if kind == 'move':
        # Recompute each frame against the crewmate's body, rather than the source feet.
        lift = pipeline.smooth_max(np.maximum(-height - 0.003, 0), True)
    else:
        lift = pipeline.smooth_max(np.maximum(-height - 0.003, 0), kind == 'loop')
    hips = target.hips_world(clip)
    hips[:, 2] += lift
    target.set_hips_world(clip, hips)
    bpy.data.actions.remove(action)
    return float(np.min(height + lift))

def main(downloads):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(SOURCE))
    scene = bpy.context.scene
    scene.render.fps = 30
    arm = next(o for o in scene.objects if o.type == 'ARMATURE')
    mesh = bpy.data.objects['Crewmate_body']
    target = pipeline.Rig(arm)
    original_walk = bpy.data.actions['walk']
    arm.animation_data_clear()
    arm.animation_data_create()
    arm.animation_data.action = original_walk
    arm.animation_data.action_slot = original_walk.slots[0]
    walk, walk_hips, _walk_rest, _mapped = sample_take(arm, target)
    source_actions = list(bpy.data.actions)
    # Keep the imported rest skin, meshes and materials intact.
    arm.animation_data_clear()
    for action in source_actions:
        bpy.data.actions.remove(action)
    for bone in arm.pose.bones:
        bone.rotation_mode = 'QUATERNION'
        bone.matrix_basis.identity()
    actions = set()
    index = {}
    for name, filename, kind in TAKES:
        path = downloads / filename
        if not path.is_file():
            raise FileNotFoundError(path.name)
        imported = pipeline.import_fbx(str(path))
        source = next(o for o in imported if o.type == 'ARMATURE')
        clip, source_hips, rest, mapped = sample_take(source, target)
        travel = source_hips[-1] - source_hips[0]
        n = len(source_hips)
        hips = target.t + (source_hips - rest) * (target.t[2] / rest.z)
        hips[:, :2] -= hips[0, :2].copy()
        if kind == 'move':
            hips[:, :2] -= np.linspace(0, 1, n)[:, None] * hips[-1, :2].copy()
        target.set_hips_world(clip, hips)
        if kind in ['move', 'loop']:
            pipeline.close_loop(clip, hips_xy_too=True)
        source_bones = len(source.data.bones)
        pipeline.remove_objects(imported)
        floor = stabilize_floor(target, mesh, clip, kind)
        action = target.write(name, clip)
        actions.add(action)
        duration = (n - 1) / scene.render.fps
        index[name] = {
            'take': filename, 'fps': scene.render.fps, 'frames': [0, n - 1],
            'duration_seconds': duration, 'kind': kind,
            'mapped_bones': mapped, 'source_bones': source_bones,
            'source_travel_m': np.round(travel, 4).tolist(),
            'speed_mps': round(float(np.linalg.norm(travel[:2])) / duration, 4) if kind == 'move' else 0,
            'mesh_floor_m': round(floor, 4),
        }
        print('BAKED', name, index[name], flush=True)
    arm.animation_data.action = None
    baked_names = set(index)
    for action in list(bpy.data.actions):
        if action.name not in baked_names:
            bpy.data.actions.remove(action)
    INBOX.mkdir(parents=True, exist_ok=True)
    (INBOX / 'crew-zombie-clips.json').write_text(json.dumps(index, indent=2) + '\n', encoding='utf8')
    bpy.ops.export_scene.gltf(filepath=str(INBOX / 'crew-zombie-actions.glb'),
         export_format='GLB', export_animation_mode='ACTIONS', export_yup=True,
         export_anim_single_armature=True, export_force_sampling=True, export_def_bones=False)

if __name__ == '__main__':
    takes = Path(sys.argv[sys.argv.index('--') + 1]) if '--' in sys.argv else INBOX / 'mixamo' / 'zombie'
    main(takes)
