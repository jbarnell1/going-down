"""Build "the Temp" (the Annex's resident, docs/floors/annex.md section 4) from an empty scene: an
office worker about 1.8 m tall in a short-sleeved shirt, tie, lanyard with a badge, trousers and office
shoes, with an A4 sheet stapled over its face. A clean T-pose for Mixamo (no armature), fingers spread,
thumbs forward. The stapler (right hand) and the pad of sticky notes (left hand) are separate files, so
the game can parent them to the hands after animation.

Usage (headless, from anywhere):
  blender.exe --background --factory-startup --python-exit-code 1 --python build_temp.py -- [--out DIR]

Outputs (default: this folder):
  temp_tpose.glb       the figure, one mesh "Temp", two materials:
                         temp_body        512 px atlas (temp_body.png), nearest filtering
                         temp_face_sheet  the A4 sheet's front, 0..1 UVs, upright (the game swaps its texture
                                          for a photocopy of a crewmate's drawn face); temp_face_sheet.png is a
                                          sample photocopy made the way client/temp_view.gd makes them
  temp_stapler.glb     the stapler, origin at the grip (see STAPLER)
  temp_notes.glb       the pad of yellow sticky notes, origin at the middle of the pad (see NOTES)
  temp_body.png, temp_face_sheet.png, temp_stapler.png, temp_notes.png

Then the Mixamo upload (FBX with embedded textures plus front/side/back/top pictures):
  blender.exe --background --factory-startup --python assets_src/mixamo/mixamo_export.py --
        assets_src/blender/temp/temp_tpose.glb assets_src/mixamo/export/temp.fbx assets_src/mixamo/export/temp

How it is built: box modelling done by numbers, the Convict's scheme (build_convict.py). The torso is a
stack of 14-vertex rings (the outline of a 5 x 2 grid); each arm grows out of a 2 x 2 patch of the side
wall, each leg out of a 2 x 2 patch of the bottom (the middle column stays as the crotch), the neck out of
the middle of the top. Every ring after that is placed by a small table, so the body is one closed,
manifold surface with nothing hidden under the clothes. The hands are new: a 16-vertex palm whose
knuckle end is a row of seven quads, four of them pulled out as diamond-section fingers (two segments
each, a ring at every joint) fanned apart, the thumb pulled out of the side of the palm, forward and a
little down. Clothing that lies on the body (collar, tie, lanyard, badge, pen) and the sheet with its
staples are thin closed shells laid over it, each pushed clear of the body surface.
Blender space: metres, Z up, the figure faces -Y, +X is its left, feet on the origin.
"""
import bpy, bmesh, sys, os, math, argparse
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

# =========================== PARAMETERS ===========================
P = dict(body_px=512, prop_px=64, notes_px=128, sharp_deg=60.0)
MATS = ("temp_body", "temp_face_sheet")
BODY, SHEET = 0, 1

# Torso key rows, right half (x < 0): z, front (x, y) outer..inner, back (x, y) outer..inner, side-middle y.
# Narrow, sloping shoulders, a soft belly over the belt, a flat seat.
KEYS = [
    (0.800, [(-0.156, -0.052), (-0.094, -0.088), (-0.030, -0.082)], [(-0.156, 0.058), (-0.094, 0.100), (-0.030, 0.086)], 0.0),
    (0.900, [(-0.166, -0.060), (-0.104, -0.096), (-0.034, -0.104)], [(-0.166, 0.060), (-0.104, 0.104), (-0.034, 0.090)], 0.0),
    (0.985, [(-0.161, -0.058), (-0.104, -0.100), (-0.034, -0.112)], [(-0.158, 0.055), (-0.104, 0.082), (-0.034, 0.072)], 0.0),
    (1.060, [(-0.158, -0.058), (-0.106, -0.102), (-0.036, -0.116)], [(-0.156, 0.054), (-0.104, 0.080), (-0.036, 0.070)], 0.0),
    (1.160, [(-0.154, -0.056), (-0.106, -0.098), (-0.038, -0.109)], [(-0.154, 0.055), (-0.106, 0.086), (-0.038, 0.078)], 0.0),
    (1.250, [(-0.158, -0.056), (-0.112, -0.097), (-0.040, -0.105)], [(-0.160, 0.058), (-0.112, 0.092), (-0.040, 0.086)], 0.0),
    (1.330, [(-0.157, -0.057), (-0.113, -0.095), (-0.040, -0.101)], [(-0.158, 0.058), (-0.110, 0.090), (-0.040, 0.084)], 0.0),
    (1.385, [(-0.155, -0.057), (-0.108, -0.088), (-0.042, -0.093)], [(-0.155, 0.058), (-0.104, 0.084), (-0.042, 0.078)], None),
]
# rows actually built: z, how far the row is pushed out (the belt, the shirt bloused over it)
TORSO_Z = [(0.800, 0.0), (0.880, 0.0), (0.955, 0.0), (0.958, 0.006), (1.000, 0.006), (1.003, 0.0),
           (1.030, 0.010), (1.090, 0.004), (1.170, 0.0), (1.250, 0.0), (1.290, 0.0), (1.330, 0.0), (1.385, 0.0)]
BELT = (0.955, 1.003)
ARM_ROOT_Z = 1.330
POCKET_ROWS = (1.170, 1.250)        # the breast pocket: left chest, these two bands, front column x2..x1
SHOULDER = dict(x=-0.155, y=0.057, z=1.430, zmid=1.436)
CROTCH = (-0.030, 0.006, 0.772)

A10 = [-144, -108, -72, -36, 0, 36, 72, 108, 144, 180]   # neck ring angles (x = cos, y = sin; -90 = front)
A12 = [-162, -126, -90, -54, -18, 0, 18, 54, 90, 126, 162, 180]
# neck and head rings: rx, ry front, ry back, centre y, z front, z back. A long neck and a head a little
# small for the body (chin 1.588 to crown 1.80).
HEADR = [
    ("N0", 0.060, 0.055, 0.055, 0.000, 1.462, 1.476),   # base of the neck = top of the torso
    ("N1", 0.055, 0.050, 0.051, 0.004, 1.500, 1.512),   # top of the shirt's neckband (under the collar)
    ("N2", 0.050, 0.046, 0.049, 0.006, 1.540, 1.552),
    ("N3", 0.052, 0.049, 0.051, 0.006, 1.570, 1.588),
    ("H1", 0.060, 0.072, 0.062, 0.000, 1.588, 1.612),   # jaw and chin
    ("H2", 0.068, 0.082, 0.078, 0.000, 1.625, 1.638),
    ("H3", 0.071, 0.088, 0.089, 0.000, 1.662, 1.665),   # cheekbones
    ("H4", 0.073, 0.090, 0.096, 0.000, 1.702, 1.698),   # brow; tops of the ears
    ("H5", 0.072, 0.086, 0.097, 0.000, 1.738, 1.734),
    ("H6", 0.063, 0.074, 0.087, 0.000, 1.770, 1.766),
    ("H7", 0.040, 0.047, 0.058, 0.000, 1.791, 1.789),
]
HEAD_TOP_Z = 1.800

# Arm rings (left arm; the right is mirrored): x, centre z, half depth (y), half height up, down.
# Short sleeve to mid upper arm (a hem that flares and steps in), bare arm, a long forearm.
ARM = [
    (0.172, 1.383, 0.059, 0.055, 0.050),   # 1 deltoid cap
    (0.205, 1.382, 0.058, 0.054, 0.050),   # 2
    (0.250, 1.381, 0.056, 0.052, 0.050),   # 3
    (0.300, 1.380, 0.058, 0.054, 0.053),   # 4 sleeve opening out to the hem
    (0.318, 1.380, 0.059, 0.055, 0.054),   # 5 hem edge
    (0.320, 1.380, 0.041, 0.039, 0.039),   # 6 under the hem: skin from here
    (0.336, 1.380, 0.041, 0.039, 0.038),   # 7
    (0.420, 1.380, 0.036, 0.034, 0.034),   # 8 above the elbow
    (0.445, 1.380, 0.038, 0.035, 0.035),   # 9 elbow
    (0.470, 1.380, 0.039, 0.036, 0.035),   # 10 below the elbow; the point of the elbow pushed back
    (0.560, 1.380, 0.036, 0.033, 0.032),   # 11 forearm
    (0.680, 1.380, 0.028, 0.022, 0.022),   # 12
    (0.692, 1.380, 0.0275, 0.0215, 0.0215),  # 13 watch (left wrist only, pushed out)
    (0.706, 1.380, 0.0270, 0.0205, 0.0205),  # 14 watch
    (0.722, 1.380, 0.0265, 0.0190, 0.0190),  # 15 wrist
]
SLEEVE_BANDS = 5            # bands before this are shirt sleeve; the next is the hem's underside
ELBOW = 10
WATCH = (13, 14)
ARM_ANG = [-135, 180, 135, 90, 45, 0, -45, -90]  # (y = cos, z = sin): a vertex on top, as the hands tutorial says

# The hand (left; the right is mirrored), palm down, fingers straight and fanned, thumb forward.
HAND_Z = 1.380
FINGERS = [  # name, width, length, fan (degrees, + toward the back), knuckle x offset
    ("index", 0.0175, 0.087, -7.0, -0.003),
    ("middle", 0.0180, 0.096, 0.0, 0.000),
    ("ring", 0.0170, 0.091, 7.0, -0.003),
    ("pinky", 0.0145, 0.073, 14.0, -0.011),
]
FGAP = 0.004
PALM = [  # x, y scale, top half-thickness, bottom half-thickness
    (0.740, 0.80, 0.0175, 0.0150),
    (0.778, 0.93, 0.0165, 0.0135),
    (0.814, 1.00, 0.0125, 0.0105),     # knuckles: the finger roots
]
# finger rings: (fraction of length, half width, half height); the tip is a point
FRING = [(0.09, 0.0081, 0.0080), (0.42, 0.0073, 0.0071), (0.52, 0.0076, 0.0072), (0.74, 0.0067, 0.0063),
         (0.84, 0.0065, 0.0060), (0.95, 0.0052, 0.0046)]      # blunt tips, not points
