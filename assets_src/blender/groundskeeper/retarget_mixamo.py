"""Bake Mixamo takes on the existing Groundskeeper bones, leaving game timing and props in Blender."""

from math import floor, pi, sin, sqrt

import bpy
from mathutils import Quaternion, Vector


# Each range is a fraction of the source take. Use the bite's forward grab
# and stop before its recoil; retain the reach's long extension.
TAKES = {
    "listen": ("Looking Around (1).fbx", 0., 1.),
    "walk": ("Injured Run.fbx", 0., 1.),
    "tilt": ("Agony.fbx", .08, .88),
    "sweep": ("Looking Around.fbx", .08, .72),
    "lean": ("Reaching Out.fbx", .16, .94),
    "snatch": ("Vampiric Bite.fbx", .14, .44),
}
BONES = {"Hips": "Hips", "Spine": "Spine", "Chest": "Spine2", "Neck": "Neck", "Head": "Head"}
ARMS = ("UpperArm.", "Forearm.", "Hand.")
LEGS = ("Thigh.", "Shin.", "Foot.")
for side, prefix in (("L", "Left"), ("R", "Right")):
    for target, mixamo in (("UpperArm", "Arm"), ("Forearm", "ForeArm"), ("Hand", "Hand"),
                           ("Thigh", "UpLeg"), ("Shin", "Leg"), ("Foot", "Foot")):
        BONES[f"{target}.{side}"] = prefix + mixamo

# Weight the parts that give each take its silhouette. Grounded clips keep
# the Blender leg solve, and the lean still ends at the authored recover pose.
MIX = {
    "listen": (.24, .14, 0.),
    "walk": (.68, .42, .64),
    "tilt": (.72, 0., 0.),
    "sweep": (.42, .45, 0.),
    "lean": (.26, .58, 0.),
    "snatch": (.52, .46, 0.),
}
Y = Vector((0, 1, 0))


def read_take(path, target, count, first, last):
    scene = bpy.context.scene
    previous_objects = set(bpy.data.objects)
    previous_actions = set(bpy.data.actions)
    bpy.ops.import_scene.fbx(filepath=str(path))
    imported = set(bpy.data.objects) - previous_objects
    source, = [obj for obj in imported if obj.type == "ARMATURE"]
    source_bones = {bone.name.split(":")[-1]: bone for bone in source.pose.bones}
    if len(source_bones) != 33 or not set(BONES.values()) <= source_bones.keys():
        raise ValueError(f"{path.name}: expected the Groundskeeper Mixamo skeleton")
    if any(obj.type == "MESH" and
           (not obj.name.startswith("Groundskeeper_T_Pose") or len(obj.data.vertices) != 1378)
           for obj in imported):
        raise ValueError(f"{path.name}: mesh does not match the Groundskeeper upload")

    axis = source.matrix_world.to_quaternion()
    source_rest = {name: axis @ bone.bone.matrix_local.to_quaternion() for name, bone in source_bones.items()}
    target_rest = {bone.name: bone.bone.matrix_local.to_quaternion() for bone in target.pose.bones}
    alignment = {
        name: (target_rest[name] @ Y).rotation_difference(source_rest[mixamo] @ Y)
        if name.startswith(ARMS) else Quaternion() for name, mixamo in BONES.items()
    }
    start, end = source.animation_data.action.frame_range
    samples = []
    for index in range(count):
        phase = index / (count - 1)
        if path.name == TAKES["snatch"][0]:
            # The bite reaches forward at roughly 30% of the downloaded take.
            # Put that reach on frame 6, when the game closes the blades.
            impact = 6 / (count - 1)
            fraction = (first + (.30 - first) * phase / impact if phase <= impact else
                        .30 + (last - .30) * (phase - impact) / (1. - impact))
        else:
            fraction = first + (last - first) * phase
        frame = start + (end - start) * fraction
        scene.frame_set(floor(frame), subframe=frame % 1)
        world = {}
        rotations = {}
        for bone in target.pose.bones:
            name = bone.name
            parent = world[bone.parent.name] if bone.parent else Quaternion()
            world[name] = parent
            if name in BONES:
                mixamo = BONES[name]
                world[name] = axis @ source_bones[mixamo].matrix.to_quaternion() @ source_rest[mixamo].inverted()
                world[name] = world[name] @ alignment[name]
                basis = target_rest[name]
                rotations[name] = (parent @ basis).inverted() @ world[name] @ basis
        head = source_bones["Head"]
        head_basis = axis @ head.matrix.to_quaternion()
        wrists = {}
        for side, prefix in (("L", "Left"), ("R", "Right")):
            displacement = source.matrix_world.to_3x3() @ (source_bones[prefix + "Hand"].head - head.head)
            wrists[side] = head_basis.inverted() @ displacement
        samples.append((rotations, wrists))

    for obj in imported:
        bpy.data.objects.remove(obj, do_unlink=True)
    for action in set(bpy.data.actions) - previous_actions:
        bpy.data.actions.remove(action)
    return samples


