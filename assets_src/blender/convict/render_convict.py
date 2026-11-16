"""Check the Convict's exports in a fresh scene and render the review images.

Usage:
  blender.exe --background --factory-startup --python-exit-code 1 --python render_convict.py
        -- [--verify-only] [--only turn,lineup,player,closeup,blackout,wire,bend,headwear]

--verify-only re-imports the Mixamo FBX (and the OBJ from the zip, and the glb) and prints counts, size, materials,
image sizes, a mirror test and non-manifold edges; it also reads the FBX file itself for the unit
scale and the raw vertex extent, which is what Mixamo sees.

The renders reuse the Orderly's corridor, lights and camera helpers (render_orderly.py, imported, not
edited). Poses other than the T-pose come from a throwaway test rig with automatic weights, built
here and never exported.
"""
import bpy, bmesh, sys, os, math, time, argparse, struct, zlib, importlib.util
import numpy as np
from mathutils import Vector, Matrix
from mathutils.kdtree import KDTree

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(ROOT, "assets_src", "renders", "convict")
GLB = os.path.join(HERE, "convict_tpose.glb")
FBX = os.path.join(ROOT, "assets_src", "inbox", "convict-for-mixamo.fbx")
ZIP = os.path.join(ROOT, "assets_src", "inbox", "convict-for-mixamo.zip")
SCRATCH = os.path.join(ROOT, ".local", "convict-scratch")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


RO = load_module("render_orderly", os.path.join(ROOT, "assets_src", "blender", "orderly", "render_orderly.py"))
BC = load_module("build_convict", os.path.join(HERE, "build_convict.py"))

# the game's jumpsuit tints (src/render/crewFigures.ts SUIT_TINTS) and number ink
TINTS = dict(orange=0xd0662c, blue=0x5f86ad, mustard=0xc4a12a, green=0x7c9a46)
INK = 0x1b1a18


def srgb_hex(h):
    return tuple((h >> s & 255) / 255.0 for s in (16, 8, 0))


def lin(c):
    return tuple(v ** 2.2 for v in c)


# ============================ FBX READER ============================
def read_fbx(path):
    """Minimal binary FBX reader: returns the node tree as (name, props, children)."""
    data = open(path, "rb").read()
    assert data[:20] == b"Kaydara FBX Binary  ", "not a binary FBX"
    ver = struct.unpack_from("<I", data, 23)[0]
    wide = ver >= 7500
    hdr = "<QQQ" if wide else "<III"
    hlen = 24 if wide else 12

    def prop(o):
        t = chr(data[o]); o += 1
        simple = {"Y": "<h", "C": "<?", "I": "<i", "F": "<f", "D": "<d", "L": "<q"}
        if t in simple:
            v = struct.unpack_from(simple[t], data, o)[0]
            return v, o + struct.calcsize(simple[t])
        if t in "fdlib":
            n, enc, clen = struct.unpack_from("<III", data, o); o += 12
            raw = data[o:o + clen]; o += clen
            if enc == 1:
                raw = zlib.decompress(raw)
            fmt = {"f": "f", "d": "d", "l": "q", "i": "i", "b": "?"}[t]
            return np.frombuffer(raw, dtype=np.dtype("<" + fmt)), o
        if t in "SR":
            n = struct.unpack_from("<I", data, o)[0]; o += 4
            v = data[o:o + n]; o += n
            return (v.decode("utf-8", "replace") if t == "S" else v), o
        raise ValueError(t)

    def node(o):
        end, nprop, plen = struct.unpack_from(hdr, data, o); o += hlen
        if end == 0:
            return None, o
        nl = data[o]; o += 1
        name = data[o:o + nl].decode(); o += nl
        props = []
        for _ in range(nprop):
            v, o = prop(o)
            props.append(v)
        kids = []
        while o < end:
            k, o2 = node(o)
            if k is None:
                o = o2
                break
            kids.append(k)
            o = o2
        return (name, props, kids), end

    o, top = 27, []
    while o < len(data) - hlen:
        n, o = node(o)
        if n is None:
            break
        top.append(n)
    return ver, top


def fbx_find(nodes, name):
    for n in nodes:
        if n[0] == name:
            yield n
        yield from fbx_find(n[2], name)


def fbx_props70(n):
    out = {}
    for p in fbx_find(n[2], "P"):
        out[p[1][0]] = p[1][4:]
    return out


