"""Build "the Orderly" from an empty scene and export a skinned, animated GLB.

Usage (headless):
  blender.exe --background --factory-startup --python build_orderly.py -- [--out PATH] [--blend PATH]

Pattern for future characters: edit the PARAMETER block, the BONES table, the
body-part builders and the POSE specs. Everything is deterministic (seeded RNG).
Blender space: Z up, character faces -Y, X = character's left. glTF export turns
this into +Y up, facing +Z.
"""
import bpy, sys, os, math, argparse
import numpy as np
from mathutils import Vector, Quaternion

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# =========================== PARAMETERS ===========================
P = dict(
    name="Orderly",
    height=2.30,        # all nominal dims below are authored for 2.30 m and scaled
    stoop=1.0,          # multiplier on forward offset of chest/neck/head
    arm_scale=1.08,     # multiplier on arm length below the shoulder
    head_scale=1.0,     # head ellipsoid size multiplier
    sides=dict(torso=16, gown=24, arm=10, leg=10, finger=5, sleeve=10),
    fingers=3,
    tex_size=256,
    colors=dict(        # sRGB 0..1
        skin=(0.55, 0.57, 0.56), skin_dark=(0.47, 0.45, 0.47),
        gown=(0.63, 0.76, 0.69), gown_line=(0.52, 0.64, 0.58), stain=(0.56, 0.47, 0.28),
        cap=(0.60, 0.73, 0.80), mask=(0.76, 0.86, 0.91), mask_line=(0.62, 0.72, 0.78),
        ink=(0.04, 0.04, 0.06), cheek=(0.95, 0.52, 0.58), tie=(0.88, 0.88, 0.84),
    ),
    fps=24,
    step=3,             # frames per pose for stepped actions (24/3 = 8 poses/s)
)
S = P["height"] / 2.30

# Atlas regions (u0, v0, u1, v1)
REG = dict(mask=(0.0, 0.5, 0.5, 1.0), gown=(0.5, 0.5, 1.0, 1.0),
           skin=(0.0, 0.0, 0.25, 0.25), skin_dark=(0.25, 0.0, 0.5, 0.25),
           cap=(0.5, 0.0, 0.75, 0.25), tie=(0.75, 0.0, 1.0, 0.25))


def V(x, y, z):
    return Vector((x * S, y * S, z * S))


# Spine curve (z -> forward offset); stoop bends the upper body forward
SPINE = [(1.00, 0.0), (1.30, 0.0), (1.52, -0.02), (1.71, -0.07), (1.86, -0.15), (2.03, -0.29)]


def spine_y(z):
    pts = SPINE
    if z <= pts[0][0]:
        return pts[0][1] * P["stoop"]
    for (z0, y0), (z1, y1) in zip(pts, pts[1:]):
        if z <= z1:
            t = (z - z0) / (z1 - z0)
            return (y0 + (y1 - y0) * t) * P["stoop"]
    return pts[-1][1] * P["stoop"]


HEAD_C = (0.0, -0.32 * P["stoop"], 2.14)
HEAD_R = (0.082 * P["head_scale"], 0.095 * P["head_scale"], 0.11 * P["head_scale"])


def arm_pts(side):
    """Shoulder->fingertip chain points for side +1 (left) / -1 (right)."""
    sx = side
    sh = (0.16 * sx, spine_y(1.76) + 0.02, 1.76)  # slumped, narrow shoulders
    rel = [(0.03, 0.02, -0.52), (0.03, -0.03, -0.51), (0.008, -0.01, -0.13), (0.002, -0.005, -0.12), (0.0, -0.005, -0.13)]
    pts = [sh]
    for dx, dy, dz in rel:
        a = P["arm_scale"]
        x, y, z = pts[-1]
        pts.append((x + dx * sx * a, y + dy * a, z + dz * a))
    return pts  # shoulder, elbow, wrist, knuckle, finger joint, tip


# ============================ ARMATURE ============================
def bone_table():
    b = {}
    b["hips"] = ((0, 0, 1.02), (0, 0, 1.30), None)
    b["spine"] = ((0, 0, 1.30), (0, spine_y(1.52), 1.52), "hips")
    b["spine1"] = ((0, spine_y(1.52), 1.52), (0, spine_y(1.71), 1.71), "spine")
    b["spine2"] = ((0, spine_y(1.71), 1.71), (0, spine_y(1.86), 1.86), "spine1")
    b["neck"] = ((0, spine_y(1.86), 1.86), (0, spine_y(2.05), 2.05), "spine2")
    b["head"] = ((0, HEAD_C[1] + 0.01, 2.05), (0, HEAD_C[1] + 0.0, 2.05 + 0.22 * P["head_scale"]), "neck")
    for side, sfx in ((1, ".L"), (-1, ".R")):
        a = arm_pts(side)
        b["clavicle" + sfx] = ((0.03 * side, spine_y(1.82), 1.82), a[0], "spine2")
        b["upperarm" + sfx] = (a[0], a[1], "clavicle" + sfx)
        b["forearm" + sfx] = (a[1], a[2], "upperarm" + sfx)
        b["hand" + sfx] = (a[2], a[3], "forearm" + sfx)
        b["finger1" + sfx] = (a[3], a[4], "hand" + sfx)
        b["finger2" + sfx] = (a[4], a[5], "finger1" + sfx)
        b["thigh" + sfx] = ((0.095 * side, 0.0, 1.10), (0.10 * side, -0.025, 0.64), "hips")
        b["shin" + sfx] = ((0.10 * side, -0.025, 0.64), (0.105 * side, 0.0, 0.09), "thigh" + sfx)
        b["foot" + sfx] = ((0.105 * side, 0.0, 0.09), (0.11 * side, -0.19, 0.025), "shin" + sfx)
    return b