THUMB_DIR = (0.50, -0.78, -0.36)
THUMB = [(0.012, 0.0118, 0.0108), (0.030, 0.0102, 0.0095), (0.040, 0.0104, 0.0095), (0.056, 0.0094, 0.0085),
         (0.066, 0.0088, 0.0078), (0.074, 0.0066, 0.0058)]
THUMB_LEN = 0.078

# Leg rings (right leg; the left is mirrored): z, centre x, centre y, half width, half depth front, back.
# The trousers stop a little short over thin ankles in dark socks.
LEG = [
    (0.760, -0.096, 0.006, 0.078, 0.084, 0.092),   # top of the thigh
    (0.660, -0.097, 0.002, 0.071, 0.076, 0.080),
    (0.560, -0.099, -0.002, 0.063, 0.067, 0.066),
    (0.520, -0.100, -0.006, 0.060, 0.068, 0.061),  # knee loops
    (0.490, -0.101, -0.008, 0.059, 0.070, 0.059),  # kneecap
    (0.460, -0.101, -0.005, 0.059, 0.064, 0.063),  # behind the knee
    (0.350, -0.102, 0.003, 0.058, 0.061, 0.067),   # calf
    (0.200, -0.104, 0.005, 0.056, 0.059, 0.061),
    (0.140, -0.104, 0.006, 0.058, 0.061, 0.064),   # trouser hem
    (0.132, -0.104, 0.006, 0.058, 0.061, 0.064),   # hem edge
    (0.131, -0.104, 0.010, 0.034, 0.035, 0.038),   # under the hem: sock from here
    (0.090, -0.104, 0.012, 0.031, 0.033, 0.036),   # ankle
    (0.072, -0.104, 0.014, 0.041, 0.048, 0.050),   # shoe opening
    (0.045, -0.104, 0.012, 0.046, 0.060, 0.058),
    (0.000, -0.104, 0.010, 0.047, 0.062, 0.060),   # sole
]
TROUSER_BANDS = 11          # bands before this are trousers (the last of them the hem's underside)
SOCK_BANDS = 12
LEG_ANG = [-135, -90, -45, 0, 45, 90, 135, 180]
TOE = [dict(y=-0.120, ztop=0.050, sx=1.04), dict(y=-0.172, ztop=0.040, sx=0.92), dict(y=-0.198, ztop=0.028, sx=0.60)]

# The collar: a stand up the neck, a fold, a fall down over the shirt, two points at the front.
COLLAR = dict(gap=16.0, cols=18, stand=0.034, fall_out=0.026, fall_drop=0.040, point_drop=0.030, thick=0.0025)
# The tie: knot under the collar points, a blade lying 4 mm off the shirt, slightly askew, a V tip.
TIE = dict(knot_top=1.494, knot_bot=1.455, knot_w=(0.036, 0.022), knot_d=0.016,
           rows=[(1.456, 0.015), (1.420, 0.019), (1.340, 0.025), (1.240, 0.030), (1.150, 0.034), (1.095, 0.036)],
           askew=0.010, lift=0.004, thick=0.004)
# The lanyard (a blue ribbon round the neck over the collar) and the ID badge, hung to the right.
LANYARD_PATH = [(-0.050, -0.11, 1.318), (-0.020, -0.11, 1.370), (0.020, -0.10, 1.420), (0.048, -0.075, 1.460),
                (0.064, -0.040, 1.484), (0.068, 0.000, 1.494), (0.060, 0.040, 1.498), (0.032, 0.066, 1.498),
                (0.000, 0.074, 1.498), (-0.032, 0.066, 1.498), (-0.060, 0.040, 1.498), (-0.068, 0.000, 1.494),
                (-0.064, -0.040, 1.484), (-0.056, -0.075, 1.458), (-0.054, -0.100, 1.410), (-0.054, -0.11, 1.360),
                (-0.056, -0.11, 1.318)]
LANYARD = dict(width=0.011, lift=0.0035, thick=0.0015, step=0.022)
BADGE = dict(x=-0.060, top=1.300, w=0.054, h=0.086, t=0.004, tilt=-6.0, clip=0.018)
# The A4 sheet: the side profile of its middle, from the top edge over the hairline, down the face, past
# the chin and hanging a little forward. Wrapped round a vertical axis with radius SHEET_R (by arc length
# from the top): gently, so it reads as a flat sheet bent over a face, not a mask.
SHEET_W, SHEET_H = 0.210, 0.297
SHEET_PROFILE = [(-0.080, 1.784), (-0.088, 1.762), (-0.094, 1.735), (-0.098, 1.706), (-0.101, 1.678),
                 (-0.103, 1.650), (-0.103, 1.622), (-0.100, 1.598), (-0.101, 1.575), (-0.106, 1.550),
                 (-0.114, 1.525), (-0.124, 1.500), (-0.134, 1.478), (-0.142, 1.460)]
SHEET_R = [(0.0, 0.115), (0.06, 0.135), (0.14, 0.150), (0.22, 0.165), (0.297, 0.190)]
# (u, v spread, strength) of the pull onto the head round the top and the bottom staples: the top corners
# are stapled into the hair at the temples; the bottom hangs free past the chin, stapled through the paper
SHEET_PULL = [(0.15, 0.10, 1.0), (0.10, 0.05, 0.0)]
SHEET_NU, SHEET_NV = 10, 16
SHEET_THICK = 0.0012
STAPLE_INSET = 0.014
# the sample photocopy on the sheet (client/temp_view.gd's page): 120 x 170, face drawn in FACE_RECT
PAGE = (120, 170)
FACE_RECT = (9, 26, 102, 102)
PAPER = np.array([0.93, 0.92, 0.88])
TONER = np.array([0.07, 0.07, 0.08])

# Props. Each in its own file; Blender space as above.
# STAPLER: origin at the grip (the middle of the top arm), the striking end toward -Y, top up (+Z).
# NOTES: origin at the middle of the pad, sticky edge toward +Y, writing up (+Z).

TAGS = ["shirt", "sleeve_in", "pocket", "belt", "trousers", "trouser_in", "skin", "nail", "sock", "shoe",
        "collar", "tie", "knot", "lanyard", "clip", "badge", "paperback", "staple", "pen", "sheet",
        "plastic", "metal", "pad", "padtop"]
TG = {n: i for i, n in enumerate(TAGS)}


# ============================ MESH ============================
class Mesh:
    def __init__(self):
        self.co, self.faces, self.mat, self.tag = [], [], [], []
        self.uv = {}

    def v(self, p):
        self.co.append(Vector(p))
        return len(self.co) - 1

    def f(self, ids, mat, tag):
        self.faces.append(list(ids))
        self.mat.append(mat)
        self.tag.append(tag)
        return len(self.faces) - 1

    def extrude(self, fids, newpos, wall_tag=None, wall_mat=None, idx=False):
        """Extrude a region of faces: duplicate its vertices (placed by newpos), move the region onto them
        and wall the boundary. Returns ({frozenset(old edge): wall face id}, {old vertex: new vertex})."""
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

    def solid(self, pts, faces, out, thick, mat, tag, back_mat=None, back_tag=None, uvs=None):
        """A thin closed shell from an open surface: the surface (offset nothing), a copy `thick` behind it
        (against `out`, the side the surface faces) with the faces reversed, and a rim on every boundary
        edge. `out(p)` gives the rough outward direction at p. Returns the front vertex ids."""
        n = [Vector() for _ in pts]
        for fc in faces:
            a, b, c = (Vector(pts[i]) for i in fc[:3])
            fn = (b - a).cross(c - a)
            if len(fc) == 4:
                fn = (Vector(pts[fc[2]]) - a).cross(Vector(pts[fc[3]]) - Vector(pts[fc[1]]))
            for i in fc:
                n[i] += fn
        front, back = [], []
        for i, p in enumerate(pts):
            nn = n[i].normalized() if n[i].length > 1e-12 else Vector(out(p)).normalized()
            if nn.dot(Vector(out(p))) < 0:
                nn = -nn
            front.append(self.v(p))
            back.append(self.v(Vector(p) - nn * thick))
            if uvs is not None:
                self.uv[front[-1]] = uvs[i]
        bm, bt = (mat if back_mat is None else back_mat), (tag if back_tag is None else back_tag)
        count = {}
        for fc in faces:
            self.f([front[i] for i in fc], mat, tag)
            self.f([back[i] for i in reversed(fc)], bm, bt)
            for a, b in zip(fc, fc[1:] + fc[:1]):
                k = frozenset((a, b))
                count[k] = count.get(k, 0) + 1
        for fc in faces:
            for a, b in zip(fc, fc[1:] + fc[:1]):
                if count[frozenset((a, b))] == 1:
                    self.f([front[a], back[a], back[b], front[b]], bm, bt)
        return front

    def box(self, centre, ex, ey, ez, mat, tag):
        """a closed box: centre and three half-axis vectors"""
        c = Vector(centre)
        ids = [self.v(c + sx * Vector(ex) + sy * Vector(ey) + sz * Vector(ez))
               for sz in (-1, 1) for sy in (-1, 1) for sx in (-1, 1)]
        for q in ((0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)):
            self.f([ids[i] for i in q], mat, tag)
        return ids


def mx(p):
    return (-p[0], p[1], p[2])


def sup(c, s, p=2.4):
    """superellipse radius factor: corners a little squarer than a circle"""
    return 1.0 / (abs(c) ** p + abs(s) ** p) ** (1.0 / p)


def head_pt(a_deg, row, extra=0.0):
    name, rx, ryf, ryb, cy, zf, zb = row
    c, s = math.cos(math.radians(a_deg)), math.sin(math.radians(a_deg))
    k = sup(c, s)
    ry = ryf if s < 0 else ryb
    x, y = (rx + extra) * c * k, cy + (ry + extra) * s * k
    z = zb + (zf - zb) * (1 - s) / 2
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


