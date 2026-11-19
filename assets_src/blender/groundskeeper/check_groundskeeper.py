"""Check both exports in a fresh Blender process."""

import json
from pathlib import Path
from struct import unpack_from
import sys

import bpy


REPO = Path(__file__).resolve().parents[3]
GLB = REPO / "godot/assets/entities/groundskeeper.glb"
FBX = REPO / "assets_src/mixamo/export/groundskeeper.fbx"
ANIMATIONS = {"listen": 3.2, "walk": .5, "tilt": .8, "sweep": 2.,
              "lean": 3., "snatch": 19 / 30, "recover": .6}
JOINTS = {"Root", "Hips", "Spine", "Chest", "Neck", "Head", "Badges", "Shears", "Blade.A", "Blade.B"}
JOINTS.update(f"{joint}.{side}" for joint in ("UpperArm", "Forearm", "Hand", "Thigh", "Shin", "Foot")
              for side in ("L", "R"))


def check_package(glb):
    data = glb.read_bytes()
    assert data[:4] == b"glTF" and len(data) < 1_000_000
    header_length = unpack_from("<I", data, 12)[0]
    package = json.loads(data[20:20 + header_length])
    binary = memoryview(data)[28 + header_length:]
    assert len(package["meshes"]) == len(package["materials"]) == len(package["skins"]) == 1
    nodes = package["nodes"]
    game_joints = {nodes[i]["name"] for i in package["skins"][0]["joints"]}
    assert game_joints == JOINTS, game_joints
    atlas, = package["images"]
    view = package["bufferViews"][atlas["bufferView"]]
    png = binary[view["byteOffset"]:]
    mime_type = "image/jpeg" if "--break-atlas" in sys.argv else atlas["mimeType"]
    assert mime_type == "image/png" and png[:8] == b"\x89PNG\r\n\x1a\n", "atlas MIME/signature mismatch"
    assert unpack_from(">II", png, 16) == (512, 512), "atlas resolution"
    assert package["samplers"][0]["magFilter"] == 9728, "texture should use nearest sampling"

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
        assert abs(root[-1][0][0] - ANIMATIONS[name]) < 1e-5
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

    primitive, = package["meshes"][0]["primitives"]
    triangles = package["accessors"][primitive["indices"]]["count"] // 3
    assert 4000 < triangles < 8000, triangles
    print(f"GLB {len(data):,} bytes | {triangles:,} triangles | {len(game_joints)} joints | seven fixed-root clips")


def bounds(mesh):
    points = [mesh.matrix_world @ vertex.co for vertex in mesh.data.vertices]
    return tuple((min(v[i] for v in points), max(v[i] for v in points)) for i in range(3))


def check_blender_imports():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 30
    bpy.ops.import_scene.gltf(filepath=str(GLB))
    rig, = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    mesh, = [obj for obj in bpy.context.scene.objects
             if obj.type == "MESH" and any(mod.type == "ARMATURE" and mod.object == rig for mod in obj.modifiers)]
    assert set(rig.data.bones.keys()) == JOINTS
    by_name = {action.name: action for action in bpy.data.actions}
    assert by_name.keys() == ANIMATIONS.keys(), list(by_name)
    # The silhouette the owner asked for on 19 Nov ("not very scary"): at rest the dead branch stands well
    # above the head, the left hand's roots reach far past the right hand, and the body is starved.
    rig.data.pose_position = "REST"
    bpy.context.view_layer.update()
    rest = [mesh.matrix_world @ v.co for v in mesh.evaluated_get(bpy.context.evaluated_depsgraph_get()).data.vertices]
    crown = max(p.z for p in rest)
    wide = max(abs(p.x) for p in rest)
    waist = max(abs(p.x) for p in rest if 1.47 < p.z < 1.5)
    assert 2.9 < crown < 3.05, f"the dead branch should stand to about 3 m, not {crown:.2f}"
    assert wide > 1.85, f"the root fingers should reach past 1.85 m, not {wide:.2f}"
    assert waist < .16, f"the waist should be starved, not {waist:.2f} m from the spine"
    print(f"silhouette: branch {crown:.2f} m, reach {wide:.2f} m, waist {waist:.2f} m")
    rig.data.pose_position = "POSE"
    rig.animation_data.use_nla = False
    for name, action in by_name.items():
        rig.animation_data.action = action
        heights = []
        first, last = map(round, action.frame_range)
        if name == "tilt" and "--authored" not in sys.argv:
            check_hearing_reaction(rig, first)
        for frame in range(first, last + 1):
            bpy.context.scene.frame_set(frame)
            posed = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
            _, _, (bottom, top) = bounds(posed)
            assert -.15 < bottom < .15 and 1.6 < top < 3.1, (name, frame, bottom, top)
            heights.append(top)
        print(f"{name}: animated height {min(heights):.2f}-{max(heights):.2f} m")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=str(FBX))
    upload, = list(bpy.context.scene.objects)
    assert upload.type == "MESH" and not upload.animation_data
    (left, right), _, (floor, crown) = bounds(upload)
    assert left < -1.4 and right > 1.4 and right - left > crown - floor
    assert 0 <= floor < .02 and 2.5 < crown < 2.75
    print(f"Mixamo FBX: {FBX.stat().st_size:,} bytes | mesh only | T-pose {right - left:.2f} m wide, {crown - floor:.2f} m tall")


def check_hearing_reaction(rig, first):
    scene = bpy.context.scene
    bones = rig.pose.bones
    scene.frame_set(first)
    feet = {name: bones[name].head.copy() for name in ("Foot.L", "Foot.R")}
    head = bones["Head"]
    assert all((bones[f"Hand.{side}"].head - head.head).length > .7 for side in ("L", "R")), \
        "hearing reaction should start with lowered hands"
    # The live hearing window can be as short as 0.30 s. Both wrists
    # must reach opposite sides of the head by 0.20 s and stay there.
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


check_package(GLB)
check_blender_imports()
