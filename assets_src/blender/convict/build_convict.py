"""Build "the Convict" (the crewmate figure) from an empty scene: one closed mesh in a strict T-pose
wearing a screen mask, four materials, painted textures, the separate headwear pieces, and the
exports for Mixamo and for three.js.

Usage (headless, from anywhere):
  blender.exe --background --factory-startup --python-exit-code 1 --python build_convict.py
        -- [--glb PATH] [--texdir DIR] [--no-inbox]

Outputs (default):
  assets_src/inbox/convict-for-mixamo.fbx   unrigged T-pose, skin 1 and suit textures embedded
  assets_src/inbox/convict-for-mixamo.zip   OBJ + MTL + both textures (fallback upload)
  assets_src/blender/convict/convict_tpose.glb
  assets_src/blender/convict/convict_suit.png (256), convict_skin_1..4.png (128, skin tones)
  assets_src/blender/convict/headwear_knit.glb, headwear_hair.glb, headwear_none.glb
      (origin at the head joint, see JOINTS["head"]; no rig of their own)

How it is built: box modelling done by numbers. The torso is a stack of 14-vertex rings (the outline
of a 5 x 2 grid); each arm grows out of a 2 x 2 patch of its side wall, each leg out of a 2 x 2 patch
of the bottom (the middle column of the bottom stays as the crotch), and the neck out of the middle
3 x 2 patch of the top. Every ring after that is placed by a small table, so the whole figure is one
closed, manifold surface with no hidden parts. The mask, its straps and cable, the pockets, toes and
thumbs are face extrusions of that surface.
Blender space: Z up, the figure faces -Y, +X is its left, feet on the origin.
"""
import bpy, bmesh, sys, os, math, argparse, zipfile
import numpy as np
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
INBOX = os.path.join(ROOT, "assets_src", "inbox")

# =========================== PARAMETERS ===========================
P = dict(
    suit_px=256, skin_px=128, hw_px=64,
    sharp_deg=58.0,          # edges folding more than this are hard (mask box, cuffs, boot welt)
    mats=("convict_suit", "convict_skin", "number_patch", "face_screen"),
)
SUIT, SKIN, PATCH, SCREEN = 0, 1, 2, 3

# Torso key rows, right half (x < 0): z, front verts (x0 outer, x1, x2 inner), back verts, side-middle y.
# Rows in between are interpolated (TORSO_Z). Front x2..x3 at 1.24-1.34 is the flat chest patch
# (16 x 10 cm); back x1..x4 at 1.18-1.34 the back patch (26 x 16 cm). 1.34 and up at the side wall is
# the arm root.
KEYS = [
    (0.800, [(-0.165, -0.050), (-0.0985, -0.095), (-0.032, -0.075)], [(-0.165, 0.055), (-0.0985, 0.105), (-0.032, 0.085)], 0.0),
    (0.920, [(-0.177, -0.060), (-0.110, -0.102), (-0.035, -0.110)], [(-0.177, 0.062), (-0.110, 0.112), (-0.035, 0.100)], 0.0),
    (1.050, [(-0.160, -0.052), (-0.118, -0.094), (-0.050, -0.104)], [(-0.160, 0.050), (-0.118, 0.084), (-0.050, 0.085)], 0.0),
    (1.180, [(-0.166, -0.052), (-0.130, -0.099), (-0.080, -0.111)], [(-0.166, 0.052), (-0.130, 0.088), (-0.080, 0.088)], 0.0),
    (1.240, [(-0.170, -0.056), (-0.135, -0.104), (-0.080, -0.115)], [(-0.170, 0.056), (-0.130, 0.088), (-0.080, 0.088)], 0.0),
    (1.340, [(-0.168, -0.060), (-0.138, -0.106), (-0.080, -0.115)], [(-0.168, 0.060), (-0.130, 0.088), (-0.080, 0.088)], 0.0),
    (1.3975, [(-0.168, -0.063), (-0.134, -0.096), (-0.070, -0.105)], [(-0.168, 0.063), (-0.122, 0.084), (-0.060, 0.084)], None),
]
# rows actually built: z, how far the row is pushed out (belt, the blousing over it)
TORSO_Z = [(0.800, 0.0), (0.930, 0.0), (1.004, -0.001), (1.006, 0.008), (1.054, 0.008),
           (1.064, 0.015), (1.180, 0.0), (1.240, 0.0), (1.290, 0.0), (1.340, 0.0), (1.3975, 0.0)]
SHOULDER = dict(x=-0.168, y=0.060, z=1.450, zmid=1.455)
CROTCH = (-0.032, 0.005, 0.772)   # lowered: a gusset between the legs

A10 = [-144, -108, -72, -36, 0, 36, 72, 108, 144, 180]  # neck ring angles (x = cos, y = sin; -90 = front)
A12 = [-162, -126, -90, -54, -18, 0, 18, 54, 90, 126, 162, 180]  # head ring angles: -18 / -162 just in front of the ears
# neck and head rings: rx, ry front, ry back, centre y, z front, z back. The head rings ("H") are scaled
# by HS about HZ0, so the head with its mask balances the torso; the collar sits low and soft.
HEADR = [
    ("N0", 0.072, 0.064, 0.062, 0.000, 1.468, 1.480),   # base of the neck = top of the torso
    ("N1", 0.081, 0.075, 0.071, 0.000, 1.478, 1.496),   # collar edge
    ("N2", 0.063, 0.058, 0.060, 0.002, 1.484, 1.503),   # collar tucks in to the neck
    ("N3", 0.057, 0.051, 0.055, 0.004, 1.500, 1.524),
    ("H1", 0.066, 0.086, 0.070, 0.000, 1.535, 1.580),   # jaw (the bottom of the mask)
    ("H2", 0.078, 0.094, 0.090, 0.000, 1.575, 1.608),
    ("H3", 0.084, 0.097, 0.101, 0.000, 1.615, 1.635),
    ("H4", 0.086, 0.096, 0.106, 0.000, 1.655, 1.660),   # ears
    ("H5", 0.085, 0.096, 0.106, 0.000, 1.695, 1.695),   # top of the mask; harness band round the back
    ("H6", 0.077, 0.088, 0.098, 0.000, 1.730, 1.728),
    ("H7", 0.052, 0.060, 0.070, 0.000, 1.746, 1.746),   # crown
]
HS, HZ0 = 1.075, 1.52
HEAD_TOP_Z = HZ0 + (1.753 - HZ0) * HS
EAR = 0.009
# The mask: a small CRT housing over the face. The front of the head (four columns, jaw to brow) is
# extruded out by a soft gasket, then to the rim of the housing (whose sides reach back to just in
# front of the ears), then forward to the front, which is inset for a chunky bezel and recessed for the
# screen. W is the head's half width plus 1.5 cm, so nothing overhangs as a flap.
MASK = dict(W=0.108, z0=1.512, z1=1.752, rim_y=-0.012, front=-0.138, taper=0.94, gasket=0.008,
            bezel=(0.83, 0.75), recess=0.006, strap=0.0065, bolt=0.006)
CABLE = [  # under the housing to the collar, lying against the neck: centre y, z, half width, half depth
    (-0.112, 1.507, 0.014, 0.012), (-0.106, 1.499, 0.011, 0.010), (-0.101, 1.492, 0.013, 0.011),
    (-0.097, 1.485, 0.011, 0.010), (-0.094, 1.477, 0.016, 0.012)]  # last: the plug on the collar

