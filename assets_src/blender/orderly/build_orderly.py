"""Build "the Orderly" (third pass) from an empty scene and export a skinned, animated GLB.

Third pass: the gown is torn (hem in swinging strips, right sleeve half gone, a rip up the right
side, frayed ties, holes), cloth, skin, mask and sewn lids come from the Gemini textures in
public/assets/textures (made by assets_src/textures/generate.mjs), and the grin is thinner.
The material is alpha-tested (glTF MASK) and double-sided so the torn cloth can be cut by texture.

Usage (headless):
  blender.exe --background --factory-startup --python build_orderly.py -- [--out PATH] [--blend PATH]

How to change it:
  * proportions: HEIGHTS / SPINE / TORSO tables and the ARM / LEG / HAND dicts
  * the face: HEAD, SOCKET, MASK, SMILE dicts (the print is drawn in make_atlas)
  * colours: P["colors"]
  * motion: the *_keys() functions at the bottom; poses are dicts of bone -> ops (see set_pose)
Everything is deterministic. Blender space: Z up, the figure faces -Y, +X is its left.
glTF export turns this into +Y up, facing +Z, origin on the floor between the feet.
"""
import bpy, sys, os, math, argparse
import numpy as np
from mathutils import Vector, Quaternion

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TEXDIR = os.path.join(ROOT, "public", "assets", "textures")

# =========================== PARAMETERS ===========================
P = dict(
    name="Orderly",
    scale=1.0,      # uniform scale on everything (set by HEIGHT below)
    height=2.66,    # target standing height (top of cap, idle pose) in metres
    tex_size=512,
    colors=dict(  # sRGB 0..1
        skin=(0.83, 0.79, 0.65), skin_lo=(0.72, 0.66, 0.60), skin_hi=(0.91, 0.89, 0.77),
        bruise=(0.77, 0.68, 0.64), bruise_deep=(0.55, 0.44, 0.44), suture=(0.09, 0.06, 0.06),
        vein=(0.60, 0.67, 0.80),
        gown=(0.69, 0.78, 0.80), gown_line=(0.61, 0.70, 0.73), gown_print=(0.52, 0.62, 0.73),
        band=(0.95, 0.95, 0.92), band_ink=(0.20, 0.30, 0.55),
        stain=(0.50, 0.43, 0.30),
        cap=(0.72, 0.82, 0.90), cap_band=(0.62, 0.72, 0.82),
        mask=(0.68, 0.81, 0.90), mask_line=(0.52, 0.65, 0.76), ink=(0.06, 0.06, 0.08),
        damp=(0.78, 0.76, 0.52), nose=(0.80, 0.82, 0.84),
        tie=(0.86, 0.88, 0.84), nail=(0.58, 0.55, 0.48),
        # third pass: multipliers on the Gemini cloth (washed blue-green) toward dried yellow-grey,
        # and the brown it turns at the hem and round every tear
        gown_tint=(0.88, 0.86, 0.78), hem_mid=(0.58, 0.55, 0.42), hem_dirt=(0.40, 0.33, 0.22), tear_dirt=(0.33, 0.27, 0.19),
        skin_mean=(0.80, 0.76, 0.63),
    ),
    fps=24,
    step=3,  # frames per pose for stepped actions: 24 / 3 = 8 poses a second
)

# Spine centre line: z -> y offset (negative y = forward). Lower back nearly straight, then a hunch.
SPINE = [(1.05, 0.0), (1.34, 0.022), (1.56, 0.024), (1.70, -0.004), (1.84, -0.070), (1.95, -0.150),
         (2.04, -0.225)]
NECK_TOP = (0.0, -0.345, 2.140)      # where the neck meets the skull
HEAD = dict(c=(0.0, -0.385, 2.262), r=(0.084, 0.100, 0.134), jaw=0.84)

# Torso cross-section table: z, half-width, front depth, back depth (from the spine line)
TORSO = [
    (1.08, 0.115, 0.075, 0.085), (1.20, 0.130, 0.080, 0.092), (1.32, 0.122, 0.070, 0.085),
    (1.42, 0.100, 0.046, 0.074), (1.50, 0.104, 0.050, 0.074), (1.57, 0.128, 0.090, 0.078),
    (1.65, 0.140, 0.104, 0.084), (1.75, 0.146, 0.110, 0.090), (1.83, 0.150, 0.102, 0.096),
    (1.89, 0.160, 0.090, 0.096), (1.95, 0.140, 0.078, 0.092), (2.00, 0.098, 0.062, 0.076),
    (2.045, 0.054, 0.044, 0.050),
]
RIBS = dict(z0=1.585, z1=1.965, spacing=0.050, amp=0.011, slope=0.065, sternum=14.0)

ARM = dict(  # left arm points; the right one is mirrored
    shoulder=(0.190, -0.105, 1.900), elbow=(0.232, -0.085, 1.425), wrist=(0.246, -0.165, 0.965),
    knuckle=(0.248, -0.180, 0.790), stretch=1.0,
)
HAND = dict(  # per finger: knuckle y offset, segment lengths, radius, splay (x out, y)
    index=(-0.036, (0.098, 0.076, 0.060), 0.0108, (0.000, -0.012)),
    middle=(-0.012, (0.108, 0.084, 0.066), 0.0112, (0.000, -0.003)),
    ring=(0.012, (0.100, 0.078, 0.062), 0.0106, (0.000, 0.005)),
    little=(0.034, (0.078, 0.062, 0.052), 0.0094, (0.000, 0.014)),
    curl=(0.0, -0.008, -0.024),  # x offset toward the palm at each joint
)
LEG = dict(hip=(0.088, 0.0, 1.16), knee=(0.096, -0.022, 0.625), ankle=(0.100, 0.020, 0.090),
           toe=(0.108, -0.225, 0.018))
SOCKET = dict(lat=16.0, az=31.0, r=0.031, depth=0.009, rim=0.002, skip=0.033,
              right_drop=0.006, right_scale=1.10, right_depth=2.0, stitch_angle=(9.0, -17.0))
MASK = dict(a_half=96.0, lat0=-70.0, lat1=2.0, cols=16, rows=6, scale=1.11, proud=0.010, pleat=0.0075,
            bulge=0.010, tilt=4.0)
CAP = dict(front_lat=34.0, back_lat=-14.0, puff=0.40, lean=(0.035, 0.012, -0.006))
GOWN = dict(top_front=1.875, top_side=2.07, top_left=1.880, hem=0.74, gap=0.022,
            hang_front=1.0, hang_side=0.80, hang_back=0.96, flare=0.030, folds=7, fold_amp=0.014,
            slit_top=64.0, slit_bottom=22.0, slit_to=1.28, sides=34, collar_sag=0.035)
# Third pass: the tears. Angles as in body_r (0 = left, 90 = back, -90 = front, 180 = right).
TEAR = dict(
    rip_a=181.0, rip_top=1.86, rip_bottom=0.60, rip_half=27.0,   # the long rip up the right side
    # hanging strips below the hem: column boundaries (never crossing column 17, where the texture repeats)
    strip_cuts=(0, 2, 4, 6, 8, 10, 12, 14, 17, 19, 21, 23, 25, 27, 29, 31, 34),
    strip_len=(0.05, 0.34), strip_rows=4, strip_overlap=0.07,
    # torn holes: (first column, last column + 1, first row, last row + 1) of gown faces
    holes=((6, 11, 10, 13), (11, 15, 5, 8)),
    sleeve_r=(0.14, 0.30),  # how far down the upper arm the half-gone right sleeve reaches: back, front
)


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


# ============================ BODY FIELD ============================
def rib_bump(a_deg, z):
    """Rib ridges on the ribcage; ribs slope down toward the front. a_deg: 0 = left, 90 = back, -90 = front."""
    s = math.sin(math.radians(a_deg))
    front = max(0.0, -s)
    if abs(a_deg + 90) < RIBS["sternum"]:
        return 0.0
    back_spine = abs(a_deg - 90) < 9
    if back_spine:
        return 0.0
    ze = z + RIBS["slope"] * front
    if ze < RIBS["z0"] - 0.02 or ze > RIBS["z1"] + 0.03 or z > 1.975:
        return 0.0
    env = min(1.0, (ze - RIBS["z0"] + 0.02) / 0.05) * min(1.0, (RIBS["z1"] + 0.03 - ze) / 0.05)
    ph = (ze - RIBS["z0"]) / RIBS["spacing"]
    ridge = max(0.0, math.cos(2 * math.pi * ph)) ** 3
    side_w = 0.55 + 0.45 * abs(math.cos(math.radians(a_deg)))  # strongest on the flanks
    return RIBS["amp"] * env * ridge * side_w


def rib_valley(a_deg, z):
    """0..1, how deep in a gap between ribs this point is (for painted shadow)."""
    s = math.sin(math.radians(a_deg))
    front = max(0.0, -s)
    if abs(a_deg + 90) < RIBS["sternum"] or abs(a_deg - 90) < 9:
        return 0.0
    ze = z + RIBS["slope"] * front
    if ze < RIBS["z0"] or ze > RIBS["z1"] or z > 1.97:
        return 0.0
    ph = (ze - RIBS["z0"]) / RIBS["spacing"]
    return max(0.0, -math.cos(2 * math.pi * ph))


def body_r(a_deg, z):
    """Distance from the spine line to the skin in direction a (degrees) at height z."""
    rx, rf, rb = table(z, TORSO, 1), table(z, TORSO, 2), table(z, TORSO, 3)
    a = math.radians(a_deg)
    c, s = math.cos(a), math.sin(a)
    ry = rb if s > 0 else rf
    r = 1.0 / math.sqrt((c / rx) ** 2 + (s / ry) ** 2)
    r += rib_bump(a_deg, z)
    if s < 0:  # collarbones: a ridge from the notch of the sternum out to each shoulder
        off = abs(a_deg + 90)
        if 9 < off < 72:
            zc = 1.962 + 0.014 * (off - 9) / 63
            r += 0.008 * math.exp(-((z - zc) / 0.011) ** 2) * min(1.0, (off - 9) / 8)
    # third pass: the crest of the hip bone stands out at the sides (it shows through the rip)
    r += 0.011 * math.exp(-((z - 1.255) / 0.035) ** 2) * abs(c) ** 3
    # spine groove and shoulder-blade ridge on the back
    if s > 0:
        r -= 0.006 * max(0.0, 1 - abs(a_deg - 90) / 12) * (1.0 if 1.35 < z < 1.98 else 0.0)
    return r


def body_point(a_deg, z, extra=0.0):
    r = body_r(a_deg, z) + extra
    a = math.radians(a_deg)
    return Vector((r * math.cos(a), spine_y(z) + r * math.sin(a), z))


# ============================ ARMATURE ============================
def mirror_pt(p, side):
    return (p[0] * side, p[1], p[2])


def finger_points(side, name):
    """knuckle, joint1, joint2, tip for one finger of one hand."""
    yoff, segs, rad, (sx, sy) = HAND[name]
    kn = Vector(mirror_pt(ARM["knuckle"], side)) + Vector((0, yoff, 0))
    pts = [kn]
    curl = HAND["curl"]
    z = kn.z
    for i, L in enumerate(segs):
        z -= L
        f = (i + 1) / len(segs)
        pts.append(Vector((kn.x + side * (sx * f + curl[i]), kn.y + sy * f, z)))
    return pts


def thumb_points(side):
    wr = Vector(mirror_pt(ARM["wrist"], side))
    a = wr + Vector((-0.014 * side, -0.034, -0.036))
    b = a + Vector((-0.012 * side, -0.026, -0.066))
    c = b + Vector((-0.012 * side, -0.012, -0.056))
    return [a, b, c]


def bone_table():
    """name -> (head, tail, parent). Order matters: parents first."""
    b = {}
    b["hips"] = ((0, 0, 1.12), (0, spine_y(1.34), 1.34), None)
    b["spine"] = ((0, spine_y(1.34), 1.34), (0, spine_y(1.56), 1.56), "hips")
    b["spine1"] = ((0, spine_y(1.56), 1.56), (0, spine_y(1.76), 1.76), "spine")
    b["spine2"] = ((0, spine_y(1.76), 1.76), (0, spine_y(2.03), 2.03), "spine1")
    nb = (0, spine_y(2.03), 2.03)
    nm = tuple(lerp(nb[i], NECK_TOP[i], 0.5) for i in range(3))
    b["neck"] = (nb, nm, "spine2")
    b["neck1"] = (nm, NECK_TOP, "neck")
    b["head"] = (NECK_TOP, (NECK_TOP[0], NECK_TOP[1], NECK_TOP[2] + 0.25), "neck1")
    for side, sfx in ((1, ".L"), (-1, ".R")):
        sh, el, wr, kn = (mirror_pt(ARM[k], side) for k in ("shoulder", "elbow", "wrist", "knuckle"))
        b["clavicle" + sfx] = ((0.03 * side, spine_y(1.97), 1.97), sh, "spine2")
        b["upperarm" + sfx] = (sh, el, "clavicle" + sfx)
        b["forearm" + sfx] = (el, wr, "upperarm" + sfx)
        b["hand" + sfx] = (wr, kn, "forearm" + sfx)
        fi = finger_points(side, "index")
        fm = finger_points(side, "middle")
        fr = finger_points(side, "ring")
        th = thumb_points(side)
        b["index1" + sfx] = (tuple(fi[0]), tuple(fi[1]), "hand" + sfx)
        b["index2" + sfx] = (tuple(fi[1]), tuple(fi[2]), "index1" + sfx)
        b["index3" + sfx] = (tuple(fi[2]), tuple(fi[3]), "index2" + sfx)
        b["middle1" + sfx] = (tuple(fm[0]), tuple(fm[1]), "hand" + sfx)
        b["middle2" + sfx] = (tuple(fm[1]), tuple(fm[2]), "middle1" + sfx)
        b["middle3" + sfx] = (tuple(fm[2]), tuple(fm[3]), "middle2" + sfx)
        b["ring1" + sfx] = (tuple(fr[0]), tuple(fr[1]), "hand" + sfx)
        b["ring2" + sfx] = (tuple(fr[1]), tuple(fr[3]), "ring1" + sfx)
        b["thumb" + sfx] = (tuple(th[0]), tuple(th[2]), "hand" + sfx)
        hip, knee, ankle, toe = (mirror_pt(LEG[k], side) for k in ("hip", "knee", "ankle", "toe"))
        b["thigh" + sfx] = (hip, knee, "hips")
        b["shin" + sfx] = (knee, ankle, "thigh" + sfx)
        b["foot" + sfx] = (ankle, toe, "shin" + sfx)
    # third pass: cloth bones (new names; the 39 bones above are unchanged). Four hang inside the
    # skirt and carry the hem strips; one hangs from the right sleeve and carries its rag.
    for name, (x, y) in SKIRT_BONES.items():
        b[name] = ((x, y, 1.02), (x * 1.3, y * 1.3, 0.60), "hips")
    sh, el = Vector(mirror_pt(ARM["shoulder"], -1)), Vector(mirror_pt(ARM["elbow"], -1))
    b["sleeve_rag.R"] = (tuple(sh.lerp(el, 0.22)), tuple(sh.lerp(el, 0.62)), "upperarm.R")
    return b


