# The lift at the landing, drawn where the rules' car is (plan.car from src/sim/run.ts carGeometry):
# a steel room (the rules' size: 4 m by 4 m, run.gd CAR_WIDTH by CAR_DEPTH, read from plan.car) with its
# own light, two sliding doors as wide as the rules' door, the floor split into a BANK half (left as you
# walk in) and a DOWN half, a door-hold button inside, and on the landing a call button and the indicator
# above the doors. Built in the car's frame: origin at the middle of the doorway on the wall line at floor
# height, x to the right walking in, z OUT of the car (the car is z = -depth .. 0), y up.
# Like src/render/elevator.ts. It only shows what the rules say (doors open, indicator, votes), and on
# a monitor on the back wall every crewmate's drawn face (set_faces). Under it the day monitor (show_day:
# the day quota's rows, client/day_view.gd), and the BANK half's paint turns hatched grey and LOCKED while the
# host says BANK is locked (set_bank_locked; FD3).
class_name Lift
extends Node3D

const CAR_H := 2.5
const DOOR_H := 2.25
const FRONT := 0.09
const DOOR_SECONDS := 0.9
## The door-hold button inside, on the front wall right of the doorway: car-local v (right walking in)
## and height. client/play_link.gd offers the button within reach of this spot.
const HOLD_BUTTON := Vector2(1.25, 1.15)
## The call button on the landing wall left of the doorway, beyond the door frame (a landing in a wider
## lobby): v and height.
const CALL_BUTTON := Vector2(-1.3, 1.12)
## The call button on the landing cell's own left wall (a one-cell lobby, whose side walls meet the door
## frame): distance out from the elevator wall line, and height.
const CALL_SIDE := Vector2(0.35, 1.12)
## How far short of fully open each door panel stops (m).
const PANEL_TUCK := 0.03
## The landing's wall face (the wall is drawn Level.WALL_T thick, centred on the wall line).
const LAND := Level.WALL_T * 0.5
## The monitor on the back wall inside the car: every crewmate's drawn face side by side (North Star
## H1), seen from inside and through the open doors. Its picture is MON_W x MON_H pixels, faces 32 x 32
## (64 x 64 for one or two players) with a 2-pixel gap, four to a row, drawn with nearest filtering.
const MON_W := 138
const MON_H := 70
const MON_SIZE := Vector2(1.2, 1.2 * MON_H / MON_W)
const MON_Y := 2.14
const MON_BG := Color("#0b0f0e")
## The car's light, at full.
const LAMP_ENERGY := 0.8
## The call panel (show_quota): its picture in pixels (two rows of the pixel font), its size on the wall,
## how far above the call button its middle is, and its dark glass.
const QUOTA_PX := Vector2i(88, 21)
const QUOTA_SIZE := Vector2(0.84, 0.84 * 21.0 / 88.0)
const QUOTA_RISE := 0.38
const QUOTA_BG := Color("#0b0605")
## The day monitor (show_day, FD3): a wide strip on the back wall under the faces monitor, big enough to read from
## anywhere in the car through the tape: at most DAY_COLS characters of the HUD's pixel font a line, rows 1 and 2
## wrapped to fit, row 3 (the stakes, boarding only) one line scrolling by at DAY_SCROLL characters a second.
## Its picture in pixels, its size and height on the wall.
const DAY_COLS := 28
const DAY_PX := Vector2i(DAY_COLS * 6 + 4, 44)
const DAY_SIZE := Vector2(2.8, 2.8 * 44.0 / (DAY_COLS * 6 + 4))
const DAY_Y := 1.36
const DAY_SCROLL := 3.0
## The party table's warning (show_party, T15h): a red-lit strip on the landing wall right of the doors (on the
## landing cell's right wall in a one-cell lobby), up to PARTY_COLS characters a row, three rows. Its picture in
## pixels, its size and height on the wall.
const PARTY_COLS := 20
const PARTY_PX := Vector2i(PARTY_COLS * 6 + 4, 32)
const PARTY_SIZE := Vector2(1.0, 1.0 * 32.0 / (PARTY_COLS * 6 + 4))
const PARTY_AT := Vector2(1.45, 1.45)
## HUD1b (the owner, 21 Nov: "put somewhere on paper that each level only gets ten min before tenant arrives"; the
## rates "Lift and tab"): a paper notice on the car's right-hand wall inside, printed in the company's words. The
## minutes are the host's own clock (its "tenant" block's len), so it stays true if the host changes it. On a floor
## with printed rates (the Playroom's anger and health), the same paper lists them under the notice.
const NOTICE_COLS := 22
const NOTICE_ROWS := 18
const NOTICE_PX := Vector2i(NOTICE_COLS * 6 + 8, NOTICE_ROWS * 10 + 8)
const NOTICE_SIZE := Vector2(0.9, 0.9 * float(NOTICE_ROWS * 10 + 8) / float(NOTICE_COLS * 6 + 8))
const NOTICE_Y := 1.4
const NOTICE_PAPER := Color("#e9e2cc")
const NOTICE_INK := Color("#2a2620")
const LOSS_PX := Vector2i(286, 94)
const LOSS_SIZE := Vector2(2.8, 2.8 * LOSS_PX.y / LOSS_PX.x)