def fbx_raw_report(path):
    ver, top = read_fbx(path)
    gs = next(fbx_find(top, "GlobalSettings"))
    g = fbx_props70(gs)
    print(f"fbx raw: version {ver}, UnitScaleFactor {g.get('UnitScaleFactor')}, OriginalUnitScaleFactor "
          f"{g.get('OriginalUnitScaleFactor')}, UpAxis {g.get('UpAxis')} sign {g.get('UpAxisSign')}, "
          f"FrontAxis {g.get('FrontAxis')} sign {g.get('FrontAxisSign')}")
    for m in fbx_find(top, "Model"):
        p = fbx_props70(m)
        print(f"fbx raw: model {m[1][1].split(chr(0))[0]!r} type {m[1][2]!r} Lcl Translation {p.get('Lcl Translation')} "
              f"Lcl Rotation {p.get('Lcl Rotation')} Lcl Scaling {p.get('Lcl Scaling')}")
    for gnode in fbx_find(top, "Geometry"):
        v = next(fbx_find(gnode[2], "Vertices"))[1][0].reshape(-1, 3)
        print(f"fbx raw: geometry vertices {len(v)}, extent x {np.ptp(v[:, 0]):.4f} y {np.ptp(v[:, 1]):.4f} "
              f"z {np.ptp(v[:, 2]):.4f} (file units), min y {v[:, 1].min():.4f}")
    vids = list(fbx_find(top, "Video"))
    for vd in vids:
        c = list(fbx_find(vd[2], "Content"))
        size = len(c[0][1][0]) if c and c[0][1] and isinstance(c[0][1][0], (bytes, bytearray)) else 0
        print(f"fbx raw: embedded texture {vd[1][1].split(chr(0))[0]!r}, {size} bytes")


# ============================ VERIFY ============================
def mesh_report(tag, objs):
    meshes = [o for o in objs if o.type == "MESH"]
    print(f"{tag}: objects {len(objs)} ({', '.join(o.type for o in objs)}), meshes {len(meshes)}")
    for ob in meshes:
        dg = bpy.context.evaluated_depsgraph_get()
        me = ob.evaluated_get(dg).to_mesh()
        mw = ob.matrix_world
        vs = np.array([mw @ v.co for v in me.vertices])
        tris = sum(len(p.vertices) - 2 for p in me.polygons)
        bm = bmesh.new()
        bm.from_mesh(me)
        nm = sum(1 for e in bm.edges if len(e.link_faces) != 2)
        bm.free()
        kd = KDTree(len(vs))
        for i, v in enumerate(vs):
            kd.insert(v, i)
        kd.balance()
        worst = max(kd.find((-v[0], v[1], v[2]))[2] for v in vs)
        print(f"{tag}: mesh {ob.name}: loc {tuple(round(c, 4) for c in ob.location)} rot "
              f"{tuple(round(c, 4) for c in ob.rotation_euler)} scale {tuple(round(c, 4) for c in ob.scale)}")
        print(f"{tag}:   dimensions (world) x {np.ptp(vs[:, 0]):.3f} y {np.ptp(vs[:, 1]):.3f} z {np.ptp(vs[:, 2]):.3f} m,"
              f" feet at z {vs[:, 2].min():.4f}, top {vs[:, 2].max():.3f}")
        print(f"{tag}:   verts {len(vs)}, polygons {len(me.polygons)}, triangles {tris}, non-manifold edges {nm}")
        print(f"{tag}:   materials {[m.name if m else None for m in ob.data.materials]}")
        for mi, mt in enumerate(ob.data.materials):
            if mt and (mt.name.startswith("number_patch") or mt.name.startswith("face_screen")):
                for sgn, lab in ((-1, "front"), (1, "back")):
                    pts = np.array([mw @ me.vertices[v].co for p in me.polygons if p.material_index == mi
                                    and (mw.to_3x3() @ p.normal).y * sgn > 0 for v in p.vertices])
                    if len(pts):
                        print(f"{tag}:   {mt.name} {lab}: {np.ptp(pts[:, 0]) * 100:.1f} x {np.ptp(pts[:, 2]) * 100:.1f} cm,"
                              f" flat to {np.ptp(pts[:, 1]) * 1000:.2f} mm")
        print(f"{tag}:   mirror test: worst distance to the mirrored vertex {worst * 1000:.3f} mm"
              f" -> {'SYMMETRIC' if worst < 0.001 else 'NOT symmetric'}")
        ob.evaluated_get(dg).to_mesh_clear()
    for im in bpy.data.images:
        if im.size[0]:
            print(f"{tag}:   image {im.name}: {im.size[0]}x{im.size[1]} {'packed' if im.packed_file else im.filepath}")


