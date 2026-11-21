# The Playroom dressed: what Level draws when plan.place is "playroom" (docs/floors/playarea.md,
# sections 1, 6 and 10; the plan comes from sim/playroom.gd). An indoor soft-play centre with nobody
# in it: padded walls and mats in faded red, yellow, blue and green, white strip lights a little too
# white, a pale haze, grey netting round the upper deck. Too clean and too bright by the lift; further
# in (the walking distance from the lift, as the Clinic's gradient) the colours bleach, the balls lose
# their colour, and the cut-out letters on the walls start to say the wrong things (V5).
#
# Everything the rules decide is drawn from the rules, never guessed here:
# - every hiding place's furniture (ball pit, tube slide, crawl den, playhouse, party table, toy chest,
#   coat cubby) stands at its `Playroom.hides` inside spot, its open side towards the hide's gap;
# - every squeaker tile in `Playroom.squeakers`, and no other, is drawn, with its printed note;
# - every zone's ways in carry a laminated sign reading `Playroom.sign_text(zone)`, so the number on
#   it is the zone's hide count.
# `check()` compares what was drawn against fresh calls to the rules (the demo and the walk tool run it).
#
# Count dark (section 3): `count_dark` is the flag the count drives, 0 to 1. At 1 the strip lights and
# every real light are out and only the glow-in-the-dark things stay: the ceiling stars, the lines on
# the mats, the EXIT signs, and the Minder's card mask (client/minder_view.gd registers it). The
# run's own blackout (Level.set_emergency) shows the same dark, so the interim rules look right too.
#
# The real lights are few (the renderer draws at most 256 a frame): one at every walkway junction and
# one over every zone, about 120 on the biggest floor; the flat baked-in light carries the brightness.
# Like the Annex it reuses Level's geometry helpers (chunked SurfaceTools, wall slabs, door openings).
extends Node3D

const Playroom = preload("res://sim/playroom.gd")
const Floor = preload("res://sim/floor.gd")
const AnnexView = preload("res://client/annex_view.gd")

const S := 2.0
const LH := 3.2
## A tube slide's climb up the wall starts this high on its mouth's tube (whose top is at 0.88 m).
const SLIDE_CLIMB := 0.86
## A toy chest's size and its lid's open crack (radians up from shut), the crack you look out of (MH1b).
const CHEST := Vector3(0.9, 0.5, 0.56)
const CHEST_WALL := 0.03
const CHEST_LID := 0.3
const CHEST_SLOT := Vector3(0.32, 0.43, 0.17)
## The party table's cloth on its gap side stops this far off the floor: under it is the view out (MH1b).
const TABLE_HEM := 0.4
const WALL_T := 0.14
const DOOR_H := 2.1
const LIGHT_LIMIT := 256
const HAZE := Color(0.9, 0.9, 0.86)
const HAZE_DENSITY := 0.012
## The dark with the emergency (or count dark) on: a dim blue night, never red.
const AMBIENT_DARK := Color(0.05, 0.07, 0.12)
const BLEACH := 0.7
## Faded primaries, as the shader's palette.
const RED := Color(0.82, 0.36, 0.32)
const YELLOW := Color(0.92, 0.78, 0.36)
const BLUE := Color(0.36, 0.55, 0.8)
const GREEN := Color(0.45, 0.72, 0.45)
const PAL: Array[Color] = [RED, YELLOW, BLUE, GREEN]
const WHITE := Color(0.94, 0.94, 0.9)
const GREY := Color(0.6, 0.6, 0.6)
const DARK := Color(0.16, 0.15, 0.17)
const WOOD := Color(0.78, 0.62, 0.42)
const CLOTH := Color(0.96, 0.86, 0.88)
## The real lights: an omni at every walkway junction and over every zone.
const JUNCTION_ENERGY := 0.32
const JUNCTION_REACH := 8.5
const ZONE_ENERGY := 0.3
const LOBBY_ENERGY := 0.5
const LIGHT_DECAY := 0.6
## The baked-in light (playroom_shade.gdshader `self_light`): too bright.
const SELF_WALL := 0.5
const SELF_FLOOR := 0.46
const SELF_CEIL := 0.62
const SELF_PROPS := 0.5
## Glow-in-the-dark things: lit (a pale sticker under the strip lights) and in count dark.
const STAR_LIT := Color(0.86, 0.9, 0.66)
const STAR_DARK := Color(0.55, 1.0, 0.62)
const LINE_LIT := Color(0.74, 0.94, 0.6)
const LINE_DARK := Color(0.42, 1.0, 0.58)
## The words on the walls, from the lift outwards (V5: further in they say the wrong things).
const WORDS: Array[String] = ["PLAY NICELY", "PLAY QUIETLY", "STAY QUIET", "HIDE NICELY"]
const LETTER_PX := 0.07
## Tests only: the deliberate breaks the walk tool proves its checks with. "sign": a sign's number is
## guessed from its zone's kind instead of taken from the rules; "squeak": one squeaker tile is left out.
static var test_break := ""
## CC0 photographs (godot/assets/playroom/SOURCES.md, made by assets_src/playroom_textures.py) and the metres
## each one covers on a surface.
const CEILING_PHOTO := preload("res://assets/playroom/ceiling.webp")
const PLASTER_PHOTO := preload("res://assets/playroom/plaster.webp")
const GRIME_PHOTO := preload("res://assets/playroom/grime.webp")
const CEILING_M := 3.6
const PLASTER_M := 2.5
const GRIME_M := 6.0
## How strongly the plaster and the dirt show (0 none, 1 full).
const WALL_PLASTER := 0.3
const WALL_GRIME := 0.2
const FLOOR_GRIME := 0.35
const CEIL_GRIME := 0.25
## The ready-made soft-play pieces (Meshy, the owner's paid plan; assets_src/blender/playroom/): [path, scale,
## depth off the wall and length along it, both after scaling]. The slide is 2.05 by 1.13 m and 2 m tall as
## built, the tower 2.18 by 2.15 m and 2.3 m tall; both are drawn 2.8 m tall, near the 3.2 m ceiling, so a
## tower stands over its room. Each covers the cells under it (all walkable, in its room, clear of hides).
const PIECES := {
	&"slide": ["res://assets/playroom/slide.glb", 1.4, 1.58, 2.87],
	&"frame": ["res://assets/playroom/frame.glb", 1.22, 2.62, 2.66],
}
## Room kinds that get pieces against their walls, in this order, and how many at most in one room; and at
## most MAX_PIECES on a floor (each piece is one draw of about 9,000 to 14,000 triangles).
const PIECE_ROOMS := {"toddler": 3, "deck": 1, "nook": 1}
## And at most this many of one room kind on a floor, so the upper deck gets its share.
const PIECE_KIND_CAP := {"toddler": 7, "deck": 3, "nook": 2}
const MAX_PIECES := 12
## The wall murals (assets_src/playroom_murals.py): four pictures of 2 by 1 in a 2 by 2 sheet, painted above
## the padding, one on every plain wall of a play room long enough for it but the cut-out words' wall.
const MURALS := preload("res://assets/playroom/murals.png")
const MURAL_ROOMS: Array[String] = ["lobby", "ballpit", "toddler", "party"]
const MURAL_H := 1.7
const MURAL_Y := 2.1
## Only a wall this long (metres of plain wall) is "large" enough for a mural.
const MURAL_WALL := 6.0
## Murals drawn: {room, level, pos, facing, picture}.
var murals: Array[Dictionary] = []
## Clear space kept between the piece and its wall.
const PIECE_GAP := 0.06
## The Meshy colour maps average about 0.33 (sRGB); this brings them up to the floor's faded paint (the tower less: its
## panels are pale and went white under the bleach).
const PIECE_GAIN := {&"slide": 2.8, &"frame": 2.0}
## Pieces drawn: {kind, level, cell (Vector2i), pos, facing}.
var pieces: Array[Dictionary] = []
static var _piece_cache := {}

const GUESS := {&"ballpit": 3, &"frame": 3, &"upper": 3, &"deck": 4, &"party": 3, &"toddler": 2, &"cloak": 4, &"nook": 2}

var lv: Level
var W := 0
var H := 0
## The plan as the rules hold it, and its lists.
var fp: Floor.FloorPlan
var hides: Array[Playroom.Hide] = []
var zones: Array[Playroom.Zone] = []
var squeak := PackedInt32Array()
## The flag the count drives: 0 the strip lights on, 1 count dark.
var count_dark := 0.0
## What was drawn, for check(): {hide, kind, level, pos (Vector3, the middle of the piece's footprint)}.
var furniture: Array[Dictionary] = []
## The squeaker tiles drawn, as Floor.pos_index values.
var squeaker_tiles := PackedInt32Array()
## The zone signs: {zone, text, level, pos, facing}.
var signs: Array[Dictionary] = []
## The cut-out words: {room, text, level, pos}.
var words: Array[Dictionary] = []
## Junctions: {level, cell}.
var junctions: Array[Dictionary] = []

var _lit_mats: Array[ShaderMaterial] = []
## {mat, light (bool: a strip light, off in the dark), lit_col, dark_col, lit_e, dark_e}
var _glows: Array[Dictionary] = []
var _last_k := -1.0
var _last_cd := -1.0
var _skipped_squeak := false

var mat_wall: ShaderMaterial
var mat_mat: ShaderMaterial
var mat_walk: ShaderMaterial
var mat_ceil: ShaderMaterial
var mat_props: ShaderMaterial
var mat_decal: ShaderMaterial
var mat_net: ShaderMaterial
var mat_balls: ShaderMaterial
var mat_ballbed: ShaderMaterial
var mat_strip: ShaderMaterial
var mat_star: ShaderMaterial
var mat_line: ShaderMaterial
var mat_exit: ShaderMaterial
var mat_mural: ShaderMaterial

static var _tex := {}
## The sign atlas: text -> Rect2i, filled as signs are made.
static var _sign_rects := {}
static var _atlas_img: Image = null
static var _atlas_tex: ImageTexture = null

## Dresses `level` (built up to its room index by Level.build) as the Playroom. Returns the view, also
## kept as the level's "playroom" meta and added as its child (it sets the lights every frame).
static func dress(level: Level, source_plan: Floor.FloorPlan = null, source_hides: Array[Playroom.Hide] = []) -> Node3D:
	var v: Node3D = new()
	v.name = "PlayroomView"
	# After main.gd's Level.update_lights, which this overrides for count dark.
	v.process_priority = 1000
	v.call(&"_dress", level, source_plan, source_hides)
	return v

func _dress(level: Level, source_plan: Floor.FloorPlan, source_hides: Array[Playroom.Hide]) -> void:
	lv = level
	W = level.W
	H = level.H
	level.set_meta("playroom", self)
	level.add_child(self)
	level.shadows = false
	level.ambient_dark = AMBIENT_DARK
	fp = source_plan if source_plan != null else Playroom.generate_playroom(str(level.plan.seed), int(level.plan.depth))
	if fp.width != W or fp.height != H or fp.rooms.size() != (level.plan.rooms as Array).size() or fp.doors.size() != (level.plan.doors as Array).size():
		push_error("playroom view: the plan for %s/%d does not match the one being drawn" % [level.plan.seed, level.plan.depth])
	hides = source_hides if not source_hides.is_empty() else Playroom.hides(fp, fp.seed)
	zones = Playroom.zones(fp, hides)
	squeak = Playroom.squeakers(fp, fp.seed, hides)
	_materials()
	_floors_and_ceilings()
	_walls()
	_stairs()
	_find_junctions()
	_lights()
	_strip_lights()
	_stars()
	_mat_lines()
	_squeakers()
	_furniture()
	_signs()
	_exits()
	if level.props_on:
		_dress_rooms()
	_commit()
	level.props_placed = furniture.size() + words.size()
	_apply(1.0, 0.0)

# --- the dark ----------------------------------------------------------------------------------

## The count's switch: 0 lit, 1 count dark (strip lights out, the glow-in-the-dark things on).
func set_count_dark(k: float) -> void:
	count_dark = clampf(k, 0.0, 1.0)