## The car as the rules give it (plan.car): half its width, its depth, half its door.
var half := 2.0
var depth := 4.0
var door_half := 0.9
## Where the call button's light is drawn, in the car's frame (tests: within the rules' call reach).
var call_at := Vector3.ZERO
var doors := 0.0          # 0 shut .. 1 open, as drawn
var doors_target := 0.0
var indicator_text := ""
var _ind_img: Image
var _ind_tex: ImageTexture
var _ind_key := ""
var _left: Node3D
var _right: Node3D
var _call_mat: ShaderMaterial
var _hold_mat: ShaderMaterial
var _bank_mat: ShaderMaterial
var _down_mat: ShaderMaterial
var _lamp: OmniLight3D
var _lamp_panel: ShaderMaterial
var _t := 0.0
var _vote := ""
var _light := 1.0
## The monitor: its picture, texture, the faces it shows (FaceCodec text, "" = the default face) and
## where each sits in the picture.
const ReelView = preload("res://client/night_reel_view.gd")
var _monitor: MeshInstance3D
var _face_material: Material
var _reel_material: Material
var _reel_viewport: SubViewport
var _reel_view: ReelView
var monitor_faces: Array[String] = []
var _mon_img: Image
var _mon_tex: ImageTexture
var _mon_key := "-"
var _mon_slots: Array[Rect2i] = []
## The call panel above the call button (client/quota_view.gd): the floor quota, earned against needed.
## What it shows ("" while hidden) and its tone ("count", "met", "refused").
var quota_text := ""
var quota_tone := ""
var _quota_node: Node3D
var _quota_img: Image
var _quota_tex: ImageTexture
var _quota_key := "-"
## The day monitor (client/day_view.gd): the rows it shows ([] blank), and the BANK paint: locked
## (hatched grey, LOCKED) while the host says so, else amber.
var day_rows: Array[String] = []
var bank_locked := false
var _day_img: Image
var _day_tex: ImageTexture
var _day_key := "-"
var _day_scroll := 0.0
var loss_rows := PackedStringArray()
var _loss_monitor: MeshInstance3D
var _loss_image: Image
var _loss_texture: ImageTexture
var _bank_floor: MeshInstance3D
## The party table's warning (show_party): what it shows ("" while hidden).
var party_text := ""
var _party_node: Node3D
var _party_img: Image
var _party_tex: ImageTexture
var _bank_open_mat: ShaderMaterial
var _bank_locked_mat: ShaderMaterial