def bridge(m, A, aa, B, bb, mat, tag):
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


def cap(m, ring, C, mat, tag):
    """close an 8-vertex ring (outline of a 3 x 3 grid, starting at a corner) with four quads"""
    r = ring
    for q in ([r[0], r[1], C, r[7]], [r[1], r[2], r[3], C], [C, r[3], r[4], r[5]], [r[7], C, r[5], r[6]]):
        m.f(q, mat, tag)


# ============================ BODY ============================
def build_hand(m, side, wrist):
    """The hand at the end of the arm ring `wrist` (8 vertices in ARM_ANG order). Built for the left hand
    (+X) and mirrored for the right by placing every vertex through L()."""
    L = (lambda p: Vector(p)) if side > 0 else (lambda p: Vector(mx(p)))
    widths = [f[1] for f in FINGERS]
    total = sum(widths) + FGAP * 3
    edges, y = [], -total / 2
    for w in widths:
        edges += [y, y + w]
        y += w + FGAP
    half = total / 2
    rings = []
    for ri, (x, sy, top, bot) in enumerate(PALM):
        t, b = [], []
        for k, ye in enumerate(edges):
            xx = x + (FINGERS[k // 2][4] if ri == len(PALM) - 1 else 0.0)
            yy = ye * sy
            q = (ye / half) ** 2
            t.append(m.v(L((xx, yy, HAND_Z + top * (1 - 0.30 * q)))))
            b.append(m.v(L((xx, yy, HAND_Z - bot * (1 - 0.12 * q)))))
        rings.append((t, b))
    order16 = lambda tb: tb[1] + list(reversed(tb[0]))     # b0..b7, t7..t0: ascending angle
    ang16 = []
    t0, b0 = rings[0]
    for vid in order16(rings[0]):
        p = m.co[vid]
        ang16.append(math.degrees(math.atan2((p.z - HAND_Z) / 0.015, p.y / 0.04)))
    order8 = sorted(range(8), key=lambda q: ARM_ANG[q])
    bridge(m, [wrist[q] for q in order8], sorted(ARM_ANG), order16(rings[0]), ang16, BODY, "skin")
    bands = []
    for r in range(len(rings) - 1):
        A, B = order16(rings[r]), order16(rings[r + 1])
        bands.append([m.f([A[i], A[(i + 1) % 16], B[(i + 1) % 16], B[i]], BODY, "skin") for i in range(16)])
    tk, bk = rings[-1]
    capq = [m.f([tk[k], tk[k + 1], bk[k + 1], bk[k]], BODY, "skin") for k in range(7)]

    def grow(fid, roles, centre, d, side_v, up_v, steps, tip_at):
        """pull a quad out as a diamond-section finger: each step (s, w, h) is a ring at distance s along d
        from `centre`; roles map the quad's four corners to top/back/bottom/front of the diamond"""
        role = dict(roles)
        for n_, (s, w, h) in enumerate(steps):
            c = centre + d * s
            pos = {"top": c + up_v * h, "back": c + side_v * w, "bottom": c - up_v * h, "front": c - side_v * w}
            walls, nv = m.extrude([fid], lambda p, v: L(pos[role[v]]), idx=True)
            role = {nv[v]: r for v, r in role.items()}
            if n_ == len(steps) - 1:    # the nail: the top of the last band and the tip
                top_new = next(v for v, r in role.items() if r == "top")
                for wf in walls.values():
                    if top_new in m.faces[wf]:
                        m.tag[wf] = "nail"
        tip = m.v(L(centre + d * tip_at - up_v * 0.001))
        ring = m.faces[fid]
        top_v = next(v for v in ring if role[v] == "top")
        tris = [[ring[i], ring[(i + 1) % 4], tip] for i in range(4)]
        m.faces[fid] = tris[0]
        m.tag[fid] = "nail" if top_v in tris[0][:2] else "skin"
        for tri in tris[1:]:
            m.f(tri, BODY, "nail" if top_v in tri[:2] else "skin")
        return role

    Z = Vector((0, 0, 1))
    for fi, (name, w, length, fan, koff) in enumerate(FINGERS):
        k = 2 * fi
        a = math.radians(fan)
        d = Vector((math.cos(a), math.sin(a), 0.0))
        sv = Vector((-d.y, d.x, 0.0))
        c0 = Vector((PALM[-1][0] + koff, (edges[k] + edges[k + 1]) / 2, HAND_Z + (PALM[-1][2] - PALM[-1][3]) / 2))
        roles = {tk[k]: "top", tk[k + 1]: "back", bk[k + 1]: "bottom", bk[k]: "front"}
        sc = w / 0.018 * 1.08
        steps = [(f * length, hw * sc, hh * sc) for f, hw, hh in FRING]
        grow(capq[k], roles, c0, d, sv, Z, steps, length)
    # the thumb: out of the front side of the palm between the first two rings
    tb0, tb1 = rings[0], rings[1]
    tf = bands[0][15]   # [t0 base, b0 base, b0 mid, t0 mid]
    d = Vector(THUMB_DIR).normalized()
    X = Vector((1, 0, 0))
    sv = (X - d * X.dot(d)).normalized()
    up = d.cross(sv).normalized()
    if up.z < 0:
        up = -up
    c0 = Vector(((PALM[0][0] + PALM[1][0]) / 2, edges[0] * (PALM[0][1] + PALM[1][1]) / 2, HAND_Z))
    roles = {tb0[0][0]: "top", tb1[0][0]: "back", tb1[1][0]: "bottom", tb0[1][0]: "front"}
    grow(tf, roles, c0, d, sv, up, THUMB, THUMB_LEN)


def build_body():
    m = Mesh()
    zs = [z for z, _ in TORSO_Z]
    ri = {round(z, 4): i for i, z in enumerate(zs)}
    rA = ri[ARM_ROOT_Z]

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
            xs = fr[0][0] - 0.004
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
    zrow = zs + [sh["z"]]

    tband = {}
    for r in range(nrow - 1):
        z0, z1 = zrow[r], zrow[r + 1]
        if BELT[0] <= z0 and z1 <= BELT[1]:
            tag = "belt"
        elif z1 <= BELT[0]:
            tag = "trousers"
        else:
            tag = "shirt"
        for j in range(14):
            if r >= rA and j in (12, 13, 5, 6):
                continue
            j2 = (j + 1) % 14
            tband[(r, j)] = m.f([T[r][j], T[r][j2], T[r + 1][j2], T[r + 1][j]], BODY, tag)
    t = T[-1]
    m.f([t[0], t[1], Q1, t[13]], BODY, "shirt")
    m.f([t[13], Q1, t[11], t[12]], BODY, "shirt")
    m.f([t[5], t[4], Q4, t[6]], BODY, "shirt")
    m.f([t[6], Q4, t[8], t[7]], BODY, "shirt")
    B2 = m.v(CROTCH)
    B3 = m.v(mx(CROTCH))
    b = T[0]
    m.f([b[2], b[3], B3, B2], BODY, "trousers")
    m.f([B2, B3, b[9], b[10]], BODY, "trousers")
    # the breast pocket on the left chest, raised 3 mm
    fids = [tband[(ri[z], 3)] for z in POCKET_ROWS]
    for i in fids:
        m.tag[i] = "pocket"
    ctr = sum((m.co[v] for i in fids for v in m.faces[i]), Vector()) / 8

    def pk(p, ctr=ctr):
        d = p - ctr
        return Vector((ctr.x + d.x * 0.90, p.y - 0.003, ctr.z + d.z * 0.94))
    m.extrude(fids, pk, wall_tag="pocket")

    # ---- arms
    for side in (1, -1):
        if side > 0:
            r0 = [T[rA][5], T[rA + 1][5], T[-1][5], T[-1][6], T[-1][7], T[rA + 1][7], T[rA][7], T[rA][6]]
        else:
            r0 = [T[rA][0], T[rA + 1][0], T[-1][0], T[-1][13], T[-1][12], T[rA + 1][12], T[rA][12], T[rA][13]]
        rings = [r0]
        for n, (x, cz, ry, rzu, rzd) in enumerate(ARM, start=1):
            grow = 0.003 if (side > 0 and n in WATCH) else 0.0
            rr = []
            for a in ARM_ANG:
                c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
                k = sup(c, s, 2.2)
                yy = (ry + grow) * c * k
                zz = ((rzu if s > 0 else rzd) + grow) * s * k
                if n == ELBOW and c > 0:   # the point of the elbow
                    yy += 0.008 * c
                rr.append(m.v((side * x, yy, cz + zz)))
            rings.append(rr)
        for i in range(len(rings) - 1):
            tag = "shirt" if i < SLEEVE_BANDS else ("sleeve_in" if i == SLEEVE_BANDS else "skin")
            for k in range(8):
                k2 = (k + 1) % 8
                m.f([rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]], BODY, tag)
        build_hand(m, side, rings[-1])

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
                k = sup(c, s, 2.3)
                ry = ryf if s < 0 else ryb
                p = (cx + rx * c * k, cy + ry * s * k, z)
                rr.append(m.v(p if side < 0 else mx(p)))
            rings.append(rr)
        band = {}
        for i in range(len(rings) - 1):
            tag = ("trousers" if i < TROUSER_BANDS - 1 else "trouser_in") if i < TROUSER_BANDS else \
                  ("sock" if i < SOCK_BANDS else "shoe")
            for k in range(8):
                k2 = (k + 1) % 8
                band[(i, k)] = m.f([rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]], BODY, tag)
        last = LEG[-1]
        lcx = side * -last[1]
        C = m.v((lcx, last[2], 0.0))
        cap(m, rings[-1], C, BODY, "shoe")
        fids = [band[(len(LEG) - 1, 0)], band[(len(LEG) - 1, 1)]]
        for st in TOE:
            def tp(p, st=st, lcx=lcx):
                top = p.z > 0.02
                dx = (p.x - lcx) * st["sx"]
                return Vector((lcx + dx, st["y"] - 0.010 * (1 - min(1.0, abs(dx) / 0.03)) * (st is TOE[-1]),
                               st["ztop"] if top else 0.0))
            m.extrude(fids, tp)

    # ---- neck and head
    nrings = [neck0] + [[m.v(head_pt(a, row)) for a in A10] for row in HEADR[1:4]]
    for i in range(len(nrings) - 1):
        for k in range(10):
            k2 = (k + 1) % 10
            m.f([nrings[i][k], nrings[i][k2], nrings[i + 1][k2], nrings[i + 1][k]], BODY, "shirt" if i == 0 else "skin")
    hrows = [r for r in HEADR if r[0][0] == "H"]
    H = [[m.v(head_pt(a, row)) for a in A12] for row in hrows]
    bridge(m, nrings[-1], A10, H[0], A12, BODY, "skin")
    hb = {}
    for i in range(len(H) - 1):
        for k in range(12):
            k2 = (k + 1) % 12
            hb[(i, k)] = m.f([H[i][k], H[i][k2], H[i + 1][k2], H[i + 1][k]], BODY, "skin")
    R = H[-1]
    M1 = m.v((0, -0.020, HEAD_TOP_Z))
    M2 = m.v((0, 0.026, HEAD_TOP_Z))
    for q in ([R[2], R[3], R[4], M1], [M1, R[4], R[5], M2], [M2, R[5], R[6], R[7]], [M2, R[7], R[8]],
              [R[2], R[1], R[0], M1], [M1, R[0], R[11], M2], [M2, R[11], R[10], R[9]], [M2, R[9], R[8]]):
        m.f(q, BODY, "skin")
    # ears: a 2 x 2 patch of each side of the head (H2 to H4), pulled out and back twice
    for ks in ((4, 5), (10, 11)):
        fids = [hb[(i, k)] for i in (1, 2) for k in ks]
        for step, (sc, out, back) in enumerate(((0.80, 0.011, 0.006), (0.86, 0.005, 0.002))):
            ctr = sum((m.co[v] for i in fids for v in m.faces[i]), Vector()) / 16
            o = Vector((math.copysign(1.0, ctr.x), 0, 0))

            def ear(p, ctr=ctr, sc=sc, out=out, back=back, o=o):
                q = ctr + (p - ctr) * sc + o * out
                return Vector((q.x, q.y + back, q.z))
            m.extrude(fids, ear)
    return m