def verify():
    print("=== RE-IMPORT REPORT ===")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    fbx_raw_report(FBX)
    bpy.ops.import_scene.fbx(filepath=FBX)
    mesh_report("fbx", list(bpy.data.objects))
    import zipfile
    zdir = os.path.join(SCRATCH, "zip")
    os.makedirs(zdir, exist_ok=True)
    with zipfile.ZipFile(ZIP) as z:
        print("zip:", z.namelist())
        z.extractall(zdir)
    for path, op in ((os.path.join(zdir, "convict-for-mixamo.obj"), "obj"), (GLB, "glb")):
        bpy.ops.wm.read_factory_settings(use_empty=True)
        if op == "obj":
            bpy.ops.wm.obj_import(filepath=path)
        else:
            bpy.ops.import_scene.gltf(filepath=path, merge_vertices=True)
        mesh_report(op, list(bpy.data.objects))
        if op == "glb":
            print("glb: (glTF splits vertices at UV seams by design; after welding them back:)")
            weld(next(o for o in bpy.data.objects if o.type == "MESH"))
            mesh_report("glb welded", list(bpy.data.objects))
    print("=== END REPORT ===")


# ============================ SCENE HELPERS ============================
def weld(ob):
    """glTF splits vertices at UV seams; weld them back so the rig sees one surface"""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(ob.data)
    bm.free()


def import_glb(path, weld_it=True):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path, merge_vertices=True)
    ob = next(o for o in bpy.data.objects if o not in before and o.type == "MESH")
    for o in set(bpy.data.objects) - before - {ob}:
        bpy.data.objects.remove(o)
    if weld_it:
        weld(ob)
    return ob


def build_rig(ob):
    """A throwaway rig with Mixamo-like joints, bound with automatic weights."""
    J = {k: Vector(v) for k, v in BC.JOINTS.items()}

    def m(v):
        return Vector((-v.x, v.y, v.z))
    bones = {"hips": (J["hips"], J["spine"], None), "spine": (J["spine"], J["chest"], "hips"),
             "chest": (J["chest"], J["neck"], "spine"), "neck": (J["neck"], J["head"], "chest"),
             "head": (J["head"], J["head_end"], "neck")}
    for sfx, f in ((".L", lambda v: v), (".R", m)):
        bones["clavicle" + sfx] = (f(J["clavicle"]), f(J["shoulder"]), "chest")
        bones["upperarm" + sfx] = (f(J["shoulder"]), f(J["elbow"]), "clavicle" + sfx)
        bones["forearm" + sfx] = (f(J["elbow"]), f(J["wrist"]), "upperarm" + sfx)
        bones["hand" + sfx] = (f(J["wrist"]), f(J["hand_end"]), "forearm" + sfx)
        bones["thigh" + sfx] = (f(J["hip"]), f(J["knee"]), "hips")
        bones["shin" + sfx] = (f(J["knee"]), f(J["ankle"]), "thigh" + sfx)
        bones["foot" + sfx] = (f(J["ankle"]), f(J["toe"]), "shin" + sfx)
    ad = bpy.data.armatures.new("test_rig")
    arm = bpy.data.objects.new("test_rig", ad)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for n, (h, t, p) in bones.items():
        eb = ad.edit_bones.new(n)
        eb.head, eb.tail = h, t
    for n, (h, t, p) in bones.items():
        if p:
            ad.edit_bones[n].parent = ad.edit_bones[p]
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    empty = [n for n in bones if n not in ob.vertex_groups or not any(
        g.group == ob.vertex_groups[n].index and g.weight > 0.01 for v in ob.data.vertices for g in v.groups)]
    print("[rig] automatic weights done; bones with no weights:", empty or "none")
    return arm


def pose(arm, spec):
    """spec: bone -> list of (world axis 'x'|'y'|'z', degrees), applied in the rest frame."""
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0)
    for name, ops in spec.items():
        pb = arm.pose.bones[name]
        R = Matrix.Identity(3)
        for ax, deg in ops:
            R = Matrix.Rotation(math.radians(deg), 3, ax.upper()) @ R
        Mr = pb.bone.matrix_local.to_3x3()
        pb.rotation_quaternion = (Mr.inverted() @ R @ Mr).to_quaternion()
    bpy.context.view_layer.update()


RELAXED = {"upperarm.L": [("y", 76)], "upperarm.R": [("y", -76)],
           "forearm.L": [("z", -14)], "forearm.R": [("z", 14)],
           "clavicle.L": [("y", 6)], "clavicle.R": [("y", -6)]}