# Arm rings (left arm; the right is mirrored): x, centre z, half depth (y), half height up, down.
# Root on the torso is ring 0. The sleeve and the glove's gauntlet use 8-sided rings; the hand uses
# 12-sided rings (HAND) so the finger block can carry grooves.
ARM = [
    (0.188, 1.404, 0.063, 0.069, 0.058),   # 1 deltoid cap
    (0.222, 1.402, 0.059, 0.065, 0.055),   # 2
    (0.262, 1.400, 0.056, 0.058, 0.054),   # 3 high on the upper arm
    (0.430, 1.398, 0.049, 0.049, 0.049),   # 4 elbow loops (five), gathered
    (0.452, 1.398, 0.053, 0.052, 0.052),   # 5
    (0.472, 1.398, 0.050, 0.050, 0.050),   # 6 elbow point (pushed back)
    (0.492, 1.398, 0.050, 0.049, 0.049),   # 7
    (0.515, 1.398, 0.047, 0.046, 0.046),   # 8
    (0.668, 1.398, 0.053, 0.051, 0.051),   # 9 rolled cuff
    (0.700, 1.398, 0.053, 0.051, 0.051),   # 10
    (0.702, 1.398, 0.040, 0.036, 0.036),   # 11 glove (from here): under the sleeve
    (0.706, 1.398, 0.047, 0.043, 0.043),   # 12 gauntlet, flaring
    (0.742, 1.398, 0.059, 0.054, 0.054),   # 13 gauntlet rim, wider than the sleeve
    (0.745, 1.398, 0.041, 0.034, 0.034),   # 14 steps in to the wrist
]
ARM_STEP = 11               # bands before this ring are sleeve
ELBOW = 6                   # the ring whose back is pushed out into the point of the elbow
WOBBLE = {4, 5, 7, 8}    # sleeve rings that get a little uneven bagginess
ARM_ANG = [-135, 180, 135, 90, 45, 0, -45, -90]  # (y = cos, z = sin), matches the torso patch order
# hand: x, centre z, half depth, half height, curl (degrees toward the palm), finger grooves
HAND = [
    (0.762, 1.397, 0.041, 0.034, 0, False),   # wrist
    (0.800, 1.396, 0.055, 0.036, 0, False),   # palm
    (0.842, 1.395, 0.059, 0.035, 0, False),   # knuckles
    (0.868, 1.390, 0.058, 0.033, 15, True),   # fingers
    (0.890, 1.381, 0.056, 0.031, 32, True),
    (0.905, 1.368, 0.050, 0.026, 52, True),   # tips
]
HAND_ANG = [-150, -120, -90, -60, -30, 0, 30, 60, 90, 120, 150, 180]  # ascending; 60/120 are grooves
GROOVE = 0.84

# Leg rings (right leg; the left is mirrored): z, centre x, centre y, half width, half depth front, back
LEG = [
    (0.765, -0.099, 0.005, 0.083, 0.088, 0.095),   # 1 top of the thigh
    (0.665, -0.102, 0.002, 0.076, 0.081, 0.086),   # 3 thigh pocket from here...
    (0.585, -0.105, 0.000, 0.070, 0.074, 0.076),   # 4 ...to here
    (0.545, -0.107, -0.004, 0.067, 0.070, 0.069),  # 5 knee loops (five), gathered above
    (0.520, -0.108, -0.007, 0.064, 0.073, 0.065),  # 6
    (0.495, -0.108, -0.010, 0.065, 0.081, 0.064),  # 7 kneecap
    (0.470, -0.109, -0.007, 0.063, 0.072, 0.068),  # 8 behind the knee
    (0.445, -0.110, -0.004, 0.062, 0.066, 0.066),  # 9
    (0.340, -0.113, 0.005, 0.062, 0.062, 0.073),   # 10 calf
    (0.148, -0.118, 0.006, 0.071, 0.072, 0.075),   # 12 hem, over the boot top
    (0.146, -0.118, 0.008, 0.057, 0.059, 0.062),   # 13 boot shaft (boot from here), ankle loops
    (0.112, -0.118, 0.006, 0.056, 0.060, 0.062),   # 14
    (0.068, -0.119, 0.010, 0.062, 0.066, 0.070),   # 15
    (0.000, -0.119, 0.012, 0.064, 0.070, 0.074),   # 16 sole
]
LEG_STEP = 11
LEG_POCKET = 2
LEG_WOBBLE = {2, 3, 4, 9}
LEG_ANG = [-135, -90, -45, 0, 45, 90, 135, 180]  # (x = cos, y = sin) for the right leg
TOE = [dict(y=-0.140, ztop=0.066, sx=1.07), dict(y=-0.203, ztop=0.044, sx=0.86, back=0.016)]

# Joint positions (left side; mirrored). "head" is the origin of the headwear files and roughly where
# Mixamo puts its Head joint (base of the skull); the render script's test rig uses all of them.
JOINTS = dict(hips=(0, 0.0, 0.93), spine=(0, 0.0, 1.10), chest=(0, 0.0, 1.30), neck=(0, 0.004, 1.475),
              head=(0, 0.005, 1.548), head_end=(0, 0.005, 1.76),
              clavicle=(0.035, 0.0, 1.43), shoulder=(0.185, 0.0, 1.400), elbow=(0.472, 0.004, 1.398),
              wrist=(0.755, 0.0, 1.397), hand_end=(0.91, 0.0, 1.368),
              hip=(0.098, 0.0, 0.86), knee=(0.108, -0.004, 0.495), ankle=(0.118, 0.010, 0.095),
              toe=(0.118, -0.170, 0.025))

# Skin tones: only neck, ears and scalp change (the face is the player's drawing on the screen)
SKIN_TONES = [
    dict(skin=(0.80, 0.62, 0.50), stubble=(0.30, 0.24, 0.20)),
    dict(skin=(0.50, 0.34, 0.25), stubble=(0.12, 0.09, 0.08)),
    dict(skin=(0.88, 0.72, 0.62), stubble=(0.60, 0.40, 0.27)),
    dict(skin=(0.68, 0.52, 0.40), stubble=(0.50, 0.48, 0.45)),
]

# texture tags (per face)
TAGS = ["", "mask", "bezel", "lip", "strap", "cable", "pocket", "belt", "scalp", "gasket", "bolt", "patchedge"]
TG = {n: i for i, n in enumerate(TAGS)}


# ============================ MESH ============================
class Mesh:
    def __init__(self):
        self.co, self.faces, self.mat, self.tag = [], [], [], []

    def v(self, p):
        self.co.append(Vector(p))
        return len(self.co) - 1

    def f(self, ids, mat, tag=""):
        self.faces.append(list(ids))
        self.mat.append(mat)
        self.tag.append(tag)
        return len(self.faces) - 1

    def extrude(self, fids, newpos, wall_tag=None, wall_mat=None, idx=False):
        """Extrude a region of faces: duplicate its vertices (placed by newpos(old_co)), move the
        region onto them and wall the boundary. Returns {frozenset(old edge): wall face id}."""
        verts = sorted({v for i in fids for v in self.faces[i]})
        nv = {v: self.v(newpos(self.co[v].copy(), v) if idx else newpos(self.co[v].copy())) for v in verts}
        count = {}
        for i in fids:
            fc = self.faces[i]
            for a, b in zip(fc, fc[1:] + fc[:1]):
                k = frozenset((a, b))
                count[k] = count.get(k, 0) + 1
        walls = {}
        for i in fids:
            fc = self.faces[i]
            for a, b in zip(fc, fc[1:] + fc[:1]):
                if count[frozenset((a, b))] == 1:
                    walls[frozenset((a, b))] = self.f([a, b, nv[b], nv[a]],
                                                      self.mat[i] if wall_mat is None else wall_mat,
                                                      self.tag[i] if wall_tag is None else wall_tag)
        for i in fids:
            self.faces[i] = [nv[v] for v in self.faces[i]]
        return walls, nv


def mx(p):
    return (-p[0], p[1], p[2])


def sup(c, s, p=2.4):
    """superellipse radius factor: corners a little squarer than a circle"""
    return 1.0 / (abs(c) ** p + abs(s) ** p) ** (1.0 / p)


def head_pt(a_deg, row, extra=0.0, ears=True):
    name, rx, ryf, ryb, cy, zf, zb = row
    if name[0] == "H":
        rx, ryf, ryb = rx * HS, ryf * HS, ryb * HS
        zf, zb = HZ0 + (zf - HZ0) * HS, HZ0 + (zb - HZ0) * HS
    c, s = math.cos(math.radians(a_deg)), math.sin(math.radians(a_deg))
    k = sup(c, s)
    ry = ryf if s < 0 else ryb
    x, y = (rx + extra) * c * k, cy + (ry + extra) * s * k
    z = zb + (zf - zb) * (1 - s) / 2
    if ears and name == "H4" and abs(s) < 0.01:
        x += EAR * (1 if c > 0 else -1)
    return (x, y, z)