def build_armature(bt):
    arm_data = bpy.data.armatures.new(P["name"] + "_Rig")
    arm = bpy.data.objects.new(P["name"] + "_Rig", arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (h, t, parent) in bt.items():
        eb = arm_data.edit_bones.new(name)
        eb.head, eb.tail = V(*h), V(*t)
        eb.roll = 0.0
    for name, (h, t, parent) in bt.items():
        if parent:
            arm_data.edit_bones[name].parent = arm_data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


# ============================ MESH KIT ============================
def ruv(reg, u, v):
    m = 0.03
    u = m + (1 - 2 * m) * u
    v = m + (1 - 2 * m) * v
    return (reg[0] + (reg[2] - reg[0]) * u, reg[1] + (reg[3] - reg[1]) * v)


class MeshBuilder:
    def __init__(self):
        self.co, self.w, self.faces, self.uvs = [], [], [], []

    def vert(self, co, w):
        self.co.append(Vector(co))
        self.w.append(dict(w))
        return len(self.co) - 1

    def face(self, idx, uv, interior=None):
        idx, uv = list(idx), list(uv)
        if interior is not None:
            pts = [self.co[i] for i in idx]
            n = Vector((0, 0, 0))
            for a, b in zip(pts, pts[1:] + pts[:1]):
                n += a.cross(b)
            c = sum(pts, Vector()) / len(pts)
            if n.dot(c - Vector(interior)) < 0:
                idx.reverse(); uv.reverse()
        self.faces.append(idx)
        self.uvs.append(uv)


def frame_for(t):
    x = Vector((1, 0, 0))
    if abs(t.dot(x)) > 0.9:
        x = Vector((0, 1, 0))
    xp = (x - t * x.dot(t)).normalized()
    return xp, t.cross(xp)


def tube(mb, rings, sides, reg, cap0=True, cap1=True, angles=None):
    """rings: list of (center Vector, rx, ry, weights). Returns ring vertex index lists."""
    n = len(rings)
    cs = [r[0] for r in rings]
    if angles is None:
        angles = [2 * math.pi * k / sides for k in range(sides)]
    idx = []
    for i, (c, rx, ry, w) in enumerate(rings):
        t = (cs[min(i + 1, n - 1)] - cs[max(i - 1, 0)]).normalized()
        xp, yp = frame_for(t)
        idx.append([mb.vert(c + xp * (rx * math.cos(a)) + yp * (ry * math.sin(a)), w) for a in angles])
    for i in range(n - 1):
        interior = (cs[i] + cs[i + 1]) / 2
        for k in range(sides):
            k2 = (k + 1) % sides
            q = [idx[i][k], idx[i][k2], idx[i + 1][k2], idx[i + 1][k]]
            uv = [ruv(reg, k / sides, i / (n - 1)), ruv(reg, (k + 1) / sides, i / (n - 1)),
                  ruv(reg, (k + 1) / sides, (i + 1) / (n - 1)), ruv(reg, k / sides, (i + 1) / (n - 1))]
            mb.face(q, uv, interior)
    for end, use in ((0, cap0), (n - 1, cap1)):
        if not use:
            continue
        nb = 1 if end == 0 else n - 2
        c, rx, ry, w = rings[end]
        out = (c - cs[nb]).normalized()
        tip = mb.vert(c + out * (0.35 * min(rx, ry)), w)
        for k in range(sides):
            k2 = (k + 1) % sides
            mb.face([tip, idx[end][k], idx[end][k2]],
                    [ruv(reg, 0.5, 0.5), ruv(reg, k / sides, 0.0), ruv(reg, (k + 1) / sides, 0.0)], cs[nb])
    return idx


def box(mb, c, size, w, reg):
    c = Vector(c)
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    vs = [mb.vert(c + Vector((sx * hx, sy * hy, sz * hz)), w)
          for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    for q in quads:
        mb.face([vs[i] for i in q], [ruv(reg, 0, 0), ruv(reg, 1, 0), ruv(reg, 1, 1), ruv(reg, 0, 1)], c)


def lerp_w(z, table):
    """table: list of (z, {bone: w}) sorted descending or ascending; linear blend."""
    tb = sorted(table, key=lambda e: e[0])
    if z <= tb[0][0]:
        return dict(tb[0][1])
    for (z0, w0), (z1, w1) in zip(tb, tb[1:]):
        if z <= z1:
            t = (z - z0) / (z1 - z0)
            out = {}
            for k in set(w0) | set(w1):
                out[k] = w0.get(k, 0) * (1 - t) + w1.get(k, 0) * t
            return out
    return dict(tb[-1][1])


# ============================ BODY PARTS ============================
def build_torso(mb):
    spec = [  # z, rx, ry, weights
        (1.00, 0.10, 0.075, {"hips": 1}), (1.12, 0.12, 0.085, {"hips": 1}),
        (1.30, 0.10, 0.072, {"hips": .5, "spine": .5}), (1.45, 0.105, 0.072, {"spine": 1}),
        (1.60, 0.125, 0.078, {"spine": .5, "spine1": .5}), (1.72, 0.14, 0.082, {"spine1": .5, "spine2": .5}),
        (1.80, 0.15, 0.082, {"spine2": 1}), (1.86, 0.08, 0.06, {"spine2": .6, "neck": .4}),
    ]
    rings = [(V(0, spine_y(z), z), rx * S, ry * S, w) for z, rx, ry, w in spec]
    tube(mb, rings, P["sides"]["torso"], REG["skin"], cap0=True, cap1=False)
    neck = [(V(0, spine_y(1.84), 1.84), 0.056 * S, 0.05 * S, {"spine2": .5, "neck": .5}),
            (V(0, spine_y(1.94), 1.94), 0.046 * S, 0.044 * S, {"neck": 1}),
            (V(0, spine_y(2.05), 2.05), 0.042 * S, 0.042 * S, {"neck": .4, "head": .6})]
    tube(mb, neck, 8, REG["skin"], cap0=False, cap1=True)


def build_head(mb):
    hc = Vector(V(*HEAD_C))
    rx, ry, rz = (r * S for r in HEAD_R)
    segs = 12
    lats = [-90, -70, -50, -30, -12, 6, 24, 42, 60, 76, 90]
    dents = {(1, 24): 0.020, (11, 24): 0.020, (1, 6): 0.007, (11, 6): 0.007, (0, 24): 0.004}
    grid = {}
    W = {"head": 1}
    for li, lat in enumerate(lats):
        if abs(lat) == 90:
            grid[(0, lat)] = mb.vert(hc + Vector((0, 0, rz * (1 if lat > 0 else -1))), W)
            continue
        for k in range(segs):
            a = math.radians(-90 + 30 * k)
            la = math.radians(lat)
            d = Vector((rx * math.cos(la) * math.cos(a), ry * math.cos(la) * math.sin(a), rz * math.sin(la)))
            dent = dents.get((k, lat), 0.0) * S
            if dent:
                d -= d.normalized() * dent
            grid[(k, lat)] = mb.vert(hc + d, W)
    dark = set(grid[k] for k in dents if k[1] == 24 and k[0] != 0)

    def reg_for(ids):
        return REG["skin_dark"] if any(i in dark for i in ids) else REG["skin"]

    for li in range(len(lats) - 1):
        l0, l1 = lats[li], lats[li + 1]
        for k in range(segs):
            k2 = (k + 1) % segs
            uv0, uv1 = k / segs, (k + 1) / segs
            v0, v1 = li / (len(lats) - 1), (li + 1) / (len(lats) - 1)
            if l0 == -90:
                ids = [grid[(0, l0)], grid[(k2, l1)], grid[(k, l1)]]
                uvs = [(0.5, v0), (uv1, v1), (uv0, v1)]
            elif l1 == 90:
                ids = [grid[(k, l0)], grid[(k2, l0)], grid[(0, l1)]]
                uvs = [(uv0, v0), (uv1, v0), (0.5, v1)]
            else:
                ids = [grid[(k, l0)], grid[(k2, l0)], grid[(k2, l1)], grid[(k, l1)]]
                uvs = [(uv0, v0), (uv1, v0), (uv1, v1), (uv0, v1)]
            reg = reg_for(ids)
            mb.face(ids, [ruv(reg, u, v) for u, v in uvs], hc)


def build_cap(mb):
    hc = Vector(V(*HEAD_C))
    rx, ry, rz = (r * S for r in HEAD_R)
    segs, rows = 12, 5
    ring_ids = []
    for j in range(rows):
        t = j / rows
        ids = []
        for k in range(segs):
            a = math.radians(-90 + 30 * k)
            front = 0.5 + 0.5 * math.cos(math.radians(30 * k))  # 1 at front, 0 at back
            lat_edge = -15 + 55 * front
            lat = math.radians(lat_edge + (88 - lat_edge) * t)
            puff = 1.10 + 0.10 * math.sin(math.pi * min(1, t * 1.3)) + 0.04 * (1 - front)
            d = Vector((rx * puff * math.cos(lat) * math.cos(a), ry * puff * math.cos(lat) * math.sin(a),
                        rz * (puff + 0.06) * math.sin(lat)))
            ids.append(mb.vert(hc + d, {"head": 1}))
        ring_ids.append(ids)
    top = mb.vert(hc + Vector((0, 0.01 * S, rz * 1.30)), {"head": 1})
    for j in range(rows - 1):
        for k in range(segs):
            k2 = (k + 1) % segs
            mb.face([ring_ids[j][k], ring_ids[j][k2], ring_ids[j + 1][k2], ring_ids[j + 1][k]],
                    [ruv(REG["cap"], k / segs, j / rows), ruv(REG["cap"], (k + 1) / segs, j / rows),
                     ruv(REG["cap"], (k + 1) / segs, (j + 1) / rows), ruv(REG["cap"], k / segs, (j + 1) / rows)], hc)
    for k in range(segs):
        k2 = (k + 1) % segs
        mb.face([ring_ids[-1][k], ring_ids[-1][k2], top],
                [ruv(REG["cap"], k / segs, 0.8), ruv(REG["cap"], (k + 1) / segs, 0.8), ruv(REG["cap"], 0.5, 1.0)], hc)


MASK = dict(a_half=100.0, lat0=-64.0, lat1=4.0, cols=10, rows=4, scale=1.08, proud=0.008)


def mask_point(a_deg, lat_deg):
    hc = Vector(V(*HEAD_C))
    rx, ry, rz = (r * S for r in HEAD_R)
    a, la = math.radians(-90 + a_deg), math.radians(lat_deg)
    s = MASK["scale"]
    d = Vector((rx * s * math.cos(la) * math.cos(a), ry * s * math.cos(la) * math.sin(a), rz * s * math.sin(la)))
    # paper mask stands proud of the face at the centre
    d.y -= MASK["proud"] * S * math.cos(math.radians(a_deg)) ** 2 * math.cos(la)
    return hc + d


def mask_size():
    """Approximate physical width/height (m) of mask UV space, so the print stays round."""
    w = sum((mask_point(-MASK["a_half"] + 2 * MASK["a_half"] * i / 40, -25) -
             mask_point(-MASK["a_half"] + 2 * MASK["a_half"] * (i + 1) / 40, -25)).length for i in range(40))
    h = sum((mask_point(0, MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * i / 40) -
             mask_point(0, MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * (i + 1) / 40)).length for i in range(40))
    return w, h


def build_mask(mb):
    cols, rows = MASK["cols"], MASK["rows"]
    hc = Vector(V(*HEAD_C))
    ids = [[mb.vert(mask_point(-MASK["a_half"] + 2 * MASK["a_half"] * i / cols,
                               MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * j / rows), {"head": 1})
            for i in range(cols + 1)] for j in range(rows + 1)]
    for j in range(rows):
        for i in range(cols):
            mb.face([ids[j][i], ids[j][i + 1], ids[j + 1][i + 1], ids[j + 1][i]],
                    [ruv(REG["mask"], i / cols, j / rows), ruv(REG["mask"], (i + 1) / cols, j / rows),
                     ruv(REG["mask"], (i + 1) / cols, (j + 1) / rows), ruv(REG["mask"], i / cols, (j + 1) / rows)], hc)
    # ear loops: thin strips from the mask's side edges round to the back of the head
    for side in (0, cols):
        for j in (1, rows - 1):
            p0 = ids[j][side]
            back = mask_point(180.0 if side else -180.0, MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * j / rows)
            back.y -= 0.0
            a = mb.vert(back, {"head": 1})
            b = mb.vert(back + Vector((0, 0, 0.008 * S)), {"head": 1})
            c = mb.vert(mb.co[p0] + Vector((0, 0, 0.008 * S)), {"head": 1})
            mb.face([p0, a, b, c], [ruv(REG["tie"], 0, 0), ruv(REG["tie"], 1, 0), ruv(REG["tie"], 1, 1), ruv(REG["tie"], 0, 1)])


def build_arm(mb, side, sfx):
    a = arm_pts(side)
    sh, el, wr, kn, fj, tip = (Vector(V(*p)) for p in a)
    clav_in = Vector(V(0.11 * side, spine_y(1.78) + 0.02, 1.78))
    U, F, H, C = "upperarm" + sfx, "forearm" + sfx, "hand" + sfx, "clavicle" + sfx

    def along(p, q, t):
        return p + (q - p) * t

    up_len = (el - sh).length
    e_up = along(el, sh, 0.05 / up_len * S)
    e_dn = along(el, wr, 0.05 / (wr - el).length * S)
    rings = [
        (clav_in, 0.05 * S, 0.05 * S, {C: 1}),
        (sh, 0.052 * S, 0.05 * S, {C: .4, U: .6}),
        (along(sh, el, 0.3), 0.046 * S, 0.044 * S, {U: 1}),
        (e_up, 0.037 * S, 0.037 * S, {U: .8, F: .2}),
        (el, 0.04 * S, 0.038 * S, {U: .5, F: .5}),
        (e_dn, 0.036 * S, 0.036 * S, {U: .2, F: .8}),
        (along(el, wr, 0.45), 0.037 * S, 0.035 * S, {F: 1}),
        (along(el, wr, 0.9), 0.026 * S, 0.024 * S, {F: .7, H: .3}),
        (wr, 0.022 * S, 0.026 * S, {F: .4, H: .6}),
    ]
    tube(mb, rings, P["sides"]["arm"], REG["skin"], cap0=True, cap1=False)
    # palm: thin in X, wide front-back (palm faces the body)
    palm = [(wr, 0.016 * S, 0.03 * S, {F: .3, H: .7}), (along(wr, kn, 0.5), 0.017 * S, 0.045 * S, {H: 1}),
            (kn, 0.014 * S, 0.044 * S, {H: 1})]
    tube(mb, palm, 8, REG["skin"], cap0=False, cap1=True)
    F1, F2 = "finger1" + sfx, "finger2" + sfx
    nf = P["fingers"]
    for i in range(nf):
        off = (i - (nf - 1) / 2) * 0.030 * S
        o = Vector((0.004 * side * S, off, 0))
        splay = Vector((0.010 * side * S, off * 0.5, 0))
        rings = [(kn + o, 0.010 * S, 0.011 * S, {H: .5, F1: .5}),
                 (along(kn, fj, 0.5) + o + splay * 0.3, 0.0095 * S, 0.0095 * S, {F1: 1}),
                 (fj + o + splay * 0.6, 0.0095 * S, 0.0095 * S, {F1: .5, F2: .5}),
                 (along(fj, tip, 0.6) + o + splay * 0.85, 0.0085 * S, 0.0085 * S, {F2: 1}),
                 (tip + o + splay + Vector((0, -0.01 * S, 0)), 0.006 * S, 0.006 * S, {F2: 1})]
        tube(mb, rings, P["sides"]["finger"], REG["skin_dark"] if i == 1 else REG["skin"], cap0=False, cap1=True)


def build_leg(mb, side, sfx):
    T, Sh, Ft = "thigh" + sfx, "shin" + sfx, "foot" + sfx
    x = lambda z: (0.088 + 0.017 * (1.10 - z) / 1.0) * side
    kz = 0.64
    spec = [(1.14, 0.052, {T: .5, "hips": .5}), (0.95, 0.050, {T: 1}), (0.70, 0.047, {T: .8, Sh: .2}),
            (0.64, 0.05, {T: .5, Sh: .5}), (0.58, 0.045, {T: .2, Sh: .8}), (0.46, 0.047, {Sh: 1}),
            (0.25, 0.033, {Sh: 1}), (0.12, 0.029, {Sh: .6, Ft: .4}), (0.07, 0.034, {Sh: .2, Ft: .8})]
    rings = []
    for z, r, w in spec:
        y = -0.025 * (1 - abs(z - kz) / 0.5) if abs(z - kz) < 0.5 else 0.0
        rings.append((V(x(z), y, z), r * S, r * S, w))
    tube(mb, rings, P["sides"]["leg"], REG["skin"], cap0=True, cap1=False)
    # long bare foot, horizontal tube heel -> toe (ry is vertical for a -Y tube)
    fx = 0.105 * side
    fspec = [(0.045, 0.030, 0.030), (0.0, 0.040, 0.046), (-0.08, 0.044, 0.028), (-0.17, 0.046, 0.019), (-0.235, 0.032, 0.011)]
    frings = [(V(fx + 0.004 * side * (-y / 0.2), y, rz), rx * S, rz * S, {Ft: 1}) for y, rx, rz in fspec]
    tube(mb, frings, 8, REG["skin"], cap0=True, cap1=True)


GOWN = dict(  # z, rx, ry, extra forward offset
    rings=[(1.92, 0.072, 0.062, 0.0), (1.88, 0.11, 0.088, 0.0), (1.82, 0.16, 0.098, 0.0), (1.73, 0.18, 0.105, 0.0),
           (1.62, 0.15, 0.105, 0.0), (1.48, 0.125, 0.10, 0.0), (1.30, 0.13, 0.105, 0.0), (1.10, 0.15, 0.115, -0.01),
           (0.90, 0.168, 0.13, -0.02), (0.70, 0.18, 0.14, -0.03), (0.55, 0.19, 0.148, -0.035),
           (0.42, 0.198, 0.152, -0.04)],
    hem_z=0.42, slit_down_to=0.80,
)


def gown_weights(p):
    z = p.z / S
    w = lerp_w(z, [(1.10, {"hips": 1}), (1.30, {"hips": .5, "spine": .5}), (1.45, {"spine": 1}),
                   (1.62, {"spine": .5, "spine1": .5}), (1.74, {"spine1": .3, "spine2": .7}), (1.84, {"spine2": 1})])
    if z < 1.10:
        t = min(1.0, (1.10 - z) / (1.10 - GOWN["hem_z"])) ** 0.7 * 0.75
        sl = max(0.0, min(1.0, 0.5 + p.x / (0.12 * S)))
        w = {"hips": 1 - t, "thigh.L": t * sl, "thigh.R": t * (1 - sl)}
    return w


def build_gown(mb):
    sides = P["sides"]["gown"]
    step = 360.0 / sides
    base = [step / 2 + step * k for k in range(sides)]  # column centred on +Y (back) between k_b and k_b+1
    kb = int((90 - step / 2) // step)  # vertex just before back centre
    rings = GOWN["rings"]
    zs = [r[0] for r in rings]
    ids = []
    for (z, rx, ry, fy) in rings:
        ang = list(base)
        slit = z >= GOWN["slit_down_to"]
        if slit:  # open back: pull the two edge columns apart
            ang[kb], ang[kb + 1] = 90 - 15, 90 + 15
        cy = spine_y(z) + fy
        row = []
        for a in ang:
            p = V(rx * math.cos(math.radians(a)), cy + ry * math.sin(math.radians(a)), z)
            row.append(mb.vert(p, gown_weights(p)))
        ids.append(row)
    n = len(rings)
    for i in range(n - 1):
        both_slit = zs[i] >= GOWN["slit_down_to"] and zs[i + 1] >= GOWN["slit_down_to"]
        interior = V(0, spine_y((zs[i] + zs[i + 1]) / 2), (zs[i] + zs[i + 1]) / 2)
        for k in range(sides):
            if both_slit and k == kb:
                continue
            k2 = (k + 1) % sides
            vv0 = (zs[i] - GOWN["hem_z"]) / (zs[0] - GOWN["hem_z"])
            vv1 = (zs[i + 1] - GOWN["hem_z"]) / (zs[0] - GOWN["hem_z"])
            mb.face([ids[i][k], ids[i][k2], ids[i + 1][k2], ids[i + 1][k]],
                    [ruv(REG["gown"], k / sides, vv0), ruv(REG["gown"], (k + 1) / sides, vv0),
                     ruv(REG["gown"], (k + 1) / sides, vv1), ruv(REG["gown"], k / sides, vv1)], interior)
    # back ties across the slit
    for z in (1.72, 1.20):
        if z < GOWN["slit_down_to"]:
            continue
        y = spine_y(z) + 0.0
        ry = dict((r[0], r[2]) for r in rings)
        ryz = lerp_w(z, [(r[0], {"r": r[2]}) for r in rings])["r"]
        p = V(0, y + ryz, z)
        box(mb, p, (0.11 * S, 0.012 * S, 0.014 * S), gown_weights(p), REG["tie"])
        for s in (-1, 1):  # dangling tie ends
            q = p + Vector((0.012 * s * S, 0.004 * S, -0.04 * S))
            box(mb, q, (0.012 * S, 0.006 * S, 0.07 * S), gown_weights(q), REG["tie"])
    # short sleeves
    for side, sfx in ((1, ".L"), (-1, ".R")):
        a = arm_pts(side)
        sh, el = Vector(V(*a[0])), Vector(V(*a[1]))
        U, C = "upperarm" + sfx, "clavicle" + sfx
        srings = [(sh + (sh - el).normalized() * 0.03 * S, 0.062 * S, 0.062 * S, {C: .6, U: .4}),
                  (sh + (el - sh) * 0.18, 0.064 * S, 0.062 * S, {C: .2, U: .8}),
                  (sh + (el - sh) * 0.40, 0.062 * S, 0.058 * S, {U: 1})]
        tube(mb, srings, P["sides"]["sleeve"], REG["gown"], cap0=False, cap1=False)


# ============================ TEXTURE ============================
def make_atlas():
    n = P["tex_size"]
    C = {k: np.array(v, dtype=np.float32) for k, v in P["colors"].items()}
    rng = np.random.default_rng(1977)
    img = np.ones((n, n, 4), dtype=np.float32)

    def region_px(reg):
        return int(reg[0] * n), int(reg[1] * n), int(reg[2] * n), int(reg[3] * n)

    def fill(reg, col, noise=0.02, blotch=None):
        x0, y0, x1, y1 = region_px(reg)
        h, w = y1 - y0, x1 - x0
        block = np.tile(col, (h, w, 1))
        block += (rng.random((h, w, 1)) - 0.5) * 2 * noise
        if blotch is not None:
            bcol, count, rad = blotch
            yy, xx = np.mgrid[0:h, 0:w]
            for _ in range(count):
                cx, cy, r = rng.random() * w, rng.random() * h, rad * (0.5 + rng.random())
                m = np.clip(1 - ((xx - cx) ** 2 + (yy - cy) ** 2) / r ** 2, 0, 1)[..., None] * 0.35
                block = block * (1 - m) + bcol * m
        img[y0:y1, x0:x1, :3] = np.clip(block, 0, 1)

    fill(REG["skin"], C["skin"], 0.025, (C["skin_dark"], 6, 6))
    fill(REG["skin_dark"], C["skin_dark"], 0.02)
    fill(REG["cap"], C["cap"], 0.02)
    fill(REG["tie"], C["tie"], 0.015)
    # cap elastic band at the bottom edge
    x0, y0, x1, y1 = region_px(REG["cap"])
    img[y0:y0 + 6, x0:x1, :3] = C["cap"] * 0.82

    # gown: vertical crease lines, stained hem (v = 0 is the hem)
    x0, y0, x1, y1 = region_px(REG["gown"])
    h, w = y1 - y0, x1 - x0
    g = np.tile(C["gown"], (h, w, 1)) + (rng.random((h, w, 1)) - 0.5) * 0.03
    for cx in rng.integers(0, w, 9):
        g[:, cx:cx + 1] = g[:, cx:cx + 1] * 0.5 + C["gown_line"] * 0.5
    yy, xx = np.mgrid[0:h, 0:w]
    vfrac = yy / h
    stain = np.clip(1 - vfrac / 0.16, 0, 1) ** 1.5 * 0.55
    for _ in range(14):
        cx, cy, r = rng.random() * w, rng.random() * h * 0.22, 3 + rng.random() * 9
        stain = np.maximum(stain, np.clip(1 - ((xx - cx) ** 2 + (yy - cy) ** 2) / r ** 2, 0, 1) * 0.6)
    stain = stain[..., None]
    g = g * (1 - stain) + C["stain"] * stain
    img[y0:y1, x0:x1, :3] = np.clip(g, 0, 1)

    # mask with printed children's-ward face; draw in physical metres so it stays round
    x0, y0, x1, y1 = region_px(REG["mask"])
    h, w = y1 - y0, x1 - x0
    mw, mh = mask_size()
    yy, xx = np.mgrid[0:h, 0:w]
    m = 0.03
    u = ((xx + 0.5) / w - m) / (1 - 2 * m)
    v = ((yy + 0.5) / h - m) / (1 - 2 * m)
    px, py = (u - 0.5) * mw, (v - 0.5) * mh
    mk = np.tile(C["mask"], (h, w, 1)) + (rng.random((h, w, 1)) - 0.5) * 0.02
    for pl in (0.22, 0.80):  # faint pleats, kept clear of the printed face
        band = (np.abs(v - pl) < 0.012)[..., None]
        mk = np.where(band, mk * 0.5 + C["mask_line"] * 0.5, mk)
    edge = ((v < 0.04) | (v > 0.96))[..., None]
    mk = np.where(edge, C["mask_line"], mk)
    sc = S * P["head_scale"]
    cheek = ((px / (0.012 * sc)) ** 2 + ((py + 0.006 * sc) / (0.009 * sc)) ** 2)
    for s in (-1, 1):
        cm = (((px - s * 0.060 * sc) / (0.011 * sc)) ** 2 + ((py - 0.006 * sc) / (0.008 * sc)) ** 2 < 1)[..., None]
        mk = np.where(cm, mk * 0.4 + C["cheek"] * 0.6, mk)
    for s in (-1, 1):
        eye = ((px - s * 0.027 * sc) ** 2 + (py - 0.024 * sc) ** 2 < (0.0150 * sc) ** 2)[..., None]
        mk = np.where(eye, C["ink"], mk)
    r = np.sqrt(px ** 2 + (py - 0.016 * sc) ** 2)
    ang = np.arctan2(py - 0.016 * sc, px)
    smile = ((np.abs(r - 0.046 * sc) < 0.0090 * sc) & (ang < -0.28) & (ang > -math.pi + 0.28))[..., None]
    mk = np.where(smile, C["ink"], mk)
    img[y0:y1, x0:x1, :3] = np.clip(mk, 0, 1)

    im = bpy.data.images.new(P["name"] + "_atlas", n, n, alpha=False)
    im.pixels.foreach_set(img.ravel())
    im.pack()
    return im


def make_material(image):
    mat = bpy.data.materials.new(P["name"] + "_mat")
    try:
        mat.use_nodes = True
    except Exception:
        pass
    nt = mat.node_tree
    bsdf = next((nd for nd in nt.nodes if nd.type == "BSDF_PRINCIPLED"), None)
    out = next((nd for nd in nt.nodes if nd.type == "OUTPUT_MATERIAL"), None)
    if bsdf is None:
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    if out is None:
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.85
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.2
    mat.use_backface_culling = False  # gown/mask are open shells -> glTF doubleSided
    return mat


# ============================ ASSEMBLY ============================
def build_mesh(arm, bt):
    mb = MeshBuilder()
    build_torso(mb)
    build_head(mb)
    build_cap(mb)
    build_mask(mb)
    for side, sfx in ((1, ".L"), (-1, ".R")):
        build_arm(mb, side, sfx)
        build_leg(mb, side, sfx)
    build_gown(mb)

    me = bpy.data.meshes.new(P["name"])
    me.from_pydata([tuple(c) for c in mb.co], [], mb.faces)
    me.update()
    uvl = me.uv_layers.new(name="UVMap")
    li = 0
    for poly, uvs in zip(me.polygons, mb.uvs):
        for k in range(poly.loop_total):
            uvl.data[poly.loop_start + k].uv = uvs[k]
    for poly in me.polygons:
        poly.use_smooth = False  # flat, late-90s shading
    ob = bpy.data.objects.new(P["name"], me)
    bpy.context.scene.collection.objects.link(ob)
    groups = {name: ob.vertex_groups.new(name=name) for name in bt}
    for vi, w in enumerate(mb.w):
        tot = sum(w.values())
        for bname, val in w.items():
            if val > 1e-4:
                groups[bname].add([vi], val / tot, "REPLACE")
    ob.parent = arm
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    return ob


# ============================ ANIMATION ============================
AX = {"x": Vector((1, 0, 0)), "y": Vector((0, 1, 0)), "z": Vector((0, 0, 1))}


def set_pose(arm, spec):
    """spec: {bone: [("x", deg), ("y", deg), ("s", (sx,sy,sz))]}. Rotations are about
    armature-space axes (+X pitch = lean forward for up-bones / swing back for down-bones)."""
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
        pb.scale = (1, 1, 1)
    for bname, ops in spec.items():
        pb = arm.pose.bones[bname]
        q = Quaternion()
        for op in ops:
            if op[0] == "s":
                pb.scale = op[1]
            else:
                q = Quaternion(AX[op[0]], math.radians(op[1])) @ q
        B = pb.bone.matrix_local.to_quaternion()
        pb.rotation_quaternion = B.inverted() @ q @ B


def iter_fcurves(act):
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for cb in strip.channelbags:
                for fc in cb.fcurves:
                    yield fc


def make_action(arm, name, keys, interp):
    bpy.context.preferences.edit.keyframe_new_interpolation_type = interp
    ad = arm.animation_data or arm.animation_data_create()
    act = bpy.data.actions.new(name)
    ad.action = act
    for frame, spec in keys:
        set_pose(arm, spec)
        for pb in arm.pose.bones:
            for path in ("rotation_quaternion", "location", "scale"):
                pb.keyframe_insert(path, frame=frame, group=pb.name)
    for fc in iter_fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = interp
    act.use_fake_user = True
    track = ad.nla_tracks.new()
    track.name = name
    track.strips.new(name, int(keys[0][0]), act)
    track.mute = True
    ad.action = None
    return act


def mirror(spec):
    """Swap .L/.R and flip y/z rotation signs."""
    out = {}
    for b, ops in spec.items():
        nb = b.replace(".L", ".#").replace(".R", ".L").replace(".#", ".R")
        out[nb] = [(o[0], -o[1]) if o[0] in "yz" else o for o in ops]
    return out


def merge(*specs):
    out = {}
    for s in specs:
        for b, ops in s.items():
            out.setdefault(b, []).extend(ops)
    return out


# Constant asymmetry layered into idle/walk/still: one shoulder hitched, head canted.
BASE = {"clavicle.L": [("y", -4)], "upperarm.L": [("y", 4)],      # left shoulder hitched up
        "clavicle.R": [("y", -3)], "upperarm.R": [("y", 3)],      # right shoulder dropped
        "head": [("y", -5), ("x", 9)], "spine2": [("z", 3)]}      # canted, looking down at you


def idle_keys():
    keys = _idle_keys()
    return [(f, merge(BASE, s)) for f, s in keys]


def _idle_keys():
    breath = lambda a: {"spine1": [("x", -a * 0.6)], "spine2": [("x", -a)], "clavicle.L": [("y", a * 0.8)],
                        "clavicle.R": [("y", -a * 0.8)], "head": [("x", a * 0.8)]}
    tilt = {"head": [("y", 13), ("z", -6)], "neck": [("y", 4)]}
    return [(1, breath(0)), (22, breath(1.6)), (43, breath(0)),
            (50, merge(breath(0.5))), (53, merge(breath(0.6), tilt)), (70, merge(breath(1.2), tilt)),
            (78, merge(breath(0.6), {"head": [("y", 4)]})), (85, breath(0))]


def walk_pose(p):
    """Stiff glide: short stride, almost no knee, flat feet, arms dead, head level."""
    s = math.sin(p)
    def leg(sfx, ph):
        th = -17 * math.sin(ph)
        kn = 16 * max(0.0, math.cos(ph)) ** 1.5
        return {"thigh" + sfx: [("x", th)], "shin" + sfx: [("x", kn)], "foot" + sfx: [("x", -(th + kn))]}
    sway = 2.0 * s
    spec = merge(BASE, leg(".L", p), leg(".R", p + math.pi),
                 {"hips": [("y", sway)], "spine": [("y", -sway * 0.7)], "neck": [("y", -sway * 0.3)],
                  "head": [("x", 0)],
                  "upperarm.L": [("y", -sway)], "upperarm.R": [("y", -sway)],  # arms stay vertical, no swing
                  "finger1.L": [("x", 4 * s)], "finger1.R": [("x", -4 * s)]})
    return spec


def walk_keys():
    st = P["step"]
    n = 8
    keys = [(1 + i * st, walk_pose(2 * math.pi * i / n)) for i in range(n)]
    keys.append((1 + n * st, walk_pose(0)))
    return keys


def reach_keys():
    st = P["step"]
    R = ".R"
    stages = [  # (upperarm pitch, stretch, forearm, spine2 lean, head roll, finger spread)
        (0, 1.0, 0, 0, 0, 0), (0, 1.0, 0, 2, 8, 0), (-25, 1.0, -8, 4, 10, 0), (-55, 1.0, -10, 6, 10, 5),
        (-80, 1.0, -6, 8, 12, 10), (-88, 1.12, -3, 10, 12, 14), (-90, 1.25, 0, 12, 14, 18),
        (-90, 1.38, 0, 13, 16, 22), (-91, 1.5, 0, 14, 18, 26), (-92, 1.6, 0, 15, 20, 30),
        (-92, 1.65, 0, 15, 22, 32), (-92, 1.65, 0, 15, 22, 32), (-92, 1.65, 0, 15, 24, 34)]
    keys = []
    for i, (up, stch, fo, lean, roll, spread) in enumerate(stages):
        spec = {"upperarm" + R: [("x", up), ("z", -6 if up else 0), ("s", (1, stch, 1))],
                "clavicle" + R: [("x", up * 0.12), ("z", up * 0.08)],
                "forearm" + R: [("x", fo)],
                "finger1" + R: [("x", -spread * 0.5)], "finger2" + R: [("x", spread * 0.3)],
                "spine2": [("x", lean), ("z", -lean * 0.5)], "spine1": [("x", lean * 0.4)],
                "head": [("y", -roll), ("x", -lean * 0.8)], "neck": [("x", -lean * 0.5)]}
        keys.append((1 + i * st, spec))
    return keys


def still_keys():
    spec = {"thigh.L": [("x", -17)], "shin.L": [("x", 6)], "foot.L": [("x", 11)],
            "thigh.R": [("x", 13)], "shin.R": [("x", 24)], "foot.R": [("x", 8)],
            "hips": [("y", -3)], "spine": [("y", 2)], "spine2": [("z", 8), ("x", 4)],
            "neck": [("x", -6)], "head": [("y", 22), ("x", 6)],
            "upperarm.L": [("x", -14), ("y", -4)], "forearm.L": [("x", -10)],
            "finger1.L": [("x", -14)], "finger2.L": [("x", 10)],
            "upperarm.R": [("x", 6)]}
    spec = merge(BASE, spec)
    return [(1, spec), (2, spec)]


# ============================ MAIN ============================
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "public", "assets", "entities", "orderly.glb"))
    ap.add_argument("--blend", default=os.path.join(HERE, "orderly.blend"))
    args = ap.parse_args(argv)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.fps = P["fps"]
    bt = bone_table()
    arm = build_armature(bt)
    ob = build_mesh(arm, bt)
    ob.data.materials.append(make_material(make_atlas()))

    make_action(arm, "idle", idle_keys(), "BEZIER")
    make_action(arm, "walk", walk_keys(), "CONSTANT")
    make_action(arm, "reach", reach_keys(), "CONSTANT")
    make_action(arm, "still", still_keys(), "CONSTANT")
    set_pose(arm, {})
    scn.frame_start, scn.frame_end = 1, 85

    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    print(f"[build] verts={len(ob.data.vertices)} tris={tris} bones={len(arm.data.bones)}")
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    if args.blend:
        bpy.ops.wm.save_as_mainfile(filepath=args.blend)
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB", export_animations=True,
                              export_animation_mode="ACTIONS", export_skins=True, export_yup=True,
                              export_apply=False, export_force_sampling=True, export_anim_slide_to_zero=True)
    print("[build] exported", args.out, os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
