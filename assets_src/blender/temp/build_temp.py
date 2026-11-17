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
# Narrow, sloping shoulders, a soft belly over the belt, a flat seat, and a rounded upper back: years
# bent over a desk, so the side view is a curve even standing straight.
KEYS = [
    (0.800, [(-0.156, -0.052), (-0.094, -0.088), (-0.030, -0.082)], [(-0.156, 0.058), (-0.094, 0.100), (-0.030, 0.086)], 0.0),
    (0.900, [(-0.166, -0.060), (-0.104, -0.096), (-0.034, -0.104)], [(-0.166, 0.060), (-0.104, 0.104), (-0.034, 0.090)], 0.0),
    (0.985, [(-0.161, -0.058), (-0.104, -0.100), (-0.034, -0.112)], [(-0.158, 0.055), (-0.104, 0.082), (-0.034, 0.072)], 0.0),
    (1.060, [(-0.158, -0.058), (-0.106, -0.102), (-0.036, -0.116)], [(-0.156, 0.054), (-0.104, 0.080), (-0.036, 0.070)], 0.0),
    (1.160, [(-0.154, -0.056), (-0.106, -0.098), (-0.038, -0.109)], [(-0.154, 0.055), (-0.106, 0.086), (-0.038, 0.078)], 0.0),
    (1.250, [(-0.158, -0.054), (-0.112, -0.094), (-0.040, -0.101)], [(-0.160, 0.064), (-0.112, 0.104), (-0.040, 0.098)], 0.0),
    (1.330, [(-0.157, -0.055), (-0.113, -0.091), (-0.040, -0.096)], [(-0.158, 0.066), (-0.110, 0.106), (-0.040, 0.100)], 0.0),
    (1.385, [(-0.155, -0.057), (-0.108, -0.086), (-0.042, -0.090)], [(-0.155, 0.064), (-0.104, 0.098), (-0.042, 0.092)], None),
]
# rows actually built: z, how far the row is pushed out (the belt, the shirt bloused over it), and how far
# on the side where the shirt tail has come out of the trousers (TAIL), which hangs over the belt
TORSO_Z = [(0.800, 0.0, 0.0), (0.860, 0.0, 0.0), (0.876, 0.0, 0.012), (0.890, 0.0, 0.012), (0.905, 0.0, 0.012),
           (0.920, 0.0, 0.013), (0.937, 0.0, 0.013), (0.955, 0.0, 0.013), (0.958, 0.006, 0.014),
           (0.979, 0.006, 0.014), (1.000, 0.006, 0.015), (1.003, 0.0, 0.015),
           (1.030, 0.010, 0.017), (1.090, 0.004, 0.009), (1.170, 0.0, 0.002), (1.250, 0.0, 0.0), (1.290, 0.0, 0.0),
           (1.330, 0.0, 0.0), (1.385, 0.0, 0.0)]
BELT = (0.955, 1.003)
# Half the shirt tail is out: on its left (+X) it hangs loose over the belt down to TAIL["hem"]; on the
# right it is tucked in under the belt. Between, the hem is pulled up diagonally across the belt, so the
# belt runs all the way round, hidden under the loose tail. Below TAIL["top"] a ring of the torso belongs
# to the shirt where it is above hem_z(), otherwise to the belt or the trousers.
TAIL = dict(x0=-0.085, x1=0.075, hem=0.889, top=1.003, wave=0.008)
ARM_ROOT_Z = 1.330
POCKET_ROWS = (1.170, 1.250)        # the breast pocket: left chest, these two bands, front column x2..x1
SHOULDER = dict(x=-0.155, y=0.057, z=1.430, zmid=1.436)
CROTCH = (-0.030, 0.006, 0.772)

A10 = [-144, -108, -72, -36, 0, 36, 72, 108, 144, 180]   # neck ring angles (x = cos, y = sin; -90 = front)
A12 = [-162, -126, -90, -54, -18, 0, 18, 54, 90, 126, 162, 180]
# neck and head rings: rx, ry front, ry back, centre y, z front, z back. An ordinary neck (the one wrong
# thing is the arms) with the pit of the throat, an Adam's apple and the two neck tendons; the head rows
# ("H") are scaled by HS about HZ0 and lowered by HDZ.
HEADR = [
    ("N0", 0.060, 0.055, 0.055, 0.000, 1.462, 1.476),   # base of the neck = top of the torso (10 sides)
    ("N1", 0.055, 0.050, 0.052, 0.004, 1.493, 1.506),   # top of the shirt's neckband (12 sides from here)
    ("N2", 0.052, 0.047, 0.050, 0.006, 1.516, 1.531),   # Adam's apple
    ("N3", 0.051, 0.047, 0.050, 0.006, 1.538, 1.556),
    ("N4", 0.053, 0.050, 0.052, 0.006, 1.556, 1.574),   # under the jaw
    ("H1", 0.056, 0.072, 0.062, 0.000, 1.588, 1.612),   # jaw and chin (a narrow face: the sheet reaches round it)
    ("H2", 0.063, 0.082, 0.078, 0.000, 1.625, 1.638),
    ("H3", 0.066, 0.088, 0.089, 0.000, 1.662, 1.665),   # cheekbones
    ("H4", 0.068, 0.090, 0.096, 0.000, 1.702, 1.698),   # brow; tops of the ears
    ("H5", 0.068, 0.086, 0.097, 0.000, 1.738, 1.734),
    ("H6", 0.060, 0.074, 0.087, 0.000, 1.770, 1.766),
    ("H7", 0.040, 0.047, 0.058, 0.000, 1.791, 1.789),
]
HEAD_TOP_Z = 1.800
HS, HZ0, HDZ = 1.05, 1.588, -0.020
NECK_PUSH = {  # (row, angle): outward push (m): the throat's pit, the Adam's apple, the tendons
    ("N1", -90): -0.004, ("N2", -90): 0.009, ("N3", -90): 0.003,
    ("N1", -54): 0.004, ("N1", -126): 0.004, ("N2", -54): 0.005, ("N2", -126): 0.005,
    ("N3", -18): 0.004, ("N3", -162): 0.004, ("N4", -18): 0.003, ("N4", -162): 0.003}
NOSE = {"H2": 0.011, "H3": 0.006, "H4": 0.003}   # a nose and brow under the paper (front vertex, before HS)

# Arm rings (left arm; the right is mirrored): x, centre z, half depth (y), half height up, down.
# Short sleeve to mid upper arm (a hem that flares and steps in), then bare arms that are too long: the
# forearm is 7 cm longer than it should be, so the hands hang to just above the knees. The forearm swells
# below the elbow and flattens toward the wrist; the wrist bone stands out on the little-finger side.
ARM = [
    (0.172, 1.383, 0.059, 0.055, 0.050),   # 1 deltoid cap
    (0.205, 1.382, 0.058, 0.054, 0.050),   # 2
    (0.250, 1.381, 0.056, 0.052, 0.050),   # 3
    (0.300, 1.380, 0.058, 0.054, 0.053),   # 4 sleeve opening out to the hem
    (0.318, 1.380, 0.059, 0.055, 0.054),   # 5 hem edge
    (0.320, 1.380, 0.041, 0.039, 0.039),   # 6 under the hem: skin from here
    (0.345, 1.381, 0.042, 0.041, 0.038),   # 7 biceps
    (0.405, 1.380, 0.037, 0.035, 0.034),   # 8 above the elbow
    (0.440, 1.380, 0.036, 0.034, 0.034),   # 9 elbow
    (0.468, 1.380, 0.039, 0.036, 0.035),   # 10 below the elbow; the point of the elbow pushed back
    (0.515, 1.381, 0.043, 0.040, 0.035),   # 11 the forearm's swell, high and to the thumb side
    (0.585, 1.380, 0.039, 0.035, 0.032),   # 12
    (0.660, 1.380, 0.033, 0.027, 0.026),   # 13
    (0.735, 1.380, 0.029, 0.021, 0.021),   # 14 flattening toward the wrist
    (0.762, 1.380, 0.0285, 0.0205, 0.0205),  # 15 watch (left wrist only, pushed out)
    (0.776, 1.380, 0.0280, 0.0200, 0.0200),  # 16 watch
    (0.792, 1.380, 0.0270, 0.0190, 0.0190),  # 17 wrist
]
SLEEVE_BANDS = 5            # bands before this are shirt sleeve; the next is the hem's underside
ELBOW = 10
SWELL = 11                  # the swell sits toward the front (thumb side) and top
WRIST = 17                  # the wrist bone: the back (little-finger side) pushed out
WATCH = (15, 16)
WATCH_X = (0.757, 0.781)
ARM_ANG = [-135, 180, 135, 90, 45, 0, -45, -90]  # (y = cos, z = sin): a vertex on top, as the hands tutorial says