SKIRT_BONES = {"skirt.F.L": (0.075, -0.085), "skirt.F.R": (-0.075, -0.085),
               "skirt.B.L": (0.075, 0.095), "skirt.B.R": (-0.075, 0.095)}


def skirt_bone_for(a_deg):
    """Which skirt bone a direction belongs to (a: 0 = left, 90 = back, -90 / 270 = front)."""
    s, c = math.sin(math.radians(a_deg)), math.cos(math.radians(a_deg))
    return ("skirt.B" if s > 0 else "skirt.F") + (".L" if c > 0 else ".R")


def build_armature(bt):
    arm_data = bpy.data.armatures.new(P["name"] + "_Rig")
    arm = bpy.data.objects.new(P["name"] + "_Rig", arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (h, t, parent) in bt.items():
        eb = arm_data.edit_bones.new(name)
        eb.head, eb.tail = Vector(h) * P["scale"], Vector(t) * P["scale"]
        eb.roll = 0.0
    for name, (h, t, parent) in bt.items():
        if parent:
            arm_data.edit_bones[name].parent = arm_data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


# ============================ MESH KIT ============================
# Atlas regions (u0, v0, u1, v1) on the packed texture
REG = dict(mask=(0.0, 0.5, 0.5, 1.0), gown=(0.5, 0.5, 1.0, 1.0), band=(0.0, 0.0, 0.25, 0.125),
           ink=(0.25, 0.0, 0.375, 0.125), gown_top=(0.5, 0.78, 1.0, 1.0),
           skin=(0.0, 0.25, 0.125, 0.375), skin_lo=(0.125, 0.25, 0.25, 0.375),
           skin_hi=(0.0, 0.375, 0.125, 0.5), bruise=(0.125, 0.375, 0.25, 0.5),
           socket=(0.25, 0.25, 0.5, 0.5),
           cap=(0.5, 0.25, 0.75, 0.5), tie=(0.75, 0.25, 0.875, 0.375), nail=(0.875, 0.25, 1.0, 0.375),
           gown_in=(0.75, 0.375, 1.0, 0.5),
           # third pass, in the space that was free: the torn cloth (alpha), holes and dirty edges
           strips=(0.375, 0.0, 0.875, 0.25), holes=(0.0, 0.125, 0.25, 0.25),
           dirty=(0.875, 0.0, 1.0, 0.125), skin_dk=(0.875, 0.125, 1.0, 0.25))


def ruv(reg, u, v):
    m = 0.04
    u = m + (1 - 2 * m) * min(1.0, max(0.0, u))
    v = m + (1 - 2 * m) * min(1.0, max(0.0, v))
    return (reg[0] + (reg[2] - reg[0]) * u, reg[1] + (reg[3] - reg[1]) * v)


class MeshBuilder:
    def __init__(self):
        self.co, self.w, self.faces, self.uvs = [], [], [], []
        self.smooth, self.sm = False, []

    def vert(self, co, w):
        self.co.append(Vector(co))
        self.w.append(dict(w))
        return len(self.co) - 1

    def face(self, idx, uv, interior=None, outward=None):
        """Orient so the normal points away from `interior` (or along `outward`)."""
        idx, uv = list(idx), list(uv)
        pts = [self.co[i] for i in idx]
        n = Vector((0, 0, 0))
        for a, b in zip(pts, pts[1:] + pts[:1]):
            n += a.cross(b)
        c = sum(pts, Vector()) / len(pts)
        ref = (c - Vector(interior)) if interior is not None else (Vector(outward) if outward is not None else None)
        if ref is not None and n.dot(ref) < 0:
            idx.reverse(); uv.reverse()
        self.faces.append(idx)
        self.uvs.append(uv)
        self.sm.append(self.smooth)


def frame_for(t, ref=None):
    x = Vector(ref) if ref is not None else Vector((1, 0, 0))
    if abs(t.dot(x)) > 0.9:
        x = Vector((0, 1, 0))
    xp = (x - t * x.dot(t)).normalized()
    return xp, t.cross(xp)


def tube(mb, rings, sides, reg, cap0=True, cap1=True, ref=None, reg_fn=None, phase=0.0):
    """rings: list of (center, radius, weights). radius is a number, (rx, ry) or a function of the
    world-space unit direction d -> radius. weights is a dict or a function of position -> dict.
    reg_fn(i, k, center) can pick the atlas region per face."""
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
        r = reg
        for k in range(sides):
            k2 = (k + 1) % sides
            mb.face([tip, idx[end][k], idx[end][k2]],
                    [ruv(r, 0.5, 0.5), ruv(r, k / sides, 0.0), ruv(r, (k + 1) / sides, 0.0)], cs[nb])
    return idx


def lerp_w(z, tab):
    tb = sorted(tab, key=lambda e: e[0])
    if z <= tb[0][0]:
        return dict(tb[0][1])
    for (z0, w0), (z1, w1) in zip(tb, tb[1:]):
        if z <= z1:
            t = (z - z0) / (z1 - z0)
            return {k: w0.get(k, 0) * (1 - t) + w1.get(k, 0) * t for k in set(w0) | set(w1)}
    return dict(tb[-1][1])


SPINE_W = [(1.12, {"hips": 1}), (1.30, {"hips": .6, "spine": .4}), (1.42, {"spine": 1}),
           (1.56, {"spine": .5, "spine1": .5}), (1.70, {"spine1": 1}), (1.80, {"spine1": .4, "spine2": .6}),
           (1.92, {"spine2": 1}), (2.02, {"spine2": .7, "neck": .3}), (2.08, {"neck": 1})]


def torso_weights(p):
    w = lerp_w(p.z, SPINE_W)
    # shoulders follow the clavicles
    ax = abs(p.x)
    if p.z > 1.80 and ax > 0.09:
        t = min(1.0, (ax - 0.09) / 0.07) * min(1.0, (p.z - 1.80) / 0.08)
        sfx = ".L" if p.x > 0 else ".R"
        w = {k: v * (1 - t) for k, v in w.items()}
        w["clavicle" + sfx] = w.get("clavicle" + sfx, 0) + t * 0.75
        w["upperarm" + sfx] = w.get("upperarm" + sfx, 0) + t * 0.25 * min(1.0, (ax - 0.13) / 0.04 if ax > 0.13 else 0)
    if p.z < 1.20:
        t = min(1.0, (1.20 - p.z) / 0.12) * 0.6
        sfx = ".L" if p.x > 0 else ".R"
        w = {k: v * (1 - t) for k, v in w.items()}
        w["thigh" + sfx] = t
    return w


# ============================ BODY PARTS ============================
def torso_zs():
    zs = [1.06, 1.14, 1.22, 1.30, 1.37, 1.43, 1.49, 1.545]
    z = 1.575
    while z < 1.975:
        zs.append(round(z, 4))
        z += RIBS["spacing"] / 4
    zs += [1.985, 1.995, 2.01, 2.025, 2.045]
    return zs


def build_torso(mb):
    sides = 22
    zs = torso_zs()
    rings = []
    for z in zs:
        c = Vector((0, spine_y(z), z))

        def rad(d, z=z, c=c):
            a = math.degrees(math.atan2(d.y, d.x))
            return body_r(a, z)
        rings.append((c, rad, torso_weights))

    def reg_fn(i, k, cen, fc=None):
        a = 360.0 * (k + 0.5) / sides
        a = a if a <= 180 else a - 360
        z = cen.z
        v = rib_valley(a, z)
        # the tops of the shoulders sit just under the paper; where they show, they show as cloth
        if z > 1.84 and not (-135 < a < -45) and abs(a - 90) > 58 and abs(a + 270) > 58:
            return REG["gown_top"]
        if v > 0.6 and z < 1.90:
            return REG["skin_lo"]
        # hollow above the collarbones and the belly under the ribcage
        if -130 < a < -50 and 1.43 < z < 1.56:
            return REG["skin_lo"]
        if 1.22 < z < 1.29 and abs(math.cos(math.radians(a))) > 0.85:
            return REG["skin_hi"]  # the hip crest catches the light
        if 1.14 < z < 1.22 and abs(math.cos(math.radians(a))) > 0.8:
            return REG["skin_lo"]  # and the hollow under it
        return REG["skin"]
    tube(mb, rings, sides, REG["skin"], cap0=True, cap1=False, ref=(1, 0, 0), reg_fn=reg_fn)


def build_spine_knobs(mb):
    """Vertebrae standing out along the curved back."""
    z = 1.36
    while z < 2.05:
        p = body_point(90, z)
        t = Vector((0, spine_y(z + 0.01) - spine_y(z - 0.01), 0.02)).normalized()
        n = Vector((0, 1, 0))
        n = (n - t * n.dot(t)).normalized()
        size = 0.010 + 0.004 * (1 - abs(z - 1.85) / 0.5)
        w = lerp_w(z, SPINE_W)
        tube(mb, [(p - n * 0.006, size, w), (p + n * 0.006, size * 0.8, w)], 4, REG["skin_hi"],
             cap0=False, cap1=True, ref=t)
        z += 0.034


def build_collarbones(mb):
    for side, sfx in ((1, ".L"), (-1, ".R")):
        sh = Vector(mirror_pt(ARM["shoulder"], side))
        pts = []
        for i in range(6):
            t = i / 5
            a = lerp(-90 + 9 * side * -1 * -1, -90 + 62 * side * -1 * -1, t)  # sweep from sternum to shoulder
            a = -90 + side * lerp(10, 66, t)
            z = lerp(1.962, 1.975, t) + 0.010 * math.sin(math.pi * t)
            p = body_point(a, z, extra=0.001 + 0.002 * math.sin(math.pi * t))
            pts.append(p)
        C = "clavicle" + sfx

        def w(p, C=C):
            t = min(1.0, abs(p.x) / 0.15)
            return {"spine2": 1 - t, C: t}
        rings = [(p, 0.0075 if 0 < i < 5 else 0.006, w) for i, p in enumerate(pts)]
        tube(mb, rings, 5, REG["skin_hi"], cap0=True, cap1=True)


def build_scapulae(mb):
    """Winged shoulder blades: a plate whose inner edge lifts off the back."""
    for side, sfx in ((1, ".L"), (-1, ".R")):
        C = "clavicle" + sfx
        grid = []
        for j, z in enumerate((1.93, 1.83, 1.72)):
            row = []
            for i, a in enumerate((90 - side * 18, 90 - side * 36, 90 - side * 56)):
                lift = (0.010 if i == 0 else 0.005 if i == 1 else 0.0) * (1.0 if j < 2 else 0.7)
                if j == 2 and i == 2:
                    continue
                p = body_point(a, z, extra=lift + 0.002)
                row.append(mb.vert(p, {"spine2": 0.6, C: 0.4}))
            grid.append(row)
        c = Vector((0, spine_y(1.83), 1.83))
        r = REG["skin"]
        for j in range(2):
            for i in range(2):
                if j + 1 == 2 and i + 1 >= len(grid[2]):
                    mb.face([grid[j][i], grid[j][i + 1], grid[j + 1][i]],
                            [ruv(r, 0, 0), ruv(r, 1, 0), ruv(r, 0, 1)], c)
                    continue
                mb.face([grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]],
                        [ruv(r, 0, 0), ruv(r, 1, 0), ruv(r, 1, 1), ruv(r, 0, 1)], c)
        # lip under the inner edge so it reads as lifted
        for j in range(2):
            a0, a1 = grid[j][0], grid[j + 1][0]
            b0 = mb.vert(body_point(90 - side * 16, (1.93, 1.83, 1.72)[j], -0.004), {"spine2": 1})
            b1 = mb.vert(body_point(90 - side * 16, (1.93, 1.83, 1.72)[j + 1], -0.004), {"spine2": 1})
            mb.face([a0, a1, b1, b0], [ruv(REG["skin_lo"], 0, 0), ruv(REG["skin_lo"], 1, 0),
                                       ruv(REG["skin_lo"], 1, 1), ruv(REG["skin_lo"], 0, 1)], c)


def build_neck(mb):
    nb = Vector((0, spine_y(2.02), 2.02))
    top = Vector(NECK_TOP) + Vector((0, -0.004, 0.03))
    rings = []
    for i in range(6):
        t = i / 5
        c = nb.lerp(top, t)

        def rad(d, t=t):
            r = lerp(0.056, 0.037, min(1, t * 1.6))
            # tendons at the front sides, an Adam's apple
            r += 0.006 * max(0.0, -d.y) ** 6 * math.sin(math.pi * min(1, t * 1.3))
            r += 0.004 * abs(d.x) ** 8
            return r
        w = {"spine2": 1} if i == 0 else {"neck": 1} if t < 0.45 else {"neck": 0.4, "neck1": 0.6} if t < 0.7 else {"neck1": 1} if t < 0.95 else {"neck1": .5, "head": .5}
        rings.append((c, rad, w))
    mb.smooth = True
    tube(mb, rings, 12, REG["skin"], cap0=False, cap1=False)
    mb.smooth = False


