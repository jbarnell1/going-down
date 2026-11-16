"""Rebuild every Clinic prop glb from the source kits and props.json.

Usage (from the repo root):
  <blender> --background --factory-startup --python-exit-code 1 \
      --python assets_src/blender/props/build_props.py -- [--sources DIR] [--only name,name]

Sources default to tools/props under the repo root (not in git). Outputs go to
public/assets/props/<name>.glb plus public/assets/props/manifest.json.

Blender is Z-up with the front of a prop facing -Y; the glTF export turns that into
+Y up with the front facing +Z.
"""
import bpy, bmesh, json, math, os, sys, argparse, struct
import numpy as np
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(ROOT, "public", "assets", "props")
MANIFEST_IN = os.path.join(HERE, "props.json")
LICENCES = {"kenney": "CC0 1.0 (Kenney, Furniture Kit)",
            "quaternius": "CC0 1.0 (Quaternius, Ultimate House Interior Pack)",
            "polyhaven": "CC0 1.0 (Poly Haven)",
            "handbuilt": "CC0 1.0 (built for this game; proportions from a Poly Haven CC0 scan)"}
SHARP_ANGLE = math.radians(35)


def log(*a):
    print("[props]", *a, flush=True)


def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


# ---------------------------------------------------------------- mesh helpers

def glb_triangles(path):
    """Triangles as stored in the exported file (index count / 3 over all primitives)."""
    with open(path, "rb") as f:
        data = f.read()
    n = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + n])
    t = 0
    for m in doc["meshes"]:
        for pr in m["primitives"]:
            acc = doc["accessors"][pr["indices"]] if "indices" in pr else doc["accessors"][pr["attributes"]["POSITION"]]
            t += acc["count"] // 3
    return t, len(doc.get("materials", [])), doc


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def bbox(ob):
    co = np.array([v.co[:] for v in ob.data.vertices]) if len(ob.data.vertices) else np.zeros((1, 3))
    return co.min(0), co.max(0)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_source(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    else:
        raise RuntimeError("unknown source type " + path)


def join_meshes(keep=None):
    """Bake world transforms into every mesh, drop everything else, join into one object."""
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if keep:
        meshes = [o for o in meshes if any(o.name == k or o.name.split(".")[0] == k for k in keep)]
    if not meshes:
        raise RuntimeError("no meshes kept")
    for o in meshes:
        mw = o.matrix_world.copy()
        if o.data.users > 1:
            o.data = o.data.copy()
        o.data.transform(mw)
        o.parent = None
        o.matrix_world = Matrix.Identity(4)
    for o in list(bpy.data.objects):
        if o not in meshes:
            bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = "prop"
    return ob


def triangulate(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    bm.to_mesh(ob.data)
    bm.free()


def duplicate_faces(bm, size):
    q = size * 1e-5
    seen, dup = set(), 0
    for f in bm.faces:
        k = tuple(sorted(tuple(round(c / q) for c in v.co) for v in f.verts))
        dup += k in seen
        seen.add(k)
    return dup


def clean(ob, recalc):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    size = max((Vector(bbox(ob)[1]) - Vector(bbox(ob)[0])).length, 1e-3)
    if duplicate_faces(bm, size):
        # Some kit pieces are thin shells modelled twice, back to back. Merging vertices would
        # delete one side and recalculating would turn both sides the same way: leave them alone.
        log(f"  {duplicate_faces(bm, size)} back-to-back faces kept; no merge, no normal recalculation")
        recalc = False
    else:
        bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=size * 1e-5)
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bmesh.ops.delete(bm, geom=[e for e in bm.edges if not e.link_faces], context="EDGES")
    bmesh.ops.dissolve_degenerate(bm, dist=size * 1e-5, edges=bm.edges[:])
    degenerate = [f for f in bm.faces if f.calc_area() < size * size * 1e-8]
    bmesh.ops.delete(bm, geom=degenerate, context="FACES")
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(ob.data)
    bm.free()


def apply_modifier(ob, mod):
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)