func _process(_delta: float) -> void:
	if lv != null:
		_apply(lv._level, lv._emergency)

## Sets every light and material for the light level (Level.set_light_level) and the dark (the count's
## flag, or the run's emergency lighting, whichever is darker).
func _apply(light: float, emergency: float) -> void:
	var cd := maxf(count_dark, emergency)
	var k := clampf(light, 0.0, 1.0) * (1.0 - cd)
	for i in lv.main_lights.size():
		var l := lv.main_lights[i]
		l.light_energy = lv._base_energy[i] * k
		l.visible = k > 0.02
	if is_equal_approx(k, _last_k) and is_equal_approx(cd, _last_cd):
		return
	_last_k = k
	_last_cd = cd
	var pk := k if k >= 1.0 else k * k
	for m in _lit_mats:
		m.set_shader_parameter("energy", pk)
		m.set_shader_parameter("haze", HAZE)
	for g: Dictionary in _glows:
		var m: ShaderMaterial = g.mat
		if bool(g.light):
			m.set_shader_parameter("energy", pk)
		else:
			m.set_shader_parameter("energy", lerpf(float(g.lit_e), float(g.dark_e), cd))
			m.set_shader_parameter("color", (g.lit_col as Color).lerp(g.dark_col, cd))
		m.set_shader_parameter("haze", HAZE * pk)

## For figures on the floor (client/minder_view.gd): a lit material that goes dark with the strip
## lights, and a glow that stays on in count dark.
func add_lit(m: ShaderMaterial) -> void:
	_lit_mats.append(m)
	_last_k = -1.0

func add_glow(m: ShaderMaterial, lit_col: Color, dark_col: Color, lit_e: float, dark_e: float) -> void:
	_glows.append({"mat": m, "light": false, "lit_col": lit_col, "dark_col": dark_col, "lit_e": lit_e, "dark_e": dark_e})
	_last_k = -1.0

# --- textures --------------------------------------------------------------

static func _finish(img: Image) -> Texture2D:
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

## Walls: 2 m across, the storey high. The lower 1.1 m is padded vinyl (alpha 1: the shader tints it
## a palette colour), with a seam every metre and soft pillowing; above it, white paint.
static func wall_tex() -> Texture2D:
	return preload("res://assets/textures/playroom_padding.png")

## Floor mats: four vinyl pads to a cell, with rounded corners and a welded edge.
static func mat_tex() -> Texture2D:
	return preload("res://assets/textures/playroom_mats.png")

## The walkways: pale laminate planks.
static func laminate_tex() -> Texture2D:
	if _tex.has("laminate"):
		return _tex["laminate"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 4103
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	var base := Color(0.86, 0.8, 0.7)
	for y in 64:
		var plank := y / 8
		var shade := rng.randf_range(-0.03, 0.03)
		var joint := (plank * 23) % 64
		for x in 64:
			var c := base * (1.0 + shade + 0.02 * sin(x * 0.4 + plank) + rng.randf_range(-0.012, 0.012))
			if y % 8 == 0 or x == joint:
				c = base * 0.82
			img.set_pixel(x, y, c)
	_tex["laminate"] = _finish(img)
	return _tex["laminate"]

## The ceiling: white tiles.
static func ceiling_tex() -> Texture2D:
	if _tex.has("ceiling"):
		return _tex["ceiling"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 4104
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var c := Color(0.93, 0.93, 0.92) * (1.0 + rng.randf_range(-0.015, 0.015))
			if x % 32 == 0 or y % 32 == 0:
				c = Color(0.72, 0.72, 0.72)
			img.set_pixel(x, y, c)
	_tex["ceiling"] = _finish(img)
	return _tex["ceiling"]

## Netting: grey cord on a 10 cm square mesh, the rest cut out.
static func net_tex() -> Texture2D:
	if _tex.has("net"):
		return _tex["net"]
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in 32:
		for t in 2:
			img.set_pixel(i, t, Color(0.62, 0.62, 0.6, 1))
			img.set_pixel(t, i, Color(0.62, 0.62, 0.6, 1))
	_tex["net"] = _finish(img)
	return _tex["net"]

## The ball bed under the top layer of balls: packed coloured dots.
static func balls_tex() -> Texture2D:
	if _tex.has("balls"):
		return _tex["balls"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 4105
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.2, 0.22))
	for k in 140:
		var c := PAL[rng.randi_range(0, 3)]
		var cx := rng.randi_range(0, 63)
		var cy := rng.randi_range(0, 63)
		for y in range(-3, 4):
			for x in range(-3, 4):
				var d := sqrt(float(x * x + y * y))
				if d <= 3.2:
					img.set_pixel(posmod(cx + x, 64), posmod(cy + y, 64), c * (1.05 - d * 0.08))
	_tex["balls"] = _finish(img)
	return _tex["balls"]

## The atlas of printed things (512 x 256): the zone signs (made as they are needed), the squeaker
## note, SOCKS MUST BE WORN, the EXIT sign, TOYS, and the height chart.
const ATLAS_W := 512
const ATLAS_H := 256
const A_NOTE := Rect2i(0, 200, 48, 48)
const A_SOCKS := Rect2i(56, 200, 120, 24)
const A_EXIT := Rect2i(184, 200, 48, 20)
const A_TOYS := Rect2i(240, 200, 40, 16)
const A_PARTY := Rect2i(288, 200, 112, 20)
const A_CHART := Rect2i(480, 0, 32, 256)
const SIGN_SIZE := Vector2i(144, 26)
## A zone sign's width on the wall, metres.
const SIGN_W := 1.0

static func _atlas() -> Image:
	if _atlas_img != null:
		return _atlas_img
	var img := Image.create(ATLAS_W, ATLAS_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.95, 0.95, 0.92))
	# The squeaker tile's printed note: a white tile, a red border, a blue quaver.
	AnnexView._frame(img, A_NOTE, RED, Color(0.98, 0.97, 0.94), 3)
	var o := A_NOTE.position
	for y in range(10, 34):
		img.fill_rect(Rect2i(o.x + 28, o.y + y, 3, 1), BLUE)
	for y in 9:
		for x in 11:
			if Vector2(x - 5, (y - 4) * 1.3).length() <= 5.2:
				img.set_pixel(o.x + 19 + x, o.y + 30 + y, BLUE)
	for k in 7:
		img.fill_rect(Rect2i(o.x + 31 + k, o.y + 10 + k, 2, 2), BLUE)
	AnnexView._frame(img, A_SOCKS, BLUE, Color(0.97, 0.96, 0.9), 2)
	PixelFont.blit(img, "SOCKS MUST", A_SOCKS.position + Vector2i(4, 3), BLUE * 0.6)
	PixelFont.blit(img, "BE WORN", A_SOCKS.position + Vector2i(4, 13), RED * 0.7)
	AnnexView._frame(img, A_EXIT, Color(0.95, 1.0, 0.95), Color(0.08, 0.6, 0.3), 2)
	PixelFont.blit(img, "EXIT", A_EXIT.position + Vector2i(13, 7), Color(0.95, 1.0, 0.95))
	AnnexView._frame(img, A_TOYS, YELLOW, RED, 2)
	PixelFont.blit(img, "TOYS", A_TOYS.position + Vector2i(8, 5), YELLOW)
	AnnexView._frame(img, A_PARTY, PAL[2], Color(0.98, 0.95, 0.85), 2)
	PixelFont.blit(img, "PARTY ROOM", A_PARTY.position + Vector2i(26, 7), RED * 0.8)
	# The height chart by the lift: a giraffe-yellow strip with a mark every 10 cm and the metres
	# printed, from the floor to the ceiling and on past where any child stands.
	img.fill_rect(A_CHART, YELLOW)
	for k in 33:
		var y := A_CHART.end.y - 1 - int(k * 0.1 / LH * A_CHART.size.y)
		img.fill_rect(Rect2i(A_CHART.position.x, y, 14 if k % 5 == 0 else 7, 1), DARK)
		if k % 5 == 0 and k > 0:
			PixelFont.blit(img, str(k * 10), Vector2i(A_CHART.position.x + 15, y - 3), DARK, Vector2i(1, 1))
	for k in 6:
		img.fill_rect(Rect2i(A_CHART.position.x + 3 + (k % 3) * 9, A_CHART.position.y + 6 + k * 41, 6, 5), Color(0.6, 0.38, 0.18))
	_atlas_img = img
	return img

static func atlas_tex() -> Texture2D:
	if _atlas_tex == null:
		var img := _atlas().duplicate() as Image
		img.generate_mipmaps()
		_atlas_tex = ImageTexture.create_from_image(img)
	return _atlas_tex

static func atlas_uv(r: Rect2i) -> Rect2:
	return Rect2(float(r.position.x) / ATLAS_W, float(r.position.y) / ATLAS_H, float(r.size.x) / ATLAS_W, float(r.size.y) / ATLAS_H)

## The atlas rect holding a sign's text, printed on first use (two lines: up to the first ". ").
static func sign_rect(text: String) -> Rect2i:
	if _sign_rects.has(text):
		return _sign_rects[text]
	var i := _sign_rects.size()
	var r := Rect2i((i % 3) * (SIGN_SIZE.x + 8), (i / 3) * (SIGN_SIZE.y + 6), SIGN_SIZE.x, SIGN_SIZE.y)
	var img := _atlas()
	AnnexView._frame(img, r, BLUE, Color(0.99, 0.98, 0.93), 2)
	var cut := text.find(". ")
	var a := text.substr(0, cut + 1) if cut >= 0 else text
	var b := text.substr(cut + 2) if cut >= 0 else ""
	PixelFont.blit(img, a, r.position + Vector2i((SIGN_SIZE.x - PixelFont.width(a)) / 2, 4), Color(0.12, 0.18, 0.45))
	PixelFont.blit(img, b, r.position + Vector2i((SIGN_SIZE.x - PixelFont.width(b)) / 2, 15), RED * 0.75)
	_sign_rects[text] = r
	_atlas_tex = null
	return r

# --- materials ---------------------------------------------------------------------------------