# four people standing differently: weight on one leg, a slump, arms not the same. Heads only turn
# (a turn about the vertical keeps the screen upright); a slump is levelled again at the neck.
POSES = {
    "a": {"hips": [("y", 3)], "spine": [("y", -2)], "chest": [("y", -1)], "thigh.R": [("x", -9)], "shin.R": [("x", 17)],
          "foot.R": [("x", -7)], "head": [("z", 8)], "upperarm.L": [("y", 74)], "upperarm.R": [("y", -80)],
          "forearm.L": [("z", -26)], "forearm.R": [("z", 8)], "clavicle.L": [("y", 5)], "clavicle.R": [("y", -6)]},
    "b": {"hips": [("y", -3)], "spine": [("y", 2)], "chest": [("y", 1)], "thigh.L": [("x", -8)], "shin.L": [("x", 15)],
          "foot.L": [("x", -6)], "head": [("z", -10)], "upperarm.L": [("z", -14), ("y", 72)], "upperarm.R": [("y", -78)],
          "forearm.L": [("z", -38)], "forearm.R": [("z", 12)], "clavicle.L": [("y", 4)], "clavicle.R": [("y", -8)]},
    "c": {"spine": [("x", 6)], "chest": [("x", 4)], "neck": [("x", -10)], "head": [("z", 4)],
          "upperarm.L": [("y", 82)], "upperarm.R": [("y", -82)], "forearm.L": [("z", -10)], "forearm.R": [("z", 10)],
          "clavicle.L": [("y", -2)], "clavicle.R": [("y", 2)], "thigh.L": [("x", -4)], "shin.L": [("x", 8)]},
    "d": {"hips": [("y", 2)], "spine": [("y", -2)], "thigh.L": [("z", -4)], "thigh.R": [("z", 4), ("x", -5)], "shin.R": [("x", 9)],
          "head": [("z", -5)], "upperarm.L": [("z", -18), ("y", 70)], "upperarm.R": [("z", 18), ("y", -70)],
          "forearm.L": [("z", -30)], "forearm.R": [("z", 30)], "clavicle.L": [("y", 7)], "clavicle.R": [("y", -7)]},
}
BEND = {"upperarm.R": [("y", 74)], "clavicle.R": [("y", 22)],
        "forearm.L": [("z", -90)],
        "thigh.L": [("x", -60)], "shin.L": [("x", 90)], "foot.L": [("x", -30)]}
STEP = {"thigh.R": [("x", -55)], "shin.R": [("x", 62)], "foot.R": [("x", -8)], "thigh.L": [("x", 6)],
        "upperarm.L": [("x", -40), ("y", 60)], "upperarm.R": [("y", -76)], "forearm.L": [("z", -40)]}


def bake(ob, arm, name):
    """the evaluated (posed) mesh as a new static object standing on the floor, and the matrix that
    carries the head joint's rest frame to where the posed head is"""
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    me.name = name
    lift = -min(v.co.z for v in me.vertices)
    for v in me.vertices:
        v.co.z += lift
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    pb = arm.pose.bones["head"]
    head = Matrix.Translation((0, 0, lift)) @ arm.matrix_world @ pb.matrix @ pb.bone.matrix_local.inverted()
    o["head"] = [c for row in head for c in row]
    return o


def clone(src, name, loc=(0, 0, 0), rot_z=0.0):
    o = src.copy()
    o.data = src.data.copy()
    o.name = name
    o.location = loc
    o.rotation_euler = (0, 0, rot_z)
    for i, mt in enumerate(o.data.materials):
        o.data.materials[i] = mt.copy()
    bpy.context.scene.collection.objects.link(o)
    return o


# 3 x 5 digits
DIGITS = {"0": "111101101101111", "1": "010110010010111", "2": "111001111100111", "3": "111001111001111",
          "4": "101101111001001", "5": "111100111001111", "6": "111100111101111", "7": "111001010010010",
          "8": "111101111101111", "9": "111101111001111"}


def number_image(text, bg, name):
    """the game draws the number on the patch: dark digits on the suit tint; 16:10 like the patch"""
    w, h = 80, 50
    px = np.ones((h, w, 4), np.float32)
    px[..., :3] = bg
    cell, gap = 4, 3
    tw = len(text) * 3 * cell + (len(text) - 1) * gap
    x0, y0 = (w - tw) // 2, (h - 5 * cell) // 2
    for i, ch in enumerate(text):
        bits = DIGITS[ch]
        for r in range(5):
            for c in range(3):
                if bits[r * 3 + c] == "1":
                    xx = x0 + i * (3 * cell + gap) + c * cell
                    yy = h - (y0 + (r + 1) * cell)
                    px[yy:yy + cell, xx:xx + cell, :3] = srgb_hex(INK)
    im = bpy.data.images.new(name, w, h)
    im.pixels.foreach_set(px.ravel())
    return im


# ---- crude doodles, as a player might draw them: 48 x 48, one colour on dark
def _stroke(img, pts, r=1.6):
    pts = np.array(pts, float)
    yy, xx = np.mgrid[0:48, 0:48]
    for a, b in zip(pts, pts[1:]):
        for t in np.linspace(0, 1, 40):
            p = a + (b - a) * t
            img[(xx - p[0]) ** 2 + (yy - p[1]) ** 2 <= r * r] = 1.0


