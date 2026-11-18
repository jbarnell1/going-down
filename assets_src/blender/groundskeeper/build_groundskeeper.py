"""Build the Groundskeeper from geometry and painted maps. Blender 5.3, no inputs."""

from array import array
import argparse
from math import cos, pi, sin, sqrt, tau
from pathlib import Path
import random
import sys

import bmesh
import bpy
from mathutils import Euler, Vector


REPO = Path(__file__).resolve().parents[3]
PROOF = REPO / "godot/export/groundskeeper"
FPS = 30
RNG = random.Random(91)
PAL = [
    (115, 105, 76), (82, 78, 61), (134, 130, 81), (72, 99, 48),
    (94, 59, 38), (158, 114, 72), (38, 27, 21), (76, 66, 49),
    (155, 156, 142), (188, 146, 68), (98, 100, 90), (60, 57, 45),
    (177, 159, 106), (77, 90, 46), (122, 112, 69), (44, 42, 37),
]
CLOTH, SHADOW, HEM, MOSS, BARK, SAP, CRACK, BOOT, STEEL, BRASS, OXIDE, CORD, PATCH, LEAF, CANVAS, INK = range(16)


def make_atlas():
    size = 512
    image = bpy.data.images.new("GroundskeeperAtlas", size, size, alpha=False)
    pixels = array("f")
    for y in range(size):
        v = y % 128
        for x in range(size):
            u = x % 128
            tile = x // 128 + 4 * (y // 128)
            base = PAL[tile]
            broad = sin(u * .16 + sin(v * .09) * 2) * 4 + cos(v * .108 + u * .08) * 3
            if tile in (BARK, SAP, CRACK):
                vein = sin(u * .28 + sin(v * .035) * 1.5)
                broad += 9 * vein - 19 * max(0, sin(u * .83 + v * .019)) ** 12
            if tile in (CLOTH, SHADOW, HEM, PATCH, CANVAS):
                broad += (1 if u % 3 else -2) + (1 if v % 3 else -2)
            if tile in (MOSS, LEAF):
                broad += 9 * sin(u * .32) * cos(v * .21)
            if tile in (STEEL, OXIDE, BRASS):
                broad += 5 * sin(u * .7 + v * .018)
            shade = broad + RNG.uniform(-4, 4)
            pixels.extend(max(0, min(255, k + shade)) / 255 for k in base)
            pixels.append(1)
    image.pixels.foreach_set(pixels)
    image.pack()
    material = bpy.data.materials.new("Groundskeeper")
    material.use_nodes = True
    shader = material.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Roughness"].default_value = .89
    tex = material.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Closest"
    material.node_tree.links.new(tex.outputs["Color"], shader.inputs["Base Color"])
    return material