# ============================ OBJECTS ============================
def make_object(m, name):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(c) for c in m.co], [], m.faces)
    me.update()
    for poly, mt in zip(me.polygons, m.mat):
        poly.material_index = mt
    attr = me.attributes.new("tag", "INT", "FACE")
    attr.data.foreach_set("value", [TG[t] for t in m.tag])
    uvl = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            if vi in m.uv:
                uvl.data[li].uv = m.uv[vi]
    for mn in MATS:
        me.materials.append(bpy.data.materials.get(mn) or bpy.data.materials.new(mn))
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    bm = bmesh.new()
    bm.from_mesh(me)
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.update()
    if loose:
        print(f"[build] {name}: removed {len(loose)} loose vertices")
    face_out(me)
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
    sa = me.attributes.get("sharp_edge") or me.attributes.new("sharp_edge", "BOOLEAN", "EDGE")
    sa.data.foreach_set("value", sharp)
    return ob


def face_out(me):
    """every closed island faces out: make each consistent, then flip any whose signed volume is negative"""
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    seen = set()
    for f in bm.faces:
        if f.index in seen:
            continue
        stack, isl = [f], []
        seen.add(f.index)
        while stack:
            g = stack.pop()
            isl.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index)
                        stack.append(h)
        vol = sum(g.calc_center_median().dot(g.normal) * g.calc_area() for g in isl)
        if vol < 0:
            bmesh.ops.reverse_faces(bm, faces=isl)
    bm.to_mesh(me)
    bm.free()
    me.update()


def body_bvh(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bm.transform(ob.matrix_world)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bm.normal_update()
    tree = BVHTree.FromBMesh(bm)
    return tree, bm


def clear_of(tree, p, clear):
    """p moved out of the surface (along its normal) until it is at least `clear` in front of it"""
    p = Vector(p)
    loc, nrm, _, _ = tree.find_nearest(p)
    if loc is None:
        return p
    d = (p - loc).dot(nrm)
    if d < clear:
        p = p + nrm * (clear - d)
    return p


def onto(tree, p, lift):
    """the nearest point of the surface to p, lifted off it by `lift`, and the surface normal there"""
    loc, nrm, _, _ = tree.find_nearest(Vector(p))
    return loc + nrm * lift, nrm


def ray_front(tree, x, z, lift):
    """where a ray from the front at (x, z) meets the body, lifted off it by `lift`"""
    loc, nrm, _, _ = tree.ray_cast(Vector((x, -1.0, z)), Vector((0, 1, 0)))
    if loc is None:
        raise RuntimeError(f"no body at x={x} z={z}")
    return loc + nrm * lift, nrm


# ============================ CLOTHING AND THE SHEET ============================
def build_collar(m, tree):
    C = COLLAR
    a0, a1 = -90 + C["gap"], 270 - C["gap"]
    cols = C["cols"]
    N0, N1 = HEADR[0], HEADR[1]
    pts, faces = [], []
    for j in range(cols):
        a = a0 + (a1 - a0) * j / (cols - 1)
        base = Vector(head_pt(a, N0, 0.004)) + Vector((0, 0, 0.008))
        fold = Vector(head_pt(a, N1, 0.006))
        fold.z = base.z + C["stand"]
        fall = Vector(head_pt(a, N0, C["fall_out"]))
        fall.z = fold.z - C["fall_drop"]
        end = min(j, cols - 1 - j)
        if end == 0:          # the collar points: down and in over the knot
            fall = Vector((fall.x * 0.55, fall.y, fall.z - C["point_drop"]))
        elif end == 1:
            fall = Vector((fall.x * 0.85, fall.y, fall.z - C["point_drop"] * 0.35))
        fall = onto(tree, fall, 0.003)[0]      # the fall lies on the shirt
        if end == 0:
            fall = fall + Vector((0, -0.004, 0))
        pts += [clear_of(tree, base, 0.002), clear_of(tree, fold, 0.002), fall]
    for j in range(cols - 1):
        for r in range(2):
            i = j * 3 + r
            faces.append([i, i + 1, i + 4, i + 3])
    centre = Vector((0, 0.003, 1.49))

    def out(p):
        d = Vector(p) - centre
        return Vector((d.x, d.y, 0.3)).normalized()
    m.solid(pts, faces, out, C["thick"], BODY, "collar")


def build_tie(m, tree):
    t = TIE
    # knot: a tapered block, its back on the shirt front
    zt, zb = t["knot_top"], t["knot_bot"]
    wt, wb = t["knot_w"]
    ids = []
    for z, w in ((zb, wb), (zt, wt)):
        yb, _ = ray_front(tree, 0.0, z, 0.001)
        for sx in (-1, 1):
            for dy in (0.0, -t["knot_d"]):
                ids.append(m.v((sx * w / 2, yb.y + dy, z)))
    # ids: z0: (-x,back) (-x,front) (+x,back) (+x,front); z1 same
    q = [(0, 2, 3, 1), (4, 5, 7, 6), (1, 3, 7, 5), (0, 4, 6, 2), (0, 1, 5, 4), (2, 6, 7, 3)]
    for f in q:
        m.f([ids[i] for i in f], BODY, "knot")
    # blade: three columns (edge, middle, edge) down the shirt, then a V tip
    rows = t["rows"]
    pts, faces = [], []
    z_top = rows[0][0]
    for z, w in rows:
        dx = t["askew"] * (z_top - z) / (z_top - rows[-1][0])
        for c, bulge in ((-1, 0.0), (0, 0.0025), (1, 0.0)):
            p, n = ray_front(tree, dx + c * w, z, t["lift"] + bulge)
            pts.append(p)
    zl, wl = rows[-1]
    dx = t["askew"]
    tip, _ = ray_front(tree, dx, zl - wl * 0.95, t["lift"])
    pts.append(tip)
    nr = len(rows)
    for j in range(nr - 1):
        for c in range(2):
            i = j * 3 + c
            faces.append([i, i + 1, i + 4, i + 3])
    last = (nr - 1) * 3
    faces.append([last, last + 1, len(pts) - 1])
    faces.append([last + 1, last + 2, len(pts) - 1])
    m.solid(pts, faces, lambda p: (0, -1, 0), t["thick"], BODY, "tie")


def resample(path, step):
    pts = [Vector(p) for p in path]
    out = [pts[0]]
    acc = 0.0
    for a, b in zip(pts, pts[1:]):
        seg = (b - a).length
        n = max(1, round(seg / step))
        for i in range(1, n + 1):
            out.append(a.lerp(b, i / n))
    return out


def build_lanyard(m, tree):
    L = LANYARD
    path = resample(LANYARD_PATH, L["step"])
    # snap to the body (and collar) and smooth twice
    for _ in range(3):
        path = [onto(tree, p, L["lift"])[0] for p in path]
        path = [path[0]] + [(path[i - 1] + path[i] * 2 + path[i + 1]) / 4 for i in range(1, len(path) - 1)] + [path[-1]]
    path = [clear_of(tree, p, L["lift"]) for p in path]
    pts, faces = [], []
    for i, p in enumerate(path):
        tg = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
        _, n = onto(tree, p, 0.0)
        sd = tg.cross(n).normalized()
        pts += [p - sd * L["width"] / 2, p + sd * L["width"] / 2]
    for i in range(len(path) - 1):
        faces.append([2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2])

    def out(p):
        return onto(tree, p, 0.0)[1]
    m.solid(pts, faces, out, L["thick"], BODY, "lanyard")
    # the clip where both ends meet, and the badge hanging under it
    B = BADGE
    clip_c = Vector((B["x"], 0, B["top"] + B["clip"] / 2))
    cp, cn = ray_front(tree, clip_c.x, clip_c.z, 0.006)
    m.box(cp, (0.006, 0, 0), (0, 0.002, 0), (0, 0, B["clip"] / 2 + 0.008), BODY, "clip")
    tilt = math.radians(B["tilt"])
    ex = Vector((math.cos(tilt), 0, math.sin(tilt)))
    ez = Vector((-math.sin(tilt), 0, math.cos(tilt)))
    centre_z = B["top"] - B["h"] / 2
    bp, bn = ray_front(tree, B["x"], centre_z, 0.010)
    m.box(bp, ex * B["w"] / 2, Vector((0, B["t"] / 2, 0)), ez * B["h"] / 2, BODY, "badge")
    global BADGE_FRAME
    BADGE_FRAME = (bp.copy(), ex.copy(), ez.copy())


def build_pen(m, tree):
    # a ballpoint clipped in the breast pocket, its top standing out
    p, n = ray_front(tree, 0.090, 1.262, 0.005)
    m.box(p + Vector((0, 0, 0.012)), (0.0045, 0, 0), (0, 0.0045, 0), (0, 0, 0.030), BODY, "pen")


def sheet_profile():
    pts = [Vector((0.0, y, z)) for y, z in SHEET_PROFILE]
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + (b - a).length)
    if cum[-1] < SHEET_H:
        raise RuntimeError(f"sheet profile too short: {cum[-1]:.3f} m")

    def at(s):
        for i in range(len(cum) - 1):
            if cum[i] <= s <= cum[i + 1]:
                t = (s - cum[i]) / (cum[i + 1] - cum[i])
                p = pts[i].lerp(pts[i + 1], t)
                tg = (pts[i + 1] - pts[i]).normalized()
                return p, tg
        return pts[-1], (pts[-1] - pts[-2]).normalized()
    return at