def _arc(cx, cy, rx, ry, a0, a1, n=24, jitter=0.0, seed=0):
    rng = np.random.default_rng(seed)
    return [(cx + rx * math.cos(a) + rng.normal(0, jitter), cy + ry * math.sin(a) + rng.normal(0, jitter))
            for a in np.linspace(math.radians(a0), math.radians(a1), n)]


def doodle(kind):
    """y grows downward here (as drawn on paper); flipped when made into an image"""
    img = np.zeros((48, 48))
    if kind == "smile":
        _stroke(img, _arc(24, 24, 19, 19, 0, 360, 40, 0.4, 1))
        _stroke(img, [(17, 17), (17, 21)], 2.0)
        _stroke(img, [(31, 17), (31, 21)], 2.0)
        _stroke(img, _arc(24, 26, 10, 8, 20, 160, 16, 0.3, 2))
    elif kind == "worried":
        _stroke(img, _arc(24, 25, 18, 20, 0, 360, 40, 0.5, 3))
        _stroke(img, [(14, 17), (21, 14)])
        _stroke(img, [(34, 17), (27, 14)])
        _stroke(img, _arc(18, 21, 2, 2, 0, 360, 10), 1.4)
        _stroke(img, _arc(30, 21, 2, 2, 0, 360, 10), 1.4)
        _stroke(img, [(16, 35), (20, 32), (24, 35), (28, 32), (32, 35)])
    elif kind == "cat":
        _stroke(img, _arc(24, 27, 17, 15, -40, 220, 34, 0.4, 4))
        _stroke(img, [(11, 18), (13, 5), (21, 13)])
        _stroke(img, [(37, 18), (35, 5), (27, 13)])
        _stroke(img, [(17, 24), (17, 26)], 2.0)
        _stroke(img, [(31, 24), (31, 26)], 2.0)
        _stroke(img, [(22, 30), (24, 32), (26, 30)])
        for dy in (-2, 2):
            _stroke(img, [(4, 30 + dy * 2), (15, 31 + dy)], 1.1)
            _stroke(img, [(44, 30 + dy * 2), (33, 31 + dy)], 1.1)
    else:  # an angry scribble
        _stroke(img, _arc(24, 24, 19, 21, 0, 360, 40, 0.8, 5))
        _stroke(img, [(12, 13), (21, 19)])
        _stroke(img, [(36, 13), (27, 19)])
        _stroke(img, [(16, 22), (19, 22)], 2.2)
        _stroke(img, [(29, 22), (32, 22)], 2.2)
        rng = np.random.default_rng(6)
        _stroke(img, [(13 + i * 2.2, 33 + rng.normal(0, 2.2)) for i in range(11)])
    return img[::-1]


SCREEN_INK = dict(smile=(0.70, 1.00, 0.72), worried=(1.00, 0.78, 0.40), cat=(0.55, 0.88, 1.00), angry=(1.00, 0.55, 0.62))


def screen_image(kind):
    a = doodle(kind)
    ink = np.array(SCREEN_INK[kind])
    bg = np.array([0.02, 0.035, 0.03])
    px = np.ones((48, 48, 4), np.float32)
    px[..., :3] = bg[None, None, :] * (1 - a[..., None]) + ink[None, None, :] * a[..., None]
    px[::2, :, :3] *= 0.82  # scanlines
    im = bpy.data.images.new("doodle_" + kind, 48, 48)
    im.pixels.foreach_set(px.ravel())
    return im


SKIN_IMG = {}


def person(o, colour_hex, number, skin=1, face="smile", glow=2.5):
    """tint the suit, draw the number, choose the skin tone and light the screen with a doodle"""
    c = srgb_hex(colour_hex)
    for mt in o.data.materials:
        nt = mt.node_tree
        bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
        if mt.name.startswith("convict_suit"):
            tex = next(n for n in nt.nodes if n.type == "TEX_IMAGE")
            mix = nt.nodes.new("ShaderNodeMix")
            mix.data_type = "RGBA"
            mix.blend_type = "MULTIPLY"
            mix.inputs[0].default_value = 1.0
            mix.inputs[7].default_value = (*lin(c), 1)
            nt.links.new(tex.outputs["Color"], mix.inputs[6])
            nt.links.new(mix.outputs[2], bsdf.inputs["Base Color"])
        elif mt.name.startswith("convict_skin"):
            tex = next(n for n in nt.nodes if n.type == "TEX_IMAGE")
            if skin not in SKIN_IMG:
                SKIN_IMG[skin] = bpy.data.images.load(os.path.join(HERE, f"convict_skin_{skin}.png"))
            tex.image = SKIN_IMG[skin]
        elif mt.name.startswith("number_patch"):
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = number_image(number, c, "num_" + number)
            tex.interpolation = "Closest"
            nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        elif mt.name.startswith("face_screen"):
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = screen_image(face)
            tex.interpolation = "Closest"
            nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
            nt.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
            bsdf.inputs["Emission Strength"].default_value = glow
            bsdf.inputs["Roughness"].default_value = 0.25