# The hand (left; the right is mirrored), palm down, fingers straight and fanned, thumb forward.
HAND_Z = 1.380
FINGERS = [  # name, width, length, fan (degrees, + toward the back), knuckle x offset
    ("index", 0.0180, 0.087, -7.0, -0.003),
    ("middle", 0.0185, 0.095, 0.0, 0.000),
    ("ring", 0.0175, 0.090, 7.0, -0.003),
    ("pinky", 0.0150, 0.072, 14.0, -0.011),
]
FGAP = 0.004
PALM = [  # x, y scale, top half-thickness, bottom half-thickness
    (0.810, 0.82, 0.0185, 0.0165),
    (0.848, 0.95, 0.0175, 0.0150),     # the meat of the palm
    (0.884, 1.00, 0.0135, 0.0115),     # knuckles: the finger roots
]
# finger rings: (fraction of length, half width, half height); the tip is blunt
FRING = [(0.09, 0.0090, 0.0088), (0.30, 0.0083, 0.0080), (0.45, 0.0082, 0.0078), (0.55, 0.0086, 0.0080),
         (0.74, 0.0076, 0.0071), (0.86, 0.0072, 0.0066), (0.96, 0.0058, 0.0052)]
FINGER_SCALE = 1.0
THUMB_DIR = (0.50, -0.78, -0.36)
THUMB = [(0.012, 0.0135, 0.0120), (0.030, 0.0112, 0.0102), (0.040, 0.0114, 0.0102), (0.056, 0.0102, 0.0092),
         (0.066, 0.0096, 0.0086), (0.075, 0.0074, 0.0064)]
THUMB_LEN = 0.080

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
    (0.072, -0.104, 0.014, 0.038, 0.046, 0.048),   # shoe opening
    (0.045, -0.104, 0.012, 0.041, 0.056, 0.054),
    (0.000, -0.104, 0.010, 0.042, 0.058, 0.055),   # sole
]
TROUSER_BANDS = 11          # bands before this are trousers (the last of them the hem's underside)
SOCK_BANDS = 12
LEG_ANG = [-135, -90, -45, 0, 45, 90, 135, 180]
# office shoes, slim, the toe springing up off the floor
TOE = [dict(y=-0.115, ztop=0.046, zbot=0.0, sx=1.0), dict(y=-0.162, ztop=0.037, zbot=0.004, sx=0.88),
       dict(y=-0.186, ztop=0.027, zbot=0.011, sx=0.55)]

# The collar: a stand up the neck, a fold, a fall down over the shirt, two points at the front. The top
# button is undone, so it stands open (a wide gap, the points splayed), and its left point has curled up.
COLLAR = dict(gap=27.0, cols=20, stand=0.032, fall_out=0.026, fall_drop=0.038, point_drop=0.026, thick=0.0025,
              point_in=0.95, curl=0.012)
# The open neck: the shirt's front is painted open in a V from the collar down to here (skin showing).
OPEN_V = dict(bottom=1.405, top=1.47, half=0.034)
# The tie, pulled loose: the knot hangs at the bottom of the open V, its two loop ends run up either side
# of the neck under the collar, and the blade lies 4 mm off the shirt, askew to the left, its V tip short of
# the belt.
TIE = dict(knot_top=1.402, knot_bot=1.365, knot_w=(0.038, 0.024), knot_d=0.016, knot_x=-0.006, knot_tilt=-9.0,
           rows=[(1.367, 0.015), (1.330, 0.019), (1.260, 0.026), (1.190, 0.031), (1.130, 0.034), (1.090, 0.036)],
           askew=0.026, lift=0.004, thick=0.004,
           loop=[(0.014, -0.0, 1.402), (0.026, 0.0, 1.430), (0.036, 0.0, 1.458), (0.046, 0.0, 1.482)], loop_w=0.011)
# The lanyard (a blue ribbon round the neck over the collar) and the ID badge, hung to the right.
LANYARD_PATH = [(-0.050, -0.11, 1.318), (-0.020, -0.11, 1.370), (0.020, -0.10, 1.420), (0.048, -0.075, 1.460),
                (0.064, -0.040, 1.484), (0.068, 0.000, 1.494), (0.060, 0.040, 1.498), (0.032, 0.066, 1.498),
                (0.000, 0.074, 1.498), (-0.032, 0.066, 1.498), (-0.060, 0.040, 1.498), (-0.068, 0.000, 1.494),
                (-0.064, -0.040, 1.484), (-0.056, -0.075, 1.458), (-0.054, -0.100, 1.410), (-0.054, -0.11, 1.360),
                (-0.056, -0.11, 1.318)]
LANYARD = dict(width=0.011, lift=0.0035, thick=0.0015, step=0.022)
BADGE = dict(x=-0.060, top=1.300, w=0.054, h=0.086, t=0.004, tilt=-6.0, clip=0.018)
# The A4 sheet, worn: draped over the head like cloth (springs that keep it A4, pulled onto the head and
# never into it), from over the crown, down the face (over the brow, the nose and the chin), and tucked
# under the jaw; 21 cm round reaches from cheek to cheek, just in front of the ears. Then creased (an old
# fold across the middle, a crumple down one side, faceted), its free edges lifting a little, stapled at
# the corners and tied on with string round the back of the head, taped where the string meets the paper.
SHEET_W, SHEET_H = 0.210, 0.297
SHEET_NU, SHEET_NV = 12, 18
SHEET_OFF = 0.0055               # how far the paper stands off the skin and hair
SHEET_NOSE = (0.165, 1.618)      # the page's arc length (from the top) that lies on the tip of the nose, and its height
SHEET_THICK = 0.0012
STAPLE_INSET = 0.014
SHEET_CREASES = [  # (u0, v0, u1, v1, height m, half width in uv): a tent along a line across the page
    (0.0, 0.52, 1.0, 0.47, -0.0040, 0.06),     # folded in half once, long ago
    (0.62, 0.0, 0.88, 0.40, 0.0030, 0.05),     # a crumple down the right
    (0.05, 0.70, 0.30, 1.0, 0.0025, 0.05),     # and one in the bottom left
    (0.30, 0.0, 0.10, 0.22, -0.0020, 0.04)]
SHEET_LIFT = 0.0045              # free edges between the staples stand off this much at most
STRING = dict(v=0.30, w=0.0020, thick=0.0012, lift=0.0015, sag=0.016)   # round the back at the page's v (from the top), slack
TAPE = dict(du=0.11, dv=0.07)    # a strip of masking tape at each side over the string's end
# the sample photocopy on the sheet (client/temp_view.gd's page, 120 x 170 with the face drawn in
# FACE_RECT), made PAGE_K times finer so the copied lines have no pixel steps close up
PAGE = (120, 170)
PAGE_K = 4
FACE_RECT = (9, 26, 102, 102)
PAPER = np.array([0.97, 0.965, 0.94])
TONER = np.array([0.07, 0.07, 0.08])

# Props. Each in its own file; Blender space as above.
# STAPLER: origin at the grip (the middle of the top arm), the striking end toward -Y, top up (+Z).
# NOTES: origin at the middle of the pad, sticky edge toward +Y, writing up (+Z).

TAGS = ["shirt", "sleeve_in", "pocket", "belt", "trousers", "trouser_in", "skin", "nail", "sock", "shoe",
        "collar", "tie", "knot", "lanyard", "clip", "badge", "paperback", "staple", "pen", "sheet",
        "plastic", "metal", "pad", "padtop", "shoe_in", "tail", "string", "tape", "base"]
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


