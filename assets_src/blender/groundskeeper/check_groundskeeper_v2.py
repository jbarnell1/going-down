"""Check groundskeeper_v2.glb in a fresh Blender process: today's clip promises on the Meshy figure.

    blender -b --factory-startup --python-exit-code 1 --python check_groundskeeper_v2.py
"""

import json
from pathlib import Path
from struct import unpack_from
import sys

import bpy


REPO = Path(__file__).resolve().parents[3]
GLB = REPO / "godot/assets/entities/groundskeeper_v2.glb"
ANIMATIONS = {"listen": 3.2, "walk": .5, "tilt": .8, "sweep": 2.,
              "lean": 3., "snatch": 19 / 30, "recover": .6}
JOINTS = {"Root", "Hips", "Spine", "Spine1", "Chest", "Neck", "Head", "Badges", "Shears", "Blade.A", "Blade.B"}
JOINTS.update(f"{joint}.{side}" for joint in ("Shoulder", "UpperArm", "Forearm", "Hand", "Thigh", "Shin", "Foot", "Toe")
              for side in ("L", "R"))
HEAD_JOINT = 2.29   # today's groundskeeper.glb


def jpeg_size(data):
    at = 2
    while at < len(data):
        marker, length = data[at + 1], unpack_from(">H", data, at + 2)[0]
        # Godot 4.7 cannot read a JPEG that carries a colour profile.
        assert marker != 0xE2, "the albedo still carries an ICC profile (APP2), which Godot will not load"
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = unpack_from(">HH", data, at + 5)
            return width, height
        at += 2 + length
    raise AssertionError("no JPEG frame header")