def head_point(az_deg, lat_deg, s=1.0, extra=0.0):
    """az 0 = straight forward (-Y), positive toward the figure's left (+X)."""
    hc = Vector(HEAD["c"])
    rx, ry, rz = HEAD["r"]
    a, la = math.radians(az_deg), math.radians(lat_deg)
    jaw = 1.0 if lat_deg > 0 else lerp(1.0, HEAD["jaw"], min(1.0, -lat_deg / 60))
    back = 1.0 + 0.10 * max(0.0, -math.cos(a)) * max(0.0, math.cos(la)) * (1 if lat_deg > -20 else 0.4)
    d = Vector((rx * jaw * math.cos(la) * math.sin(a), -ry * back * math.cos(la) * math.cos(a), rz * math.sin(la)))
    # flatten the brow where the eyes should be
    flat = max(0.0, math.cos(a)) ** 4 * math.exp(-((lat_deg - SOCKET["lat"]) / 18) ** 2)
    d.y += 0.010 * flat
    p = hc + d * s
    if extra:
        p += (p - hc).normalized() * extra
    return p


def socket_centres():
    out = []
    for side in (1, -1):
        drop = SOCKET["right_drop"] if side < 0 else 0.0
        lat = SOCKET["lat"] - math.degrees(drop / HEAD["r"][2])
        c = head_point(side * SOCKET["az"], lat)
        n = (head_point(side * SOCKET["az"], lat, extra=0.01) - c).normalized()
        n = (n + Vector((0, -0.6, 0))).normalized()
        sc = SOCKET["right_scale"] if side < 0 else 1.0
        out.append((side, c, n, SOCKET["r"] * sc))
    return out


def build_head(mb):
    hc = Vector(HEAD["c"])
    segs = 18
    lats = [-90, -72, -56, -42, -28, -14, -2, 8, 17, 26, 36, 48, 62, 76, 90]
    socks = socket_centres()
    grid = {}
    W = {"head": 1}
    for lat in lats:
        if abs(lat) == 90:
            grid[(0, lat)] = mb.vert(head_point(0, lat), W)
            continue
        for k in range(segs):
            az = -180 + 360 * k / segs
            grid[(k, lat)] = mb.vert(head_point(az, lat), W)
    for li in range(len(lats) - 1):
        l0, l1 = lats[li], lats[li + 1]
        for k in range(segs):
            k2 = (k + 1) % segs
            if l0 == -90:
                ids = [grid[(0, l0)], grid[(k2, l1)], grid[(k, l1)]]
            elif l1 == 90:
                ids = [grid[(k, l0)], grid[(k2, l0)], grid[(0, l1)]]
            else:
                ids = [grid[(k, l0)], grid[(k2, l0)], grid[(k2, l1)], grid[(k, l1)]]
            cen = sum((mb.co[i] for i in ids), Vector()) / len(ids)
            if any((cen - c).length < SOCKET["skip"] * (r / SOCKET["r"]) for _, c, _, r in socks):
                continue
            u0, u1 = k / segs, (k + 1) / segs
            v0, v1 = li / (len(lats) - 1), (li + 1) / (len(lats) - 1)
            uvs = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)][:len(ids)]
            reg = REG["skin"]
            # shadowed hollows round the sockets and under the cheekbones
            near = min((cen - c).length for _, c, _, _ in socks)
            if near < 0.0:
                reg = REG["bruise"]
            mb.face(ids, [ruv(reg, u, v) for u, v in uvs], hc)
    # sockets: concentric loops stepping into the skull, sealed with skin and sewn shut
    for side, c, n, r in socks:
        xp = Vector((1, 0, 0))
        xp = (xp - n * xp.dot(n)).normalized()
        yp = n.cross(xp)
        if yp.z < 0:
            yp = -yp
        dep = SOCKET["depth"] * (SOCKET["right_depth"] if side < 0 else 1.0)
        # third pass: no disc. A soft swollen rim, then skin sinking into the socket, puckered into
        # radial folds that all pull toward one seam (the lids sewn together), deepest along the seam.
        loops = [(1.45, -0.001), (1.22, -0.003), (1.00, -dep * 0.60),
                 (0.78, -dep * 0.95), (0.55, -dep * 1.15), (0.30, -dep * 1.25), (0.0, -dep * 1.45)]
        rot = math.radians(SOCKET["stitch_angle"][0 if side > 0 else 1])
        sides = 16
        rows = []
        for li, (rs, d0) in enumerate(loops[:-1]):
            row = []
            for k in range(sides):
                a = 2 * math.pi * k / sides
                lx, ly = rs * math.cos(a), rs * math.sin(a) * 0.78  # a little wider than tall
                if 0 < rs < 1.1:
                    # puckering: the inner rings are drawn in toward the seam (ly shrinks) and
                    # folded (depth alternates), more strongly the closer to the seam
                    ly *= 0.70 + 0.30 * rs
                    fold = 0.0022 * (1.0 if k % 2 else -0.6) * (1.1 - rs)
                    seam = -0.0045 * math.exp(-(ly / 0.22) ** 2) * (1.0 - rs * 0.6)
                    dd = d0 + fold + seam
                else:
                    dd = d0
                # stitches rotate with the texture, so rotate the pucker the same way
                rx = lx * math.cos(rot) - ly * math.sin(rot)
                ry = lx * math.sin(rot) + ly * math.cos(rot)
                p = c + xp * (rx * r) + yp * (ry * r) + n * dd
                row.append((mb.vert(p, W), (lx, ly)))
            rows.append(row)
        ctr = mb.vert(c + n * loops[-1][1], W)

        def suv(l):
            # the geometry is already turned by `rot`, so the decal's seam follows the pucker
            return ruv(REG["socket"], 0.5 + l[0] / 3.0, 0.5 + l[1] / (3.0 * 0.78))
        inside = c - n * 0.2
        for j in range(len(rows) - 1):
            for k in range(sides):
                k2 = (k + 1) % sides
                q = [rows[j][k], rows[j][k2], rows[j + 1][k2], rows[j + 1][k]]
                mb.face([v for v, _ in q], [suv(l) for _, l in q], inside)
        for k in range(sides):
            k2 = (k + 1) % sides
            q = [rows[-1][k], rows[-1][k2]]
            mb.face([q[0][0], q[1][0], ctr], [suv(q[0][1]), suv(q[1][1]), suv((0, 0))], inside)


def build_cap(mb):
    """A paper bouffant surgical cap: an elastic edge snug on the head, then puffed out wider than the
    skull, crinkled, and slumped a little to one side."""
    hc = Vector(HEAD["c"])
    segs, rows = 20, 7
    lean = Vector(CAP["lean"])
    ring_ids = []
    for j in range(rows):
        t = j / (rows - 1)
        ids = []
        for k in range(segs):
            az = -180 + 360 * k / segs
            front = 0.5 + 0.5 * math.cos(math.radians(az))
            edge = lerp(CAP["back_lat"], CAP["front_lat"], front)
            lat = lerp(edge, 80, t)
            if j == 0:
                p = head_point(az, lat, s=1.04)
            else:
                puff = 1.05 + CAP["puff"] * math.sin(math.pi * min(1.0, 0.18 + t * 0.95)) ** 0.7
                crinkle = 0.045 * math.sin(math.radians(az) * 7 + j * 1.9) * math.sin(j * 2.3 + k)
                p = head_point(az, lat, s=puff + crinkle)
                p += lean * t
                p.z -= 0.035 * t * t  # the crown sags, it is only paper
            ids.append(mb.vert(p, {"head": 1}))
        ring_ids.append(ids)
    last = ring_ids[-1]
    topc = sum((mb.co[i] for i in last), Vector()) / len(last) + Vector((0, 0, 0.012))
    top = mb.vert(topc, {"head": 1})
    reg = REG["cap"]
    for j in range(rows - 1):
        for k in range(segs):
            k2 = (k + 1) % segs
            mb.face([ring_ids[j][k], ring_ids[j][k2], ring_ids[j + 1][k2], ring_ids[j + 1][k]],
                    [ruv(reg, k / segs, j / rows), ruv(reg, (k + 1) / segs, j / rows),
                     ruv(reg, (k + 1) / segs, (j + 1) / rows), ruv(reg, k / segs, (j + 1) / rows)], hc)
    for k in range(segs):
        k2 = (k + 1) % segs
        mb.face([last[k], last[k2], top], [ruv(reg, k / segs, 0.9), ruv(reg, (k + 1) / segs, 0.9), ruv(reg, 0.5, 1.0)], hc)


def mask_point(a_deg, lat_deg):
    """a_deg: -a_half..a_half across the face (0 = front). The mask is worn a few degrees crooked
    and bulges forward across almost its whole width, as if over a mouth far wider than a mouth."""
    lat_deg = lat_deg + MASK["tilt"] * (a_deg / MASK["a_half"])
    j = (lat_deg - MASK["lat0"]) / (MASK["lat1"] - MASK["lat0"])
    ca = math.cos(math.radians(min(89.0, abs(a_deg) * 0.80)))
    pleat = MASK["pleat"] * math.cos(j * 3 * 2 * math.pi) * ca
    p = head_point(a_deg, lat_deg, s=MASK["scale"])
    bul = MASK["bulge"] * ca ** 0.7 * math.exp(-((lat_deg + 30) / 24) ** 2)
    p.y -= MASK["proud"] * ca ** 2 * math.cos(math.radians(lat_deg + 20)) + pleat + bul
    side = math.sin(math.radians(a_deg))
    p.x += 0.012 * side * math.exp(-((lat_deg + 30) / 24) ** 2)
    if lat_deg < -52:
        p.y += 0.008 * (-52 - lat_deg) / 18
    return p


def mask_size():
    """Approximate physical width/height (m) of the mask's UV space, so the print stays in proportion."""
    n = 40
    mid = (MASK["lat0"] + MASK["lat1"]) / 2
    w = sum((mask_point(-MASK["a_half"] + 2 * MASK["a_half"] * i / n, mid) -
             mask_point(-MASK["a_half"] + 2 * MASK["a_half"] * (i + 1) / n, mid)).length for i in range(n))
    h = sum((mask_point(0, MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * i / n) -
             mask_point(0, MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * (i + 1) / n)).length for i in range(n))
    return w, h


def build_mask(mb):
    cols, rows = MASK["cols"], MASK["rows"]
    hc = Vector(HEAD["c"])
    ids = [[mb.vert(mask_point(-MASK["a_half"] + 2 * MASK["a_half"] * i / cols,
                               MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * j / rows), {"head": 1})
            for i in range(cols + 1)] for j in range(rows + 1)]
    for j in range(rows):
        for i in range(cols):
            mb.face([ids[j][i], ids[j][i + 1], ids[j + 1][i + 1], ids[j + 1][i]],
                    [ruv(REG["mask"], i / cols, j / rows), ruv(REG["mask"], (i + 1) / cols, j / rows),
                     ruv(REG["mask"], (i + 1) / cols, (j + 1) / rows), ruv(REG["mask"], i / cols, (j + 1) / rows)], hc)
    # ear loops: elastic cords from the corners of the mask round behind the ears
    for col in (0, cols):
        sgn = -1 if col == 0 else 1
        for j in (0, rows):
            p0 = mb.co[ids[j][col]]
            lat = MASK["lat0"] + (MASK["lat1"] - MASK["lat0"]) * j / rows
            mid = head_point(sgn * 120, lat * 0.5 - 4, s=1.06)
            back = head_point(sgn * 140, lat * 0.3 + 2, s=1.03)
            tube(mb, [(p0, 0.003, {"head": 1}), (mid, 0.003, {"head": 1}), (back, 0.003, {"head": 1})],
                 3, REG["tie"], cap0=False, cap1=False)
    build_cheek_ink(mb)


def build_cheek_ink(mb):
    """The printed grin does not stop at the mask: someone carried it on in ink across the cheeks,
    further and higher on one side than the other."""
    S_ = SMILE
    mw, mh = mask_size()
    def curve(tx):
        return S_["cy"] - S_["depth"] * (1 - tx * tx) + S_["lift"] * max(0.0, abs(tx) - 0.72) ** 2 / 0.08

    # where the printed line leaves the mask: either its top edge or its side
    tx_exit, top = 1.0, 0.5 * mh * 0.93
    for i in range(101):
        tx = i / 100
        if curve(tx) >= top:
            tx_exit = tx
            break
    py_exit = min(curve(tx_exit), top)
    lat_exit = MASK["lat0"] + (0.5 + py_exit / mh) * (MASK["lat1"] - MASK["lat0"])
    hc = Vector(HEAD["c"])
    print(f"[build] cheek ink: mask {mw:.3f} x {mh:.3f} m, leaves the mask at tx {tx_exit:.2f}, lat {lat_exit:.1f}")
    for sgn, (ext, rise) in ((1, S_["cheek"][0]), (-1, S_["cheek"][1])):
        az0 = MASK["a_half"] * tx_exit
        pts = [mask_point(sgn * az0, lat_exit)]
        n = 7
        for i in range(1, n + 1):
            t = i / n
            az = sgn * (az0 + ext * t)
            lat = lat_exit + MASK["tilt"] * sgn * (az0 / MASK["a_half"]) + 2 + rise * t ** 1.3
            pts.append(head_point(az, lat, extra=0.0030))
        rows = []
        for i, p in enumerate(pts):
            tan = (pts[min(i + 1, n)] - pts[max(i - 1, 0)]).normalized()
            nrm = (p - hc).normalized()
            side = tan.cross(nrm).normalized()
            hw = 0.0040 * (1.0 + 0.45 * math.sin(i * 2.7 + sgn)) * (0.6 if i == n else 1.0)
            rows.append((mb.vert(p + side * hw, {"head": 1}), mb.vert(p - side * hw, {"head": 1})))
        reg = REG["ink"]
        for i in range(n):
            a0, b0 = rows[i]
            a1, b1 = rows[i + 1]
            mb.face([a0, a1, b1, b0], [ruv(reg, 0, 0), ruv(reg, 1, 0), ruv(reg, 1, 1), ruv(reg, 0, 1)],
                    interior=hc)


