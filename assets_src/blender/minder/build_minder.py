"""Build "the Minder", the Playroom's resident, from an empty scene and export a skinned, animated GLB.

A gaunt, hairless, too-long thing (2.3 m upright) in the rags of a play attendant's vinyl tabard, with a
staff lanyard, a laminated badge and a wind-up music box. Its head is long and narrow and has no eyes; a
cheap card party mask with a printed smiley is strapped over the FRONT only and glows faintly; its own
slack jaw with small uneven teeth hangs below the mask. It walks upright, slow and stooped, and drops to
all fours to search and run. Design: docs/floors/playarea.md, section 2 (owner's changes, 17 Nov).

Usage (headless, from the repository root):
  blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/minder/build_minder.py -- [--out PATH] [--blend PATH] [--atlas PATH] [--drop NAME,...]

  --drop cover   leaves the named actions out of the export (used once to prove the animation check goes red)

How to change it:
  * proportions: SPINE / TORSO / HEAD_RINGS / JAW tables and the ARM / HAND / LEG dicts
  * colours: COL; the mask print: paint_mask()
  * motion: the *_keys() functions at the bottom. Poses are dicts of bone -> ops (see Rig.solve);
    arms and legs are placed by a two-bone solver (targets on the floor, on the mask, ...).
Everything is deterministic. Blender space: Z up, the figure faces -Y, +X is its left.
glTF export turns this into +Y up, facing +Z, origin on the floor between the feet.
"""
import bpy, sys, os, math, argparse
import numpy as np
from mathutils import Vector, Quaternion, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# =========================== PARAMETERS ===========================
NAME = "Minder"
FPS = 24
TEX = 512
MASK_TEX = 256

COL = dict(  # sRGB 0..1. A dark, matte body; the mask is the one clean bright thing on it.
    skin=(0.33, 0.30, 0.27), skin_lo=(0.17, 0.13, 0.14), skin_hi=(0.49, 0.46, 0.37),
    bruise=(0.29, 0.21, 0.23), skin_shade=(0.26, 0.22, 0.22), skin_mid=(0.39, 0.36, 0.30),
    skin_dk=(0.27, 0.21, 0.20), gum=(0.20, 0.10, 0.10), mouth=(0.09, 0.04, 0.05),
    tooth=(0.80, 0.75, 0.58), nail=(0.16, 0.13, 0.11),
    red=(0.36, 0.19, 0.18), yellow=(0.44, 0.37, 0.19), blue=(0.21, 0.26, 0.32),   # faded: maroon, mustard, slate
    cord=(0.17, 0.27, 0.42), clip=(0.45, 0.46, 0.47), strap=(0.62, 0.60, 0.55),
    box=(0.66, 0.48, 0.52), box_top=(0.72, 0.65, 0.50), brass=(0.55, 0.45, 0.24),
    badge=(0.80, 0.79, 0.74), card=(0.86, 0.84, 0.76), card_back=(0.36, 0.33, 0.28),
    ink=(0.10, 0.09, 0.10), glow=(0.66, 0.92, 0.68),
)

# Spine centre line: z -> y offset (negative y = forward).
SPINE = [(1.05, 0.0), (1.30, 0.004), (1.45, 0.018), (1.62, 0.010), (1.80, 0.010), (1.92, 0.006), (2.00, -0.006)]

# Torso cross-section: z, half-width, front depth, back depth (from the spine line). Gaunt: a waist
# sucked in under a flaring ribcage, a long torso.
TORSO = [
    (1.08, 0.060, 0.044, 0.056), (1.13, 0.092, 0.052, 0.070), (1.21, 0.106, 0.048, 0.076),
    (1.29, 0.094, 0.040, 0.066), (1.37, 0.082, 0.036, 0.064), (1.45, 0.090, 0.044, 0.066),
    (1.52, 0.116, 0.082, 0.072), (1.61, 0.134, 0.100, 0.080), (1.71, 0.142, 0.104, 0.086),
    (1.79, 0.146, 0.098, 0.090), (1.86, 0.150, 0.084, 0.090), (1.915, 0.128, 0.068, 0.084),
    (1.955, 0.084, 0.054, 0.066), (1.99, 0.048, 0.040, 0.046),
]
RIBS = dict(z0=1.54, z1=1.88, spacing=0.046, amp=0.012, slope=0.07, sternum=13.0)

NECK_BASE = (0.0, -0.004, 1.965)
NECK_TOP = (0.0, 0.000, 2.150)     # where the neck enters the underside of the skull
# The skull, lofted from the back of the head to the end of the snout: y, half-width, half-height, z.
HEAD_RINGS = [
    (0.080, 0.020, 0.022, 2.208), (0.070, 0.042, 0.048, 2.210), (0.050, 0.054, 0.062, 2.213),
    (0.020, 0.058, 0.068, 2.214), (-0.016, 0.057, 0.066, 2.212), (-0.054, 0.054, 0.060, 2.206),
    (-0.094, 0.046, 0.054, 2.198), (-0.138, 0.040, 0.049, 2.190), (-0.182, 0.037, 0.045, 2.181),
    (-0.222, 0.035, 0.042, 2.175), (-0.250, 0.030, 0.036, 2.172),
]
JAW_HINGE = (0.0, 0.030, 2.158)
JAW_OPEN = 38.0            # degrees: the jaw is built hanging open
# Lower jaw from the hinge to the chin (built closed, then opened by JAW_OPEN): y, half-width, half-height, z
JAW = [(0.030, 0.050, 0.016, 2.150), (-0.010, 0.046, 0.016, 2.143), (-0.060, 0.040, 0.015, 2.136),
       (-0.110, 0.034, 0.014, 2.130), (-0.160, 0.030, 0.013, 2.126), (-0.205, 0.027, 0.013, 2.122),
       (-0.240, 0.022, 0.012, 2.119), (-0.258, 0.012, 0.009, 2.118)]
# The card mask: centre, half-width, half-height, the curve of the card, a slight downward tilt.
MASK = dict(c=(0.0, -0.280, 2.176), hw=0.106, hh=0.114, bend=0.21, tilt=7.0, rings=6, sectors=28,
            rim=0.62, curl=0.030, flute=0.0035, crumple=0.0028, torn=((8, 10, 0.885), (19, 20, 0.90)),
            bent=(3, 6, 0.024))

ARM = dict(shoulder=(0.205, 0.020, 1.915), elbow=(0.236, 0.062, 1.435), wrist=(0.246, 0.012, 0.905),
           knuckle=(0.250, -0.004, 0.790))
HAND = dict(  # per finger: knuckle y offset, segment lengths, radius, splay of the tip (x, y)
    index=(-0.030, (0.074, 0.060, 0.050), 0.0132, (0.000, -0.050)),
    middle=(-0.010, (0.086, 0.068, 0.055), 0.0137, (0.000, -0.016)),
    ring=(0.011, (0.078, 0.062, 0.050), 0.0130, (0.000, 0.020)),
    little=(0.030, (0.060, 0.050, 0.042), 0.0118, (0.000, 0.052)),
    curl=(0.0, -0.007, -0.020),
)
LEG = dict(hip=(0.095, 0.005, 1.150), knee=(0.104, -0.032, 0.620), ankle=(0.110, 0.050, 0.140),
           ball=(0.114, -0.096, 0.032), toe=(0.120, -0.250, 0.014))

# Bones that the solver treats as two-bone chains: upper -> lower.
IK_CHILD = {"upperarm.L": "forearm.L", "upperarm.R": "forearm.R", "thigh.L": "shin.L", "thigh.R": "shin.R"}


def lerp(a, b, t):
    return a + (b - a) * t


def table(z, tab, col):
    if z <= tab[0][0]:
        return tab[0][col]
    for r0, r1 in zip(tab, tab[1:]):
        if z <= r1[0]:
            t = (z - r0[0]) / (r1[0] - r0[0])
            t = t * t * (3 - 2 * t)
            return lerp(r0[col], r1[col], t)
    return tab[-1][col]


def spine_y(z):
    return table(z, SPINE, 1)


def mirror_pt(p, side):
    return (p[0] * side, p[1], p[2])


def hash01(i):
    x = math.sin(i * 12.9898 + 78.233) * 43758.5453
    return x - math.floor(x)


# ============================ BODY FIELD ============================
def rib_bump(a_deg, z):
    """Rib ridges on the ribcage, sloping down toward the front. a_deg: 0 = left, 90 = back, -90 = front."""
    s = math.sin(math.radians(a_deg))
    front = max(0.0, -s)
    if abs(a_deg + 90) < RIBS["sternum"] or abs(a_deg - 90) < 10:
        return 0.0
    ze = z + RIBS["slope"] * front
    if ze < RIBS["z0"] - 0.02 or ze > RIBS["z1"] + 0.03 or z > 1.90:
        return 0.0
    env = min(1.0, (ze - RIBS["z0"] + 0.02) / 0.05) * min(1.0, (RIBS["z1"] + 0.03 - ze) / 0.05)
    ph = (ze - RIBS["z0"]) / RIBS["spacing"]
    ridge = max(0.0, math.cos(2 * math.pi * ph)) ** 3
    side_w = 0.55 + 0.45 * abs(math.cos(math.radians(a_deg)))
    return RIBS["amp"] * env * ridge * side_w


def rib_valley(a_deg, z):
    s = math.sin(math.radians(a_deg))
    front = max(0.0, -s)
    if abs(a_deg + 90) < RIBS["sternum"] or abs(a_deg - 90) < 10:
        return 0.0
    ze = z + RIBS["slope"] * front
    if ze < RIBS["z0"] or ze > RIBS["z1"] or z > 1.89:
        return 0.0
    return max(0.0, -math.cos(2 * math.pi * (ze - RIBS["z0"]) / RIBS["spacing"]))


def body_r(a_deg, z):
    rx, rf, rb = table(z, TORSO, 1), table(z, TORSO, 2), table(z, TORSO, 3)
    a = math.radians(a_deg)
    c, s = math.cos(a), math.sin(a)
    ry = rb if s > 0 else rf
    r = 1.0 / math.sqrt((c / rx) ** 2 + (s / ry) ** 2)
    r += rib_bump(a_deg, z)
    if s < 0:  # collarbone ridges
        off = abs(a_deg + 90)
        if 9 < off < 72:
            zc = 1.935 + 0.012 * (off - 9) / 63
            r += 0.008 * math.exp(-((z - zc) / 0.011) ** 2) * min(1.0, (off - 9) / 8)
    # the pelvis: crests of the hip bones standing out at the sides, running forward into two points
    # (just inside the front of each hip), the pubic bone low at the front, a flat sacrum behind
    r += 0.012 * math.exp(-((z - 1.215) / 0.028) ** 2) * abs(c) ** 2
    off_front = abs(abs(a_deg + 90) - 58) if s < 0 else 99
    r += 0.018 * math.exp(-((z - 1.195) / 0.026) ** 2) * math.exp(-(off_front / 16) ** 2)
    if s < 0:
        r += 0.008 * math.exp(-((z - 1.100) / 0.020) ** 2) * max(0.0, -s) ** 6
        r -= 0.010 * math.exp(-((z - 1.27) / 0.05) ** 2) * max(0.0, -s) ** 3      # the belly sunk in
    if s > 0:  # spine groove; the sacrum flattened
        r -= 0.007 * max(0.0, 1 - abs(a_deg - 90) / 12) * (1.0 if 1.30 < z < 1.95 else 0.0)
        r -= 0.010 * math.exp(-((z - 1.15) / 0.06) ** 2) * max(0.0, s) ** 4
    return r


def body_point(a_deg, z, extra=0.0):
    r = body_r(a_deg, z) + extra
    a = math.radians(a_deg)
    return Vector((r * math.cos(a), spine_y(z) + r * math.sin(a), z))


# ============================ ARMATURE ============================
def finger_points(side, name):
    yoff, segs, rad, (sx, sy) = HAND[name]
    kn = Vector(mirror_pt(ARM["knuckle"], side)) + Vector((0, yoff, 0))
    pts = [kn]
    z = kn.z
    for i, L in enumerate(segs):
        z -= L
        f = (i + 1) / len(segs)
        pts.append(Vector((kn.x + side * (sx * f + HAND["curl"][i]), kn.y + sy * f, z)))
    return pts


def thumb_points(side):
    wr = Vector(mirror_pt(ARM["wrist"], side))
    a = wr + Vector((-0.012 * side, -0.030, -0.034))
    b = a + Vector((-0.010 * side, -0.026, -0.060))
    c = b + Vector((-0.010 * side, -0.014, -0.052))
    return [a, b, c]


RAG_BONES = {"rag.F.L": (0.060, -0.118), "rag.F.R": (-0.060, -0.118),
             "rag.B.L": (0.060, 0.104), "rag.B.R": (-0.060, 0.104)}
RAG_TOP = 1.705
LANYARD = ((0.0, -0.070, 1.958), (0.0, -0.128, 1.660))


def bone_table():
    """name -> (head, tail, parent). Parents first. 43 bones."""
    b = {}
    b["hips"] = ((0, 0, 1.12), (0, spine_y(1.36), 1.36), None)
    b["spine"] = ((0, spine_y(1.36), 1.36), (0, spine_y(1.56), 1.56), "hips")
    b["spine1"] = ((0, spine_y(1.56), 1.56), (0, spine_y(1.76), 1.76), "spine")
    b["spine2"] = ((0, spine_y(1.76), 1.76), NECK_BASE, "spine1")
    nm = tuple(lerp(NECK_BASE[i], NECK_TOP[i], 0.5) for i in range(3))
    b["neck"] = (NECK_BASE, nm, "spine2")
    b["neck1"] = (nm, NECK_TOP, "neck")
    b["head"] = (NECK_TOP, (NECK_TOP[0], NECK_TOP[1], NECK_TOP[2] + 0.20), "neck1")
    chin = jaw_open_point(Vector((0.0, JAW[-1][0], JAW[-1][3])))
    b["jaw"] = (JAW_HINGE, tuple(chin), "head")
    for side, sfx in ((1, ".L"), (-1, ".R")):
        sh, el, wr, kn = (mirror_pt(ARM[k], side) for k in ("shoulder", "elbow", "wrist", "knuckle"))
        b["clavicle" + sfx] = ((0.028 * side, spine_y(1.94), 1.94), sh, "spine2")
        b["upperarm" + sfx] = (sh, el, "clavicle" + sfx)
        b["forearm" + sfx] = (el, wr, "upperarm" + sfx)
        b["hand" + sfx] = (wr, kn, "forearm" + sfx)
        for f in ("index", "middle", "ring"):
            p = finger_points(side, f)
            b[f + "1" + sfx] = (tuple(p[0]), tuple(p[1]), "hand" + sfx)
            b[f + "2" + sfx] = (tuple(p[1]), tuple(p[3]), f + "1" + sfx)
        th = thumb_points(side)
        b["thumb" + sfx] = (tuple(th[0]), tuple(th[2]), "hand" + sfx)
        hip, knee, ankle, ball, toe = (mirror_pt(LEG[k], side) for k in ("hip", "knee", "ankle", "ball", "toe"))
        b["thigh" + sfx] = (hip, knee, "hips")
        b["shin" + sfx] = (knee, ankle, "thigh" + sfx)
        b["foot" + sfx] = (ankle, ball, "shin" + sfx)
        b["toe" + sfx] = (ball, toe, "foot" + sfx)
    # cloth: four bones carry the hanging tabard strips, one the lanyard with the badge and music box
    for name, (x, y) in RAG_BONES.items():
        b[name] = ((x, y, RAG_TOP), (x * 1.15, y * 1.05, RAG_TOP - 0.42), "spine1")
    b["lanyard"] = (LANYARD[0], LANYARD[1], "spine2")
    return apply_asym_bones(b)