def load_takes(directory, rig, clips, fps):
    return {name: read_take(directory / file, rig, round(clips[name] * fps) + 1, first, last)
            for name, (file, first, last) in TAKES.items()}


def aim(bone, direction, weight):
    local = bone.matrix.to_quaternion().inverted() @ direction
    adjustment = Y.rotation_difference(local)
    original = bone.rotation_quaternion
    bone.rotation_quaternion = original.slerp(original @ adjustment, weight)
    bpy.context.view_layer.update()


def aim_limb(upper, lower, target, bend, weight):
    delta = target - upper.head
    length = min(delta.length, upper.length + lower.length - .001)
    direction = delta.normalized()
    bend = (bend - bend.dot(direction) * direction).normalized()
    along = (upper.length ** 2 + length ** 2 - lower.length ** 2) / (2 * length)
    middle = upper.head + direction * along + bend * sqrt(max(0, upper.length ** 2 - along ** 2))
    aim(upper, middle - upper.head, weight)
    aim(lower, target - lower.head, weight)


def grasp_head(rig, wrists, weight):
    """Match the head-relative contact after the source's shoulders and head change proportions."""
    head = rig.pose.bones["Head"]
    for side, sign in (("L", 1), ("R", -1)):
        upper, fore, hand = [rig.pose.bones[f"{joint}.{side}"] for joint in ("UpperArm", "Forearm", "Hand")]
        # The source wrist rides beside the temple. In the game the head
        # origin is lower, so raise both wrists and put them outside the bark.
        rest = head.bone.matrix_local.to_quaternion()
        offset = rest.inverted() @ Vector((sign * .23, -.016, .20))
        offset += wrists[side] * .18
        wrist = head.head + head.matrix.to_quaternion() @ offset
        aim_limb(upper, fore, wrist, Vector((sign, -.36, -.42)), weight)
        # Point along the bark so the palms sit on either side and the
        # extended fingers do not cross through the head.
        fingers = rest.inverted() @ Vector((sign * .18, -.10, .34))
        aim(hand, head.head + head.matrix.to_quaternion() @ fingers - hand.head, weight)

    # Pivot about the grip, not the rivet. Point the blades out past the
    # temple along the line of sight, with the handles beside the ear.
    shears = rig.pose.bones["Shears"]
    original = shears.matrix.to_quaternion()
    grip_to_rivet = Y * .27
    aim(shears, Vector((-.34, -.91, -.23)), weight)
    turned = shears.matrix.to_quaternion()
    shears.location = original.inverted() @ ((turned @ grip_to_rivet) - (original @ grip_to_rivet))
    bpy.context.view_layer.update()


def apply_take(rig, name, sample, time, duration):
    rotations, wrists = sample
    body, arms, legs = MIX[name]
    phase = time / duration
    weight = 1.
    if name in ("sweep", "snatch"):
        weight = sin(pi * phase)
    elif name == "lean":
        weight = sin(pi * min(time / 2.5, 1.))
    elif name == "tilt":
        # Agony starts with its hands already on its head. Let the reaction
        # come up from the current stance during the first few frames.
        progress = min(1., time / .20)
        weight = progress ** 2 * (3. - 2. * progress)
    planted = []
    if not legs:
        for side in ("L", "R"):
            foot = rig.pose.bones[f"Foot.{side}"]
            planted.append((foot, foot.head.copy(), foot.matrix.to_quaternion()))
    for bone, rotation in rotations.items():
        mix = arms if bone.startswith(ARMS) else legs if bone.startswith(LEGS) else body
        if mix:
            part = rig.pose.bones[bone]
            part.rotation_quaternion = part.rotation_quaternion.slerp(rotation, mix * weight)
    bpy.context.view_layer.update()
    for foot, ankle, facing in planted:
        aim_limb(foot.parent.parent, foot.parent, ankle, Vector((0, -1, 0)), 1.)
        foot.rotation_quaternion = foot.rotation_quaternion @ foot.matrix.to_quaternion().inverted() @ facing
        bpy.context.view_layer.update()
    if name == "tilt":
        grasp_head(rig, wrists, weight)