def head_pt(a_deg, row, extra=0.0, features=False):
    """a point of a neck or head ring; `features` adds the throat's anatomy and the nose"""
    name, rx, ryf, ryb, cy, zf, zb = row
    c, s = math.cos(math.radians(a_deg)), math.sin(math.radians(a_deg))
    k = sup(c, s)
    ry = ryf if s < 0 else ryb
    if features:
        extra += NECK_PUSH.get((name, a_deg), 0.0)
        if a_deg == -90:
            extra += NOSE.get(name, 0.0)
    if name[0] == "H":
        rx, ry, extra = rx * HS, ry * HS, extra * HS
        zf, zb = hz(zf), hz(zb)
    x, y = (rx + extra) * c * k, cy + (ry + extra) * s * k
    z = zb + (zf - zb) * (1 - s) / 2
    return (x, y, z)


def hz(z):
    """a head height after the head is scaled and lowered"""
    return HZ0 + (z - HZ0) * HS + HDZ


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


def tail_w(x):
    """0 where the shirt is tucked in (its right), 1 where its tail is out (its left)"""
    t = np.clip((np.asarray(x) - TAIL["x0"]) / (TAIL["x1"] - TAIL["x0"]), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def hem_z(x, y):
    """the height of the shirt's hem: the top of the belt where tucked, hanging below it where loose, pulled
    up diagonally between, with a couple of soft folds in it"""
    w = tail_w(x)
    a = np.arctan2(np.asarray(y), np.asarray(x))
    return TAIL["top"] - (TAIL["top"] - TAIL["hem"]) * w + TAIL["wave"] * w * np.sin(a * 3 + 1.0)


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
        sc = w / 0.018 * FINGER_SCALE
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
    zs = [r[0] for r in TORSO_Z]
    ri = {round(z, 4): i for i, z in enumerate(zs)}
    rA = ri[ARM_ROOT_Z]

    def pushed(x, y, z, grow, tail):
        if z <= TAIL["top"] + 1e-6:     # the loose tail stands off the belt and trousers above its hem
            h = float(hem_z(x, y))
            s = min(1.0, max(0.0, (z - (h - 0.012)) / 0.016))
            g = max(grow, tail * s * s * (3 - 2 * s))
        else:
            g = grow + (tail - grow) * float(tail_w(x))
        d = Vector((x, y * 1.6)).normalized()
        return (x + d.x * g, y + d.y * g, z)

    # ---- torso rings: j 0..5 front x0..x5, 6 (x5, mid), 7..12 back x5..x0, 13 (x0, mid)
    T = []
    for z, grow, tail in TORSO_Z:
        fr, bk, midy = torso_row(z, 0.0)
        ring = [None] * 14
        front = fr + [(-x, y) for x, y in reversed(fr)]
        back = bk + [(-x, y) for x, y in reversed(bk)]
        for i, (x, y) in enumerate(front):
            ring[i] = m.v(pushed(x, y, z, grow, tail))
        for i, (x, y) in enumerate(back):
            ring[12 - i] = m.v(pushed(x, y, z, grow, tail))
        if midy is not None:
            xs = fr[0][0] - 0.004
            ring[13] = m.v(pushed(xs, midy, z, grow, tail))
            ring[6] = m.v(pushed(-xs, midy, z, grow, tail))
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
            q = [T[r][j], T[r][j2], T[r + 1][j2], T[r + 1][j]]
            ft = tag
            cq = sum((m.co[v] for v in q), Vector()) / 4
            if z1 <= TAIL["top"] + 1e-6 and z0 >= 0.86 - 1e-6 and cq.z > hem_z(cq.x, cq.y):
                ft = "tail"                                   # the loose shirt tail over the belt
            tband[(r, j)] = m.f(q, BODY, ft)
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
                if n == SWELL:             # the forearm's swell, toward the thumb side and the top
                    yy += 0.004 * min(0.0, c)
                    zz += 0.003 * max(0.0, s)
                if n == WRIST and c > 0.9:  # the wrist bone on the little-finger side
                    yy += 0.004
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
                  ("sock" if i < SOCK_BANDS else ("shoe_in" if i == SOCK_BANDS else "shoe"))
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
                               st["ztop"] if top else st["zbot"]))
            m.extrude(fids, tp)

    # ---- neck and head
    # the neck: the 10-sided base ring bridges to 12-sided rings (so there is a vertex at the front for
    # the Adam's apple and either side of it for the tendons); the shirt's neckband is the first band
    nrows = [r for r in HEADR[1:] if r[0][0] == "N"]
    nrings = [[m.v(head_pt(a, row, features=True)) for a in A12] for row in nrows]
    bridge(m, neck0, A10, nrings[0], A12, BODY, "shirt")
    for i in range(len(nrings) - 1):
        for k in range(12):
            k2 = (k + 1) % 12
            m.f([nrings[i][k], nrings[i][k2], nrings[i + 1][k2], nrings[i + 1][k]], BODY, "skin")
    hrows = [r for r in HEADR if r[0][0] == "H"]
    H = [[m.v(head_pt(a, row, features=True)) for a in A12] for row in hrows]
    for k in range(12):
        k2 = (k + 1) % 12
        m.f([nrings[-1][k], nrings[-1][k2], H[0][k2], H[0][k]], BODY, "skin")
    hb = {}
    for i in range(len(H) - 1):
        for k in range(12):
            k2 = (k + 1) % 12
            hb[(i, k)] = m.f([H[i][k], H[i][k2], H[i + 1][k2], H[i + 1][k]], BODY, "skin")
    R = H[-1]
    M1 = m.v((0, -0.020 * HS, hz(HEAD_TOP_Z)))
    M2 = m.v((0, 0.026 * HS, hz(HEAD_TOP_Z)))
    for q in ([R[2], R[3], R[4], M1], [M1, R[4], R[5], M2], [M2, R[5], R[6], R[7]], [M2, R[7], R[8]],
              [R[2], R[1], R[0], M1], [M1, R[0], R[11], M2], [M2, R[11], R[10], R[9]], [M2, R[9], R[8]]):
        m.f(q, BODY, "skin")
    # ears: small and flat, a 2 x 2 patch of each side of the head (H2 to H4) pulled out a little and back,
    # under hair grown long over them
    for ks in ((4, 5), (10, 11)):
        fids = [hb[(i, k)] for i in (1, 2) for k in ks]
        for step, (sc, out, back) in enumerate(((0.80, 0.006, 0.010),)):
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
        if end == 0:          # the collar points: down, splayed open
            fall = Vector((fall.x * C["point_in"], fall.y, fall.z - C["point_drop"]))
        elif end == 1:
            fall = Vector((fall.x * 0.97, fall.y, fall.z - C["point_drop"] * 0.35))
        fall = onto(tree, fall, 0.003)[0]      # the fall lies on the shirt...
        if end == 0:
            fall = fall + Vector((0, -0.004, 0))
            if fall.x > 0:                     # ...except the left point, which has curled up off it
                fall = fall + Vector((0.002, -C["curl"], C["curl"] * 0.6))
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
    # knot: a tapered block pulled down to the bottom of the open neck, a little to the right and tilted,
    # its back on the shirt front
    zt, zb = t["knot_top"], t["knot_bot"]
    wt, wb = t["knot_w"]
    kc = Vector((t["knot_x"], 0, (zt + zb) / 2))
    tl = math.radians(t["knot_tilt"])
    ids = []
    for z, w in ((zb, wb), (zt, wt)):
        for sx in (-1, 1):
            lx, lz = sx * w / 2, z - kc.z
            x = kc.x + lx * math.cos(tl) - lz * math.sin(tl)
            zz = kc.z + lx * math.sin(tl) + lz * math.cos(tl)
            yb, _ = ray_front(tree, x, zz, 0.001)
            for dy in (0.0, -t["knot_d"]):
                ids.append(m.v((x, yb.y + dy, zz)))
    # ids: z0: (-x,back) (-x,front) (+x,back) (+x,front); z1 same
    q = [(0, 2, 3, 1), (4, 5, 7, 6), (1, 3, 7, 5), (0, 4, 6, 2), (0, 1, 5, 4), (2, 6, 7, 3)]
    for f in q:
        m.f([ids[i] for i in f], BODY, "knot")
    # the loop round the neck: from the knot's top corners up either side of the open neck, under the collar
    for sgn in (-1, 1):
        path = [ray_front(tree, t["knot_x"] + sgn * x, z, 0.003)[0] for x, _, z in t["loop"]]
        lp, lf = [], []
        for i, p in enumerate(path):
            tg = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
            sd = tg.cross(Vector((0, -1, 0))).normalized()
            lp += [p - sd * t["loop_w"] / 2, p + sd * t["loop_w"] / 2]
        for i in range(len(path) - 1):
            lf.append([2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2])
        m.solid(lp, lf, lambda p: (0, -1, 0), 0.003, BODY, "tie")
    # blade: three columns (edge, middle, edge) down the shirt, then a V tip
    rows = t["rows"]
    pts, faces = [], []
    z_top = rows[0][0]
    for z, w in rows:
        dx = t["knot_x"] + t["askew"] * (z_top - z) / (z_top - rows[-1][0])
        for c, bulge in ((-1, 0.0), (0, 0.0025), (1, 0.0)):
            p, n = ray_front(tree, dx + c * w, z, t["lift"] + bulge)
            pts.append(p)
    zl, wl = rows[-1]
    dx = t["knot_x"] + t["askew"]
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