def check_package(glb):
    data = glb.read_bytes()
    assert data[:4] == b"glTF" and len(data) < 4_000_000, len(data)
    header_length = unpack_from("<I", data, 12)[0]
    package = json.loads(data[20:20 + header_length])
    binary = memoryview(data)[28 + header_length:]
    assert len(package["meshes"]) == len(package["skins"]) == 1, "one mesh, one skin"
    assert {m["name"] for m in package["materials"]} == {"Material_0", "Shears"}, package["materials"]
    nodes = package["nodes"]
    game_joints = {nodes[i]["name"] for i in package["skins"][0]["joints"]}
    assert game_joints == JOINTS, game_joints ^ JOINTS
    image, = package["images"]
    view = package["bufferViews"][image["bufferView"]]
    picture = bytes(binary[view.get("byteOffset", 0):view.get("byteOffset", 0) + view["byteLength"]])
    assert image["mimeType"] == "image/jpeg" and picture[:2] == b"\xff\xd8", "albedo should be a JPEG"
    assert jpeg_size(picture) == (1024, 1024), jpeg_size(picture)

    def unpack(accessor_id, size, count=1):
        accessor = package["accessors"][accessor_id]
        address = package["bufferViews"][accessor["bufferView"]].get("byteOffset", 0) + accessor.get("byteOffset", 0)
        return [unpack_from("<" + "f" * count, binary, address + i * size)
                for i in range(accessor["count"])]

    def keys(animation, name, property_name, size):
        for channel in animation["channels"]:
            target = channel["target"]
            if nodes[target["node"]]["name"] == name and target["path"] == property_name:
                sampler = animation["samplers"][channel["sampler"]]
                return list(zip(unpack(sampler["input"], 4), unpack(sampler["output"], 4 * size, size)))
        raise AssertionError(f"{animation['name']}: {name} {property_name} track missing")

    assert set(a["name"] for a in package["animations"]) == ANIMATIONS.keys()
    for animation in package["animations"]:
        name = animation["name"]
        root = keys(animation, "Root", "translation", 3)
        assert abs(root[-1][0][0] - ANIMATIONS[name]) < 1e-5, (name, root[-1][0][0])
        assert all(max(abs(axis) for axis in value) < 1e-5 for _, value in root), f"{name}: root moved"
        if name in ("listen", "walk"):
            joints = ("Head",) if name == "listen" else ("Thigh.L", "Thigh.R", "Forearm.R")
            for joint in joints:
                poses = keys(animation, joint, "rotation", 4)
                alignment = sum(a * b for a, b in zip(poses[0][1], poses[-1][1]))
                assert abs(alignment) > .9999, f"{name}: {joint} jumps at loop seam"
        if name == "lean":
            for joint in ("Head", "Spine", "Badges", "Hand.R", "Blade.B"):
                poses = keys(animation, joint, "rotation", 4)
                end_hold = [q for (time,), q in poses if time >= 2.5]
                assert end_hold and all(
                    abs(sum(a * b for a, b in zip(q, end_hold[-1]))) > .9999 for q in end_hold), joint
        if name == "snatch":
            poses = keys(animation, "Blade.B", "rotation", 4)
            closed = poses[0][1]
            closed_dot = lambda q: abs(sum(a * b for a, b in zip(q, closed)))
            assert closed_dot(poses[4][1]) < .92, "blade should spread at frame 4"
            assert all(closed_dot(q) > .9999 for _, q in poses[6:]), "blade must close at frame 6 and hold"

    triangles = sum(package["accessors"][p["indices"]]["count"] // 3 for p in package["meshes"][0]["primitives"])
    assert 20000 < triangles < 40000, triangles
    print(f"GLB {len(data):,} bytes | {triangles:,} triangles | {len(game_joints)} joints | "
          f"1024 px JPEG albedo | seven fixed-root clips")


def bounds(points):
    return tuple((min(v[i] for v in points), max(v[i] for v in points)) for i in range(3))


def check_blender_import():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30
    bpy.ops.import_scene.gltf(filepath=str(GLB))
    rig, = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    mesh, = [obj for obj in bpy.context.scene.objects
             if obj.type == "MESH" and any(mod.type == "ARMATURE" and mod.object == rig for mod in obj.modifiers)]
    assert set(rig.data.bones.keys()) == JOINTS
    assert rig.data.bones["Shears"].parent.name == "Hand.R" and rig.data.bones["Badges"].parent.name == "Chest"
    for group in ("Badges", "Shears", "Blade.A", "Blade.B", "Head"):
        index = mesh.vertex_groups[group].index
        assert any(g.group == index and g.weight > .5 for v in mesh.data.vertices for g in v.groups), group
    by_name = {action.name: action for action in bpy.data.actions}
    assert by_name.keys() == ANIMATIONS.keys(), list(by_name)

    rig.data.pose_position = "REST"
    bpy.context.view_layer.update()
    rest = [mesh.matrix_world @ v.co for v in mesh.evaluated_get(bpy.context.evaluated_depsgraph_get()).data.vertices]
    (left, right), (front, back), (bottom, crown) = bounds(rest)
    head = (rig.matrix_world @ rig.data.bones["Head"].head_local).z
    assert abs(head - HEAD_JOINT) < .01, f"the Head joint should stand where today's does, not at {head:.3f}"
    assert abs(bottom) < .01, f"feet on the floor, not {bottom:.3f}"
    assert 2.9 < crown < 3.05, f"the dead branch should stand to about 3 m, not {crown:.2f}"
    # A-pose: the arms hang along the body, not out in a T.
    for side in ("L", "R"):
        wrist = rig.data.bones[f"Hand.{side}"].head_local
        assert wrist.z < 1.4 and abs(wrist.x) < .75, f"{side} wrist {tuple(wrist)} is not in an A-pose"
    # ONE branch: nothing on the left shoulder above the collar outside the head.
    shoulder = [p for p in rest if p.x > .17 and 2.2 < p.z < 2.5 and -.2 < p.y < .14]
    assert len(shoulder) < 40, f"the second branch is back on the shoulder ({len(shoulder)} vertices)"
    print(f"silhouette: Head joint {head:.3f} m, branch {crown:.2f} m, width {right - left:.2f} m, depth {back - front:.2f} m")

    rig.data.pose_position = "POSE"
    rig.animation_data.use_nla = False
    for name, action in by_name.items():
        rig.animation_data.action = action
        rig.animation_data.action_slot = action.slots[0]
        heights = []
        first, last = map(round, action.frame_range)
        if name == "tilt":
            check_hearing_reaction(rig, first)
        for frame in range(first, last + 1):
            bpy.context.scene.frame_set(frame)
            posed = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
            _, _, (low, top) = bounds([mesh.matrix_world @ v.co for v in posed.data.vertices])
            # Today's ceiling was 3.1 m; the new snatch raises the shears overhead before the blades close.
            assert -.15 < low < .15 and 1.6 < top < (3.3 if name == "snatch" else 3.1), (name, frame, low, top)
            heights.append(top)
        print(f"{name}: {last - first + 1} frames, animated height {min(heights):.2f}-{max(heights):.2f} m")


def check_hearing_reaction(rig, first):
    scene = bpy.context.scene
    bones = rig.pose.bones
    scene.frame_set(first)
    feet = {name: bones[name].head.copy() for name in ("Foot.L", "Foot.R")}
    head = bones["Head"]
    assert all((bones[f"Hand.{side}"].head - head.head).length > .7 for side in ("L", "R")), \
        "hearing reaction should start with lowered hands"
    for elapsed in (6, 8, 12, 18, 24):
        scene.frame_set(first + elapsed)
        for side, sign in (("L", 1), ("R", -1)):
            wrist = bones[f"Hand.{side}"].head
            offset = head.matrix.to_quaternion().inverted() @ (wrist - head.head)
            rest_offset = head.bone.matrix_local.to_quaternion() @ offset
            assert .13 < sign * rest_offset.x < .31 and .14 < rest_offset.z < .29, \
                (f"Agony: {side} wrist missed its temple at frame {elapsed}", rest_offset)
        assert all((bones[name].head - initial).length < .015 for name, initial in feet.items()), \
            f"hearing reaction moved a planted foot at frame {elapsed}"
    print("Agony: hands up by 0.20 s and feet planted for the hearing reaction")


if "--break-blade" in sys.argv:
    ANIMATIONS["snatch"] = 20 / 30
check_package(GLB)
check_blender_import()
print("groundskeeper_v2 checks passed")