def wrap_radius(s):
    for (s0, r0), (s1, r1) in zip(SHEET_R, SHEET_R[1:]):
        if s0 <= s <= s1:
            t = (s - s0) / (s1 - s0)
            t = t * t * (3 - 2 * t)
            return r0 + (r1 - r0) * t
    return SHEET_R[-1][1]


def build_sheet(m, tree):
    at = sheet_profile()
    nu, nv = SHEET_NU, SHEET_NV
    grid, uvs = [], []
    for j in range(nv + 1):
        s = SHEET_H * j / nv
        c, tg = at(s)
        inward = Vector((0, -tg.z, tg.y))           # toward the head
        R = wrap_radius(s)
        for i in range(nu + 1):
            u = i / nu
            a = (u - 0.5) * SHEET_W / R
            p = c + Vector((R * math.sin(a), 0, 0)) + inward * R * (1 - math.cos(a))
            # the nose under the paper
            nose = 0.010 * math.exp(-((u - 0.5) / 0.10) ** 2 - ((s - 0.150) / 0.028) ** 2)
            p = p - inward * nose
            p = p - inward * 0.0015 * math.sin(u * 7.0 + s * 20.0)      # a slight ripple, as paper does
            grid.append(p)
            uvs.append((u, 1.0 - s / SHEET_H))
    # stapled at the corners: pull the paper onto the head round each staple, then keep it all clear
    staples = []
    du, dv = STAPLE_INSET / SHEET_W, STAPLE_INSET / SHEET_H
    for (cu, cv) in ((du, dv), (1 - du, dv), (du, 1 - dv), (1 - du, 1 - dv)):
        staples.append((cu, cv))
    for _ in range(2):
        for k, p in enumerate(grid):
            u, v = k % (nu + 1) / nu, k // (nu + 1) / nv
            w = 0.0
            for cu, cv in staples:
                su, sv, kk = SHEET_PULL[0] if cv < 0.5 else SHEET_PULL[1]
                w = max(w, kk * math.exp(-(((u - cu) / su) ** 2 + ((v - cv) / sv) ** 2)))
            if w > 0.02:
                q, _ = onto(tree, p, 0.0025)
                grid[k] = p.lerp(q, w)
            grid[k] = clear_of(tree, grid[k], 0.0025)
    faces = []
    for j in range(nv):
        for i in range(nu):
            a = j * (nu + 1) + i
            faces.append([a, a + 1, a + nu + 2, a + nu + 1])
    head_c = Vector((0, 0.0, 1.68))
    front = m.solid(grid, faces, lambda p: Vector(p) - head_c, SHEET_THICK, SHEET, "sheet", BODY, "paperback", uvs)
    # staples across each corner, standing just off the paper
    for cu, cv in staples:
        fi, fj = cu * nu, cv * nv
        i0, j0 = min(int(fi), nu - 1), min(int(fj), nv - 1)
        tu, tv = fi - i0, fj - j0
        g = lambda i, j: grid[j * (nu + 1) + i]
        p = (g(i0, j0) * (1 - tu) + g(i0 + 1, j0) * tu) * (1 - tv) + (g(i0, j0 + 1) * (1 - tu) + g(i0 + 1, j0 + 1) * tu) * tv
        eu = (g(i0 + 1, j0) - g(i0, j0)).normalized()
        ev = (g(i0, j0 + 1) - g(i0, j0)).normalized()
        n = eu.cross(ev).normalized()
        if n.dot(p - head_c) < 0:
            n = -n
        diag = (eu * (1 if cu < 0.5 else -1) + ev * (1 if cv < 0.5 else -1)).normalized()
        across = diag.cross(n).normalized()
        m.box(p + n * 0.0011, across * 0.0065, diag * 0.0010, n * 0.0006, BODY, "staple")
    return grid