def build_arm(mb, side, sfx):
    sh, el, wr, kn = (Vector(mirror_pt(ARM[k], side)) for k in ("shoulder", "elbow", "wrist", "knuckle"))
    C, U, F, H = "clavicle" + sfx, "upperarm" + sfx, "forearm" + sfx, "hand" + sfx
    inside = Vector((0.11 * side, spine_y(1.90) + 0.01, 1.90))
    back = Vector((0, 1, 0))
    outv = Vector((side, 0, 0))

    def along(p, q, t):
        return p.lerp(q, t)

    def r_upper(base, bicep=0.0):
        return lambda d: base + bicep * max(0.0, -d.y) ** 2

    def r_elbow(base, knob):
        # bony point of the elbow sticks out backwards, a ridge to the outside
        return lambda d: base + knob * max(0.0, d.dot(back)) ** 3 + 0.4 * knob * max(0.0, d.dot(outv)) ** 4

    def r_wrist(base, knob):
        # flat wrist, wider front to back, with the knob of the ulna on the outside-back
        return lambda d: base * (0.75 + 0.35 * abs(d.y)) + knob * max(0.0, (d.dot(outv) * 0.6 + d.dot(back) * 0.8)) ** 4

    e_up, e_dn = along(el, sh, 0.06), along(el, wr, 0.07)
    rings = [
        (inside, 0.040, {C: 1}),
        (along(inside, sh, 0.6), 0.044, {C: 1}),
        (sh, 0.046, {C: .6, U: .4}),
        (along(sh, el, 0.25), r_upper(0.037, 0.004), {C: .15, U: .85}),
        (along(sh, el, 0.55), r_upper(0.028, 0.006), {U: 1}),
        (along(sh, el, 0.82), 0.022, {U: 1}),
        (e_up, 0.030, {U: .85, F: .15}),
        (el, r_elbow(0.036, 0.024), {U: .5, F: .5}),
        (e_dn, r_elbow(0.031, 0.009), {U: .15, F: .85}),
        (along(el, wr, 0.28), 0.030, {F: 1}),
        (along(el, wr, 0.62), 0.020, {F: 1}),
        (along(el, wr, 0.86), 0.0155, {F: .9, H: .1}),
        (wr, r_wrist(0.025, 0.015), {F: .45, H: .55}),
    ]
    def arm_reg(i, k, c, f):
        d = (f - c).normalized()
        if i in (6, 7, 8) and d.y > 0.2:      # the bony point of the elbow, bruised
            return REG["bruise"]
        if i == 12:                           # knobbed, bruised wrist
            return REG["bruise"] if d.dot(Vector((side * 0.6, 0.8, 0))) > 0.2 else REG["skin_lo"]
        if i in (3, 4) and d.y < -0.5:
            return REG["skin_hi"]
        if i < 2:
            return REG["gown_top"]  # the root of the arm, inside the sleeve
        return REG["skin"]
    tube(mb, rings, 10, REG["skin"], cap0=True, cap1=False, ref=(side, 0, 0), reg_fn=arm_reg)
    if side > 0:  # hospital wristband, a little loose
        wb = along(el, wr, 0.78)
        tube(mb, [(wb + (wr - el).normalized() * -0.009, 0.0215, {F: 1}),
                  (wb + (wr - el).normalized() * 0.009, 0.0220, {F: 1})], 10, REG["band"],
             cap0=False, cap1=False, ref=(side, 0, 0))
    # palm: thin across, long, wide front to back, with knuckle bumps
    pv = (kn - wr)
    palm = [(wr + pv * 0.05, (0.013, 0.024), {F: .3, H: .7}), (wr + pv * 0.45, (0.012, 0.036), {H: 1}),
            (wr + pv * 0.85, (0.011, 0.042), {H: 1}), (kn + Vector((0, 0, -0.004)), (0.010, 0.040), {H: 1})]
    tube(mb, palm, 8, REG["skin"], cap0=False, cap1=True, ref=(side, 0, 0))
    # four long fingers with knobbed joints
    names = {"index": ("index1", "index2", "index3"), "middle": ("middle1", "middle2", "middle3"),
             "ring": ("ring1", "ring2", "ring2"), "little": ("ring1", "ring2", "ring2")}
    for fname, bones in names.items():
        pts = finger_points(side, fname)
        rad = HAND[fname][2]
        b1, b2, b3 = (b + sfx for b in bones)
        rings = [(pts[0] + Vector((0, 0, 0.012)), rad * 1.05, {H: 1}),
                 (pts[0], rad * 1.40, {H: .4, b1: .6}),
                 (pts[0].lerp(pts[1], 0.5), rad * 0.74, {b1: 1}),
                 (pts[1], rad * 1.30, {b1: .5, b2: .5}),
                 (pts[1].lerp(pts[2], 0.5), rad * 0.70, {b2: 1}),
                 (pts[2], rad * 1.15, {b2: .5, b3: .5}),
                 (pts[2].lerp(pts[3], 0.55), rad * 0.68, {b3: 1}),
                 (pts[3], rad * 0.55, {b3: 1})]
        tube(mb, rings, 5, REG["skin"], cap0=False, cap1=True, ref=(side, 0, 0),
             reg_fn=lambda i, k, c, f=None: REG["skin_lo"] if i in (1, 3, 5) else (REG["nail"] if i == 6 else REG["skin"]))
    th = thumb_points(side)
    T = "thumb" + sfx
    rings = [(th[0] + Vector((0.004 * side, 0.012, 0.016)), 0.011, {H: 1}), (th[0], 0.011, {H: .5, T: .5}),
             (th[1], 0.0105, {T: 1}), (th[1].lerp(th[2], 0.6), 0.008, {T: 1}), (th[2], 0.005, {T: 1})]
    tube(mb, rings, 5, REG["skin"], cap0=True, cap1=True)


def build_leg(mb, side, sfx):
    """Thin legs with a kneecap, the ridge of the shin, a little calf, ankle bones and the Achilles
    tendon; long bare feet with tendons on top and toes that are too long."""
    T, Sh, Ft = "thigh" + sfx, "shin" + sfx, "foot" + sfx
    hip, knee, ankle, toe = (Vector(mirror_pt(LEG[k], side)) for k in ("hip", "knee", "ankle", "toe"))
    fwd, back, out = Vector((0, -1, 0)), Vector((0, 1, 0)), Vector((side, 0, 0))

    def leg_r(base, front=0.0, front_p=3, sides_=0.0, calf=0.0, achilles=0.0, inner=0.0):
        def r(d):
            v = base + front * max(0.0, d.dot(fwd)) ** front_p
            v += sides_ * abs(d.x) ** 6 + calf * max(0.0, d.dot(back)) ** 2
            v += achilles * max(0.0, d.dot(back)) ** 10 + inner * max(0.0, -d.dot(out)) ** 4
            return v
        return r

    kd = (hip - knee).normalized()
    ad = (ankle - knee).normalized()
    rings = [(hip + Vector((0, 0, 0.06)), 0.060, {T: .5, "hips": .5}),
             (hip.lerp(knee, 0.25), leg_r(0.048, inner=0.004), {T: 1}),
             (hip.lerp(knee, 0.62), leg_r(0.033, front=0.004), {T: 1}),
             (knee + kd * 0.065, leg_r(0.025, front=0.006), {T: .9, Sh: .1}),
             (knee + kd * 0.025, leg_r(0.034, front=0.022, sides_=0.013), {T: .65, Sh: .35}),
             (knee, leg_r(0.036, front=0.024, front_p=4, sides_=0.013), {T: .5, Sh: .5}),
             (knee + ad * 0.035, leg_r(0.029, front=0.010, sides_=0.005), {T: .2, Sh: .8}),
             (knee + ad * 0.090, leg_r(0.027, front=0.007, front_p=8, calf=0.010), {Sh: 1}),
             (knee.lerp(ankle, 0.38), leg_r(0.025, front=0.006, front_p=8, calf=0.006), {Sh: 1}),
             (knee.lerp(ankle, 0.68), leg_r(0.020, front=0.005, front_p=8, achilles=0.004), {Sh: 1}),
             (knee.lerp(ankle, 0.88), leg_r(0.017, front=0.003, achilles=0.008), {Sh: .9, Ft: .1}),
             (ankle + Vector((0, 0, 0.012)), leg_r(0.020, sides_=0.011, achilles=0.009), {Sh: .5, Ft: .5}),
             (ankle + Vector((0, 0, -0.022)), leg_r(0.024, sides_=0.006, achilles=0.012), {Sh: .2, Ft: .8})]

    def leg_reg(i, k, c, f):
        d = (f - c)
        if i in (4, 5, 6) and d.y < -0.010:
            return REG["skin_hi"]          # knobbed knees catch the light
        if i in (11, 12) and abs(d.x) > 0.012:
            return REG["skin_hi"]          # ankle bones
        if i in (7, 8, 9) and d.y < -0.016:
            return REG["skin_hi"]          # edge of the shin bone
        return REG["skin"]
    tube(mb, rings, 10, REG["skin"], cap0=True, cap1=False, ref=(side, 0, 0), reg_fn=leg_reg)

    # foot: heel to the ball, a flat sole, tendons standing up on top
    fspec = [(0.060, 0.022, 0.026, 0.035), (0.040, 0.030, 0.036, 0.045), (0.000, 0.034, 0.044, 0.050),
             (-0.060, 0.038, 0.034, 0.040), (-0.120, 0.044, 0.024, 0.028), (-0.170, 0.050, 0.016, 0.020)]
    frings = []
    for y, rx, ztop, zc in fspec:
        lift = 0.030 * max(0.0, min(1.0, (y + 0.12) / 0.16))
        c = Vector((ankle.x + 0.008 * side * (-y / 0.2), ankle.y + y, zc * 0.5 + 0.003 + lift))

        def rad(d, rx=rx, ztop=ztop, zc=zc, y=y, lift=lift):
            if d.z < -0.3:
                bottom = zc * 0.5 + 0.002 + lift
                if -0.13 < y < 0.03 and d.x * side < 0:
                    bottom *= 0.55  # the arch
                return min(rx, bottom / max(0.05, -d.z))
            base = math.hypot(rx * d.x, ztop * d.z) / max(1e-4, math.hypot(d.x, d.z))
            if d.z > 0.2 and y < 0.01:  # tendons running down to the toes
                a = math.atan2(d.z, d.x)
                base += 0.004 * max(0.0, math.cos(a * 9)) ** 4 * d.z
            return base
        frings.append((c, rad, {Ft: 1}))
    tube(mb, frings, 10, REG["skin"], cap0=True, cap1=True, ref=(1, 0, 0))
    # five long toes, gripping the floor at the tips
    ball = Vector((ankle.x + 0.008 * side * 0.85, ankle.y - 0.170, 0.012))
    toes = [(-0.034, 0.110, 0.0125), (-0.016, 0.104, 0.0100), (0.002, 0.098, 0.0094),
            (0.019, 0.088, 0.0088), (0.035, 0.074, 0.0082)]
    for dx, L, r0 in toes:
        b0 = ball + Vector((-dx * side, 0.004, 0.0))
        spread = -dx * side * 0.25
        pts = [b0, b0 + Vector((spread * 0.3, -L * 0.38, 0.010)), b0 + Vector((spread * 0.6, -L * 0.68, 0.016)),
               b0 + Vector((spread * 0.8, -L * 0.90, 0.006)), b0 + Vector((spread, -L * 0.96, -0.006))]
        rings = [(pts[0], r0 * 1.15, {Ft: 1}), (pts[1], r0 * 1.10, {Ft: 1}), (pts[2], r0 * 0.95, {Ft: 1}),
                 (pts[3], r0 * 0.85, {Ft: 1}), (pts[4], r0 * 0.55, {Ft: 1})]
        tube(mb, rings, 5, REG["skin"], cap0=False, cap1=True,
             reg_fn=lambda i, k, c, f=None: REG["bruise"] if i in (1, 2) and (f - c).z > 0.003 else (REG["nail"] if i == 3 else REG["skin"]))


def gown_top(a_deg):
    """Height of the gown's upper edge in direction a: a sagging scoop at the front, the back slit
    handled separately, slid down off the left shoulder."""
    s = math.sin(math.radians(a_deg))
    c = math.cos(math.radians(a_deg))
    if s < 0:  # front half: scoop
        f = (-s) ** 4.0
        top = lerp(GOWN["top_side"], GOWN["top_front"], f)
    else:
        top = GOWN["top_side"] + 0.07 * s  # ties high at the back of the neck
    if c > 0:  # left side slipped down
        top = lerp(top, min(top, GOWN["top_left"] - 0.02 * max(0, -s)), min(1.0, c * 1.6))
    return top


def slit_half(z):
    """Half-angle of the open back at height z (degrees from the back centre)."""
    if z < GOWN["slit_to"]:
        return 0.0
    t = (z - GOWN["slit_to"]) / (GOWN["top_side"] - GOWN["slit_to"])
    return lerp(GOWN["slit_bottom"], GOWN["slit_top"], min(1.0, t) ** 1.3)


def gown_weights(p):
    z = p.z
    if z >= 1.16:
        return torso_weights(p)
    t = min(1.0, (1.16 - z) / (1.16 - GOWN["hem"])) ** 0.8 * 0.8
    sl = max(0.0, min(1.0, 0.5 + p.x / 0.14))
    return {"hips": 1 - t, "thigh.L": t * sl, "thigh.R": t * (1 - sl)}