def decimate(ob, budget):
    triangulate(ob)
    t0 = tri_count(ob)
    if t0 <= budget:
        return "none"
    # Planar dissolve first: free for flat kit furniture, keeps the shape exactly.
    m = ob.modifiers.new("planar", "DECIMATE")
    m.decimate_type = "DISSOLVE"
    m.angle_limit = math.radians(1.0)
    m.delimit = {"MATERIAL", "UV"}
    apply_modifier(ob, m)
    triangulate(ob)
    if tri_count(ob) <= budget:
        return "planar"
    target = budget * 0.97
    for _ in range(8):
        t = tri_count(ob)
        if t <= budget:
            break
        m = ob.modifiers.new("collapse", "DECIMATE")
        m.decimate_type = "COLLAPSE"
        m.ratio = max(0.01, target / t)
        m.use_collapse_triangulate = True
        apply_modifier(ob, m)
        triangulate(ob)
        target *= 0.97
    return "collapse"


def smooth_normals(ob, angle=SHARP_ANGLE, flat=False):
    me = ob.data
    if flat:
        me.shade_flat()
        return
    me.shade_smooth()
    try:
        me.set_sharp_from_angle(angle=angle)
    except AttributeError:
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.shade_smooth_by_angle(angle=angle)


def place_origin(ob, mount):
    lo, hi = bbox(ob)
    c = (lo + hi) / 2
    if mount == "floor":
        ref = Vector((c[0], c[1], lo[2]))
    elif mount == "wall":       # back face (+Y in Blender) touches the wall
        ref = Vector((c[0], hi[1], c[2]))
    elif mount == "ceiling":
        ref = Vector((c[0], c[1], hi[2]))
    else:
        raise RuntimeError("bad mount " + mount)
    ob.data.transform(Matrix.Translation(-ref))
    ob.location = (0, 0, 0)


def scale_to(ob, size):
    lo, hi = bbox(ob)
    ext = hi - lo
    dim = size["dim"]
    cur = {"height": ext[2], "length": max(ext[0], ext[1]), "longest": max(ext)}[dim]
    f = size["m"] / cur
    ob.data.transform(Matrix.Scale(f, 4))


def measured(ext, dim):
    return {"height": ext[2], "length": max(ext[0], ext[1]), "longest": max(ext)}[dim]


# ---------------------------------------------------------------- primitives (Blender units: metres)

class Builder:
    """Collects boxes, cylinders and rings into one bmesh with material slots named by palette keys."""

    def __init__(self):
        self.bm = bmesh.new()
        self.slots = []

    def slot(self, key):
        if key not in self.slots:
            self.slots.append(key)
        return self.slots.index(key)

    def _finish(self, geom_verts, mat, matrix):
        bmesh.ops.transform(self.bm, matrix=matrix, verts=geom_verts)
        faces = {f for v in geom_verts for f in v.link_faces}
        idx = self.slot(mat)
        for f in faces:
            f.material_index = idx

    def box(self, center, size, mat, rot=None):
        r = bmesh.ops.create_cube(self.bm, size=1.0)
        verts = r["verts"]
        bmesh.ops.scale(self.bm, vec=Vector(size), verts=verts)
        m = Matrix.Translation(Vector(center))
        if rot is not None:
            m = m @ rot
        self._finish(verts, mat, m)

    def beam(self, a, b, w, mat, d=None):
        """Square-section bar from a to b."""
        a, b = Vector(a), Vector(b)
        L = (b - a).length
        r = bmesh.ops.create_cube(self.bm, size=1.0)
        verts = r["verts"]
        bmesh.ops.scale(self.bm, vec=Vector((w, d or w, L)), verts=verts)
        q = Vector((0, 0, 1)).rotation_difference((b - a).normalized())
        self._finish(verts, mat, Matrix.Translation((a + b) / 2) @ q.to_matrix().to_4x4())

    def cyl(self, center, radius, depth, mat, segs=8, axis="Z"):
        r = bmesh.ops.create_cone(self.bm, cap_ends=True, cap_tris=False, segments=segs,
                                  radius1=radius, radius2=radius, depth=depth)
        verts = r["verts"]
        rot = {"Z": Matrix.Identity(4), "X": Matrix.Rotation(math.pi / 2, 4, "Y"),
               "Y": Matrix.Rotation(math.pi / 2, 4, "X")}[axis]
        self._finish(verts, mat, Matrix.Translation(Vector(center)) @ rot)

    def ring(self, center, radius, tube, mat, segs=16, sides=4, axis="X"):
        """Torus lying in the plane normal to axis."""
        verts = []
        grid = []
        for i in range(segs):
            a = 2 * math.pi * i / segs
            row = []
            for j in range(sides):
                b = 2 * math.pi * j / sides + math.pi / sides
                rr = radius + tube * math.cos(b)
                p = Vector((rr * math.cos(a), rr * math.sin(a), tube * math.sin(b)))
                v = self.bm.verts.new(p)
                row.append(v)
                verts.append(v)
            grid.append(row)
        for i in range(segs):
            for j in range(sides):
                self.bm.faces.new((grid[i][j], grid[(i + 1) % segs][j],
                                   grid[(i + 1) % segs][(j + 1) % sides], grid[i][(j + 1) % sides]))
        rot = {"Z": Matrix.Identity(4), "X": Matrix.Rotation(math.pi / 2, 4, "Y"),
               "Y": Matrix.Rotation(math.pi / 2, 4, "X")}[axis]
        self._finish(verts, mat, Matrix.Translation(Vector(center)) @ rot)

    def to_object(self, name="prop", into=None):
        me = bpy.data.meshes.new(name)
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces[:])
        self.bm.to_mesh(me)
        self.bm.free()
        for key in self.slots:
            mat = bpy.data.materials.get(key) or bpy.data.materials.new(key)
            me.materials.append(mat)
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        if into is not None:  # join into an existing object
            bpy.ops.object.select_all(action="DESELECT")
            ob.select_set(True)
            into.select_set(True)
            bpy.context.view_layer.objects.active = into
            bpy.ops.object.join()
            return into
        return ob