def torso_row(z, grow):
    """interpolate the key rows at height z, then push the row out by `grow`"""
    for k0, k1 in zip(KEYS, KEYS[1:]):
        if k0[0] <= z <= k1[0]:
            t = (z - k0[0]) / (k1[0] - k0[0])
            break
    lerp2 = lambda a, b: (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    fr = [lerp2(a, b) for a, b in zip(k0[1], k1[1])]
    bk = [lerp2(a, b) for a, b in zip(k0[2], k1[2])]
    midy = None if (k1[3] is None and t > 0.999) else 0.0

    def push(p):
        d = Vector((p[0], p[1] * 1.6)).normalized()
        return (p[0] + d.x * grow, p[1] + d.y * grow)
    return [push(p) for p in fr], [push(p) for p in bk], midy


def bridge(m, A, aa, B, bb, mat, tag=""):
    """join two closed rings with different vertex counts (angles ascending in both) by triangles"""
    n, k = len(A), len(B)

    def ang(lst, i):
        return lst[i % len(lst)] + 360 * (i // len(lst))
    i = j = 0
    while i < n or j < k:
        na = ang(aa, i + 1) if i < n else 1e9
        nb = ang(bb, j + 1) if j < k else 1e9
        if na <= nb:
            m.f([A[i % n], A[(i + 1) % n], B[j % k]], mat, tag)
            i += 1
        else:
            m.f([A[i % n], B[(j + 1) % k], B[j % k]], mat, tag)
            j += 1


def ring_wobble(a_deg, i):
    """a small, mirror-symmetric unevenness for baggy cloth (a function of the angle and ring)"""
    a = math.radians(a_deg)
    return 1.0 + 0.035 * math.sin(3 * a + i * 1.7) * math.cos(a + i)


def build():
    m = Mesh()
    zs = [z for z, _ in TORSO_Z]
    ri = {round(z, 4): i for i, z in enumerate(zs)}
    rA = ri[1.34]

    # ---- torso rings: j 0..5 front x0..x5, 6 (x5, mid), 7..12 back x5..x0, 13 (x0, mid)
    T = []
    for z, grow in TORSO_Z:
        fr, bk, midy = torso_row(z, grow)
        ring = [None] * 14
        front = fr + [(-x, y) for x, y in reversed(fr)]
        back = bk + [(-x, y) for x, y in reversed(bk)]
        for i, (x, y) in enumerate(front):
            ring[i] = m.v((x, y, z))
        for i, (x, y) in enumerate(back):
            ring[12 - i] = m.v((x, y, z))
        if midy is not None:
            xs = fr[0][0] - (0.004 if z < 1.34 else 0.0)
            ring[13] = m.v((xs, midy, z))
            ring[6] = m.v((-xs, midy, z))
        T.append(ring)
    N0 = HEADR[0]
    ring = [None] * 14
    sh = SHOULDER
    ring[0] = m.v((sh["x"], -sh["y"], sh["z"]))
    ring[12] = m.v((sh["x"], sh["y"], sh["z"]))
    ring[13] = m.v((sh["x"], 0.0, sh["zmid"]))
    ring[5] = m.v(mx((sh["x"], -sh["y"], sh["z"])))
    ring[7] = m.v(mx((sh["x"], sh["y"], sh["z"])))
    ring[6] = m.v(mx((sh["x"], 0.0, sh["zmid"])))
    neck_j = {-144: 1, -108: 2, -72: 3, -36: 4, 36: 8, 72: 9, 108: 10, 144: 11}
    neck0 = []
    for a in A10:
        if a in neck_j:
            ring[neck_j[a]] = m.v(head_pt(a, N0))
            neck0.append(ring[neck_j[a]])
        else:
            neck0.append(m.v(head_pt(a, N0)))
    Q4, Q1 = neck0[4], neck0[9]
    T.append(ring)
    nrow = len(T)

    tband = {}
    for r in range(nrow - 1):
        for j in range(14):
            j2 = (j + 1) % 14
            if r >= rA and j in (12, 13, 5, 6):
                continue
            mat, tag = SUIT, ""
            if r in (ri[1.24], ri[1.29]) and j == 2:
                mat = PATCH
            if r in (ri[1.18], ri[1.24], ri[1.29]) and j in (8, 9, 10):
                mat = PATCH
            if ri[1.006] <= r < ri[1.054]:
                tag = "belt"
            tband[(r, j)] = m.f([T[r][j], T[r][j2], T[r + 1][j2], T[r + 1][j]], mat, tag)
    t = T[-1]
    m.f([t[0], t[1], Q1, t[13]], SUIT)
    m.f([t[13], Q1, t[11], t[12]], SUIT)
    m.f([t[5], t[4], Q4, t[6]], SUIT)
    m.f([t[6], Q4, t[8], t[7]], SUIT)
    B2 = m.v(CROTCH)
    B3 = m.v(mx(CROTCH))
    b = T[0]
    m.f([b[2], b[3], B3, B2], SUIT)
    m.f([B2, B3, b[9], b[10]], SUIT)
    # number patches: raised a few millimetres, like sewn-on labels (still flat on top)
    for fids, dy in (([tband[(r, 2)] for r in (ri[1.24], ri[1.29])], -0.003),
                     ([tband[(r, j)] for r in (ri[1.18], ri[1.24], ri[1.29]) for j in (8, 9, 10)], 0.003)):
        m.extrude(fids, lambda p, dy=dy: Vector((p.x, p.y + dy, p.z)), wall_tag="patchedge", wall_mat=SUIT)
    # chest pockets: shallow raised panels below and beside the chest patch (never sharing its edges)
    for j in (1, 3):
        fids = [tband[(ri[1.18], j)]]
        for i in fids:
            m.tag[i] = "pocket"
        ctr = sum((m.co[v] for i in fids for v in m.faces[i]), Vector()) / 4

        def pk(p, ctr=ctr):
            q = ctr + (p - ctr) * 0.94
            return Vector((q.x, q.y - 0.005, q.z))
        m.extrude(fids, pk, wall_tag="pocket")

    # ---- arms
    for side in (1, -1):
        if side > 0:
            r0 = [T[rA][5], T[rA + 1][5], T[-1][5], T[-1][6], T[-1][7], T[rA + 1][7], T[rA][7], T[rA][6]]
        else:
            r0 = [T[rA][0], T[rA + 1][0], T[-1][0], T[-1][13], T[-1][12], T[rA + 1][12], T[rA][12], T[rA][13]]
        rings = [r0]
        for n, (x, cz, ry, rzu, rzd) in enumerate(ARM, start=1):
            rr = []
            for a in ARM_ANG:
                c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
                k = sup(c, s, 2.2) * (ring_wobble(a, n) if n in WOBBLE else 1.0)
                yy = ry * c * k
                zz = (rzu if s > 0 else rzd) * s * k
                if n == ELBOW and c > 0:   # the point of the elbow
                    yy += 0.010 * c
                rr.append(m.v((side * x, yy, cz + zz)))
            rings.append(rr)
        for i in range(len(rings) - 1):
            for k in range(8):
                k2 = (k + 1) % 8
                m.f([rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]], SUIT if i < ARM_STEP else SKIN)
        # the gloved hand: 12-sided rings, grooves between three fingers on the back and the palm
        hrings = []
        for (x, cz, ry, rz, curl, groove) in HAND:
            tl = math.radians(curl)
            rr = []
            for a in HAND_ANG:
                c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
                k = sup(c, s, 2.6) * (GROOVE if groove and abs(abs(a) - 90) == 30 else 1.0)
                yy, zz = ry * c * k, rz * s * k
                rr.append(m.v((side * (x + zz * math.sin(tl)), yy, cz + zz * math.cos(tl))))
            hrings.append(rr)
        order = sorted(range(8), key=lambda q: ARM_ANG[q])
        bridge(m, [rings[-1][q] for q in order], sorted(ARM_ANG), hrings[0], HAND_ANG, SKIN)
        hband = {}
        for i in range(len(hrings) - 1):
            for k in range(12):
                k2 = (k + 1) % 12
                hband[(i, k)] = m.f([hrings[i][k], hrings[i][k2], hrings[i + 1][k2], hrings[i + 1][k]], SKIN)
        x, cz, _, _, curl, _ = HAND[-1]
        tl = math.radians(curl)
        C = m.v((side * (x + 0.010 * math.cos(tl)), 0.0, cz - 0.010 * math.sin(tl)))
        for k in range(12):
            m.f([hrings[-1][k], hrings[-1][(k + 1) % 12], C], SKIN)
        # thumb: out of the front of the wrist-to-palm band (faces 150-180 and 180-210 degrees)
        fids = [hband[(0, 10)], hband[(0, 11)]]
        for sc, off in ((0.78, (0.018, -0.030, -0.008)), (0.74, (0.026, -0.018, -0.008))):
            ctr = sum((m.co[v] for i in fids for v in m.faces[i]), Vector()) / 8

            def th(p, ctr=ctr, sc=sc, off=off, side=side):
                return ctr + (p - ctr) * sc + Vector((side * off[0], off[1], off[2]))
            m.extrude(fids, th)

    # ---- legs
    for side in (-1, 1):
        if side < 0:
            r0 = [T[0][0], T[0][1], T[0][2], B2, T[0][10], T[0][11], T[0][12], T[0][13]]
        else:
            r0 = [T[0][5], T[0][4], T[0][3], B3, T[0][9], T[0][8], T[0][7], T[0][6]]
        rings = [r0]
        for n, (z, cx, cy, rx, ryf, ryb) in enumerate(LEG, start=1):
            rr = []
            for a in LEG_ANG:
                c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
                k = sup(c, s, 2.3) * (ring_wobble(a, n) if n in LEG_WOBBLE else 1.0)
                ry = ryf if s < 0 else ryb
                p = (cx + rx * c * k, cy + ry * s * k, z)
                rr.append(m.v(p if side < 0 else mx(p)))
            rings.append(rr)
        band = {}
        for i in range(len(rings) - 1):
            for k in range(8):
                k2 = (k + 1) % 8
                band[(i, k)] = m.f([rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]],
                                   SUIT if i < LEG_STEP else SKIN)
        last = LEG[-1]
        lcx = side * -last[1]
        C = m.v((lcx, last[2], 0.0))
        cap(m, rings[-1], C, SKIN)
        fids = [band[(len(LEG) - 1, 0)], band[(len(LEG) - 1, 1)]]
        for st in TOE:
            def tp(p, st=st, lcx=lcx):
                top = p.z > 0.02
                dx = (p.x - lcx) * st["sx"]
                y = st["y"] + (st.get("back", 0.0) * min(1.0, abs(dx) / 0.05))
                return Vector((lcx + dx, y, st["ztop"] if top else 0.0))
            m.extrude(fids, tp)
        # thigh pocket on the outside of each leg
        fids = [band[(LEG_POCKET, 6)], band[(LEG_POCKET, 7)]]
        for i in fids:
            m.tag[i] = "pocket"
        ctr = sum((m.co[v] for i in fids for v in m.faces[i]), Vector()) / 8
        lc = Vector((side * -LEG[LEG_POCKET][1], 0.0, 0.0))

        def tpk(p, ctr=ctr, lc=lc):
            q = ctr + (p - ctr) * 0.92
            out = Vector((q.x - lc.x, q.y, 0)).normalized()
            return q + out * 0.007
        m.extrude(fids, tpk, wall_tag="pocket")

    # ---- neck and head
    nrings = [neck0] + [[m.v(head_pt(a, row)) for a in A10] for row in HEADR[1:4]]
    for i in range(len(nrings) - 1):
        for k in range(10):
            k2 = (k + 1) % 10
            m.f([nrings[i][k], nrings[i][k2], nrings[i + 1][k2], nrings[i + 1][k]], SUIT if i < 2 else SKIN)
    hrows = [r for r in HEADR if r[0][0] == "H"]
    H = [[m.v(head_pt(a, row)) for a in A12] for row in hrows]
    bridge(m, nrings[-1], A10, H[0], A12, SKIN)
    hb = {}
    for i in range(len(H) - 1):
        for k in range(12):
            k2 = (k + 1) % 12
            hb[(i, k)] = m.f([H[i][k], H[i][k2], H[i + 1][k2], H[i + 1][k]], SKIN, "scalp" if i >= 3 else "")
    R = H[-1]
    M1 = m.v((0, -0.022 * HS, HEAD_TOP_Z))
    M2 = m.v((0, 0.028 * HS, HEAD_TOP_Z))
    crown = []
    for q in ([R[2], R[3], R[4], M1], [M1, R[4], R[5], M2], [M2, R[5], R[6], R[7]], [M2, R[7], R[8]],
              [R[2], R[1], R[0], M1], [M1, R[0], R[11], M2], [M2, R[11], R[10], R[9]], [M2, R[9], R[8]]):
        crown.append(m.f(q, SKIN, "scalp"))

    # the mask housing
    M = MASK
    fids = [hb[(i, k)] for i in range(4) for k in range(4)]
    cr = {H[i][k]: (k, i) for i in range(5) for k in range(5)}
    HC = Vector((0, 0.0, 1.64))
    for i in fids:
        m.tag[i] = "mask"

    def follow(nv):
        return {nv[v]: cr[v] for v in cr if v in nv}
    _, nv = m.extrude(fids, lambda p: p + (p - HC).normalized() * M["gasket"], wall_tag="gasket")
    cr = follow(nv)

    def rim(p, v):
        c, r = cr[v]
        x = -M["W"] + 2 * M["W"] * c / 4
        z = M["z0"] + (M["z1"] - M["z0"]) * r / 4
        y = M["rim_y"] if c in (0, 4) else min(p.y, -0.06)
        return Vector((x, y, z))
    _, nv = m.extrude(fids, rim, wall_tag="mask", idx=True)
    cr = follow(nv)
    zc = (M["z0"] + M["z1"]) / 2
    walls, nv = m.extrude(fids, lambda p: Vector((p.x * M["taper"], M["front"], zc + (p.z - zc) * M["taper"])), wall_tag="mask")
    m.extrude(fids, lambda p: Vector((p.x * M["bezel"][0], p.y, zc + (p.z - zc) * M["bezel"][1])), wall_tag="bezel")
    m.extrude(fids, lambda p: Vector((p.x * 0.985, p.y + M["recess"], zc + (p.z - zc) * 0.985)), wall_tag="lip")
    for i in fids:
        m.mat[i] = SCREEN
        m.tag[i] = ""

    def centre(i):
        return sum((m.co[v] for v in m.faces[i]), Vector()) / len(m.faces[i])
    wl = list(walls.values())
    # bolts: a boss on each side of the housing, high and to the back, where the harness meets it
    for sgn in (1, -1):
        side_walls = [i for i in wl if centre(i).x * sgn > M["W"] * 0.9]
        b = max(side_walls, key=lambda i: centre(i).z)
        cb = centre(b)
        m.tag[b] = "bolt"
        m.extrude([b], lambda p, cb=cb, sgn=sgn: cb + (p - cb) * 0.45 + Vector((sgn * M["bolt"], 0, 0)), wall_tag="bolt")
    # the cable: from the middle of the housing's underside to the collar
    under = [i for i in wl if centre(i).z < M["z0"] + 0.02 and abs(centre(i).x) < M["W"] / 2]
    q0 = [m.co[v].copy() for i in under for v in m.faces[i]]
    for i in under:
        m.tag[i] = "cable"
    for (cy, cz, hw, hd) in CABLE:
        ym = sum(q.y for q in q0) / len(q0)

        def cb(p, cy=cy, cz=cz, hw=hw, hd=hd, ym=ym):
            x = 0.0 if abs(p.x) < 1e-6 else math.copysign(hw, p.x)
            return Vector((x, cy + math.copysign(hd, p.y - ym), cz))
        _, nv = m.extrude(under, cb, wall_tag="cable", wall_mat=SKIN)
        q0 = [m.co[v].copy() for i in under for v in m.faces[i]]

    # the harness: a band round the back of the skull and one over the crown, ear to ear, both
    # meeting the housing's sides at the bolts
    hz = [hb[(4, k)] for k in range(5, 11)] + [hb[(5, k)] for k in (4, 5, 10, 11)] + [crown[1], crown[5]]
    for i in hz:
        m.tag[i] = "strap"
    m.extrude(hz, lambda p: p + (p - HC).normalized() * M["strap"], wall_tag="strap")
    return m