HEADWEAR = {}


def wear(o, kind):
    """put a headwear piece on a baked figure: its origin goes to the posed head joint"""
    if kind == "none":
        return None
    if kind not in HEADWEAR:
        HEADWEAR[kind] = import_glb(os.path.join(HERE, f"headwear_{kind}.glb"), weld_it=False)
        HEADWEAR[kind].hide_render = True
    h = HEADWEAR[kind].copy()
    bpy.context.scene.collection.objects.link(h)
    h.hide_render = False
    hm = list(o["head"])
    head = Matrix([hm[0:4], hm[4:8], hm[8:12], hm[12:16]])
    J = Vector(BC.JOINTS["head"])
    fig = Matrix.Translation(o.location) @ o.rotation_euler.to_matrix().to_4x4()  # matrix_world is stale until an update
    h.matrix_world = fig @ head @ Matrix.Translation(J)
    bpy.context.view_layer.update()
    top = max((h.matrix_world @ v.co).z for v in h.data.vertices)
    print(f"[wear] {kind} on {o.name}: joint at {tuple(round(c, 3) for c in (fig @ head @ J))}, top {top:.3f}")
    return h


def plain(o, colour):
    for i in range(len(o.data.materials)):
        o.data.materials[i] = RO.mat("plain_%d" % i, colour, rough=0.8)


def upscale(path, k=3):
    im = bpy.data.images.load(path)
    w, h = im.size
    a = np.array(im.pixels[:], np.float32).reshape(h, w, 4)
    a = a.repeat(k, 0).repeat(k, 1)
    out = bpy.data.images.new("up", w * k, h * k)
    out.pixels.foreach_set(a.ravel())
    out.filepath_raw = path
    out.file_format = "PNG"
    out.save()
    return a


def tape(a, path):
    """a rough stand-in for the game's tape look: soft, desaturated toward green-grey, grain"""
    rgb = a[..., :3]
    lum = rgb @ np.array([0.3, 0.59, 0.11])
    rgb = rgb * 0.65 + lum[..., None] * 0.35 * np.array([0.95, 1.02, 0.96])
    k = np.ones(5) / 5
    rgb = np.apply_along_axis(lambda r: np.convolve(r, k, "same"), 1, rgb)
    rng = np.random.default_rng(3)
    rgb = np.clip(rgb + rng.normal(0, 0.025, rgb.shape[:2])[..., None], 0, 1)
    out = a.copy()
    out[..., :3] = rgb
    im = bpy.data.images.new("tape", a.shape[1], a.shape[0])
    im.pixels.foreach_set(out.ravel())
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()


def side_by_side(paths, out):
    RO.contact_sheet(paths, out)
    for p in paths:
        os.remove(p)


def only_show(keep):
    keep = {o for o in keep if o is not None}
    for o in bpy.data.objects:
        if o.type == "MESH" and o.users_collection and o.users_collection[0] == bpy.context.scene.collection:
            o.hide_render = o not in keep


# the crew in the line-up: suit colour, number, skin tone, headwear, drawn face, pose
CREW = [("blue", "2041", 2, "knit", "worried", "a"), ("mustard", "3317", 3, "hair", "cat", "b"),
        ("green", "5126", 4, "none", "angry", "c"), ("orange", "0417", 1, "hair", "smile", "d")]