def sheet_drape(tree):
    """The A4 sheet draped over the head like cloth: springs keep every edge of the grid at its A4 length
    (and skip-one springs give it a paper's stiffness), the head pulls it in and never lets it through, the
    page's nose row is held at the nose. Returns the grid (rows from the top of the page, columns from its
    left as seen from the front)."""
    nu, nv = SHEET_NU, SHEET_NV
    W, H = SHEET_W, SHEET_H
    s_nose, z_nose = SHEET_NOSE
    c = Vector((0, -0.01, z_nose))
    P = []
    for j in range(nv + 1):
        s = H * j / nv
        el = (s_nose - s) / 0.105
        for i in range(nu + 1):
            az = math.radians(-90) + (i / nu - 0.5) * W / 0.105
            r = 0.15
            P.append(c + Vector((r * math.cos(el) * math.cos(az), r * math.cos(el) * math.sin(az), r * math.sin(el))))
    P = np.array([tuple(p) for p in P])
    idx = lambda i, j: j * (nu + 1) + i
    hu, hv = W / nu, H / nv
    springs = []
    for j in range(nv + 1):
        for i in range(nu + 1):
            if i < nu:
                springs.append((idx(i, j), idx(i + 1, j), hu, 1.0))
            if j < nv:
                springs.append((idx(i, j), idx(i, j + 1), hv, 1.0))
            if i < nu and j < nv:
                springs.append((idx(i, j), idx(i + 1, j + 1), math.hypot(hu, hv), 0.7))
                springs.append((idx(i + 1, j), idx(i, j + 1), math.hypot(hu, hv), 0.7))
            if i < nu - 1:
                springs.append((idx(i, j), idx(i + 2, j), 2 * hu, 0.35))
            if j < nv - 1:
                springs.append((idx(i, j), idx(i, j + 2), 2 * hv, 0.35))
    A = np.array([s[0] for s in springs])
    B = np.array([s[1] for s in springs])
    Lr = np.array([s[2] for s in springs])
    K = np.array([s[3] for s in springs])
    pin = idx(nu // 2, round(s_nose / H * nv))
    mirror = np.array([idx(nu - i, j) for j in range(nv + 1) for i in range(nu + 1)])
    for it in range(160):
        for _ in range(4):
            d = P[B] - P[A]
            ln = np.linalg.norm(d, axis=1)
            c_ = d * (((ln - Lr) / np.maximum(ln, 1e-9)) * 0.5 * K)[:, None]
            corr = np.zeros_like(P)
            cnt = np.zeros(len(P))
            np.add.at(corr, A, c_)
            np.add.at(corr, B, -c_)
            np.add.at(cnt, A, K)
            np.add.at(cnt, B, K)
            P += corr / np.maximum(cnt, 1e-9)[:, None] * 1.6
        pull = 0.004 if it < 140 else 0.0
        for k in range(len(P)):
            loc, n, _, _ = tree.find_nearest(Vector(P[k]))
            dd = (Vector(P[k]) - loc).dot(n)
            if dd < SHEET_OFF:
                P[k] = tuple(loc + n * SHEET_OFF)
            else:
                P[k] = tuple(Vector(P[k]) - n * min(dd - SHEET_OFF, pull))
        Q = P[mirror] * np.array([-1, 1, 1])
        P = (P + Q) / 2
        P[:, 2] += (z_nose + 0.012 - P[pin, 2]) * 0.5      # the paper's nose row on the nose (it stands off it)
    err = np.abs(np.linalg.norm(P[B] - P[A], axis=1) - Lr)[K == 1.0] / Lr[K == 1.0]
    print(f"[build] sheet draped: edge lengths within {err.max() * 100:.1f}% of A4 (mean {err.mean() * 100:.2f}%)")
    return [Vector(p) for p in P]


def grid_frame(grid, u, v, head_c):
    """a point of the sheet's grid at (u, v from the top), with its outward normal"""
    nu, nv = SHEET_NU, SHEET_NV
    fi, fj = min(max(u, 0.0), 1.0) * nu, min(max(v, 0.0), 1.0) * nv
    i0, j0 = min(int(fi), nu - 1), min(int(fj), nv - 1)
    tu, tv = fi - i0, fj - j0
    g = lambda i, j: grid[j * (nu + 1) + i]
    p = (g(i0, j0) * (1 - tu) + g(i0 + 1, j0) * tu) * (1 - tv) + (g(i0, j0 + 1) * (1 - tu) + g(i0 + 1, j0 + 1) * tu) * tv
    eu = (g(i0 + 1, j0) - g(i0, j0)).normalized()
    ev = (g(i0, j0 + 1) - g(i0, j0)).normalized()
    n = eu.cross(ev).normalized()
    if n.dot(p - head_c) < 0:
        n = -n
    return p, n, eu, ev


def build_sheet(m, tree):
    nu, nv = SHEET_NU, SHEET_NV
    grid = sheet_drape(tree)
    head_c = Vector((0, 0.0, 1.66))
    du, dv = STAPLE_INSET / SHEET_W, STAPLE_INSET / SHEET_H
    staples = [(du, dv), (1 - du, dv), (du, 1 - dv), (1 - du, 1 - dv)]
    # wear: creases (tents along lines across the page), a faint crumple, and the free edges lifting
    # between the staples
    normals = [grid_frame(grid, (k % (nu + 1)) / nu, (k // (nu + 1)) / nv, head_c)[1] for k in range(len(grid))]
    asp = SHEET_W / SHEET_H
    out = []
    for k, p in enumerate(grid):
        u, v = (k % (nu + 1)) / nu, (k // (nu + 1)) / nv
        h = 0.0
        for (u0, v0, u1, v1, height, hw) in SHEET_CREASES:
            a, b, q = Vector((u0 * asp, v0)), Vector((u1 * asp, v1)), Vector((u * asp, v))
            t = max(0.0, min(1.0, (q - a).dot(b - a) / (b - a).length_squared))
            dist = (a + (b - a) * t - q).length
            h += height * max(0.0, 1.0 - dist / hw)
        h += 0.0006 * math.sin(u * 19.0 + v * 7.0) * math.sin(v * 23.0 - u * 5.0)
        edge = max(0.5 * math.exp(-(u / 0.07) ** 2), 0.5 * math.exp(-((1 - u) / 0.07) ** 2),
                   math.exp(-((1 - v) / 0.05) ** 2))         # the top edge stays down on the hair
        near = min(math.hypot((u - cu) * asp, v - cv) for cu, cv in staples)
        h += SHEET_LIFT * edge * (1 - math.exp(-(near / 0.10) ** 2)) * (0.6 + 0.4 * math.sin(u * 11 + v * 17))
        q = clear_of(tree, p + normals[k] * h, 0.004)
        if near < 0.15:                    # stapled down: the corners and round each staple lie on the head
            w = 1.0 - max(0.0, min(1.0, (near - 0.08) / 0.07))
            q = q.lerp(onto(tree, q, 0.004)[0], w * w * (3 - 2 * w))
        out.append(q)
    grid = out
    # the low-poly head can still poke through the middle of a face: push any face whose middle is too
    # close to the head out, with its four corners
    for _ in range(4):
        moved = 0
        for j in range(nv):
            for i in range(nu):
                ids = [j * (nu + 1) + i, j * (nu + 1) + i + 1, (j + 1) * (nu + 1) + i + 1, (j + 1) * (nu + 1) + i]
                cen = sum((grid[q] for q in ids), Vector()) / 4
                loc, nrm, _, _ = tree.find_nearest(cen)
                deficit = 0.0035 - (cen - loc).dot(nrm)
                if deficit > 0:
                    for q in ids:
                        grid[q] = grid[q] + nrm * deficit
                    moved += 1
        if not moved:
            break
    faces, uvs = [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            uvs.append((i / nu, 1.0 - j / nv))
    for j in range(nv):
        for i in range(nu):
            a = j * (nu + 1) + i
            faces.append([a, a + 1, a + nu + 2, a + nu + 1])
    m.solid(grid, faces, lambda p: Vector(p) - head_c, SHEET_THICK, SHEET, "sheet", BODY, "paperback", uvs)
    # staples across each corner, standing just off the paper
    for cu, cv in staples:
        p, n, eu, ev = grid_frame(grid, cu, cv, head_c)
        diag = (eu * (1 if cu < 0.5 else -1) + ev * (1 if cv < 0.5 else -1)).normalized()
        across = diag.cross(n).normalized()
        m.box(p + n * 0.0011, across * 0.0065, diag * 0.0010, n * 0.0006, BODY, "staple")
    # the string: from one side of the sheet round the back of the head to the other, over the hair
    S = STRING
    ends = [grid_frame(grid, 1.0, S["v"], head_c)[0], grid_frame(grid, 0.0, S["v"], head_c)[0]]
    z0 = (ends[0].z + ends[1].z) / 2
    a0 = math.atan2(ends[0].y, ends[0].x)
    a1 = math.atan2(ends[1].y, ends[1].x) + 2 * math.pi
    path = [ends[0]]
    n_ = 18
    for i in range(1, n_):
        a = a0 + (a1 - a0) * i / n_
        z = z0 - S["sag"] * math.sin(math.pi * i / n_)     # slack: it droops round the back of the head
        path.append(onto(tree, Vector((0.2 * math.cos(a), 0.2 * math.sin(a), z)), S["lift"])[0])
    path.append(ends[1])
    pts, fcs = [], []
    for i, p in enumerate(path):
        tg = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
        n = onto(tree, p, 0.0)[1]
        sd = tg.cross(n).normalized()
        pts += [p - sd * S["w"] / 2, p + sd * S["w"] / 2]
    for i in range(len(path) - 1):
        fcs.append([2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2])
    m.solid(pts, fcs, lambda p: onto(tree, p, 0.0)[1], S["thick"], BODY, "string")
    # tied in a knot at the back, its two ends hanging loose down the hair
    knot = path[n_ // 2]
    kn = onto(tree, knot, 0.0)[1]
    side = Vector((0, 0, 1)).cross(kn).normalized()
    m.box(knot + kn * 0.003, side * 0.0045, kn * 0.003, Vector((0, 0, 1)) * 0.0035, BODY, "string")
    for sgn, length in ((-1, 0.034), (1, 0.026)):
        tail = [onto(tree, knot + side * sgn * (0.002 + 0.004 * f) - Vector((0, 0, length * f)), 0.0025)[0]
                for f in (0.0, 0.33, 0.66, 1.0)]
        pts, fcs = [], []
        for i, p in enumerate(tail):
            tg = (tail[min(i + 1, 3)] - tail[max(i - 1, 0)]).normalized()
            n = onto(tree, p, 0.0)[1]
            sd = tg.cross(n).normalized()
            pts += [p - sd * S["w"] / 2, p + sd * S["w"] / 2]
        for i in range(3):
            fcs.append([2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2])
        m.solid(pts, fcs, lambda p: onto(tree, p, 0.0)[1], S["thick"], BODY, "string")
    # masking tape over each end of the string, folded round the paper's edge
    for side_u in (0.0, 1.0):
        pts, fcs = [], []
        us = [side_u + (TAPE["du"] if side_u == 0.0 else -TAPE["du"]) * f for f in (1.0, 0.5, 0.0)]
        vs = [S["v"] - TAPE["dv"] / 2, S["v"], S["v"] + TAPE["dv"] / 2]
        for v in vs:
            for u in us:
                p, n, _, _ = grid_frame(grid, u, v, head_c)
                pts.append(p + n * 0.0009)
        for j in range(2):
            for i in range(2):
                a = j * 3 + i
                fcs.append([a, a + 1, a + 4, a + 3])
        m.solid(pts, fcs, lambda p: Vector(p) - head_c, 0.0004, BODY, "tape")
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


def stain(Pt, cx, cz, radius, seed, ring_only=False):
    """a blotchy coffee mark seen from the front (x, z): 0..1, a ragged edge, darker at the rim where it
    dried; ring_only: the ring a mug leaves"""
    d = np.hypot(Pt[:, 0] - cx, Pt[:, 2] - cz) / radius
    d = d * (1 + 0.30 * (vnoise(Pt, 140.0, seed) - 0.5))
    rim = np.exp(-((d - 0.95) / 0.09) ** 2)
    if ring_only:
        # soaked in: a wide soft rim, broken where the mug was lifted at an angle, a faint wash inside
        ang = np.arctan2(Pt[:, 2] - cz, Pt[:, 0] - cx)
        broken = np.clip(0.35 + 0.65 * np.sin(ang + 0.6) + 0.3 * (vnoise(Pt, 70.0, seed + 1) - 0.5), 0, 1)
        soft = np.exp(-((d - 0.92) / 0.20) ** 2)
        return np.clip(soft * broken * 0.55 + 0.10 * np.clip(1.1 - d, 0, 1), 0, 1)
    inside = np.clip((1.0 - d) / 0.15, 0, 1)
    return np.clip(inside * 0.6 + rim * 0.5, 0, 1)


def body_colour(Pt, N, T):
    x, y, z = Pt[:, 0], Pt[:, 1], Pt[:, 2]
    ax = np.abs(x)
    n = len(x)
    col = np.zeros((n, 3))
    is_ = lambda *names: np.isin(T, [TG[k] for k in names])
    grain = 1 + 0.012 * (vnoise(Pt, 90.0, 9) - 0.5)
    blot = vnoise(Pt, 9.0, 3)
    soft = lambda ph: (0.5 + 0.5 * np.sin(ph)) ** 2
    front = N[:, 1] < -0.35
    # round the waist the hem decides, texel by texel, what is shirt, belt or trousers (so the diagonal
    # hem is a clean line, not the steps of the rings under it)
    hem = hem_z(x, y)
    waist = np.isin(T, [TG["tail"], TG["belt"], TG["trousers"], TG["shirt"]]) & (z > 0.86) & (z < TAIL["top"] + 0.0005) & (ax < 0.21)
    T = np.where(waist, np.where(z > hem, TG["tail"], np.where(z > BELT[0] + 0.002, TG["belt"], TG["trousers"])), T)
    below = np.clip((hem - z) / 0.012, 0, 1) * (z < hem)
    hem_shadow = 1 - 0.5 * np.exp(-((hem - z - 0.004) / 0.008) ** 2) * (z < hem) * (z > 0.85)

    # --- shirt (body, sleeves, pocket, collar, the loose tail): pale blue-white gone dingy and grey
    shirt = is_("shirt", "pocket", "collar", "sleeve_in", "tail")
    sh = np.ones(n)
    sh *= 1 - 0.03 * vnoise(Pt, 14.0, 1)
    # folds: where the right side is tucked in, short pulls down into the belt (front only); the loose tail
    # on the left hangs in long soft creases and is crumpled from being sat on
    tucked = (x < 0.0) & front
    sh *= 1 - 0.13 * band(z, 1.003, 1.08, 0.02) * soft(x * 95 + 1.3) * tucked
    tail = (T == TG["tail"]) | ((T == TG["shirt"]) & (x > 0.0) & (z < 1.06))
    sh *= 1 - 0.12 * tail * soft(np.arctan2(y, x) * 7 + z * 12) * band(z, 0.889, 1.06, 0.02)
    sh *= 1 - 0.08 * band(z, 1.15, 1.32, 0.05) * band(ax, 0.08, 0.16, 0.03) * soft((z + ax * 1.2) * 48) * front
    sh *= 1 - 0.10 * (ax > 0.17) * (N[:, 2] < -0.3) * soft(ax * 70)
    # seams: shoulders, the yoke at the back, sleeve hems, side seams
    sh *= 1 - 0.20 * g(ax - 0.172, 0.004) * (z > 1.30)
    sh *= 1 - 0.16 * (y > 0.03) * g(z - 1.405, 0.004) * (ax < 0.15)
    sh *= 1 - 0.25 * g(ax - 0.309, 0.004) * (z > 1.30)
    sh *= 1 - 0.14 * g(np.abs(y), 0.004) * (ax > 0.14) * (z < 1.33)
    # the tail's hem and the shadow it throws on the trousers is painted below
    sh *= 1 - 0.20 * (T == TG["tail"]) * np.exp(-((z - hem) / 0.005) ** 2)         # the hem's turned edge
    # placket and buttons down the front; the top one undone
    fr_ = front & (z < 1.47) & (z > 1.00) & (ax < 0.15)
    sh *= np.where(fr_ & (np.abs(x - 0.013) < 0.0025) & (z < OPEN_V["bottom"]), 0.84, 1.0)
    bz = np.abs(((z - 1.43) / 0.085) - np.round((z - 1.43) / 0.085)) * 0.085
    button = fr_ & (ax < 0.006) & (bz < 0.0055) & (z < OPEN_V["bottom"] - 0.01)
    sh *= np.where(button, 1.06, 1.0)
    sh *= np.where(button & (ax < 0.002) & (bz < 0.0018), 0.55, 1.0)
    # the pocket: a darker edge, a hem across the top, a shadow inside the opening
    pk = T == TG["pocket"]
    sh *= np.where(pk & (np.abs(N[:, 1]) < 0.6), 0.74, 1.0)
    sh *= np.where(pk & (np.abs(z - 1.282) < 0.004), 0.80, 1.0)
    sh *= np.where((T == TG["shirt"]) & (x > 0.035) & (x < 0.115) & (np.abs(z - 1.293) < 0.004) & (N[:, 1] < -0.3), 0.70, 1.0)
    # crevice shadow: armpits, under the collar, the hem's underside
    d = ((ax - 0.158) / 0.03) ** 2 + ((z - 1.335) / 0.05) ** 2
    sh *= 1 - 0.35 * np.exp(-d)
    sh *= np.where(T == TG["sleeve_in"], 0.62, 1.0)
    sh *= 1 - 0.22 * (T == TG["shirt"]) * g(z - 1.462, 0.012) * (ax < 0.10)
    sh *= 1 - 0.10 * smooth(1.20, 0.95, z) * (T != TG["collar"])          # dingier toward the waist
    c = np.array([0.79, 0.82, 0.83])[None, :] * (sh * grain)[:, None]

    def over(c, w, rgb):
        return c * (1 - w[:, None]) + np.array(rgb)[None, :] * w[:, None]
    # sweat: big yellowed rings under the arms, a band down the middle of the back
    sweat = np.exp(-(((ax - 0.162) / 0.055) ** 2 + ((z - 1.30) / 0.085) ** 2)) * (0.7 + 0.3 * blot)
    c = over(c, 0.55 * sweat, (0.70, 0.64, 0.44))
    c = over(c, 0.30 * (y > 0.04) * g(ax, 0.05) * band(z, 1.12, 1.38, 0.05) * blot, (0.70, 0.66, 0.50))
    # the collar: grime round the fold, creased and grey along its edges
    coll = T == TG["collar"]
    ring_ = coll * np.clip((z - 1.497) / 0.016, 0, 1) * (0.7 + 0.3 * blot)
    c = over(c, 0.60 * ring_, (0.50, 0.46, 0.36))
    c = np.where((coll & (np.abs(N[:, 2]) < 0.2) & (z < 1.50))[:, None], c * 0.85, c)
    c = np.where((coll & (np.sin(np.arctan2(y, x) * 23) > 0.85))[:, None], c * 0.86, c)
    # grime at the sleeve hems and on the loose tail where hands wipe
    c = over(c, 0.25 * band(ax, 0.280, 0.320, 0.01) * (z > 1.30) * blot, (0.55, 0.55, 0.52))
    c = over(c, 0.22 * tail * blot * band(z, 0.889, 0.98, 0.03), (0.55, 0.53, 0.47))
    # coffee: a dribble down from beside the tie with drops below it, and a ring where a mug was set down
    cof = (0.36, 0.22, 0.11)
    dr_x = 0.042 + 0.006 * np.sin(z * 55)
    dribble = front & (z > 1.18) & (z < 1.385) & (np.abs(x - dr_x) < 0.006 * (0.5 + smooth(1.18, 1.37, z)))
    dribble = dribble * (0.6 + 0.4 * vnoise(Pt, 220.0, 7))
    drops = np.zeros(n)
    for cx_, cz_, r_ in ((0.047, 1.165, 0.007), (0.036, 1.145, 0.005), (0.055, 1.120, 0.004), (0.044, 1.395, 0.010)):
        drops = np.maximum(drops, stain(Pt, cx_, cz_, r_, 31) * front)
    ring = stain(Pt, -0.075, 1.115, 0.026, 33, ring_only=True) * front
    c = over(c, np.clip(0.80 * dribble + 0.75 * drops + 0.60 * ring, 0, 0.80), cof)
    # the open neck: the top button undone, the shirt parted in a V down to the knot (skin, in shadow)
    V = OPEN_V
    vopen = (T == TG["shirt"]) & front & (z > V["bottom"]) & (ax < V["half"] * (z - V["bottom"]) / (V["top"] - V["bottom"]))
    skin = np.array([0.84, 0.69, 0.57])
    c = np.where(vopen[:, None], skin[None, :] * (0.78 - 0.12 * smooth(1.44, 1.40, z))[:, None], c)
    vedge = (T == TG["shirt"]) & front & (z > V["bottom"] - 0.004) & \
        (np.abs(ax - V["half"] * (z - V["bottom"]) / (V["top"] - V["bottom"])) < 0.004)
    c = np.where(vedge[:, None], c * 0.72, c)
    col = np.where(shirt[:, None], c, col)

    # --- trousers: charcoal, a pressed crease down each leg, worn shiny at the knees, a fly, pockets
    tr = is_("trousers", "trouser_in")
    s = np.ones(n) * (1 - 0.04 * vnoise(Pt, 10.0, 4))
    leg = z < 0.79
    s *= 1 + 0.10 * leg * g(ax - 0.100, 0.005) * (N[:, 1] < -0.5)
    s *= 1 + 0.12 * leg * g(z - 0.50, 0.04) * np.clip(-N[:, 1], 0, 1)
    s *= 1 - 0.10 * leg * band(z, 0.15, 0.28, 0.04) * soft(z * 70)
    s *= 1 - 0.14 * leg * g(z - 0.47, 0.03) * (N[:, 1] > 0.3)
    fly = (~leg) & (N[:, 1] < -0.3) & (np.abs(x + 0.014) < 0.003) & (z < 0.95) & (z > 0.80)
    s *= np.where(fly, 0.62, 1.0)
    slant = (~leg) & (z > 0.84) & (np.abs((ax - 0.115) - (0.955 - z) * 0.45) < 0.003) & (N[:, 1] < 0.2)
    s *= np.where(slant, 0.62, 1.0)
    s *= 1 - 0.30 * np.exp(-((ax / 0.05) ** 2 + ((z - 0.785) / 0.05) ** 2))
    s *= 1 - 0.22 * leg * g(ax - 0.03, 0.022) * band(z, 0.45, 0.78, 0.08)
    s *= 1 - 0.25 * (~leg) * g(z - 0.952, 0.006)
    s *= hem_shadow                                                     # the loose tail's shadow
    s *= np.where(T == TG["trouser_in"], 0.6, 1.0)
    s *= 1 - 0.18 * leg * smooth(0.30, 0.13, z) * (0.6 + 0.4 * blot)    # dust at the hems
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
    col = np.where(bl[:, None], bc * hem_shadow[:, None], col)

    # --- skin: warm, unhealthy, darker in the creases; the neck in the shadow of the sheet and the collar
    sk = is_("skin", "nail")
    kc = skin[None, :] * (1 - 0.06 * (blot[:, None] - 0.5))
    hand = ax > 0.80
    arm = (ax > 0.32) & ~hand
    # tone: blotchy at two sizes, a ruddier, darker elbow and wrist crease, the tops of the forearms a
    # shade darker (and a little hairy), the undersides paler
    kc = kc * (1 + 0.09 * (vnoise(Pt, 24.0, 14) - 0.5) + 0.05 * (vnoise(Pt, 70.0, 15) - 0.5))[:, None]
    elbow = arm * np.exp(-((ax - 0.452) / 0.022) ** 2) * np.clip(N[:, 1] + 0.3, 0, 1)
    kc = kc * (1 - elbow[:, None] * np.array([0.12, 0.20, 0.22])[None, :])
    kc = kc * (1 - 0.06 * arm * np.clip(N[:, 2], 0, 1))[:, None]
    kc = kc * (1 + 0.05 * arm * np.clip(-N[:, 2], 0, 1))[:, None]
    fuzz = arm & (ax > 0.48) & (N[:, 2] > 0.3) & (vnoise(Pt, 420.0, 16) > 0.72)
    kc = np.where(fuzz[:, None], kc * 0.88, kc)
    kc = kc * (1 - 0.12 * np.exp(-((ax - 0.790) / 0.004) ** 2) * (N[:, 2] < 0))[:, None]
    knuckle = hand * (np.exp(-((ax - 0.886) / 0.007) ** 2) + 0.7 * np.exp(-((ax - 0.931) / 0.005) ** 2)
                      + 0.5 * np.exp(-((ax - 0.960) / 0.004) ** 2)) * np.clip(N[:, 2], 0, 1)
    kc = kc * (1 - np.clip(knuckle, 0, 1)[:, None] * np.array([0.10, 0.18, 0.20])[None, :])
    kc = np.where((arm & (N[:, 2] < -0.3))[:, None], kc * np.array([0.93, 0.90, 0.90]), kc)       # under the arm
    kc = kc * (1 - 0.06 * (arm & (N[:, 1] < -0.2)) * g(ax - 0.452, 0.012))[:, None]      # the crook of the elbow
    vein = arm & (ax > 0.50) & (ax < 0.75) & (N[:, 2] > 0.2) & (np.abs(y + 0.008 + 0.004 * np.sin(ax * 60)) < 0.0018)
    kc = np.where(vein[:, None], kc * np.array([0.90, 0.88, 0.95]), kc)
    kc = np.where((hand & (N[:, 2] < -0.5))[:, None], kc * np.array([1.03, 0.96, 0.93]), kc)
    neck = (z > 1.47) & (z < 1.60) & (ax < 0.07) & ~hand
    kc = np.where(neck[:, None], kc * (1 - 0.30 * smooth(1.52, 1.575, z) - 0.25 * smooth(1.50, 1.47, z))[:, None], kc)
    tendon = neck & (np.abs(ax - (0.030 + 0.6 * (z - 1.47))) < 0.004) & (N[:, 1] < -0.2)
    kc = np.where(tendon[:, None], kc * 1.06, kc)
    ear = (ax > 0.07) & (z > 1.60) & (z < 1.70) & (np.abs(y) < 0.03)
    kc = np.where(ear[:, None], kc * np.array([0.98, 0.86, 0.82]), kc)
    kc = np.where((T == TG["nail"])[:, None], np.array([0.80, 0.72, 0.62]), kc)
    # the watch on the left wrist: a cracked brown strap, a dull steel face on top
    watch = (x > WATCH_X[0]) & (x < WATCH_X[1])
    kc = np.where(watch[:, None], np.array([0.22, 0.15, 0.10]), kc)
    face = watch & (N[:, 2] > 0.55) & (np.abs(y) < 0.016)
    kc = np.where(face[:, None], np.array([0.55, 0.55, 0.52]), kc)
    kc = np.where((face & (np.abs(y) < 0.011) & (x > WATCH_X[0] + 0.004) & (x < WATCH_X[1] - 0.004))[:, None], np.array([0.82, 0.80, 0.72]), kc)
    # hair: dark, greasy, overgrown: down over the ears to the jaw at the sides, down to the collar at the
    # back in a ragged edge, combed flat on top
    head = (z > 1.50) & (ax < 0.12) & ~hand & ~arm
    hairline = np.where(y > 0.030, 1.522 + 0.010 * np.abs(x) / 0.06, np.where(y > -0.028, 1.548, hz(1.752)))
    hl = hairline + 0.008 * vnoise(Pt, 45.0, 5)
    hair_a = head * smooth(hl - 0.007, hl + 0.007, z)        # thinning out to stubble, no hard edge
    comb = 1 - 0.14 * (0.5 + 0.5 * np.sin((x * 0.35 + z) * 2 * math.pi / 0.007))
    hc = np.array([0.17, 0.14, 0.11])[None, :] * comb[:, None] * (1 - 0.15 * (blot[:, None] - 0.5))
    kc = kc * (1 - hair_a[:, None]) + hc * hair_a[:, None]
    col = np.where(sk[:, None], kc * grain[:, None], col)

    # --- socks slipped down below a strip of bare shin, shoes
    so = T == TG["sock"]
    around = np.arctan2(y, ax - 0.104)
    sock = np.array([0.10, 0.10, 0.12])[None, :] * (1 - 0.12 * (np.sin(around * 14) > 0.6))[:, None]
    top = 0.104
    sock = np.where((np.abs(z - top) < 0.004)[:, None], sock * 1.5, sock)
    bare = skin[None, :] * 0.88
    col = np.where(so[:, None], np.where((z > top + 0.004)[:, None], bare, sock), col)
    shoe = T == TG["shoe"]
    sc = np.tile(np.array([0.115, 0.088, 0.075]), (n, 1))
    sc = np.where(((y < -0.12) & (N[:, 2] > 0.3))[:, None], sc * 1.6, sc)                       # toe
    sc = np.where(((np.abs(y + 0.115) < 0.003) & (z > 0.02))[:, None], sc * 0.6, sc)             # toe cap seam
    lz = (y < -0.035) & (y > -0.110) & (np.abs(ax - 0.104) < 0.017) & (N[:, 2] > 0.35)
    sc = np.where((lz & (np.abs(np.sin(y * 2 * math.pi / 0.014)) > 0.6))[:, None], np.array([0.05, 0.045, 0.04]), sc)
    scuff = (x < 0) & (y < -0.13) & (z > 0.014) & (N[:, 2] > 0.2) & (np.abs(np.sin((x * 2 + y) * 300)) > 0.93)  # the right toe scuffed
    sc = np.where(scuff[:, None], np.array([0.36, 0.33, 0.30]), sc)
    sc = np.where(((z > 0.006) & (z < 0.013))[:, None], np.array([0.24, 0.19, 0.14]), sc)        # welt
    sc = np.where((z <= 0.006)[:, None], np.array([0.06, 0.055, 0.05]), sc)                     # sole
    col = np.where(shoe[:, None], sc, col)
    col = np.where((T == TG["shoe_in"])[:, None], np.array([0.06, 0.05, 0.045]), col)

    # --- tie: maroon with thin navy diagonal stripes; the knot darker
    ti = is_("tie", "knot")
    stripe = np.sin((x * 1.0 + z) * 2 * math.pi / 0.026) > 0.80
    tcol = np.where(stripe[:, None], np.array([0.22, 0.23, 0.38])[None, :], np.array([0.38, 0.12, 0.14])[None, :])
    tcol = tcol * (1 - 0.15 * blot)[:, None]                       # worn shiny and grubby
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
    col = np.where((T == TG["paperback"])[:, None], np.array([0.90, 0.89, 0.86]), col)
    col = np.where((T == TG["staple"])[:, None], np.array([0.42, 0.43, 0.46]), col)
    col = np.where((T == TG["string"])[:, None], np.array([0.58, 0.50, 0.36]) * (1 - 0.2 * (np.sin((x + y) * 900) > 0.5))[:, None], col)
    col = np.where((T == TG["tape"])[:, None], np.array([0.80, 0.72, 0.52]) * (1 - 0.08 * blot)[:, None], col)
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


def setup_material(mat, img, interpolation="Closest"):
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Roughness"].default_value = 0.9
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.15
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = interpolation
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])


def export_mixamo(ob, outdir, name="temp"):
    """The Mixamo upload, as assets_src/mixamo/mixamo_export.py makes it (unrigged mesh, FBX with embedded
    textures, front/side/back/top pictures), but straight from the welded mesh: a glb splits every vertex on
    a UV seam or hard edge, and an auto-rigger can tear the skin apart along those seams."""
    os.makedirs(outdir, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    path = os.path.join(outdir, name + ".fbx")
    bpy.ops.export_scene.fbx(filepath=path, use_selection=True, object_types={"MESH"}, path_mode="COPY",
                             embed_textures=True, apply_scale_options="FBX_SCALE_ALL", add_leaf_bones=False,
                             bake_anim=False)
    print("[build] exported", os.path.relpath(path, ROOT), os.path.getsize(path), "bytes,",
          len(ob.data.vertices), "vertices (welded)")
    scn = bpy.context.scene
    eng, res = scn.render.engine, (scn.render.resolution_x, scn.render.resolution_y)
    scn.render.engine = "BLENDER_WORKBENCH"
    scn.display.shading.color_type = "TEXTURE"
    scn.render.resolution_x, scn.render.resolution_y = 600, 800
    vs = [ob.matrix_world @ v.co for v in ob.data.vertices]
    mn = Vector(tuple(min(v[i] for v in vs) for i in range(3)))
    mx_ = Vector(tuple(max(v[i] for v in vs) for i in range(3)))
    c, h = (mn + mx_) / 2, max(mx_ - mn)
    cam_d = bpy.data.cameras.new("mixcam")
    cam_d.type = "ORTHO"
    cam_d.ortho_scale = h * 1.15
    cam = bpy.data.objects.new("mixcam", cam_d)
    scn.collection.objects.link(cam)
    scn.camera = cam
    w = bpy.data.worlds.new("mixw")
    scn.world = w
    w.color = (0.6, 0.6, 0.6)
    for view, d in (("front", Vector((0, -1, 0))), ("side", Vector((1, 0, 0))), ("back", Vector((0, 1, 0))),
                    ("top", Vector((0, 0, 1)))):
        cam.location = c + d * (h * 3)
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        scn.render.filepath = os.path.join(outdir, f"{name}_{view}.png")
        bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)
    scn.render.engine = eng
    scn.render.resolution_x, scn.render.resolution_y = res


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


def blur(a, n=1):
    for _ in range(n):
        a = (a + np.roll(a, 1, 0) + np.roll(a, -1, 0)) / 3
        a = (a + np.roll(a, 1, 1) + np.roll(a, -1, 1)) / 3
    return a


def photocopy(src, seed=7, K=PAGE_K):
    """client/temp_view.gd photocopy(), in numpy, K times finer than the game's 120 x 170 page: grey, high
    contrast, a little skewed and wobbly, smeared down the page, toner specks, a drum streak, the lid's
    shadow. Returns rows top-down."""
    rng = np.random.default_rng(seed)
    lum = src @ np.array([0.2126, 0.7152, 0.0722])
    sh, sw = lum.shape
    w0, h0 = PAGE
    w, h = w0 * K, h0 * K
    fx, fy, fw, fh = FACE_RECT
    ang = math.radians(rng.uniform(-3.5, 3.5))
    wob = rng.uniform(0, 2 * math.pi)
    cx, cy = fx + fw / 2, fy + fh / 2
    X, Y = np.meshgrid((np.arange(w) + 0.5) / K, (np.arange(h) + 0.5) / K)     # in the game page's pixels
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
    f = np.arange(w) / (w - 1)
    kk = (0.50 + (0.88 - 0.50) * (f if right else 1 - f)) ** (1.0 / K)
    carry = np.zeros(w)
    for yy in range(h):
        carry = np.maximum(dens[yy], carry * kk)
        dens[yy] = np.maximum(dens[yy], carry * 0.78)
    streak = rng.integers(14, w0 - 14) * K
    lid = rng.uniform(3.0, 7.0)
    vv = smooth(0.26, 0.60, dens) * 0.9 + dens * 0.1
    up = lambda a: np.kron(a, np.ones((K, K)))
    vv = vv + blur(up(rng.random((h0, w0))), 1) * 0.06
    vv = vv + np.clip(blur(up((rng.random((h0, w0)) < 0.012).astype(float)), 1) * 1.6, 0, 1) * 0.65
    yy = Y
    vv = vv + ((np.abs(np.arange(w)[None, :] - streak) < K * 0.6) & (np.mod((yy - 0.5) * 0.11, 1.0) < 0.85)) * 0.3
    vv = vv + 0.55 * (1 - smooth(0.0, lid, X))
    vv = vv + 0.35 * (1 - smooth(0.0, lid * 0.6, Y))
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
    loft(m, base, 0, "base")
    m.box((0, -0.068, 0.0105), (0.010, 0, 0), (0, 0.010, 0), (0, 0, 0.0008), 0, "metal")
    m.box((0, 0.068, 0.020), (0.014, 0, 0), (0, 0.010, 0), (0, 0, 0.011), 0, "base")
    arm = [section(0.076, 0.016, 0.016, 0.040), section(0.040, 0.017, 0.016, 0.044),
           section(-0.020, 0.017, 0.016, 0.043), section(-0.066, 0.016, 0.015, 0.038),
           section(-0.084, 0.013, 0.016, 0.032), section(-0.090, 0.008, 0.019, 0.028)]
    loft(m, arm, 0, "plastic")
    m.box((0, -0.010, 0.0445), (0.0085, 0, 0), (0, 0.062, 0), (0, 0, 0.0008), 0, "metal")
    m.box((0, -0.0875, 0.0235), (0.0085, 0, 0), (0, 0.0020, 0), (0, 0, 0.005), 0, "metal")   # the nose plate
    for i in range(len(m.co)):
        m.co[i] -= Vector((0, -0.005, 0.028))
    return m


def build_notes():
    """A fat pad of 90 mm sticky notes, 16 mm of sheets, the top one written on and lifting at its free
    edge. Origin at the middle of the pad."""
    m = Mesh()
    s, t = 0.045, 0.008
    m.box((0, 0, 0), (s, 0, 0), (0, s, 0), (0, 0, t), 0, "pad")
    pts, faces, uvs = [], [], []
    n = 4
    for j in range(n + 1):
        for i in range(n + 1):
            u, v = i / n, j / n
            lift = 0.010 * (1 - v) ** 2.2 + 0.003 * (1 - v) * math.sin(u * math.pi)
            pts.append(Vector((-s + 2 * s * u, -s + 2 * s * v, t + 0.0004 + lift)))
    for j in range(n):
        for i in range(n):
            a = j * (n + 1) + i
            faces.append([a, a + 1, a + n + 2, a + n + 1])
    m.solid(pts, faces, lambda p: (0, 0, 1), 0.0003, 0, "padtop")
    return m


def stapler_colour(Pt, N, T):
    """a warm grey office stapler on a black base, chrome strip and nose: readable at a distance"""
    arm = np.array([0.56, 0.54, 0.50]) * (0.85 + 0.25 * np.clip(N[:, 2], 0, 1))[:, None]
    arm = np.where((np.abs(N[:, 0]) > 0.7)[:, None], arm * 0.8, arm)
    base = np.array([0.10, 0.10, 0.11]) * (1 + 0.4 * np.clip(N[:, 2], 0, 1))[:, None]
    metal = np.array([0.78, 0.79, 0.82]) * (0.85 + 0.15 * np.clip(N[:, 2], 0, 1))[:, None]
    c = np.where((T == TG["metal"])[:, None], metal, np.where((T == TG["base"])[:, None], base, arm))
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
    for k, (yc, x0, x1) in enumerate(((0.024, -0.036, 0.010), (0.006, -0.036, 0.034), (-0.012, -0.036, 0.022))):
        wav = np.sin(x * 900.0 + k) * 0.0022 + np.sin(x * 310.0) * 0.0012
        ink = (np.abs(y - yc - wav) < 0.0016) & (x > x0) & (x < x1) & (np.sin(x * 420.0 + k * 2) > -0.6)
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
    ap.add_argument("--no-mixamo", action="store_true", help="skip the FBX and its pictures")
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
    setup_material(bpy.data.materials["temp_face_sheet"], simg, "Linear")
    ob.data.attributes.remove(ob.data.attributes["tag"])
    export_glb(ob, os.path.join(out, "temp_tpose.glb"))
    if not args.no_mixamo:
        export_mixamo(ob, os.path.join(ROOT, "assets_src", "mixamo", "export"))
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