def cap(m, ring, C, mat):
    """close an 8-vertex ring (outline of a 3 x 3 grid, starting at a corner) with four quads"""
    r = ring
    for q in ([r[0], r[1], C, r[7]], [r[1], r[2], r[3], C], [C, r[3], r[4], r[5]], [r[7], C, r[5], r[6]]):
        m.f(q, mat)


# ============================ OBJECT, UVS ============================
def make_object(m, name="Convict"):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(c) for c in m.co], [], m.faces)
    me.update()
    for poly, mt in zip(me.polygons, m.mat):
        poly.material_index = mt
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    bm = bmesh.new()
    bm.from_mesh(me)
    loose = [v for v in bm.verts if not v.link_faces]  # inner points an extrusion moved away from
    bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.update()
    print(f"[build] removed {len(loose)} loose vertices")
    vol = sum(p.center.dot(p.normal) * p.area for p in me.polygons) / 3.0
    if vol < 0:
        me.flip_normals()
    for p in me.polygons:
        p.use_smooth = True
    bm = bmesh.new()
    bm.from_mesh(me)
    sharp = [False] * len(bm.edges)
    for e in bm.edges:
        if len(e.link_faces) == 2:
            a = e.link_faces[0].normal.angle(e.link_faces[1].normal, 0.0)
            sharp[e.index] = math.degrees(a) > P["sharp_deg"]
    bm.free()
    attr = me.attributes.get("sharp_edge") or me.attributes.new("sharp_edge", "BOOLEAN", "EDGE")
    attr.data.foreach_set("value", sharp)
    return ob