# ============================ MAIN ============================
def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--only", default="turn,lineup,player,closeup,blackout,wire,bend,headwear")
    args = ap.parse_args(argv)
    only = set(args.only.split(","))
    if args.verify_only:
        verify()
        return
    os.makedirs(OUT, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_EEVEE"
    scn.eevee.taa_render_samples = 16
    scn.view_settings.view_transform = "Standard"
    scn.render.image_settings.file_format = "PNG"
    world = bpy.data.worlds.new("w")
    scn.world = world
    bg = world.node_tree.nodes.get("Background")

    def world_bg(col, strength):
        bg.inputs["Color"].default_value = (*col, 1)
        bg.inputs["Strength"].default_value = strength
    world_bg(RO.R["backdrop"], 1.0)
    backdrop = RO.build_backdrop()
    corridor = RO.build_corridor()
    colls = [backdrop, corridor]

    base = import_glb(GLB)
    base.name = "convict_tpose"
    arm = build_rig(base)
    posed = {}
    for name, spec in list(POSES.items()) + [("relaxed", {}), ("bend", "BEND"), ("step", "STEP")]:
        pose(arm, BEND if spec == "BEND" else {**RELAXED, **STEP} if spec == "STEP" else {**RELAXED, **spec})
        posed[name] = bake(base, arm, "posed_" + name)
        posed[name].hide_render = True
    pose(arm, {})
    base.modifiers.clear()
    base.parent = None
    arm.hide_render = True
    sq = (960, 960)

    if "turn" in only:
        RO.show([backdrop], colls)
        t = clone(base, "turn")
        person(t, TINTS["orange"], "0417", 1, "smile", 1.5)
        only_show([t])
        paths = []
        for name, ang in (("front", 0), ("34", 35), ("side", 90), ("back", 180)):
            a = math.radians(ang)
            loc = (math.sin(a) * 9.0, -math.cos(a) * 9.0, 1.1)
            p = os.path.join(OUT, f"turn_{name}.png")
            RO.render(p, RO.camera("cam_" + name, loc, (0, 0, 0.90), 13.5), sq)
            paths.append(p)
        RO.contact_sheet(paths, os.path.join(OUT, "turnaround.png"))
        t.hide_render = True

    if "lineup" in only:
        RO.show([backdrop], colls)
        figs = []
        for i, (cname, num, skin, hw, face, pz) in enumerate(CREW):
            o = clone(posed[pz], "fig_" + cname, (-1.35 + 0.9 * i, 0, 0))
            person(o, TINTS[cname], num, skin, face, 1.5)
            figs += [o, wear(o, hw)]
        only_show(figs)
        paths = []
        for name, yy in (("front", -1), ("back", 1)):
            cam = RO.camera("cam_line_" + name, (0, yy * 11.0, 1.15), (0, 0, 0.88), 11.5)
            p = os.path.join(OUT, f"_lineup_{name}.png")
            RO.render(p, cam, (1280, 720))
            paths.append(p)
        side_by_side(paths, os.path.join(OUT, "lineup.png"))
        only_show([])

    if "player" in only or "closeup" in only:
        RO.show([corridor], colls)
        world_bg(RO.COL["wall"], RO.R["ambient"])
        near = clone(posed["d"], "pv_near", (-0.30, 0.0, 0))
        person(near, TINTS["orange"], "0417", 1, "smile", 1.2)
        far = clone(posed["a"], "pv_far", (0.35, 5.0, 0), math.radians(-12))
        person(far, TINTS["blue"], "2041", 2, "worried", 1.2)
        keep = [near, far, wear(near, "hair"), wear(far, "knit")]
        only_show(keep)
        if "player" in only:
            cam = RO.camera("cam_player", (0.0, -3.0, RO.R["eye"]), (0.0, 10, RO.R["eye"] - 0.25), RO.R["vfov"])
            p = os.path.join(OUT, "player_view.png")
            RO.render(p, cam, RO.R["lowres"])
            tape(upscale(p, 3), os.path.join(OUT, "player_view_tape.png"))
        if "closeup" in only:
            only_show([keep[0], keep[2]])
            cam = RO.camera("cam_close", (-0.55, -1.25, 1.66), (-0.30, 0, 1.50), 40.0)
            p = os.path.join(OUT, "closeup_mask.png")
            RO.render(p, cam, RO.R["lowres"])
            upscale(p, 3)
        world_bg(RO.R["backdrop"], 1.0)
        only_show([])

    if "blackout" in only:
        RO.show([corridor], colls)
        world_bg((0, 0, 0), 0.0)
        saved = []
        for o in corridor.objects:
            if o.type == "LIGHT":
                saved.append((o.data, o.data.energy))
                o.data.energy = 0.0
        lamp = bpy.data.materials.get("lamp")
        lb = next(n for n in lamp.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        lamp_e = lb.inputs["Emission Strength"].default_value
        lb.inputs["Emission Strength"].default_value = 0.0
        ld = bpy.data.lights.new("amber", "POINT")
        ld.energy = 6.0
        ld.color = (1.0, 0.55, 0.18)
        ld.shadow_soft_size = 0.3
        lo = bpy.data.objects.new("amber", ld)
        lo.location = (0.7, 1.5, 0.12)
        scn.collection.objects.link(lo)
        figs = []
        spots = [((-0.50, 0.4, 0), 15), ((0.30, 1.8, 0), -20), ((-0.25, 4.0, 0), 5), ((0.05, 6.5, 0), -10)]
        for (cname, num, skin, hw, face, pz), (loc, rz) in zip(CREW, spots):
            o = clone(posed[pz], "bo_" + cname, loc, math.radians(rz))
            person(o, TINTS[cname], num, skin, face, 4.0)
            figs += [o, wear(o, hw)]
        only_show(figs)
        cam = RO.camera("cam_bo", (0.0, -3.0, RO.R["eye"]), (0.0, 10, RO.R["eye"] - 0.25), RO.R["vfov"])
        p = os.path.join(OUT, "blackout.png")
        RO.render(p, cam, RO.R["lowres"])
        tape(upscale(p, 3), os.path.join(OUT, "blackout_tape.png"))
        for d, e in saved:
            d.energy = e
        lb.inputs["Emission Strength"].default_value = lamp_e
        ld.energy = 0.0
        world_bg(RO.R["backdrop"], 1.0)
        only_show([])

    if "wire" in only:
        RO.show([backdrop], colls)
        solid = clone(base, "wire_solid")
        plain(solid, (0.75, 0.74, 0.72))
        wire = clone(base, "wire_lines")
        plain(wire, (0.03, 0.03, 0.04))
        mod = wire.modifiers.new("wf", "WIREFRAME")
        mod.thickness = 0.0035
        mod.use_even_offset = False
        only_show([solid, wire])
        paths = []
        for name, loc in (("front", (0, -9, 0.88)), ("side", (-9, 0, 0.88))):
            cd = bpy.data.cameras.new("wc_" + name)
            cd.type = "ORTHO"
            cd.ortho_scale = 2.0
            co = bpy.data.objects.new("wc_" + name, cd)
            co.location = loc
            scn.collection.objects.link(co)
            RO.look_at(co, (0, 0, 0.88))
            p = os.path.join(OUT, f"_wire_{name}.png")
            RO.render(p, co, (1200, 1200))
            paths.append(p)
        side_by_side(paths, os.path.join(OUT, "wireframe.png"))
        only_show([])

    if "bend" in only:
        RO.show([backdrop], colls)
        b1 = clone(posed["bend"], "bend_solid")
        person(b1, TINTS["green"], "5126", 1, "smile", 1.0)
        wire = clone(posed["bend"], "bend_wire")
        plain(wire, (0.03, 0.03, 0.04))
        mod = wire.modifiers.new("wf", "WIREFRAME")
        mod.thickness = 0.0028
        only_show([b1, wire])
        paths = []
        for name, ang in (("34", 40), ("side", 90), ("back34", 150)):
            a = math.radians(ang)
            loc = (math.sin(a) * 8.0, -math.cos(a) * 8.0, 1.25)
            p = os.path.join(OUT, f"_bend_{name}.png")
            RO.render(p, RO.camera("bc_" + name, loc, (0, -0.1, 0.95), 15.0), (800, 960))
            paths.append(p)
        b2 = clone(posed["step"], "step_solid")
        person(b2, TINTS["mustard"], "3317", 3, "cat", 1.0)
        w2 = clone(posed["step"], "step_wire")
        plain(w2, (0.03, 0.03, 0.04))
        w2.modifiers.new("wf", "WIREFRAME").thickness = 0.0028
        only_show([b2, w2])
        for name, ang in (("step34", -35), ("stepfront", 0)):
            a = math.radians(ang)
            loc = (math.sin(a) * 8.0, -math.cos(a) * 8.0, 1.25)
            p = os.path.join(OUT, f"_bend_{name}.png")
            RO.render(p, RO.camera("bc_" + name, loc, (0, -0.1, 0.95), 15.0), (800, 960))
            paths.append(p)
        side_by_side(paths, os.path.join(OUT, "bend_test.png"))
        only_show([])

    if "headwear" in only:
        RO.show([backdrop], colls)
        figs = []
        for i, (hw, skin, face) in enumerate((("knit", 2, "worried"), ("hair", 3, "cat"), ("none", 1, "smile"))):
            o = clone(posed["relaxed"], "hw_" + hw, (-0.6 + 0.6 * i, 0, 0))
            person(o, TINTS["orange"], "0417", skin, face, 1.5)
            figs += [o, wear(o, hw)]
        only_show(figs)
        paths = []
        for name, ang in (("34", 25), ("back34", 155)):
            a = math.radians(ang)
            loc = (math.sin(a) * 6.0, -math.cos(a) * 6.0, 1.75)
            p = os.path.join(OUT, f"_head_{name}.png")
            RO.render(p, RO.camera("hc_" + name, loc, (0, 0, 1.55), 13.0), (900, 600))
            paths.append(p)
        side_by_side(paths, os.path.join(OUT, "headwear.png"))


if __name__ == "__main__":
    main()