func _shade(tex: Texture2D, mode: int, self_light: float, scissor := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/playroom_shade.gdshader")
	if tex:
		m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("mode", float(mode))
	m.set_shader_parameter("self_light", self_light)
	m.set_shader_parameter("scissor", scissor)
	m.set_shader_parameter("energy", 1.0)
	m.set_shader_parameter("bleach", BLEACH)
	m.set_shader_parameter("haze", HAZE)
	m.set_shader_parameter("haze_density", HAZE_DENSITY)
	for i in 4:
		m.set_shader_parameter("pal%d" % i, PAL[i])
	_lit_mats.append(m)
	return m

func _glow_mat(col: Color, tex: Texture2D, light: bool, dark_col := Color.WHITE, lit_e := 1.0, dark_e := 1.0, scissor := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://client/playroom_glow.gdshader")
	m.set_shader_parameter("color", col)
	m.set_shader_parameter("energy", 1.0)
	m.set_shader_parameter("scissor", scissor)
	if tex:
		m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("haze", HAZE)
	m.set_shader_parameter("haze_density", HAZE_DENSITY)
	_glows.append({"mat": m, "light": light, "lit_col": col, "dark_col": dark_col, "lit_e": lit_e, "dark_e": dark_e})
	return m

func _materials() -> void:
	mat_wall = _shade(wall_tex(), 2, SELF_WALL)
	mat_mat = _shade(mat_tex(), 3, SELF_FLOOR)
	mat_walk = _shade(laminate_tex(), 0, SELF_FLOOR)
	mat_ceil = _shade(ceiling_tex(), 0, SELF_CEIL)
	# CC0 photographs (godot/assets/playroom/SOURCES.md): the ceiling's real tiles, plaster and dirt over
	# the walls, dirt trodden into the mats and walkways. Laid in world metres.
	mat_ceil.set_shader_parameter("photo", 1.0)
	mat_ceil.set_shader_parameter("photo_tex", CEILING_PHOTO)
	mat_ceil.set_shader_parameter("photo_scale", 1.0 / CEILING_M)
	for m: ShaderMaterial in [mat_wall, mat_mat, mat_walk, mat_ceil]:
		m.set_shader_parameter("detail_tex", PLASTER_PHOTO)
		m.set_shader_parameter("grime_tex", GRIME_PHOTO)
	mat_wall.set_shader_parameter("detail_amt", WALL_PLASTER)
	mat_wall.set_shader_parameter("detail_scale", 1.0 / PLASTER_M)
	mat_wall.set_shader_parameter("grime_amt", WALL_GRIME)
	mat_wall.set_shader_parameter("grime_scale", 1.0 / GRIME_M)
	mat_wall.set_shader_parameter("grime_band", 1.0)
	mat_mat.set_shader_parameter("grime_amt", FLOOR_GRIME)
	mat_mat.set_shader_parameter("grime_scale", 1.0 / GRIME_M)
	mat_walk.set_shader_parameter("grime_amt", FLOOR_GRIME)
	mat_walk.set_shader_parameter("grime_scale", 1.0 / GRIME_M)
	mat_ceil.set_shader_parameter("grime_amt", CEIL_GRIME)
	mat_ceil.set_shader_parameter("grime_scale", 1.0 / GRIME_M)
	mat_props = _shade(null, 1, SELF_PROPS)
	mat_decal = _shade(null, 1, 0.62)
	mat_net = _shade(net_tex(), 1, 0.5, 0.5)
	mat_balls = _shade(null, 1, 0.55)
	mat_ballbed = _shade(balls_tex(), 1, 0.5)
	mat_strip = _glow_mat(Color(1.25, 1.27, 1.3), null, true)
	mat_star = _glow_mat(STAR_LIT, null, false, STAR_DARK, 0.85, 1.5)
	mat_line = _glow_mat(LINE_LIT, null, false, LINE_DARK, 0.75, 1.35)
	mat_exit = _glow_mat(Color(1.1, 1.1, 1.1), null, false, Color(1.0, 1.25, 1.05), 1.0, 1.3)
	mat_mural = _shade(MURALS, 1, SELF_WALL, 0.3)
	mat_mural.set_shader_parameter("grime_tex", GRIME_PHOTO)
	mat_mural.set_shader_parameter("grime_amt", WALL_GRIME)
	mat_mural.set_shader_parameter("grime_scale", 1.0 / GRIME_M)
	mat_mural.set_shader_parameter("grime_band", 1.0)

func _commit() -> void:
	mat_decal.set_shader_parameter("albedo_tex", atlas_tex())
	mat_exit.set_shader_parameter("tex", atlas_tex())
	for key: String in lv._chunks:
		var st: SurfaceTool = lv._chunks[key]
		var what := key.get_slice("_", 3)
		st.index()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.name = key
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		match what:
			"pwall": mi.material_override = mat_wall
			"pmat": mi.material_override = mat_mat
			"pwalk": mi.material_override = mat_walk
			"pceil": mi.material_override = mat_ceil
			"pprops": mi.material_override = mat_props
			"pdecal": mi.material_override = mat_decal
			"pnet": mi.material_override = mat_net
			"pbed": mi.material_override = mat_ballbed
			"pstrip": mi.material_override = mat_strip
			"pstar": mi.material_override = mat_star
			"pline": mi.material_override = mat_line
			"pexit": mi.material_override = mat_exit
			"pmural": mi.material_override = mat_mural
		lv.add_child(mi)
	lv._chunks.clear()

# --- helpers -----------------------------------------------------------------------------------

static func gap_vec(gap: StringName) -> Vector3:
	return Vector3(Floor.dir_dx(gap), 0, Floor.dir_dy(gap))

## A colour as the shader expects it (linear), bleached by how far in `pos` is.
func _tone(col: Color, pos: Vector3) -> Color:
	var corr := lv.corruption_at(pos)
	var b := smoothstep(0.25, 1.0, corr) * BLEACH
	var l := col.r * 0.3 + col.g * 0.59 + col.b * 0.11
	var g := Color(l * 0.8 + 0.16, l * 0.8 + 0.16, l * 0.8 + 0.16, col.a)
	var out := col.lerp(g, b)
	out.a = col.a
	return out.srgb_to_linear()

## A box by size and the middle of its bottom face (in a piece's own frame).
static func _b(sx: float, sy: float, sz: float, cx: float, y0: float, cz: float, col: Color) -> Array:
	return [Vector3(sx, sy, sz), Vector3(cx, y0 + sy * 0.5, cz), col]

## Draws boxes [size, centre, colour] in frame `xf` into the props chunk, toned by where they stand.
func _boxes(level: int, xf: Transform3D, boxes: Array, what := "pprops") -> void:
	var st := lv._st(level, xf.origin.x, xf.origin.z, what)
	for b: Array in boxes:
		AnnexView.box(st, xf, b[0], b[1], _tone(b[2], xf * (b[1] as Vector3)))

## A primitive mesh (cylinder, sphere) drawn into a chunk by `xf`, one colour.
## `inward`: the faces turned to look inwards (the inside of a tube you sit in: MH1b, no mask over the camera).
func _prim(level: int, mesh: PrimitiveMesh, xf: Transform3D, col: Color, what := "pprops", inward := false) -> void:
	var st := lv._st(level, xf.origin.x, xf.origin.z, what)
	var arr := mesh.get_mesh_arrays()
	var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var ns: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var nb := xf.basis.inverse().transposed()
	var c := _tone(col, xf.origin)
	for k in idx.size():
		# Inward: each triangle's winding reversed and its normals flipped.
		var i := idx[k - 2 * (k % 3) + 2] if inward else idx[k]
		st.set_normal((nb * ns[i]).normalized() * (-1.0 if inward else 1.0))
		st.set_color(c)
		st.set_uv(Vector2.ZERO)
		st.add_vertex(xf * vs[i])

## A tube without its end caps (the inside of a slide's mouth).
static func _tube(r: float, h: float, seg := 12) -> CylinderMesh:
	var c := _cyl(r, r, h, seg)
	c.cap_top = false
	c.cap_bottom = false
	return c

static func _cyl(top: float, bottom: float, h: float, seg := 12) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

static func _ball(r: float, seg := 10) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = seg
	s.rings = seg / 2
	return s

## The frame of a piece standing at `at` (floor level) with its open side towards `gap`.
static func piece_xf(at: Vector3, gap: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3.UP.cross(gap).normalized(), Vector3.UP, gap), at)

func _edge_kind(level: int, x: int, y: int, d: Vector2i) -> String:
	var vert: Array = lv.edges[level].vertical
	var hor: Array = lv.edges[level].horizontal
	if d == Vector2i(0, -1): return hor[y * W + x]
	if d == Vector2i(0, 1): return hor[(y + 1) * W + x]
	if d == Vector2i(-1, 0): return vert[y * (W + 1) + x]
	return vert[y * (W + 1) + x + 1]

func _room_kind(level: int, x: int, y: int) -> String:
	if x < 0 or y < 0 or x >= W or y >= H:
		return ""
	var rid: int = lv.room_at[level][y * W + x]
	return str(lv.plan.rooms[rid].kind) if rid >= 0 else ""

func _ceiling_y(level: int, x: int, y: int) -> float:
	var open_above := level == 0 and (lv.kind(1, x, y) == "atriumOpen" or lv.kind(1, x, y) == "stair")
	return (2 * LH if open_above else level * LH + LH) - 0.02

func _cell_of(idx: int) -> Vector3i:
	var level := idx / (W * H)
	var r := idx % (W * H)
	return Vector3i(level, r % W, r / W)

# --- floors, ceilings, walls, netting, stairs ---------------------------------------------------

func _floor_what(level: int, x: int, y: int) -> String:
	if lv.kind(level, x, y) != "room":
		return "pwalk"
	var rk := _room_kind(level, x, y)
	return "pwalk" if rk == "lobby" or rk == "store" else "pmat"

func _floors_and_ceilings() -> void:
	for y in H:
		for x in W:
			if lv.walkable(0, x, y):
				if lv.kind(0, x, y) != "stair":
					lv._floor_quad(0, x, y, 0.0, true, _floor_what(0, x, y))
				var above := lv.kind(1, x, y)
				if above != "atriumOpen" and above != "stair":
					lv._floor_quad(0, x, y, LH - 0.001, false, "pceil")
			var k1 := lv.kind(1, x, y)
			if k1 == "corridor" or k1 == "room" or k1 == "landing":
				lv._floor_quad(1, x, y, LH, true, _floor_what(1, x, y))
			if k1 == "corridor" or k1 == "room" or k1 == "atriumOpen" or k1 == "stair" or k1 == "landing":
				lv._floor_quad(1, x, y, 2 * LH - 0.001, false, "pceil")

## As Level._build_walls, with padded walls and, where the rules have a rail (round the ball pits'
## openings on the upper deck), netting to the ceiling over a padded rail.
func _walls() -> void:
	var lift_edge := lv._lift_edge()
	for level in 2:
		var vert: Array = lv.edges[level].vertical
		var hor: Array = lv.edges[level].horizontal
		for y in H:
			for x in W + 1:
				var k: String = vert[y * (W + 1) + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(0, x, y, 1)
				if k == "rail":
					_net(level, Vector3(x * S, 0, y * S), Vector3(x * S, 0, (y + 1) * S))
					continue
				var before_v: String = vert[(y - 1) * (W + 1) + x] if y > 0 else "none"
				var after_v: String = vert[(y + 1) * (W + 1) + x] if y + 1 < H else "none"
				for piece: Array in lv._edge_parts(level, k, is_lift):
					lv._wall_edge(level, x * S, y * S, x * S, (y + 1) * S, Vector2i(x - 1, y), Vector2i(x, y), piece[0], piece[1], piece[2], "pwall", lv._ext(k, before_v), lv._ext(k, after_v))
		for y in H + 1:
			for x in W:
				var k: String = hor[y * W + x]
				var is_lift := level == lv.landing.x and lift_edge == Vector4i(1, x, y, 1)
				if k == "rail":
					_net(level, Vector3(x * S, 0, y * S), Vector3((x + 1) * S, 0, y * S))
					continue
				var before_h: String = hor[y * W + x - 1] if x > 0 else "none"
				var after_h: String = hor[y * W + x + 1] if x + 1 < W else "none"
				for piece: Array in lv._edge_parts(level, k, is_lift):
					lv._wall_edge(level, x * S, y * S, (x + 1) * S, y * S, Vector2i(x, y - 1), Vector2i(x, y), piece[0], piece[1], piece[2], "pwall", lv._ext(k, before_h), lv._ext(k, after_h))

## Netting along an edge: grey mesh from the floor to the ceiling, a padded rail at 1 m, posts at the
## ends. The rules' rail stops you; the net shows it, and you see through it.
func _net(level: int, a: Vector3, b: Vector3) -> void:
	var base := level * LH
	var along := (b - a).normalized()
	var n := Vector3(-along.z, 0, along.x)
	var st := lv._st(level, (a.x + b.x) * 0.5, (a.z + b.z) * 0.5, "pnet")
	var top := LH - 0.03
	var len := a.distance_to(b)
	var col := _tone(Color(1, 1, 1), (a + b) * 0.5 + Vector3(0, base, 0))
	for side: float in [1.0, -1.0]:
		var o := n * 0.01 * side
		AnnexView.quad(st, a + o + Vector3(0, base, 0), b + o + Vector3(0, base, 0), b + o + Vector3(0, base + top, 0), a + o + Vector3(0, base + top, 0),
			Vector2(0, top / 0.1), Vector2(len / 0.1, top / 0.1), Vector2(len / 0.1, 0), Vector2(0, 0), n * side, col)
	var mid := (a + b) * 0.5 + Vector3(0, base, 0)
	var xf := Transform3D(Basis(along, Vector3.UP, along.cross(Vector3.UP)), mid)
	_boxes(level, xf, [_b(len, 0.12, 0.16, 0, 0.95, 0, BLUE), _b(len, 0.12, 0.12, 0, 0.0, 0, RED),
		_b(0.08, top, 0.08, -len * 0.5, 0.0, 0, YELLOW)])

## The soft steps: padded foam blocks in alternating colours.
func _stairs() -> void:
	for s: Dictionary in lv.plan.stairs:
		var v := lv._dir_vec(str(s.dir))
		var fwd := Vector3(v.x, 0, v.y)
		var c0 := Vector3((int(s.x) + 0.5) * S, 0, (int(s.y) + 0.5) * S) - fwd * (S * 0.5)
		var n := int(round(LH / 0.2))
		var depth := int(s.length) * S / n
		for i in n:
			var top := (i + 1) * 0.2
			var size := Vector3(S if v.x == 0 else depth, top, depth if v.x == 0 else S)
			var at := c0 + fwd * (depth * (i + 0.5))
			_boxes(0, Transform3D(Basis.IDENTITY, at), [[size, Vector3(0, top * 0.5, 0), PAL[i % 4]]])

# --- lights ------------------------------------------------------------------------------------

func _find_junctions() -> void:
	for level in 2:
		for y in H:
			for x in W:
				if lv.kind(level, x, y) != "corridor":
					continue
				var ways := 0
				for d: Vector2i in AnnexView.DIRS:
					if lv.kind(level, x + d.x, y + d.y) == "corridor" and _edge_kind(level, x, y, d) == "open":
						ways += 1
				if ways >= 3:
					junctions.append({"level": level, "cell": Vector2i(x, y)})

func _omni(pos: Vector3, energy: float, reach: float) -> void:
	var o := OmniLight3D.new()
	o.position = pos
	o.omni_range = reach
	o.omni_attenuation = LIGHT_DECAY
	o.light_color = Color(0.95, 0.97, 1.0)
	o.light_energy = energy
	o.shadow_enabled = false
	o.distance_fade_enabled = true
	o.distance_fade_begin = 18.0
	o.distance_fade_length = 6.0
	lv.add_child(o)
	lv.main_lights.append(o)
	lv._base_energy.append(energy)

## One light at every walkway junction, one over every zone (its block's middle), one in the lobby.
func _lights() -> void:
	for j: Dictionary in junctions:
		var c: Vector2i = j.cell
		var p := lv.cell_center(int(j.level), c.x, c.y)
		p.y = _ceiling_y(int(j.level), c.x, c.y) - 0.15
		_omni(p, JUNCTION_ENERGY, JUNCTION_REACH)
	for z in zones:
		var mid := Vector2(z.rect.position) * S + Vector2(z.rect.size) * S * 0.5
		var cell := Vector2i(int(mid.x / S), int(mid.y / S))
		var y := _ceiling_y(z.level, cell.x, cell.y) - 0.15
		var high := y > z.level * LH + LH
		_omni(Vector3(mid.x, y, mid.y), ZONE_ENERGY * (1.4 if high else 1.0), 10.0 + (LH if high else 0.0))
	for r: Dictionary in lv.plan.rooms:
		if str(r.kind) == "lobby":
			var c := Vector3((int(r.x) + int(r.w) * 0.5) * S, LH - 0.15, (int(r.y) + int(r.h) * 0.5) * S)
			_omni(c, LOBBY_ENERGY, 9.0)

## White strip lights on the ceiling: one along every walkway cell, rows across every room.
func _strip_lights() -> void:
	for level in 2:
		for y in H:
			for x in W:
				var k := lv.kind(level, x, y)
				if k != "corridor" and k != "room" and k != "landing":
					continue
				var p := lv.cell_center(level, x, y)
				p.y = _ceiling_y(level, x, y) - 0.03
				var along_x := true
				if k == "corridor":
					var ew := int(lv.kind(level, x - 1, y) == "corridor") + int(lv.kind(level, x + 1, y) == "corridor")
					var ns := int(lv.kind(level, x, y - 1) == "corridor") + int(lv.kind(level, x, y + 1) == "corridor")
					along_x = ew >= ns
				else:
					var rid: int = lv.room_at[level][y * W + x]
					if rid < 0:
						continue
					var r: Dictionary = lv.plan.rooms[rid]
					along_x = int(r.w) >= int(r.h)
					# Rows on every other line of cells across the room.
					var across := (y - int(r.y)) if along_x else (x - int(r.x))
					if across % 2 == 1 and (int(r.h) if along_x else int(r.w)) > 2:
						continue
				var st := lv._st(level, p.x, p.z, "pstrip")
				AnnexView.box(st, Transform3D.IDENTITY, Vector3(1.7, 0.04, 0.16) if along_x else Vector3(0.16, 0.04, 1.7), p, Color.WHITE)

## Glow-in-the-dark stars stuck on the ceilings, seeded from the floor so every screen has the same.
func _stars() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(lv.plan.seed) + ":stars:" + str(lv.plan.depth))
	for level in 2:
		for y in H:
			for x in W:
				var k := lv.kind(level, x, y)
				if k != "corridor" and k != "room":
					continue
				var count := rng.randi_range(0, 3) if k == "room" else rng.randi_range(0, 1)
				for i in count:
					var p := Vector3((x + rng.randf_range(0.1, 0.9)) * S, _ceiling_y(level, x, y) - 0.008, (y + rng.randf_range(0.1, 0.9)) * S)
					_star(lv._st(level, p.x, p.z, "pstar"), p, rng.randf_range(0.12, 0.24), rng.randf() * TAU)

static func _star(st: SurfaceTool, c: Vector3, r: float, turn: float) -> void:
	var pts: Array[Vector3] = []
	for i in 10:
		var a := turn + i * TAU / 10.0
		var rr := r if i % 2 == 0 else r * 0.42
		pts.append(c + Vector3(cos(a) * rr, 0, sin(a) * rr))
	for i in 10:
		var a := pts[i]
		var b := pts[(i + 1) % 10]
		for v: Vector3 in [c, b, a]:
			st.set_normal(Vector3.DOWN)
			st.set_color(Color.WHITE)
			st.set_uv(Vector2.ZERO)
			st.add_vertex(v)

## The glowing lines on the mats: a loop just inside every room's walls, and a dashed line down the
## middle of every walkway.
func _mat_lines() -> void:
	for r: Dictionary in lv.plan.rooms:
		if str(r.kind) == "lobby":
			continue
		var level := int(r.level)
		var x0 := int(r.x) * S + 0.4
		var z0 := int(r.y) * S + 0.4
		var x1 := (int(r.x) + int(r.w)) * S - 0.4
		var z1 := (int(r.y) + int(r.h)) * S - 0.4
		var y := level * LH + 0.006
		var st := lv._st(level, (x0 + x1) * 0.5, (z0 + z1) * 0.5, "pline")
		var t := 0.05
		AnnexView.box(st, Transform3D.IDENTITY, Vector3(x1 - x0, 0.004, t), Vector3((x0 + x1) * 0.5, y, z0), Color.WHITE)
		AnnexView.box(st, Transform3D.IDENTITY, Vector3(x1 - x0, 0.004, t), Vector3((x0 + x1) * 0.5, y, z1), Color.WHITE)
		AnnexView.box(st, Transform3D.IDENTITY, Vector3(t, 0.004, z1 - z0), Vector3(x0, y, (z0 + z1) * 0.5), Color.WHITE)
		AnnexView.box(st, Transform3D.IDENTITY, Vector3(t, 0.004, z1 - z0), Vector3(x1, y, (z0 + z1) * 0.5), Color.WHITE)
	for level in 2:
		for y in H:
			for x in W:
				if lv.kind(level, x, y) != "corridor":
					continue
				var p := lv.cell_center(level, x, y) + Vector3(0, 0.006, 0)
				var st := lv._st(level, p.x, p.z, "pline")
				for d: Vector2i in AnnexView.DIRS:
					if lv.kind(level, x + d.x, y + d.y) == "corridor" and _edge_kind(level, x, y, d) == "open":
						var c := p + Vector3(d.x, 0, d.y) * 0.55
						AnnexView.box(st, Transform3D.IDENTITY, Vector3(0.06, 0.004, 0.5) if d.x == 0 else Vector3(0.5, 0.004, 0.06), c, Color.WHITE)

# --- squeaker tiles -----------------------------------------------------------------------------

## Every squeaker tile in the rules: a raised white tile with a red border and the printed note.
func _squeakers() -> void:
	var skip := -1
	if test_break == "squeak" and squeak.size() > 0:
		skip = squeak[squeak.size() / 2]
	for idx in squeak:
		if idx == skip:
			_skipped_squeak = true
			continue
		var c := _cell_of(idx)
		var p := lv.cell_center(c.x, c.y, c.z)
		_boxes(c.x, Transform3D(Basis.IDENTITY, p), [_b(1.7, 0.03, 1.7, 0, 0.0, 0, Color(0.96, 0.95, 0.9))])
		var st := lv._st(c.x, p.x, p.z, "pdecal")
		var uv := atlas_uv(A_NOTE)
		var h := 0.031
		var e := 0.8
		AnnexView.quad(st, p + Vector3(-e, h, -e), p + Vector3(e, h, -e), p + Vector3(e, h, e), p + Vector3(-e, h, e),
			uv.position, Vector2(uv.end.x, uv.position.y), uv.end, Vector2(uv.position.x, uv.end.y), Vector3.UP, _tone(Color.WHITE, p))
		squeaker_tiles.append(idx)

# --- the hiding places ---------------------------------------------------------------------------

## Every hide's furniture at its inside spot, open towards its gap. The middle of each piece's
## footprint is the inside spot (recorded from the boxes as drawn, for check()).
func _furniture() -> void:
	var seat_list := Playroom.seats(fp)
	for h in hides:
		var at := Vector3(h.inside.x / 100.0, h.level * LH, h.inside.y / 100.0)
		var g := gap_vec(h.gap)
		var xf := piece_xf(at, g)
		var col := PAL[h.id % 4]
		var col2 := PAL[(h.id + 2) % 4]
		var body: Array = []
		match h.kind:
			&"pit": body = _pit(h, xf)
			&"slide": body = _slide(h, xf, col, col2)
			&"den": body = _den(h, xf, col, col2)
			&"playhouse": body = _playhouse(h, xf)
			&"table": body = _table(h, xf, seat_list)
			&"chest": body = _chest(h, xf, col, col2)
			&"cubby": body = _cubby(h, xf, true)
		# The footprint's middle, from the boxes that make the body of the piece.
		var lo := Vector3(INF, 0, INF)
		var hi := Vector3(-INF, 0, -INF)
		for b: Array in body:
			var half: Vector3 = (b[0] as Vector3) * 0.5
			var c: Vector3 = b[1]
			for sx: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					var w := xf * (c + Vector3(half.x * sx, 0, half.z * sz))
					lo = Vector3(minf(lo.x, w.x), 0, minf(lo.z, w.z))
					hi = Vector3(maxf(hi.x, w.x), 0, maxf(hi.z, w.z))
		var mid := (lo + hi) * 0.5
		furniture.append({"hide": h.id, "kind": String(h.kind), "level": h.level, "zone": h.zone, "pos": Vector3(mid.x, at.y, mid.z)})
	# The cloakrooms' other cubbies: shallow shelves, too shallow to hide in.
	var doors := Playroom._door_cells(fp)
	var taken := {}
	for h in hides:
		if h.kind == &"cubby":
			taken[Playroom.cell_of(h.inside)] = true
	for room in fp.rooms:
		if room.kind != &"cloak":
			continue
		for slot: Vector3i in Playroom._cubby_wall(fp, room, doors):
			if taken.has(Vector2i(slot.x, slot.y)):
				continue
			var wall := Playroom.DIRS[slot.z]
			var wv := gap_vec(wall)
			var at := lv.cell_center(room.level, slot.x, slot.y) + wv * (S * 0.5 - 0.25)
			_cubby(null, piece_xf(at, -wv), false)

## The ball pit: a padded basin 5.6 m square in the middle of the hall, full of balls. The balls lose
## their colour further in.
func _pit(h: Playroom.Hide, xf: Transform3D) -> Array:
	var half := 2.8
	var t := 0.3
	var rim := 0.42
	var body: Array = [
		_b(half * 2.0, rim, t, 0, 0, -half + t * 0.5, BLUE), _b(half * 2.0, rim, t, 0, 0, half - t * 0.5, BLUE),
		_b(t, rim, half * 2.0 - t * 2.0, -half + t * 0.5, 0, 0, RED), _b(t, rim, half * 2.0 - t * 2.0, half - t * 0.5, 0, 0, RED),
	]
	var caps: Array = [
		_b(half * 2.0 + 0.04, 0.06, t + 0.04, 0, rim, -half + t * 0.5, YELLOW), _b(half * 2.0 + 0.04, 0.06, t + 0.04, 0, rim, half - t * 0.5, YELLOW),
		_b(t + 0.04, 0.06, half * 2.0 - t * 2.0, -half + t * 0.5, rim, 0, GREEN), _b(t + 0.04, 0.06, half * 2.0 - t * 2.0, half - t * 0.5, rim, 0, GREEN),
	]
	_boxes(h.level, xf, body + caps)
	# The bed under the top layer, then the top layer itself (one MultiMesh).
	var inner := half - t
	var bed := lv._st(h.level, xf.origin.x, xf.origin.z, "pbed")
	var y := 0.3
	var c0 := xf * Vector3(-inner, y, -inner)
	var c1 := xf * Vector3(inner, y, -inner)
	var c2 := xf * Vector3(inner, y, inner)
	var c3 := xf * Vector3(-inner, y, inner)
	var tone := _tone(Color.WHITE, xf.origin)
	AnnexView.quad(bed, c0, c1, c2, c3, Vector2(0, 0), Vector2(inner * 4, 0), Vector2(inner * 4, inner * 4), Vector2(0, inner * 4), Vector3.UP, tone)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(fp.seed) + ":pit:" + str(h.id))
	var step := 0.19
	var n := int(inner * 2.0 / step)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _ball(0.085, 8)
	mm.instance_count = n * n
	var corr := lv.corruption_at(xf.origin)
	var fade := smoothstep(0.2, 0.95, corr)
	var i := 0
	for a in n:
		for b in n:
			var p := Vector3(-inner + (a + 0.5) * step + rng.randf_range(-0.04, 0.04), y + 0.03 + rng.randf_range(0.0, 0.07), -inner + (b + 0.5) * step + rng.randf_range(-0.04, 0.04))
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, xf * p))
			var c := PAL[rng.randi_range(0, 3)]
			if rng.randf() < 0.12:
				c = WHITE
			# Further in the balls lose their colour: grey-white.
			var l := c.r * 0.3 + c.g * 0.59 + c.b * 0.11
			c = c.lerp(Color(l * 0.7 + 0.25, l * 0.7 + 0.25, l * 0.7 + 0.25), fade * 0.9)
			mm.set_instance_color(i, c.srgb_to_linear())
			i += 1
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "BallPit_%d" % h.id
	mmi.multimesh = mm
	mmi.material_override = mat_balls
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 34.0
	lv.add_child(mmi)
	return body