def build_gown(mb):
    """Each column hangs from the gown's top edge to the hem, so the neckline stays clean. The radius
    is the larger of the body plus a gap and the widest body point above (paper hangs from what it
    rests on), clinging more at the sides so the waist shows."""
    sides = GOWN["sides"]
    fr = [0, 0.015, 0.04, 0.075, 0.12, 0.17, 0.23, 0.30, 0.37, 0.44, 0.51, 0.58, 0.65, 0.72, 0.79, 0.86, 0.93, 1.0]
    base_angles = [-90 + 360.0 * (k + 0.5) / sides for k in range(sides)]
    kb = min(range(sides), key=lambda k: abs(base_angles[k] - 90 + 180 / sides))  # column just before the back centre
    verts, zcol = [], []
    mb.smooth = True
    for k, a0 in enumerate(base_angles):
        runmax = 0.0
        col, zc = [], []
        top = gown_top(a0)
        for j, f in enumerate(fr):
            z = lerp(top, GOWN["hem"], f)
            a = a0
            hw = slit_half(z)
            if hw > 0 and k in (kb, (kb + 1) % sides):
                a = 90 - hw if k == kb else 90 + hw
            zb = max(z, 1.10)
            br = body_r(a, zb) + GOWN["gap"]
            runmax = max(runmax, br)
            s_ = math.sin(math.radians(a))
            hang_w = GOWN["hang_front"] if s_ < -0.5 else (GOWN["hang_back"] if s_ > 0.5 else GOWN["hang_side"])
            r = max(br, runmax * hang_w)
            low = max(0.0, min(1.0, (1.30 - z) / 0.75))
            r += GOWN["flare"] * low ** 1.2 * (1.0 + 0.3 * max(0.0, s_))
            r += GOWN["fold_amp"] * low * math.cos(math.radians(a) * GOWN["folds"] + 1.3)
            # a collar that sags away from the chest and rolls over at the edge
            front = max(0.0, -s_)
            if j == 0:
                r += 0.012 + GOWN["collar_sag"] * front ** 3
            elif j == 1:
                r += 0.004 + GOWN["collar_sag"] * 0.6 * front ** 3
            elif j == 2:
                r += GOWN["collar_sag"] * 0.25 * front ** 3
            r += 0.006 * low * math.cos(math.radians(a) * 13 + 0.4)  # smaller creases
            zz = z
            if j == 0:
                zz = z - 0.010
            if j == len(fr) - 1:  # uneven, torn-looking hem, longer at the back, one corner dipped
                rad = math.radians(a)
                zz = (z + 0.040 * math.cos(rad * 3 + 0.7) + 0.022 * math.cos(rad * 7 + 2.1)
                      - 0.05 * max(0.0, s_) - 0.07 * math.exp(-((a + 55) / 16) ** 2))
            cy = spine_y(max(z, 1.05))
            p = Vector((r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)), zz))
            col.append(mb.vert(p, gown_weights(p)))
            zc.append(z)
        verts.append(col)
        zcol.append(zc)
    n = len(fr)
    T = TEAR

    def rip_open(a_deg, z, k, j):
        """How far inside the side rip a face is (> 0: open). The rip is widest at the hip and closes
        to a point under the ribs; its edges are ragged (a fixed per-face jitter)."""
        t = (z - T["rip_bottom"]) / (T["rip_top"] - T["rip_bottom"])
        if t <= 0 or t >= 1:
            return -99.0
        half = T["rip_half"] * math.sin(math.pi * t) ** 0.6
        jit = 10.0 * (hash01(k * 31 + j * 7) - 0.5)
        d = abs((a_deg - T["rip_a"] + 180) % 360 - 180)
        return half + jit - d

    open_at = {}
    for k in range(sides):
        k2 = (k + 1) % sides
        ac = -90 + 360.0 * (k + 1) / sides
        for j in range(n - 1):
            if k == kb and max(zcol[k][j], zcol[k2][j]) > GOWN["slit_to"]:
                continue  # the open back
            zm = (zcol[k][j] + zcol[k][j + 1]) / 2
            ro = rip_open(ac, zm, k, j)
            open_at[(k, j)] = ro > 0
            if ro > 0:
                continue  # the long rip up the right side
            interior = Vector((0, spine_y(max(zm, 1.05)), zm))
            reg = REG["gown"]
            uv = [ruv(reg, k / sides, 1 - fr[j]), ruv(reg, (k + 1) / sides, 1 - fr[j]),
                  ruv(reg, (k + 1) / sides, 1 - fr[j + 1]), ruv(reg, k / sides, 1 - fr[j + 1])]
            if ro > -5.5:  # the cloth right along the rip is frayed and filthy (judge round: narrower)
                reg = REG["dirty"]
                uv = [ruv(reg, 0, 1), ruv(reg, 1, 1), ruv(reg, 1, 0), ruv(reg, 0, 0)]
            for (k0, k1, j0, j1) in T["holes"]:
                if k0 <= k < k1 and j0 <= j < j1:  # a patch of the torn texture: holes cut by alpha
                    reg = REG["holes"]
                    uv = [ruv(reg, (k - k0) / (k1 - k0), 1 - (j - j0) / (j1 - j0)),
                          ruv(reg, (k + 1 - k0) / (k1 - k0), 1 - (j - j0) / (j1 - j0)),
                          ruv(reg, (k + 1 - k0) / (k1 - k0), 1 - (j + 1 - j0) / (j1 - j0)),
                          ruv(reg, (k - k0) / (k1 - k0), 1 - (j + 1 - j0) / (j1 - j0))]
            mb.face([verts[k][j], verts[k2][j], verts[k2][j + 1], verts[k][j + 1]], uv, interior)
    build_hem_strips(mb, verts, n, sides, open_at)
    # ties across the open back, hanging loose; their ends are frayed into threads, one is torn short
    for z in (1.86, 1.58):
        hw = slit_half(z)
        l = body_point(90 - hw, z, GOWN["gap"] + 0.004)
        r = body_point(90 + hw, z, GOWN["gap"] + 0.004)
        w = torso_weights((l + r) / 2)
        lens = ((0.24, 0.17) if z > 1.7 else (0.27, 0.07))
        for i, (p0, p1, L) in enumerate(((l, l.lerp(r, 0.40), lens[0]), (r, r.lerp(l, 0.30), lens[1]))):
            d1 = p1 + Vector((0.01, 0.012, -L * 0.5))
            d2 = p1 + Vector((-0.006, 0.020, -L))
            rings = [(p0, 0.006, w), (p1, 0.006, w), (d1, 0.005, w), (d2, 0.0045, w)]
            tube(mb, rings, 3, REG["dirty"], cap0=False, cap1=False)
            for t, (dx, dz) in enumerate(((0.012, -0.045), (-0.010, -0.060), (0.002, -0.030))):
                e = d2 + Vector((dx, 0.006 * (t - 1), dz))
                tube(mb, [(d2, 0.0022, w), (e, 0.0012, w)], 3, REG["dirty"], cap0=False, cap1=True)
    # sleeves: raglan, following the slope of the shoulder; the left one has slid down the arm
    for side, sfx in ((1, ".L"), (-1, ".R")):
        sh, el = Vector(mirror_pt(ARM["shoulder"], side)), Vector(mirror_pt(ARM["elbow"], side))
        U, C = "upperarm" + sfx, "clavicle" + sfx
        ax = el - sh

        def srad(base, droop):
            # paper hangs: looser at the back and much looser underneath
            return lambda d: base + droop * max(0.0, d.y) ** 2 + 2.2 * droop * max(0.0, -d.z) ** 2

        if side < 0:
            # third pass: the right sleeve is half gone, torn off short at the back and a little
            # longer at the front, with a frayed edge and one rag hanging from it
            rings = [(sh + Vector((-0.055 * side, 0.004, 0.030)), srad(0.034, 0.0), {"spine2": .5, C: .5}),
                     (sh + Vector((-0.012 * side, 0.002, 0.016)), srad(0.054, 0.004), {C: .6, U: .4}),
                     (sh + ax * 0.12, srad(0.056, 0.008), {U: 1}),
                     (sh + ax * 0.22 + Vector((0, 0.004, -0.012)), srad(0.059, 0.012), {U: 1})]
        else:
            rings = [(sh + ax * 0.10, srad(0.050, 0.004), {C: .3, U: .7}),
                     (sh + ax * 0.32, srad(0.055, 0.008), {U: 1}),
                     (sh + ax * 0.58 + Vector((0, 0.006, -0.030)), srad(0.062, 0.018), {U: 1})]
        idx = tube(mb, rings, 10, REG["gown_top"], cap0=False, cap1=False, ref=(side, 0, 0))
        if side < 0:
            build_torn_sleeve(mb, idx[-1], sh, ax, U)
    mb.smooth = False


def hash01(i):
    """A fixed pseudo-random number in 0..1 for an integer (so the build stays deterministic)."""
    return (math.sin(i * 12.9898 + 78.233) * 43758.5453) % 1.0


def fringe(mb, tops, bottoms, wfn, reg, u0, u1, v_len, interior, rows):
    """A band of cloth from a row of top points to a row of bottom points, mapped onto the torn-cloth
    strips (v = 1 at the top, where the strips join the cloth). v_len[i]: how much of the texture's
    height column i uses, so short strips end part-way down the texture. Returns the vertex rows."""
    grid = []
    for r_ in range(rows + 1):
        t = r_ / rows
        row = []
        for i, (a, b) in enumerate(zip(tops, bottoms)):
            p = a.lerp(b, t)
            row.append(mb.vert(p, wfn(p, t)))
        grid.append(row)
    m = len(tops)
    for r_ in range(rows):
        for i in range(m - 1):
            def uv(ii, rr):
                return ruv(reg, lerp(u0, u1, ii / (m - 1)), 1 - v_len[ii] * rr / rows)
            q = [grid[r_][i], grid[r_][i + 1], grid[r_ + 1][i + 1], grid[r_ + 1][i]]
            mb.face(q, [uv(i, r_), uv(i + 1, r_), uv(i + 1, r_ + 1), uv(i, r_ + 1)], interior)
    return grid


def build_hem_strips(mb, verts, n, sides, open_at):
    """The hem hangs in strips of different lengths: separate pieces of real geometry (so neighbours
    can part), each carried partly by one of the skirt bones so they swing a little in the walk, and
    cut into frayed strips by the torn texture. They overlap the bottom of the gown to hide the join."""
    T = TEAR
    cuts = T["strip_cuts"]
    lmax = T["strip_len"][1] + T["strip_overlap"]
    for si, (c0, c1) in enumerate(zip(cuts, cuts[1:])):
        cols = list(range(c0, c1 + 1))
        if any(open_at.get((k % sides, n - 2), False) for k in cols[:-1]):
            continue  # no strips where the rip runs out through the hem
        L = lerp(T["strip_len"][0], T["strip_len"][1], hash01(si * 5 + 1))
        share = 0.45 + 0.5 * hash01(si * 11 + 3)  # how freely this strip swings
        tops, bots, vl = [], [], []
        for c in cols:
            k = c % sides
            hv, av = mb.co[verts[k][n - 1]], mb.co[verts[k][n - 2]]
            up = (av - hv).normalized()
            down = -up
            outward = Vector((hv.x, hv.y - spine_y(1.05), 0)).normalized()
            l_here = L * (0.75 + 0.5 * hash01(si * 17 + c))
            tops.append(hv + up * T["strip_overlap"] + outward * 0.002)
            bots.append(hv + down * l_here + outward * (0.010 + 0.03 * l_here))
            vl.append((T["strip_overlap"] + l_here) / lmax)
        a_mid = -90 + 360.0 * (0.5 * (c0 + c1) + 0.5) / sides
        bone = skirt_bone_for(a_mid)

        def wfn(p, t, bone=bone, share=share):
            w = gown_weights(p)
            s = share * min(1.0, t * 1.4)
            out = {k: v * (1 - s) for k, v in w.items()}
            out[bone] = out.get(bone, 0) + s
            return out
        u0 = (c0 % 17) / 17.0
        u1 = u0 + (c1 - c0) / 17.0
        zc = mb.co[verts[c0 % sides][n - 1]].z
        fringe(mb, tops, bots, wfn, REG["strips"], u0, u1, vl, Vector((0, spine_y(1.05), zc)), T["strip_rows"])


def build_torn_sleeve(mb, last, sh, ax, U):
    """Ragged end of the half-gone right sleeve and a rag hanging from it toward the elbow."""
    axn = ax.normalized()
    ring = [Vector(mb.co[i]) for i in last]
    cen = sum(ring, Vector()) / len(ring)
    # the torn edge: back of the sleeve shorter, front longer; frayed by the strips texture
    tops, bots, vl = [], [], []
    for i, p in enumerate(ring + ring[:1]):
        d = (p - cen).normalized()
        front = max(0.0, -d.y)
        ln = 0.02 + 0.07 * front * (0.6 + 0.8 * hash01(i + 40))
        tops.append(p - axn * 0.025)
        bots.append(p + axn * ln + (p - cen) * 0.12)
        vl.append(0.25 + 1.6 * ln)
    fringe(mb, tops, bots, lambda p, t: {U: 1}, REG["strips"], 0.05, 0.62, vl, cen - axn * 0.05, 2)
    # one rag, hanging straight down from the front of the torn edge
    lo = min(ring, key=lambda p: p.z + 0.5 * p.y)
    side = Vector((-1, 0, 0)).cross(Vector((0, 0, 1)))  # front-back spread
    w0 = 0.020
    tops = [lo + Vector((0.006, -w0, 0.004)), lo + Vector((0.004, w0, 0.004))]
    drop = Vector((0.010, 0.0, -0.24)) + axn * 0.04
    bots = [tops[0] + drop + Vector((0.004, 0.006, 0.02)), tops[1] + drop + Vector((0, -0.004, 0))]

    def wfn(p, t):
        s = min(1.0, t * 1.6)
        return {U: 1 - s, "sleeve_rag.R": s}
    fringe(mb, tops, bots, wfn, REG["strips"], 0.30, 0.40, [1.0, 1.0], lo + Vector((-0.05, 0, 0)), 4)