# ============================ UVS ============================
def unwrap(ob):
    me = ob.data
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="DESELECT")
    ob.active_material_index = BODY
    bpy.ops.object.material_slot_select()
    bpy.ops.mesh.hide(unselected=True)
    bpy.ops.uv.smart_project(angle_limit=math.radians(60.0), island_margin=0.006, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(rotate=True, margin=0.006, shape_method="CONCAVE")
    bpy.ops.mesh.reveal(select=False)
    bpy.ops.mesh.select_all(action="DESELECT")
    bpy.ops.object.mode_set(mode="OBJECT")
    # the sheet's front keeps the 0..1 UVs it was built with: check them
    uvl = me.uv_layers[0]
    us = [uvl.data[li].uv.copy() for p in me.polygons if p.material_index == SHEET for li in p.loop_indices]
    print(f"[build] face sheet: {sum(1 for p in me.polygons if p.material_index == SHEET)} faces, "
          f"u {min(u.x for u in us):.3f}..{max(u.x for u in us):.3f}, v {min(u.y for u in us):.3f}..{max(u.y for u in us):.3f}")


# ============================ TEXTURES ============================
_TAB = np.random.default_rng(23).random(4096)


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


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


BADGE_FRAME = None


def body_colour(Pt, N, T):
    x, y, z = Pt[:, 0], Pt[:, 1], Pt[:, 2]
    ax = np.abs(x)
    n = len(x)
    col = np.zeros((n, 3))
    is_ = lambda *names: np.isin(T, [TG[k] for k in names])
    grain = 1 + 0.012 * (vnoise(Pt, 90.0, 9) - 0.5)
    blot = vnoise(Pt, 9.0, 3)

    # --- shirt (body, sleeves, pocket, collar): pale blue-white, gone a little grey and yellow
    shirt = is_("shirt", "pocket", "collar", "sleeve_in")
    sh = np.ones(n)
    sh *= 1 - 0.035 * vnoise(Pt, 12.0, 1)
    # tucked in: soft vertical folds above the belt; pull folds to the armpits; under the sleeves
    soft = lambda ph: (0.5 + 0.5 * np.sin(ph)) ** 2
    sh *= 1 - 0.12 * band(z, 1.003, 1.10, 0.03) * soft(x * 95 + 1.3) * (ax < 0.16)
    sh *= 1 - 0.08 * band(z, 1.15, 1.32, 0.05) * band(ax, 0.08, 0.16, 0.03) * soft((z + ax * 1.2) * 48)
    sh *= 1 - 0.10 * (ax > 0.17) * (N[:, 2] < -0.3) * soft(ax * 70)
    # seams: shoulders (yoke at the back), sleeve hems, side seams
    sh *= 1 - 0.22 * g(ax - 0.172, 0.004) * (z > 1.30)
    sh *= 1 - 0.18 * (y > 0.03) * g(z - 1.405, 0.004) * (ax < 0.15)
    sh *= 1 - 0.25 * g(ax - 0.309, 0.004) * (z > 1.30)
    sh *= 1 - 0.15 * g(np.abs(y), 0.004) * (ax > 0.14) * (z < 1.33)
    # placket and buttons down the front (mostly under the tie)
    front = (N[:, 1] < -0.4) & (z < 1.47) & (z > 1.00) & (ax < 0.15)
    sh *= np.where(front & (np.abs(ax - 0.013) < 0.0025), 0.84, 1.0)
    bz = np.abs(((z - 1.43) / 0.085) - np.round((z - 1.43) / 0.085)) * 0.085
    button = front & (ax < 0.006) & (bz < 0.0055)
    sh *= np.where(button, 1.06, 1.0)
    sh *= np.where(button & (ax < 0.002) & (bz < 0.0018), 0.55, 1.0)
    # the pocket: a darker edge, a hem across the top, a shadow inside the opening
    pk = T == TG["pocket"]
    sh *= np.where(pk & (np.abs(N[:, 1]) < 0.6), 0.74, 1.0)
    sh *= np.where(pk & (np.abs(z - 1.282) < 0.004), 0.78, 1.0)
    sh *= np.where((T == TG["shirt"]) & (x > 0.035) & (x < 0.115) & (np.abs(z - 1.293) < 0.004) & (N[:, 1] < -0.3), 0.70, 1.0)
    # crevice shadow: armpits, under the collar, the hem's underside
    for cx, cz, sx, sz, k in ((0.158, 1.335, 0.03, 0.05, 0.35),):
        d = ((ax - cx) / sx) ** 2 + ((z - cz) / sz) ** 2
        sh *= 1 - k * np.exp(-d)
    sh *= np.where(T == TG["sleeve_in"], 0.62, 1.0)
    sh *= 1 - 0.18 * (T == TG["shirt"]) * g(z - 1.465, 0.014) * (ax < 0.10)
    shirt_c = np.array([0.80, 0.84, 0.86])
    c = shirt_c[None, :] * (sh * grain)[:, None]
    # sweat: yellowed under the arms and round the collar (a ring of grime at the fold)
    sweat = np.exp(-(((ax - 0.165) / 0.05) ** 2 + ((z - 1.31) / 0.07) ** 2)) * (0.6 + 0.4 * blot)
    coll = T == TG["collar"]
    ring_ = coll * np.clip((z - 1.505) / 0.02, 0, 1) * (0.6 + 0.4 * blot)
    yel = np.array([0.74, 0.70, 0.52])
    c = c * (1 - 0.45 * sweat[:, None]) + yel[None, :] * (0.45 * sweat[:, None])
    c = c * (1 - 0.55 * ring_[:, None]) + np.array([0.56, 0.53, 0.42])[None, :] * (0.55 * ring_[:, None])
    c = np.where((coll & (np.abs(N[:, 2]) < 0.2) & (z < 1.50))[:, None], c * 0.85, c)
    col = np.where(shirt[:, None], c, col)

    # --- trousers: charcoal, a pressed crease down each leg, worn shiny at the knees, a fly, pockets
    tr = is_("trousers", "trouser_in")
    s = np.ones(n) * (1 - 0.04 * vnoise(Pt, 10.0, 4))
    leg = z < 0.79
    crease = leg & (np.abs(ax - 0.100) < 0.0035) & (N[:, 1] < -0.6)
    s *= np.where(crease, 1.28, 1.0)
    s *= np.where(leg & (np.abs(ax - 0.100) < 0.0035) & (N[:, 1] > 0.6), 1.12, 1.0)
    s *= 1 + 0.12 * leg * g(z - 0.50, 0.04) * np.clip(-N[:, 1], 0, 1)
    s *= 1 - 0.16 * leg * band(z, 0.13, 0.26, 0.03) * soft(z * 85)
    s *= 1 - 0.14 * leg * g(z - 0.47, 0.03) * (N[:, 1] > 0.3)
    fly = (~leg) & (N[:, 1] < -0.3) & (np.abs(x - 0.014) < 0.003) & (z < 0.95) & (z > 0.80)
    s *= np.where(fly, 0.62, 1.0)
    slant = (~leg) & (z > 0.84) & (np.abs((ax - 0.115) - (0.955 - z) * 0.45) < 0.003) & (N[:, 1] < 0.2)
    s *= np.where(slant, 0.62, 1.0)
    s *= 1 - 0.30 * np.exp(-((ax / 0.05) ** 2 + ((z - 0.785) / 0.05) ** 2))
    s *= 1 - 0.22 * leg * g(ax - 0.03, 0.022) * band(z, 0.45, 0.78, 0.08)
    s *= 1 - 0.25 * (~leg) * g(z - 0.952, 0.006)
    s *= np.where(T == TG["trouser_in"], 0.6, 1.0)
    col = np.where(tr[:, None], np.array([0.29, 0.29, 0.32])[None, :] * (s * grain)[:, None], col)

    # --- belt: black leather, stitched edges, a dull buckle
    bl = T == TG["belt"]
    bc = np.tile(np.array([0.13, 0.11, 0.10]), (n, 1))
    bc = np.where(((np.abs(z - 0.963) < 0.002) | (np.abs(z - 0.995) < 0.002))[:, None], bc * 1.6, bc)
    buckle = bl & (ax < 0.024) & (N[:, 1] < -0.5)
    bc = np.where(buckle[:, None], np.array([0.58, 0.56, 0.50]), bc)
    bc = np.where((buckle & (ax < 0.016) & (np.abs(z - 0.979) < 0.010))[:, None], np.array([0.20, 0.18, 0.16]), bc)
    loop = bl & (np.abs(ax - 0.10) < 0.006) & (N[:, 1] < 0)
    bc = np.where(loop[:, None], np.array([0.25, 0.25, 0.28]), bc)
    col = np.where(bl[:, None], bc, col)

    # --- skin: sallow, office-pale; darker knuckles and elbows, the neck in the sheet's shadow
    sk = is_("skin", "nail")
    skin = np.array([0.80, 0.74, 0.66])
    kc = skin[None, :] * (1 - 0.05 * (blot[:, None] - 0.5))
    hand = ax > 0.73
    kc = np.where((hand & (N[:, 2] > 0.5) & (np.abs(ax - 0.816) < 0.005))[:, None], kc * np.array([0.96, 0.92, 0.91]), kc)
    kc = np.where((hand & (N[:, 2] < -0.5))[:, None], kc * np.array([1.03, 0.97, 0.95]), kc)
    kc = np.where(((ax > 0.43) & (ax < 0.48) & (N[:, 1] > 0.3) & (z > 1.3))[:, None], kc * np.array([0.92, 0.86, 0.84]), kc)
    neck = (z > 1.47) & (z < 1.59) & (ax < 0.07)
    kc = np.where(neck[:, None], kc * (1 - 0.20 * smooth(1.50, 1.585, z))[:, None], kc)
    ear = (ax > 0.07) & (z > 1.62) & (z < 1.71) & (np.abs(y) < 0.03) & (z < 1.75)
    kc = np.where(ear[:, None], kc * np.array([0.98, 0.88, 0.84]), kc)
    kc = np.where((T == TG["nail"])[:, None], np.array([0.83, 0.78, 0.70]), kc)
    # hair: dark, combed flat with a parting on its left, cut short at the nape
    head = (z > 1.585) & (ax < 0.12) & ~hand
    hairline = np.where(y > 0.035, 1.618, np.where(y > -0.035, 1.700, 1.752))
    hair = head & (z > hairline + 0.010 * vnoise(Pt, 60.0, 5))
    comb = 1 - 0.18 * (0.5 + 0.5 * np.sin((x * 0.35 + z) * 2 * math.pi / 0.006))
    hc = np.array([0.19, 0.15, 0.12])[None, :] * comb[:, None]
    parting = hair & (np.abs(x - 0.028) < 0.0025) & (z > 1.76)
    hc = np.where(parting[:, None], skin[None, :] * 0.85, hc)
    kc = np.where(hair[:, None], hc, kc)
    col = np.where(sk[:, None], kc * grain[:, None], col)

    # --- socks, shoes
    # thin dark socks slipped down: a band of bare shin between them and the trousers
    so = T == TG["sock"]
    around = np.arctan2(y, ax - 0.104)
    sock = np.array([0.10, 0.10, 0.12])[None, :] * (1 - 0.15 * (np.sin(around * 14) > 0.6))[:, None]
    top = 0.103 + 0.006 * np.sin(around * 3 + 1.0)
    sock = np.where((np.abs(z - top) < 0.003)[:, None], sock * 1.5, sock)
    bare = (skin[None, :] * 0.92) * (1 - 0.06 * blot[:, None])
    col = np.where(so[:, None], np.where((z > top + 0.003)[:, None], bare, sock), col)
    shoe = T == TG["shoe"]
    sc = np.tile(np.array([0.115, 0.088, 0.075]), (n, 1))
    sc = np.where(((y < -0.12) & (N[:, 2] > 0.3))[:, None], sc * 1.7, sc)                       # polished toe
    sc = np.where(((np.abs(y + 0.115) < 0.003) & (z > 0.02))[:, None], sc * 0.6, sc)             # toe cap seam
    lz = (y < -0.035) & (y > -0.110) & (np.abs(ax - 0.104) < 0.017) & (N[:, 2] > 0.35)
    sc = np.where((lz & (np.abs(np.sin(y * 2 * math.pi / 0.014)) > 0.6))[:, None], np.array([0.05, 0.045, 0.04]), sc)
    sc = np.where(((z > 0.006) & (z < 0.013))[:, None], np.array([0.24, 0.19, 0.14]), sc)        # welt
    sc = np.where((z <= 0.006)[:, None], np.array([0.06, 0.055, 0.05]), sc)                     # sole
    sc = np.where(((z > 0.06) & (N[:, 2] > 0.6))[:, None], np.array([0.05, 0.04, 0.035]), sc)   # inside the opening
    col = np.where(shoe[:, None], sc, col)

    # --- tie: maroon with thin navy diagonal stripes; the knot darker
    ti = is_("tie", "knot")
    stripe = np.sin((x * 1.0 + z) * 2 * math.pi / 0.026) > 0.80
    tcol = np.where(stripe[:, None], np.array([0.20, 0.22, 0.40])[None, :], np.array([0.40, 0.10, 0.13])[None, :])
    tcol = np.where((T == TG["knot"])[:, None], tcol * 0.82, tcol)
    tcol = np.where((ti & (np.abs(N[:, 1]) < 0.5))[:, None], tcol * 0.7, tcol)
    col = np.where(ti[:, None], tcol, col)

    # --- lanyard, clip, badge, pen, the back of the sheet, staples
    la = T == TG["lanyard"]
    dash = np.abs(np.sin((z + y) * 2 * math.pi / 0.030)) > 0.93
    col = np.where(la[:, None], np.where(dash[:, None], np.array([0.36, 0.46, 0.72]), np.array([0.14, 0.26, 0.62])), col)
    col = np.where((T == TG["clip"])[:, None], np.array([0.60, 0.61, 0.63]), col)
    bd = T == TG["badge"]
    if BADGE_FRAME is not None and bd.any():
        bp, ex, ez = (np.array(v) for v in BADGE_FRAME)
        rel = Pt - bp[None, :]
        u = rel @ ex / (BADGE["w"] / 2)       # -1..1 across
        v = rel @ ez / (BADGE["h"] / 2)       # -1..1 up
        facing = N[:, 1] < -0.5
        card = np.tile(np.array([0.92, 0.92, 0.89]), (n, 1))
        card = np.where((v > 0.62)[:, None], np.array([0.16, 0.30, 0.64]), card)                 # header band
        card = np.where(((v > 0.80) & (v < 0.86) & (u > -0.6) & (u < 0.5))[:, None], np.array([0.85, 0.88, 0.94]), card)
        photo = (u > -0.82) & (u < -0.05) & (v > -0.30) & (v < 0.50)
        card = np.where(photo[:, None], np.array([0.55, 0.55, 0.54]), card)                     # a grey square, no face
        card = np.where((photo & (np.abs(u + 0.43) < 0.20) & (np.abs(v - 0.06) < 0.24))[:, None], np.array([0.47, 0.47, 0.46]), card)
        lines = (u > 0.10) & (u < 0.86) & (v > -0.30) & (v < 0.50) & (np.abs(np.sin(v * math.pi * 4.2)) > 0.75)
        card = np.where(lines[:, None], np.array([0.30, 0.30, 0.32]), card)
        bars = (v < -0.55) & (v > -0.86) & (np.abs(u) < 0.75) & (np.sin(u * 61.0) * np.sin(u * 23.0) > 0.1)
        card = np.where(bars[:, None], np.array([0.15, 0.15, 0.16]), card)
        card = np.where((~facing)[:, None], np.array([0.80, 0.80, 0.78]), card)
        col = np.where(bd[:, None], card, col)
    pen = T == TG["pen"]
    col = np.where(pen[:, None], np.where((z > 1.296)[:, None], np.array([0.62, 0.63, 0.66]), np.array([0.12, 0.20, 0.55])), col)
    col = np.where((T == TG["paperback"])[:, None], np.array([0.86, 0.85, 0.81]), col)
    col = np.where((T == TG["staple"])[:, None], np.array([0.42, 0.43, 0.46]), col)
    return np.clip(col, 0.04, 1.0)


def sample(ob, slot, px):
    """Rasterise every triangle of one material into UV space: where each texel sits on the body
    (position, normal) and the tag of its face."""
    me = ob.data
    me.calc_loop_triangles()
    uvl = me.uv_layers[0].data
    tags = [0] * len(me.polygons)
    me.attributes["tag"].data.foreach_get("value", tags)
    pos = np.zeros((px, px, 3))
    nrm = np.zeros((px, px, 3))
    tag = np.zeros((px, px), np.int32)
    hit = np.zeros((px, px), bool)
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
    print(f"[build] {ob.name} slot {slot}: {px}x{px}, {hit.mean() * 100:.0f}% of texels on the surface")
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
    """arr: rows bottom-up (Blender's order), RGB 0..1 as stored in the PNG"""
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


def setup_material(mat, img):
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.9
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.15
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])