def build_armature(bt):
    arm_data = bpy.data.armatures.new(NAME + "_Rig")
    arm = bpy.data.objects.new(NAME + "_Rig", arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (h, t, parent) in bt.items():
        eb = arm_data.edit_bones.new(name)
        eb.head, eb.tail = Vector(h), Vector(t)
        eb.roll = 0.0
    for name, (h, t, parent) in bt.items():
        if parent:
            arm_data.edit_bones[name].parent = arm_data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


# ============================ MESH KIT ============================
def cell(cx, cy, w=1, h=1):
    return (cx / 8, cy / 8, (cx + w) / 8, (cy + h) / 8)


# Atlas regions on the 512 px body texture (64 px cells).
REG = dict(skin=cell(2, 2, 2, 2), skin_hi=cell(4, 2, 2, 2), bruise=cell(6, 2, 2, 2),
           skin_shade=cell(6, 4, 2, 2), skin_mid=cell(6, 6, 2, 2),
           skin_lo=cell(1, 0), skin_dk=cell(3, 0), gum=cell(4, 0), tooth=cell(5, 0), nail=cell(6, 0),
           strap=cell(7, 0), mouth=cell(0, 0), skin_ext=cell(2, 0),
           cord=cell(0, 1), clip=cell(1, 1), box=cell(2, 1), box_top=cell(3, 1), brass=cell(4, 1),
           card_back=cell(5, 1),
           badge=cell(0, 2, 2, 2),
           red=cell(0, 4, 2, 2), yellow=cell(2, 4, 2, 2), blue=cell(4, 4, 2, 2),
           red_p=cell(0, 6, 2, 2), yellow_p=cell(2, 6, 2, 2), blue_p=cell(4, 6, 2, 2))
VINYL = ("red", "yellow", "blue")


def ruv(reg, u, v):
    m = 0.04
    u = m + (1 - 2 * m) * min(1.0, max(0.0, u))
    v = m + (1 - 2 * m) * min(1.0, max(0.0, v))
    return (reg[0] + (reg[2] - reg[0]) * u, reg[1] + (reg[3] - reg[1]) * v)


class MeshBuilder:
    def __init__(self):
        self.co, self.w, self.faces, self.uvs, self.sm, self.mat = [], [], [], [], [], []
        self.smooth = True
        self.material = 0

    def vert(self, co, w):
        self.co.append(Vector(co))
        self.w.append(dict(w))
        return len(self.co) - 1

    def face(self, idx, uv, interior=None, outward=None):
        idx, uv = list(idx), list(uv)
        pts = [self.co[i] for i in idx]
        n = Vector((0, 0, 0))
        for a, b in zip(pts, pts[1:] + pts[:1]):
            n += a.cross(b)
        c = sum(pts, Vector()) / len(pts)
        ref = (c - Vector(interior)) if interior is not None else (Vector(outward) if outward is not None else None)
        if ref is not None and n.dot(ref) < 0:
            idx.reverse()
            uv.reverse()
        self.faces.append(idx)
        self.uvs.append(uv)
        self.sm.append(self.smooth)
        self.mat.append(self.material)


def frame_for(t, ref=None):
    x = Vector(ref) if ref is not None else Vector((1, 0, 0))
    if abs(t.dot(x)) > 0.9:
        x = Vector((0, 1, 0))
    xp = (x - t * x.dot(t)).normalized()
    return xp, t.cross(xp)


def tube(mb, rings, sides, reg, cap0=True, cap1=True, ref=None, reg_fn=None, phase=0.0, wob=0.0):
    """rings: list of (center, radius, weights). radius: a number, (rx, ry) or a function of the
    unit direction d. weights: a dict or a function of position. reg_fn(i, k, centre, face centre).
    wob roughens the outline: each vertex's distance from the centre varies by up to +-wob."""
    n = len(rings)
    cs = [Vector(r[0]) for r in rings]
    idx = []
    for i, (c, rad, w) in enumerate(rings):
        c = Vector(c)
        t = (cs[min(i + 1, n - 1)] - cs[max(i - 1, 0)]).normalized()
        xp, yp = frame_for(t, ref)
        row = []
        for k in range(sides):
            a = 2 * math.pi * (k + phase) / sides
            d = xp * math.cos(a) + yp * math.sin(a)
            if callable(rad):
                p = c + d * rad(d)
            elif isinstance(rad, tuple):
                p = c + xp * (rad[0] * math.cos(a)) + yp * (rad[1] * math.sin(a))
            else:
                p = c + d * rad
            if wob and 0 < i < n - 1:
                p = c + (p - c) * (1.0 + wob * wobble(len(mb.co)))
            row.append(mb.vert(p, w(p) if callable(w) else w))
        idx.append(row)
    for i in range(n - 1):
        interior = (cs[i] + cs[i + 1]) / 2
        for k in range(sides):
            k2 = (k + 1) % sides
            q = [idx[i][k], idx[i][k2], idx[i + 1][k2], idx[i + 1][k]]
            fc = sum((mb.co[j] for j in q), Vector()) / 4
            r = reg_fn(i, k, interior, fc) if reg_fn else reg
            uv = [ruv(r, k / sides, i / (n - 1)), ruv(r, (k + 1) / sides, i / (n - 1)),
                  ruv(r, (k + 1) / sides, (i + 1) / (n - 1)), ruv(r, k / sides, (i + 1) / (n - 1))]
            mb.face(q, uv, interior)
    for end, use in ((0, cap0), (n - 1, cap1)):
        if not use:
            continue
        nb = 1 if end == 0 else n - 2
        c, rad, w = rings[end]
        c = Vector(c)
        out = (c - cs[nb]).normalized()
        rr = rad if isinstance(rad, (int, float)) else (min(rad) if isinstance(rad, tuple) else 0.01)
        tipp = c + out * (0.35 * rr)
        tip = mb.vert(tipp, w(tipp) if callable(w) else w)
        for k in range(sides):
            k2 = (k + 1) % sides
            mb.face([tip, idx[end][k], idx[end][k2]],
                    [ruv(reg, 0.5, 0.5), ruv(reg, k / sides, 0.0), ruv(reg, (k + 1) / sides, 0.0)], cs[nb])
    return idx


def grid(mb, rows, reg, interior=None, outward=None, wfn=None, reg_fn=None):
    """rows: list of rows of points (an open sheet). Returns vertex ids."""
    ids = [[mb.vert(p, wfn(p, j, i) if wfn else {}) for i, p in enumerate(row)] for j, row in enumerate(rows)]
    nr, nc = len(rows), len(rows[0])
    for j in range(nr - 1):
        for i in range(nc - 1):
            r = reg_fn(j, i) if reg_fn else reg
            q = [ids[j][i], ids[j][i + 1], ids[j + 1][i + 1], ids[j + 1][i]]
            uv = [ruv(r, i / (nc - 1), 1 - j / (nr - 1)), ruv(r, (i + 1) / (nc - 1), 1 - j / (nr - 1)),
                  ruv(r, (i + 1) / (nc - 1), 1 - (j + 1) / (nr - 1)), ruv(r, i / (nc - 1), 1 - (j + 1) / (nr - 1))]
            mb.face(q, uv, interior, outward)
    return ids


def box(mb, c, ax, ay, az, w, reg_fn):
    """A box centred at c with half-extent vectors ax, ay, az; reg_fn(face name) -> region."""
    c = Vector(c)
    corners = {}
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                corners[(sx, sy, sz)] = mb.vert(c + ax * sx + ay * sy + az * sz, w)
    faces = {"x+": [(1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)], "x-": [(-1, -1, -1), (-1, 1, -1), (-1, 1, 1), (-1, -1, 1)],
             "y+": [(-1, 1, -1), (1, 1, -1), (1, 1, 1), (-1, 1, 1)], "y-": [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)],
             "z+": [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)], "z-": [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1)]}
    for name, cs in faces.items():
        r = reg_fn(name)
        mb.face([corners[k] for k in cs], [ruv(r, 0, 0), ruv(r, 1, 0), ruv(r, 1, 1), ruv(r, 0, 1)], interior=c)


def lerp_w(z, tab):
    if z <= tab[0][0]:
        return dict(tab[0][1])
    for (z0, w0), (z1, w1) in zip(tab, tab[1:]):
        if z <= z1:
            t = (z - z0) / (z1 - z0)
            return {k: w0.get(k, 0) * (1 - t) + w1.get(k, 0) * t for k in set(w0) | set(w1)}
    return dict(tab[-1][1])


SPINE_W = [(1.12, {"hips": 1}), (1.30, {"hips": .6, "spine": .4}), (1.42, {"spine": 1}),
           (1.56, {"spine": .5, "spine1": .5}), (1.70, {"spine1": 1}), (1.80, {"spine1": .4, "spine2": .6}),
           (1.90, {"spine2": 1}), (1.96, {"spine2": .7, "neck": .3}), (2.01, {"neck": 1})]


def torso_weights(p):
    w = lerp_w(p.z, SPINE_W)
    ax = abs(p.x)
    if p.z > 1.80 and ax > 0.09:  # shoulders follow the clavicles
        t = min(1.0, (ax - 0.09) / 0.07) * min(1.0, (p.z - 1.80) / 0.08)
        sfx = ".L" if p.x > 0 else ".R"
        w = {k: v * (1 - t) for k, v in w.items()}
        w["clavicle" + sfx] = w.get("clavicle" + sfx, 0) + t * 0.75
        w["upperarm" + sfx] = w.get("upperarm" + sfx, 0) + t * 0.25 * (min(1.0, (ax - 0.13) / 0.04) if ax > 0.13 else 0)
    if p.z < 1.19:
        t = min(1.0, (1.19 - p.z) / 0.12) * 0.6
        sfx = ".L" if p.x > 0 else ".R"
        w = {k: v * (1 - t) for k, v in w.items()}
        w["thigh" + sfx] = t
    return w


# ============================ BODY PARTS ============================
def torso_zs():
    zs = [1.085, 1.13, 1.18, 1.24, 1.31, 1.38, 1.45, 1.505]
    z = 1.535
    while z < 1.90:
        zs.append(round(z, 4))
        z += RIBS["spacing"] / 3
    zs += [1.915, 1.94, 1.96, 1.98, 1.995]
    return zs


def build_torso(mb):
    sides = 18
    rings = []
    for z in torso_zs():
        c = Vector((0, spine_y(z), z))

        def rad(d, z=z):
            return body_r(math.degrees(math.atan2(d.y, d.x)), z)
        rings.append((c, rad, torso_weights))

    def reg_fn(i, k, cen, fc):
        a = 360.0 * (k + 0.5) / sides
        a = a if a <= 180 else a - 360
        z = cen.z
        if rib_valley(a, z) > 0.55 and z < 1.88:
            return REG["bruise"]
        if -125 < a < -55 and 1.33 < z < 1.50:
            return REG["skin_shade"]       # the hollow belly under the ribs
        if 1.19 < z < 1.25 and abs(math.cos(math.radians(a))) > 0.85:
            return REG["skin_mid"]         # hip crests
        if 1.10 < z < 1.19 and abs(math.cos(math.radians(a))) > 0.8:
            return REG["bruise"]
        if rib_bump(a, z) > RIBS["amp"] * 0.5:
            return REG["skin_mid"]
        return REG["skin"]
    tube(mb, rings, sides, REG["skin"], cap0=True, cap1=False, ref=(1, 0, 0), reg_fn=reg_fn)


def build_spine_knobs(mb):
    z = 1.30
    while z < 1.97:
        p = body_point(90, z)
        t = Vector((0, spine_y(z + 0.01) - spine_y(z - 0.01), 0.02)).normalized()
        n = (Vector((0, 1, 0)) - t * t.y).normalized()
        size = 0.010 + 0.004 * (1 - abs(z - 1.80) / 0.5)
        w = lerp_w(z, SPINE_W)
        tube(mb, [(p - n * 0.007, size, w), (p + n * 0.006, size * 0.75, w)], 4, REG["skin_hi"],
             cap0=False, cap1=True, ref=t)
        z += 0.033


def build_scapulae(mb):
    for side, sfx in ((1, ".L"), (-1, ".R")):
        C = "clavicle" + sfx
        zs = (1.90, 1.80, 1.69)
        rows = []
        for j, z in enumerate(zs):
            row = []
            for i, a in enumerate((90 - side * 18, 90 - side * 36, 90 - side * 56)):
                lift = (0.012 if i == 0 else 0.006 if i == 1 else 0.0) * (1.0 if j < 2 else 0.6)
                row.append(body_point(a, z, extra=lift + 0.002))
            rows.append(row)
        grid(mb, rows, REG["skin_mid"], interior=Vector((0, spine_y(1.80), 1.80)),
             wfn=lambda p, j, i, C=C: {"spine2": 0.6, C: 0.4} if p.z > 1.76 else {"spine1": 0.5, "spine2": 0.3, C: 0.2})
        # the lip under the inner edge, so the blade reads as lifted off the back
        lip = [[rows[j][0] for j in range(3)], [body_point(90 - side * 15, z, -0.004) for z in zs]]
        grid(mb, lip, REG["skin_lo"], interior=Vector((0, spine_y(1.80), 1.80)),
             wfn=lambda p, j, i: lerp_w(p.z, SPINE_W))


def build_collarbones(mb):
    for side, sfx in ((1, ".L"), (-1, ".R")):
        pts = []
        for i in range(6):
            t = i / 5
            a = -90 + side * lerp(10, 66, t)
            z = lerp(1.935, 1.948, t) + 0.010 * math.sin(math.pi * t)
            pts.append(body_point(a, z, extra=0.001 + 0.002 * math.sin(math.pi * t)))
        C = "clavicle" + sfx
        rings = [(p, 0.0075 if 0 < i < 5 else 0.006, lambda p, C=C: {"spine2": 1 - min(1.0, abs(p.x) / 0.15), C: min(1.0, abs(p.x) / 0.15)})
                 for i, p in enumerate(pts)]
        tube(mb, rings, 5, REG["skin_hi"], cap0=True, cap1=True)


def build_neck(mb):
    nb = Vector(NECK_BASE) + Vector((0, 0, -0.03))
    top = Vector(NECK_TOP) + Vector((0, 0.004, 0.025))
    rings = []
    n = 7
    for i in range(n):
        t = i / (n - 1)
        c = nb.lerp(top, t)

        def rad(d, t=t):
            r = lerp(0.050, 0.033, min(1, t * 1.5))
            r += 0.007 * max(0.0, -d.y) ** 6 * math.sin(math.pi * min(1, t * 1.2))   # tendons, windpipe
            r += 0.004 * abs(d.x) ** 8
            r += 0.005 * max(0.0, d.y) ** 4 * (1 - t)      # the hump where the neck meets the back
            return r
        w = ({"spine2": 1} if t < 0.1 else {"spine2": .4, "neck": .6} if t < 0.25 else {"neck": 1} if t < 0.45
             else {"neck": .5, "neck1": .5} if t < 0.6 else {"neck1": 1} if t < 0.85 else {"neck1": .4, "head": .6})
        rings.append((c, rad, w))
    tube(mb, rings, 10, REG["skin"], cap0=False, cap1=False)