## A tube slide's mouth: a tube coming out of the wall at the inside spot, its mouth flared into the
## room; behind it the tube climbs the wall to the floor above (level 0) or drops through the deck
## (level 1, the top of a slide).
func _slide(h: Playroom.Hide, xf: Transform3D, col: Color, col2: Color) -> Array:
	var r := 0.4
	var tube_xf := xf * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 0.48, 0))
	_prim(h.level, _tube(r, 0.9, 14), tube_xf, col)
	# Its dark inside, faced inwards and open at both ends: from the room the mouth is dark, and sat in it
	# (the camera at the hide's eye) the tube's own wall is round the view out (MH1b: no mask drawn).
	_prim(h.level, _tube(r - 0.03, 0.9, 14), tube_xf, DARK, "pprops", true)
	# A flared mouth ring.
	_prim(h.level, _tube(r + 0.06, 0.06, 14), xf * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 0.48, 0.45)), col2)
	if h.level == 0:
		# The climb starts on top of the mouth's tube, never down through it (the camera sits in there).
		var top := _ceiling_y(0, int(xf.origin.x / S), int(xf.origin.z / S)) - xf.origin.y
		_prim(h.level, _cyl(r * 0.85, r * 0.85, top - SLIDE_CLIMB, 14), xf * Transform3D(Basis.IDENTITY, Vector3(0, SLIDE_CLIMB + (top - SLIDE_CLIMB) * 0.5, -0.12)), col)
		for k in int((top - 0.8) / 0.6):
			_prim(h.level, _cyl(r * 0.9, r * 0.9, 0.05, 14), xf * Transform3D(Basis.IDENTITY, Vector3(0, 1.0 + k * 0.6, -0.12)), col2)
	else:
		# The top of a slide: a hood over the mouth and a ladder of padded rungs beside it.
		_boxes(h.level, xf, [_b(1.0, 0.1, 1.0, 0, 1.0, -0.05, col2), _b(0.08, 1.0, 0.08, -0.46, 0, -0.45, col2), _b(0.08, 1.0, 0.08, 0.46, 0, -0.45, col2)])
	# The body for the footprint: the horizontal tube's box.
	return [_b(r * 2.0, r * 2.0, 0.9, 0, 0.08, 0, col)]