# ============================ TEXTURE ============================
SMILE = dict(cy=0.098, depth=0.044, lift=0.010, half=0.50, width=0.0058,
             cheek=((10.0, 27.0), (5.0, 17.0)))  # how far the ink runs on past the mask: (az, rise) left, right


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
        block = np.tile(col, (h, w, 1)) + (rng.random((h, w, 1)) - 0.5) * 2 * noise
        if blotch is not None:
            bcol, count, rad = blotch
            yy, xx = np.mgrid[0:h, 0:w]
            for _ in range(count):
                cx, cy, r = rng.random() * w, rng.random() * h, rad * (0.5 + rng.random())
                m = np.clip(1 - ((xx - cx) ** 2 + (yy - cy) ** 2) / r ** 2, 0, 1)[..., None] * 0.35
                block = block * (1 - m) + bcol * m
        img[y0:y1, x0:x1, :3] = np.clip(block, 0, 1)

    fill(REG["skin"], C["skin"], 0.006)
    sx0, sy0, sx1, sy1 = region_px(REG["skin"])
    for _ in range(5):  # faint blue veins under the waxy skin
        x, y = float(rng.integers(sx0, sx1)), float(rng.integers(sy0, sy1))
        a = rng.random() * 6.28
        for _ in range(40):
            a += (rng.random() - 0.5) * 0.7
            x, y = x + math.cos(a), y + math.sin(a)
            if sx0 <= x < sx1 and sy0 <= y < sy1:
                img[int(y), int(x), :3] = img[int(y), int(x), :3] * 0.55 + C["vein"] * 0.45
    fill(REG["ink"], C["ink"], 0.01)
    fill(REG["skin_lo"], C["skin_lo"], 0.005)
    fill(REG["skin_hi"], C["skin_hi"], 0.005)
    fill(REG["bruise"], C["bruise"], 0.005)
    # wristband: white, a printed name strip
    fill(REG["band"], C["band"], 0.004)
    bx0, by0, bx1, by1 = region_px(REG["band"])
    img[by0 + 12:by0 + 20, bx0 + 20:bx0 + 60, :3] = C["band_ink"]
    fill(REG["cap"], C["cap"], 0.008)
    cx0, cy0, cx1, cy1 = region_px(REG["cap"])
    for _ in range(70):  # crinkles in the paper
        x, y = int(rng.integers(cx0, cx1 - 12)), int(rng.integers(cy0 + 10, cy1 - 3))
        ln = int(rng.integers(4, 12))
        img[y, x:x + ln, :3] = C["cap"] * 0.84
    fill(REG["tie"], C["tie"], 0.015)
    fill(REG["nail"], C["nail"], 0.02)
    fill(REG["gown_in"], C["gown_line"], 0.02)
    x0, y0, x1, y1 = region_px(REG["cap"])
    img[y0:y0 + 8, x0:x1, :3] = C["cap_band"]

    # socket: a puckered bruised rim, a pale closed lid, a thick dark seam with uneven stitches
    x0, y0, x1, y1 = region_px(REG["socket"])
    h, w = y1 - y0, x1 - x0
    yy, xx = np.mgrid[0:h, 0:w]
    m = 0.04
    lx = (((xx + 0.5) / w - m) / (1 - 2 * m) - 0.5) * 3.0
    ly = (((yy + 0.5) / h - m) / (1 - 2 * m) - 0.5) * 3.0
    rr = np.sqrt(lx ** 2 + (ly / 0.78) ** 2)
    ang = np.arctan2(ly, lx)
    lid = C["skin_hi"] * 0.85 + C["bruise"] * 0.15
    sk = np.where((rr < 0.95)[..., None], lid, np.where((rr < 1.20)[..., None], C["skin"] * 0.6 + C["bruise"] * 0.4, C["skin"]))
    crease = (rr > 0.93) & (rr < 1.02)
    sk = np.where(crease[..., None], C["bruise_deep"], sk)
    pucker = (rr > 0.60) & (rr < 0.95) & (np.cos(ang * 9) > 0.92)
    sk = np.where(pucker[..., None], sk * 0.8 + C["bruise_deep"] * 0.2, sk)
    seam = (np.abs(ly - 0.03 * lx * lx) < 0.075) & (np.abs(lx) < 0.88)
    stitches = np.zeros_like(seam)
    for sx, slant, ln in ((-0.55, 0.45, 0.30), (-0.05, -0.25, 0.36), (0.45, 0.30, 0.26)):
        stitches |= (np.abs(lx - sx - ly * slant) < 0.075) & (np.abs(ly) < ln)
    sk = np.where((seam | stitches)[..., None], C["suture"], sk)
    img[y0:y1, x0:x1, :3] = np.clip(sk, 0, 1)

    # gown: paper, a faint printed diamond pattern, creases, stained hem (v = 0 is the hem)
    x0, y0, x1, y1 = region_px(REG["gown"])
    h, w = y1 - y0, x1 - x0
    yy, xx = np.mgrid[0:h, 0:w]
    g = np.tile(C["gown"], (h, w, 1)) + (rng.random((h, w, 1)) - 0.5) * 0.008
    # the small repeating hospital print: little crosses on a staggered grid
    gx, gy = xx % 20, (yy + 10 * ((xx // 20) % 2)) % 20
    patt = ((np.abs(gx - 10) <= 1) & (np.abs(gy - 10) <= 4)) | ((np.abs(gy - 10) <= 1) & (np.abs(gx - 10) <= 4))
    g = np.where(patt[..., None], g * 0.6 + C["gown_print"] * 0.4, g)
    for cx in rng.integers(0, w, 10):
        g[:, cx:cx + 1] = g[:, cx:cx + 1] * 0.7 + C["gown_line"] * 0.3
    vfrac = yy / h
    stain = np.clip(1 - vfrac / 0.13, 0, 1) ** 1.6 * 0.55
    for _ in range(16):
        cx, cy, r = rng.random() * w, rng.random() * h * 0.18, 3 + rng.random() * 10
        stain = np.maximum(stain, np.clip(1 - ((xx - cx) ** 2 + (yy - cy) ** 2) / r ** 2, 0, 1) * 0.55)
    stain = stain[..., None]
    g = g * (1 - stain) + C["stain"] * stain
    img[y0:y1, x0:x1, :3] = np.clip(g, 0, 1)

    # the mask: a printed smile, huge and bold, drawn in metres so it stays round on the curved mask
    x0, y0, x1, y1 = region_px(REG["mask"])
    h, w = y1 - y0, x1 - x0
    mw, mh = mask_size()
    yy, xx = np.mgrid[0:h, 0:w]
    u = ((xx + 0.5) / w - m) / (1 - 2 * m)
    v = ((yy + 0.5) / h - m) / (1 - 2 * m)
    px, py = (u - 0.5) * mw, (v - 0.5) * mh
    gem_mask = load_tex("orderly_mask.png", w, h)
    if gem_mask is not None:
        # third pass: the stained, pleated paper panel made with Gemini (it has its own pleats,
        # hems and nose wire); only the smile is drawn by code. The pleat shadows are softened so
        # the printed line is the only hard dark line on the mask.
        mk = soften(gem_mask[..., :3], 1.0)
        mmean = mk.reshape(-1, 3).mean(0)
        mk = mmean + np.maximum(mk - mmean, (mk - mmean) * 0.45)
    else:
        mk = np.tile(C["mask"], (h, w, 1)) + (rng.random((h, w, 1)) - 0.5) * 0.006
        for pl in (1 / 6, 0.5, 5 / 6):
            band = (np.abs(v - pl) < 0.014)[..., None]
            mk = np.where(band, mk * 0.35 + C["mask_line"] * 0.65, mk)
        mk = np.where((v > 0.94)[..., None], C["nose"], mk)  # the wire across the top
        edge = ((v < 0.035) | (v > 0.965))[..., None]
        mk = np.where(edge, C["mask_line"], mk)
    S_ = SMILE
    # Printed on the flat mask before it was pleated, so every fold shifts the line a little.
    jog = np.select([v < 1 / 6, v < 0.5, v < 5 / 6], [0.004, -0.003, 0.002], -0.004)
    qx = px + jog
    hw = S_["half"] * mw  # half-width: nearly the whole mask, round the sides of the face
    tx = np.clip(qx / hw, -1.2, 1.2)
    curve = S_["cy"] - S_["depth"] * (1 - tx ** 2) + S_["lift"] * np.clip(np.abs(tx) - 0.72, 0, None) ** 2 / 0.08
    curve += 0.0007 * np.sin(qx * 140.0) + 0.0012 * np.sin(qx * 41.0 + 1.0)
    slope = np.gradient(curve, axis=1) / max(1e-6, (mw / w))
    dist = np.abs(py - curve) / np.sqrt(1 + slope ** 2)
    width = S_["width"] * (1 + 0.25 * np.sin(qx * 33.0 + 0.5))
    band = (dist < width / 2) & (np.abs(tx) <= 1.0)
    # ends trail off where the ink ran out on the pleat
    band &= ~((np.abs(tx) > 0.93) & (((yy // 2) % 3) == 0))
    # a damp, yellowed patch over the mouth
    dmp = ((px / 0.034) ** 2 + ((py - 0.030) / 0.020) ** 2) + 0.3 * np.sin(px * 160) * np.sin(py * 120)
    if gem_mask is None:
        mk = np.where((dmp < 1.0)[..., None], mk * 0.65 + C["damp"] * 0.35, mk)
    # the ink bled into the fibres round the line (a thinner bleed for the thinner third-pass line)
    bleed = (dist < width * 0.95) & (np.abs(tx) <= 1.0) & ~band
    mk = np.where(bleed[..., None], mk * 0.60 + C["ink"] * 0.40, mk)
    mk = np.where(band[..., None], C["ink"], mk)
    img[y0:y1, x0:x1, :3] = np.clip(mk, 0, 1)

    apply_gemini_textures(img, C, region_px)
    im = bpy.data.images.new(P["name"] + "_atlas", n, n, alpha=True)
    im.alpha_mode = "STRAIGHT"
    im.pixels.foreach_set(img.ravel())
    im.pack()
    return im


def soften(a, k):
    """A small blur ([1,2,1] in each direction), mixed in by k: takes the dither grain off."""
    b = (np.roll(a, 1, 0) + 2 * a + np.roll(a, -1, 0)) / 4
    b = (np.roll(b, 1, 1) + 2 * b + np.roll(b, -1, 1)) / 4
    return a * (1 - k) + b * k


def load_tex(name, w=None, h=None):
    """A texture from public/assets/textures as a float array (rows bottom-up, as Blender stores
    them), resized to w x h by area averaging / nearest pick. None if the file is missing."""
    path = os.path.join(TEXDIR, name)
    if not os.path.exists(path):
        print(f"[build] {name} missing: falling back to the code-made texture")
        return None
    im = bpy.data.images.load(path)
    W, H = im.size
    a = np.array(im.pixels[:], dtype=np.float32).reshape(H, W, 4)
    bpy.data.images.remove(im)
    if w is None:
        return a
    ys = ((np.arange(h) + 0.5) * H / h).astype(int)
    xs = ((np.arange(w) + 0.5) * W / w).astype(int)
    if W >= 2 * w and H >= 2 * h:  # average 2x2 around each pick so the dither does not alias
        ys1, xs1 = np.minimum(ys + 1, H - 1), np.minimum(xs + 1, W - 1)
        out = (a[ys][:, xs] + a[ys1][:, xs] + a[ys][:, xs1] + a[ys1][:, xs1]) / 4
        out[..., 3] = np.minimum.reduce([a[ys][:, xs, 3], a[ys1][:, xs, 3], a[ys][:, xs1, 3], a[ys1][:, xs1, 3]])
        return out
    return a[ys][:, xs]


def apply_gemini_textures(img, C, region_px):
    """Third pass: put the Gemini textures into the atlas, tinted so the figure separates from the pale
    green walls: the gown dirtied toward dried yellow-grey, brown at the hem and round every tear."""
    def put(reg, arr):
        x0, y0, x1, y1 = region_px(reg)
        img[y0:y1, x0:x1, :] = np.clip(arr, 0, 1)

    def size(reg):
        x0, y0, x1, y1 = region_px(reg)
        return x1 - x0, y1 - y0

    tint = np.array(C["gown_tint"], np.float32)
    hem = np.array(C["hem_dirt"], np.float32)
    tear = np.array(C["tear_dirt"], np.float32)

    def blotches(h, w, count, seed, r0, r1, ymax=1.0):
        rng = np.random.default_rng(seed)
        yy, xx = np.mgrid[0:h, 0:w]
        m = np.zeros((h, w), np.float32)
        for _ in range(count):
            cx, cy = rng.random() * w, rng.random() * h * ymax
            r = r0 + rng.random() * (r1 - r0)
            m = np.maximum(m, np.clip(1 - ((xx - cx) ** 2 + ((yy - cy) * 0.6) ** 2) / r ** 2, 0, 1))
        return m

    # gown: the cloth, dirtied; v = 0 (bottom rows) is the hem
    w, h = size(REG["gown"])
    cloth = load_tex("orderly_gown_cloth.png", w, h)
    if cloth is not None:
        g = soften(cloth[..., :3], 0.5) * tint
        v = (np.arange(h, dtype=np.float32) / h)[:, None, None]
        # grimy hospital blue-green above, going dried yellow-grey toward the hem, brown at the hem
        f1 = 0.22 + np.clip(1 - v / 0.62, 0, 1) ** 1.2 * 0.45
        f1 = np.maximum(f1, blotches(h, w, 6, 9, 6, 16)[..., None] * 0.45)  # old stains all over
        g = g * (1 - f1) + np.array(C["hem_mid"], np.float32) * f1
        f = np.clip(1 - v / 0.26, 0, 1) ** 1.4 * 0.80
        f = np.maximum(f, blotches(h, w, 14, 7, 4, 12, ymax=0.40)[..., None] * 0.55)
        g = g * (1 - f) + hem * f
        put(REG["gown"], np.dstack([g, np.ones((h, w, 1), np.float32)]))
        # the inside of the gown (ties, inner faces) and the filthy cloth along the rip
        wi, hi = size(REG["gown_in"])
        put(REG["gown_in"], np.dstack([cloth[:hi, :wi, :3] * tint * 0.75, np.ones((hi, wi, 1))]))
        wd, hd = size(REG["dirty"])
        d = cloth[:hd, :wd, :3] * tint * 0.45 + tear * 0.55
        put(REG["dirty"], np.dstack([d, np.ones((hd, wd, 1))]))

    # torn cloth: the lower half (strips) and upper half (holes) of the Gemini tear, alpha kept
    torn = load_tex("orderly_gown_torn.png")
    if torn is not None:
        H = torn.shape[0]
        lower, upper = torn[: H // 2], torn[H // 2:]  # rows are bottom-up: the strips are the first half

        def dirty_torn(t, reg, seed):
            w, h = size(reg)
            ys = ((np.arange(h) + 0.5) * t.shape[0] / h).astype(int)
            xs = ((np.arange(w) + 0.5) * t.shape[1] / w).astype(int)
            a = t[ys][:, xs].copy()
            rgb = a[..., :3]
            # pink fringe left by the cut-out colour: pull it back to dirty cloth
            pink = (rgb[..., 0] - rgb[..., 1] > 0.08) & (rgb[..., 2] - rgb[..., 1] > 0.08)
            rgb[pink] = tear
            rgb = rgb * tint
            # brown near every edge of the cloth (distance to transparent, a few pixels)
            al = (a[..., 3] > 0.5).astype(np.float32)
            near = al.copy()
            for _ in range(3):
                near = np.minimum.reduce([near, np.roll(near, 1, 0), np.roll(near, -1, 0),
                                          np.roll(near, 1, 1), np.roll(near, -1, 1)])
            edge = (1 - near)[..., None] * 0.6
            v = (np.arange(h, dtype=np.float32) / h)[:, None, None]
            low = np.clip(1 - v / 0.9, 0, 1) * 0.45 if reg == REG["strips"] else 0.15
            f = np.maximum(edge, low)
            rgb = rgb * (1 - f) + tear * f
            # cut-away pixels get a deep shadow colour: if a renderer ever ignores the alpha test,
            # the gaps between strips still read as dark gaps, not as a flat band
            rgb = np.where(al[..., None] > 0.5, rgb, np.array((0.12, 0.11, 0.09), np.float32))
            a[..., :3] = rgb
            a[..., 3] = al
            put(reg, a)
        dirty_torn(lower, REG["strips"], 3)
        dirty_torn(upper, REG["holes"], 4)

    # skin: the mottled waxy skin, matched to the old skin tone so the figure keeps its colour
    w, h = size(REG["skin"])
    sk = load_tex("orderly_skin.png", w, h)
    if sk is not None:
        rgb = soften(sk[..., :3], 1.0)
        mean = rgb.reshape(-1, 3).mean(0)
        rgb = mean + (rgb - mean) * 0.55  # rule 14: keep texture noise low, it crawls at 480x270
        rgb = rgb / mean * np.array(C["skin_mean"], np.float32)
        one = np.ones((h, w, 1), np.float32)
        put(REG["skin"], np.dstack([rgb, one]))
        put(REG["skin_lo"], np.dstack([rgb * 0.80 * np.array((1.0, 0.95, 0.97)), one]))
        put(REG["skin_hi"], np.dstack([rgb * 1.09, one]))
        put(REG["bruise"], np.dstack([rgb * 0.80 * np.array((1.0, 0.88, 0.96)), one]))
        put(REG["skin_dk"], np.dstack([rgb * 0.6, one]))

    # sewn lids: the Gemini decal (an oval of puckered, bruised skin with thick thread) turned so the
    # seam runs across, set into skin; its edge fades into the skin so it is not a disc
    w, h = size(REG["socket"])
    dec = load_tex("orderly_eyelid.png")
    if dec is not None:
        x0, y0, x1, y1 = region_px(REG["skin"])
        base = img[y0:y1, x0:x1, :3]
        skin_tile = np.tile(base, (h // base.shape[0] + 1, w // base.shape[1] + 1, 1))[:h, :w]
        out = skin_tile.copy()
        D = 104  # decal size in atlas pixels (its oval then meets the socket's rim ring)
        dd = np.rot90(dec, 1)
        ys = ((np.arange(D) + 0.5) * dd.shape[0] / D).astype(int)
        xs = ((np.arange(D) + 0.5) * dd.shape[1] / D).astype(int)
        dd = dd[ys][:, xs]
        oy, ox = (h - D) // 2, (w - D) // 2
        yy, xx = np.mgrid[0:D, 0:D]
        rr = np.sqrt((xx - D / 2 + 0.5) ** 2 + (yy - D / 2 + 0.5) ** 2) / (D * 0.47)
        inside = rr < 1.0
        slit = inside & (dd[..., 3] < 0.5)  # the gap between the lids where the decal is cut out
        # judge round: at 10 m the seam must still read, so thicken it into a bold dark line across
        # (a slit, never a dark disc, which reads as sunglasses)
        sy = np.abs(yy - D / 2 + 0.5)
        sx = np.abs(xx - D / 2 + 0.5)
        taper = np.clip(1 - (sx / (D * 0.34)) ** 2, 0, 1)
        slit |= (sy - 0.9 * np.sin(xx * 0.21) < 0.8 + 2.4 * taper + 0.5 * np.sin(xx * 0.9)) & (taper > 0)
        for _ in range(1):
            slit = slit | np.roll(slit, 1, 0) & inside
        rgb = dd[..., :3].copy()
        # match the decal's skin to the head's skin, then shade it darker toward the seam (sunken)
        sel = inside & ~slit
        rgb = rgb / rgb[sel].mean(0) * base.reshape(-1, 3).mean(0) * 0.97
        rgb *= (0.78 + 0.22 * np.clip(rr, 0, 1))[..., None]
        rgb[slit] = (0.16, 0.10, 0.09)
        k = np.clip((1.0 - rr) / 0.45, 0, 1)[..., None] * inside[..., None]  # a wide fade: no disc edge
        patch = out[oy:oy + D, ox:ox + D]
        out[oy:oy + D, ox:ox + D] = patch * (1 - k) + rgb * k
        put(REG["socket"], np.dstack([out, np.ones((h, w, 1), np.float32)]))


def make_material(image):
    mat = bpy.data.materials.new(P["name"] + "_mat")
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
    bsdf.inputs["Roughness"].default_value = 0.9
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.15
    mat.use_backface_culling = False  # gown, sleeves and mask are open shells -> glTF doubleSided
    # third pass: torn cloth is cut by the texture's alpha. A Math "Round" node between the alpha and
    # the shader is what the glTF exporter reads as alpha test (alphaMode MASK, cutoff 0.5), which
    # three.js draws as alphaTest, not as blended transparency.
    rnd = nt.nodes.new("ShaderNodeMath")
    rnd.operation = "ROUND"
    nt.links.new(tex.outputs["Alpha"], rnd.inputs[0])
    nt.links.new(rnd.outputs[0], bsdf.inputs["Alpha"])
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "DITHERED"
    return mat


# ============================ ASSEMBLY ============================
def collect_mesh():
    mb = MeshBuilder()
    build_torso(mb)
    build_spine_knobs(mb)
    build_scapulae(mb)
    build_neck(mb)
    build_head(mb)
    build_cap(mb)
    build_mask(mb)
    for side, sfx in ((1, ".L"), (-1, ".R")):
        build_arm(mb, side, sfx)
        build_leg(mb, side, sfx)
    build_gown(mb)
    return mb


IDLE_SAG = 0.135  # how much lower the cap sits in the idle pose than at rest


def build_mesh(mb, arm, bt):
    K = P["scale"]
    me = bpy.data.meshes.new(P["name"])
    me.from_pydata([tuple(c * K) for c in mb.co], [], mb.faces)
    me.update()
    uvl = me.uv_layers.new(name="UVMap")
    for poly, uvs in zip(me.polygons, mb.uvs):
        for k in range(poly.loop_total):
            uvl.data[poly.loop_start + k].uv = uvs[k]
    for poly, sm in zip(me.polygons, mb.sm):
        poly.use_smooth = sm  # flat, late-90s shading on the body; the paper gown is smooth
    ob = bpy.data.objects.new(P["name"], me)
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


# ============================ ANIMATION ============================
AX = {"x": Vector((1, 0, 0)), "y": Vector((0, 1, 0)), "z": Vector((0, 0, 1))}


def set_pose(arm, spec):
    """spec: {bone: [op, ...]}. Ops, all about armature (rest) axes:
        ("x"|"y"|"z", degrees)  rotate relative to the parent (+x pitches an up-bone forward,
                                swings a down-bone back)
        ("level",)              cancel every ancestor's rotation, so the bone keeps its rest
                                orientation in the world (the head stays level); later rotations
                                on the same bone are then world-space
        ("s", (sx, sy, sz))     bone-local scale (y runs along the bone)
        ("t", (x, y, z))        translate in armature space (metres)
    """
    bones = arm.pose.bones
    for pb in bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
        pb.scale = (1, 1, 1)
    D = {}  # accumulated rest-axis rotation from the root to each bone
    for pb in bones:  # bones iterate parents first (creation order)
        parentD = D[pb.parent.name] if pb.parent else Quaternion()
        ops = spec.get(pb.name, [])
        q = Quaternion()
        t = None
        level = any(o[0] == "level" for o in ops)
        for op in ops:
            if op[0] == "s":
                pb.scale = op[1]
            elif op[0] == "t":
                t = (t if t is not None else Vector()) + Vector(op[1]) * P["scale"]
            elif op[0] in AX:
                q = Quaternion(AX[op[0]], math.radians(op[1])) @ q
        if level:  # q is now the bone's world (rest-axis) rotation: undo the parents
            q = parentD.inverted() @ q
        B = pb.bone.matrix_local.to_quaternion()
        pb.rotation_quaternion = B.inverted() @ q @ B
        D[pb.name] = parentD @ q
        if t is not None:
            pb.location = B.inverted() @ (parentD.inverted() @ t)


def iter_fcurves(act):
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for cb in strip.channelbags:
                for fc in cb.fcurves:
                    yield fc


def make_action(arm, name, keys, interp):
    """keys: list of (frame, spec) or (frame, spec, interpolation-from-this-key)."""
    bpy.context.preferences.edit.keyframe_new_interpolation_type = interp
    ad = arm.animation_data or arm.animation_data_create()
    act = bpy.data.actions.new(name)
    ad.action = act
    per = {}
    for key in keys:
        frame, spec = key[0], key[1]
        per[frame] = key[2] if len(key) > 2 else interp
        set_pose(arm, spec)
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


def mirror(spec):
    """Swap .L/.R and flip y/z rotation signs and x translation."""
    out = {}
    for b, ops in spec.items():
        nb = b.replace(".L", ".#").replace(".R", ".L").replace(".#", ".R")
        new = []
        for o in ops:
            if o[0] in "yz" and len(o) > 1:
                new.append((o[0], -o[1]))
            elif o[0] == "t":
                new.append(("t", (-o[1][0], o[1][1], o[1][2])))
            else:
                new.append(o)
        out[nb] = new
    return out


def merge(*specs):
    out = {}
    for s in specs:
        for b, ops in s.items():
            out.setdefault(b, []).extend(ops)
    return out


def curl(sfx, a, spread=0.0, side=None):
    """Curl a whole hand's fingers by a degrees toward the palm (rest axes)."""
    sgn = 1 if sfx == ".L" else -1
    sp = {"index": -spread, "middle": 0, "ring": spread}
    out = {}
    for f, n in (("index", 3), ("middle", 3), ("ring", 2)):
        for i in range(1, n + 1):
            ops = [("y", sgn * a * (0.6 if i == 1 else 1.0))]
            if i == 1 and spread:
                ops.append(("x", sp[f]))
            out[f"{f}{i}{sfx}"] = ops
    out["thumb" + sfx] = [("y", sgn * a * 0.4)]
    return out


# ---------------- posture ----------------
def body_pose():
    """Everything but the arms. Not a person standing normally: knees soft, pelvis pushed forward,
    the back folding over at the top, the head carried far out in front and inclined attentively,
    both shoulders drawn up toward the ears and the left one much higher, one foot turned out."""
    return {
        "hips": [("t", (0, -0.030, -0.014))],
        "spine": [("x", -3)], "spine1": [("x", 5)], "spine2": [("x", 13)], "neck": [("x", 19)],
        "thigh.L": [("x", -11), ("z", 9)], "thigh.R": [("x", -6), ("z", -2)],
        "shin.L": [("x", 18)], "shin.R": [("x", 12)],
        "foot.L": [("x", -7), ("z", 24)], "foot.R": [("x", -6), ("z", -5)],
        "clavicle.L": [("y", -27)], "clavicle.R": [("y", 17)],
        "head": [("level",), ("y", -31), ("x", 7)],
        # third pass: the cloth bones hang plumb whatever the body does; actions add swing on top
        "skirt.F.L": [("level",)], "skirt.F.R": [("level",)], "skirt.B.L": [("level",)],
        "skirt.B.R": [("level",)], "sleeve_rag.R": [("level",)],
    }


def cloth(fl=0.0, fr=0.0, bl=0.0, br=0.0, side=0.0, rag=0.0, rag_side=0.0):
    """Swing of the hem strips and the sleeve rag in degrees (world axes, since the bones are levelled):
    + x swings the hanging cloth backward, + z (side) toward the figure's right."""
    return {"skirt.F.L": [("x", fl), ("z", side)], "skirt.F.R": [("x", fr), ("z", side)],
            "skirt.B.L": [("x", bl), ("z", side)], "skirt.B.R": [("x", br), ("z", side)],
            "sleeve_rag.R": [("x", rag), ("z", rag_side)]}


# Where the wrists rest when the hands are folded in front, waiting to be useful (unscaled metres).
CLASP_TARGET = {".L": (0.040, -0.315, 1.400), ".R": (-0.028, -0.392, 1.448)}
ELBOW_OUT = 0.37  # the elbows stand out to the sides: a waiting posture that reads as a shape far off
CLASP = {}  # filled by solve_arm() in main(): upper and forearm rotations for the folded hands


def solve_arm(arm, spec, sfx, target, elbow_out=0.0, guess=(-35.0, 0.0, 0.0, -80.0)):
    """Two-bone reach by coordinate descent on the real rig: finds upperarm (x, y, z) and forearm x
    rotations that put the wrist on `target`, preferring the elbow at least `elbow_out` metres out
    to the side (unscaled). Returns the ops for those two bones."""
    tgt = Vector(target) * P["scale"]
    pb = arm.pose.bones["forearm" + sfx]
    side = 1 if sfx == ".L" else -1

    def ops(q):
        return {"upperarm" + sfx: [("x", q[0]), ("y", q[1]), ("z", q[2])], "forearm" + sfx: [("x", q[3])]}

    def err(q):
        set_pose(arm, merge(spec, ops(q)))
        bpy.context.view_layer.update()
        e = (arm.matrix_world @ pb.tail - tgt).length
        return e + 1.0 * max(0.0, elbow_out * P["scale"] - side * pb.head.x)

    q = list(guess)
    best = err(q)
    step = 16.0
    while step > 0.2:
        better = False
        for i in range(4):
            for d in (step, -step):
                t = list(q)
                t[i] += d
                t[3] = min(0.0, max(-150.0, t[3]))  # elbows only bend one way
                e = err(t)
                if e < best - 1e-7:
                    best, q, better = e, t, True
        if not better:
            step *= 0.5
    print(f"[build] {sfx} wrist solve: error {best * 1000:.1f} mm, angles {[round(v, 1) for v in q]}")
    return ops(q)


def clasp_arms(side=None):
    """One long hand resting politely in the other, in front of the body. side limits it to one arm."""
    out = merge(
        {k: v for k, v in CLASP.items()},
        {"hand.L": [("level",), ("z", -80), ("y", 18), ("x", -8)],
         "hand.R": [("level",), ("z", 84), ("y", -24), ("x", -34)]},
        curl(".L", 8, spread=3), curl(".R", 20, spread=4))
    if side:
        out = {k: v for k, v in out.items() if k.endswith(side)}
    return out


def hang_arms():
    """For walking: the arms hang differently from each other; the left forearm is lifted with the
    fingers in a small beckoning curl."""
    return merge({"upperarm.L": [("y", 4), ("x", -8)], "forearm.L": [("x", -38)], "hand.L": [("x", -12)],
                  "upperarm.R": [("y", 3), ("x", -4)], "forearm.R": [("x", -6)]},
                 curl(".L", 34, spread=6), curl(".R", 10))


def base_pose(arms="clasp"):
    return merge(body_pose(), clasp_arms() if arms == "clasp" else hang_arms())


def idle_keys():
    """4 s, in an attitude of service. The body breathes; the head does not move. The fingers of
    the upper hand close one at a time (stepped), and once the head snaps further over and holds."""
    def breath(a):
        return merge({"spine1": [("x", -a * 0.5)], "spine2": [("x", -a * 0.8)],
                      "clavicle.L": [("y", a * 0.9)], "clavicle.R": [("y", -a * 0.9)]},
                     cloth(fl=a * 0.8, fr=-a * 0.5, bl=-a * 0.6, br=a * 0.4, rag=a * 1.5, rag_side=-a))

    def head(tilt=0.0, turn=0.0):
        return {"head": [("y", tilt), ("z", turn)]}
    keys = []
    B = base_pose()
    keys.append((1, merge(B, breath(0), head()), "BEZIER"))
    keys.append((25, merge(B, breath(1.8), head()), "BEZIER"))
    keys.append((40, merge(B, breath(0.6), head()), "CONSTANT"))
    fing = {}
    for j, f in enumerate(("index1.R", "middle1.R", "ring1.R")):
        fing.setdefault(f, []).append(("y", -24))
        keys.append((43 + j * 3, merge(B, breath(0.6), head(), dict(fing)), "CONSTANT"))
    keys.append((55, merge(B, breath(0.4), head(), dict(fing)), "CONSTANT"))
    keys.append((58, merge(B, breath(0.4), head(-14, 8), dict(fing)), "CONSTANT"))
    keys.append((61, merge(B, breath(0.5), head(-16, 9), dict(fing)), "CONSTANT"))
    keys.append((79, merge(B, breath(0.3), head(), dict(fing)), "BEZIER"))
    keys.append((97, merge(B, breath(0), head()), "BEZIER"))
    return keys


def bump(p, c, w):
    d = (p - c + math.pi) % (2 * math.pi) - math.pi
    return math.exp(-(d / w) ** 2)


WALK = dict(poses=16, thigh=24.0, drop=0.050, sway=3.0, twist=5.0, arm=9.0, lurch=5.0)


def walk_pose(p):
    """Heavy, long-legged gait. p = 0: left heel strikes. Head held level at a constant height."""
    W = WALK

    def leg(sfx, ph):
        th = -W["thigh"] * math.cos(ph)
        kn = 4 + 16 * bump(ph, 0.45, 0.45) + 30 * bump(ph, 3.9, 0.7)
        ft = -(th + kn) * 0.85 + 26 * bump(ph, 3.6, 0.7)  # toes drag through the swing
        return {"thigh" + sfx: [("x", th)], "shin" + sfx: [("x", kn)], "foot" + sfx: [("x", ft)]}

    load = bump(p, 0.45, 0.5) + bump(p, math.pi + 0.45, 0.5)
    drop = -W["drop"] * load
    sway = W["sway"] * math.cos(p)
    tw = W["twist"] * math.cos(p)
    arm_l = W["arm"] * math.cos(p - 0.9)  # arms swing late, like dead weight
    # third pass: the hem strips follow the thighs late and loosely; the sleeve rag swings with the arm
    th = lambda ph: -W["thigh"] * math.cos(ph)
    cl = cloth(fl=0.55 * th(p - 0.9) + 3, fr=0.55 * th(p + math.pi - 0.9) + 3,
               bl=0.35 * th(p - 1.3) + 2, br=0.35 * th(p + math.pi - 1.3) + 2,
               side=4.0 * math.sin(p - 0.8), rag=-14 * math.cos(p - 1.6 - math.pi) + 4,
               rag_side=5 * math.sin(p - 1.2))
    return merge(base_pose("hang"), leg(".L", p), leg(".R", p + math.pi), cl, {
        "hips": [("t", (0, 0, drop)), ("y", -sway), ("z", tw)],
        "spine": [("y", sway * 0.6), ("z", -tw * 0.5)],
        "spine1": [("x", W["lurch"] * load), ("z", -tw * 0.4)],
        "spine2": [("x", 2 * load)],
        "upperarm.L": [("x", arm_l * 0.5)], "upperarm.R": [("x", -arm_l)],
        "forearm.R": [("x", -0.5 * W["arm"] * math.cos(p - 1.6))],
        "head": [("t", (0, 0, -drop))],
    })


def walk_keys():
    st = P["step"]
    n = WALK["poses"]
    keys = [(1 + i * st, walk_pose(2 * math.pi * i / n)) for i in range(n)]
    keys.append((1 + n * st, walk_pose(0)))
    return keys


def reach_keys():
    """An offer of help: the right hand leaves the left, turns palm up and comes toward you low, and
    the arm keeps on lengthening; the body bows a little, the head stays inclined."""
    st = P["step"]
    R = ".R"
    stages = [  # (pitch, roll 0..1, stretch, bow, fingers open 0..1)
        (-34, 0.2, 1.0, 2, 0.1), (-52, 0.45, 1.0, 3, 0.25), (-68, 0.7, 1.0, 4, 0.45), (-80, 0.9, 1.06, 5, 0.65),
        (-88, 1.0, 1.14, 6, 0.8), (-92, 1.0, 1.24, 6, 0.9), (-94, 1.0, 1.33, 7, 1.0), (-95, 1.0, 1.40, 7, 1.0),
        (-96, 1.0, 1.44, 7, 1.0), (-96, 1.0, 1.45, 7, 1.0), (-96, 1.0, 1.46, 8, 1.0)]
    keys = [(1, base_pose())]
    for i, (pitch, roll, stch, bow, op) in enumerate(stages):
        spec = merge(body_pose(), clasp_arms(".L"), curl(R, 6 - 16 * op, spread=12 * op), {
            "upperarm" + R: [("z", -90 * roll), ("x", pitch + 16 * op), ("y", 4)],
            "clavicle" + R: [("x", pitch * 0.08)],
            "forearm" + R: [("x", -24 * op), ("s", (1, stch, 1))],
            "hand" + R: [("x", 8 * op), ("s", (1, 1 / stch, 1))],
            "spine2": [("x", bow)], "spine1": [("x", bow * 0.4)]},
            cloth(fl=-1.5 * (i % 2), br=1.0 * ((i + 1) % 2), rag=-3 * roll + 4 * (i % 2)))
        keys.append((1 + (i + 1) * st, spec))
    return keys


def duck_pose(f):
    """f = 0 standing, 1 fully folded to pass under a 2.1 m door frame. The body folds at the
    hunch, the arms hang straight down from the bent body, and the head stays level."""
    e = f
    return merge(base_pose("hang"), {
        "hips": [("t", (0, 0.02 * e, -0.08 * e)), ("x", 6 * e)],
        "thigh.L": [("x", -24 * e)], "thigh.R": [("x", -20 * e)],
        "shin.L": [("x", 36 * e)], "shin.R": [("x", 32 * e)],
        "foot.L": [("x", -12 * e)], "foot.R": [("x", -12 * e)],
        "spine": [("x", 6 * e)], "spine1": [("x", 15 * e)], "spine2": [("x", 24 * e)],
        "neck": [("x", -10 * e)],
        "upperarm.L": [("level",), ("x", -4 * e), ("y", 6 * e)],
        "upperarm.R": [("level",), ("x", -8 * e), ("y", -5 * e)],
    }, cloth(fl=-16 * e, fr=-13 * e, bl=-4 * e, br=-4 * e, rag=-3 * e))


def duck_keys():
    st = P["step"]
    seq = [0, 0.08, 0.25, 0.45, 0.65, 0.82, 0.95, 1.0, 1.0, 1.0, 0.97, 1.0, 1.0, 1.0, 0.9, 0.72, 0.5, 0.3,
           0.14, 0.04, 0.0]
    keys = []
    for i, f in enumerate(seq):
        spec = duck_pose(f)
        if i == 10:  # a twitch of the head while folded
            spec = merge(spec, {"head": [("y", 12)]})
        keys.append((1 + i * st, spec))
    return keys


def still_keys():
    """Frozen mid-step, as if caught: weight on the back foot, one hand lifted in a beckoning curl."""
    spec = merge(body_pose(), {
        "thigh.L": [("x", -16)], "shin.L": [("x", 8)], "foot.L": [("x", 10)],
        "thigh.R": [("x", 14)], "shin.R": [("x", 18)], "foot.R": [("x", 2)],
        "hips": [("y", -3), ("t", (0, 0, -0.02))], "spine": [("y", 2)], "spine2": [("z", 8)],
        "head": [("y", -6)],
        "upperarm.L": [("x", -22), ("y", 6)], "forearm.L": [("x", -70)], "hand.L": [("x", -24)],
        "upperarm.R": [("y", 3), ("x", -4)], "forearm.R": [("x", -8)]},
        curl(".L", 55, spread=10), curl(".R", 12),
        cloth(fl=-9, fr=6, bl=-3, br=4, side=-2, rag=5))  # caught mid-step: the strips still swinging
    return [(1, spec), (2, spec)]


# ============================ MAIN ============================
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "public", "assets", "entities", "orderly.glb"))
    ap.add_argument("--blend", default="")
    ap.add_argument("--atlas", default="", help="also save the atlas PNG here, for review")
    args = ap.parse_args(argv)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.fps = P["fps"]
    mb = collect_mesh()
    P["scale"] = P["height"] / (max(c.z for c in mb.co) - IDLE_SAG)
    print(f"[build] scale {P['scale']:.4f}")
    bt = bone_table()
    arm = build_armature(bt)
    ob = build_mesh(mb, arm, bt)
    atlas = make_atlas()
    if args.atlas:
        cp = atlas.copy()
        cp.filepath_raw = args.atlas
        cp.file_format = "PNG"
        cp.save()
    ob.data.materials.append(make_material(atlas))
    for sfx in (".L", ".R"):
        CLASP.update(solve_arm(arm, body_pose(), sfx, CLASP_TARGET[sfx], ELBOW_OUT))

    make_action(arm, "idle", idle_keys(), "BEZIER")
    make_action(arm, "walk", walk_keys(), "CONSTANT")
    make_action(arm, "reach", reach_keys(), "CONSTANT")
    make_action(arm, "duck", duck_keys(), "CONSTANT")
    make_action(arm, "still", still_keys(), "CONSTANT")
    set_pose(arm, {})
    scn.frame_start, scn.frame_end = 1, 97

    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    zs = [v.co.z for v in ob.data.vertices]
    print(f"[build] verts={len(ob.data.vertices)} tris={tris} bones={len(arm.data.bones)} height={max(zs):.3f}")
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    if args.blend:
        bpy.ops.wm.save_as_mainfile(filepath=args.blend)
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB", export_animations=True,
                              export_animation_mode="ACTIONS", export_skins=True, export_yup=True,
                              export_apply=False, export_force_sampling=True, export_anim_slide_to_zero=True)
    print("[build] exported", args.out, os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