def skull_radius(ring, d):
    """Cross-section of the skull in direction d (in the x-z plane): flat-topped, narrowing to a keel
    underneath, a crest along the cranium, a heavy brow, a cheek ridge along each side, the temples sunk
    in, and shallow sealed hollows under the brow where eyes would be."""
    y, hw, hh, zc = ring
    ang = math.atan2(d.z, d.x)
    s, c = math.sin(ang), abs(math.cos(ang))
    w = hw * (1 - 0.22 * max(0.0, -s) ** 1.5)
    h = hh * (1 - 0.10 * max(0.0, s) ** 2)
    r = 1.0 / math.sqrt((math.cos(ang) / w) ** 2 + (s / h) ** 2)
    if y > -0.07:
        r += 0.007 * max(0.0, s) ** 30                                                  # crest
    r += 0.008 * math.exp(-((y + 0.060) / 0.016) ** 2) * math.exp(-((s - 0.62) / 0.16) ** 2)   # brow
    r += 0.007 * math.exp(-((y + 0.080) / 0.045) ** 2) * math.exp(-((s + 0.12) / 0.14) ** 2) * c ** 4  # cheek
    r -= 0.008 * math.exp(-((y - 0.012) / 0.025) ** 2) * math.exp(-((s - 0.25) / 0.25) ** 2) * c ** 2  # temples
    if -0.13 < y < -0.04:                                                                # sealed hollows
        k = math.exp(-((y + 0.090) / 0.024) ** 2)
        r -= 0.010 * k * math.exp(-((s - 0.40) / 0.18) ** 2) * min(1.0, c / 0.6)
    return r


def head_ring_at(y):
    """The skull's (half-width, half-height, z) at y, interpolated between HEAD_RINGS."""
    rs = HEAD_RINGS
    if y >= rs[0][0]:
        return rs[0][1:]
    for a, b in zip(rs, rs[1:]):
        if b[0] <= y <= a[0]:
            t = (a[0] - y) / (a[0] - b[0])
            return tuple(lerp(a[i], b[i], t) for i in (1, 2, 3))
    return rs[-1][1:]


def build_head(mb):
    W = {"head": 1}
    rings = []
    for ring in HEAD_RINGS:
        c = Vector((0, ring[0], ring[3]))
        rings.append((c, lambda d, ring=ring: skull_radius(ring, d), W))

    def reg_fn(i, k, c, f):
        d = (f - c)
        y = c.y
        n = d.normalized()
        s = n.z
        if abs(y + 0.060) < 0.022 and 0.40 < s < 0.85:
            return REG["skin_mid"]                 # brow
        if abs(y + 0.08) < 0.05 and -0.30 < s < 0.05 and abs(n.x) > 0.9:
            return REG["skin_mid"]                 # cheek ridge
        if abs(y - 0.012) < 0.03 and 0.0 < s < 0.5:
            return REG["skin_shade"]               # temples
        if -0.12 < y < -0.06 and 0.2 < s < 0.6:
            return REG["bruise"]                   # under the brow, the sealed hollows: a soft bruise
        if s > 0.98 and y > -0.07:
            return REG["skin_mid"]                 # crest
        if s < -0.4 and y < -0.05:
            return REG["skin_dk"]                  # the underside of the snout, toward the mouth
        return REG["skin"]
    tube(mb, rings, 16, REG["skin"], cap0=True, cap1=True, ref=(1, 0, 0), reg_fn=reg_fn)
    # upper teeth along the front half of the snout's underside: long, uneven, some missing
    for i in range(6):
        y = lerp(-0.130, -0.238, i / 5)
        hw, hh, zc = head_ring_at(y)
        for side in (1, -1):
            if hash01(i * 7 + side) < 0.22:
                continue
            base = Vector((side * hw * 0.58, y, zc - hh * 0.78))
            ln = 0.015 + 0.022 * hash01(i * 3 + side * 11)
            lean = Vector((side * 0.25 * (hash01(i + 5) - 0.5), 0.35 * (hash01(i) - 0.5) - 0.1, -1)).normalized()
            tooth(mb, base, lean, ln, 0.0055 + 0.002 * hash01(i * 5 + side), W)


def tooth(mb, base, direction, length, r, w, reg=None):
    reg = reg or REG["tooth"]
    xp, yp = frame_for(direction, (1, 0, 0))
    ids = [mb.vert(base + (xp * math.cos(a) + yp * math.sin(a)) * r, w) for a in (0.3, 2.4, 4.4)]
    bend = xp * (0.18 * length)                  # a slight hook
    mid = [mb.vert(base + direction * (length * 0.55) + bend * 0.4 + (xp * math.cos(a) + yp * math.sin(a)) * r * 0.55, w)
           for a in (0.3, 2.4, 4.4)]
    tip = mb.vert(base + direction * length + bend, w)
    inside = base - direction * 0.01
    for k in range(3):
        k2 = (k + 1) % 3
        mb.face([ids[k], ids[k2], mid[k2], mid[k]], [ruv(reg, k / 3, 0), ruv(reg, (k + 1) / 3, 0),
                                                     ruv(reg, (k + 1) / 3, 0.55), ruv(reg, k / 3, 0.55)], interior=inside)
        mb.face([mid[k], mid[k2], tip], [ruv(reg, k / 3, 0.55), ruv(reg, (k + 1) / 3, 0.55), ruv(reg, 0.5, 1)],
                interior=inside)


def jaw_open_point(p, angle=JAW_OPEN):
    h = Vector(JAW_HINGE)
    q = Quaternion(Vector((1, 0, 0)), math.radians(angle))
    return h + q @ (p - h)


def build_jaw(mb):
    first = len(mb.co)
    W = {"jaw": 1}
    rings = []
    for y, hw, hh, z in JAW:
        rings.append((Vector((0, y, z)), lambda d, hw=hw, hh=hh: 1.0 / math.sqrt((d.x / hw) ** 2 + (d.z / hh) ** 2 + 1e-12), W))
    tube(mb, rings, 8, REG["skin"], cap0=True, cap1=True, ref=(1, 0, 0),
         reg_fn=lambda i, k, c, f: REG["gum"] if (f - c).z > 0.006 and c.y < -0.10 else (
             REG["mouth"] if (f - c).z > 0.006 else (REG["skin_dk"] if (f - c).z < -0.006 else REG["skin"])))
    # lower teeth: front half only, long, crooked, off-white going yellow, gaps
    for i in range(7):
        t = i / 6
        y = lerp(-0.135, -0.250, t)
        jr = min(JAW, key=lambda r: abs(r[0] - y))
        for side in (1, -1):
            if hash01(i * 5 + side * 3 + 1) < 0.20:
                continue
            x = side * jr[1] * (0.62 - 0.4 * max(0.0, t - 0.8))
            base = Vector((x, y, jr[3] + jr[2] * 0.80))
            ln = 0.020 + 0.026 * hash01(i * 13 + side)
            lean = Vector((side * 0.30 * (hash01(i * 2 + side) - 0.4), 0.35 * (hash01(i + 9) - 0.5) - 0.2, 1)).normalized()
            tooth(mb, base, lean, ln, 0.0055 + 0.0025 * hash01(i), W)
    for i in range(first, len(mb.co)):
        mb.co[i] = jaw_open_point(mb.co[i])
    # the corners of the mouth: wet dark skin stretched from the snout to the open jaw, back half only
    for side in (1, -1):
        rows = []
        for y in (0.010, -0.025, -0.060, -0.095, -0.125):
            hw, hh, zc = head_ring_at(y)
            top = Vector((side * hw * 0.70, y, zc - hh * 0.62))
            jr = min(JAW, key=lambda r: abs(r[0] - y))
            bot = jaw_open_point(Vector((side * jr[1] * 0.80, y, jr[3] + jr[2] * 0.5)))
            mid = top.lerp(bot, 0.5) + Vector((-side * 0.010, 0, 0))
            rows.append([top, mid, bot])
        grid(mb, rows, REG["mouth"], outward=(side, 0, 0),
             wfn=lambda p, j, i: {"head": 1.0} if i == 0 else ({"head": 0.5, "jaw": 0.5} if i == 1 else {"jaw": 1.0}))


def mask_frame():
    c = Vector(MASK["c"])
    q = Quaternion(Vector((1, 0, 0)), math.radians(MASK["tilt"]))
    fwd = q @ Vector((0, -1, 0))
    up = q @ Vector((0, 0, 1))
    return c, fwd, up, Vector((1, 0, 0))


def mask_point(u, v, back=0.0, k=None):
    """u, v in -1..1 across the oval. A paper plate: the middle gently curved, the rim curling back
    toward the head and fluted, the whole thing crumpled; one corner bent forward."""
    c, fwd, up, right = mask_frame()
    x = u * MASK["hw"]
    z = v * MASK["hh"]
    R = MASK["bend"]
    sag = R - math.sqrt(max(0.0, R * R - x * x))
    rr = math.hypot(u, v)
    ang = math.atan2(v, u)
    t = max(0.0, (rr - MASK["rim"]) / (1 - MASK["rim"]))
    sag += MASK["curl"] * t ** 1.5
    sag += MASK["flute"] * t * math.sin(ang * MASK["sectors"] / 2)
    sag += MASK["crumple"] * math.sin(u * 17 + v * 9 + 1.3) * math.sin(v * 13 - u * 5)
    s0, s1, amt = MASK["bent"]
    a0, a1 = 2 * math.pi * s0 / MASK["sectors"], 2 * math.pi * s1 / MASK["sectors"]
    if a0 <= ang % (2 * math.pi) <= a1 and rr > 0.68:
        mid = (a0 + a1) / 2
        sag -= amt * ((rr - 0.68) / 0.32) ** 1.3 * math.cos((ang % (2 * math.pi) - mid) / (a1 - a0) * math.pi)
    return c + right * x + up * z - fwd * (sag + back)


def build_mask(mb, mask_mat):
    """The card mask: a printed front (its own glowing material) and a plain card back just behind it,
    so from behind there is only card. Torn in two places at the rim. An elastic round the back."""
    W = {"head": 1}
    nr, ns = MASK["rings"], MASK["sectors"]
    c, fwd, _, _ = mask_frame()
    for back, mat, reg in ((0.0, mask_mat, None), (0.0024, 0, REG["card_back"])):
        mb.material = mat
        mb.smooth = True
        ctr = mb.vert(mask_point(0, 0, back), W)
        rings = []
        for j in range(1, nr + 1):
            rr = j / nr
            row = []
            for k in range(ns):
                a = 2 * math.pi * k / ns
                r_ = rr
                if j == nr:
                    for k0, k1, cut in MASK["torn"]:
                        if k0 <= k <= k1:
                            r_ = rr * (cut + 0.03 * hash01(k))
                u = r_ * math.cos(a)
                v = r_ * math.sin(a)
                row.append((mb.vert(mask_point(u, v, back), W), (u, v)))
            rings.append(row)

        def uv(u, v):
            if reg is None:
                return (0.5 + 0.48 * u, 0.5 + 0.48 * v)
            return ruv(reg, 0.5 + 0.5 * u, 0.5 + 0.5 * v)
        ref_out = fwd if back == 0.0 else -fwd
        for k in range(ns):
            k2 = (k + 1) % ns
            a, b = rings[0][k], rings[0][k2]
            mb.face([ctr, a[0], b[0]], [uv(0, 0), uv(*a[1]), uv(*b[1])], outward=ref_out)
            for j in range(nr - 1):
                p, q, r_, s = rings[j][k], rings[j][k2], rings[j + 1][k2], rings[j + 1][k]
                mb.face([p[0], q[0], r_[0], s[0]], [uv(*p[1]), uv(*q[1]), uv(*r_[1]), uv(*s[1])], outward=ref_out)
    mb.material = 0
    side_ys = (-0.175, -0.110, -0.040, 0.020, 0.058)
    pts = [mask_point(-0.97, 0.05, 0.003)]
    for y in side_ys:
        hw, hh, zc = head_ring_at(y)
        pts.append(Vector((-(hw + 0.004), y, zc + 0.35 * hh)))
    hw, hh, zc = head_ring_at(0.075)
    pts.append(Vector((0.0, 0.083, zc + 0.30 * hh)))
    for y in reversed(side_ys):
        hw, hh, zc = head_ring_at(y)
        pts.append(Vector((hw + 0.004, y, zc + 0.35 * hh)))
    pts.append(mask_point(0.97, 0.05, 0.003))
    tube(mb, [(p, 0.0022, W) for p in pts], 3, REG["strap"], cap0=False, cap1=False)


