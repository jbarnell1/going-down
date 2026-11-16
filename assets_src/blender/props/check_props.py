"""Re-import every exported prop in a clean scene, check it against props.json, render contact sheets.

Usage (from the repo root):
  <blender> --background --factory-startup --python-exit-code 1 \
      --python assets_src/blender/props/check_props.py -- [--verify-only] [--only name,name]

Fails (exit code 1 with --python-exit-code 1) when a prop is over its triangle budget or 1,500, has
more than 2 materials, carries an image larger than allowed, or its measured size is more than 5%
off the target in props.json.

Sheets go to assets_src/renders/props/: sheet_N.png (full size) and sheet_N_game.png (each sheet
rendered at 480x270, the game's resolution, and blown up 3x with nearest-neighbour).
"""
import bpy, json, math, os, sys, argparse
import numpy as np
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
PROPS = os.path.join(ROOT, "public", "assets", "props")
RENDERS = os.path.join(ROOT, "assets_src", "renders", "props")
COLS, ROWS = 3, 2                    # cells per sheet
FULL_CELL = (640, 540)               # full-size cell -> 1920x1080 sheet
GAME = (480, 270)                    # game resolution sheet -> 160x135 cells
GREY = 0.214                         # linear mid grey (sRGB 0.5)


def log(*a):
    print("[check]", *a, flush=True)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def load(name):
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROPS, name + ".glb"))
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    others = [o for o in bpy.data.objects if o.type not in ("MESH", "EMPTY")]
    return meshes, others


def world_bbox(meshes):
    pts = [o.matrix_world @ v.co for o in meshes for v in o.data.vertices]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    return lo, hi


def verify(prop, entry, src_tex_limit):
    reset()
    meshes, others = load(prop["name"])
    tris = sum(len(p.vertices) - 2 for o in meshes for p in o.data.polygons)
    mats = {m.name for o in meshes for m in o.data.materials if m}
    imgs = [(im.name, im.size[0], im.size[1]) for im in bpy.data.images if im.size[0] > 0]
    lo, hi = world_bbox(meshes)
    ext = hi - lo
    dim = prop["size"]["dim"]
    got = {"height": ext[2], "length": max(ext[0], ext[1]), "longest": max(ext)}[dim]
    want = prop["size"]["m"]
    c = (lo + hi) / 2
    origin = {"floor": (c.x, c.y, lo.z), "wall": (c.x, hi.y, c.z), "ceiling": (c.x, c.y, hi.z)}[prop["mount"]]
    errs = []
    if tris > prop["budget"] or tris > 1500:
        errs.append(f"{tris} tris over budget {prop['budget']}")
    if len(mats) > 2:
        errs.append(f"{len(mats)} materials")
    lim = 256 if prop["name"] == "wheelchair" else 128
    for n, w, h in imgs:
        if w > lim or h > lim:
            errs.append(f"image {n} {w}x{h} over {lim}")
    if "texture" in prop and not imgs:
        errs.append("textured prop has no image")
    if abs(got - want) > 0.05 * want:
        errs.append(f"{dim} {got:.3f} m, target {want} m")
    if max(abs(x) for x in origin) > 0.01 * max(ext):
        errs.append(f"origin off the {prop['mount']} reference by {[round(x, 3) for x in origin]}")
    if others:
        errs.append("extra objects " + ", ".join(o.type for o in others))
    if entry and entry["triangles"] != tris:
        errs.append(f"manifest says {entry['triangles']} tris")
    if bpy.data.actions:
        errs.append("has animation")
    blacks = []
    for m in bpy.data.materials:
        if not m.node_tree:
            continue
        b = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if b and not b.inputs["Base Color"].links and max(b.inputs["Base Color"].default_value[:3]) < 0.05:
            blacks.append(m.name)
        if b and b.inputs["Metallic"].default_value > 0.0:
            errs.append(f"{m.name} metallic {b.inputs['Metallic'].default_value}")
    if blacks:
        errs.append("black materials " + ", ".join(blacks))
    line = (f"{prop['name']:<20} tris {tris:>5}  mats {len(mats)}  images {[(w, h) for _, w, h in imgs]}  "
            f"size x{ext.x:.3f} y{ext.y:.3f} z{ext.z:.3f} (Blender axes)  {dim} {got:.3f}/{want}")
    log(line + ("  FAIL: " + "; ".join(errs) if errs else "  ok"))
    return errs, tris