# ============================ THE SAMPLE PHOTOCOPY ============================
def drawn_face():
    """A crewmate's face as a player might draw it on the 32 x 32 screen (rows top-down): two eyes that
    do not quite match, brows, a nose, a mouth, a scribble of hair. Only a sample: the game copies the
    real drawings."""
    S = 32
    img = np.tile(np.array([0xb8, 0xcc, 0xbd]) / 255.0, (S, S, 1))
    ink = np.array([0x14, 0x16, 0x1a]) / 255.0
    red = np.array([0xd0, 0x20, 0x2c]) / 255.0

    def dot(x, y, c=ink):
        if 0 <= x < S and 0 <= y < S:
            img[int(y), int(x)] = c

    def line(x0, y0, x1, y1, c=ink):
        n = int(max(abs(x1 - x0), abs(y1 - y0)) * 2) + 1
        for i in range(n + 1):
            t = i / n
            dot(round(x0 + (x1 - x0) * t), round(y0 + (y1 - y0) * t), c)

    def ring(cx, cy, r):
        for i in range(48):
            a = i / 48 * 2 * math.pi
            dot(round(cx + r * math.cos(a)), round(cy + r * math.sin(a) * 1.1))
    ring(10, 13, 3.2)
    ring(22, 12, 2.8)
    for dx, dy in ((0, 0), (1, 0), (0, 1), (1, 1)):
        dot(10 + dx, 13 + dy)
        dot(22 + dx, 12 + dy)
    line(6, 8, 13, 8)
    line(19, 7, 25, 8)
    line(16, 13, 15, 19)
    line(15, 19, 18, 19)
    pts = [(9, 24), (12, 25), (16, 25), (20, 24), (23, 23)]
    for a, b in zip(pts, pts[1:]):
        line(*a, *b)
    for x0 in range(3, 29, 2):
        line(x0, 3, x0 + 1, 0)
    line(2, 4, 2, 14)
    line(29, 4, 29, 13)
    return img


def photocopy(src, seed=7):
    """client/temp_view.gd photocopy(), in numpy: grey, high contrast, a little skewed and wobbly, smeared
    down the page, toner specks, a drum streak, the lid's shadow. Returns rows top-down."""
    rng = np.random.default_rng(seed)
    lum = src @ np.array([0.2126, 0.7152, 0.0722])
    sh, sw = lum.shape
    w, h = PAGE
    fx, fy, fw, fh = FACE_RECT
    ang = math.radians(rng.uniform(-3.5, 3.5))
    wob = rng.uniform(0, 2 * math.pi)
    cx, cy = fx + fw / 2, fy + fh / 2
    X, Y = np.meshgrid(np.arange(w) + 0.5, np.arange(h) + 0.5)
    qx, qy = X - cx, Y - cy
    rx = qx * math.cos(ang) - qy * math.sin(ang)
    ry = qx * math.sin(ang) + qy * math.cos(ang)
    rx = rx + 1.4 * np.sin((Y - 0.5) * 0.42 + wob)
    u, v = rx / fw + 0.5, ry / fh + 0.5
    inside = (u >= 0) & (u <= 1) & (v >= 0) & (v <= 1)
    px_, py_ = np.clip(u * sw - 0.5, 0, sw - 1), np.clip(v * sh - 0.5, 0, sh - 1)
    x0, y0 = np.floor(px_).astype(int), np.floor(py_).astype(int)
    x1, y1 = np.minimum(x0 + 1, sw - 1), np.minimum(y0 + 1, sh - 1)
    tx, ty = px_ - x0, py_ - y0
    l = (lum[y0, x0] * (1 - tx) + lum[y0, x1] * tx) * (1 - ty) + (lum[y1, x0] * (1 - tx) + lum[y1, x1] * tx) * ty
    d = 1 - smooth(0.30, 0.70, l)
    edge = np.minimum(np.minimum(u, 1 - u), np.minimum(v, 1 - v))
    d = np.maximum(d, 0.07 + 0.4 * (1 - smooth(0.0, 0.03, edge)))
    dens = np.where(inside, d, 0.0)
    right = rng.random() < 0.5
    for xx in range(w):
        f = xx / (w - 1)
        k = 0.50 + (0.88 - 0.50) * (f if right else 1 - f)
        carry = 0.0
        for yy in range(h):
            carry = max(dens[yy, xx], carry * k)
            dens[yy, xx] = max(dens[yy, xx], carry * 0.78)
    streak = rng.integers(14, w - 14)
    lid = rng.uniform(3.0, 7.0)
    vv = smooth(0.26, 0.60, dens) * 0.9 + dens * 0.1
    vv = vv + rng.random((h, w)) * 0.06
    vv = vv + (rng.random((h, w)) < 0.012) * 0.65
    yy = np.arange(h)[:, None]
    vv = vv + ((np.arange(w)[None, :] == streak) & (np.mod(yy * 0.11, 1.0) < 0.85)) * 0.3
    vv = vv + 0.55 * (1 - smooth(0.0, lid, np.arange(w)[None, :].astype(float)))
    vv = vv + 0.35 * (1 - smooth(0.0, lid * 0.6, yy.astype(float)))
    vv = np.clip(vv, 0, 1)
    return PAPER[None, None, :] * (1 - vv[..., None]) + TONER[None, None, :] * vv[..., None]


# ============================ PROPS ============================
def loft(m, sections, mat, tag, cap0=True, cap1=True):
    """rings (lists of points, same count) joined in order, ends capped with a fan to their centre"""
    ids = [[m.v(p) for p in sec] for sec in sections]
    k = len(sections[0])
    for a, b in zip(ids, ids[1:]):
        for i in range(k):
            m.f([a[i], a[(i + 1) % k], b[(i + 1) % k], b[i]], mat, tag)
    for ring_, on in ((ids[0], cap0), (ids[-1], cap1)):
        if on:
            c = m.v(sum((m.co[i] for i in ring_), Vector()) / k)
            for i in range(k):
                m.f([ring_[i], ring_[(i + 1) % k], c], mat, tag)
    return ids


def section(y, w, z0, z1, round_top=True):
    """a 6-point cross-section at y: flat bottom, sides, a rounded top"""
    if round_top:
        return [(-w, y, z0), (w, y, z0), (w, y, z1 - (z1 - z0) * 0.25), (w * 0.55, y, z1), (-w * 0.55, y, z1),
                (-w, y, z1 - (z1 - z0) * 0.25)]
    return [(-w, y, z0), (w, y, z0), (w, y, z1), (w * 0.5, y, z1), (-w * 0.5, y, z1), (-w, y, z1)]