def build_arm(mb, side, sfx):
    """Tapered, knobbly: each segment thick at its upper end and thin at its lower, the bones showing
    at the ends (the point of the elbow, the knob of the wrist) on one side only, never a ring."""
    sh, el, wr, kn = (Vector(mirror_pt(ARM[k], side)) for k in ("shoulder", "elbow", "wrist", "knuckle"))
    C, U, F, H = "clavicle" + sfx, "upperarm" + sfx, "forearm" + sfx, "hand" + sfx
    inside = Vector((0.11 * side, spine_y(1.88) + 0.01, 1.88))
    back = Vector((0, 1, 0))
    outv = Vector((side, 0, 0))
    fwd = Vector((0, -1, 0))

    def r_seg(base, front=0.0, backk=0.0, outk=0.0, ink=0.0, p=4):
        return lambda d: (base + front * max(0.0, d.dot(fwd)) ** p + backk * max(0.0, d.dot(back)) ** p
                          + outk * max(0.0, d.dot(outv)) ** p + ink * max(0.0, -d.dot(outv)) ** p)

    rings = [
        (inside, 0.040, {C: 1}),
        (inside.lerp(sh, 0.6), 0.043, {C: 1}),
        (sh, r_seg(0.044, outk=0.006), {C: .6, U: .4}),
        (sh.lerp(el, 0.18), r_seg(0.036, front=0.006, outk=0.005), {C: .15, U: .85}),
        (sh.lerp(el, 0.45), r_seg(0.029, front=0.004), {U: 1}),
        (sh.lerp(el, 0.72), r_seg(0.022), {U: 1}),
        (sh.lerp(el, 0.90), r_seg(0.022, outk=0.007, ink=0.006, p=6), {U: .9, F: .1}),     # the condyles
        (el, r_seg(0.024, backk=0.020, outk=0.004, p=8), {U: .5, F: .5}),                  # the point of the elbow
        (el.lerp(wr, 0.08), r_seg(0.028, front=0.004, backk=0.006), {U: .15, F: .85}),
        (el.lerp(wr, 0.30), r_seg(0.025, front=0.004), {F: 1}),
        (el.lerp(wr, 0.60), 0.019, {F: 1}),
        (el.lerp(wr, 0.86), 0.0155, {F: .9, H: .1}),
        (wr, r_seg(0.019, outk=0.009, backk=0.004, p=8), {F: .45, H: .55}),               # the knob of the wrist
    ]

    def arm_reg(i, k, c, f):
        d = (f - c).normalized()
        if i == 7 and d.y > 0.85:
            return REG["skin_mid"]         # the point of the elbow
        if i == 12 and d.dot(outv) > 0.8:
            return REG["skin_mid"]
        if i == 7 and d.y < -0.7:
            return REG["bruise"]
        return REG["skin"]
    tube(mb, rings, 10, REG["skin"], cap0=True, cap1=False, ref=(side, 0, 0), reg_fn=arm_reg, wob=0.07)
    pv = kn - wr
    palm = [(wr - pv * 0.12, (0.015, 0.024), {F: .5, H: .5}), (wr + pv * 0.40, (0.013, 0.036), {H: 1}),
            (wr + pv * 0.85, (0.012, 0.044), {H: 1}), (kn + Vector((0, 0, -0.004)), (0.011, 0.042), {H: 1})]
    tube(mb, palm, 8, REG["skin_ext"], cap0=False, cap1=True, ref=(side, 0, 0))
    names = {"index": ("index1", "index2"), "middle": ("middle1", "middle2"),
             "ring": ("ring1", "ring2"), "little": ("ring1", "ring2")}
    for fname, (b1, b2) in names.items():
        b1, b2 = b1 + sfx, b2 + sfx
        pts = finger_points(side, fname)
        rad = HAND[fname][2]
        rings = [(pts[0] + Vector((0, 0, 0.012)), rad * 1.00, {H: 1}),
                 (pts[0], rad * 1.22, {H: .4, b1: .6}),
                 (pts[0].lerp(pts[1], 0.5), rad * 0.80, {b1: 1}),
                 (pts[1], rad * 1.08, {b1: .5, b2: .5}),
                 (pts[1].lerp(pts[2], 0.5), rad * 0.74, {b2: 1}),
                 (pts[2], rad * 0.92, {b2: 1}),
                 (pts[2].lerp(pts[3], 0.55), rad * 0.62, {b2: 1}),
                 (pts[3], rad * 0.45, {b2: 1})]
        tube(mb, rings, 5, REG["skin_ext"], cap0=False, cap1=False, ref=(side, 0, 0),
             reg_fn=lambda i, k, c, f=None: REG["bruise"] if i in (1, 3) else REG["skin_ext"])
        d = (pts[3] - pts[2]).normalized()
        tooth(mb, pts[3] - d * 0.004, (d + Vector((-side * 0.25, 0, 0))).normalized(), 0.020, rad * 0.50,
              {b2: 1}, REG["nail"])
    th = thumb_points(side)
    T = "thumb" + sfx
    rings = [(th[0] + Vector((0.004 * side, 0.012, 0.016)), 0.012, {H: 1}), (th[0], 0.013, {H: .5, T: .5}),
             (th[1], 0.012, {T: 1}), (th[1].lerp(th[2], 0.6), 0.009, {T: 1}), (th[2], 0.0055, {T: 1})]
    tube(mb, rings, 5, REG["skin_ext"], cap0=True, cap1=True)


def build_leg(mb, side, sfx):
    """Long thin legs, tapered and knobbly. The heel never touches the floor: it stands on the balls of
    long feet, with a knob of heel bone behind the raised ankle, so a crouch bends it the wrong way."""
    T, Sh, Ft, To = "thigh" + sfx, "shin" + sfx, "foot" + sfx, "toe" + sfx
    hip, knee, ankle, ball, toe = (Vector(mirror_pt(LEG[k], side)) for k in ("hip", "knee", "ankle", "ball", "toe"))
    fwd, back, out = Vector((0, -1, 0)), Vector((0, 1, 0)), Vector((side, 0, 0))

    def leg_r(base, front=0.0, front_p=3, sides_=0.0, calf=0.0, achilles=0.0, inner=0.0, outer=0.0):
        def r(d):
            v = base + front * max(0.0, d.dot(fwd)) ** front_p
            v += sides_ * abs(d.x) ** 8 + calf * max(0.0, d.dot(back)) ** 2
            v += achilles * max(0.0, d.dot(back)) ** 10 + inner * max(0.0, -d.dot(out)) ** 6
            v += outer * max(0.0, d.dot(out)) ** 6
            return v
        return r

    kd = (hip - knee).normalized()
    ad = (ankle - knee).normalized()
    rings = [(hip + Vector((0, 0, 0.08)), 0.070, {T: .4, "hips": .6}),
             (hip + Vector((0, -0.004, -0.02)), leg_r(0.060, outer=0.008), {T: .8, "hips": .2}),
             (hip.lerp(knee, 0.18), leg_r(0.050, inner=0.006, outer=0.006), {T: 1}),
             (hip.lerp(knee, 0.42), leg_r(0.040, front=0.006), {T: 1}),
             (hip.lerp(knee, 0.70), leg_r(0.030, front=0.004), {T: 1}),
             (knee + kd * 0.060, leg_r(0.025, front=0.004, sides_=0.006), {T: .9, Sh: .1}),
             (knee + kd * 0.022, leg_r(0.028, front=0.012, sides_=0.008, front_p=6), {T: .65, Sh: .35}),
             (knee, leg_r(0.028, front=0.018, front_p=8, sides_=0.006), {T: .5, Sh: .5}),         # kneecap
             (knee + ad * 0.040, leg_r(0.029, front=0.008, front_p=6, outer=0.004), {T: .2, Sh: .8}),
             (knee + ad * 0.110, leg_r(0.026, front=0.006, front_p=8, calf=0.010), {Sh: 1}),
             (knee.lerp(ankle, 0.42), leg_r(0.022, front=0.005, front_p=8, calf=0.005), {Sh: 1}),
             (knee.lerp(ankle, 0.72), leg_r(0.017, front=0.004, front_p=8, achilles=0.003), {Sh: 1}),
             (knee.lerp(ankle, 0.90), leg_r(0.015, achilles=0.006), {Sh: .85, Ft: .15}),
             (ankle, leg_r(0.018, sides_=0.009, achilles=0.006), {Sh: .5, Ft: .5})]           # ankle bones

    def leg_reg(i, k, c, f):
        d = (f - c).normalized()
        if i == 7 and d.y < -0.8:
            return REG["skin_hi"]          # the kneecap
        if i == 7 and d.y > 0.85:
            return REG["bruise"]           # behind the knee
        if i == 13 and abs(d.x) > 0.9:
            return REG["skin_mid"]         # ankle bones
        return REG["skin"]
    tube(mb, rings, 10, REG["skin"], cap0=True, cap1=False, ref=(side, 0, 0), reg_fn=leg_reg, wob=0.07)
    fv = ball - ankle
    frings = [(ankle - fv * 0.10, 0.024, {Sh: .3, Ft: .7}), (ankle + fv * 0.25, (0.024, 0.028), {Ft: 1}),
              (ankle + fv * 0.60, (0.029, 0.024), {Ft: 1}), (ball - fv * 0.06, (0.037, 0.021), {Ft: .6, To: .4})]
    tube(mb, frings, 8, REG["skin_ext"], cap0=True, cap1=True, ref=(1, 0, 0),
         reg_fn=lambda i, k, c, f: REG["skin_mid"] if (f - c).z > 0.016 else REG["skin_ext"])
    hb = ankle + Vector((0, 0.034, -0.020))
    tube(mb, [(ankle + Vector((0, 0.004, -0.004)), 0.020, {Ft: 1}), (hb, 0.019, {Ft: 1}),
              (hb + Vector((0, 0.014, -0.012)), 0.012, {Ft: 1})], 6, REG["skin_hi"], cap0=False, cap1=True)
    # four long toes from the ball, gripping at the tips, each ending in a thick dark claw
    for j, (dx, L, r0) in enumerate(((-0.034, 0.165, 0.0150), (-0.011, 0.158, 0.0140), (0.012, 0.146, 0.0132),
                                     (0.034, 0.124, 0.0122))):
        b0 = ball + Vector((-dx * side, 0.006, -0.004))
        spread = -dx * side * 0.40
        pts = [b0, b0 + Vector((spread * 0.3, -L * 0.36, 0.008)), b0 + Vector((spread * 0.6, -L * 0.66, 0.012)),
               b0 + Vector((spread * 0.85, -L * 0.90, 0.003)), b0 + Vector((spread, -L, -0.008))]
        tws = [{Ft: .5, To: .5}, {To: 1}, {To: 1}, {To: 1}, {To: 1}]
        rings = [(p, r0 * s, w) for p, s, w in zip(pts, (1.15, 1.10, 0.95, 0.80, 0.55), tws)]
        tube(mb, rings, 5, REG["skin_ext"], cap0=False, cap1=False,
             reg_fn=lambda i, k, c, f=None: REG["bruise"] if i in (1, 2) and (f - c).z > 0.003 else REG["skin_ext"])
        d = (pts[4] - pts[3]).normalized()
        tooth(mb, pts[4] - d * 0.006, (d + Vector((0, -0.6, -0.2))).normalized(), 0.032, r0 * 0.55, {To: 1},
              REG["nail"])


# --------------------------- the job: tabard rags, lanyard, badge, music box ---------------------------
TABARD = dict(top=1.950, bottom=RAG_TOP, off=0.013, cols=8, front=(-152.0, -28.0), back=(28.0, 152.0))
# strips hanging from the bottom edge of each panel: (panel, column, length m, colour index); some torn off
STRIPS = [("F", 0, 0.22, 0, 0.70), ("F", 1, 0.40, 1, 1.30), ("F", 3, 0.34, 2, 0.80), ("F", 4, 0.15, 0, 1.25),
          ("F", 6, 0.30, 1, 0.65),
          ("B", 1, 0.16, 2, 1.20), ("B", 2, 0.24, 0, 0.70), ("B", 5, 0.20, 1, 1.35), ("B", 6, 0.12, 2, 0.80)]


def panel_col_colour(panel, i):
    return VINYL[(i + (1 if panel == "B" else 0)) % 3]


def build_tabard(mb):
    mb.smooth = False
    zs = [TABARD["top"], 1.905, 1.85, 1.79, 1.745, TABARD["bottom"]]
    edges = {}
    for panel, (a0, a1) in (("F", TABARD["front"]), ("B", TABARD["back"])):
        cols = TABARD["cols"]
        angles = [lerp(a0, a1, i / cols) for i in range(cols + 1)]
        rows = []
        for j, z in enumerate(zs):
            row = []
            for i, a in enumerate(angles):
                off = TABARD["off"] + 0.004 * (1 if z < 1.80 else 0)
                p = body_point(a, z, extra=off)
                if j == len(zs) - 1:      # the bottom edge is torn, not cut straight
                    p.z += 0.025 * hash01(i * 3 + (0 if panel == "F" else 40))
                row.append(p)
            rows.append(row)
        interior = Vector((0, spine_y(1.82), 1.82))
        ids = grid(mb, rows, REG["red_p"], interior=interior, wfn=lambda p, j, i: torso_weights(Vector((p.x, p.y, min(p.z, 1.89)))),
                   reg_fn=lambda j, i, panel=panel: REG[panel_col_colour(panel, i) + "_p"])
        edges[panel] = (angles, [mb.co[k] for k in ids[-1]])
    for side in (1, -1):
        pts = []
        for i in range(6):
            t = i / 5
            y = lerp(-0.085, 0.085, t)
            x = side * 0.090
            z = 1.930 + 0.022 * math.sin(math.pi * t)
            pts.append(Vector((x, spine_y(1.93) + y * (0.85 + 0.15 * math.sin(math.pi * t)), z)))
        rows = [[p + Vector((-side * 0.024, 0, 0.004)), p + Vector((side * 0.024, 0, -0.004))] for p in pts]
        grid(mb, rows, REG["yellow_p"], outward=(0, 0, 1),
             wfn=lambda p, j, i, s=side: {"spine2": 0.5, ("clavicle.L" if s > 0 else "clavicle.R"): 0.5})
    for n_strip, (panel, col, length, ci, width) in enumerate(STRIPS):
        angles, bottom = edges[panel]
        p0, p1 = bottom[col], bottom[col + 1]
        mid = (p0 + p1) / 2
        mid.z = RAG_TOP
        half = (p1 - p0) / 2 * 0.86 * width
        half.z = 0.0
        out = Vector((mid.x, mid.y - spine_y(RAG_TOP), 0)).normalized()
        rows = []
        nrow = 5
        for j in range(nrow + 1):
            t = j / nrow
            z = RAG_TOP - length * t
            hw = half * (1 - 0.25 * t * hash01(n_strip + 3))
            a = mid + out * (0.006 * t) + Vector((0, 0, z - mid.z))
            row = [a - hw, a, a + hw]
            if j == nrow:      # ragged torn end: three points at different lengths
                row = [p + Vector((0, 0, length * 0.35 * hash01(n_strip * 5 + q))) for q, p in enumerate(row)]
            rows.append(row)
        side = 1 if mid.x >= 0 else -1
        rb = "rag.%s.%s" % (panel, "L" if side > 0 else "R")
        top_w = torso_weights(Vector((mid.x, mid.y, RAG_TOP)))

        def wfn(p, j, i, top_w=top_w, rb=rb):
            t = min(1.0, (j / nrow) ** 0.7 * 1.15)
            w = {k: v * (1 - t) for k, v in top_w.items()}
            w[rb] = w.get(rb, 0) + t
            return w
        grid(mb, rows, REG[VINYL[ci]], outward=out, wfn=wfn)
    mb.smooth = True


def build_lanyard(mb):
    """The staff lanyard round the neck, its clip, the laminated badge (grimy, hanging crooked) and the
    wind-up music box."""
    mb.smooth = False
    ring_pts = []
    n = 14
    for i in range(n):
        a = 2 * math.pi * i / n
        s = math.sin(a)
        ring_pts.append(Vector((0.064 * math.cos(a), -0.004 + 0.060 * s,
                                1.982 + 0.022 * max(0.0, s) - 0.026 * max(0.0, -s) ** 2)))
    ring_w = lambda p: {"spine2": 0.55, "neck": 0.45}
    tube(mb, [(p, 0.0045, ring_w) for p in ring_pts + ring_pts[:1]], 3, REG["cord"], cap0=False, cap1=False)
    clip = Vector(LANYARD[1])
    for side in (1, -1):
        start = Vector((0.030 * side, -0.060, 1.955))
        pts = []
        for i in range(7):
            t = i / 6
            p = start.lerp(clip + Vector((0.006 * side, 0, 0.012)), t)
            surf = body_point(-90 + side * 12 * (1 - t), p.z, extra=TABARD["off"] + 0.016)
            pts.append(Vector((p.x, min(p.y, surf.y), p.z)))

        def cw(p, start=start):
            t = min(1.0, max(0.0, (start.z - p.z) / (start.z - clip.z)))
            return {"spine2": 1 - t, "lanyard": t}
        tube(mb, [(p, 0.0040, cw) for p in pts], 3, REG["cord"], cap0=False, cap1=False)
    L = {"lanyard": 1}
    X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
    box(mb, clip + Vector((0, -0.002, 0.004)), X * 0.009, Y * 0.004, Z * 0.012, L, lambda f: REG["clip"])
    q = Quaternion(Y, math.radians(-16)) @ Quaternion(Z, math.radians(9))     # hanging crooked
    bc = clip + Vector((0.010, -0.006, -0.062))
    box(mb, bc, q @ (X * 0.040), q @ (Y * 0.0020), q @ (Z * 0.056), L,
        lambda f: REG["badge"] if f == "y-" else REG["card_back"])
    mc = clip + Vector((0.058, -0.024, -0.036))
    box(mb, mc, X * 0.032, Y * 0.023, Z * 0.028, L, lambda f: REG["box_top"] if f == "z+" else REG["box"])
    crank = [mc + Vector((0.032, 0, 0.006)), mc + Vector((0.052, 0, 0.006)), mc + Vector((0.052, 0, -0.016)),
             mc + Vector((0.064, 0, -0.016))]
    tube(mb, [(p, 0.0032, L) for p in crank], 3, REG["brass"], cap0=False, cap1=True)
    tube(mb, [(mc + Vector((0.064, 0, -0.016)), 0.0070, L), (mc + Vector((0.077, 0, -0.016)), 0.0070, L)], 5,
         REG["box_top"], cap0=True, cap1=True)
    tube(mb, [(clip + Vector((0.008, -0.004, 0.0)), 0.003, L), (mc + Vector((-0.016, 0, 0.028)), 0.003, L)], 3,
         REG["cord"], cap0=False, cap1=False)
    mb.smooth = True