## A crawl den: a padded hutch with a netted front, dark inside.
func _den(h: Playroom.Hide, xf: Transform3D, col: Color, col2: Color) -> Array:
	var w := 1.0
	var d := 0.8
	var ht := 1.05
	var body: Array = [
		_b(w, 0.08, d, 0, 0, 0, col2),
		_b(w, ht, 0.06, 0, 0, -d * 0.5 + 0.03, col),
		_b(0.07, ht, d, -w * 0.5 + 0.035, 0, 0, col), _b(0.07, ht, d, w * 0.5 - 0.035, 0, 0, col),
		_b(w + 0.08, 0.1, d + 0.06, 0, ht, 0, col2),
	]
	var inside: Array = [_b(w - 0.16, ht - 0.1, 0.02, 0, 0.08, -d * 0.5 + 0.07, DARK), _b(w - 0.16, 0.02, d - 0.1, 0, ht - 0.04, 0, DARK)]
	var frame: Array = [_b(w, 0.1, 0.08, 0, ht - 0.1, d * 0.5 - 0.04, YELLOW), _b(0.1, ht - 0.1, 0.08, -w * 0.5 + 0.05, 0, d * 0.5 - 0.04, YELLOW),
		_b(0.1, ht - 0.1, 0.08, w * 0.5 - 0.05, 0, d * 0.5 - 0.04, YELLOW)]
	_boxes(h.level, xf, body + inside + frame)
	_net_panel(h.level, xf, Vector3(0, 0.08, d * 0.5 - 0.05), w - 0.2, ht - 0.2)
	return body

## A flat net, facing the piece's front, `w` wide and `ht` tall, bottom middle at `c`.
func _net_panel(level: int, xf: Transform3D, c: Vector3, w: float, ht: float) -> void:
	var st := lv._st(level, xf.origin.x, xf.origin.z, "pnet")
	var n := (xf.basis * Vector3.BACK).normalized()
	var col := _tone(Color.WHITE, xf.origin)
	for side: float in [1.0, -1.0]:
		var o := Vector3(0, 0, 0.005 * side)
		AnnexView.quad(st, xf * (c + o + Vector3(-w * 0.5, 0, 0)), xf * (c + o + Vector3(w * 0.5, 0, 0)), xf * (c + o + Vector3(w * 0.5, ht, 0)), xf * (c + o + Vector3(-w * 0.5, ht, 0)),
			Vector2(0, ht / 0.1), Vector2(w / 0.1, ht / 0.1), Vector2(w / 0.1, 0), Vector2.ZERO, n * side, col)

## A playhouse: yellow plastic walls, a red pitched roof, a blue shutter at eye height (1 m).
func _playhouse(h: Playroom.Hide, xf: Transform3D) -> Array:
	var w := 1.2
	var d := 0.84
	var wh := 1.3
	var body: Array = [
		_b(w, wh, 0.06, 0, 0, -d * 0.5 + 0.03, YELLOW),
		_b(0.06, wh, d, -w * 0.5 + 0.03, 0, 0, YELLOW), _b(0.06, wh, d, w * 0.5 - 0.03, 0, 0, YELLOW),
		# The front wall round the shutter (0.84 to 1.16 m, 0.5 wide).
		_b(w, 0.84, 0.06, 0, 0, d * 0.5 - 0.03, YELLOW), _b(w, wh - 1.16, 0.06, 0, 1.16, d * 0.5 - 0.03, YELLOW),
		_b((w - 0.5) * 0.5, 0.32, 0.06, -(w + 0.5) * 0.25, 0.84, d * 0.5 - 0.03, YELLOW), _b((w - 0.5) * 0.5, 0.32, 0.06, (w + 0.5) * 0.25, 0.84, d * 0.5 - 0.03, YELLOW),
	]
	var trim: Array = [
		_b(0.5, 0.04, 0.1, 0, 0.8, d * 0.5, BLUE), _b(0.5, 0.04, 0.1, 0, 1.16, d * 0.5, BLUE),
		_b(0.04, 0.36, 0.1, -0.25, 0.8, d * 0.5, BLUE), _b(0.04, 0.36, 0.1, 0.25, 0.8, d * 0.5, BLUE),
		_b(0.48, 0.03, 0.03, 0, 1.0, d * 0.5 - 0.02, BLUE),
		_b(w - 0.1, 0.02, d - 0.1, 0, 0.0, 0, DARK),
	]
	_boxes(h.level, xf, body + trim)
	# The roof: two red slopes and a ridge.
	var roof := 0.62
	for side: float in [-1.0, 1.0]:
		var r_xf := xf * Transform3D(Basis(Vector3.BACK, -side * 0.75), Vector3(side * w * 0.26, wh + roof * 0.42, 0))
		_boxes(h.level, r_xf, [_b(0.82, 0.06, d + 0.16, 0, 0, 0, RED)])
	_boxes(h.level, xf, [_b(0.08, 0.08, d + 0.18, 0, wh + roof - 0.02, 0, RED)])
	return body

## The party table: low, long along the room, a cloth to the floor (the hem lifted a little on its
## gap side), paper plates, cups and hats laid for a party that has not started. Kids' chairs at the
## seats (the far party room's are the rules' seats).
func _table(h: Playroom.Hide, xf: Transform3D, seat_list: Array[Playroom.Seat]) -> Array:
	var room: Floor.Room = fp.rooms[h.room]
	# The long axis of the table is the room's long axis; the gap faces one long side (local +z).
	var len := 2.6
	var wid := 1.1
	var ht := 0.56
	var body: Array = [_b(len, 0.05, wid, 0, ht - 0.05, 0, WHITE)]
	_boxes(h.level, xf, body + [_b(len + 0.08, 0.02, wid + 0.08, 0, ht - 0.01, 0, CLOTH)])
	for side: float in [-1.0, 1.0]:
		var hem := TABLE_HEM if side > 0.0 else 0.03
		_tablecloth_edge(h.level, xf, Vector3.BACK * side, len * 0.5, wid * 0.5, ht, hem)
		_tablecloth_edge(h.level, xf, Vector3.RIGHT * side, wid * 0.5, len * 0.5, ht, 0.03)
	for i in 8:
		var along := -1.0 + (i % 4) * 0.66
		var across := -0.32 if i < 4 else 0.32
		var p := Vector3(along, ht + 0.01, across)
		_prim(h.level, _cyl(0.11, 0.1, 0.012, 12), xf * Transform3D(Basis.IDENTITY, p), WHITE)
		_prim(h.level, _cyl(0.035, 0.03, 0.09, 8), xf * Transform3D(Basis.IDENTITY, p + Vector3(0.16, 0.045, 0)), PAL[i % 4])
		_prim(h.level, _cyl(0.0, 0.05, 0.14, 8), xf * Transform3D(Basis.IDENTITY, p + Vector3(0, 0.08, 0)), PAL[(i + 1) % 4])
	# Chairs: the rules' seats in the far party room, the same spots round every other table.
	var spots: Array = []
	if room.id == Playroom.party_room(fp).id:
		for s in seat_list:
			spots.append([Vector3(s.at.x / 100.0, h.level * LH, s.at.y / 100.0), gap_vec(s.facing)])
	else:
		for side: float in [1.0, -1.0]:
			for along: float in [-1.35, -0.45, 0.45, 1.35]:
				spots.append([xf * Vector3(along, 0, side), (xf.basis * Vector3(0, 0, -side)).normalized()])
	for sp: Array in spots:
		var c_xf := piece_xf(sp[0], sp[1])
		_boxes(h.level, c_xf, [_b(0.36, 0.05, 0.34, 0, 0.3, 0, PAL[int(absf(sp[0].x * 7.0)) % 4]), _b(0.36, 0.34, 0.04, 0, 0.35, -0.17, WHITE),
			_b(0.04, 0.3, 0.04, -0.15, 0, -0.14, GREY), _b(0.04, 0.3, 0.04, 0.15, 0, -0.14, GREY), _b(0.04, 0.3, 0.04, -0.15, 0, 0.14, GREY), _b(0.04, 0.3, 0.04, 0.15, 0, 0.14, GREY)])
	return body