# ---------------------------------------------------------------- rendering

def lin(h):
    h = h.lstrip("#")
    return tuple((int(h[i:i + 2], 16) / 255.0) ** 2.2 for i in (0, 2, 4))


def emit_mat(name, col, strength=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    e = nt.nodes.new("ShaderNodeEmission")
    e.inputs["Color"].default_value = (*col, 1)
    e.inputs["Strength"].default_value = strength
    o = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(e.outputs[0], o.inputs[0])
    return m


def diffuse_mat(name, col):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*col, 1)
    b.inputs["Roughness"].default_value = 1.0
    return m


def setup_scene(res):
    scn = bpy.context.scene
    for eng in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scn.render.engine = eng
            break
        except TypeError:
            continue
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.resolution_percentage = 100
    scn.render.filter_size = 0.5 if res[0] < 300 else 1.5   # game cells: close to the game's unfiltered pixels
    scn.render.image_settings.file_format = "PNG"
    scn.render.image_settings.color_mode = "RGB"
    scn.view_settings.view_transform = "Standard"
    try:
        scn.eevee.taa_render_samples = 8
    except AttributeError:
        pass
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (GREY, GREY, GREY, 1)
    bg.inputs["Strength"].default_value = 0.9
    scn.world = world
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 2.5
    sun.data.angle = math.radians(10)
    sun.rotation_euler = (math.radians(35), 0, math.radians(30))
    scn.collection.objects.link(sun)


def add_floor_and_marker(lo, hi):
    floor = bpy.data.meshes.new("floor")
    s = 50
    floor.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    fo = bpy.data.objects.new("floor", floor)
    fo.data.materials.append(diffuse_mat("floor", (GREY, GREY, GREY)))
    bpy.context.scene.collection.objects.link(fo)
    # 1.7 m figure marker: body column, head, beside the prop
    mx = lo.x - 0.35
    my = (lo.y + hi.y) / 2
    mat = diffuse_mat("marker", lin("#4a5a78"))
    bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.14, depth=1.42, location=(mx, my, 0.71))
    bpy.context.object.data.materials.append(mat)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=8, radius=0.13, location=(mx, my, 1.57))
    bpy.context.object.data.materials.append(mat)
    return Vector((mx - 0.15, my - 0.15, 0)), Vector((mx + 0.15, my + 0.15, 1.7))


def frame_camera(points, res):
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    cam.data.type = "ORTHO"
    d = Vector((0.85, -1.0, 0.62)).normalized()      # 3/4 view from the front right, above
    centre = sum(points, Vector()) / len(points)
    cam.location = centre + d * 30
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    bpy.context.view_layer.update()
    inv = cam.matrix_world.inverted()
    loc = [inv @ p for p in points]
    xs, ys = [p.x for p in loc], [p.y for p in loc]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    aspect = res[0] / res[1]
    top_space = 1.25                                  # room for the label
    scale = max(w, h * top_space * aspect) * 1.12
    cam.data.ortho_scale = scale
    sx, sy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2 + h * (top_space - 1) / 2
    cam.location = cam.matrix_world @ Vector((sx, sy, 0))
    cam.data.clip_end = 100
    return cam, scale, aspect


def label(cam, scale, aspect, text):
    cu = bpy.data.curves.new("label", "FONT")
    cu.body = text
    cu.size = scale * 0.055
    ob = bpy.data.objects.new("label", cu)
    bpy.context.scene.collection.objects.link(ob)
    ob.data.materials.append(emit_mat("label", (0.02, 0.02, 0.02)))
    ob.parent = cam
    ob.location = (-scale / 2 + scale * 0.03, scale / aspect / 2 - scale * 0.075, -1)


def render_cell(prop, entry, res, path):
    reset()
    setup_scene(res)
    meshes, _ = load(prop["name"])
    lo, hi = world_bbox(meshes)
    for o in meshes:                         # everything stands on the floor for the sheet
        o.location.z -= lo.z
        for m in o.data.materials:
            m.use_backface_culling = True    # inside-out faces show up as holes
    lo, hi = world_bbox(meshes)
    mlo, mhi = add_floor_and_marker(lo, hi)
    pts = [Vector((x, y, z)) for x in (lo.x, hi.x, mlo.x) for y in (lo.y, hi.y) for z in (lo.z, hi.z, mhi.z)]
    cam, scale, aspect = frame_camera(pts, res)
    tag = f"{prop['name']}  {entry['triangles']} tris  {prop['mount']}"
    label(cam, scale, aspect, tag)
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def read_png(path):
    im = bpy.data.images.load(path)
    w, h = im.size
    px = np.array(im.pixels[:], np.float32).reshape(h, w, im.channels)[..., :3]
    bpy.data.images.remove(im)
    return px


