"""Bake the owner's Mixamo performances onto the Orderly's original mesh and armature."""

import math
from pathlib import Path

import bpy
from mathutils import Quaternion, Vector

SOURCES = {
    "idle": "Zombie Idle.fbx",
    "walk": "Scary Clown Walk.fbx",
    "fast_walk": "Scary Clown Walk (1).fbx",
    "push": "Push.fbx",
    "reach": "Zombie Attack (1).fbx",
    "roar": "Yelling Out.fbx",
    "bellydance": "Bellydancing.fbx",
}

BONES = {
    "hips": "Hips", "spine": "Spine", "spine1": "Spine1", "spine2": "Spine2",
    "neck": "Neck", "head": "Head",
}
for side, word in (("L", "Left"), ("R", "Right")):
    for target, source in (("clavicle", "Shoulder"), ("upperarm", "Arm"),
                           ("forearm", "ForeArm"), ("hand", "Hand"),
                           ("thigh", "UpLeg"), ("shin", "Leg"), ("foot", "Foot")):
        BONES[f"{target}.{side}"] = word + source
ARMS = ("clavicle.", "upperarm.", "forearm.", "hand.")
LEGS = ("thigh.", "shin.", "foot.")


def read_source(path, target, frames, portion=1.0):
    scene = bpy.context.scene
    fps = scene.render.fps
    scene.render.fps = 30  # the downloads are at 30 fps
    previous = set(bpy.data.objects)
    actions = set(bpy.data.actions)
    bpy.ops.import_scene.fbx(filepath=str(path))
    objects = set(bpy.data.objects) - previous
    source, = [obj for obj in objects if obj.type == "ARMATURE"]
    source_bones = {bone.name.split(":")[-1]: bone for bone in source.pose.bones}
    if len(source_bones) != 25 or not any(
        obj.type == "MESH" and obj.name.startswith("Orderly") and len(obj.data.vertices) == 14458
        for obj in objects
    ):
        raise ValueError(f"{path.name} is not from the Orderly's Mixamo rig")
    source_axis = source.matrix_world.to_quaternion()
    rest = {name: bone.bone.matrix_local.to_quaternion() for name, bone in source_bones.items()}
    alignment = {}
    for name, mixamo in BONES.items():
        target_rest = target.data.bones[name].matrix_local.to_quaternion()
        alignment[name] = Quaternion()
        if name.startswith(ARMS):
            # The source rests with arms extended horizontally; ours rests with arms down.
            axis = Vector((0, 1, 0))
            alignment[name] = (target_rest @ axis).rotation_difference(source_axis @ rest[mixamo] @ axis)

    action = source.animation_data.action
    start, end = action.frame_range
    span = (end - start) * portion
    if frames is None:
        # The sequence can only play for the remainder of the ten-second rescue window.
        frames = min(round(span * fps / 30), 9 * fps) + 1
        span = (frames - 1) * 30 / fps
    samples = []
    hips_zero = None
    for index in range(frames):
        frame = start + span * index / (frames - 1)
        scene.frame_set(math.floor(frame), subframe=frame % 1)
        deformation = {}
        rotations = {}
        for bone in target.pose.bones:
            name = bone.name
            parent = deformation[bone.parent.name] if bone.parent else Quaternion()
            target_rest = bone.bone.matrix_local.to_quaternion()
            if name in BONES:
                mixamo = BONES[name]
                posed = source_bones[mixamo].matrix.to_quaternion()
                motion = source_axis @ posed @ rest[mixamo].inverted() @ source_axis.inverted()
                deformation[name] = motion @ alignment[name]
                rotations[name] = (parent @ target_rest).inverted() @ deformation[name] @ target_rest
            else:
                deformation[name] = parent
        hips = source.matrix_world @ source_bones["Hips"].head
        if hips_zero is None:
            hips_zero = hips.copy()
        samples.append((rotations, hips - hips_zero))

    for obj in objects:
        bpy.data.objects.remove(obj, do_unlink=True)
    for act in set(bpy.data.actions) - actions:
        bpy.data.actions.remove(act)
    scene.render.fps = fps
    return samples


def sampled_pose(arm, frame):
    bpy.context.scene.frame_set(frame)
    return {bone.name: (bone.rotation_quaternion.copy(), bone.location.copy(), bone.scale.copy())
            for bone in arm.pose.bones}