## A folded drop below the tabletop. The existing opening on the hide side stays clear.
func _tablecloth_edge(level: int, xf: Transform3D, out: Vector3, across: float, depth: float, top: float, hem: float) -> void:
	var st := lv._st(level, xf.origin.x, xf.origin.z, "pprops")
	var along := Vector3.UP.cross(out)
	var segments := roundi(across * 24.0)
	var folds := roundi(across * 5.0)
	var prev_top := Vector3.ZERO
	var prev_hem := Vector3.ZERO
	for i in range(segments + 1):
		var t := float(i) / segments
		var x := lerpf(-across - 0.02, across + 0.02, t)
		var fold := sin(TAU * folds * t)
		var lower := hem + absf(fold) * 0.035
		var a := xf * (along * x + out * (depth + 0.02) + Vector3.UP * (top - 0.01))
		var b := xf * (along * x + out * (depth + 0.02 + fold * 0.017) + Vector3.UP * lower)
		if i > 0:
			var n := (prev_hem - b).cross(a - b).normalized()
			if n.dot(xf.basis * out) < 0.0:
				n = -n
			var light := 0.90 + 0.10 * n.dot(xf.basis * along)
			var c := _tone(Color(CLOTH.r * light, CLOTH.g * light, CLOTH.b * light), a)
			AnnexView.quad(st, prev_top, a, b, prev_hem, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, n, c)
			AnnexView.quad(st, prev_top, a, b, prev_hem, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, -n, c)
		prev_top = a
		prev_hem = b

## A toy chest: a painted box, its lid open a crack on the gap side, TOYS on the front.
func _chest(h: Playroom.Hide, xf: Transform3D, col: Color, col2: Color) -> Array:
	var w := CHEST.x
	var d := CHEST.z
	var ht := CHEST.y
	# Hollow (MH1b): a floor and four walls, so sat in it the camera has the chest's own inside round it
	# and the lid's crack to look out of; a solid box would vanish round a camera inside it.
	var t := CHEST_WALL
	# The front has the chest's carrying slot cut in it (CHEST_SLOT: its bottom, top and half width): sat
	# back below the rim, that slot is the view out; peeking, the lid's crack above the rim.
	var fz := d * 0.5 - t * 0.5
	var sw := w * 0.5 - CHEST_SLOT.z
	var body: Array = [_b(w, t, d, 0, 0, 0, col), _b(w, ht, t, 0, 0, -d * 0.5 + t * 0.5, col),
		_b(w, CHEST_SLOT.x, t, 0, 0, fz, col), _b(w, ht - CHEST_SLOT.y, t, 0, CHEST_SLOT.y, fz, col),
		_b(sw, CHEST_SLOT.y - CHEST_SLOT.x, t, -w * 0.5 + sw * 0.5, CHEST_SLOT.x, fz, col), _b(sw, CHEST_SLOT.y - CHEST_SLOT.x, t, w * 0.5 - sw * 0.5, CHEST_SLOT.x, fz, col),
		_b(t, ht, d - t * 2.0, -w * 0.5 + t * 0.5, 0, 0, col), _b(t, ht, d - t * 2.0, w * 0.5 - t * 0.5, 0, 0, col)]
	# The painted bands round it, outside the walls only (a band across the whole top would be a ceiling inside).
	var trim: Array = []
	for band: Vector2 in [Vector2(0.0, 0.05), Vector2(ht - 0.06, 0.04)]:
		trim.append_array([_b(w + 0.02, band.y, 0.01, 0, band.x, -d * 0.5 - 0.005, col2), _b(w + 0.02, band.y, 0.01, 0, band.x, d * 0.5 + 0.005, col2),
			_b(0.01, band.y, d, -w * 0.5 - 0.005, band.x, 0, col2), _b(0.01, band.y, d, w * 0.5 + 0.005, band.x, 0, col2)])
	_boxes(h.level, xf, body + trim)
	var lid := xf * Transform3D(Basis(Vector3.RIGHT, -CHEST_LID), Vector3(0, ht, -d * 0.5))
	_boxes(h.level, lid, [_b(w + 0.04, 0.06, d + 0.04, 0, 0, d * 0.5, col2)])
	var st := lv._st(h.level, xf.origin.x, xf.origin.z, "pdecal")
	var front := xf * Vector3(0, CHEST_SLOT.x * 0.55, d * 0.5 + 0.003)   # under the slot
	AnnexView.picture(st, front, (xf.basis * Vector3.BACK).normalized(), 0.4, 0.16, atlas_uv(A_TOYS), _tone(Color.WHITE, xf.origin))
	return body

## A coat cubby. As a hide: 0.8 m deep from the wall, coats hanging inside (between the coats is the
## gap). Otherwise a shallow shelf of the same front, with shoes on it.
func _cubby(h: Playroom.Hide, xf: Transform3D, deep: bool) -> Array:
	var level := h.level if h != null else (1 if xf.origin.y > LH - 0.5 else 0)
	var w := 0.8
	var d := 0.8 if deep else 0.34
	var ht := 1.9
	var body: Array = [
		_b(0.05, ht, d, -w * 0.5 + 0.025, 0, 0, WOOD), _b(0.05, ht, d, w * 0.5 - 0.025, 0, 0, WOOD),
		_b(w, 0.05, d, 0, ht - 0.05, 0, WOOD), _b(w, ht, 0.03, 0, 0, -d * 0.5 + 0.015, WOOD * 0.85),
		_b(w, 0.06, d, 0, 0, 0, WOOD),
	]
	var extra: Array = [_b(w - 0.1, 0.12, 0.03, 0, ht - 0.22, d * 0.5 - 0.02, PAL[int(absf(xf.origin.x + xf.origin.z) * 3.0) % 4])]
	if deep:
		# A rail, two coats and a hat on the shelf.
		extra.append(_b(w - 0.1, 0.025, 0.025, 0, 1.55, -0.05, GREY))
		# Two coats with a hand's width between them: the gap you look out of (MH1b: no mask drawn).
		extra.append(_b(0.3, 0.85, 0.16, -0.2, 0.7, -0.14, BLUE))
		extra.append(_b(0.28, 0.75, 0.14, 0.2, 0.8, 0.02, RED))
		extra.append(_b(w - 0.1, 0.03, d - 0.05, 0, 1.6, 0, WOOD))
		extra.append(_b(0.3, 0.12, 0.25, 0.1, 1.63, -0.1, YELLOW))
	else:
		extra.append(_b(w - 0.1, 0.03, d - 0.04, 0, 0.6, 0, WOOD))
		extra.append(_b(w - 0.1, 0.03, d - 0.04, 0, 1.2, 0, WOOD))
		extra.append(_b(0.14, 0.08, 0.24, -0.18, 0.06, 0, PAL[1]))
		extra.append(_b(0.14, 0.08, 0.24, 0.0, 0.06, 0, PAL[1]))
		extra.append(_b(0.14, 0.08, 0.24, 0.2, 0.63, 0, PAL[2]))
	_boxes(level, xf, body + extra)
	return body

# --- zone signs, EXIT signs, words ----------------------------------------------------------------

## The words on a zone's sign: from the rules (the break guesses them from the zone's kind instead).
func _sign_text(z: Playroom.Zone) -> String:
	if test_break == "sign":
		return "HIDING PLACES HERE: %d. IT LOOKS IN 1." % int(GUESS.get(z.kind, 3))
	return Playroom.sign_text(z)

## Over every way into every zone, on the walkway side of the lintel, a laminated sign with the odds.
func _signs() -> void:
	for z in zones:
		var text := _sign_text(z)
		var uv := atlas_uv(sign_rect(text))
		for di in z.doors:
			var d: Floor.Door = fp.doors[di]
			var a := Vector2i(d.ax, d.ay)
			var b := Vector2i(d.bx, d.by)
			var corr := a if lv.kind(d.level, a.x, a.y) == "corridor" else b
			var other := b if corr == a else a
			var n := Vector3(corr.x - other.x, 0, corr.y - other.y)
			var mid := (lv.cell_center(d.level, a.x, a.y) + lv.cell_center(d.level, b.x, b.y)) * 0.5 + n * (WALL_T * 0.5 + 0.012)
			var at := mid + Vector3(0, DOOR_H + 0.3, 0)
			var st := lv._st(d.level, at.x, at.z, "pdecal")
			AnnexView.picture(st, at, n, SIGN_W, SIGN_W * SIGN_SIZE.y / SIGN_SIZE.x, uv, _tone(Color.WHITE, at))
			signs.append({"zone": z.id, "text": text, "level": d.level, "pos": at, "facing": n})

## The EXIT signs: over the lift on the landing side, and over the lobby's doors on the walkway side.
## They glow in count dark.
func _exits() -> void:
	var v := lv._dir_vec(lv.lift_dir)
	var lc := lv.cell_center(lv.landing.x, lv.landing.y, lv.landing.z)
	var wall := lc + Vector3(v.x, 0, v.y) * (S * 0.5 - WALL_T * 0.5 - 0.012)
	var at := wall + Vector3(0, Level.LIFT_H + 0.22, 0)
	AnnexView.picture(lv._st(lv.landing.x, at.x, at.z, "pexit"), at, -Vector3(v.x, 0, v.y), 0.6, 0.25, atlas_uv(A_EXIT))
	for d: Floor.Door in fp.doors:
		var ka := _room_kind(d.level, d.ax, d.ay)
		var kb := _room_kind(d.level, d.bx, d.by)
		if ka != "lobby" and kb != "lobby":
			continue
		var corr := Vector2i(d.ax, d.ay) if ka != "lobby" else Vector2i(d.bx, d.by)
		var other := Vector2i(d.bx, d.by) if ka != "lobby" else Vector2i(d.ax, d.ay)
		var n := Vector3(corr.x - other.x, 0, corr.y - other.y)
		var mid := (lv.cell_center(d.level, d.ax, d.ay) + lv.cell_center(d.level, d.bx, d.by)) * 0.5 + n * (WALL_T * 0.5 + 0.012)
		var p := mid + Vector3(0, DOOR_H + 0.2, 0)
		AnnexView.picture(lv._st(d.level, p.x, p.z, "pexit"), p, n, 0.5, 0.21, atlas_uv(A_EXIT))