## HUD1b: the notice's rows as printed ("" rows are gaps), [] for no notice (no Tenant clock: minutes 0).
static func notice_rows(minutes: int, rates: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	if minutes <= 0:
		return PackedStringArray()
	var out := PackedStringArray(["NOTICE TO ALL CREWS", ""])
	out.append_array(PixelFont.wrap("EACH LEVEL ALLOWS %d MINUTE%s BEFORE THE TENANT ARRIVES. PLAN YOUR VISIT ACCORDINGLY." % [minutes, "" if minutes == 1 else "S"], NOTICE_COLS))
	for r: String in rates:
		if r != "":
			out.append("")
			out.append_array(PixelFont.wrap(r, NOTICE_COLS))
	out.append("")
	out.append("- THE MANAGEMENT")
	return out.slice(0, NOTICE_ROWS)

var notice_lines := PackedStringArray()
var _notice_img: Image
var _notice_tex: ImageTexture
var _notice: MeshInstance3D

## HUD1b: prints the notice (notice_rows); none hides the paper.
func show_notice(minutes: int, rates: PackedStringArray = PackedStringArray()) -> void:
	var rows := notice_rows(minutes, rates)
	if rows == notice_lines or _notice == null:
		return
	notice_lines = rows
	_notice.visible = not rows.is_empty()
	if rows.is_empty():
		return
	_notice_img.fill(NOTICE_PAPER)
	for i in rows.size():
		var ink := Color("#8a1c12") if i == 0 else NOTICE_INK
		PixelFont.blit(_notice_img, rows[i], Vector2i(4, 4 + i * 10), ink)
	_notice_tex.update(_notice_img)

func _build_notice() -> void:
	_notice_img = Image.create(NOTICE_PX.x, NOTICE_PX.y, false, Image.FORMAT_RGBA8)
	_notice_img.fill(NOTICE_PAPER)
	_notice_tex = ImageTexture.create_from_image(_notice_img)
	var q := QuadMesh.new()
	q.size = NOTICE_SIZE
	_notice = MeshInstance3D.new()
	_notice.name = "TenantNotice"
	_notice.mesh = q
	_notice.material_override = Level.prop_material(Color.WHITE, _notice_tex)
	# On the right-hand wall inside, facing into the car, its text reading toward the doors.
	_notice.position = Vector3(half - 0.006, NOTICE_Y, -depth * 0.45)
	_notice.rotation = Vector3(0, -PI / 2.0, 0)
	_notice.visible = false
	add_child(_notice)

## Builds the lift for the rules' car (plan.car). `left_wall`: the landing cell has a wall on its left as
## you face the lift (Level.lift_left_wall), so the call button goes on it.
func build(car: Dictionary, left_wall := false) -> void:
	half = float(car.width) * 0.5
	depth = float(car.depth)
	door_half = float(car.doorWidth) * 0.5
	position = Vector3(float(car.doorX), float(car.floorY), float(car.doorZ))
	var right := Vector3(float(car.rightX), 0, float(car.rightZ))
	var inv := Vector3(float(car.inX), 0, float(car.inZ))
	basis = Basis(right, Vector3.UP, -inv)
	var steel := Level.prop_material(Color(0.58, 0.62, 0.64))
	var dark := Level.prop_material(Color(0.19, 0.21, 0.23))
	var door_mat := Level.prop_material(Color(0.66, 0.71, 0.73))
	var ceil := Level.prop_material(Color(0.17, 0.2, 0.21))
	# Walls, ceiling.
	_box(Vector3(0, CAR_H * 0.5, -depth - 0.02), Vector3(half * 2, CAR_H, 0.04), steel)
	_box(Vector3(-half - 0.02, CAR_H * 0.5, -depth * 0.5), Vector3(0.04, CAR_H, depth), steel)
	_box(Vector3(half + 0.02, CAR_H * 0.5, -depth * 0.5), Vector3(0.04, CAR_H, depth), steel)
	_box(Vector3(0, CAR_H + 0.02, -depth * 0.5), Vector3(half * 2, 0.04, depth), ceil)
	_build_notice()
	# Handrail at the back.
	_box(Vector3(0, 0.95, -depth + 0.06), Vector3(half * 1.8, 0.05, 0.05), dark)
	# Front wall inside face, around the door opening.
	var fw := half - door_half
	_box(Vector3(-door_half - fw * 0.5, CAR_H * 0.5, -FRONT - 0.01), Vector3(fw, CAR_H, 0.02), steel).name = "FrontLeft"
	_box(Vector3(door_half + fw * 0.5, CAR_H * 0.5, -FRONT - 0.01), Vector3(fw, CAR_H, 0.02), steel).name = "FrontRight"
	_box(Vector3(0, (DOOR_H + CAR_H) * 0.5, -FRONT - 0.01), Vector3(door_half * 2, CAR_H - DOOR_H, 0.02), steel)
	# A dark frame around the doors on the landing side. The jambs stop under the header: overlapping
	# it, their faces shared its planes and flickered (z-fighting).
	_box(Vector3(-door_half - 0.06, DOOR_H * 0.5, LAND + 0.02), Vector3(0.12, DOOR_H, 0.04), dark)
	_box(Vector3(door_half + 0.06, DOOR_H * 0.5, LAND + 0.02), Vector3(0.12, DOOR_H, 0.04), dark)
	_box(Vector3(0, DOOR_H + 0.06, LAND + 0.02), Vector3(door_half * 2 + 0.24, 0.12, 0.04), dark)
	# Doors.
	_left = Node3D.new()
	_right = Node3D.new()
	add_child(_left)
	add_child(_right)
	_box(Vector3(-door_half * 0.5, DOOR_H * 0.5, -0.0475), Vector3(door_half, DOOR_H, 0.035), door_mat, _left)
	_box(Vector3(door_half * 0.5, DOOR_H * 0.5, -0.0475), Vector3(door_half, DOOR_H, 0.035), door_mat, _right)
	# Floor: BANK on the left walking in (x < 0), DOWN on the right.
	_bank_open_mat = Level.prop_material(Color.WHITE, _paint("BANK", Color("#e8a21c"), Color("#2a1a05"), false))
	_bank_locked_mat = Level.prop_material(Color.WHITE, _paint("LOCKED", Color("#6d6f6c"), Color("#151515"), false, true))
	_bank_mat = _bank_open_mat
	_down_mat = Level.prop_material(Color.WHITE, _paint("DOWN", Color("#b8231c"), Color("#f6efe6"), true))
	_bank_floor = _floor_half(-1.0, _bank_mat)
	_floor_half(1.0, _down_mat)
	_add_sill()
	# The car's light.
	_lamp_panel = Level.glow_material(Color(0.9, 0.95, 1.0), 1.0)
	_box(Vector3(0, CAR_H - 0.01, -depth * 0.5), Vector3(1.4, 0.02, 1.4), _lamp_panel)
	_lamp = OmniLight3D.new()
	_lamp.position = Vector3(0, CAR_H - 0.25, -depth * 0.5)
	_lamp.light_color = Color(0.9, 0.95, 1.0)
	_lamp.light_energy = LAMP_ENERGY
	_lamp.omni_range = 4.6
	_lamp.omni_attenuation = 1.6
	add_child(_lamp)
	# Indicator above the doors, landing side.
	_ind_img = Image.create(26, 11, false, Image.FORMAT_RGBA8)
	_ind_tex = ImageTexture.create_from_image(_ind_img)
	var q := QuadMesh.new()
	q.size = Vector2(0.52, 0.22)
	var ind := MeshInstance3D.new()
	ind.mesh = q
	ind.material_override = Level.glow_material(Color.WHITE, 1.0, _ind_tex)
	ind.position = Vector3(0, DOOR_H + 0.38, LAND + 0.045)
	add_child(ind)
	_box(Vector3(0, DOOR_H + 0.38, LAND + 0.03), Vector3(0.62, 0.3, 0.02), dark)
	# The same indicator inside, over the doors, for the ride.
	var ind_in := MeshInstance3D.new()
	ind_in.mesh = q
	ind_in.material_override = ind.material_override
	ind_in.position = Vector3(0, DOOR_H + 0.12, -FRONT - 0.03)
	ind_in.rotation = Vector3(0, PI, 0)
	ind_in.scale = Vector3(0.8, 0.8, 0.8)
	add_child(ind_in)
	show_indicator("", false, 0)
	# The monitor on the back wall, above the handrail, facing the doors.
	_mon_img = Image.create(MON_W, MON_H, false, Image.FORMAT_RGB8)
	_mon_img.fill(MON_BG)
	_mon_tex = ImageTexture.create_from_image(_mon_img)
	_box(Vector3(0, MON_Y, -depth + 0.015), Vector3(MON_SIZE.x + 0.08, MON_SIZE.y + 0.08, 0.03), dark)
	var mq := QuadMesh.new()
	mq.size = MON_SIZE
	var mon := MeshInstance3D.new()
	mon.name = "Monitor"
	mon.mesh = mq
	mon.material_override = Level.glow_material(Color.WHITE, 0.95, _mon_tex)
	mon.position = Vector3(0, MON_Y, -depth + 0.032)
	add_child(mon)
	_monitor = mon
	_face_material = mon.material_override
	var none: Array[String] = []
	set_faces(none)
	# The day monitor, a strip under the faces (FD3).
	_day_img = Image.create(DAY_PX.x, DAY_PX.y, false, Image.FORMAT_RGB8)
	_day_img.fill(MON_BG)
	_day_tex = ImageTexture.create_from_image(_day_img)
	_box(Vector3(0, DAY_Y, -depth + 0.015), Vector3(DAY_SIZE.x + 0.08, DAY_SIZE.y + 0.06, 0.03), dark)
	var dq := QuadMesh.new()
	dq.size = DAY_SIZE
	var dm := MeshInstance3D.new()
	dm.name = "DayMonitor"
	dm.mesh = dq
	dm.material_override = Level.glow_material(Color.WHITE, 0.95, _day_tex)
	dm.position = Vector3(0, DAY_Y, -depth + 0.032)
	add_child(dm)
	show_day(PackedStringArray())
	# Fixed rows below the day monitor keep the odds available without waiting for the ticker.
	_loss_image = Image.create(LOSS_PX.x, LOSS_PX.y, false, Image.FORMAT_RGB8)
	_loss_texture = ImageTexture.create_from_image(_loss_image)
	var odds_quad := QuadMesh.new()
	odds_quad.size = LOSS_SIZE
	_loss_monitor = MeshInstance3D.new()
	_loss_monitor.name = "LossOddsMonitor"
	_loss_monitor.mesh = odds_quad
	_loss_monitor.material_override = Level.glow_material(Color.WHITE, 0.95, _loss_texture)
	_loss_monitor.position = Vector3(0, DAY_Y - (DAY_SIZE.y + LOSS_SIZE.y) * 0.5 - 0.04, -depth + 0.032)
	_loss_monitor.hide()
	add_child(_loss_monitor)
	# The call button, left of the doors: on the landing wall beyond the landing cell when the lobby is
	# wider than it, else on the landing cell's own left wall, near the doors. Hold button inside.
	_call_mat = Level.glow_material(Color(1.0, 0.55, 0.15), 0.25)
	if left_wall:
		var wx := -(Level.S * 0.5 - Level.WALL_T * 0.5)
		call_at = Vector3(wx + 0.035, CALL_SIDE.y, CALL_SIDE.x)
		_box(Vector3(wx + 0.015, CALL_SIDE.y, CALL_SIDE.x), Vector3(0.03, 0.26, 0.14), dark)
		_box(Vector3(wx + 0.035, CALL_SIDE.y, CALL_SIDE.x), Vector3(0.02, 0.06, 0.06), _call_mat)
	else:
		call_at = Vector3(CALL_BUTTON.x, CALL_BUTTON.y, LAND + 0.04)
		_box(Vector3(CALL_BUTTON.x, CALL_BUTTON.y, LAND + 0.02), Vector3(0.14, 0.26, 0.03), dark)
		_box(Vector3(CALL_BUTTON.x, CALL_BUTTON.y, LAND + 0.04), Vector3(0.06, 0.06, 0.02), _call_mat)
	_build_quota_panel(left_wall, dark)
	_build_party_panel(left_wall, dark)
	_box(Vector3(HOLD_BUTTON.x, HOLD_BUTTON.y, -FRONT - 0.03), Vector3(0.14, 0.2, 0.03), dark)
	_hold_mat = Level.glow_material(Color(0.4, 1.0, 0.5), 0.25)
	_box(Vector3(HOLD_BUTTON.x, HOLD_BUTTON.y, -FRONT - 0.05), Vector3(0.06, 0.06, 0.02), _hold_mat)

## Tests: the car as DRAWN, measured from its meshes in the car's frame (x to the right walking in, z out
## of the car): "box" the AABB of everything inside the car (walls, ceiling, floor, monitor), "bank" and
## "down" the painted floor halves, "doorway" the gap the front wall leaves, "panels" the width the two
## door panels cover when shut. Compared with the rules' car by tests/prop_lift.gd.
func drawn_car() -> Dictionary:
	var parts: Array = []
	_collect_meshes(self, Transform3D.IDENTITY, parts)
	var box := AABB()
	var first := true
	var named := {}
	var panels := AABB()
	var panels_first := true
	for pr: Array in parts:
		var mi: MeshInstance3D = pr[0]
		var bb: AABB = (pr[1] as Transform3D) * mi.mesh.get_aabb()
		named[String(mi.name)] = bb
		var holder := mi.get_parent()
		if holder == _left or holder == _right:
			var shut: AABB = (holder as Node3D).transform.affine_inverse() * bb
			panels = shut if panels_first else panels.merge(shut)
			panels_first = false
			continue
		if bb.get_center().z < -FRONT:
			box = bb if first else box.merge(bb)
			first = false
	var fl: AABB = named.get("FrontLeft", AABB())
	var fr: AABB = named.get("FrontRight", AABB())
	return {"box": box, "bank": named.get("FloorBank", AABB()), "down": named.get("FloorDown", AABB()),
		"doorway": fr.position.x - (fl.position.x + fl.size.x), "panels": panels.size.x}

func _collect_meshes(node: Node, xf: Transform3D, out: Array) -> void:
	for c in node.get_children():
		if not (c is Node3D):
			continue
		var cx := xf * (c as Node3D).transform
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			out.append([c, cx])
		_collect_meshes(c, cx, out)

func _box(pos: Vector3, size: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	(parent if parent else self).add_child(mi)
	return mi

# Worn checker plate across the doorway. A visual cap over the floor, outside both vote panels.
func _add_sill() -> void:
	var plate := PlaneMesh.new()
	plate.size = Vector2(door_half * 2.0, LAND + FRONT)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = preload("res://assets/textures/metal_plate_sill_diff.webp")
	mat.normal_enabled = true
	mat.normal_texture = preload("res://assets/textures/metal_plate_sill_nor_gl.webp")
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.metallic = 0.28
	mat.roughness = 0.64
	var sill := MeshInstance3D.new()
	sill.name = "MetalSill"
	sill.mesh = plate
	sill.material_override = mat
	sill.position = Vector3(0.0, 0.009, (LAND - FRONT) * 0.5)
	sill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sill)


## One painted half of the car's floor: `side` -1 is BANK (left walking in), 1 is DOWN.
func _floor_half(side: float, mat: ShaderMaterial) -> MeshInstance3D:
	var q := PlaneMesh.new()
	q.size = Vector2(half, depth - 0.1)
	var mi := MeshInstance3D.new()
	mi.name = "FloorBank" if side < 0.0 else "FloorDown"
	mi.mesh = q
	mi.material_override = mat
	mi.position = Vector3(side * half * 0.5, 0.006, -depth * 0.5)
	add_child(mi)
	return mi

# The floor paint (src/render/elevator.ts paintHalf): the word twice, stretched along the car, against
# the dividing line, with a hazard edge along it. `hatched`: diagonal stripes over the fill (the locked BANK).
func _paint(word: String, fill: Color, ink: Color, edge_left: bool, hatched := false) -> ImageTexture:
	var w := 48
	var h := 92
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	if hatched:
		var stripe := fill.darkened(0.35)
		for y in h:
			for x in w:
				if posmod(x + y, 8) < 3:
					img.set_pixel(x, y, stripe)
	var ex := 0 if edge_left else w - 3
	for y in range(0, h, 6):
		var c := Color("#f2d43a") if (y / 6) % 2 == 0 else Color("#151515")
		img.fill_rect(Rect2i(ex, y, 3, 6), c)
	img.fill_rect(Rect2i(w - 2 if edge_left else 0, 0, 2, h), Color("#1b1b18"))
	var tw := PixelFont.width(word)
	var sx := 6 if edge_left else w - 6 - tw
	# Image top is the back of the car: upright there for someone walking in, turned round by the doors.
	PixelFont.blit(img, word, Vector2i(sx, 10), ink, Vector2i(1, 2))
	PixelFont.blit(img, word, Vector2i(sx, 68), ink, Vector2i(1, 2), true)
	var t := ImageTexture.create_from_image(img)
	return t

## `label` up to two characters; `arrow` -1 down, 1 up, 0 none; `lit` bright, else a faint glow.
func show_indicator(label: String, lit: bool, arrow: int) -> void:
	var key := "%s|%s|%d" % [label, lit, arrow]
	if key == _ind_key:
		return
	_ind_key = key
	indicator_text = label
	_ind_img.fill(Color("#0b0605"))
	var faint := Color("#2a0f06")
	PixelFont.blit(_ind_img, "▼", Vector2i(2, 2), faint)
	PixelFont.blit(_ind_img, "88", Vector2i(12, 2), faint)
	var on := Color("#ffb02a") if lit else Color("#7a3a12")
	if arrow != 0:
		PixelFont.blit(_ind_img, "▼" if arrow < 0 else "▲", Vector2i(2, 2), on)
	var lw := PixelFont.width(label)
	PixelFont.blit(_ind_img, label, Vector2i(24 - lw, 2), on)
	_ind_tex.update(_ind_img)

## The call panel: a small lit display just above the call button, on the same wall, facing the landing.
func _build_quota_panel(left_wall: bool, dark: ShaderMaterial) -> void:
	_quota_img = Image.create(QUOTA_PX.x, QUOTA_PX.y, false, Image.FORMAT_RGBA8)
	_quota_img.fill(QUOTA_BG)
	_quota_tex = ImageTexture.create_from_image(_quota_img)
	_quota_node = Node3D.new()
	_quota_node.name = "QuotaPanel"
	add_child(_quota_node)
	if left_wall:
		var wx := -(Level.S * 0.5 - Level.WALL_T * 0.5)
		_quota_node.position = Vector3(wx, CALL_SIDE.y + QUOTA_RISE, CALL_SIDE.x + 0.25)
		_quota_node.rotation = Vector3(0, PI / 2.0, 0)
	else:
		_quota_node.position = Vector3(CALL_BUTTON.x - 0.2, CALL_BUTTON.y + QUOTA_RISE, LAND)
	_box(Vector3(0, 0, 0.015), Vector3(QUOTA_SIZE.x + 0.05, QUOTA_SIZE.y + 0.05, 0.03), dark, _quota_node)
	var q := QuadMesh.new()
	q.size = QUOTA_SIZE
	var mi := MeshInstance3D.new()
	mi.name = "QuotaScreen"
	mi.mesh = q
	mi.material_override = Level.glow_material(Color.WHITE, 1.0, _quota_tex)
	mi.position = Vector3(0, 0, 0.032)
	_quota_node.add_child(mi)
	_quota_node.visible = false

## What the call panel shows: `text` one line (client/quota_view.gd), drawn on two; "" hides it. `tone`
## "count" (amber), "met" (green) or "refused" (red); `lit` false dims it (the refusal's blink).
func show_quota(text: String, tone: String, lit := true) -> void:
	var key := "%s|%s|%s" % [text, tone, lit]
	if key == _quota_key or _quota_img == null:
		return
	_quota_key = key
	quota_text = text
	quota_tone = tone
	_quota_node.visible = text != ""
	if text == "":
		return
	_quota_img.fill(QUOTA_BG)
	var ink := Color("#ffb02a")
	if tone == "met":
		ink = Color("#8dff9e")
	elif tone == "refused":
		ink = Color("#ff4a34")
	if not lit:
		ink = ink.darkened(0.75)
	var rows := quota_rows(text)
	for i in rows.size():
		var w := PixelFont.width(rows[i])
		PixelFont.blit(_quota_img, rows[i], Vector2i((QUOTA_PX.x - w) / 2, 3 + i * 10), ink)
	_quota_tex.update(_quota_img)

## The party table's warning panel (T15h), right of the doors, facing the landing.
func _build_party_panel(left_wall: bool, dark: ShaderMaterial) -> void:
	_party_img = Image.create(PARTY_PX.x, PARTY_PX.y, false, Image.FORMAT_RGBA8)
	_party_img.fill(QUOTA_BG)
	_party_tex = ImageTexture.create_from_image(_party_img)
	_party_node = Node3D.new()
	_party_node.name = "PartyPanel"
	add_child(_party_node)
	if left_wall:
		var wx := Level.S * 0.5 - Level.WALL_T * 0.5
		_party_node.position = Vector3(wx, PARTY_AT.y, CALL_SIDE.x + 0.6)
		_party_node.rotation = Vector3(0, -PI / 2.0, 0)
	else:
		_party_node.position = Vector3(PARTY_AT.x, PARTY_AT.y, LAND)
	_box(Vector3(0, 0, 0.015), Vector3(PARTY_SIZE.x + 0.05, PARTY_SIZE.y + 0.05, 0.03), dark, _party_node)
	var q := QuadMesh.new()
	q.size = PARTY_SIZE
	var mi := MeshInstance3D.new()
	mi.name = "PartyScreen"
	mi.mesh = q
	mi.material_override = Level.glow_material(Color.WHITE, 1.0, _party_tex)
	mi.position = Vector3(0, 0, 0.032)
	_party_node.add_child(mi)
	_party_node.visible = false

## What the party table's warning shows (client/hide_view.gd party_warning): `text` wrapped at PARTY_COLS, at most
## three rows; "" hides it.
func show_party(text: String) -> void:
	if text == party_text or _party_img == null:
		return
	party_text = text
	_party_node.visible = text != ""
	if text == "":
		return
	_party_img.fill(QUOTA_BG)
	var rows := PixelFont.wrap(text, PARTY_COLS)
	for i in mini(rows.size(), 3):
		var w := PixelFont.width(rows[i])
		PixelFont.blit(_party_img, rows[i], Vector2i((PARTY_PX.x - w) / 2, 1 + i * 10), Color("#ff4a34"))
	_party_tex.update(_party_img)

## Tests: the lines the party table's warning draws now.
func party_lines() -> PackedStringArray:
	return PackedStringArray() if party_text == "" else PixelFont.wrap(party_text, PARTY_COLS).slice(0, 3)

## Tests: the middle of the call panel's screen in the world.
func quota_point() -> Vector3:
	return _quota_node.global_position if _quota_node != null else Vector3.ZERO

## The panel's line on two rows: after "RECORDED", after a full stop, or after a colon.
static func quota_rows(text: String) -> PackedStringArray:
	for cut: String in ["RECORDED ", "CLOSED ", ". ", ": "]:
		var i := text.find(cut)
		if i >= 0:
			var at := i + cut.length()
			return PackedStringArray([text.left(at).strip_edges(), text.substr(at).strip_edges()])
	return PackedStringArray([text])

## The day monitor's rows (client/day_view.gd): row 1 pale, row 2 amber (green once BANK is open), each wrapped
## at DAY_COLS; row 3 pale, scrolling (update() moves it). [] blanks it.
func show_day(rows: PackedStringArray) -> void:
	var key := "|".join(rows)
	if key == _day_key or _day_img == null:
		return
	_day_key = key
	day_rows.assign(Array(rows))
	_day_scroll = 0.0
	_draw_day()

func show_loss_odds(rows: PackedStringArray) -> void:
	if _loss_monitor == null or rows == loss_rows:
		return
	loss_rows = rows.duplicate()
	_loss_monitor.visible = not rows.is_empty()
	if rows.is_empty():
		return
	_loss_image.fill(MON_BG)
	for i in rows.size():
		PixelFont.blit(_loss_image, rows[i], Vector2i(4, 4 + 10 * i), Color("#ffd27a") if i == 0 else Color("#d8ddd9"))
	_loss_texture.update(_loss_image)

## The lines the day monitor draws now: rows 1 and 2 wrapped, then row 3's window of DAY_COLS characters.
func day_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for i in mini(day_rows.size(), 2):
		out.append_array(PixelFont.wrap(day_rows[i], DAY_COLS))
	if day_rows.size() > 2:
		var tape := day_rows[2] + "    "
		var at := int(_day_scroll) % tape.length()
		out.append((tape + tape).substr(at, DAY_COLS))
	return out

func _draw_day() -> void:
	_day_img.fill(MON_BG)
	var lines := day_lines()
	var row2 := PixelFont.wrap(day_rows[0], DAY_COLS).size() if not day_rows.is_empty() else 0
	var row3 := row2 + (PixelFont.wrap(day_rows[1], DAY_COLS).size() if day_rows.size() > 1 else 0)
	var y := 2
	for i in lines.size():
		if y > DAY_PX.y - 8:
			break
		var ink := Color("#d8ddd9")
		if i >= row2 and i < row3:
			ink = Color("#8dff9e") if day_rows[1].begins_with("BANK OPEN") else Color("#ffb02a")
		PixelFont.blit(_day_img, lines[i], Vector2i(2, y), ink)
		y += 10
	_day_tex.update(_day_img)

## The BANK half's paint: hatched grey and LOCKED, or its amber.
func set_bank_locked(on: bool) -> void:
	if on == bank_locked or _bank_floor == null:
		return
	bank_locked = on
	_bank_mat = _bank_locked_mat if on else _bank_open_mat
	_bank_floor.material_override = _bank_mat

## Tests: the middle of the day monitor in the world.
func day_point() -> Vector3:
	return to_global(Vector3(0, DAY_Y, -depth + 0.032))

## Show the host's reel while riding up. Keep the existing face texture ready underneath.
func show_reel(reel: Variant, host_now: float, player_id: String, pending: Variant) -> void:
	var active: bool = reel is Dictionary and not bool(reel.get("skipped", false))
	if not active:
		if _reel_viewport != null:
			_reel_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			_monitor.material_override = _face_material
		return
	if _reel_viewport == null:
		_reel_viewport = SubViewport.new()
		_reel_viewport.size = ReelView.SIZE
		_reel_viewport.disable_3d = true
		add_child(_reel_viewport)
		_reel_view = ReelView.new()
		_reel_viewport.add_child(_reel_view)
		_reel_material = Level.glow_material(Color.WHITE, 0.95, _reel_viewport.get_texture())
	_reel_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_monitor.material_override = _reel_material
	_reel_view.present(reel, host_now, player_id, pending)

## The monitor shows these faces (FaceCodec text each, "" for a crewmate who drew none) side by side.
func set_faces(codes: Array[String]) -> void:
	var key := "|".join(codes)
	if key == _mon_key or _mon_img == null:
		return
	_mon_key = key
	monitor_faces = codes.duplicate()
	_mon_slots.clear()
	_mon_img.fill(MON_BG)
	var n := mini(codes.size(), 8)
	var k := 2 if n <= 2 else 1
	var side := FaceCodec.SIZE * k
	var cols := mini(n, 4)
	var rows := ceili(n / 4.0)
	var x0 := (MON_W - (cols * (side + 2) - 2)) / 2
	var y0 := (MON_H - (rows * (side + 2) - 2)) / 2
	for i in n:
		var px := FaceCodec.decode_indices(codes[i])
		var img: Image = FaceCodec.to_image(px) if not px.is_empty() else _default_face_image()
		if k != 1:
			img.resize(side, side, Image.INTERPOLATE_NEAREST)
		var at := Vector2i(x0 + (i % 4) * (side + 2), y0 + (i / 4) * (side + 2))
		_mon_img.blit_rect(img, Rect2i(0, 0, side, side), at)
		_mon_slots.append(Rect2i(at, Vector2i(side, side)))
	_mon_tex.update(_mon_img)

## Tests: a short hash of each face as drawn on the monitor (at 32 x 32, comparable with
## CrewView.texture_hash of the decoded face).
func monitor_hashes() -> Array[String]:
	var out: Array[String] = []
	for r in _mon_slots:
		var img := _mon_img.get_region(r)
		img.resize(FaceCodec.SIZE, FaceCodec.SIZE, Image.INTERPOLATE_NEAREST)
		out.append(CrewView.image_hash(img))
	return out

static func _default_face_image() -> Image:
	var img := CrewView.default_face().get_image()
	img.resize(FaceCodec.SIZE, FaceCodec.SIZE, Image.INTERPOLATE_NEAREST)
	img.convert(Image.FORMAT_RGB8)
	return img

func set_doors(open: bool, instant := false) -> void:
	doors_target = 1.0 if open else 0.0
	if instant:
		doors = doors_target

func set_call_lit(on: bool) -> void:
	_call_mat.set_shader_parameter("energy", 1.6 if on else 0.25)

func set_hold_lit(on: bool) -> void:
	_hold_mat.set_shader_parameter("energy", 1.6 if on else 0.25)

## The half the player stands on ("bank", "down" or "").
func set_vote(side: String) -> void:
	_vote = side

func set_light(k: float) -> void:
	_light = k

func update(delta: float) -> void:
	_t += delta
	if day_rows.size() > 2 and _day_img != null:
		var was := int(_day_scroll)
		_day_scroll += delta * DAY_SCROLL
		if int(_day_scroll) != was:
			_draw_day()
	doors = move_toward(doors, doors_target, delta / DOOR_SECONDS)
	var e := doors * doors * (3.0 - 2.0 * doors)
	_left.position.x = -(door_half - PANEL_TUCK) * e
	_right.position.x = (door_half - PANEL_TUCK) * e
	var pulse := 0.42 + (0.68 - 0.42) * (0.5 + 0.5 * sin(_t * 5.0))
	_bank_mat.set_shader_parameter("emit", pulse if _vote == "bank" else 0.16)
	_down_mat.set_shader_parameter("emit", pulse if _vote == "down" else 0.16)
	_bank_mat.set_shader_parameter("albedo", Color.WHITE * (1.0 if _vote == "bank" else (0.5 if _vote != "" else 0.85)))
	_down_mat.set_shader_parameter("albedo", Color.WHITE * (1.0 if _vote == "down" else (0.5 if _vote != "" else 0.85)))
	_lamp.light_energy = LAMP_ENERGY * _light
	_lamp_panel.set_shader_parameter("energy", _light)