def write_png(px, path):
    h, w, _ = px.shape
    im = bpy.data.images.new("out", w, h, alpha=False)
    rgba = np.concatenate([px, np.ones((h, w, 1), np.float32)], 2)
    im.pixels.foreach_set(rgba.ravel())
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    bpy.data.images.remove(im)


def sheets(props, entries, tmp):
    per = COLS * ROWS
    game_cell = (GAME[0] // COLS, GAME[1] // ROWS)
    out = []
    for s in range(0, len(props), per):
        group = props[s:s + per]
        n = s // per + 1
        for kind, cell in (("full", FULL_CELL), ("game", game_cell)):
            W, H = cell[0] * COLS, cell[1] * ROWS
            sheet = np.full((H, W, 3), 0.35, np.float32)
            for k, p in enumerate(group):
                f = os.path.join(tmp, f"{p['name']}_{kind}.png")
                render_cell(p, entries[p["name"]], cell, f)
                px = read_png(f)
                r, c = k // COLS, k % COLS
                y0 = H - (r + 1) * cell[1]   # image rows go bottom-up
                sheet[y0:y0 + cell[1], c * cell[0]:(c + 1) * cell[0]] = px
                sheet[y0:y0 + cell[1], c * cell[0]] = 0.15
                sheet[y0, c * cell[0]:(c + 1) * cell[0]] = 0.15
            if kind == "full":
                path = os.path.join(RENDERS, f"sheet_{n}.png")
            else:
                sheet = np.repeat(np.repeat(sheet, 3, 0), 3, 1)
                path = os.path.join(RENDERS, f"sheet_{n}_game.png")
            write_png(sheet, path)
            out.append(path)
            log("wrote", os.path.relpath(path, ROOT))
    return out


def main():
    global PROPS, RENDERS
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--manifest", default=os.path.join(HERE, "props.json"), help="for experiments")
    ap.add_argument("--props", default=PROPS, help="for experiments")
    ap.add_argument("--renders", default=RENDERS, help="for experiments")
    a = ap.parse_args(argv)
    PROPS, RENDERS = os.path.abspath(a.props), os.path.abspath(a.renders)
    man = json.load(open(a.manifest, encoding="utf-8"))
    out_man = json.load(open(os.path.join(PROPS, "manifest.json"), encoding="utf-8"))
    entries = {e["name"]: e for e in out_man["props"]}
    only = {s for s in a.only.split(",") if s}
    props = [p for p in man["props"] if not only or p["name"] in only]
    failed = []
    for p in props:
        if p["name"] not in entries:
            failed.append(p["name"] + ": not in manifest.json")
            continue
        errs, _ = verify(p, entries[p["name"]], None)
        failed += [p["name"] + ": " + e for e in errs]
    files = [f for f in os.listdir(PROPS)]
    total = sum(os.path.getsize(os.path.join(PROPS, f)) for f in files)
    log(f"folder public/assets/props: {len(files)} files, {total} bytes")
    if total > 1.5 * 1024 * 1024:
        failed.append(f"folder is {total} bytes, over 1.5 MB")
    extra = sorted(set(f[:-4] for f in files if f.endswith(".glb")) - {p["name"] for p in man["props"]})
    if extra:
        failed.append("stray glb files: " + ", ".join(extra))
    if not a.verify_only:
        os.makedirs(RENDERS, exist_ok=True)
        tmp = os.path.join(ROOT, ".local", "props-scratch", "cells")
        os.makedirs(tmp, exist_ok=True)
        sheets(props, entries, tmp)
        for f in os.listdir(tmp):
            os.remove(os.path.join(tmp, f))
        os.rmdir(tmp)
    if failed:
        for f in failed:
            log("FAIL", f)
        raise SystemExit(1)
    log("all props pass")


if __name__ == "__main__":
    main()