## Room by room: the cut-out words, the lobby's chart and benches, bunting, soft shapes.
func _dress_rooms() -> void:
	var rng := RandomNumberGenerator.new()
	var avoid := {}
	for h in hides:
		avoid[Vector3i(h.level, h.inside.x / 200, h.inside.y / 200)] = true
		avoid[Vector3i(h.level, h.front.x / 200, h.front.y / 200)] = true
	for idx in squeak:
		avoid[_cell_of(idx)] = true
	for d: Floor.Door in fp.doors:
		avoid[Vector3i(d.level, d.ax, d.ay)] = true
		avoid[Vector3i(d.level, d.bx, d.by)] = true
	_place_pieces(avoid)
	for r: Dictionary in lv.plan.rooms:
		var kind := str(r.kind)
		var level := int(r.level)
		rng.seed = hash(str(lv.plan.seed) + ":room:" + str(r.id))
		var c := Vector3((int(r.x) + int(r.w) * 0.5) * S, level * LH, (int(r.y) + int(r.h) * 0.5) * S)
		if kind in ["lobby", "ballpit", "toddler", "party"] and level == 0:
			var corr := lv.corruption(level, int(r.x) + int(r.w) / 2, int(r.y) + int(r.h) / 2)
			var word := WORDS[mini(int(corr * 4.0), 3)] if kind != "lobby" else WORDS[0]
			_word(r, word)
		if kind in MURAL_ROOMS:
			_mural(r)
		match kind:
			"lobby":
				_lobby(r)
			"party":
				_bunting(r)
				_party_sign(r)
			"toddler", "nook", "deck", "den", "store":
				var tries := 3 if kind == "toddler" else (1 if kind == "den" or kind == "store" else 2)
				for i in tries:
					if int(r.w) < 3 or int(r.h) < 3:
						break
					var cx := rng.randi_range(int(r.x) + 1, int(r.x) + int(r.w) - 2)
					var cy := rng.randi_range(int(r.y) + 1, int(r.y) + int(r.h) - 2)
					if avoid.has(Vector3i(level, cx, cy)):
						continue
					avoid[Vector3i(level, cx, cy)] = true
					_soft_shape(level, lv.cell_center(level, cx, cy) + Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3)), rng)

## A ready-made piece: [mesh, colour texture], loaded once.
static func piece_mesh(kind: StringName) -> Array:
	if _piece_cache.has(kind):
		return _piece_cache[kind]
	var scene: PackedScene = load(str(PIECES[kind][0]))
	var root := scene.instantiate()
	var found: Array = [null, null]
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			found[0] = mi.mesh
			var m := mi.get_active_material(0)
			if m is BaseMaterial3D:
				found[1] = (m as BaseMaterial3D).albedo_texture
			break
		stack.append_array(n.get_children())
	root.free()
	_piece_cache[kind] = found
	return found

## The soft-play slides and towers: ready-made pieces stood with their backs to a plain wall in the bigger
## play rooms, in cells clear of every hide, its front, the squeakers and the doors (`avoid`, which this
## extends). Chosen by the floor's seed, so every player sees the same. They are dressing only: where a
## player walks and hides is the rules' (they stand in the back of a cell, as the soft shapes do).
func _place_pieces(avoid: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	var mats := {}
	var rooms: Array = []
	for kind: String in PIECE_ROOMS:
		for r: Dictionary in lv.plan.rooms:
			if str(r.kind) == kind:
				rooms.append(r)
	var per_kind := {}
	for r: Dictionary in rooms:
		var kind := str(r.kind)
		if int(r.w) < 3 or int(r.h) < 3:
			continue
		var level := int(r.level)
		rng.seed = hash(str(lv.plan.seed) + ":pieces:" + str(r.id))
		# The room's door cells, for putting a slide where a player comes in.
		var doors: Array[Vector2i] = []
		for dr: Floor.Door in fp.doors:
			if dr.level != level:
				continue
			for c: Vector2i in [Vector2i(dr.ax, dr.ay), Vector2i(dr.bx, dr.by)]:
				if _in_room(r, c):
					doors.append(c)
		# Every wall cell of the room with a plain wall behind it: [cell, side, door distance, shuffle].
		var spots: Array = []
		for y in range(int(r.y), int(r.y) + int(r.h)):
			for x in range(int(r.x), int(r.x) + int(r.w)):
				if avoid.has(Vector3i(level, x, y)) or not lv.walkable(level, x, y):
					continue
				if level == lv.landing.x and Vector2i(x, y) == Vector2i(lv.landing.y, lv.landing.z):
					continue
				for side in 4:
					var dd: Vector2i = AnnexView.DIRS[side]
					if _edge_kind(level, x, y, dd) == "wall":
						var near := 99
						for dc in doors:
							near = mini(near, absi(dc.x - x) + absi(dc.y - y))
						spots.append([Vector2i(x, y), side, near, 0])
		# A shuffle by the seed.
		for i in range(spots.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var tmp: Variant = spots[i]
			spots[i] = spots[j]
			spots[j] = tmp
		for i in spots.size():
			spots[i][3] = i
		var by_door := spots.duplicate()
		by_door.sort_custom(func(a: Array, b: Array) -> bool: return int(a[2]) * 10000 + int(a[3]) < int(b[2]) * 10000 + int(b[3]))
		var want: int = mini(int(PIECE_ROOMS[kind]), maxi(1, int(r.w) * int(r.h) / 12))
		var placed := 0
		while placed < want and pieces.size() < MAX_PIECES and int(per_kind.get(kind, 0)) < int(PIECE_KIND_CAP[kind]):
			# A tower first (it needs the most room), then a slide by a way in, by turns; whichever fits.
			var order: Array = [&"frame", &"slide"] if placed % 2 == 0 else [&"slide", &"frame"]
			var pk: StringName = &""
			var spec: Array = []
			var got: Array = []
			var found: Array = []
			for k: StringName in order:
				spec = PIECES[k]
				got = piece_mesh(k)
				if got[0] == null:
					continue
				for s: Array in (by_door if k == &"slide" else spots):
					var cells := _piece_cells(r, s[0], int(s[1]), float(spec[3]), float(spec[2]))
					if cells.is_empty():
						continue
					var clear := true
					for c: Vector2i in cells:
						if avoid.has(Vector3i(level, c.x, c.y)):
							clear = false
							break
					if clear:
						found = [s, cells]
						break
				if not found.is_empty():
					pk = k
					break
			if found.is_empty():
				break
			var cell: Vector2i = found[0][0]
			var d: Vector2i = AnnexView.DIRS[int(found[0][1])]
			var out := Vector3(d.x, 0, d.y)
			var depth: float = spec[2]
			var at := lv.cell_center(level, cell.x, cell.y) + out * (S * 0.5 - WALL_T * 0.5 - PIECE_GAP - depth * 0.5)
			at += Vector3(absi(d.y), 0, absi(d.x)) * (S * 0.5)
			at.y = level * LH
			# The piece's long side runs along the wall; it faces into the room.
			var xf := piece_xf(at, -out)
			xf.basis = xf.basis.scaled_local(Vector3.ONE * float(spec[1]))
			var mi := MeshInstance3D.new()
			mi.name = "Piece_%s_%d" % [pk, pieces.size()]
			mi.mesh = got[0]
			mi.transform = xf
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visibility_range_end = 34.0
			# One material per kind and bleach step (further in, the colour goes), each dimmed by the dark.
			var corr := snappedf(lv.corruption_at(at), 0.1)
			var key := "%s:%.2f" % [pk, corr]
			if not mats.has(key):
				var m := _shade(null, 4, SELF_PROPS)
				m.set_shader_parameter("photo_tex", got[1])
				m.set_shader_parameter("corr_fixed", corr)
				m.set_shader_parameter("photo_gain", float(PIECE_GAIN[pk]))
				m.set_shader_parameter("grime_tex", GRIME_PHOTO)
				m.set_shader_parameter("grime_amt", 0.15)
				m.set_shader_parameter("grime_scale", 1.0 / GRIME_M)
				mats[key] = m
			mi.material_override = mats[key]
			lv.add_child(mi)
			var covered: Array = found[1]
			for c: Vector2i in covered:
				avoid[Vector3i(level, c.x, c.y)] = true
			pieces.append({"kind": String(pk), "level": level, "cell": cell, "cells": covered, "pos": at, "facing": -out})
			placed += 1
			per_kind[kind] = int(per_kind.get(kind, 0)) + 1

func _in_room(r: Dictionary, c: Vector2i) -> bool:
	return c.x >= int(r.x) and c.y >= int(r.y) and c.x < int(r.x) + int(r.w) and c.y < int(r.y) + int(r.h)

## The cells a piece `length` along the wall and `depth` into the room stands over, backed to `side` of `cell`
## and the next cell along it (the piece's middle on the line between the two); empty if any of them is outside
## the room, not walkable, or the landing, or the piece is longer than two cells.
func _piece_cells(r: Dictionary, cell: Vector2i, side: int, length: float, depth: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var level := int(r.level)
	var d: Vector2i = AnnexView.DIRS[side]
	var along := Vector2i(absi(d.y), absi(d.x))
	# Two cells along the wall (the piece stands over the line between them), as deep as it needs.
	var deep := maxi(int(ceil((depth + PIECE_GAP + WALL_T * 0.5 - 0.05) / S)), 1)
	if length > 2.0 * S - 0.1:
		return out
	for a in 2:
		for k in deep:
			var c := cell + along * a - d * k
			if not _in_room(r, c) or not lv.walkable(level, c.x, c.y):
				return [] as Array[Vector2i]
			if level == lv.landing.x and c == Vector2i(lv.landing.y, lv.landing.z):
				return [] as Array[Vector2i]
			out.append(c)
	return out

## A faded mural on the room's longest plain wall but one (the longest has the cut-out words).
func _mural(r: Dictionary) -> void:
	var word_side: int = _plain_wall(r)[0]
	var level := int(r.level)
	var width := MURAL_H * 2.0
	for side in 4:
		if side == word_side:
			continue
		var w := _plain_wall(r, -1, side)
		var run: int = w[2]
		if run * S < MURAL_WALL:
			continue
		var d: Vector2i = AnnexView.DIRS[side]
		var mid_i: float = int(w[1]) + run * 0.5
		var base := Vector3(int(r.x) * S, level * LH, int(r.y) * S)
		var p: Vector3
		match side:
			0: p = base + Vector3(mid_i * S, 0, 0)
			1: p = base + Vector3(int(r.w) * S, 0, mid_i * S)
			2: p = base + Vector3(mid_i * S, 0, int(r.h) * S)
			_: p = base + Vector3(0, 0, mid_i * S)
		var into := -Vector3(d.x, 0, d.y)
		var at := p + into * (WALL_T * 0.5 + 0.014) + Vector3(0, MURAL_Y, 0)
		var pic := absi(hash(str(lv.plan.seed) + ":mural:" + str(r.id) + ":" + str(side))) % 4
		var uv := Rect2((pic % 2) * 0.5, (pic / 2) * 0.5, 0.5, 0.5)
		AnnexView.picture(lv._st(level, at.x, at.z, "pmural"), at, into, width, MURAL_H, uv, _tone(Color.WHITE, at))
		murals.append({"room": int(r.id), "level": level, "pos": at, "facing": into, "picture": pic})

## The longest stretch of plain wall in a room: [side (0 n 1 e 2 s 3 w), first cell, cell count]; `skip`
## leaves one side out, `only` looks at one side alone.
func _plain_wall(r: Dictionary, skip := -1, only := -1) -> Array:
	var best: Array = [0, 0, 0]
	var level := int(r.level)
	for side in 4:
		if side == skip or (only >= 0 and side != only):
			continue
		var d: Vector2i = AnnexView.DIRS[side]
		var count := int(r.w) if side % 2 == 0 else int(r.h)
		var run := 0
		for i in count + 1:
			var ok := false
			if i < count:
				var x := int(r.x) + (i if side % 2 == 0 else (int(r.w) - 1 if side == 1 else 0))
				var y := int(r.y) + (i if side % 2 == 1 else (int(r.h) - 1 if side == 2 else 0))
				ok = _edge_kind(level, x, y, d) == "wall" and not (level == lv.landing.x and Vector2i(x, y) == Vector2i(lv.landing.y, lv.landing.z))
			if ok:
				run += 1
			else:
				if run > int(best[2]):
					best = [side, i - run, run]
				run = 0
	return best

## Cut-out letters on the room's plainest wall, each letter its own colour.
func _word(r: Dictionary, text: String) -> void:
	var w := _plain_wall(r)
	var side: int = w[0]
	var run: int = w[2]
	var width := (text.length() * 6 - 1) * LETTER_PX
	if run * S < width + 0.3:
		return
	var level := int(r.level)
	var d: Vector2i = AnnexView.DIRS[side]
	var along := Vector3(1, 0, 0) if side % 2 == 0 else Vector3(0, 0, 1)
	var first: int = w[1]
	var mid_i := first + run * 0.5
	var base := Vector3(int(r.x) * S, level * LH, int(r.y) * S)
	var wall_pt: Vector3
	match side:
		0: wall_pt = base + Vector3(mid_i * S, 0, 0)
		1: wall_pt = base + Vector3(int(r.w) * S, 0, mid_i * S)
		2: wall_pt = base + Vector3(mid_i * S, 0, int(r.h) * S)
		_: wall_pt = base + Vector3(0, 0, mid_i * S)
	var into := -Vector3(d.x, 0, d.y)
	# Read left to right from inside the room.
	var right := (-into).cross(Vector3.UP).normalized()
	var top := wall_pt + into * (WALL_T * 0.5 + 0.02) + Vector3(0, 2.35, 0) - right * (width * 0.5)
	var xf := Transform3D(Basis(right, Vector3.UP, into), top)
	var boxes: Array = []
	for i in text.length():
		var col := PAL[i % 4]
		var rows := PixelFont.rows(text[i])
		for y in rows.size():
			var row: String = rows[y]
			for x in 5:
				if row[x] == "1":
					boxes.append(_b(LETTER_PX, LETTER_PX, 0.035, (i * 6 + x + 0.5) * LETTER_PX, -(y + 1) * LETTER_PX, 0.0175, col))
	_boxes(level, xf, boxes)
	words.append({"room": int(r.id), "text": text, "level": level, "pos": xf * Vector3(width * 0.5, -0.25, 0)})

## The shoe room: SOCKS MUST BE WORN, the height chart beside the lift, benches and shoe racks.
func _lobby(r: Dictionary) -> void:
	var level := int(r.level)
	var v := lv._dir_vec(lv.lift_dir)
	var out := Vector3(v.x, 0, v.y)
	var lc := lv.cell_center(lv.landing.x, lv.landing.y, lv.landing.z)
	var along := Vector3(-out.z, 0, out.x)
	var wall := lc + out * (S * 0.5 - WALL_T * 0.5 - 0.013)
	var st := lv._st(level, lc.x, lc.z, "pdecal")
	var chart := wall + along * 1.15 + Vector3(0, LH * 0.5, 0)
	AnnexView.picture(st, chart, -out, 0.3, LH - 0.02, atlas_uv(A_CHART), _tone(Color.WHITE, chart))
	var socks := wall - along * 1.25 + Vector3(0, 1.55, 0)
	AnnexView.picture(st, socks, -out, 1.4, 0.28, atlas_uv(A_SOCKS), _tone(Color.WHITE, socks))
	# Benches along the lift wall, either side, and a low shoe rack.
	for s: float in [-1.0, 1.0]:
		var at := lc + along * (s * 3.0) + out * 0.62
		var xf := piece_xf(at, -out)
		_boxes(level, xf, [_b(1.6, 0.08, 0.4, 0, 0.36, 0, BLUE), _b(0.06, 0.36, 0.36, -0.7, 0, 0, GREY), _b(0.06, 0.36, 0.36, 0.7, 0, 0, GREY),
			_b(1.5, 0.03, 0.34, 0, 0.1, 0, WOOD), _b(0.22, 0.08, 0.1, -0.4, 0.13, 0, RED), _b(0.22, 0.08, 0.1, 0.3, 0.13, 0, YELLOW)])

## Bunting round a party room: little flags in the palette on a string at 2.6 m.
func _bunting(r: Dictionary) -> void:
	var level := int(r.level)
	var x0 := int(r.x) * S + 0.1
	var z0 := int(r.y) * S + 0.1
	var x1 := (int(r.x) + int(r.w)) * S - 0.1
	var z1 := (int(r.y) + int(r.h)) * S - 0.1
	var corners: Array[Vector3] = [Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)]
	for i in 4:
		var a := corners[i]
		var b := corners[(i + 1) % 4]
		var len := a.distance_to(b)
		var dir := (b - a) / len
		var n := int(len / 0.4)
		var st := lv._st(level, (a.x + b.x) * 0.5, (a.z + b.z) * 0.5, "pprops")
		var into := Vector3(-dir.z, 0, dir.x)
		for k in n:
			var p := a + dir * ((k + 0.5) * len / n) + Vector3(0, level * LH + 2.6 - 0.12 * sin(PI * (k + 0.5) / n), 0)
			var col := _tone(PAL[k % 4], p)
			var p0 := p - dir * 0.13
			var p1 := p + dir * 0.13
			var p2 := p + Vector3(0, -0.26, 0)
			for tri: Array in [[p0, p1, p2], [p0, p2, p1]]:
				var nn := into if tri[1] == p1 else -into
				for q: Vector3 in tri:
					st.set_normal(nn)
					st.set_color(col)
					st.set_uv(Vector2.ZERO)
					st.add_vertex(q)

## PARTY ROOM over the inside of a party room's door.
func _party_sign(r: Dictionary) -> void:
	var w := _plain_wall(r)
	if int(w[2]) < 2:
		return
	var level := int(r.level)
	var side: int = w[0]
	var d: Vector2i = AnnexView.DIRS[side]
	var first: int = w[1]
	var mid_i := first + int(w[2]) * 0.5
	var base := Vector3(int(r.x) * S, level * LH, int(r.y) * S)
	var p: Vector3
	match side:
		0: p = base + Vector3(mid_i * S, 0, 0)
		1: p = base + Vector3(int(r.w) * S, 0, mid_i * S)
		2: p = base + Vector3(mid_i * S, 0, int(r.h) * S)
		_: p = base + Vector3(0, 0, mid_i * S)
	var into := -Vector3(d.x, 0, d.y)
	var at := p + into * (WALL_T * 0.5 + 0.015) + Vector3(0, 1.6, 0)
	AnnexView.picture(lv._st(level, at.x, at.z, "pdecal"), at, into, 1.4, 0.25, atlas_uv(A_PARTY), _tone(Color.WHITE, at))

## A soft-play shape: a foam cube, a cylinder or a wedge, in the palette.
func _soft_shape(level: int, at: Vector3, rng: RandomNumberGenerator) -> void:
	var col := PAL[rng.randi_range(0, 3)]
	match rng.randi_range(0, 2):
		0:
			var s := rng.randf_range(0.4, 0.7)
			_boxes(level, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), at), [_b(s, s, s, 0, 0, 0, col)])
		1:
			_prim(level, _cyl(0.3, 0.3, 0.5, 12), Transform3D(Basis.IDENTITY, at + Vector3(0, 0.25, 0)), col)
		_:
			var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU), at)
			_boxes(level, xf, [_b(0.8, 0.2, 0.6, 0, 0, 0, col), _b(0.8, 0.2, 0.4, 0, 0.2, -0.1, PAL[(rng.randi() + 1) % 4]), _b(0.8, 0.2, 0.2, 0, 0.4, -0.2, col)])