def flat_uv(me, group, mirror, label):
    """0..1 across a flat rectangle, upright and readable from outside"""
    uvl = me.uv_layers[0]
    vs = [me.vertices[v].co for p in group for v in p.vertices]
    x0, x1 = min(v.x for v in vs), max(v.x for v in vs)
    z0, z1 = min(v.z for v in vs), max(v.z for v in vs)
    for p in group:
        for li in p.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            u = (co.x - x0) / (x1 - x0)
            uvl.data[li].uv = (1 - u if mirror else u, (co.z - z0) / (z1 - z0))
    flat = max(abs(v.y - vs[0].y) for v in vs) * 1000
    print(f"[build] {label}: {(x1 - x0) * 100:.1f} x {(z1 - z0) * 100:.1f} cm, {len(group)} faces, flat to {flat:.2f} mm")


def unwrap(ob):
    me = ob.data
    me.uv_layers.new(name="UVMap")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    for mn in P["mats"]:
        ob.data.materials.append(bpy.data.materials.new(mn))
    bpy.ops.object.mode_set(mode="EDIT")
    for slot, margin in ((0, 0.012), (1, 0.02)):
        bpy.ops.mesh.select_all(action="DESELECT")
        ob.active_material_index = slot
        bpy.ops.object.material_slot_select()
        bpy.ops.mesh.hide(unselected=True)  # the packer works on everything visible, not the selection
        bpy.ops.uv.smart_project(angle_limit=math.radians(56.0), island_margin=margin, area_weight=0.0,
                                 correct_aspect=True, scale_to_bounds=False)
        bpy.ops.uv.select_all(action="SELECT")
        bpy.ops.uv.pack_islands(rotate=True, margin=margin, shape_method="CONCAVE")
        bpy.ops.mesh.reveal(select=False)
    bpy.ops.mesh.select_all(action="DESELECT")
    bpy.ops.object.mode_set(mode="OBJECT")
    flat_uv(me, [p for p in me.polygons if p.material_index == PATCH and p.normal.y < 0], False, "number patch chest")
    flat_uv(me, [p for p in me.polygons if p.material_index == PATCH and p.normal.y > 0], True, "number patch back")
    flat_uv(me, [p for p in me.polygons if p.material_index == SCREEN], False, "face screen")


# ============================ TEXTURES ============================
_TAB = np.random.default_rng(11).random(4096)


def vnoise(Pt, freq, seed=0):
    Q = Pt * freq + seed * 17.13
    i = np.floor(Q).astype(np.int64)
    f = Q - i
    f = f * f * (3 - 2 * f)

    def h(dx, dy, dz):
        a = (i[:, 0] + dx) * 73856093 ^ (i[:, 1] + dy) * 19349663 ^ (i[:, 2] + dz) * 83492791
        return _TAB[a & 4095]
    out = 0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                out = out + w * h(dx, dy, dz)
    return out


def g(x, s):
    return np.exp(-(x / s) ** 2)


def band(x, a, b, soft=0.004):
    return np.clip((x - a) / soft + 0.5, 0, 1) * np.clip((b - x) / soft + 0.5, 0, 1)


def crease(phase, sharp=0.55):
    """dark lines: 0..1 where sin(phase) is near its top"""
    return np.clip((np.sin(phase) - sharp) / (1 - sharp), 0, 1)