def build_stapler():
    """A desk stapler, 16 cm long: a base with a rounded nose and a metal anvil, a hinge block at the
    back, and the top arm (magazine under a curved cover with a metal strip). Origin at the grip."""
    m = Mesh()
    base = [section(0.078, 0.019, 0.0, 0.009, False), section(0.030, 0.020, 0.0, 0.010, False),
            section(-0.060, 0.020, 0.0, 0.010, False), section(-0.082, 0.016, 0.0, 0.009, False),
            section(-0.090, 0.010, 0.0, 0.007, False)]
    loft(m, base, 0, "plastic")
    m.box((0, -0.068, 0.0105), (0.010, 0, 0), (0, 0.010, 0), (0, 0, 0.0008), 0, "metal")
    m.box((0, 0.068, 0.020), (0.014, 0, 0), (0, 0.010, 0), (0, 0, 0.011), 0, "plastic")
    arm = [section(0.076, 0.016, 0.016, 0.040), section(0.040, 0.017, 0.016, 0.044),
           section(-0.020, 0.017, 0.016, 0.043), section(-0.066, 0.016, 0.015, 0.038),
           section(-0.084, 0.013, 0.016, 0.032), section(-0.090, 0.008, 0.019, 0.028)]
    loft(m, arm, 0, "plastic")
    m.box((0, -0.010, 0.0445), (0.0075, 0, 0), (0, 0.055, 0), (0, 0, 0.0008), 0, "metal")
    for i in range(len(m.co)):
        m.co[i] -= Vector((0, -0.005, 0.028))
    return m


def build_notes():
    """A pad of 76 mm sticky notes, 12 mm of sheets, the top one written on and lifting at its free edge.
    Origin at the middle of the pad."""
    m = Mesh()
    s, t = 0.038, 0.006
    m.box((0, 0, 0), (s, 0, 0), (0, s, 0), (0, 0, t), 0, "pad")
    pts, faces, uvs = [], [], []
    n = 4
    for j in range(n + 1):
        for i in range(n + 1):
            u, v = i / n, j / n
            lift = 0.007 * (1 - v) ** 2.2 + 0.002 * (1 - v) * math.sin(u * math.pi)
            pts.append(Vector((-s + 2 * s * u, -s + 2 * s * v, t + 0.0004 + lift)))
    for j in range(n):
        for i in range(n):
            a = j * (n + 1) + i
            faces.append([a, a + 1, a + n + 2, a + n + 1])
    m.solid(pts, faces, lambda p: (0, 0, 1), 0.0003, 0, "padtop")
    return m


def stapler_colour(Pt, N, T):
    plastic = np.array([0.12, 0.12, 0.13]) * (1 + 0.5 * np.clip(N[:, 2], 0, 1) * 0.4)[:, None]
    metal = np.array([0.66, 0.67, 0.70]) * (0.85 + 0.15 * np.clip(N[:, 2], 0, 1))[:, None]
    c = np.where((T == TG["metal"])[:, None], metal, plastic)
    return np.clip(c, 0.04, 1)


def notes_colour(Pt, N, T):
    x, y, z = Pt[:, 0], Pt[:, 1], Pt[:, 2]
    pad = np.tile(np.array([0.95, 0.82, 0.22]), (len(x), 1))
    side = np.abs(N[:, 2]) < 0.5
    pad = np.where((side & (np.sin(z * 2 * math.pi / 0.0015) > 0.3))[:, None], pad * 0.86, pad)
    pad = np.where((N[:, 2] < -0.5)[:, None], pad * 0.9, pad)
    top = (T == TG["padtop"]) & (N[:, 2] > 0.3)
    tc = np.tile(np.array([1.0, 0.91, 0.42]), (len(x), 1))
    # handwriting: three lines of scrawl in blue-black biro, the first one a name, underlined
    for k, (yc, x0, x1) in enumerate(((0.020, -0.030, 0.008), (0.004, -0.030, 0.028), (-0.011, -0.030, 0.018))):
        wav = np.sin(x * 900.0 + k) * 0.0022 + np.sin(x * 310.0) * 0.0012
        ink = (np.abs(y - yc - wav) < 0.0011) & (x > x0) & (x < x1) & (np.sin(x * 420.0 + k * 2) > -0.6)
        tc = np.where(ink[:, None], np.array([0.12, 0.13, 0.26]), tc)
    tc = np.where(((np.abs(y - 0.0145) < 0.0007) & (x > -0.030) & (x < 0.010))[:, None], np.array([0.12, 0.13, 0.26]), tc)
    c = np.where(top[:, None], tc, pad)
    c = np.where(((T == TG["padtop"]) & (N[:, 2] <= 0.3))[:, None], np.array([0.92, 0.80, 0.30]), c)
    return np.clip(c, 0.04, 1)


def prop_object(m, name, mat_name, px, colour_fn, path_png):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(c) for c in m.co], [], m.faces)
    me.update()
    attr = me.attributes.new("tag", "INT", "FACE")
    attr.data.foreach_set("value", [TG[t] for t in m.tag])
    me.uv_layers.new(name="UVMap")
    mat = bpy.data.materials.new(mat_name)
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    face_out(me)
    for p in me.polygons:
        p.use_smooth = False
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(50.0), island_margin=0.03, area_weight=0.0, correct_aspect=True)
    bpy.ops.uv.pack_islands(rotate=True, margin=0.03)
    bpy.ops.object.mode_set(mode="OBJECT")
    img = save_image(name, shade(sample(ob, 0, px), colour_fn), path_png)
    setup_material(mat, img)
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    vs = np.array([v.co for v in me.vertices])
    print(f"[build] {name}: {tris} triangles, size {np.ptp(vs[:, 0]) * 100:.1f} x {np.ptp(vs[:, 1]) * 100:.1f} x {np.ptp(vs[:, 2]) * 100:.1f} cm")
    return ob


# ============================ CHECKS ============================
def islands(me):
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    seen, out = set(), []
    for f in bm.faces:
        if f.index in seen:
            continue
        stack, isl = [f], []
        seen.add(f.index)
        while stack:
            g_ = stack.pop()
            isl.append(g_)
            for e in g_.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index)
                        stack.append(h)
        edges = {e for g_ in isl for e in g_.edges}
        nm = sum(1 for e in edges if len(e.link_faces) != 2)
        tris = sum(len(g_.verts) - 2 for g_ in isl)
        out.append((tris, nm))
    bm.free()
    return out


def report(ob, body_vcount):
    me = ob.data
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    vs = np.array([v.co for v in me.vertices])
    isl = sorted(islands(me), reverse=True)
    body = np.array([me.vertices[i].co for i in range(body_vcount)])
    kd = KDTree(len(body))
    for i, v in enumerate(body):
        kd.insert(v, i)
    kd.balance()
    errs = np.array([kd.find((-v[0], v[1], v[2]))[2] for v in body])
    print(f"[build] Temp: verts={len(vs)} faces={len(me.polygons)} tris={tris}; body {isl[0][0]} tris,"
          f" {len(isl) - 1} shells; non-manifold edges: body {isl[0][1]}, shells {sum(n for _, n in isl[1:])}")
    print(f"[build] size x {vs[:, 0].min():.3f}..{vs[:, 0].max():.3f} y {vs[:, 1].min():.3f}..{vs[:, 1].max():.3f}"
          f" z {vs[:, 2].min():.3f}..{vs[:, 2].max():.3f} m; body mirror error: {np.median(errs) * 1000:.3f} mm median,"
          f" {(errs > 0.0005).sum()} vertices off (the watch)")
    return tris


# ============================ MAIN ============================
def export_glb(ob, path):
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
                              export_apply=True, export_animations=False, export_skins=False)
    print("[build] exported", os.path.relpath(path, ROOT), os.path.getsize(path), "bytes")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=HERE)
    args = ap.parse_args(argv)
    out = args.out
    os.makedirs(out, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.unit_settings.system = "METRIC"
    scn.unit_settings.scale_length = 1.0
    for mn in MATS:
        bpy.data.materials.new(mn)

    body = make_object(build_body(), "Temp")
    nbody = len(body.data.vertices)
    tree, tbm = body_bvh(body)
    # the collar first: the lanyard runs over it
    sm = Mesh()
    build_collar(sm, tree)
    col_ob = make_object(sm, "collar")
    bm2 = bmesh.new()
    bm2.from_mesh(body.data)
    bm2.from_mesh(col_ob.data)
    bmesh.ops.triangulate(bm2, faces=bm2.faces)
    bm2.normal_update()
    tree2 = BVHTree.FromBMesh(bm2)
    sm = Mesh()
    build_tie(sm, tree)
    build_lanyard(sm, tree2)
    build_pen(sm, tree)
    build_sheet(sm, tree)
    shells = make_object(sm, "shells")
    bpy.ops.object.select_all(action="DESELECT")
    for o in (col_ob, shells, body):
        o.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()
    ob = body
    unwrap(ob)
    report(ob, nbody)

    body_png = os.path.join(out, "temp_body.png")
    img = save_image("temp_body", shade(sample(ob, BODY, P["body_px"]), body_colour), body_png)
    face = photocopy(drawn_face())
    sheet_png = os.path.join(out, "temp_face_sheet.png")
    simg = save_image("temp_face_sheet", face[::-1], sheet_png)
    setup_material(bpy.data.materials["temp_body"], img)
    setup_material(bpy.data.materials["temp_face_sheet"], simg)
    ob.data.attributes.remove(ob.data.attributes["tag"])
    export_glb(ob, os.path.join(out, "temp_tpose.glb"))
    ob.hide_set(True)

    st = prop_object(build_stapler(), "temp_stapler", "temp_stapler", P["prop_px"], stapler_colour,
                     os.path.join(out, "temp_stapler.png"))
    st.data.attributes.remove(st.data.attributes["tag"])
    export_glb(st, os.path.join(out, "temp_stapler.glb"))
    st.hide_set(True)
    nt = prop_object(build_notes(), "temp_notes", "temp_notes", P["notes_px"], notes_colour,
                     os.path.join(out, "temp_notes.png"))
    nt.data.attributes.remove(nt.data.attributes["tag"])
    export_glb(nt, os.path.join(out, "temp_notes.glb"))


if __name__ == "__main__":
    main()