# --- the check: what was drawn is what the rules say ---------------------------------------------

## Compares the drawing with fresh calls to the rules. Returns the problems (empty: all hold) and fills
## `stats`: hides, furniture, max_offset_cm, squeakers (rules, drawn), zones, signs, lights.
func check(stats: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	var tag := "%s/%d" % [fp.seed, fp.depth]
	var rules_hides := Playroom.hides(fp, fp.seed)
	var per_zone := {}
	var by_id := {}
	for f: Dictionary in furniture:
		if by_id.has(int(f.hide)):
			problems.append("%s: hide %d has two pieces of furniture" % [tag, int(f.hide)])
		by_id[int(f.hide)] = f
	var worst := 0.0
	for h in rules_hides:
		per_zone[h.zone] = int(per_zone.get(h.zone, 0)) + 1
		if not by_id.has(h.id):
			problems.append("%s: hide %d (%s in zone %d) has no furniture" % [tag, h.id, h.kind, h.zone])
			continue
		var f: Dictionary = by_id[h.id]
		var p: Vector3 = f.pos
		var off := Vector2(p.x - h.inside.x / 100.0, p.z - h.inside.y / 100.0).length()
		worst = maxf(worst, off)
		if off > 0.05 or str(f.kind) != String(h.kind) or int(f.level) != h.level:
			problems.append("%s: hide %d (%s) drawn as %s on level %d, %.1f cm from its inside spot" % [tag, h.id, h.kind, f.kind, int(f.level), off * 100.0])
	if furniture.size() != rules_hides.size():
		problems.append("%s: %d pieces of hide furniture for %d hides" % [tag, furniture.size(), rules_hides.size()])
	var want := Playroom.squeakers(fp, fp.seed)
	var drawn := {}
	for i in squeaker_tiles:
		drawn[i] = true
	var wanted := {}
	for i in want:
		wanted[i] = true
		if not drawn.has(i):
			var c := _cell_of(i)
			problems.append("%s: the squeaker tile at level %d cell %d,%d is in the rules but not drawn" % [tag, c.x, c.y, c.z])
	for i in squeaker_tiles:
		if not wanted.has(i):
			var c := _cell_of(i)
			problems.append("%s: a squeaker tile is drawn at level %d cell %d,%d where the rules have none" % [tag, c.x, c.y, c.z])
	var sign_count := 0
	var rules_zones := Playroom.zones(fp)
	for z in rules_zones:
		var n := int(per_zone.get(z.id, 0))
		var mine: Array = signs.filter(func(s: Dictionary) -> bool: return int(s.zone) == z.id)
		if mine.size() != z.doors.size() or mine.is_empty():
			problems.append("%s: zone %d (%s) has %d signs for %d ways in" % [tag, z.id, z.kind, mine.size(), z.doors.size()])
		for s: Dictionary in mine:
			sign_count += 1
			var text := str(s.text)
			var said := text.get_slice("HERE: ", 1).get_slice(".", 0)
			if not said.is_valid_int() or int(said) != n or text != "HIDING PLACES HERE: %d. IT LOOKS IN 1." % n:
				problems.append("%s: zone %d (%s): the sign says \"%s\", the rules' hides there number %d" % [tag, z.id, z.kind, text, n])
	var lights := lv.main_lights.size() + lv.emergency_lights.size()
	if lights > LIGHT_LIMIT:
		problems.append("%s: %d real lights, over the renderer's %d" % [tag, lights, LIGHT_LIMIT])
	stats["hides"] = rules_hides.size()
	stats["furniture"] = furniture.size()
	stats["max_offset_cm"] = snappedf(worst * 100.0, 0.01)
	stats["squeakers_rules"] = want.size()
	stats["squeakers_drawn"] = squeaker_tiles.size()
	stats["zones"] = rules_zones.size()
	stats["signs"] = sign_count
	stats["lights"] = lights
	return problems

## The count-dark switch, checked directly: lit, every real light on and the strips lit; at 1 every
## real light off, the lit surfaces black, and the stars, lines and EXIT glowing. Returns problems.
func check_dark() -> Array[String]:
	var problems: Array[String] = []
	var keep := count_dark
	for k: float in [0.0, 1.0, 0.0]:
		set_count_dark(k)
		_apply(1.0, 0.0)
		var on := 0
		for l in lv.main_lights:
			if l.visible and l.light_energy > 0.0:
				on += 1
		var strip := float(mat_strip.get_shader_parameter("energy"))
		var wall := float(mat_wall.get_shader_parameter("energy"))
		var glow_min := INF
		for m: ShaderMaterial in [mat_star, mat_line, mat_exit]:
			glow_min = minf(glow_min, float(m.get_shader_parameter("energy")))
		if k == 0.0 and (on != lv.main_lights.size() or strip < 0.99 or wall < 0.99):
			problems.append("lit: %d of %d lights on, strips %.2f, walls %.2f" % [on, lv.main_lights.size(), strip, wall])
		if k == 1.0 and (on != 0 or strip > 0.0 or wall > 0.0 or glow_min < 1.0):
			problems.append("count dark: %d lights still on, strips %.2f, walls %.2f, the dimmest glow %.2f" % [on, strip, wall, glow_min])
	set_count_dark(keep)
	return problems