def suit_colour(Pt, N, T):
    x, y, z = Pt[:, 0], Pt[:, 1], Pt[:, 2]
    ax = np.abs(x)
    arm = (ax > 0.185) & (z > 1.30)
    leg = (z < 0.80) & ~arm
    torso = ~arm & ~leg
    front = N[:, 1] < -0.25
    backf = N[:, 1] > 0.25
    sh = np.ones(len(x))
    sh *= 1 - 0.06 * vnoise(Pt, 7.0, 1) - 0.03 * vnoise(Pt, 23.0, 2)
    # wear: dirt rises from the floor; knees, seat, elbows, cuffs and hem are worst (neutral grey,
    # so a tint multiplied over it stays its own colour)
    rise = np.clip((0.62 - z) / 0.45, 0, 1)
    blot = 0.5 + 0.5 * vnoise(Pt, 11.0, 3)
    sh *= 1 - 0.28 * rise * blot
    knee = g(z - 0.50, 0.055) * leg * np.clip(-N[:, 1] + 0.2, 0, 1)
    sh *= 1 - 0.30 * knee * (0.5 + 0.5 * vnoise(Pt, 30.0, 4))
    seat = band(z, 0.78, 0.98, 0.05) * backf * g(ax - 0.09, 0.07)
    sh *= 1 - 0.22 * seat * blot
    elbow = arm * g(ax - 0.47, 0.04) * np.clip(N[:, 1] + 0.2, 0, 1)
    sh *= 1 - 0.22 * elbow * blot
    hem = leg * band(z, 0.14, 0.215, 0.02)
    sh *= 1 - 0.25 * hem * (0.6 + 0.4 * vnoise(Pt, 40.0, 5))
    cuff = arm * band(ax, 0.68, 0.73, 0.01)
    sh *= 1 - 0.18 * cuff
    # folds: a few broad, soft ones (shaded gradients, not lines): inside of the elbow, above the
    # cuffs and the boots, behind the knees, from the crotch, pulls to the armpits
    def soft(ph):
        return (0.5 + 0.5 * np.sin(ph)) ** 2
    ang = np.arctan2(y, x)
    s = ax
    sh *= 1 - 0.18 * arm * g(s - 0.46, 0.05) * soft(s * 55 + z * 25) * np.clip(-N[:, 1] + 0.3, 0, 1)
    sh *= 1 - 0.15 * arm * band(s, 0.60, 0.665, 0.03) * soft(s * 95)
    sh *= 1 - 0.10 * arm * band(s, 0.22, 0.40, 0.05) * soft(s * 32 + z * 40)
    sh *= 1 - 0.18 * leg * band(z, 0.15, 0.33, 0.03) * soft(z * 80 + np.sin(np.arctan2(y, ax - 0.11) * 2) * 1.2)
    sh *= 1 - 0.18 * leg * g(z - 0.48, 0.045) * (N[:, 1] > 0.2) * soft(z * 115)
    sh *= 1 - 0.14 * leg * band(z, 0.64, 0.80, 0.05) * front * g(ax - 0.06, 0.05) * soft((z - ax * 1.4) * 45)
    pull = torso * band(z, 1.10, 1.33, 0.05) * band(ax, 0.09, 0.18, 0.03)
    sh *= 1 - 0.13 * pull * soft((z + ax * 1.1) * 42)
    sh *= 1 - 0.10 * torso * backf * band(z, 0.90, 1.00, 0.04) * soft(ang * 8)
    sh *= 1 - 0.25 * torso * backf * g(z - 1.39, 0.004)
    # the belt: darker band, stitched edges, a buckle; the cloth bloused over it is shaded beneath
    belt = T == TG["belt"]
    sh *= np.where(belt, 0.80, 1.0)
    sh *= np.where(belt & ((np.abs(z - 1.010) < 0.003) | (np.abs(z - 1.050) < 0.003)), 0.75, 1.0)
    buckle = belt & front & (ax < 0.030)
    sh *= np.where(buckle, 1.25, 1.0)
    sh *= np.where(buckle & ((ax > 0.024) | (np.abs(z - 1.030) > 0.019)), 0.65, 1.0)
    sh *= 1 - 0.35 * torso * band(z, 1.055, 1.064, 0.002) * ~belt
    # seams: shoulders, legs, cuff edges, collar
    sh *= 1 - 0.30 * g(ax - 0.19, 0.004) * (z > 1.30)
    sh *= 1 - 0.20 * leg * g(np.abs(np.arctan2(y, ax - 0.11)), 0.06)
    for e in (0.690, 0.724):
        sh *= 1 - 0.35 * arm * g(s - e, 0.004)
    sh *= 1 + 0.06 * arm * band(s, 0.695, 0.72, 0.01)
    sh *= 1 - 0.40 * leg * g(z - 0.150, 0.004)
    collar = z > 1.466
    sh *= np.where(collar & (N[:, 2] > 0.5), 0.88, 1.0)
    sh *= 1 - 0.30 * torso * g(z - 1.465, 0.010) * ~collar
    # zip down the front (not across the belt)
    zip_ = torso & (y < -0.04) & (z < 1.47) & (z > 0.80) & ~belt
    sh *= np.where(zip_ & (ax < 0.0095), 0.58, 1.0)
    sh *= np.where(zip_ & (ax < 0.0030), 1.35, 1.0)
    # number patches: a raised edge and a stitched border round each (the game draws inside)
    sh *= np.where(T == TG["patchedge"], 0.62, 1.0)
    dash = np.sin((x + z) * 2 * math.pi / 0.009) > 0
    fb = torso & (y < -0.10) & (ax < 0.089) & band(z, 1.231, 1.299, 0.002).astype(bool) & ~((ax < 0.081) & (z > 1.239) & (z < 1.291))
    bb = torso & (y > 0.08) & (ax < 0.139) & band(z, 1.171, 1.299, 0.002).astype(bool) & ~((ax < 0.131) & (z > 1.179) & (z < 1.291))
    sh *= np.where((fb | bb) & dash, 0.62, np.where(fb | bb, 0.88, 1.0))
    # pockets: flap, stitched edges, the opening in shadow
    pk = T == TG["pocket"]
    sh *= np.where(pk, 0.93, 1.0)
    flap_chest = pk & torso & (np.abs(z - 1.225) < 0.005)
    flap_leg = pk & leg & (np.abs(z - 0.648) < 0.006)
    sh *= np.where(flap_chest | flap_leg, 0.62, 1.0)
    # painted shadow in the crevices: armpits, crotch, inner thighs
    for cx, cz, sx, sz, k in ((0.172, 1.34, 0.03, 0.05, 0.40), (0.0, 0.79, 0.05, 0.06, 0.40)):
        d = ((ax - cx) / sx) ** 2 + ((z - cz) / sz) ** 2
        sh *= 1 - k * np.exp(-d)
    sh *= 1 - 0.22 * leg * g(ax - 0.035, 0.025) * band(z, 0.40, 0.80, 0.08)
    sh *= 1 + 0.012 * (vnoise(Pt, 80.0, 9) - 0.5)
    base = np.array([0.885, 0.875, 0.850])
    col = base[None, :] * sh[:, None]
    col = col * (1 - 0.04 * rise[:, None] * np.array([0.0, 0.3, 1.0])[None, :])  # a hint of warm dirt
    return np.clip(col, 0.32, 1.0)


def skin_colour(Pt, N, T, tone):
    """skin of neck, ears and shaved scalp (the only parts that change with `tone`), work gloves,
    boots, and the mask body, bezel, straps and cable"""
    x, y, z = Pt[:, 0], Pt[:, 1], Pt[:, 2]
    ax = np.abs(x)
    boot = z < 0.15
    hand = ax > 0.70
    skin = np.array(tone["skin"])
    col = np.tile(skin, (len(x), 1))
    # neck: shade under the mask and at the collar
    col = np.where(((z < 1.55) & ~boot & ~hand)[:, None], col * 0.86, col)
    ear = (ax > 0.080) & (z > 1.635) & (z < 1.68) & (np.abs(y) < 0.03)
    col = np.where(ear[:, None], col * np.array([0.95, 0.85, 0.82]), col)
    scalp = (T == TG["scalp"]) | ((z > 1.70) & ~hand & ~boot)
    stub = np.array(tone["stubble"])
    col = np.where(scalp[:, None], col * 0.55 + stub[None, :] * 0.45, col)
    # mask housing: dark institutional plastic, a lighter case seam, a vent on top, a soft black gasket,
    # a chunky bezel with an LED and a label, metal bolts, a rigid harness and a ribbed cable
    mask = T == TG["mask"]
    plastic = np.array([0.205, 0.21, 0.20])
    mc = np.tile(plastic, (len(x), 1))
    mc = np.where((N[:, 2] > 0.5)[:, None], mc * 1.15, mc)
    mc = np.where((np.abs(y - (MASK["front"] + 0.022)) < 0.003)[:, None], mc * 1.45, mc)
    vent = (N[:, 2] > 0.5) & (np.abs(np.sin(x * 2 * math.pi / 0.014)) > 0.7) & (ax < 0.06) & (y < -0.07)
    mc = np.where(vent[:, None], mc * 0.55, mc)
    sidevent = (np.abs(N[:, 0]) > 0.6) & (np.abs(np.sin(z * 2 * math.pi / 0.012)) > 0.7) & (np.abs(z - 1.60) < 0.035) & (y > -0.10) & (y < -0.04)
    mc = np.where(sidevent[:, None], mc * 0.55, mc)
    col = np.where(mask[:, None], mc, col)
    col = np.where((T == TG["gasket"])[:, None], np.array([0.075, 0.075, 0.07]), col)
    bez = T == TG["bezel"]
    bc = np.tile(np.array([0.135, 0.14, 0.135]), (len(x), 1))
    led = bez & (x > 0.060) & (x < 0.074) & (np.abs(z - 1.540) < 0.006)
    bc = np.where(led[:, None], np.array([0.85, 0.20, 0.12]), bc)
    label = bez & (x < -0.040) & (x > -0.080) & (np.abs(z - 1.541) < 0.005)
    bc = np.where(label[:, None], np.array([0.55, 0.53, 0.46]), bc)
    col = np.where(bez[:, None], bc, col)
    col = np.where((T == TG["lip"])[:, None], np.array([0.07, 0.075, 0.07]), col)
    bolt = T == TG["bolt"]
    col = np.where(bolt[:, None], np.array([0.42, 0.42, 0.40]) * np.where(np.abs(N[:, 0]) > 0.8, 1.15, 0.8)[:, None], col)
    strap = T == TG["strap"]
    harness = np.array([0.22, 0.225, 0.195]) * np.where(N[:, 2] > 0.6, 1.12, 1.0)[:, None]
    col = np.where(strap[:, None], harness, col)
    cable = T == TG["cable"]
    rib = np.where(np.abs(np.sin(z * 2 * math.pi / 0.014)) > 0.5, 0.15, 0.10)
    col = np.where(cable[:, None], rib[:, None] * np.ones(3)[None, :], col)
    # gloves: dark grey work gloves, a lighter flared gauntlet with a seam at its rim, darker palm,
    # a crease over the knuckles (the finger grooves are geometry)
    gl = np.tile(np.array([0.25, 0.25, 0.24]), (len(x), 1))
    gaunt = ax < 0.746
    gl = np.where(gaunt[:, None], np.array([0.31, 0.30, 0.28]), gl)
    gl = np.where((gaunt & (ax > 0.736))[:, None], gl * 0.65, gl)
    gl = np.where((N[:, 2] < -0.5)[:, None] & ~gaunt[:, None], np.array([0.19, 0.18, 0.17]), gl)
    gl = np.where(((np.abs(ax - 0.842) < 0.004) & (N[:, 2] > 0.3))[:, None], gl * 0.6, gl)
    col = np.where(hand[:, None], gl, col)
    # boots: dark leather, laces up the front, scuffed toe, a pale welt and a near-black sole
    leather = np.array([0.205, 0.175, 0.145]) * (1 + 0.06 * (vnoise(Pt, 30.0, 10) - 0.5))[:, None]
    bc = leather.copy()
    lx = np.abs(ax - 0.118)
    lace_zone = boot & (y < -0.03) & (lx < 0.022) & (z > 0.06) & (z < 0.14) & (y > -0.125)
    lace = np.abs(np.sin(z * 2 * math.pi / 0.017)) > 0.65
    bc = np.where((lace_zone & lace)[:, None], np.array([0.29, 0.26, 0.22]), bc)
    bc = np.where((lace_zone & ~lace)[:, None], bc * 0.85, bc)
    toe = boot & (y < -0.11) & (N[:, 2] > 0.2)
    bc = np.where(toe[:, None], bc * 1.22, bc)
    welt = boot & (z > 0.020) & (z < 0.032)
    bc = np.where(welt[:, None], np.array([0.30, 0.27, 0.22]), bc)
    sole = boot & (z <= 0.020)
    bc = np.where(sole[:, None], np.array([0.125, 0.12, 0.115]), bc)
    col = np.where(boot[:, None], bc, col)
    return np.clip(col, 0.06, 1.0)