class Geometry:
    def __init__(self):
        self.vertices, self.faces, self.weights, self.uv = [], [], [], []

    def vertex(self, coordinate, weights):
        self.vertices.append(coordinate)
        self.weights.append({weights: 1.0} if isinstance(weights, str) else weights)
        return len(self.vertices) - 1

    def face(self, indices, tile, texcoords):
        self.faces.append(indices)
        self.uv.append([
            ((tile % 4 * 128 + 2 + 124 * u) / 512,
             (tile // 4 * 128 + 2 + 124 * v) / 512)
            for u, v in texcoords
        ])

    def loft(self, rings, first_axis, sides, tiles, variation=.035, shade=None):
        """Loft elliptical, weight-blended rings along a bent centerline."""
        centers = [Vector(ring[0]) for ring in rings]
        rows = []
        for row, (center, a, b, weights) in enumerate(rings):
            tangent = (centers[min(row + 1, len(rings) - 1)] - centers[max(row - 1, 0)]).normalized()
            axis = Vector(first_axis)
            axis = (axis - tangent * axis.dot(tangent)).normalized()
            across = tangent.cross(axis).normalized()
            indices = []
            for col in range(sides):
                angle = tau * col / sides
                fold = 1 + variation * (sin(angle * 3 + row * .7) + cos(angle * 5 - row) * .5)
                indices.append(self.vertex(Vector(center) + fold * (
                    axis * a * cos(angle) + across * b * sin(angle)), weights))
            rows.append(indices)
        for row in range(len(rows) - 1):
            v0, v1 = row / (len(rows) - 1), (row + 1) / (len(rows) - 1)
            for col in range(sides):
                next_col = (col + 1) % sides
                u0, u1 = col / sides, (col + 1) / sides
                tile = shade(row, col) if shade else tiles
                self.face([rows[row][col], rows[row][next_col], rows[row + 1][next_col], rows[row + 1][col]],
                          tile, [(u0, v0), (u1, v0), (u1, v1), (u0, v1)])
        self.face(list(reversed(rows[0])), tiles, [(0.5, 0.5)] * sides)
        self.face(rows[-1], tiles, [(0.5, 0.5)] * sides)

    def vine(self, points, radii, weight, tile, sides=5):
        tangent = (Vector(points[-1]) - Vector(points[0])).normalized()
        axis = (0, 0, 1) if abs(tangent.z) < .85 else (1, 0, 0)
        self.loft([(point, radius, radius, weight) for point, radius in zip(points, radii)],
                  axis, sides, tile)

    def sheet(self, points, weight, tile, depth=.006):
        """Fine stamped metal, leather tabs, bark flakes and badge plates."""
        points = [Vector(p) for p in points]
        outward = (points[1] - points[0]).cross(points[2] - points[0]).normalized()
        front = [self.vertex(point, weight) for point in points]
        back = [self.vertex(point - outward * depth, weight) for point in points]
        uv = [(.5 + .49 * cos(tau * i / len(points)), .5 + .49 * sin(tau * i / len(points)))
              for i in range(len(points))]
        self.face(front, tile, uv)
        self.face(back[::-1], tile, uv[::-1])
        for i, j in zip(range(len(points)), [*range(1, len(points)), 0]):
            self.face([front[i], back[i], back[j], front[j]], tile,
                      [(0, 0), (.04, 0), (.04, 1), (0, 1)])

    def mesh(self, name, material, rig=None):
        data = bpy.data.meshes.new(name)
        data.from_pydata(self.vertices, [], self.faces)
        data.update()
        uv = data.uv_layers.new(name="Atlas")
        for polygon, texcoords in zip(data.polygons, self.uv):
            for index, coord in zip(polygon.loop_indices, texcoords):
                uv.data[index].uv = coord
            polygon.use_smooth = len(polygon.vertices) == 4
        topology = bmesh.new()
        topology.from_mesh(data)
        bmesh.ops.recalc_face_normals(topology, faces=topology.faces)
        topology.to_mesh(data)
        topology.free()
        mesh = bpy.data.objects.new(name, data)
        bpy.context.collection.objects.link(mesh)
        data.materials.append(material)
        if rig:
            mesh.parent = rig
            skin = mesh.modifiers.new("Groundskeeper skin", "ARMATURE")
            skin.object = rig
            groups = {name: mesh.vertex_groups.new(name=name) for name in
                      sorted({bone for weights in self.weights for bone in weights})}
            for index, weights in enumerate(self.weights):
                for bone, weight in weights.items():
                    groups[bone].add([index], weight, "REPLACE")
        return mesh


def mix(a, b, fraction):
    return {a: 1 - fraction, b: fraction}


def arm_points(sign):
    return [(sign * .29, .037, 2.12), (sign * .77, .055, 2.12),
            (sign * 1.28, .035, 2.12), (sign * 1.46, .028, 2.12)]


def leg_points(sign):
    return [(sign * .135, .003, 1.28), (sign * .177, -.084, .69),
            (sign * .19, .005, .143), (sign * .193, -.23, .071)]


def make_rig():
    data = bpy.data.armatures.new("GroundskeeperRig")
    obj = bpy.data.objects.new("GroundskeeperRig", data)
    bpy.context.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")

    def bone(name, head, tail, parent=None):
        part = data.edit_bones.new(name)
        part.head, part.tail = head, tail
        if parent:
            part.parent = data.edit_bones[parent]

    bone("Root", (0, 0, 0), (0, 0, .24))
    bone("Hips", (0, 0, 1.26), (0, 0, 1.5), "Root")
    bone("Spine", (0, 0, 1.5), (0, .026, 1.81), "Hips")
    bone("Chest", (0, .026, 1.81), (0, .032, 2.14), "Spine")
    bone("Neck", (0, .032, 2.14), (-.019, -.061, 2.29), "Chest")
    bone("Head", (-.019, -.061, 2.29), (-.022, -.097, 2.62), "Neck")
    bone("Badges", (.011, -.176, 2.04), (.032, -.225, 1.76), "Chest")
    for side, sign in (("L", 1), ("R", -1)):
        hip, knee, ankle, toe = leg_points(sign)
        bone("Thigh." + side, hip, knee, "Hips")
        bone("Shin." + side, knee, ankle, "Thigh." + side)
        bone("Foot." + side, ankle, toe, "Shin." + side)
        shoulder, elbow, wrist, fingers = arm_points(sign)
        bone("UpperArm." + side, shoulder, elbow, "Chest")
        bone("Forearm." + side, elbow, wrist, "UpperArm." + side)
        bone("Hand." + side, wrist, fingers, "Forearm." + side)
    pivot = (-1.64, -.047, 2.08)
    bone("Shears", pivot, (-1.99, -.047, 2.08), "Hand.R")
    for side, z in (("A", 2.087), ("B", 2.073)):
        bone("Blade." + side, (pivot[0], pivot[1], z), (-2.06, -.04, z), "Shears")
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj


def body():
    g = Geometry()
    g.loft([
        ((0, .013, 1.15), .165, .099, "Hips"),
        ((-.008, .007, 1.25), .251, .153, "Hips"),
        ((-.005, -.005, 1.39), .244, .157, "Hips"),
        ((.006, -.014, 1.51), .207, .131, mix("Hips", "Spine", .66)),
        ((.013, .015, 1.66), .212, .137, "Spine"),
        ((.014, .025, 1.79), .246, .172, mix("Spine", "Chest", .52)),
        ((.011, .041, 1.99), .318, .178, "Chest"),
        ((.003, .038, 2.105), .336, .15, "Chest"),
        ((-.007, .037, 2.17), .24, .108, "Chest"),
        ((0, .014, 2.19), .102, .08, mix("Chest", "Neck", .44)),
    ], (1, 0, 0), 20, CLOTH, shade=lambda row, col: SHADOW if col in (3, 4, 5, 6, 7) or row == 0 else CLOTH)
    g.vine([(0, -.018, 2.13), (-.015, -.058, 2.24), (-.019, -.072, 2.34)],
           [.104, .092, .073], "Neck", CRACK, 12)
    # The wood replaces the entire face. It has a chin and crown but no eyes or mouth.
    g.loft([
        ((-.019, -.084, 2.265), .052, .068, "Head"),
        ((-.033, -.105, 2.30), .089, .11, "Head"),
        ((-.026, -.106, 2.37), .127, .13, "Head"),
        ((-.043, -.094, 2.47), .154, .139, "Head"),
        ((-.038, -.055, 2.57), .137, .124, "Head"),
        ((-.064, -.015, 2.659), .093, .086, "Head"),
        ((-.084, .012, 2.694), .018, .022, "Head"),
    ], (1, 0, 0), 20, BARK, .073,
        lambda row, col: (SAP if col in (12, 15, 17) else CRACK if col in (14, 18) else BARK))

    for side, sign in (("L", 1), ("R", -1)):
        shoulder, elbow, wrist, _ = map(Vector, arm_points(sign))
        upper, lower, hand = ("UpperArm." + side, "Forearm." + side, "Hand." + side)
        g.loft([
            (shoulder + Vector((-.059 * sign, 0, 0)), .104, .101, "Chest"),
            (shoulder, .151, .153, mix("Chest", upper, .45)),
            (shoulder.lerp(elbow, .19), .139, .132, upper),
            (shoulder.lerp(elbow, .65), .092, .1, upper),
            (shoulder.lerp(elbow, .89), .101, .104, mix(upper, lower, .20)),
            (elbow, .092, .103, mix(upper, lower, .55)),
            (elbow.lerp(wrist, .14), .1, .099, mix(upper, lower, .9)),
            (elbow.lerp(wrist, .55), .076, .084, lower),
            (elbow.lerp(wrist, .91), .059, .066, lower),
            (wrist, .062, .068, mix(lower, hand, .25)),
        ], (0, 0, 1), 14, CLOTH, .065, lambda row, col: SHADOW if col in (5, 6, 7, 8) else CLOTH)
        g.loft([
            (wrist, .047, .057, hand),
            (wrist + Vector((.052 * sign, 0, 0)), .046, .077, hand),
            (wrist + Vector((.12 * sign, 0, -.007)), .034, .07, hand),
            (wrist + Vector((.145 * sign, -.005, -.009)), .021, .051, hand),
        ], (0, 0, 1), 12, BOOT)
        for i in range(4):
            x, y, z = wrist
            digit = .154 + .028 * sin(i * pi / 4)
            g.vine([(x + sign * .12, y + .036 - .029 * i, z),
                    (x + sign * digit, y + .04 - .03 * i, z - .012),
                    (x + sign * (digit + .055 - i * .006), y + .04 - .03 * i, z - .024)],
                   [.019, .015, .007], hand, BOOT)
        x, y, z = wrist
        g.vine([(x + sign * .033, y - .049, z),
                (x + sign * .069, y - .097, z - .003),
                (x + sign * .121, y - .11, z - .017)], [.026, .019, .009], hand, BOOT)

        hip, knee, ankle, _ = map(Vector, leg_points(sign))
        thigh, shin, foot = ("Thigh." + side, "Shin." + side, "Foot." + side)
        g.loft([
            (hip + Vector((0, 0, .12)), .119, .133, "Hips"),
            (hip, .14, .148, mix("Hips", thigh, .65)),
            (hip.lerp(knee, .25), .135, .142, thigh),
            (hip.lerp(knee, .68), .117, .113, thigh),
            (hip.lerp(knee, .9), .112, .115, mix(thigh, shin, .25)),
            (knee, .121, .121, mix(thigh, shin, .56)),
            (knee.lerp(ankle, .16), .115, .109, mix(thigh, shin, .93)),
            (knee.lerp(ankle, .38), .108, .118, shin),
            (knee.lerp(ankle, .73), .082, .09, shin),
            (knee.lerp(ankle, .88), .085, .09, shin),
            (ankle, .082, .082, mix(shin, foot, .5)),
        ], (1, 0, 0), 14, CLOTH, .067,
            lambda row, col: SHADOW if row >= 8 or col in (7, 8, 9) else HEM if row == 5 and col in (3, 4) else CLOTH)
        x = ankle.x
        g.loft([
            ((x, .087, .077), .068, .066, foot),
            ((x, .045, .098), .088, .095, foot),
            ((x, -.023, .098), .092, .093, foot),
            ((x + .01 * sign, -.114, .068), .099, .063, foot),
            ((x + .023 * sign, -.205, .064), .104, .054, foot),
            ((x + .024 * sign, -.263, .061), .085, .049, foot),
            ((x + .021 * sign, -.272, .057), .046, .038, foot),
        ], (1, 0, 0), 12, BOOT, .029, lambda row, col: INK if col >= 7 else BOOT)
    return g


def badge(g, x, y, z, width, height, angle, tile):
    def place(u, v):
        return (x + u * cos(angle) - v * sin(angle), y + .07 * u, z + v * cos(angle) + u * sin(angle))
    g.sheet([place(u * width, v * height) for u, v in
             [(-.5, -.38), (-.39, -.5), (.42, -.5), (.5, -.34), (.5, .38), (.33, .5), (-.4, .5), (-.5, .37)]],
            "Badges", tile, .008)
    for row, extent in ((.20, .31), (.03, .27), (-.16, .19)):
        start = place(-.31 * width, row * height)
        end = place(extent * width, row * height)
        g.vine([(start[0], start[1] - .005, start[2]), (end[0], end[1] - .005, end[2])],
               [.0032, .0024], "Badges", OXIDE, 4)


def details(g):
    # Hide asymmetrical bark plates and a coarse split in the head's actual silhouette.
    for i, (x, y, z) in enumerate([
        (-.143, -.175, 2.37), (-.095, -.217, 2.32), (-.046, -.234, 2.34),
        (.015, -.222, 2.31), (.065, -.199, 2.36), (.107, -.163, 2.40),
    ]):
        g.vine([(x, y + .022, z), (x - .01, y - .013, z + .092),
                (x + .016, y - .009, z + .195), (x - .025, y + .049, z + .252)],
               [.009, .019, .021, .006], "Head", SAP if i in (1, 4) else BARK, 7)
    g.vine([(-.052, -.196, 2.30), (-.039, -.243, 2.38), (-.064, -.245, 2.477),
            (-.048, -.194, 2.555), (-.088, -.11, 2.647)],
           [.007, .012, .022, .015, .009], "Head", CRACK, 6)
    for x, z, lean in [(-.156, 2.51, -.068), (.07, 2.55, .052), (-.027, 2.60, -.02)]:
        g.vine([(x, -.055, z), (x + lean * .63, -.024, z + .11),
                (x + lean, .031, z + .18)], [.035, .023, .001], "Head", BARK, 6)

    # High, lopsided survey tarp running off the back and through one shoulder.
    for n in range(10):
        x = .025 + .027 * n
        g.sheet([(x, .129 - .007 * n, 2.168 - .007 * n),
                 (x + .059, .153 - .004 * n, 2.092 - .012 * n),
                 (x + .072, .151 - .004 * n, 1.87 - .046 * (n % 4)),
                 (x + .047, .17 - .007 * n, 1.90 - .042 * (n % 4)),
                 (x + .017, .185 - .006 * n, 1.73 - .076 * (n % 3)),
                 (x - .014, .179 - .003 * n, 1.969 - .02 * (n % 3))],
                "Chest", CANVAS if n % 3 else HEM, .014)
    g.vine([(.095, .14, 1.94), (.152, .161, 2.17), (.205, .123, 2.3), (.318, .105, 2.388)],
           [.063, .053, .031, .004], "Chest", BARK, 8)
    g.vine([(.201, .127, 2.28), (.267, .174, 2.35), (.276, .21, 2.485)],
           [.029, .016, .002], "Chest", BARK, 6)
    g.vine([(.201, .127, 2.28), (.226, .085, 2.42), (.334, .068, 2.5)],
           [.022, .013, .002], "Chest", SAP, 6)

    # Root tendrils wind through the left sleeve and out around the hand.
    for i in range(4):
        drift = i * .037
        g.vine([(.85 + drift, .048 - drift, 2.11), (.925 + drift, -.024 - drift * .6, 2.182),
                (1.075 + drift, -.043 - drift * .42, 2.175),
                (1.25 + drift * .2, -.023 - drift * .39, 2.143)],
               [.024, .024, .019, .011], "Forearm.L", BARK if i % 3 else SAP, 6)
        g.vine([(1.26, -.035 + drift * .48, 2.15), (1.39, -.065 + drift * .39, 2.12 - drift * .5),
                (1.51 + drift * .7, -.058 + drift * .75, 2.064 - drift * .45),
                (1.55 + drift, -.042 + drift, 2.048 - drift * .67)],
               [.019, .018, .009, .001], "Hand.L", BARK, 6)

    for _ in range(43):
        scale = RNG.uniform(.023, .06)
        x, z = RNG.uniform(.125, .28), RNG.uniform(1.68, 2.16)
        y = RNG.uniform(-.137, -.115) if x < .245 else RNG.uniform(-.09, -.07)
        tilt = RNG.uniform(-.025, .046)
        g.sheet([(x - scale * .5, y, z), (x + tilt * .45, y - .02, z + scale * .72),
                 (x + tilt, y - .022, z + scale * 1.28), (x + scale * .48, y, z + scale * .42)],
                "Chest" if z > 1.815 else "Spine", RNG.choice([MOSS, LEAF, MOSS]), .008)

    for i in range(8):
        x = -.213 + .051 * i
        z = 1.385 - RNG.uniform(.10, .30)
        y = -.13 + .032 * abs(x) / .23
        g.sheet([(x - .019, y + .022, 1.41), (x + .038, y + .008, 1.42),
                 (x + .024, y - .009, z + .024), (x + .009, y - .011, z + .05),
                 (x - .018, y - .003, z)], "Hips", HEM if i % 4 == 0 else SHADOW)

    # Survey pockets, reinforcement and a broken zip carry larger marks into the game camera.
    for sign in (-1, 1):
        left = sign * .085
        right = sign * .236
        g.sheet([(left, -.119, 1.53), (right, -.089, 1.55), (right, -.111, 1.687),
                 (left + sign * .017, -.138, 1.67)], "Spine", SHADOW, .012)
        g.vine([(left, -.142, 1.669), ((left + right) * .5, -.137, 1.681),
                (right, -.114, 1.687)], [.009, .009, .009], "Spine", HEM, 5)
        x = sign * .177
        knee = "Shin.L" if sign == 1 else "Shin.R"
        g.sheet([(x - .068, -.186, .648), (x + .061, -.190, .674), (x + .079, -.187, .772),
                 (x + .026, -.195, .802), (x - .063, -.193, .787)], knee, SHADOW, .011)
        g.vine([(x - .054, -.194, .711), (x + .004, -.214, .699), (x + .063, -.205, .714)],
               [.006, .005, .004], knee, HEM, 5)
    g.vine([(-.028, -.153, 1.51), (-.024, -.129, 1.664), (-.037, -.141, 1.785),
            (-.03, -.142, 1.96), (-.04, -.128, 2.074)], [.008] * 5,
           mix("Spine", "Chest", .48), SHADOW, 5)

    # The coverall's stitched 9-1 identifier and two gilt seams.
    g.sheet([(-.246, -.102, 1.943), (-.103, -.149, 1.933), (-.107, -.148, 2.013),
             (-.246, -.103, 2.023)], "Chest", PATCH)
    glyphs = [
        [(-.19, 1.957), (-.179, 1.97), (-.179, 2.004), (-.206, 2.007), (-.213, 1.986), (-.183, 1.983)],
        [(-.173, 1.981), (-.156, 1.979)],
        [(-.148, 1.992), (-.135, 2.004), (-.137, 1.957)],
    ]
    for glyph in glyphs:
        g.vine([(x, -.107 - (x + .246) * .31, z) for x, z in glyph],
               [.0039] * len(glyph), "Chest", INK, 5)
    g.vine([(-.111, -.072, 2.156), (-.071, -.128, 2.111), (-.036, -.159, 2.064),
            (-.027, -.156, 1.952), (-.038, -.14, 1.822)],
           [.009, .01, .01, .007, .005], "Chest", CORD, 5)
    g.vine([(-.071, -.03, 2.189), (-.12, -.107, 2.103), (-.081, -.165, 2.033),
            (.009, -.181, 1.944), (.068, -.171, 2.042), (.092, -.074, 2.152)],
           [.012] * 6, "Chest", CORD, 7)
    for i in range(7):
        x = -.083 + .026 * i
        y = -.17 - .012 * (i % 4)
        z = 1.876 - .038 * (i % 3)
        g.vine([(x * .56, -.188, 2.009), (x * .89, y - .019, 1.937), (x, y, z + .042)],
               [.006, .005, .0045], "Badges", CORD, 6)
        badge(g, x, y - .007, z, .059 + .006 * (i % 2), .087, -.27 + .125 * i,
              BRASS if i == 3 else STEEL if i % 3 else OXIDE)

    # Two tapered forged blades pivot under a worn rivet. The grip stays on the wrist.
    x, y, z = -1.64, -.047, 2.08
    for side, sign in (("A", -1), ("B", 1)):
        blade = "Blade." + side
        height = z - sign * .007
        g.vine([(x, y, height), (x + .104, y + sign * .026, height),
                (x + .346, y + sign * .051, height), (x + .593, y + sign * .083, height)],
               [.015, .021, .026, .023], blade, BARK, 9)
        g.vine([(x + .255, y + sign * .044, height), (x + .359, y + sign * .055, height),
                (x + .584, y + sign * .081, height), (x + .61, y + sign * .083, height)],
               [.026, .033, .032, .017], blade, BOOT, 10)
        g.sheet([(x + .045, y + sign * .022, height), (x - .073, y + sign * .054, height),
                 (x - .237, y + sign * .053, height), (x - .432, y + sign * .008, height),
                 (x - .305, y - sign * .008, height), (x - .059, y - sign * .015, height)],
                blade, OXIDE, .012)
        g.sheet([(x - .074, y - sign * .012, height - .006),
                 (x - .307, y - sign * .008, height - .006),
                 (x - .432, y + sign * .008, height - .006),
                 (x - .25, y + sign * .011, height - .006)],
                blade, STEEL, .009)
    g.vine([(x, y, z - .025), (x, y, z + .025)], [.038, .034], "Shears", OXIDE, 12)


def smoothstep(t):
    t = min(1, max(0, t))
    return t * t * (3 - 2 * t)


CLIPS = {"listen": 3.2, "walk": .5, "tilt": .8, "sweep": 2., "lean": 3.,
         "snatch": 19 / FPS, "recover": .6}


def pose(rig, name, t):
    bones = rig.pose.bones
    for bone in bones:
        bone.location = (0, 0, 0)
        bone.rotation_mode = "QUATERNION"
        bone.rotation_quaternion = (1, 0, 0, 0)
    bpy.context.view_layer.update()

    def rotate(bone_name, x=0., y=0., z=0.):
        bone = bones[bone_name]
        basis = bone.bone.matrix_local.to_quaternion()
        bone.rotation_quaternion = basis.inverted() @ Euler((x, y, z)).to_quaternion() @ basis

    def aim(bone_name, direction):
        bone = bones[bone_name]
        local_direction = bone.matrix.to_quaternion().inverted() @ Vector(direction)
        bone.rotation_quaternion = Vector((0, 1, 0)).rotation_difference(local_direction)
        bpy.context.view_layer.update()

    lean, turn, tilt, lunge, sweep, open_blades = 0., 0., 0., 0., 0., 0.
    gait = tau * t / CLIPS["walk"]
    badge_swing = 0.
    if name == "listen":
        turn = -.37 * sin(tau * t / CLIPS[name])
    elif name == "walk":
        badge_swing = .33 * sin(gait)
    elif name == "tilt":
        turn = .19 * smoothstep(t / .26)
        tilt = -.42 * smoothstep(t / .24)
    elif name == "sweep":
        sweep = sin(tau * (t / 2. - .17)) * sin(pi * t / 2.)
        turn = .31 * sweep
        lean = .22 * sin(pi * t / 2.)
        badge_swing = -.25 * sweep
    elif name == "lean":
        lean = .85 * smoothstep(t / .55) + .15 * smoothstep((t - .55) / 1.95)
        tilt = -.21 * lean
        badge_swing = .32 * sin(11 * t) * (1 - smoothstep(t / 1.1))
    elif name == "snatch":
        lunge = smoothstep(t / .2) * (1 - smoothstep((t - .2) / .44))
        lean = .35 + .39 * lunge
        open_blades = .49 * min(smoothstep(t / .133), 1 - smoothstep((t - .14) / .06))
        badge_swing = -.4 * lunge
    elif name == "recover":
        lean = 1 - smoothstep(t / .6)
        tilt = -.21 * lean

    breath = .012 * sin(t * tau / 3.2) if name == "listen" else 0
    dip = .10 * lean + .034
    if name == "walk":
        dip += .14 + .031 * cos(gait * 2)
    hips = bones["Hips"]
    hips.location = hips.bone.matrix_local.to_quaternion().inverted() @ Vector((0, -.046 * lean, -dip))
    rotate("Hips", -.075, .035)
    rotate("Spine", .15 + .53 * lean + breath, -.043 - .12 * lunge, sweep * .14)
    rotate("Chest", .26 + .38 * lean + .16 * lunge, -.083, -.08 - sweep * .28)
    rotate("Neck", .23 - .26 * lean, .125, turn * .43)
    rotate("Head", -.13 - .25 * lean - .05 * lunge, tilt + .17, turn)
    rotate("Badges", -.67 * lean + badge_swing, .1 * badge_swing, badge_swing * .62)
    bpy.context.view_layer.update()

    # Aim the bent arms in room space so a deep lean keeps its shears below the face.
    aim("UpperArm.L", (.42 - .16 * lean, -.08 - .36 * lean + .62 * lunge -
                      (.44 * sin(gait) if name == "walk" else 0), -.87 + .32 * lean))
    aim("Forearm.L", (.08 - .16 * lean, -.16 - .49 * lean - lunge -
                     (.5 * sin(gait) if name == "walk" else 0), -.94 + .38 * lean + .57 * lunge))
    aim("Hand.L", (.04, -.34 - .27 * lean, -.89 + .38 * lean + .53 * lunge))
    aim("UpperArm.R", (-.50 + .43 * lunge, -.02 - .27 * lean - 1.05 * lunge -
                      .47 * abs(sweep) + (.31 * sin(gait) if name == "walk" else 0), -.81 + .22 * lean + .4 * lunge))
    aim("Forearm.R", (.20 + 1.12 * sweep + .38 * lunge,
                     -.56 - .24 * lean - .94 * lunge + (.28 * sin(gait) if name == "walk" else 0),
                     -.76 + .29 * abs(sweep) + .69 * lunge))
    hand_direction = Vector((-.12 + 1.2 * sweep + .12 * lunge, -.15 - .86 * lunge -
                            .32 * abs(sweep) + (.24 * sin(gait) if name == "walk" else 0),
                            -.92 + .27 * lean + .91 * lunge + .38 * abs(sweep)))
    if name == "walk":
        # Clear the planted foot and floor on the downbeat.
        hand_direction.y -= .25
    aim("Hand.R", hand_direction)
    rotate("Blade.B", z=-2 * open_blades)

    # Solve both knees in a forward plane with fixed world-space ankle targets.
    # In-place travel is intentional: the host supplies the figure's displacement.
    for side, sign in (("L", 1), ("R", -1)):
        _, _, rest_ankle, _ = leg_points(sign)
        thigh, shin = bones["Thigh." + side], bones["Shin." + side]
        ankle = Vector(rest_ankle)
        ankle.y -= .045 * lean
        ankle.x += .024 * sign
        if name == "walk":
            phase = (t / CLIPS[name] + (0 if sign == 1 else .5)) % 1
            if phase < .5:
                ankle.y += -.53 + 2.12 * phase
            else:
                swing = (phase - .5) * 2
                ankle.y += .53 - 1.06 * smoothstep(swing)
                ankle.z += .24 * sin(swing * pi)
        offset = ankle - thigh.head
        length = min(offset.length, thigh.length + shin.length - .001)
        direction = offset.normalized()
        plane = Vector((0, -1, 0))
        plane = (plane - plane.dot(direction) * direction).normalized()
        knee_along = (thigh.length ** 2 + length ** 2 - shin.length ** 2) / (2 * length)
        knee = thigh.head + direction * knee_along + plane * sqrt(max(0, thigh.length ** 2 - knee_along ** 2))
        aim(thigh.name, knee - thigh.head)
        aim(shin.name, ankle - shin.head)
        foot = bones["Foot." + side]
        foot.rotation_quaternion = foot.matrix.to_quaternion().inverted() @ foot.bone.matrix_local.to_quaternion()
        bpy.context.view_layer.update()


def animate(rig, mixamo_dir):
    rig.animation_data_create()
    rig.animation_data.use_nla = False
    scene = bpy.context.scene
    scene.render.fps = FPS
    takes = {}
    if mixamo_dir is not None:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from retarget_mixamo import apply_take, load_takes

        takes = load_takes(mixamo_dir, rig, CLIPS, FPS)
    for name, duration in CLIPS.items():
        stop = round(duration * FPS)
        action = bpy.data.actions.new(name)
        step = 3 if name in ("listen", "lean", "recover") else 2
        if name in takes:
            step = 1
        sample_frames = sorted({*range(0, stop + 1, step), stop})
        if name == "snatch":
            sample_frames = sorted({*sample_frames, 4, 5, 6})
        slot = None
        for frame in sample_frames:
            time = frame / FPS
            if frame == stop and name in ("listen", "walk"):
                time = 0.
            pose(rig, name, time)
            if name in takes:
                apply_take(rig, name, takes[name][round(time * FPS)], time, duration)
            rig.animation_data.action = action
            for bone in rig.pose.bones:
                if bone.name == "Root":
                    continue
                bone.keyframe_insert("rotation_quaternion", frame=frame, group=bone.name)
                if bone.name == "Hips" or (bone.name == "Shears" and name == "tilt" and name in takes):
                    bone.keyframe_insert("location", frame=frame, group=bone.name)
            slot = rig.animation_data.action_slot
            rig.animation_data.action = None
        track = rig.animation_data.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, 0, action)
        strip.action_slot = slot
    rig.animation_data.use_nla = True
    scene.frame_set(0)


def preview(rig):
    PROOF.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 18
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 480
    scene.render.resolution_y = 270
    scene.render.resolution_percentage = 100
    scene.world = bpy.data.worlds.new("Greenhouse at night")
    scene.world.color = (.018, .021, .026)
    scene.view_settings.view_transform = "AgX"
    scene.render.image_settings.file_format = "PNG"
    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, 0))
    ground = bpy.context.object
    ground_mat = bpy.data.materials.new("Forest floor")
    ground_mat.diffuse_color = (.045, .049, .031, 1)
    ground.data.materials.append(ground_mat)
    bpy.ops.object.camera_add()
    camera = bpy.context.object
    scene.camera = camera
    camera.data.lens = 26

    def illuminate(name, location, color, power, size, target, light_type="AREA"):
        light = bpy.data.lights.new(name, light_type)
        light.color, light.energy = color, power
        if light_type == "AREA":
            light.shape, light.size = "DISK", size
        else:
            light.spot_size, light.spot_blend = size, .58
        obj = bpy.data.objects.new(name, light)
        bpy.context.collection.objects.link(obj)
        obj.location = location
        obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()
        return light, obj

    rim, _ = illuminate("Greenhouse lamp", (1.3, 1.8, 3.8), (.63, .82, .62), 185, 1.5, (0, 0, 1.4))
    key, spot = illuminate("Crew torch", (0, -3.4, 1.6), (1, .86, .66), 280, .58, (0, 0, 1.39), "SPOT")
    for label, anim, time, at, target, power, back in [
        ("01_flashlight", "listen", 0, (0, -3.9, 1.57), (0, 0, 1.35), 265, 100),
        ("02_profile", "listen", 0, (3.95, -.52, 1.63), (0, 0, 1.32), 300, 135),
        ("03_backlight", "listen", .38, (0, -7.8, 1.57), (0, 0, 1.3), 0, 205),
        ("04_lean", "lean", 1.55, (.07, -2.6, 1.51), (0, -.58, 1.35), 180, 100),
        ("05_walk", "walk", .11, (1.8, -3.5, 1.54), (0, 0, 1.24), 290, 150),
        ("06_tilt", "tilt", .23, (-.92, -3.85, 1.77), (0, 0, 1.32), 265, 95),
        ("07_sweep", "sweep", .83, (-1.55, -3.72, 1.55), (0, 0, 1.26), 290, 135),
        ("08_snatch_open", "snatch", 4 / FPS, (.43, -3.25, 1.55), (0, -.4, 1.31), 190, 125),
        ("09_snatch_closed", "snatch", .2, (.43, -3.25, 1.55), (0, -.4, 1.31), 190, 125),
    ]:
        rig.animation_data.action = bpy.data.actions[anim]
        frame = time * FPS
        scene.frame_set(int(frame), subframe=frame % 1)
        camera.location = at
        camera.rotation_euler = (Vector(target) - camera.location).to_track_quat("-Z", "Y").to_euler()
        spot.location = camera.location + Vector((-.11, 0, -.07))
        spot.rotation_euler = camera.rotation_euler
        key.energy, rim.energy = power, back
        scene.render.filepath = str(PROOF / f"{label}.png")
        bpy.ops.render.render(write_still=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mixamo-dir", type=Path, help="directory containing the six motion FBXs")
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    material = make_atlas()
    rig = make_rig()

    # Give Mixamo a clean figure with recognisable palms and articulated knees.
    # All loose equipment is on the game rig only.
    if args.mixamo_dir is None:
        upload = body().mesh("Groundskeeper_T_Pose", material)
        bpy.ops.object.select_all(action="DESELECT")
        upload.select_set(True)
        bpy.context.view_layer.objects.active = upload
        bpy.ops.export_scene.fbx(filepath=str(REPO / "assets_src/mixamo/export/groundskeeper.fbx"),
                                 use_selection=True, object_types={"MESH"}, bake_anim=False)
        bpy.data.objects.remove(upload, do_unlink=True)

    geometry = body()
    details(geometry)
    geometry.mesh("Groundskeeper", material, rig)
    animate(rig, args.mixamo_dir)
    path = REPO / "godot/assets/entities/groundskeeper.glb"
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB",
                              export_animation_mode="NLA_TRACKS", export_force_sampling=True,
                              export_image_format="AUTO")
    print(f"{path.name}: {len(geometry.vertices)} mesh vertices, {len(rig.pose.bones)} bones")
    if args.preview:
        preview(rig)


if __name__ == "__main__":
    main()