# ============================ TEXTURES ============================
def make_atlas():
    """Colour, normal and roughness maps for the body, all on the same 512 px layout."""
    n = TEX
    rng = np.random.default_rng(2311)
    img = np.ones((n, n, 4), dtype=np.float32)
    height = np.zeros((n, n), np.float32)
    rough = np.full((n, n), 0.86, np.float32)
    C = {k: np.array(v, dtype=np.float32) for k, v in COL.items()}

    def px(reg):
        return int(reg[0] * n), int(reg[1] * n), int(reg[2] * n), int(reg[3] * n)

    def uvgrid(reg):
        x0, y0, x1, y1 = px(reg)
        h, w = y1 - y0, x1 - x0
        yy, xx = np.mgrid[0:h, 0:w]
        return x0, y0, x1, y1, (xx + 0.5) / w, (yy + 0.5) / h

    def fill(reg, col, noise=0.012):
        x0, y0, x1, y1 = px(reg)
        h, w = y1 - y0, x1 - x0
        img[y0:y1, x0:x1, :3] = np.clip(np.tile(col, (h, w, 1)) * (1 + (rng.random((h, w, 1)) - 0.5) * 2 * noise), 0, 1)

    def skin(reg, col, bruise_k=0.25, pale_k=0.15, r=0.86):
        """Mottled skin: low-frequency blotches of bruise and of pale, fine grain, pores in the height."""
        x0, y0, x1, y1 = px(reg)
        h, w = y1 - y0, x1 - x0
        big = noise2((h, w), 24, rng)
        mid = noise2((h, w), 8, rng)
        base = np.tile(col, (h, w, 1)) * (0.88 + 0.24 * mid)[..., None]
        bk = np.clip((big - 0.55) * 3.0, 0, 1)[..., None] * bruise_k
        pk = np.clip((0.40 - big) * 3.0, 0, 1)[..., None] * pale_k
        base = base * (1 - bk) + C["bruise"] * bk
        base = base * (1 - pk) + C["skin_hi"] * pk
        base *= (1 + (rng.random((h, w, 1)) - 0.5) * 0.04)
        img[y0:y1, x0:x1, :3] = np.clip(base, 0, 1)
        fine = noise2((h, w), 3, rng, octaves=2)
        streak = noise2((h, w * 3), 6, rng, octaves=2)[:, ::3]       # wrinkles stretched across
        height[y0:y1, x0:x1] = 0.6 * fine + 0.4 * streak
        rough[y0:y1, x0:x1] = r

    skin(REG["skin"], C["skin"], pale_k=0.05)
    skin(REG["skin_hi"], C["skin_hi"], bruise_k=0.10, pale_k=0.0)
    skin(REG["bruise"], C["bruise"], bruise_k=0.0, pale_k=0.05)
    skin(REG["skin_shade"], C["skin_shade"], bruise_k=0.35)
    skin(REG["skin_mid"], C["skin_mid"], bruise_k=0.15)
    skin(REG["skin_ext"], (C["skin"] + C["bruise"]) / 2, bruise_k=0.4, pale_k=0.1)   # hands and feet
    skin(REG["skin_lo"], C["skin_lo"], bruise_k=0.0, pale_k=0.0)
    skin(REG["skin_dk"], C["skin_dk"], bruise_k=0.3, pale_k=0.0)
    fill(REG["gum"], C["gum"], 0.03)
    fill(REG["mouth"], C["mouth"], 0.03)
    for name in ("gum", "mouth"):
        x0, y0, x1, y1 = px(REG[name])
        rough[y0:y1, x0:x1] = 0.20                      # wet
    fill(REG["tooth"], C["tooth"], 0.04)
    x0, y0, x1, y1, u, v = uvgrid(REG["tooth"])      # off-white at the tip going yellow and brown at the gum
    img[y0:y1, x0:x1, :3] *= (0.55 + 0.45 * np.clip(v, 0, 1))[..., None]
    img[y0:y1, x0:x1, 2] *= (0.70 + 0.30 * np.clip(v, 0, 1))
    rough[y0:y1, x0:x1] = 0.35
    fill(REG["nail"], C["nail"], 0.05)
    x0, y0, x1, y1 = px(REG["nail"])
    rough[y0:y1, x0:x1] = 0.45
    fill(REG["strap"], C["strap"], 0.03)
    fill(REG["clip"], C["clip"], 0.04)
    fill(REG["brass"], C["brass"], 0.04)
    fill(REG["card_back"], C["card_back"], 0.03)
    x0, y0, x1, y1, u, v = uvgrid(REG["cord"])
    cord = np.tile(C["cord"], (y1 - y0, x1 - x0, 1))
    cord[np.sin(v * 2 * math.pi * 4) > 0.55] = np.array((0.62, 0.62, 0.60))
    img[y0:y1, x0:x1, :3] = cord * (0.85 + 0.15 * noise2(cord.shape[:2], 8, rng))[..., None]
    fill(REG["box"], C["box"], 0.03)
    x0, y0, x1, y1, u, v = uvgrid(REG["box"])
    r = np.hypot(u - 0.5, v - 0.5)
    ang = np.arctan2(v - 0.5, u - 0.5)
    blk = img[y0:y1, x0:x1, :3]
    blk[r < (0.16 + 0.10 * np.cos(ang * 5))] = np.array((0.78, 0.70, 0.40))
    blk[(u < 0.08) | (u > 0.92) | (v < 0.08) | (v > 0.92)] *= 0.75
    fill(REG["box_top"], C["box_top"], 0.03)
    # the badge: laminated card, a faded striped header, a photo, lines of text; grimy, a scratched shine
    x0, y0, x1, y1, u, v = uvgrid(REG["badge"])
    b = np.tile(C["badge"], (y1 - y0, x1 - x0, 1))
    head = v > 0.80
    b[head & (u < 0.33)] = C["red"] * 1.3
    b[head & (u >= 0.33) & (u < 0.66)] = C["yellow"] * 1.3
    b[head & (u >= 0.66)] = C["blue"] * 1.3
    photo = (u > 0.10) & (u < 0.46) & (v > 0.36) & (v < 0.74)
    b[photo] = np.array((0.50, 0.55, 0.60))
    b[photo & (np.hypot((u - 0.28) / 0.10, (v - 0.56) / 0.12) < 1.0)] = np.array((0.62, 0.54, 0.47))
    for yy, ww in ((0.66, 0.36), (0.56, 0.30), (0.46, 0.34)):
        b[(u > 0.54) & (u < 0.54 + ww) & (np.abs(v - yy) < 0.025)] = C["ink"] * 1.6
    b[(u > 0.10) & (u < 0.86) & (np.abs(v - 0.22) < 0.04)] = C["ink"] * 1.4
    grime = noise2(b.shape[:2], 16, rng)
    b *= (0.62 + 0.38 * grime)[..., None]
    b = b * 0.85 + np.array((0.30, 0.24, 0.16)) * 0.15 * (1 - v)[..., None]
    shine = np.abs((u - v) - 0.15) < 0.04
    b[shine] = b[shine] * 0.85 + 0.12
    img[y0:y1, x0:x1, :3] = np.clip(b, 0, 1)
    rough[y0:y1, x0:x1] = 0.35
    # vinyl: faded, dull, cracked, dirtier toward the torn hem
    for name in VINYL:
        for suffix, grime_k in (("", 1.0), ("_p", 0.45)):
            x0, y0, x1, y1, u, v = uvgrid(REG[name + suffix])
            sh = u.shape
            col = C[name] * (0.85 + 0.25 * noise2(sh, 12, rng))[..., None]
            g = np.clip(1.0 - v * 1.4, 0, 1) ** 1.3 * grime_k
            g = np.clip(g + 0.35 * (noise2(sh, 10, rng) - 0.5) * grime_k, 0, 1)
            col = col * (1 - 0.65 * g[..., None]) + np.array((0.16, 0.12, 0.08)) * 0.65 * g[..., None]
            if suffix == "_p":
                col *= 0.80        # the panels are in the shadow of the chest and as dirty
            crack_h = np.zeros(sh, np.float32)
            for _ in range(8):
                cx, cy = rng.random(), rng.random()
                a = rng.random() * math.pi
                d = np.abs((u - cx) * math.sin(a) - (v - cy) * math.cos(a))
                along = np.abs((u - cx) * math.cos(a) + (v - cy) * math.sin(a))
                m = (d < 0.006) & (along < 0.18)
                col[m] = col[m] * 0.8 + 0.12
                crack_h[m] = -1.0
            st = ((u < 0.07) | (u > 0.93)) & (np.sin(v * 60) > 0.2)
            col[st] = col[st] * 0.6
            img[y0:y1, x0:x1, :3] = np.clip(col, 0, 1)
            height[y0:y1, x0:x1] = 0.5 + 0.3 * crack_h
            rough[y0:y1, x0:x1] = 0.62
    im = bpy.data.images.new(NAME + "_atlas", n, n, alpha=True)
    im.pixels.foreach_set(img.ravel())
    im.pack()
    # normal map from the height field (tangent space, +y up the texture)
    gx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 2.2
    gy = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 2.2
    nz = np.ones_like(gx)
    ln = np.sqrt(gx * gx + gy * gy + nz * nz)
    nm = np.dstack([(-gx / ln) * 0.5 + 0.5, (-gy / ln) * 0.5 + 0.5, (nz / ln) * 0.5 + 0.5, np.ones_like(gx)])
    nim = bpy.data.images.new(NAME + "_normal", n, n, alpha=False)
    nim.colorspace_settings.name = "Non-Color"
    nim.pixels.foreach_set(nm.astype(np.float32).ravel())
    nim.pack()
    # roughness in green, metal (none) in blue, as glTF wants it
    rm = np.dstack([np.zeros_like(rough), rough, np.zeros_like(rough), np.ones_like(rough)])
    rim = bpy.data.images.new(NAME + "_rough", n, n, alpha=False)
    rim.colorspace_settings.name = "Non-Color"
    rim.pixels.foreach_set(rm.astype(np.float32).ravel())
    rim.pack()
    return im, nim, rim


def paint_mask():
    """The card mask: off-white card, a cheap print of our own face (two eyes that do not match, one
    higher and smaller, and a wobbly smile far too wide, nearly edge to edge), a little off register,
    creased, stained, staple holes. Returns (colour, glow): the bare card glows, the ink does not."""
    n = MASK_TEX
    rng = np.random.default_rng(77)
    yy, xx = np.mgrid[0:n, 0:n]
    u = ((xx + 0.5) / n - 0.5) / 0.48
    v = ((yy + 0.5) / n - 0.5) / 0.48
    C = {k: np.array(c, np.float32) for k, c in COL.items()}
    col = np.tile(C["card"], (n, n, 1)) * (0.94 + 0.08 * noise2((n, n), 16, rng))[..., None]
    edge = np.clip(np.hypot(u, v) - 0.70, 0, 1)
    col = col * (1 - 0.45 * edge[..., None]) + np.array((0.62, 0.52, 0.32)) * 0.45 * edge[..., None]
    for (cx, cy, rx, ry, k) in ((-0.45, -0.38, 0.30, 0.22, 0.10), (0.40, 0.55, 0.22, 0.16, 0.08), (0.10, -0.70, 0.35, 0.15, 0.12)):
        st = np.hypot((u - cx) / rx, (v - cy) / ry)
        col[st < 1.0] = col[st < 1.0] * (1 - k) + np.array((0.62, 0.52, 0.34)) * k
        ring = np.abs(st - 1.0) < 0.07
        col[ring] = col[ring] * 0.82 + np.array((0.50, 0.40, 0.26)) * 0.18
    ink = np.zeros((n, n), np.float32)
    for (cx, cy, r, sq) in ((-0.36, 0.34, 0.075, 1.15), (0.32, 0.20, 0.120, 0.92)):
        d = np.hypot((u - cx) / r, (v - cy) / (r * sq))
        ink = np.maximum(ink, np.clip((1.0 - d) * 8, 0, 1))
    tx = u / 0.86
    cy = -0.16 - 0.30 * (1 - tx * tx) + 0.045 * np.sin(tx * 7.0 + 0.4) + 0.05 * tx + 0.10 * np.clip(np.abs(tx) - 0.8, 0, 1) * 5
    width = 0.020 + 0.008 * np.sin(u * 23) + 0.006 * np.sin(u * 9 + 1)
    smile = (np.abs(v - cy) < width) & (np.abs(tx) <= 1.0)
    ink = np.maximum(ink, smile.astype(np.float32))
    mis = np.roll(np.roll(ink, 3, axis=1), -2, axis=0)
    col = col * (1 - 0.18 * mis[..., None]) + np.array((0.80, 0.50, 0.46)) * 0.18 * mis[..., None]
    col = col * (1 - ink[..., None]) + C["ink"] * ink[..., None]
    worn = (rng.random((n, n)) < 0.015) & (ink > 0.5)
    col[worn] = col[worn] * 0.4 + C["card"] * 0.6
    crease = (np.abs(v - (0.55 * u + 0.05)) < 0.010) | (np.abs(u + 0.62 * v - 0.30) < 0.008)
    col[crease] *= 0.80
    for sx in (-0.94, 0.94):
        col[np.hypot(u - sx, v - 0.05) < 0.035] = np.array((0.30, 0.30, 0.32))
    glow = np.tile(C["glow"], (n, n, 1)) * (0.70 + 0.30 * (1 - edge))[..., None]
    glow *= (0.85 + 0.15 * noise2((n, n), 16, rng))[..., None]
    glow = glow * (1 - np.clip(ink * 1.2, 0, 1))[..., None]
    glow[crease] *= 0.6
    imgs = []
    for name, arr in (("_mask", col), ("_mask_glow", glow)):
        a = np.dstack([np.clip(arr, 0, 1), np.ones((n, n, 1), np.float32)])
        im = bpy.data.images.new(NAME + name, n, n, alpha=False)
        im.pixels.foreach_set(a.astype(np.float32).ravel())
        im.pack()
        imgs.append(im)
    return imgs


