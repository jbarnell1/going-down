"""Build the Orderly's compact Clinic trolley for Godot from primitive meshes.

Run Blender in background with --python-exit-code 1 --python <this file>.
In the glTF, +Z leads the trolley, +Y is up, and the four tires touch Y=0.
"""
from pathlib import Path
import math

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "godot" / "assets" / "props" / "orderly_trolley.glb"


def material(name, rgb, roughness, metal=0.0):
    result = bpy.data.materials.new(name)
    result.use_nodes = True
    shader = result.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (*rgb, 1.0)
    shader.inputs["Roughness"].default_value = roughness
    shader.inputs["Metallic"].default_value = metal
    return result


def box(name, at, size, surface, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=at)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(surface)
    if bevel:
        modifier = obj.modifiers.new("Soft stamped edges", "BEVEL")
        modifier.width = bevel
        modifier.segments = 2
    return obj


def tube(name, start, end, radius, surface):
    delta = Vector(end) - Vector(start)
    middle = Vector(start) + delta / 2
    bpy.ops.mesh.primitive_cylinder_add(vertices=10, radius=radius, depth=delta.length, location=middle)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = delta.to_track_quat("Z", "Y").to_euler()
    obj.data.materials.append(surface)
    return obj


def marker(name, at):
    obj = bpy.data.objects.new(name, None)
    obj.location = at
    bpy.context.collection.objects.link(obj)


bpy.ops.wm.read_factory_settings(use_empty=True)
steel = material("Brushed Clinic steel", (0.43, 0.49, 0.48), 0.50, 0.52)
dark = material("Oxidised tray", (0.17, 0.25, 0.24), 0.72, 0.25)
rubber = material("Hard black rubber", (0.035, 0.031, 0.026), 0.87)
ivory = material("Worn cream edge", (0.68, 0.64, 0.49), 0.75)

for shelf, height in (("Bottom", 0.31), ("Top", 0.93)):
    box(shelf + " tray", (0, 0, height), (0.50, 0.56, 0.035), dark, 0.012)
    for x in (-0.245, 0.245):
        box(shelf + " folded side", (x, 0, height + 0.026), (0.022, 0.54, 0.052), steel, 0.007)
    for y in (-0.265, 0.265):
        box(shelf + " folded end", (0, y, height + 0.026), (0.48, 0.024, 0.052), steel, 0.007)
    box(shelf + " worn strip", (0.256, -0.07, height + 0.035), (0.005, 0.17, 0.011), ivory)

for x in (-0.214, 0.214):
    for y in (-0.213, 0.213):
        tube("Corner upright", (x, y, 0.16), (x, y, 0.955), 0.019, steel)
        wheel = tube("Caster tire", (x - 0.023, y, 0.079), (x + 0.023, y, 0.079), 0.079, rubber)
        # The tire is a capped ten-sided cylinder. Orient a tread flat at the floor and
        # compensate for its apothem so the low-poly wheel's flat lies at exactly zero.
        wheel.rotation_euler.rotate_axis("Z", math.pi / 10)
        wheel.location.z = 0.079 * math.cos(math.pi / 10)
        tube("Caster hub", (x - 0.028, y, 0.075), (x + 0.028, y, 0.075), 0.043, steel)
        tube("Caster fork", (x, y, 0.11), (x, y, 0.206), 0.019, steel)
for x in (-0.215, 0.215):
    tube("Handle riser", (x, 0.20, 0.92), (x, 0.30, 1.20), 0.020, steel)
tube("Push handle", (-0.23, 0.30, 1.20), (0.23, 0.30, 1.20), 0.025, rubber)
marker("GripLeft", (0.205, 0.30, 1.215))
marker("GripRight", (-0.205, 0.30, 1.215))
marker("SqueakWheel", (-0.214, -0.213, 0.075))

# One static draw mesh for the shelves and frame. Keep the four wheel meshes
# separate so their contact points can be checked against the floor.
bpy.ops.object.select_all(action="DESELECT")
frame = [obj for obj in bpy.context.scene.objects if obj.type == "MESH" and not obj.name.startswith("Caster tire")]
for obj in frame:
    bpy.context.view_layer.objects.active = obj
    for modifier in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    obj.select_set(True)
bpy.context.view_layer.objects.active = frame[0]
bpy.ops.object.join()
bpy.context.object.name = "Trolley frame"

bpy.ops.export_scene.gltf(filepath=str(OUTPUT), export_format="GLB", export_apply=True)