def build_wheelchair():
    """Folding hospital wheelchair, Z-up, front facing -Y, seat about 0.5 m up, handles 0.95 m."""
    B = Builder()
    S, R, F = "steel", "rubber", "mint_dark"
    hw = 0.27            # half width between the side frames
    t = 0.022            # tube size
    wheel_r, wheel_y = 0.30, 0.16
    for s in (-1, 1):
        x = s * hw
        xw = s * (hw + 0.07)
        # rear wheel: tyre ring, hub and four spokes
        B.ring((xw, wheel_y, wheel_r), wheel_r - 0.02, 0.022, R, segs=16, sides=4, axis="X")
        B.ring((xw - s * 0.02, wheel_y, wheel_r), wheel_r - 0.06, 0.008, S, segs=12, sides=3, axis="X")
        B.cyl((xw, wheel_y, wheel_r), 0.035, 0.05, S, segs=6, axis="X")
        for k in range(3):
            a = math.pi * k / 3
            d = Vector((0, math.cos(a), math.sin(a))) * (wheel_r - 0.04)
            c = Vector((xw, wheel_y, wheel_r))
            B.beam(c - d, c + d, 0.012, S)
        # front caster: fork stem and small wheel
        B.beam((x, -0.30, 0.20), (x, -0.30, 0.10), t, S)
        B.cyl((x, -0.30, 0.075), 0.075, 0.035, R, segs=8, axis="X")
        # side frame
        B.beam((x, 0.20, 0.50), (x, 0.24, 0.95), t, S)         # rear post up to the push handle
        B.beam((x, 0.24, 0.95), (x, 0.36, 0.95), t * 1.6, R)    # handle grip
        B.beam((x, -0.30, 0.20), (x, 0.20, 0.30), t, S)         # lower rail
        B.beam((x, -0.30, 0.50), (x, 0.20, 0.50), t, S)         # seat rail
        B.beam((x, -0.30, 0.20), (x, -0.30, 0.50), t, S)        # front post
        B.beam((x, 0.20, 0.30), (x, 0.20, 0.50), t, S)          # rear lower post
        B.beam((x, -0.30, 0.50), (x, -0.38, 0.12), t, S)        # leg rest hanger
        B.box((s * 0.12, -0.42, 0.10), (0.20, 0.14, 0.02), S)   # foot plate
        B.beam((x, -0.22, 0.50), (x, -0.22, 0.70), t, S)        # armrest front post
        B.beam((x, 0.18, 0.50), (x, 0.18, 0.70), t, S)          # armrest rear post
        B.box((x, -0.02, 0.715), (0.05, 0.42, 0.03), R)         # armrest pad
    B.beam((-hw, 0.05, 0.30), (hw, 0.05, 0.50), t, S)          # cross brace
    B.beam((-hw, 0.05, 0.50), (hw, 0.05, 0.30), t, S)
    B.box((0, -0.05, 0.51), (2 * hw, 0.46, 0.035), F)           # seat sling
    B.box((0, 0.225, 0.73), (2 * hw, 0.03, 0.38), F, rot=Matrix.Rotation(math.radians(-8), 4, "X"))
    B.cyl((0, wheel_y, wheel_r), 0.012, 2 * (hw + 0.07), S, segs=6, axis="X")   # axle
    return B.to_object()