def make_body_material(images):
    """Matte: roughness from the map (skin 0.86, the wet mouth 0.2), low specular, a skin-grain normal
    map, and (for Blender's renders only) a little dull red under the skin."""
    image, normal, rough = images
    mat = bpy.data.materials.new(NAME + "_body")
    nt = mat.node_tree
    bsdf = next(nd for nd in nt.nodes if nd.type == "BSDF_PRINCIPLED")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    rt = nt.nodes.new("ShaderNodeTexImage")
    rt.image = rough
    rt.interpolation = "Closest"
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(rt.outputs["Color"], sep.inputs["Color"])
    nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    nmt = nt.nodes.new("ShaderNodeTexImage")
    nmt.image = normal
    nmt.interpolation = "Linear"
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nmap.inputs["Strength"].default_value = 0.8
    nt.links.new(nmt.outputs["Color"], nmap.inputs["Color"])
    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.22
    if "Subsurface Weight" in bsdf.inputs:
        bsdf.inputs["Subsurface Weight"].default_value = 0.06
        bsdf.inputs["Subsurface Radius"].default_value = (1.0, 0.25, 0.15)
        bsdf.inputs["Subsurface Scale"].default_value = 0.01
    mat.use_backface_culling = False
    return mat


def make_mask_material(col_im, glow_im):
    mat = bpy.data.materials.new(NAME + "_mask")
    nt = mat.node_tree
    bsdf = next(nd for nd in nt.nodes if nd.type == "BSDF_PRINCIPLED")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = col_im
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    gl = nt.nodes.new("ShaderNodeTexImage")
    gl.image = glow_im
    gl.interpolation = "Closest"
    nt.links.new(gl.outputs["Color"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 0.35
    bsdf.inputs["Roughness"].default_value = 0.85
    mat.use_backface_culling = True                   # the print shows from the front only
    return mat


ASYM = dict(drop_r=0.065, stretch_l=0.10)


R_ARM = ("upperarm.R", "forearm.R", "hand.R", "index1.R", "index2.R", "middle1.R", "middle2.R", "ring1.R",
         "ring2.R", "thumb.R")


L_ARM = tuple(b.replace(".R", ".L") for b in R_ARM)


def wobble(n):
    """A small, fixed irregularity for vertex n: -1..1."""
    return 2.0 * hash01(n * 0.6180339 + 11.0) - 1.0


def asym_amounts(w):
    """How much a point carried by these weights is moved by ASYM: (drop, stretch) fractions."""
    tot = sum(w.values()) or 1.0
    drop = (sum(w.get(b, 0.0) for b in R_ARM) + 0.8 * w.get("clavicle.R", 0.0)) / tot
    stretch = sum(w.get(b, 0.0) for b in L_ARM) / tot
    return drop, stretch


def asym_point(p, drop, stretch):
    p = Vector(p)
    p.z -= ASYM["drop_r"] * drop
    shz = ARM["shoulder"][2]
    if stretch and p.z < shz:
        p.z = shz + (p.z - shz) * (1.0 + ASYM["stretch_l"] * stretch)
    return p


def apply_asym_mesh(mb):
    for i, w in enumerate(mb.w):
        d, s = asym_amounts(w)
        if d or s:
            mb.co[i] = asym_point(mb.co[i], d, s)


def apply_asym_bones(b):
    out = {}
    for name, (h, t, parent) in b.items():
        if name in R_ARM:
            h, t = asym_point(h, 1, 0), asym_point(t, 1, 0)
        elif name == "clavicle.R":
            t = asym_point(t, 1, 0)
        elif name in L_ARM:
            h, t = asym_point(h, 0, 1), asym_point(t, 0, 1)
        out[name] = (tuple(h), tuple(t), parent)
    return out


def noise2(shape, cell, rng, octaves=3):
    """Smooth value noise in 0..1 (bilinear upsampling of random grids, several octaves)."""
    h, w = shape
    out = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        c = max(1, cell >> o)
        gh, gw = h // c + 2, w // c + 2
        g = rng.random((gh, gw)).astype(np.float32)
        ys = np.arange(h) / c
        xs = np.arange(w) / c
        y0 = ys.astype(int)
        x0 = xs.astype(int)
        fy = (ys - y0)[:, None]
        fx = (xs - x0)[None, :]
        fy = fy * fy * (3 - 2 * fy)
        fx = fx * fx * (3 - 2 * fx)
        a = g[y0][:, x0]
        b = g[y0][:, x0 + 1]
        cc = g[y0 + 1][:, x0]
        d = g[y0 + 1][:, x0 + 1]
        out += amp * ((a * (1 - fx) + b * fx) * (1 - fy) + (cc * (1 - fx) + d * fx) * fy)
        tot += amp
        amp *= 0.5
    return out / tot


# ============================ ASSEMBLY ============================
def collect_mesh():
    mb = MeshBuilder()
    build_torso(mb)
    build_spine_knobs(mb)
    build_scapulae(mb)
    build_collarbones(mb)
    build_neck(mb)
    build_head(mb)
    build_jaw(mb)
    build_mask(mb, 1)
    for side, sfx in ((1, ".L"), (-1, ".R")):
        build_arm(mb, side, sfx)
        build_leg(mb, side, sfx)
    build_tabard(mb)
    build_lanyard(mb)
    apply_asym_mesh(mb)
    return mb


def build_mesh(mb, arm, bt, mats):
    me = bpy.data.meshes.new(NAME)
    me.from_pydata([tuple(c) for c in mb.co], [], mb.faces)
    me.update()
    uvl = me.uv_layers.new(name="UVMap")
    for poly, uvs in zip(me.polygons, mb.uvs):
        for k in range(poly.loop_total):
            uvl.data[poly.loop_start + k].uv = uvs[k]
    for m in mats:
        me.materials.append(m)
    for poly, sm, mi in zip(me.polygons, mb.sm, mb.mat):
        poly.use_smooth = sm
        poly.material_index = mi
    ob = bpy.data.objects.new(NAME, me)
    bpy.context.scene.collection.objects.link(ob)
    groups = {name: ob.vertex_groups.new(name=name) for name in bt}
    for vi, w in enumerate(mb.w):
        w = {k: v for k, v in w.items() if v > 1e-4}
        tot = sum(w.values())
        for bname, val in w.items():
            groups[bname].add([vi], val / tot, "REPLACE")
    ob.parent = arm
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    return ob


# ============================ POSING ============================
AX = {"x": Vector((1, 0, 0)), "y": Vector((0, 1, 0)), "z": Vector((0, 0, 1))}


def frame_rot(a0, n0, a1, n1):
    """The rotation that takes direction a0 to a1 and (the part of) n0 (across a0) to n1 (across a1)."""
    def basis(a, n):
        a = a.normalized()
        n = (n - a * a.dot(n)).normalized()
        return Matrix((a, n, a.cross(n))).transposed()
    return (basis(a1, n1) @ basis(a0, n0).transposed()).to_quaternion()


class Rig:
    """Poses the armature in plain maths: each bone's rotation relative to its rest, in armature axes,
    accumulated from the root; two-bone chains are solved to a target with a pole."""

    def __init__(self, arm, bt):
        self.arm = arm
        self.order = list(bt.keys())
        self.parent = {k: v[2] for k, v in bt.items()}
        self.H0 = {k: Vector(v[0]) for k, v in bt.items()}
        self.T0 = {k: Vector(v[1]) for k, v in bt.items()}
        self.B = {pb.name: pb.bone.matrix_local.to_quaternion() for pb in arm.pose.bones}
        self.reach_err = {}

    def two_bone(self, up, lo, S, T, pole, tag):
        L1 = (self.T0[up] - self.H0[up]).length
        L2 = (self.T0[lo] - self.H0[lo]).length
        v = T - S
        d0 = v.length
        d = min(max(d0, abs(L1 - L2) * 1.02 + 1e-4), (L1 + L2) * 0.9995)
        dr = v / max(d0, 1e-9)
        a = (L1 * L1 - L2 * L2 + d * d) / (2 * d)
        h = math.sqrt(max(0.0, L1 * L1 - a * a))
        pp = pole - dr * pole.dot(dr)
        pp = pp.normalized() if pp.length > 1e-6 else Vector((0, 1, 0))
        E = S + dr * a + pp * h
        Tc = S + dr * d
        self.reach_err[tag] = max(self.reach_err.get(tag, 0.0), (Tc - T).length)
        u0 = (self.T0[up] - self.H0[up]).normalized()
        l0 = (self.T0[lo] - self.H0[lo]).normalized()
        n0 = u0.cross(l0)
        u1 = (E - S).normalized()
        l1 = (Tc - E).normalized()
        n1 = u1.cross(l1)
        return frame_rot(u0, n0, u1, n1), frame_rot(l0, n0, l1, n1)

    def solve(self, spec, ik=None, tag=""):
        """spec: {bone: [op, ...]}. Ops (armature axes):
             ("x"|"y"|"z", deg)  rotate relative to the parent (+x pitches an up-bone forward, swings a
                                 down-bone back, turns a forward bone's tip down)
             ("level",)          ignore the parents: later rotations on this bone are in world axes
             ("aim", vec)        point the bone along vec in world axes (rest roll kept); ("roll", deg) after it
             ("world", quat)     the bone's rotation from rest, in world axes
             ("t", vec)          move the root (metres)
           ik: {upper bone: (target for the lower bone's tail, pole direction)}"""
        ik = ik or {}
        D, H, pending = {}, {}, {}
        for b in self.order:
            par = self.parent[b]
            Dp = D[par] if par else Quaternion()
            head = (H[par] + Dp @ (self.H0[b] - self.H0[par])) if par else self.H0[b].copy()
            q, level, aim, roll, world = Quaternion(), False, None, 0.0, None
            for op in spec.get(b, []):
                k = op[0]
                if k in AX:
                    q = Quaternion(AX[k], math.radians(op[1])) @ q
                elif k == "level":
                    level = True
                elif k == "t":
                    head = head + Vector(op[1])
                elif k == "aim":
                    aim = Vector(op[1]).normalized()
                elif k == "roll":
                    roll += op[1]
                elif k == "world":
                    world = op[1]
            if b in pending:
                Dw = pending.pop(b)
            elif b in ik:
                T, pole = ik[b]
                Dw, pending[IK_CHILD[b]] = self.two_bone(b, IK_CHILD[b], head, Vector(T), Vector(pole), tag + ":" + b)
            elif world is not None:
                Dw = world
            elif aim is not None:
                r0 = (self.T0[b] - self.H0[b]).normalized()
                Dw = Quaternion(aim, math.radians(roll)) @ r0.rotation_difference(aim)
            elif level:
                Dw = q
            else:
                Dw = Dp @ q
            D[b], H[b] = Dw, head
        return D, H

    def point(self, D, H, bone, p):
        return H[bone] + D[bone] @ (Vector(p) - self.H0[bone])

    def apply(self, D, H):
        for pb in self.arm.pose.bones:
            b = pb.name
            par = self.parent[b]
            ql = (D[par].inverted() @ D[b]) if par else D[b]
            B = self.B[b]
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = B.inverted() @ ql @ B
            pb.scale = (1, 1, 1)
            if par is None:
                pb.location = B.inverted() @ (H[b] - self.H0[b])
            else:
                pb.location = (0, 0, 0)


RIG = None


def merge(*specs):
    out = {}
    for s in specs:
        for b, ops in s.items():
            out.setdefault(b, []).extend(ops)
    return out


def iter_fcurves(act):
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for cb in strip.channelbags:
                for fc in cb.fcurves:
                    yield fc


def make_action(name, keys, interp):
    """keys: list of (frame, (D, H)) or (frame, (D, H), interpolation from this key)."""
    arm = RIG.arm
    bpy.context.preferences.edit.keyframe_new_interpolation_type = interp
    ad = arm.animation_data or arm.animation_data_create()
    act = bpy.data.actions.new(name)
    ad.action = act
    per = {}
    for key in keys:
        frame, (D, H) = key[0], key[1]
        per[frame] = key[2] if len(key) > 2 else interp
        RIG.apply(D, H)
        for pb in arm.pose.bones:
            for path in ("rotation_quaternion", "location", "scale"):
                pb.keyframe_insert(path, frame=frame, group=pb.name)
    for fc in iter_fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = per.get(int(round(kp.co.x)), interp)
    act.use_fake_user = True
    track = ad.nla_tracks.new()
    track.name = name
    track.strips.new(name, int(keys[0][0]), act)
    track.mute = True
    ad.action = None
    return act


def curl(sfx, a, spread=0.0, tip=None):
    """Bend the fingers toward the palm by a degrees; spread fans them apart along the palm."""
    sgn = 1 if sfx == ".L" else -1
    tip = a if tip is None else tip
    out = {}
    for f, fan in (("index", -1.0), ("middle", -0.2), ("ring", 0.8)):
        out[f + "1" + sfx] = [("y", sgn * a * 0.7), ("x", fan * spread)]
        out[f + "2" + sfx] = [("y", sgn * tip)]
    out["thumb" + sfx] = [("y", sgn * a * 0.4), ("x", -spread * 0.6)]
    return out


def both(fn):
    return merge(fn(1, ".L"), fn(-1, ".R"))


def palm_down(side, fan=18.0, pitch=0.0):
    """World rotation for a hand flat on the floor, fingers forward and fanned out to the side.
    pitch > 0 lifts the fingers (a hand rising off the floor), < 0 curls the hand under."""
    return [("level",), ("x", -90 + pitch), ("y", -90 * side), ("z", fan * side)]


def bump(p, c, w):
    d = (p - c + math.pi) % (2 * math.pi) - math.pi
    return math.exp(-(d / w) ** 2)


def smooth(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


# ---------------- the cloth: rags and lanyard hang plumb, then swing ----------------
def cloth(fl=0.0, fr=0.0, bl=0.0, br=0.0, side=0.0, lan=0.0, lan_side=0.0, back_follow=True):
    """Swing in degrees, world axes: + x swings hanging cloth backward, + z toward the figure's right.
    The front strips and the lanyard hang plumb; the back strips lie along the back and lift."""
    out = {"rag.F.L": [("level",), ("x", fl), ("z", side)], "rag.F.R": [("level",), ("x", fr), ("z", side)],
           "lanyard": [("level",), ("x", lan), ("z", lan_side)]}
    if back_follow:
        out["rag.B.L"] = [("x", bl), ("z", side * 0.5)]
        out["rag.B.R"] = [("x", br), ("z", side * 0.5)]
    else:
        out["rag.B.L"] = [("level",), ("x", bl), ("z", side)]
        out["rag.B.R"] = [("level",), ("x", br), ("z", side)]
    return out


# ---------------- upright ----------------
def upright(stoop=1.0, drop=0.075, back=0.04, twist=0.0, sway=0.0, head_pitch=10.0, head_turn=0.0, head_tilt=0.0,
            breath=0.0, jaw=0.0, crane=14.0, lean=7.0):
    """Upright, slow and stooped: knees soft, the long back folded over at the top, the head carried
    out in front and level, the shoulders drawn up."""
    return {
        "hips": [("t", (0, back, -drop)), ("x", 5 * stoop), ("y", sway), ("z", twist)],
        "spine": [("x", 3 * stoop - breath * 0.3)], "spine1": [("x", 11 * stoop - breath * 0.6), ("z", -twist * 0.5)],
        "spine2": [("x", 20 * stoop - breath)], "neck": [("x", 14 * stoop + crane), ("y", -lean)],
        "neck1": [("x", -12 * stoop - crane * 0.4), ("y", -lean * 0.6)],
        "head": [("level",), ("x", head_pitch), ("z", head_turn), ("y", head_tilt)],
        "jaw": [("x", jaw)],
        "clavicle.L": [("y", -10 - breath * 0.8), ("z", -7)], "clavicle.R": [("y", 13 + breath * 0.8), ("z", 7)],
    }


def hanging_arms(swing_l=0.0, swing_r=0.0, bend_l=14.0, bend_r=20.0, curl_l=22.0, curl_r=34.0, out_l=4.0, out_r=3.0):
    """The long arms hang plumb from the shoulders, a little away from the body, the fingers loose."""
    return merge({"upperarm.L": [("level",), ("y", -out_l), ("x", swing_l)],
                  "upperarm.R": [("level",), ("y", out_r), ("x", swing_r)],
                  "forearm.L": [("x", -bend_l)], "forearm.R": [("x", -bend_r)],
                  "hand.L": [("x", -6), ("y", 6)], "hand.R": [("x", -4), ("y", -8)]},
                 curl(".L", curl_l, spread=6), curl(".R", curl_r, spread=4))


FOOT_AIM_UP = 0.70     # how steeply the long foot stands when upright (z of the unit aim, negative)


def feet(ball_l, ball_r, steep_l=FOOT_AIM_UP, steep_r=FOOT_AIM_UP, toe_l=-0.05, toe_r=-0.05, splay=0.10, knee_out=0.25):
    """Feet placed by the balls (on the floor); the foot aims from the ankle down to the ball."""
    spec, ik = {}, {}
    foot_len = (Vector(LEG["ball"]) - Vector(LEG["ankle"])).length
    for side, sfx, ball, steep, toe in ((1, ".L", ball_l, steep_l, toe_l), (-1, ".R", ball_r, steep_r, toe_r)):
        horiz = math.sqrt(max(0.0, 1 - steep * steep))
        aim = Vector((side * splay * horiz, -horiz, -steep)).normalized()
        ankle = Vector(ball) - aim * foot_len
        spec["foot" + sfx] = [("aim", tuple(aim))]
        spec["toe" + sfx] = [("aim", (side * splay * 0.8, -1.0, toe))]
        ik["thigh" + sfx] = (ankle, (side * knee_out, -1.0, 0.05))
    return spec, ik


def stand_pose(breath=0.0, head_turn=0.0, head_tilt=0.0, jaw=0.0, fing=0.0, lan=0.0):
    body = upright(breath=breath, head_turn=head_turn, head_tilt=-17 + head_tilt, jaw=jaw)   # the head hangs to one side
    fs, ik = feet((0.125, -0.050, 0.026), (-0.118, 0.010, 0.026), splay=0.18)
    arms = hanging_arms(curl_r=34 + fing)
    return RIG.solve(merge(body, fs, arms, cloth(fl=2 + breath, fr=-1, bl=1, br=0, lan=lan)), ik, "stand")


def stand_keys():
    """4 s: it breathes slowly through the slack jaw; the head drifts a little to one side, and once
    the fingers of the right hand curl in one at a time."""
    keys = []
    seq = [(1, 0.0, 0, 0, 0, 0), (25, 1.0, 3, 2, 3, 0), (49, 0.2, 6, 4, 1, 0), (61, 0.6, 6, 4, 2, 10),
           (73, 1.0, 2, 2, 4, 18), (85, 0.5, 0, 0, 2, 8), (97, 0.0, 0, 0, 0, 0)]
    for f, br, turn, tilt, jaw, fing in seq:
        keys.append((f, stand_pose(breath=br * 2.2, head_turn=turn, head_tilt=tilt, jaw=jaw, fing=fing,
                                   lan=0.5 * br), "BEZIER"))
    return keys


WALK = dict(period=36, poses=12, stride=1.50, duty=0.62, lift=0.11)   # 1.5 s, 1.0 m/s natural speed


def gait_pos(ph, duty, stride, lift):
    """Phase 0..1 of one limb: 0 = touch-down. Returns (y offset from neutral, lift height, swing 0..1)."""
    if ph < duty:
        return -stride * duty / 2 + stride * ph, 0.0, 0.0
    u = (ph - duty) / (1 - duty)
    y = stride * duty / 2 - stride * duty * smooth(u)
    return y, lift * math.sin(math.pi * u) ** 0.8, u


def walk_pose(t):
    """Slow, stooped, long-legged. t = 0..1 over one cycle (two steps); left touches down at 0."""
    W = WALK
    S = W["stride"]
    yl, zl, ul = gait_pos(t % 1.0, W["duty"], S, W["lift"])
    yr, zr, ur = gait_pos((t + 0.5) % 1.0, W["duty"], S, W["lift"])
    p = 2 * math.pi * t
    load = bump(p, 0.5, 0.6) + bump(p, math.pi + 0.5, 0.6)
    drop = 0.075 + 0.030 * load
    sway = 3.0 * math.cos(p)
    twist = 5.0 * math.cos(p)
    body = upright(drop=drop, sway=-sway, twist=twist, head_pitch=10, jaw=2 + 2 * math.sin(p * 2))
    body["head"] = [("level",), ("x", 10), ("z", -twist * 0.6)]
    fs, ik = feet((0.120, -0.03 + yl, 0.026 + zl), (-0.120, -0.03 + yr, 0.026 + zr),
                  steep_l=FOOT_AIM_UP + 0.25 * ul * (1 - ul) * 4, steep_r=FOOT_AIM_UP + 0.25 * ur * (1 - ur) * 4,
                  toe_l=-0.05 - 0.6 * math.sin(math.pi * ul), toe_r=-0.05 - 0.6 * math.sin(math.pi * ur), splay=0.14)
    arm_l = 10 * math.cos(p - 1.0)             # the arms swing late, like dead weight
    arms = hanging_arms(swing_l=arm_l, swing_r=-arm_l * 0.7, bend_l=12 + 4 * math.sin(p - 1.4),
                        bend_r=20 - 4 * math.sin(p - 1.4))
    cl = cloth(fl=4 + 6 * math.sin(p - 1.2), fr=4 + 6 * math.sin(p + math.pi - 1.2), bl=2 * math.sin(p - 1.5),
               br=2 * math.sin(p + math.pi - 1.5), side=4 * math.sin(p - 0.8), lan=5 + 4 * math.sin(2 * p - 1.0),
               lan_side=6 * math.sin(p - 1.0))
    return RIG.solve(merge(body, fs, arms, cl), ik, "walk")


def walk_keys():
    W = WALK
    st = W["period"] // W["poses"]
    keys = [(1 + i * st, walk_pose(i / W["poses"])) for i in range(W["poses"])]
    keys.append((1 + W["period"], walk_pose(0.0)))
    return keys


def straighten_keys():
    """3 s, then held: it folds over at the hips, its long hands go flat on the floor in front and
    smooth it, left, right, left, then pat it once; then it unfolds back to its stoop."""
    st = 3
    keys = []
    n = 24                                       # 72 frames = 3 s
    for i in range(n + 1):
        t = i / n
        tt = t * 3.0
        bend = smooth(tt / 0.6) * (1 - smooth((tt - 2.3) / 0.6))
        reach = smooth((tt - 0.25) / 0.45) * (1 - smooth((tt - 2.2) / 0.5))
        body = upright(stoop=1.0, drop=0.075 + 0.32 * bend, back=0.04 + 0.24 * bend, head_pitch=10 + 30 * bend)
        body["hips"] += [("x", 58 * bend)]
        body["spine1"] += [("x", 8 * bend)]
        body["spine2"] += [("x", 6 * bend)]
        body["neck"] += [("x", -14 * bend)]
        fs, ik = feet((0.150, -0.020, 0.026), (-0.140, 0.040, 0.026), steep_l=FOOT_AIM_UP + 0.12 * bend,
                      steep_r=FOOT_AIM_UP + 0.12 * bend, splay=0.25, knee_out=0.45)
        spec = merge(body, fs, cloth(fl=-10 * bend, fr=-8 * bend, bl=6 * bend, br=6 * bend, lan=-3 * bend))
        if reach > 0.02:
            # the smoothing: hands slide side to side on the floor, the right one patting
            sweep = math.sin(max(0.0, tt - 0.7) / 1.5 * 2 * math.pi * 1.5) * min(1.0, max(0.0, (tt - 0.7) / 0.2))
            pat = 0.05 * max(0.0, math.sin((tt - 1.9) * math.pi / 0.3)) if 1.9 < tt < 2.2 else 0.0
            D, H = RIG.solve(merge(spec, hanging_arms()), ik)
            shl, shr = H["upperarm.L"], H["upperarm.R"]
            tl = Vector((shl.x * 1.15 + 0.10 * sweep, shl.y - 0.16, 0.040))
            tr = Vector((shr.x * 1.15 + 0.10 * sweep, shr.y - 0.12, 0.040 + pat))
            for side, sfx, tgt in ((1, ".L", tl), (-1, ".R", tr)):
                rest = Vector(mirror_pt(ARM["wrist"], side))
                hang = H["forearm" + sfx] + D["forearm" + sfx] @ (rest - RIG.H0["forearm" + sfx])
                tgt = tgt + Vector((0, 0, 0.22 * (1 - reach)))
                ik["upperarm" + sfx] = (hang.lerp(tgt, reach), (side * 0.7, 1.0, 0.2))
            arms = merge({"hand.L": palm_down(1, 20, pitch=70 * (1 - reach) ** 2),
                          "hand.R": palm_down(-1, 20, pitch=70 * (1 - reach) ** 2 - 300 * pat)},
                         curl(".L", 4 * reach + 20 * (1 - reach), spread=10 * reach, tip=-6 * reach + 20 * (1 - reach)),
                         curl(".R", 4 * reach + 30 * (1 - reach), spread=8 * reach, tip=-6 * reach + 30 * (1 - reach)))
        else:
            arms = hanging_arms()
        keys.append((1 + i * st, RIG.solve(merge(spec, arms), ik, "straighten")))
    keys[-1] = (keys[-1][0], stand_pose())         # ends exactly in the standing pose, held
    return keys


# ---------------- crouched, and on all fours ----------------
def quad_body(pitch=74.0, hip_h=0.80, back=0.36, roll=0.0, yaw=0.0, arch=0.0, neck=4.0, head_pitch=12.0,
              head_turn=0.0, head_tilt=0.0, jaw=4.0, shoulders=0.0, neck1=-4.0):
    """On all fours: the long back nearly level, the shoulders a little higher than the hips, the neck
    thrown forward and the long head carried low and level."""
    return {
        "hips": [("t", (0, back, hip_h - 1.15)), ("x", pitch), ("y", roll), ("z", yaw)],
        "spine": [("x", 2 - arch)], "spine1": [("x", 4 - arch), ("z", -yaw * 0.6)], "spine2": [("x", -2 - arch * 0.5)],
        "neck": [("x", neck), ("z", head_turn * 0.3)], "neck1": [("x", neck1)],
        "head": [("level",), ("x", head_pitch), ("z", head_turn), ("y", head_tilt)],
        "jaw": [("x", jaw)],
        "clavicle.L": [("y", -4 - shoulders), ("z", -10)], "clavicle.R": [("y", 4 + shoulders), ("z", 10)],
    }


ELBOW_POLE = (0.75, 1.0, 0.35)
KNEE_POLE = (0.55, -1.0, 0.25)


def quad_limbs(D, H, hands, feet_, hand_pitch=(0.0, 0.0), foot_steep=(0.88, 0.88), toe=(-0.05, -0.05),
               finger=(6.0, 6.0), elbow_pole=ELBOW_POLE, knee_pole=KNEE_POLE):
    """hands, feet_: per side offsets (dx, dy, lift) from the neutral spot under the shoulder / hip."""
    spec, ik = {}, {}
    foot_len = (Vector(LEG["ball"]) - Vector(LEG["ankle"])).length
    for k, (side, sfx) in enumerate(((1, ".L"), (-1, ".R"))):
        sh = H["upperarm" + sfx]
        hip = H["thigh" + sfx]
        dx, dy, lift = hands[k]
        wrist = Vector((sh.x * 1.10 + side * dx, sh.y - 0.10 + dy, 0.042 + lift))
        ik["upperarm" + sfx] = (wrist, (side * elbow_pole[0], elbow_pole[1], elbow_pole[2]))
        spec["hand" + sfx] = palm_down(side, 20, pitch=hand_pitch[k])
        spec.update(curl(sfx, finger[k], spread=12, tip=-finger[k] * 0.3))
        dx, dy, lift = feet_[k]
        steep = foot_steep[k]
        horiz = math.sqrt(max(0.0, 1 - steep * steep))
        aim = Vector((side * 0.20 * horiz, -horiz, -steep)).normalized()
        ball = Vector((hip.x * 1.30 + side * dx, hip.y - 0.02 + dy, 0.026 + lift))
        ik["thigh" + sfx] = (ball - aim * foot_len, (side * knee_pole[0], knee_pole[1], knee_pole[2]))
        spec["foot" + sfx] = [("aim", tuple(aim))]
        spec["toe" + sfx] = [("aim", (side * 0.18, -1.0, toe[k]))]
    return spec, ik


def quad_pose(body_kw, hands, feet_, cloth_kw, tag, **limb_kw):
    body = quad_body(**body_kw)
    D, H = RIG.solve(body)
    limbs, ik = quad_limbs(D, H, hands, feet_, **limb_kw)
    return RIG.solve(merge(body, limbs, cloth(**cloth_kw)), ik, tag)


PROWL = dict(period=16, step=2, stride=1.40, duty=0.58, lift_h=0.10, lift_f=0.08)   # 0.667 s, 2.1 m/s natural
RUN = dict(period=12, stride=2.60, duty=0.34, lift_h=0.16, lift_f=0.18)              # 0.5 s, 5.2 m/s natural


def prowl_pose(t):
    """All fours, low, a lateral walk (left hind, left fore, right hind, right fore), the head swinging
    from side to side, the jaw hanging."""
    P = PROWL
    p = 2 * math.pi * t
    hands, feet_, hp, fs = [], [], [], []
    for k, (h_off, f_off) in enumerate(((0.25, 0.0), (0.75, 0.5))):
        y, z, u = gait_pos((t - h_off) % 1.0, P["duty"], P["stride"], P["lift_f"])
        hands.append((0.0, y, z))
        hp.append(40 * math.sin(math.pi * u) if u > 0 else 0.0)
        y, z, u = gait_pos((t - f_off) % 1.0, P["duty"], P["stride"], P["lift_h"])
        feet_.append((0.0, y, z))
        fs.append(0.88 + 0.08 * math.sin(math.pi * u))
    bob = 0.025 * math.cos(2 * p)
    body = dict(pitch=74 + 2 * math.sin(2 * p), hip_h=0.80 + bob, roll=3 * math.sin(p), yaw=5 * math.sin(p),
                head_turn=22 * math.sin(p - 0.6), head_tilt=6 * math.sin(p), jaw=5 + 3 * math.sin(2 * p))
    cl = dict(fl=-8 + 8 * math.sin(p), fr=-8 + 8 * math.sin(p + math.pi), bl=-6 + 3 * math.sin(2 * p), br=-6 - 3 * math.sin(2 * p),
              side=8 * math.sin(p - 0.8), lan=-6 + 6 * math.sin(2 * p), lan_side=12 * math.sin(p - 1.0))
    return quad_pose(body, hands, feet_, cl, "prowl", hand_pitch=tuple(hp), foot_steep=tuple(fs))


def prowl_keys():
    P = PROWL
    keys = [(1 + i, prowl_pose(i / P["period"])) for i in range(0, P["period"], P["step"])]
    keys.append((1 + P["period"], prowl_pose(0.0)))
    return keys


def run_pose(t):
    """All fours at full stretch: a bounding gallop. Hind feet land together and drive, the fore feet
    reach far out in front, the long back folds and unfolds, the head stays low and level."""
    R = RUN
    p = 2 * math.pi * t
    hands, feet_, hp, fs = [], [], [], []
    for k, (h_off, f_off) in enumerate(((0.50, 0.0), (0.60, 0.08))):
        y, z, u = gait_pos((t - h_off) % 1.0, R["duty"], R["stride"], R["lift_f"])
        hands.append((0.03, y - 0.10, z))
        hp.append(55 * math.sin(math.pi * u) if u > 0 else 0.0)
        y, z, u = gait_pos((t - f_off) % 1.0, R["duty"], R["stride"], R["lift_h"])
        feet_.append((0.02, y + 0.05, z))
        fs.append(0.80 + 0.15 * math.sin(math.pi * u))
    flex = math.sin(p - 0.6)                      # + gathered, - stretched
    body = dict(pitch=78 - 6 * flex, hip_h=0.74 + 0.05 * math.sin(2 * p - 1.0), back=0.40, arch=10 * flex,
                neck=10 + 4 * flex, head_pitch=6 + 4 * flex, head_turn=4 * math.sin(p), jaw=8 + 4 * math.sin(2 * p))
    cl = dict(fl=40 + 10 * math.sin(p), fr=36 + 10 * math.sin(p + 0.5), bl=2 + 6 * flex, br=3 + 6 * flex,
              side=5 * math.sin(p), lan=48 + 10 * math.sin(2 * p), lan_side=6 * math.sin(p))
    return quad_pose(body, hands, feet_, cl, "run", hand_pitch=tuple(hp), foot_steep=tuple(fs),
                     finger=(2.0, 2.0))


def run_keys():
    R = RUN
    keys = [(1 + i, run_pose(i / R["period"])) for i in range(R["period"])]
    keys.append((1 + R["period"], run_pose(0.0)))
    return keys


def sweep_keys():
    """3 s loop: on all fours, turning on the spot (the rules turn its body), stepping in place, the
    head low and sweeping from side to side, the jaw working as if tasting the air."""
    keys = []
    n = 36                                        # every 2 frames over 72
    for i in range(n + 1):
        t = (i % n) / n
        p = 2 * math.pi * t
        step = 4 * t % 1.0                        # four steps of the feet over the loop
        hands = [(0.0, 0.0, 0.07 * max(0.0, math.sin(2 * math.pi * step))),
                 (0.0, 0.0, 0.07 * max(0.0, math.sin(2 * math.pi * step + math.pi)))]
        feet_ = [(0.0, 0.0, 0.06 * max(0.0, math.sin(2 * math.pi * step + math.pi))),
                 (0.0, 0.0, 0.06 * max(0.0, math.sin(2 * math.pi * step)))]
        body = dict(pitch=76, hip_h=0.78, roll=2 * math.sin(4 * p), yaw=8 * math.sin(2 * p), neck=14,
                    head_pitch=24, head_turn=34 * math.sin(2 * p), head_tilt=10 * math.sin(2 * p + 0.5),
                    jaw=6 + 6 * max(0.0, math.sin(8 * p)))
        cl = dict(fl=-6, fr=-6, bl=-6, br=-6, side=10 * math.sin(2 * p - 0.6), lan=-4, lan_side=14 * math.sin(2 * p - 0.8))
        keys.append((1 + 2 * i, quad_pose(body, hands, feet_, cl, "sweep",
                                          hand_pitch=(30 * hands[0][2] / 0.07, 30 * hands[1][2] / 0.07))))
    return keys


def look_keys():
    """2 s, then held: it lowers its front, elbows out, and pushes the long head in low and level, as
    far as the neck goes, into the gap; the jaw works once; the head turns over to one side."""
    keys = []
    n = 24
    for i in range(n + 1):
        t = i / n * 2.0
        g = smooth(t / 0.5)
        tw = smooth((t - 1.1) / 0.25)
        body = dict(pitch=74 + 10 * g, hip_h=0.80 + 0.04 * g, back=0.36 - 0.04 * g, neck=4 - 6 * g,
                    head_pitch=12 + 6 * g, head_tilt=-24 * tw, jaw=4 + 10 * (smooth((t - 0.6) / 0.2) - smooth((t - 0.9) / 0.2)),
                    shoulders=-8 * g)
        hands = [(0.10 * g, -0.06 * g, 0.0), (0.10 * g, -0.06 * g, 0.0)]
        feet_ = [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)]
        cl = dict(fl=-14 * g, fr=-12 * g, bl=-6, br=-6, lan=-6 * g)
        keys.append((1 + 2 * i, quad_pose(body, hands, feet_, cl, "look",
                                          elbow_pole=(1.0, 0.6, 0.6), finger=(10.0, 14.0))))
    return keys


def slump_keys():
    """1 s, then held: a sharp breath in that lifts the shoulders and the head, then it sags: the back
    drops, the head hangs nearly to the floor, the fingers splay flat."""
    keys = []
    n = 12
    for i in range(n + 1):
        t = i / n
        up = smooth(t / 0.25) * (1 - smooth((t - 0.3) / 0.3))
        sag = smooth((t - 0.3) / 0.45)
        body = dict(pitch=74 - 6 * up + 6 * sag, hip_h=0.80 + 0.03 * up - 0.06 * sag, neck=4 - 16 * up + 22 * sag,
                    head_pitch=12 - 12 * up + 38 * sag, head_tilt=8 * sag, jaw=4 + 6 * up + 8 * sag,
                    shoulders=6 * up - 10 * sag, arch=-8 * up + 10 * sag)
        hands = [(0.03 * sag, 0.0, 0.0), (0.05 * sag, 0.0, 0.0)]
        feet_ = [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)]
        cl = dict(fl=-6 + 4 * up, fr=-6 + 4 * up, bl=-6 + 3 * up, br=-6 + 3 * up, lan=-4)
        keys.append((1 + 2 * i, quad_pose(body, hands, feet_, cl, "slump", elbow_pole=(0.9, 0.8, 0.3),
                                          finger=(6 - 6 * sag, 6 - 6 * sag))))
    return keys


def catch_keys():
    """3 s, then held: from all fours it rears up tall, the long arms thrown wide, then comes down on
    whoever is in front of it: both hands close round them low in front, the head drives in over them
    with the jaw hanging wide under the mask, and it holds them there, breathing."""
    keys = []
    n = 36
    for i in range(n + 1):
        t = i / n * 3.0
        rise = smooth(t / 0.45) * (1 - smooth((t - 0.55) / 0.30))
        grab = smooth((t - 0.55) / 0.30)
        breathe = math.sin(max(0.0, t - 0.9) * 2 * math.pi / 1.1) * min(1.0, max(0.0, t - 0.9))
        twitch = 1.0 if (1.6 < t < 1.75 or 2.4 < t < 2.5) else 0.0
        pitch = lerp(74, 30, rise) * (1 - grab) + 60 * grab
        hip_h = lerp(0.80, 1.00, rise) * (1 - grab) + 0.82 * grab
        body = quad_body(pitch=pitch, hip_h=hip_h, back=lerp(0.36, 0.20, rise) * (1 - grab) + 0.24 * grab,
                         neck=lerp(4, -14, rise) * (1 - grab) + (14 + 3 * breathe) * grab,
                         head_pitch=lerp(12, -10, rise) * (1 - grab) + (30 + 6 * twitch) * grab,
                         head_tilt=10 * twitch, jaw=2 + 6 * rise + (14 + 3 * breathe) * grab, arch=-6 * rise + 4 * grab * breathe)
        D, H = RIG.solve(body)
        spec, ik = {}, {}
        for k, (side, sfx) in enumerate(((1, ".L"), (-1, ".R"))):
            sh = H["upperarm" + sfx]
            wide = Vector((side * 0.62, sh.y - 0.30, sh.z + 0.18))
            clutch = Vector((side * (0.13 + 0.01 * breathe), -0.62 + 0.04 * breathe, 0.78))
            if t < 0.55:
                quad = Vector((sh.x * 1.1, sh.y - 0.10, 0.032))
                tgt = quad.lerp(wide, smooth(t / 0.45))
                pole = (side * 0.8, 0.6, 0.5)
            else:
                tgt = wide.lerp(clutch, grab)
                pole = (side * 0.9, 0.5, -0.2)
            ik["upperarm" + sfx] = (tgt, pole)
            if t < 0.55:
                spec["hand" + sfx] = palm_down(side, 20, pitch=60 * smooth(t / 0.45))
            else:
                # palms turned in to close round something low in front
                spec["hand" + sfx] = [("level",), ("x", -70), ("y", -side * 8), ("z", side * 30 * (1 - grab))]
            spec.update(curl(sfx, 6 + 50 * grab + 6 * twitch, spread=16 * (1 - grab) + 8, tip=50 * grab))
        fs, fik = feet((0.20, -0.05 - 0.10 * grab, 0.026), (-0.18, 0.12 - 0.05 * grab, 0.026), steep_l=0.86, steep_r=0.86,
                       splay=0.30, knee_out=0.55)
        ik.update(fik)
        cl = cloth(fl=lerp(-6, 10, rise) - 10 * grab, fr=lerp(-6, 12, rise) - 10 * grab, bl=4, br=4,
                   lan=lerp(-4, 8, rise) - 12 * grab, lan_side=4 * twitch)
        keys.append((1 + 2 * i, RIG.solve(merge(body, spec, fs, cl), ik, "catch")))
    return keys


def cover_pose(t):
    """Crouched deep facing the wall, heels high so the legs fold the wrong way, both long hands
    spread over the mask; it rocks a little and the fingers tighten."""
    p = 2 * math.pi * t
    rock = math.sin(p)
    body = {
        "hips": [("t", (0, 0.10, 0.56 - 1.15)), ("x", 36 + 3 * rock)],
        "spine": [("x", 10)], "spine1": [("x", 12 + rock)], "spine2": [("x", 14 + rock)],
        "neck": [("x", 4)], "neck1": [("x", -2)],
        "head": [("level",), ("x", 30 + 3 * rock), ("y", 6)],
        "jaw": [("x", 8 + 2 * rock)],
        "clavicle.L": [("y", -16), ("z", -10)], "clavicle.R": [("y", 16), ("z", 10)],
    }
    fs, ik = feet((0.20, -0.12, 0.026), (-0.19, -0.08, 0.026), steep_l=0.94, steep_r=0.94, splay=0.35, knee_out=0.70)
    D, H = RIG.solve(merge(body, fs), ik)
    c, fwd, up, right = mask_frame()
    M = RIG.point(D, H, "head", c)
    f = D["head"] @ fwd
    u = D["head"] @ up
    r = D["head"] @ right
    spec = {}
    for side, sfx in ((1, ".L"), (-1, ".R")):
        wrist = M + f * 0.035 - u * 0.190 + r * (side * 0.075)
        ik["upperarm" + sfx] = (wrist, (side * 0.9, 0.2, -0.8))
        fingers = (u * 0.95 - r * side * 0.32).normalized()
        rest_d = (Vector(mirror_pt(ARM["knuckle"], side)) - Vector(mirror_pt(ARM["wrist"], side))).normalized()
        q = frame_rot(rest_d, Vector((-side, 0, 0)), fingers, -f)
        spec["hand" + sfx] = [("world", q)]
        spec.update(curl(sfx, 8 + 4 * (0.5 + 0.5 * math.sin(p * 2)), spread=10, tip=14))
    cl = cloth(fl=-4, fr=-4, bl=-8, br=-8, lan=-2, back_follow=True)
    return RIG.solve(merge(body, fs, spec, cl), ik, "cover")


def cover_keys():
    keys = []
    for i in range(13):
        t = (i % 12) / 12
        keys.append((1 + i * 6, cover_pose(t), "BEZIER"))
    return keys


# Loops loop; one-shots end held. The rules (sim/seek.gd) time the one-shots: straighten 3 s, look 2 s,
# slump 1 s, catch 3 s.
ACTIONS = [
    ("stand", stand_keys, "BEZIER", True),
    ("walk", walk_keys, "CONSTANT", True),
    ("straighten", straighten_keys, "CONSTANT", False),
    ("cover", cover_keys, "BEZIER", True),
    ("prowl", prowl_keys, "CONSTANT", True),
    ("sweep", sweep_keys, "LINEAR", True),
    ("look", look_keys, "LINEAR", False),
    ("slump", slump_keys, "LINEAR", False),
    ("run", run_keys, "LINEAR", True),
    ("catch", catch_keys, "LINEAR", False),
]


# ============================ MAIN ============================
def main():
    global RIG
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "godot", "assets", "entities", "minder.glb"))
    ap.add_argument("--blend", default="")
    ap.add_argument("--atlas", default="")
    ap.add_argument("--drop", default="", help="comma-separated actions to leave out (for the break test)")
    args = ap.parse_args(argv)
    drop = set(x for x in args.drop.split(",") if x)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.fps = FPS
    mb = collect_mesh()
    bt = bone_table()
    arm = build_armature(bt)
    atlas_imgs = make_atlas()
    atlas = atlas_imgs[0]
    mask_col, mask_glow = paint_mask()
    if args.atlas:
        for im, suffix in ((atlas, ""), (mask_col, "_mask"), (mask_glow, "_mask_glow")):
            cp = im.copy()
            base, ext = os.path.splitext(args.atlas)
            cp.filepath_raw = base + suffix + ext
            cp.file_format = "PNG"
            cp.save()
    mats = [make_body_material(atlas_imgs), make_mask_material(mask_col, mask_glow)]
    ob = build_mesh(mb, arm, bt, mats)
    RIG = Rig(arm, bt)

    for name, fn, interp, loop in ACTIONS:
        if name in drop:
            print(f"[build] DROPPED action {name} (break test)")
            continue
        keys = fn()
        # Godot's scene importer loops a clip whose name ends in "-loop" and drops the suffix, so the
        # game sees the rules' exact pose names, the loops already looping.
        make_action(name + ("-loop" if loop else ""), keys, interp)
        print(f"[build] action {name}: frames 1-{keys[-1][0]} ({(keys[-1][0] - 1) / FPS:.2f} s), "
              f"{'loop' if loop else 'one-shot, ends held'}")
    for tag, e in sorted(RIG.reach_err.items()):
        if e > 0.005:
            print(f"[build] reach: {tag} short of its target by up to {e * 1000:.0f} mm")
    for pb in arm.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
    scn.frame_start, scn.frame_end = 1, 97

    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    zs = [v.co.z for v in ob.data.vertices]
    print(f"[build] verts={len(ob.data.vertices)} tris={tris} bones={len(arm.data.bones)} "
          f"rest height={max(zs):.3f} m lowest={min(zs):.3f} m")
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    if args.blend:
        bpy.ops.wm.save_as_mainfile(filepath=args.blend)
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB", export_animations=True,
                              export_animation_mode="ACTIONS", export_skins=True, export_yup=True,
                              export_apply=False, export_force_sampling=True, export_anim_slide_to_zero=True)
    print("[build] exported", os.path.relpath(args.out, ROOT), os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