def sample(ob, slot, px):
    """Rasterise every triangle of one material into UV space: where each texel sits on the body
    (position, normal) and the tag of its face."""
    me = ob.data
    me.calc_loop_triangles()
    uvl = me.uv_layers[0].data
    pos = np.zeros((px, px, 3))
    nrm = np.zeros((px, px, 3))
    tag = np.zeros((px, px), np.int32)
    hit = np.zeros((px, px), bool)
    tags = list(ob["tags"])
    for tri in me.loop_triangles:
        if tri.material_index != slot:
            continue
        uv = np.array([uvl[l].uv for l in tri.loops]) * px - 0.5
        co = np.array([me.vertices[v].co for v in tri.vertices])
        x0, y0 = np.floor(uv.min(0)).astype(int)
        x1, y1 = np.ceil(uv.max(0)).astype(int)
        x0, y0 = max(x0, 0), max(y0, 0)
        x1, y1 = min(x1, px - 1), min(y1, px - 1)
        if x1 < x0 or y1 < y0:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        a, b, c = uv
        M = np.array([[b[0] - a[0], c[0] - a[0]], [b[1] - a[1], c[1] - a[1]]])
        if abs(np.linalg.det(M)) < 1e-12:
            continue
        l1, l2 = np.linalg.inv(M) @ np.stack([gx.ravel() - a[0], gy.ravel() - a[1]])
        l0 = 1 - l1 - l2
        ins = (l0 >= -0.08) & (l1 >= -0.08) & (l2 >= -0.08)
        if not ins.any():
            continue
        w = np.clip(np.stack([l0, l1, l2], 1)[ins], 0, None)
        w /= w.sum(1, keepdims=True)
        xs, ys = gx.ravel()[ins], gy.ravel()[ins]
        pos[ys, xs] = w @ co
        nrm[ys, xs] = np.array(tri.normal)
        tag[ys, xs] = tags[tri.polygon_index]
        hit[ys, xs] = True
    print(f"[build] slot {slot}: {px}x{px}, {hit.sum()} texels on the surface ({hit.mean() * 100:.0f}%)")
    return hit, pos, nrm, tag


def shade(smp, colour_fn):
    hit, pos, nrm, tag = smp
    px = hit.shape[0]
    img = np.zeros((px, px, 3))
    idx = np.nonzero(hit)
    img[idx] = colour_fn(pos[idx], nrm[idx], tag[idx])
    hit = hit.copy()
    for _ in range(8):  # bleed into the margins so nearest filtering never shows a seam
        acc = np.zeros_like(img)
        cnt = np.zeros((px, px))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                acc += np.roll(np.roll(img * hit[..., None], dy, 0), dx, 1)
                cnt += np.roll(np.roll(hit, dy, 0), dx, 1)
        fill = ~hit & (cnt > 0)
        img[fill] = acc[fill] / cnt[fill][:, None]
        hit = hit | fill
    return img


def save_image(name, arr, path):
    h, w = arr.shape[:2]
    im = bpy.data.images.new(name, w, h, alpha=False)
    rgba = np.ones((h, w, 4), np.float32)
    rgba[..., :3] = arr
    im.pixels.foreach_set(rgba.ravel())
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    im.filepath = path
    return im


def setup_material(mat, img, colour=None):
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.9
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.15
    if img is None:
        bsdf.inputs["Base Color"].default_value = (*colour, 1)
    else:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = img
        tex.interpolation = "Closest"
        nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])


# ============================ HEADWEAR ============================
def head_column(a):
    """points of the head rings (H4 up) at angle a, then the top"""
    pts = [Vector(head_pt(a, r, ears=False)) for r in HEADR if r[0][0] == "H"]
    pts.append(Vector((0, 0.004, HEAD_TOP_Z)))
    return pts


def column_at(pts, z_edge, s):
    """point at fraction s of the way along the column from height z_edge to the top"""
    seg = []
    for p, q in zip(pts, pts[1:]):
        if q.z <= z_edge:
            continue
        if p.z < z_edge:
            p = p.lerp(q, (z_edge - p.z) / (q.z - p.z))
        seg.append((p, q))
    L = [(q - p).length for p, q in seg]
    t = s * sum(L)
    for (p, q), l in zip(seg, L):
        if t <= l:
            return p.lerp(q, t / l if l > 0 else 0.0)
        t -= l
    return seg[-1][1]


def build_headwear(kind):
    """A cap of hair or a knit watch cap, as its own small mesh round the head, clear of the straps.
    Returns (verts, faces, uvs) in Blender space."""
    n = 24
    angs = [-90 + 360 * k / n for k in range(n + 1)]   # last repeats the first (UV seam at the back)
    HC = Vector((0, 0.0, 1.62))
    if kind == "knit":
        edge = lambda f: 1.640 + (1.762 - 1.640) * f ** 1.5
        rows = [(0.0, 0.013, 0.000), (0.0, 0.024, -0.004), (0.10, 0.031, 0.0), (0.20, 0.025, 0.0),
                (0.22, 0.017, 0.0), (0.42, 0.017, 0.0), (0.64, 0.018, 0.0), (0.84, 0.019, 0.0)]
        top_off, rib_from = 0.026, 5
    else:
        edge = lambda f: 1.612 + (1.762 - 1.612) * f ** 1.3
        rows = [(0.0, 0.004, 0.0), (0.05, 0.012, 0.0), (0.30, 0.013, 0.0), (0.60, 0.013, 0.0), (0.85, 0.013, 0.0)]
        top_off, rib_from = 0.013, 99
    verts, faces, uvs = [], [], []
    grid = []
    for j, (s, off, dz) in enumerate(rows):
        row = []
        for k, a in enumerate(angs):
            f = (1 - math.sin(math.radians(a))) / 2
            p = column_at(head_column(a), edge(f), s)
            o = off + (0.003 if (j >= rib_from and k % 2) else 0.0)
            q = p + (p - HC).normalized() * o + Vector((0, 0, dz))
            row.append(len(verts))
            verts.append(q)
        grid.append(row)
    topv = len(verts)
    verts.append(Vector((0, 0.010, HEAD_TOP_Z + top_off)))
    nr = len(rows)
    for j in range(nr - 1):
        for k in range(n):
            faces.append([grid[j][k], grid[j][k + 1], grid[j + 1][k + 1], grid[j + 1][k]])
            uvs.append([(k / n, j / nr), ((k + 1) / n, j / nr), ((k + 1) / n, (j + 1) / nr), (k / n, (j + 1) / nr)])
    for k in range(n):
        faces.append([grid[-1][k], grid[-1][k + 1], topv])
        uvs.append([(k / n, (nr - 1) / nr), ((k + 1) / n, (nr - 1) / nr), ((k + 0.5) / n, 1.0)])
    return verts, faces, uvs