def post_bed_rails(ob):
    """Steel side rails on posts along the head half of the bed (bed is long along Y, head at +Y)."""
    lo, hi = bbox(ob)
    B = Builder()
    L = hi[1] - lo[1]
    top = hi[2] + 0.08 * L * 0.25
    y0, y1 = lo[1] + 0.40 * L, hi[1] - 0.12 * L
    w = 0.012 * L
    for x in (lo[0] - w, hi[0] + w):
        B.beam((x, y0, top), (x, y1, top), w, "steel")
        B.beam((x, y0, top - 0.06 * L), (x, y1, top - 0.06 * L), w, "steel")
        for y in (y0, (y0 + y1) / 2, y1):
            B.beam((x, y, top + w / 2), (x, y, hi[2] * 0.55), w, "steel")
    return B.to_object(into=ob)


def post_gurney(ob):
    """Lift the Kenney mattress and pillow onto a steel trolley with four casters."""
    lo, hi = bbox(ob)
    L = hi[1] - lo[1]
    k = 1.95 / L                     # work in final metres, the pipeline scales by ~1 after this
    ob.data.transform(Matrix.Scale(k, 4))
    lo, hi = bbox(ob)
    ob.data.transform(Matrix.Diagonal((0.68 / (hi[0] - lo[0]), 1.0, 0.8, 1.0)))   # trolley width, thinner pad
    lo, hi = bbox(ob)
    ob.data.transform(Matrix.Translation((0, 0, 0.78 - lo[2])))
    lo, hi = bbox(ob)
    cx, cy = (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2
    hx, hy = (hi[0] - lo[0]) / 2, (hi[1] - lo[1]) / 2
    B = Builder()
    S, D, R = "steel", "steel_dark", "rubber"
    z = 0.76
    B.box((cx, cy, z), (2 * hx + 0.04, 2 * hy + 0.02, 0.04), S)                  # deck
    for sx in (-1, 1):
        for sy in (-1, 1):
            px, py = cx + sx * (hx - 0.08), cy + sy * (hy - 0.15)
            B.beam((px, py, z - 0.02), (px, py, 0.14), 0.035, S)                    # leg
            B.box((px, py, 0.11), (0.04, 0.06, 0.04), D)                            # fork
            B.cyl((px, py, 0.06), 0.06, 0.04, R, segs=8, axis="X")                 # caster
    B.box((cx, cy, 0.30), (2 * hx - 0.10, 2 * hy - 0.24, 0.025), D)              # lower shelf
    for sx in (-1, 1):                                                             # folded side rails
        x = cx + sx * (hx + 0.03)
        B.beam((x, cy - hy * 0.7, z + 0.02), (x, cy + hy * 0.7, z + 0.02), 0.025, S)
    hyH = cy + hy + 0.06                                                           # push handle at the head
    for sx in (-1, 1):
        B.beam((cx + sx * (hx - 0.05), hyH - 0.06, z), (cx + sx * (hx - 0.05), hyH, z + 0.22), 0.025, S)
    B.beam((cx - hx + 0.05, hyH, z + 0.22), (cx + hx - 0.05, hyH, z + 0.22), 0.03, S)
    return B.to_object(into=ob)


def post_pipe_pair(ob):
    """A second copy of the pipe below the first, as two runs along a wall."""
    lo, hi = bbox(ob)
    L = max(hi - lo)
    me2 = ob.data.copy()
    me2.transform(Matrix.Translation((0, 0, -0.16 * L)))
    ob2 = bpy.data.objects.new("pipe2", me2)
    bpy.context.scene.collection.objects.link(ob2)
    bpy.ops.object.select_all(action="DESELECT")
    ob2.select_set(True)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.join()
    return ob


BUILDERS = {"wheelchair": build_wheelchair}
POSTS = {"bed_rails": post_bed_rails, "gurney": post_gurney, "pipe_pair": post_pipe_pair}


# ---------------------------------------------------------------- materials

def principled(mat):
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Roughness"].default_value = 0.9
    bsdf.inputs["Metallic"].default_value = 0.0
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.3
    return nt, bsdf


def flat_colours(ob, prop, man):
    """Bake each face's material into a corner colour attribute, then use one plain material."""
    pal = {k: hex_rgb(v) for k, v in man["palette"].items()}
    cmap = dict(man["kit_colors"].get(prop["kit"], {}))
    cmap.update(prop.get("colors", {}))
    me = ob.data
    names = [m.name.split(".")[0] if m else "" for m in me.materials]
    face_col = []
    unknown = set()
    for i, n in enumerate(names):
        key = cmap.get(n, n if n in pal else None)
        if key is None:
            unknown.add(n)
            key = "off_white"
        face_col.append(pal[key])
    if unknown:
        log("  colour map has no entry for", sorted(unknown), "-> off_white")
    while me.color_attributes:
        me.color_attributes.remove(me.color_attributes[0])
    attr = me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    cols = np.zeros((len(me.loops), 4), dtype=np.float32)
    for p in me.polygons:
        c = face_col[p.material_index] if p.material_index < len(face_col) else pal["off_white"]
        for li in p.loop_indices:
            cols[li] = (c[0], c[1], c[2], 1.0)   # BYTE_COLOR color_srgb takes sRGB
    attr.data.foreach_set("color_srgb", cols.ravel())
    me.color_attributes.active_color = attr
    while me.uv_layers:
        me.uv_layers.remove(me.uv_layers[0])
    me.materials.clear()
    for p in me.polygons:
        p.material_index = 0
    mat = bpy.data.materials.new("clinic_" + prop["name"])
    nt, bsdf = principled(mat)
    ca = nt.nodes.new("ShaderNodeVertexColor")
    ca.layer_name = "Col"
    nt.links.new(ca.outputs["Color"], bsdf.inputs["Base Color"])
    me.materials.append(mat)


def base_image(mat):
    """The image feeding Base Color of a source material, or None (with the flat colour)."""
    if not mat or not mat.node_tree:
        return None, (0.8, 0.8, 0.8)
    bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if not bsdf:
        return None, (0.8, 0.8, 0.8)
    sock = bsdf.inputs["Base Color"]
    col = tuple(sock.default_value[:3])
    seen = set()
    stack = [l.from_node for l in sock.links]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        if n.type == "TEX_IMAGE" and n.image:
            return n.image, col
        for i in n.inputs:
            stack += [l.from_node for l in i.links]
    return None, col


def image_pixels(img, w, h):
    im = img.copy()
    im.scale(w, h)
    px = np.array(im.pixels[:], dtype=np.float32).reshape(h, w, im.channels)
    bpy.data.images.remove(im)
    if px.shape[2] == 3:
        px = np.concatenate([px, np.ones((h, w, 1), np.float32)], 2)
    return px


def textured(ob, prop):
    """Atlas the base colour of every source material into one small image, one material."""
    size = int(prop.get("texture", 128))
    me = ob.data
    mats = list(me.materials)
    used = sorted({p.material_index for p in me.polygons})
    weights = prop.get("atlas_weights", {})
    wsum = sum(weights.get(mats[i].name.split(".")[0], 1) if mats[i] else 1 for i in used)
    atlas = np.zeros((size, size, 4), np.float32)
    uv = me.uv_layers.active
    if uv is None:
        raise RuntimeError(prop["name"] + ": source has no UVs")
    uvs = np.zeros(len(me.loops) * 2, np.float32)
    uv.data.foreach_get("uv", uvs)
    uvs = uvs.reshape(-1, 2)
    y = 0
    region = {}
    for n, i in enumerate(used):
        wgt = weights.get(mats[i].name.split(".")[0], 1) if mats[i] else 1
        hh = size - y if n == len(used) - 1 else max(8, int(round(size * wgt / wsum)))
        img, col = base_image(mats[i])
        if img is not None:
            px = image_pixels(img, size, hh)
        else:
            px = np.ones((hh, size, 4), np.float32)
            px[..., :3] = [c ** (1 / 2.2) for c in col]
        atlas[y:y + hh] = px
        region[i] = (y / size, hh / size)
        y += hh
    pad = 0.5 / size
    for p in me.polygons:
        y0, hh = region[p.material_index]
        for li in p.loop_indices:
            u, v = uvs[li]
            u = min(max(u - math.floor(u) if (u < 0 or u > 1) else u, 0), 1)
            v = min(max(v - math.floor(v) if (v < 0 or v > 1) else v, 0), 1)
            uvs[li] = (pad + u * (1 - 2 * pad), y0 + pad + v * (hh - 2 * pad))
    uv.data.foreach_set("uv", uvs.ravel())
    for extra in [l for l in me.uv_layers if l != uv]:
        me.uv_layers.remove(extra)
    adj = prop.get("tex_adjust", {})
    if "hue" in adj:                # rotate hue about the grey axis, degrees
        a = math.radians(adj["hue"])
        c, sn, k = math.cos(a), math.sin(a), 1 / 3
        r = math.sqrt(k) * sn
        M = np.array([[c + (1 - c) * k, k * (1 - c) - r, k * (1 - c) + r],
                      [k * (1 - c) + r, c + (1 - c) * k, k * (1 - c) - r],
                      [k * (1 - c) - r, k * (1 - c) + r, c + (1 - c) * k]], np.float32)
        atlas[..., :3] = np.clip(atlas[..., :3] @ M.T, 0, 1)
    if "gain" in adj:
        atlas[..., :3] = np.clip(atlas[..., :3] * adj["gain"], 0, 1)
    if "saturation" in adj:
        g = atlas[..., :3].mean(2, keepdims=True)
        atlas[..., :3] = g + (atlas[..., :3] - g) * adj["saturation"]
    atlas[..., 3] = 1.0
    img = bpy.data.images.new("tex_" + prop["name"], size, size, alpha=False)
    img.pixels.foreach_set(atlas.ravel())
    img.pack()
    me.materials.clear()
    for p in me.polygons:
        p.material_index = 0
    mat = bpy.data.materials.new("clinic_" + prop["name"])
    nt, bsdf = principled(mat)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    me.materials.append(mat)
    while me.color_attributes:
        me.color_attributes.remove(me.color_attributes[0])


# ---------------------------------------------------------------- one prop

def build_one(prop, man, src_root):
    reset()
    name = prop["name"]
    src = os.path.join(src_root, prop["source"])
    if prop.get("builder"):
        ob = BUILDERS[prop["builder"]]()
        method = "hand-built"
    else:
        if not os.path.isfile(src):
            raise RuntimeError(f"{name}: missing source {src}")
        import_source(src)
        ob = join_meshes(prop.get("keep_objects"))
        method = None
    if prop.get("stretch"):         # non-uniform scale, e.g. a two-seat bench made into a long one
        ob.data.transform(Matrix.Diagonal((*prop["stretch"], 1.0)))
    if prop.get("rot_y"):
        ob.data.transform(Matrix.Rotation(math.radians(prop["rot_y"]), 4, "Y"))
    if prop.get("rot_z"):
        ob.data.transform(Matrix.Rotation(math.radians(prop["rot_z"]), 4, "Z"))
    if prop.get("post"):
        ob = POSTS[prop["post"]](ob)
    is_tex = "texture" in prop
    clean(ob, recalc=not is_tex)
    scale_to(ob, prop["size"])
    dec = decimate(ob, prop["budget"])
    method = method or {"none": "as is", "planar": "planar-dissolved", "collapse": "decimated"}[dec]
    if prop.get("post"):
        method += ", parts added by script"
    clean(ob, recalc=not is_tex)
    triangulate(ob)
    scale_to(ob, prop["size"])      # decimation can pull the extremes in a little
    if is_tex:
        textured(ob, prop)
    else:
        flat_colours(ob, prop, man)
    smooth_normals(ob, flat=not is_tex)   # kit furniture and hand-built props read best faceted
    place_origin(ob, prop["mount"])
    tris = tri_count(ob)
    if tris > prop["budget"] or tris > 1500:
        raise RuntimeError(f"{name}: {tris} triangles over budget {prop['budget']}")
    lo, hi = bbox(ob)
    ext = hi - lo
    path = os.path.join(OUT, name + ".glb")
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    kw = dict(filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_apply=True,
              export_animations=False, export_cameras=False, export_lights=False, export_extras=False,
              export_texcoords=is_tex, export_normals=True, export_tangents=False,
              export_materials="EXPORT", export_image_format="JPEG" if is_tex else "AUTO",
              export_jpeg_quality=85, export_vertex_color="MATERIAL", export_skins=False,
              export_morph=False)
    bpy.ops.export_scene.gltf(**kw)
    file_tris, file_mats, _ = glb_triangles(path)
    if file_tris != tris:
        log(f"  {name}: exporter wrote {file_tris} triangles (mesh had {tris})")
        tris = file_tris
    if file_mats > 2:
        raise RuntimeError(f"{name}: {file_mats} materials in the glb")
    log(f"{name}: {tris} tris, {method}, size {ext[0]:.3f} x {ext[2]:.3f} x {ext[1]:.3f} m, "
        f"{os.path.getsize(path)} bytes")
    return {
        "name": name, "file": name + ".glb", "triangles": tris,
        # glTF axes: x = width, y = height, z = depth (front faces +Z)
        "size_m": [round(float(ext[0]), 3), round(float(ext[2]), 3), round(float(ext[1]), 3)],
        "mount": prop["mount"], "kit": prop["kit"], "source": prop["source"].split("/")[-1],
        "licence": LICENCES[prop["kit"]], "textured": is_tex, "method": method,
        "materials": 1, "bytes": os.path.getsize(path),
    }


def main():
    global OUT
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default=os.path.join(ROOT, "tools", "props"))
    ap.add_argument("--only", default="")
    ap.add_argument("--manifest", default=MANIFEST_IN, help="other manifest, for experiments")
    ap.add_argument("--out", default=OUT, help="other output folder, for experiments")
    a = ap.parse_args(argv)
    OUT = os.path.abspath(a.out)
    man = json.load(open(a.manifest, encoding="utf-8"))
    only = {s for s in a.only.split(",") if s}
    os.makedirs(OUT, exist_ok=True)
    out_path = os.path.join(OUT, "manifest.json")
    if not only:                    # full rebuild starts from an empty folder
        for f in os.listdir(OUT):
            if f.endswith(".glb") or f == "manifest.json":
                os.remove(os.path.join(OUT, f))
    entries = {}
    if only and os.path.isfile(out_path):
        entries = {e["name"]: e for e in json.load(open(out_path, encoding="utf-8"))["props"]}
    for prop in man["props"]:
        if only and prop["name"] not in only:
            continue
        entries[prop["name"]] = build_one(prop, man, a.sources)
    order = [p["name"] for p in man["props"]]
    props = [entries[n] for n in order if n in entries]
    doc = {
        "about": "Clinic props. glTF, +Y up, metres, front faces +Z. mount: floor = origin at the centre of the "
                 "footprint on the floor; wall = origin at the centre of the back face; ceiling = origin at the "
                 "centre of the top face. size_m is the bounding box (x width, y height, z depth). "
                 "Built by assets_src/blender/props/build_props.py; see CREDITS.md.",
        "props": props,
        "total_bytes": sum(p["bytes"] for p in props),
    }
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    log(f"wrote {len(props)} props, {doc['total_bytes']} bytes of glb")


if __name__ == "__main__":
    main()
