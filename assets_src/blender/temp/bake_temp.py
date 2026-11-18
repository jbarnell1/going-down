"""Build the game Temp from the original meshes and the six owner-supplied Mixamo FBXs.

Invoke Blender in background with --disable-autoexec --python-exit-code 1
--python assets_src/blender/temp/bake_temp.py -- <directory containing the six FBXs>
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector, kdtree

HERE = Path(__file__).resolve().parent
OUTPUT = HERE.parents[2] / "godot/assets/entities/temp.glb"
PREFIX = "mixamorig:"
FPS = 30
CLIPS = {
    "walk": ("Walking.fbx", 1, 50),
    "chase": ("Walking (1).fbx", 1, 64),
    "idle": ("Standing W_Briefcase Idle.fbx", 1, 419),
    "look": ("Look Around.fbx", 1, 135),
    "reach": ("Button Pushing.fbx", 17, 38),
    "bend": ("Zombie Attack.fbx", 31, 42),
}


def imported(operator, **kwargs):
    before = set(bpy.data.objects)
    operator(**kwargs)
    return set(bpy.data.objects) - before


def rig_fingerprint(arm):
    return [(b.name, tuple(round(x, 5) for x in arm.matrix_world @ b.head_local))
            for b in arm.data.bones]


def pose_bone(arm, name):
    return arm.pose.bones[PREFIX + name]


def read_clip(path, first, last, moving):
    scene = bpy.context.scene
    objects = imported(bpy.ops.import_scene.fbx, filepath=str(path), use_image_search=False)
    arm, = [ob for ob in objects if ob.type == "ARMATURE"]
    mesh, = [ob for ob in objects if ob.type == "MESH"]
    assert len(mesh.data.vertices) == 2398 and len(arm.data.bones) == 65, path.name
    action = arm.animation_data.action
    assert action.frame_range[0] <= first < last <= action.frame_range[1], path.name
    assert scene.render.fps == FPS, path.name
    hips = pose_bone(arm, "Hips")
    scene.frame_set(first)
    start = arm.matrix_world @ hips.head
    scene.frame_set(last)
    travel = arm.matrix_world @ hips.head - start
    hips_axes = (arm.matrix_world @ hips.bone.matrix_local).to_3x3().inverted()
    frames = []
    for f in range(first, last + 1):
        scene.frame_set(f)
        # Remove travel along the authored path, leaving vertical motion and lateral weight shifts.
        center = travel * ((f - first) / (last - first)) if moving else Vector()
        center.y += start.y
        center.x += start.x
        center.z = 0
        frames.append((hips.location.copy() - hips_axes @ center,
                       {b.name: b.rotation_quaternion.copy() for b in arm.pose.bones}))
    if moving:
        # The copy of the first source frame at the end closes the cycle exactly.
        frames[-1] = (frames[0][0].copy(), {k: q.copy() for k, q in frames[0][1].items()})
    return objects, arm, mesh, frames


def weights_from_round_trip(arm, reference):
    body, = imported(bpy.ops.import_scene.gltf, filepath=str(HERE / "temp_tpose.glb"))
    body.name = "TempBody"
    tree = kdtree.KDTree(len(reference.data.vertices))
    for v in reference.data.vertices:
        tree.insert(reference.matrix_world @ v.co, v.index)
    tree.balance()
    groups = [body.vertex_groups.new(name=g.name) for g in reference.vertex_groups]
    head = body.vertex_groups[PREFIX + "Head"]
    paper = {i for p in body.data.polygons
             if body.material_slots[p.material_index].material.name.startswith("temp_face_sheet")
             for i in p.vertices}
    worst = 0.0
    for v in body.data.vertices:
        world = body.matrix_world @ v.co
        _, index, distance = tree.find(world)
        worst = max(worst, distance)
        # Bind the paper, its fasteners and nearby face/hair rigidly above the collar.
        if v.index in paper or world.z > 1.50:
            head.add([v.index], 1.0, "REPLACE")
        else:
            weights = reference.data.vertices[index].groups
            total = sum(g.weight for g in weights)
            assert total > 0.0, v.index
            for g in weights:
                groups[g.group].add([v.index], g.weight / total, "REPLACE")
    assert worst < 0.001, f"Mixamo removed or relocated Temp vertices ({worst:.4f} m)"
    matrix = body.matrix_world.copy()
    body.parent = arm
    body.matrix_world = matrix
    skin = body.modifiers.new("Temp skin", "ARMATURE")
    skin.object = arm
    return body


def prop(arm, mesh_name, hand_name, offset, yaw):
    item, = imported(bpy.ops.import_scene.gltf, filepath=str(HERE / f"{mesh_name}.glb"))
    item.name = mesh_name
    hand = pose_bone(arm, hand_name)
    grip = arm.matrix_world @ hand.bone.head_local + Vector(offset)
    world = Matrix.Translation(grip) @ Matrix.Rotation(yaw, 4, "Z")
    item.parent = arm
    item.parent_type = "BONE"
    item.parent_bone = hand.name
    bpy.context.view_layer.update()
    item.matrix_world = world
    return item


def local_turn(arm, bone, axis, amount):
    basis = (arm.matrix_world @ bone.bone.matrix_local).to_quaternion()
    return Quaternion(basis.inverted() @ Vector(axis), amount)


def key_clip(arm, name, frames):
    arm.animation_data.action = None
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    arm.animation_data.action = action
    arm.animation_data.action_slot = action.slots.new('OBJECT', arm.name)
    scene = bpy.context.scene
    scene.frame_end = len(frames)
    hips = pose_bone(arm, "Hips")
    prior = {}
    for frame, (location, rotations) in enumerate(frames, 1):
        scene.frame_set(frame)
        hips.location = location
        hips.keyframe_insert("location", frame=frame, group=hips.name)
        for bone in arm.pose.bones:
            q = rotations[bone.name].copy()
            # The props stay gripped even when the clip has an open hand or points one finger.
            for side, sign in (("Left", 1), ("Right", -1)):
                if bone.name.startswith(PREFIX + side + "Hand"):
                    finger = bone.name.rsplit("Hand", 1)[-1]
                    if finger and finger[-1] in "123" and not finger.startswith("Thumb"):
                        q = local_turn(arm, bone, (0, 1, 0), sign * math.radians(40))
            if bone.name in prior:
                q.make_compatible(prior[bone.name])
            prior[bone.name] = q
            bone.rotation_quaternion = q
            bone.keyframe_insert("rotation_quaternion", frame=frame, group=bone.name)
    print(f"[Temp] {name}: {len(frames)} frames", flush=True)


def main(source):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    arm = None
    frames = {}
    for name, (filename, first, last) in CLIPS.items():
        objects, clip_arm, clip_mesh, frames[name] = read_clip(
            source / filename, first, last, name in ("walk", "chase"))
        if arm is None:
            arm = clip_arm
            reference = clip_mesh
            fingerprint = rig_fingerprint(arm)
        else:
            assert rig_fingerprint(clip_arm) == fingerprint, filename
            for ob in objects:
                bpy.data.objects.remove(ob, do_unlink=True)
    arm.animation_data_clear()
    arm.animation_data_create()
    arm.name = "TempRig"
    for bone in arm.pose.bones:
        bone.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()
    # Normalize the armature object to the mesh's axes before skinning. This also makes Godot's
    # imported mesh bounds upright, including when only the paper is in the frustum.
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    body = weights_from_round_trip(arm, reference)
    bpy.data.objects.remove(reference, do_unlink=True)
    staple = prop(arm, "temp_stapler", "RightHand", (-0.065, 0, -0.020), -math.pi / 2)
    notes = prop(arm, "temp_notes", "LeftHand", (0.068, 0, -0.022), math.pi / 2)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    for name, samples in frames.items():
        key_clip(arm, name, samples)
    arm.animation_data.action = None
    for bone in arm.pose.bones:
        bone.matrix_basis = Matrix.Identity(4)
    bpy.context.scene.frame_set(1)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in (arm, body, staple, notes):
        ob.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.context.scene.frame_end = max(map(len, frames.values()))
    bpy.context.scene.render.fps = FPS
    bpy.ops.export_scene.gltf(
        filepath=str(OUTPUT), export_format="GLB", use_selection=True,
        export_animation_mode="ACTIONS", export_force_sampling=True,
        export_optimize_animation_size=True, export_def_bones=False, export_all_influences=True,
    )


if __name__ == "__main__":
    main(Path(sys.argv[sys.argv.index("--") + 1]))