def headwear_texture(kind, px):
    u = (np.arange(px) + 0.5) / px
    U, V = np.meshgrid(u, u)
    if kind == "knit":
        base = np.array([0.24, 0.25, 0.21])
        rib = 1 + 0.12 * np.sign(np.sin(U * 2 * math.pi * 24))
        roll = V < 0.5
        rib = np.where(roll, 1.08 + 0.08 * np.sign(np.sin(V * 2 * math.pi * 10)), rib)
        rib = np.where(np.abs(V - 0.5) < 0.03, 0.7, rib)
        return np.clip(base[None, None, :] * rib[..., None], 0, 1)
    rng = np.random.default_rng(4)
    strands = 1 + 0.18 * (rng.random((px, px)) - 0.5)
    strands = (strands + np.roll(strands, 1, 0) + np.roll(strands, 2, 0)) / 3
    base = np.array([0.16, 0.12, 0.095])
    edge = np.where(V < 0.12, 0.85 + V, 1.0)
    return np.clip(base[None, None, :] * (strands * edge)[..., None], 0, 1)


def export_headwear(texdir):
    J = Vector(JOINTS["head"])
    out = []
    for kind in ("knit", "hair", "none"):
        bpy.ops.object.select_all(action="DESELECT")
        name = "headwear_" + kind
        path = os.path.join(HERE, name + ".glb")
        if kind == "none":
            ob = bpy.data.objects.new(name, None)   # an empty node: nothing on the shaved head
            bpy.context.scene.collection.objects.link(ob)
        else:
            vs, fs, uvs = build_headwear(kind)
            me = bpy.data.meshes.new(name)
            me.from_pydata([tuple(v - J) for v in vs], [], fs)
            uvl = me.uv_layers.new(name="UVMap")
            for poly, uv in zip(me.polygons, uvs):
                for li, (a, b) in zip(poly.loop_indices, uv):
                    uvl.data[li].uv = (a, b)
            for p in me.polygons:
                p.use_smooth = True
            ob = bpy.data.objects.new(name, me)
            bpy.context.scene.collection.objects.link(ob)
            mat = bpy.data.materials.new(name)
            mat.use_backface_culling = False
            img = save_image(name, headwear_texture(kind, P["hw_px"]), os.path.join(texdir, name + ".png"))
            setup_material(mat, img)
            me.materials.append(mat)
            bm = bmesh.new()
            bm.from_mesh(me)
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
            bm.to_mesh(me)
            bm.free()
            me.update()
            if sum((p.center + J - Vector((0, 0, 1.62))).dot(p.normal) for p in me.polygons) < 0:
                me.flip_normals()
            tris = sum(len(p.vertices) - 2 for p in me.polygons)
            print(f"[build] {name}: {len(me.vertices)} verts, {tris} tris")
        ob.select_set(True)
        bpy.context.view_layer.objects.active = ob
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
                                  export_apply=True, export_animations=False, export_skins=False)
        out.append(ob)
        print("[build] exported", os.path.relpath(path, ROOT), os.path.getsize(path), "bytes")
    return out


# ============================ CHECKS ============================
def report(ob):
    me = ob.data
    bm = bmesh.new()
    bm.from_mesh(me)
    nm = sum(1 for e in bm.edges if len(e.link_faces) != 2)
    bm.free()
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    vs = np.array([v.co for v in me.vertices])
    from mathutils.kdtree import KDTree
    kd = KDTree(len(vs))
    for i, v in enumerate(vs):
        kd.insert(v, i)
    kd.balance()
    worst = max(kd.find((-v[0], v[1], v[2]))[2] for v in vs)
    print(f"[build] verts={len(vs)} faces={len(me.polygons)} tris={tris} non-manifold edges={nm}")
    print(f"[build] size x {np.ptp(vs[:, 0]):.3f} y {np.ptp(vs[:, 1]):.3f} z {vs[:, 2].min():.3f}..{vs[:, 2].max():.3f} m;"
          f" mirror error {worst * 1000:.3f} mm")
    return tris, nm


# ============================ MAIN ============================
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--glb", default=os.path.join(HERE, "convict_tpose.glb"))
    ap.add_argument("--texdir", default=HERE)
    ap.add_argument("--no-inbox", action="store_true", help="only write the glb files")
    args = ap.parse_args(argv)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.unit_settings.system = "METRIC"
    scn.unit_settings.scale_length = 1.0
    m = build()
    ob = make_object(m)
    ob["tags"] = [TG[t] for t in m.tag]
    unwrap(ob)
    report(ob)
    os.makedirs(args.texdir, exist_ok=True)
    suit_path = os.path.join(args.texdir, "convict_suit.png")
    suit = save_image("convict_suit", shade(sample(ob, SUIT, P["suit_px"]), suit_colour), suit_path)
    smp = sample(ob, SKIN, P["skin_px"])
    skins = []
    for i, tone in enumerate(SKIN_TONES, start=1):
        path = os.path.join(args.texdir, f"convict_skin_{i}.png")
        skins.append((save_image(f"convict_skin_{i}", shade(smp, lambda p, n, t, tone=tone: skin_colour(p, n, t, tone)), path), path))
    mats = ob.data.materials
    setup_material(mats[SUIT], suit)
    setup_material(mats[SKIN], skins[0][0])
    setup_material(mats[PATCH], None, (0.62, 0.60, 0.56))   # plain until the game draws the number
    setup_material(mats[SCREEN], None, (0.05, 0.07, 0.06))  # dark glass until the game draws the face
    del ob["tags"]

    hw = export_headwear(args.texdir)
    for o in hw:
        o.hide_set(True)
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    os.makedirs(os.path.dirname(args.glb), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=args.glb, export_format="GLB", use_selection=True, export_yup=True,
                              export_apply=True, export_animations=False, export_skins=False)
    print("[build] exported", os.path.relpath(args.glb, ROOT), os.path.getsize(args.glb), "bytes")
    if args.no_inbox:
        return
    os.makedirs(INBOX, exist_ok=True)
    fbx = os.path.join(INBOX, "convict-for-mixamo.fbx")
    # Mesh only, Y up / -Z forward (Blender's -Y front becomes Mixamo's front). Unit scale applied, with the
    # axis change baked in: the file is in centimetres (UnitScaleFactor 1), the vertices stand ~176 units
    # tall and Y up (checked by render_convict.py --verify-only, which reads the file itself), and the
    # object has no rotation or scale, so a reader that ignores the unit setting and one that honours it
    # both see the same person.
    bpy.ops.export_scene.fbx(filepath=fbx, use_selection=True, object_types={"MESH"}, apply_unit_scale=True,
                             apply_scale_options="FBX_SCALE_NONE", global_scale=1.0, axis_forward="-Z", axis_up="Y",
                             bake_space_transform=True, use_mesh_modifiers=True, mesh_smooth_type="OFF",
                             add_leaf_bones=False, bake_anim=False, path_mode="COPY", embed_textures=True)
    print("[build] exported", os.path.relpath(fbx, ROOT), os.path.getsize(fbx), "bytes")
    # OBJ fallback: only inside the zip, next to the textures it names
    tmp = os.path.join(args.texdir, "_obj")
    os.makedirs(tmp, exist_ok=True)
    obj = os.path.join(tmp, "convict-for-mixamo.obj")
    bpy.ops.wm.obj_export(filepath=obj, export_selected_objects=True, export_uv=True, export_normals=True,
                          export_materials=True, path_mode="STRIP", forward_axis="NEGATIVE_Z", up_axis="Y",
                          global_scale=1.0, export_triangulated_mesh=False)
    mtl = obj[:-4] + ".mtl"
    zp = os.path.join(INBOX, "convict-for-mixamo.zip")
    with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
        for f in (obj, mtl, suit_path, skins[0][1]):
            z.write(f, os.path.basename(f))
    for f in (obj, mtl):
        os.remove(f)
    os.rmdir(tmp)
    for stale in ("convict-for-mixamo.obj", "convict-for-mixamo.mtl"):
        if os.path.exists(os.path.join(INBOX, stale)):
            os.remove(os.path.join(INBOX, stale))
    print("[build] exported", os.path.relpath(zp, ROOT), "(obj, mtl, convict_suit.png, convict_skin_1.png)")


if __name__ == "__main__":
    main()