def bake_action(arm, name, poses):
    ad = arm.animation_data
    act = bpy.data.actions.new(name)
    ad.action = act
    previous = {}
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    for frame, pose in enumerate(poses, 1):
        for bone in arm.pose.bones:
            rotation, location, scale = pose[bone.name]
            # Quaternion sign changes are the same rotation but interpolate through a flip.
            if bone.name in previous and rotation.dot(previous[bone.name]) < 0.0:
                rotation = -rotation
            previous[bone.name] = rotation
            bone.rotation_quaternion = rotation
            bone.location = location
            bone.scale = scale
            for path in ("rotation_quaternion", "location", "scale"):
                bone.keyframe_insert(path, frame=frame, group=bone.name)
    act.use_fake_user = True
    track = ad.nla_tracks.new()
    track.name = name
    track.strips.new(name, 1, act)
    track.mute = True
    ad.action = None


def base_frames(arm, name):
    action = bpy.data.actions[name]
    arm.animation_data.action = action
    start, finish = (round(frame) for frame in action.frame_range)
    frames = [sampled_pose(arm, frame) for frame in range(start, finish + 1)]
    arm.animation_data.action = None
    return frames


def bake(arm, directory):
    directory = Path(directory)
    idle = base_frames(arm, "idle")
    walk = base_frames(arm, "walk")
    reach = base_frames(arm, "reach")
    sources = {
        name: read_source(directory / filename, arm, size, portion)
        for name, filename, size, portion in (
            ("idle", SOURCES["idle"], len(idle), 1.0),
            ("walk", SOURCES["walk"], len(walk), 1.0),
            ("fast_walk", SOURCES["fast_walk"], len(walk), 1.0),
            ("push", SOURCES["push"], len(walk), 1.0),
            ("reach", SOURCES["reach"], len(reach), 0.65),
            ("roar", SOURCES["roar"], 20, 0.54),
            ("bellydance", SOURCES["bellydance"], None, 1.0),
        )
    }

    for name, base in (("idle", idle), ("walk", walk), ("reach", reach)):
        poses = []
        for index, baseline in enumerate(base):
            mixed = baseline.copy()
            for bone, motion in sources[name][index][0].items():
                original, location, scale = baseline[bone]
                if name == "idle":
                    # Let the body twitch without losing the clasp or planted feet.
                    weight = 0.0 if bone.startswith(LEGS + ARMS) else 0.35
                elif name == "walk":
                    if bone.startswith(ARMS):
                        motion = motion.slerp(sources["push"][index][0][bone], 0.4)
                    else:
                        motion = motion.slerp(sources["fast_walk"][index][0][bone], 0.2)
                    weight = 0.18 if bone.startswith(ARMS) else 0.25
                else:
                    # The authored start and final stretched arm join gameplay's held/bend poses.
                    weight = 0.0 if bone.startswith(LEGS) else 0.22 * math.sin(math.pi * index / (len(base) - 1))
                mixed[bone] = original.slerp(motion, weight), location, scale
            poses.append(mixed)
        bake_action(arm, f"mixamo_{name}", poses)

    neutral = {bone.name: (Quaternion(), Vector((0, 0, 0)), Vector((1, 1, 1)))
               for bone in arm.pose.bones}
    first = sources["roar"][0][0]
    poses = []
    for rotations, _ in sources["roar"]:
        pose = neutral.copy()
        for bone, motion in rotations.items():
            if bone in ("spine", "spine1", "spine2", "neck", "head"):
                pose[bone] = first[bone].inverted() @ motion, *neutral[bone][1:]
        poses.append(pose)
    bake_action(arm, "mixamo_roar", poses)

    poses = []
    hips_axes = arm.data.bones["hips"].matrix_local.to_quaternion().inverted()
    for rotations, travel in sources["bellydance"]:
        pose = neutral.copy()
        for bone, motion in rotations.items():
            # Moderate the full-length gestures for the narrow Clinic corridors.
            rotation = Quaternion().slerp(motion, 0.86) if bone.startswith(ARMS) else motion
            pose[bone] = rotation, *neutral[bone][1:]
        # Keep the performance over the gameplay body. Let only the small hip shifts through.
        shift = Vector(tuple(max(-0.12, min(0.12, v * 0.55)) for v in travel))
        pose["hips"] = rotations["hips"], hips_axes @ shift, neutral["hips"][2]
        poses.append(pose)
    bake_action(arm, "bellydance", poses)
