# Native Ward view for the game's explicitly selected local review.
extends Node3D

const Layout = preload("res://sim/ward/layout.gd")
const Move = preload("res://sim/move.gd")
const Footing = preload("res://sim/ward/footing.gd")
const House = preload("res://sim/ward/house.gd")
const Ward = preload("res://sim/ward/state.gd")
const RIGGER_PATH := "res://assets/ward/rigger.glb"
const HAND_PATH := "res://assets/ward/search-hand.glb"
const Surfaces = preload("res://client/ward/surfaces.gdshader")
const WARNING_PATH := "res://assets/ward/loaded-net.ogg"
## The private rig is authored around the abdomen. The forward wrist sits 3.82 m
## ahead of that origin; the host supplies the contact at the sill, not the abdomen.
const RIGGER_WRIST := Vector3(1.81, 0.88, 3.82)
const LIFT_DEPTH := 3.0

var seed_value: int
var walk_model: Ward
var spawn: Vector3
var houses: Array[Dictionary] = []
var walkways: Array[Node3D] = []
var winches: Array[Dictionary] = []
var bridge: Node3D
var bridge_is_open := false
var player := CharacterBody3D.new()
var camera := Camera3D.new()
var lift_gate: StaticBody3D
var lift_spot := Vector3.ZERO
var rigger: Node3D
var animation: AnimationPlayer
var climb_animation: StringName
var loaded_house := -1
var previous_arm := PackedVector3Array()
var hand: Node3D
var rope := MeshInstance3D.new()
var ribbon := ImmediateMesh.new()
var cue_player := AudioStreamPlayer.new()
var load_sound := AudioStreamPlayer3D.new()
var hud := Label.new()
var prompt := Label.new()
var subtitles := Label.new()
var caught := false
var door_houses: Array[StaticBody3D] = []
var colors := {}
var peers := {}
var local_phase := ""
## Caught: after WATCH_DELAY seconds (host clock) the screen watches a living crewmate through their eyes
## (their accepted feet, yaw and pitch from the snapshot, smoothed), and left click or E moves on to the
## next. With no one left to watch it looks down on the houses from above. Client-side only: nothing a
## watcher does reaches the host (look_input leaves the player's own body and facing alone).
const WATCH_DELAY := 2.0
const WATCH_EYE := 1.56
const WATCH_EASE := 0.25
var caught_at := -1.0
var watching := false
var watch_id := ""
var watch_index := 0
var watch_camera := Camera3D.new()
## Player names by id (the room's people list), set by the scene each frame.
var names := {}

func _init(seed_: int, spawn_: Vector3) -> void:
	seed_value = seed_
	walk_model = Ward.new(seed_)
	spawn = spawn_

func _ready() -> void:
	var layout := walk_model.layout
	_setup_world()
	for site: Dictionary in layout.houses:
		_build_house(site)
	for edge: Dictionary in layout.bridges:
		_build_bridge(edge)
	_build_lift()
	_build_crew()
	_build_rigger()
	_build_hud()

func show_host(ward: Dictionary, host_now: float, id: String, crew: Array) -> void:
	walk_model.bridge_lowered = bool(ward.bridgeLowered)
	walk_model.phase = StringName(ward.phase)
	if bridge_is_open != ward.bridgeLowered:
		_set_bridge(ward.bridgeLowered)
	for i in door_houses.size():
		var closed: bool = not ward.doors[i]
		walk_model.requested_doors[i] = not closed
		if door_houses[i].visible != closed:
			_set_solid(door_houses[i], closed)
	var phase: String = ward.phase
	var close_gate := phase == "away" or phase == "departed"
	if lift_gate.visible != close_gate:
		_set_solid(lift_gate, close_gate)
	local_phase = phase
	caught = ward.caught.has(id)
	var text := "STEP OUT OF THE LIFT"
	match phase:
		"away":
			var seconds := maxi(0, ceili(ward.collectionAt - host_now))
			text = "LIFT RETURNS IN %d:%02d" % [seconds / 60, seconds % 60]
		"boarding":
			text = "DOORS CLOSE IN %d" % maxi(0, ceili(ward.departAt - host_now))
		"departed":
			if ward.boarded.has(id):
				text = "ABOARD"
			elif ward.leftBehind.has(id):
				text = "LEFT BEHIND"
			else:
				text = "LIFT DEPARTED"
	hud.text = text
	var winch := _at_winch()
	var door := _by_door()
	prompt.text = ""
	if caught:
		if caught_at < 0.0:
			caught_at = host_now
		prompt.text = "THE HAND CAUGHT YOU"
		if host_now - caught_at >= WATCH_DELAY:
			prompt.text = _watch(watch_targets(crew, ward, id), crew)
	elif phase != "departed":
		if not winch.is_empty():
			prompt.text = "F   RAISE BRIDGE" if bridge_is_open else "F   LOWER BRIDGE"
		elif door >= 0:
			prompt.text = "F   CLOSE DOOR" if ward.doors[door] else "F   OPEN DOOR"
	_show_rigger(ward, host_now)
	_show_crew(crew, id)

## The crewmates a caught player can watch: connected, not caught, not this player; in a fixed order.
static func watch_targets(crew: Array, ward: Dictionary, my_id: String) -> Array[String]:
	var out: Array[String] = []
	var caught_ids: Array = ward.get("caught", [])
	for row: Dictionary in crew:
		var id := str(row.id)
		if id != my_id and bool(row.get("connected", true)) and not caught_ids.has(id):
			out.append(id)
	out.sort()
	return out

static func watch_line(name: String) -> String:
	if name.is_empty():
		return "NO ONE LEFT TO WATCH"
	return "WATCHING THROUGH %s'S EYES   LEFT CLICK OR E: NEXT" % name.to_upper()

## Points the watching camera and returns the line under it.
func _watch(targets: Array[String], crew: Array) -> String:
	var first := not watching
	watching = true
	watch_camera.current = true
	if targets.is_empty():
		watch_id = ""
		var centre := lift_spot
		for site: Dictionary in walk_model.layout.houses:
			centre += Vector3(float(site.x), lift_spot.y, float(site.y))
		centre /= float(walk_model.layout.houses.size() + 1)
		watch_camera.position = centre + Vector3(0, 16, 14)
		watch_camera.look_at(centre, Vector3.UP)
		return watch_line("")
	watch_id = targets[posmod(watch_index, targets.size())]
	for row: Dictionary in crew:
		if str(row.id) == watch_id:
			var body: Move.Body = row.body
			var eye := Vector3(body.x, body.y + WATCH_EYE, body.z)
			var ease := 1.0 if first else WATCH_EASE
			watch_camera.position = watch_camera.position.lerp(eye, ease)
			watch_camera.rotation = Vector3(lerp_angle(watch_camera.rotation.x, float(row.get("pitch", 0.0)), ease),
				lerp_angle(watch_camera.rotation.y, float(row.get("yaw", 0.0)), ease), 0.0)
			break
	return watch_line(str(names.get(watch_id, "a crewmate")))

## Left click or E while watching: the next living crewmate.
func next_watch() -> void:
	watch_index += 1

func _show_rigger(ward: Dictionary, host_now: float) -> void:
	_show_loaded_support(ward, host_now)
	var active: bool = ward.encounter == "climbing" or ward.encounter == "searching"
	rigger.visible = active
	if not active:
		ribbon.clear_surfaces()
		previous_arm.clear()
		hand.hide()
		return
	var room: Dictionary = houses[int(ward.house)]
	var fixture: House = room.fixture
	var shoulder := fixture.to_world(fixture.shoulder)
	var progress := clampf((host_now - ward.startedAt - Ward.WARN_SECONDS) / Ward.CLIMB_SECONDS, 0.0, 1.0)
	var line: Node3D = room.lines[fixture.loaded_support_index()]
	var bases := line.global_position
	bases.y = shoulder.y
	rigger.position = (bases - Vector3.UP * 10.0).lerp(bases, minf(1.0, progress * 1.18))
	rigger.position = rigger.position.lerp(shoulder, smoothstep(0.78, 1.0, progress))
	rigger.rotation.y = (room.root as Node3D).rotation.y - fixture.window_side * PI * 0.5
	rigger.position -= rigger.basis * RIGGER_WRIST
	if animation != null and climb_animation != &"":
		animation.play(climb_animation)
		animation.pause()
		animation.seek(fmod(progress * Ward.CLIMB_SECONDS, 1.75), true)
	var packed := PackedVector3Array()
	for raw: Array in ward.armPoints:
		packed.append(fixture.to_local(Vector3(raw[0], raw[1], raw[2])))
	_draw_arm(fixture, packed)

func _show_crew(crew: Array, my_id: String) -> void:
	for ghost: MeshInstance3D in peers.values():
		ghost.hide()
	for row: Dictionary in crew:
		var id: String = row.id
		if id == my_id or not row.connected:
			continue
		if not peers.has(id):
			var ghost := MeshInstance3D.new()
			var silhouette := CapsuleMesh.new()
			silhouette.height = 1.62
			silhouette.radius = 0.21
			ghost.mesh = silhouette
			ghost.material_override = colors.iron
			peers[id] = ghost
			add_child(ghost)
		var body: Move.Body = row.body
		var ghost: MeshInstance3D = peers[id]
		ghost.position = Vector3(body.x, body.y + 0.81, body.z)
		ghost.visible = not (watching and id == watch_id)

func play_event(event: Dictionary) -> void:
	if event.type == "ward_line_loaded":
		var house: Dictionary = houses[int(event.house)]
		var support: Node3D = house.lines[(house.fixture as House).loaded_support_index()]
		load_sound.global_position = support.global_position
		load_sound.play()
		return
	var cues := {"ward_departed":"ward_lift_departed", "ward_last_minute":"ward_lift_last_minute",
		"ward_returned":"ward_lift_returned", "ward_final_call":"ward_lift_final_call", "ward_closed":"ward_lift_closed"}
	var cue := str(cues.get(event.type, ""))
	if cue.is_empty():
		return
	var path := "res://assets/ward/voice/bella/%s.ogg" % cue
	if ResourceLoader.exists(path):
		cue_player.stream = load(path)
		cue_player.play()
func _setup_world() -> void:
	for key: String in ["plaster", "brick", "wood", "rope", "iron", "light", "glass", "arm"]:
		var material := StandardMaterial3D.new()
		var shades := {"plaster":"#978377", "brick":"#553f37", "wood":"#735341", "rope":"#9d806a",
			"iron":"#33383a", "light":"#ffd09a", "glass":"#456575", "arm":"#81665c"}
		material.albedo_color = Color(shades[key])
		if key == "glass":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.albedo_color.a = 0.18
		if key == "light":
			material.emission_enabled = true
			material.emission = Color(shades[key])
		colors[key] = material
	for key: String in ["plaster", "brick", "wood"]:
		var material := ShaderMaterial.new()
		material.shader = Surfaces
		material.set_shader_parameter("base_color", (colors[key] as StandardMaterial3D).albedo_color)
		material.set_shader_parameter("surface_kind", ["plaster", "wood", "brick"].find(key))
		colors[key] = material
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#0d151d")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#b9c9db")
	env.ambient_light_energy = 0.7
	env.fog_enabled = true
	env.fog_light_color = Color("#0d151d")
	env.fog_density = 0.022
	world.environment = env
	add_child(world)

func _box(parent: Node3D, at: Vector3, dims: Vector3, color: String, solid := false) -> Node3D:
	var anchor: Node3D = StaticBody3D.new() if solid else Node3D.new()
	parent.add_child(anchor)
	anchor.position = at
	var picture := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = dims
	picture.mesh = mesh
	picture.material_override = colors[color]
	anchor.add_child(picture)
	if solid:
		var collision := CollisionShape3D.new()
		collision.name = "CollisionShape3D"
		var shape := BoxShape3D.new()
		shape.size = dims
		collision.shape = shape
		anchor.add_child(collision)
	return anchor

func _beam(parent: Node3D, first: Vector3, last: Vector3, width: float, height: float, color: String, solid := false) -> Node3D:
	var node := _box(parent, (first + last) * 0.5, Vector3(width, height, first.distance_to(last) + 0.12), color, solid)
	var direction := (last - first).normalized()
	node.look_at(node.global_position + direction, Vector3.FORWARD if absf(direction.y) > 0.99 else Vector3.UP)
	return node

## The host's climb starts on the selected front support. Keep its iron shoe and far endpoints
## fixed while the nearby rope pulls laterally; rolling a vertical beam is invisible.
func _load_bearing_support(deck: Node3D, at: Vector3) -> Node3D:
	var line := Node3D.new()
	deck.add_child(line)
	line.position = at
	for i in 4:
		_box(line, Vector3.ZERO, Vector3(0.07, 0.07, 1.0), "rope")
	_pose_support(line, 0.0)
	return line

func _pose_support(line: Node3D, pull: float) -> void:
	var points := [Vector3.DOWN * 18.0, Vector3(pull * 0.25, -2.8, pull * 0.25), Vector3.ZERO,
		Vector3(pull * 0.71, 2.2, pull * 0.71), Vector3.UP * 25.0]
	for i in 4:
		var span := line.get_child(i) as Node3D
		var first: Vector3 = points[i]
		var last: Vector3 = points[i + 1]
		span.position = (first + last) * 0.5
		span.look_at(line.to_global(last), Vector3.FORWARD)
		span.scale.z = first.distance_to(last) + 0.015

func _show_loaded_support(ward: Dictionary, host_now: float) -> void:
	var current := int(ward.house) if ward.encounter in ["warning", "climbing"] else -1
	if loaded_house >= 0 and loaded_house != current:
		_set_house_load(houses[loaded_house], 0.0)
	loaded_house = current
	if current < 0:
		return
	var elapsed := maxf(0.0, host_now - float(ward.startedAt))
	var pull := 0.0
	if elapsed < Ward.WARN_SECONDS:
		pull = 0.34 * sin(PI * elapsed / Ward.WARN_SECONDS)
	else:
		var phase := clampf((elapsed - Ward.WARN_SECONDS) / Ward.CLIMB_SECONDS, 0.0, 1.0)
		pull = 0.17 * sin(phase * TAU * 3.0) * sin(phase * PI)
	_set_house_load(houses[current], pull)

func _set_house_load(house: Dictionary, pull: float) -> void:
	_pose_support(house.support, pull)
	for joint: Node3D in house.ties:
		joint.rotation.z = pull * 1.6

func _lamp(parent: Node3D, at: Vector3) -> void:
	_box(parent, at, Vector3(0.16, 0.18, 0.11), "light")
	var lamp := OmniLight3D.new()
	lamp.position = at
	lamp.light_color = Color("#ffc381")
	lamp.light_energy = 0.84
	lamp.omni_range = 4.5
	parent.add_child(lamp)

func _build_house(site: Dictionary) -> void:
	var fixture := House.new(site, seed_value)
	var root := Node3D.new()
	add_child(root)
	root.position = fixture.to_world(Vector3.ZERO)
	root.rotation.y = -PI * 0.5 if site.id == 0 else 0.0
	var deck := Node3D.new()
	add_child(deck)
	deck.position = Vector3(site.x, site.z + 0.15, site.y)
	var across := float(site.w) + Layout.GALLERY * 2.0
	var deep := float(site.d) + Layout.GALLERY * 2.0
	var half_w := float(site.w) * 0.5
	var half_d := float(site.d) * 0.5
	for side: float in [-1.0, 1.0]:
		_box(deck, Vector3(side * (half_w + Layout.GALLERY * 0.5), -0.12, 0), Vector3(Layout.GALLERY, 0.24, deep), "wood", true)
		_box(deck, Vector3(0, -0.12, side * (half_d + Layout.GALLERY * 0.5)), Vector3(float(site.w), 0.24, Layout.GALLERY), "wood", true)
	var bounds := fixture.floor_bounds
	for wall: AABB in fixture.walls:
		var shade := "brick" if wall.size.y > 0.5 and (wall.position.x < bounds.position.x or absf(wall.position.x - bounds.end.x) < 0.01) else "plaster"
		var outside := wall.size.y > 2.9 and wall.size.z >= bounds.size.y - 0.01 and wall.size.x < 0.2
		if outside and site.id == 0 and wall.position.x < bounds.position.x:
			_lift_wall(root, wall)
		elif outside:
			_window_wall(root, wall, fixture.search_window.has_volume() and is_equal_approx(wall.position.x, fixture.search_window.position.x))
		else:
			_box(root, wall.get_center(), wall.size, "wood" if wall.size.y < 0.18 else shade, true)
	_dress_house(root, site, fixture)
	var door := fixture.door
	var leaf := _box(root, door.get_center(), door.size, "wood", true) as StaticBody3D
	door_houses.append(leaf)
	_set_solid(leaf, false)
	for room: StringName in fixture.areas:
		var at: Vector3 = fixture.areas[room]
		_lamp(root, Vector3(at.x, 2.45, at.z))
	var lines: Array[Node3D] = []
	for x: float in [-1.0, 1.0]:
		for z: float in [-1.0, 1.0]:
			var edge := Vector3(x * (across * 0.5 - 0.13), 0.02, z * (deep * 0.5 - 0.13))
			_box(deck, edge, Vector3(0.26, 0.25, 0.26), "iron")
			if lines.size() == fixture.loaded_support_index():
				lines.append(_load_bearing_support(deck, edge))
			else:
				lines.append(_beam(deck, edge - Vector3.UP * 18.0, edge + Vector3.UP * 25.0, 0.07, 0.07, "rope"))
	var support := lines[fixture.loaded_support_index()]
	var ties := _interior_ties(root, fixture, root.to_local(support.global_position))
	houses.append({"fixture": fixture, "lines": lines, "support": support, "root": root, "ties": ties})

## The suspension shoe feeds a tie through the frame of each storey to the rear wall.
## The weighted take-up lever swings on its iron pin when the line bears weight.
func _interior_ties(root: Node3D, fixture: House, shoe: Vector3) -> Array[Node3D]:
	var ties: Array[Node3D] = []
	var rear: Vector3 = fixture.areas[&"rear"]
	for floor: House.Storey in fixture.storeys:
		var height := float(floor.height) + 2.12
		var front := Vector3(shoe.x, height, shoe.z)
		var rear_eye := Vector3(rear.x, height, rear.z)
		var inward := front.direction_to(rear_eye)
		# Carry the tie along the clear side of the rear stair framing.
		rear_eye += Vector3(inward.z, 0, -inward.x) * 1.05
		inward = front.direction_to(rear_eye)
		# The ray through the occupied room ends at a wall even in the turned lift house.
		var bounds := fixture.floor_bounds
		var run_x := INF if is_zero_approx(inward.x) else (bounds.end.x - rear_eye.x if inward.x > 0 else bounds.position.x - rear_eye.x) / inward.x
		var run_z := INF if is_zero_approx(inward.z) else (bounds.end.y - rear_eye.z if inward.z > 0 else bounds.position.y - rear_eye.z) / inward.z
		var end := rear_eye + inward * minf(run_x, run_z)
		_beam(root, front, end, 0.06, 0.08, "iron")
		_box(root, front, Vector3(0.21, 0.18, 0.21), "iron")
		_box(root, end, Vector3(0.24, 0.23, 0.13), "wood")
		var mount := _beam(root, rear_eye - inward * 1.45, rear_eye - inward * 1.25, 0.18, 0.15, "wood")
		ties.append(_take_up_lever(mount))

	# The first partition hides the rear lever from the entry. Bring an indicator
	# down the entry face of the same timber frame, on the occupied side of the jamb.
	var first_door: Vector3 = fixture.room_doors[0]
	var entry: Vector3 = fixture.areas[&"entry"]
	var jamb_side := signf(entry.x - first_door.x)
	var pivot := Vector3(first_door.x + jamb_side * 0.69, 2.04, first_door.z - House.WALL_THICKNESS * 0.5 - 0.11)
	var entry_mount := _box(root, pivot, Vector3(0.22, 0.17, 0.18), "wood")
	_beam(root, pivot + Vector3.UP * 0.08, Vector3(pivot.x, 2.9, pivot.z), 0.05, 0.055, "iron")
	var entry_lever := _take_up_lever(entry_mount)
	entry_lever.name = "EntryTakeUp"
	ties.append(entry_lever)
	return ties


func _take_up_lever(mount: Node3D) -> Node3D:
	var joint := Node3D.new()
	mount.add_child(joint)
	_box(joint, Vector3(0, -0.20, 0), Vector3(0.075, 0.40, 0.075), "iron")
	_box(joint, Vector3(0, -0.43, 0), Vector3(0.15, 0.14, 0.11), "rope")
	return joint

func _lift_wall(root: Node3D, wall: AABB) -> void:
	var middle := wall.get_center()
	var side_width := (wall.size.z - 1.24) * 0.5
	for flip: float in [-1.0, 1.0]:
		_box(root, middle + Vector3(0, 0, flip * (side_width + 1.24) * 0.5),
			Vector3(wall.size.x, wall.size.y, side_width), "brick", true)
	_box(root, Vector3(middle.x, 2.615, middle.z), Vector3(wall.size.x, 0.87, 1.24), "brick", true)

func _window_wall(root: Node3D, wall: AABB, open_sash := false) -> void:
	var pane := Vector3(wall.size.x, 1.25, 1.42)
	var center := wall.get_center()
	var sill := 0.82
	var top := sill + pane.y
	_box(root, Vector3(center.x, sill * 0.5, center.z), Vector3(wall.size.x, sill, wall.size.z), "brick", true)
	_box(root, Vector3(center.x, (top + wall.end.y) * 0.5, center.z), Vector3(wall.size.x, wall.end.y - top, wall.size.z), "brick", true)
	var side_width := (wall.size.z - pane.z) * 0.5
	for side: float in [-1.0, 1.0]:
		_box(root, Vector3(center.x, sill + pane.y * 0.5, center.z + side * (side_width + pane.z) * 0.5),
			Vector3(wall.size.x, pane.y, side_width), "brick", true)
	if not open_sash:
		_box(root, Vector3(center.x, sill + pane.y * 0.5, center.z), pane, "glass", true)
		_box(root, Vector3(center.x, sill + pane.y * 0.5, center.z), Vector3(wall.size.x + 0.05, pane.y, 0.045), "wood")
	for y: float in ([sill, top] if open_sash else [sill, sill + pane.y * 0.52, top]):
		_box(root, Vector3(center.x, y, center.z), Vector3(wall.size.x + 0.12, 0.065, pane.z + 0.10), "wood")
	for z: float in [-0.5, 0.5]:
		_box(root, Vector3(center.x, sill + pane.y * 0.5, center.z + pane.z * z),
			Vector3(wall.size.x + 0.12, pane.y, 0.075), "wood")

func _dress_house(root: Node3D, site: Dictionary, fixture: House) -> void:
	# Distinct rooflines and occupied upper windows keep the eight named homes legible across the shaft.
	var bounds := fixture.floor_bounds
	var width := bounds.size.x
	var depth := bounds.size.y
	var center := bounds.get_center()
	var floors: int = site.floors
	for level: int in range(1, floors):
		var base := float(level) * House.HEIGHT
		for side: float in [-1.0, 1.0]:
			var wall_root := Node3D.new()
			root.add_child(wall_root)
			wall_root.position.y = base
			_window_wall(wall_root, AABB(Vector3(side * width * 0.5 - 0.07, 0, 0), Vector3(0.14, House.HEIGHT, depth)))
			_box(root, Vector3(0, base + House.HEIGHT * 0.50, center.y + side * depth * 0.50),
				Vector3(width, House.HEIGHT, 0.15), "brick")
			_box(root, Vector3(side * width * 0.5, base + 1.27, center.y),
				Vector3(0.04, 0.94, 1.1), "light")
	for storey: House.Storey in fixture.storeys:
		for slab: AABB in storey.slab:
			_box(root, slab.get_center(), slab.size, "wood", true)
		for jamb: AABB in storey.partitions:
			_box(root, jamb.get_center(), jamb.size, "plaster", true)
		if storey.incoming != null:
			_dress_stairs(root, storey.incoming)
		if storey.height > 0 and storey.height < House.HEIGHT * floors:
			_lamp(root, Vector3(-width * 0.30, storey.height + 2.37, depth * 0.28))
			_lamp(root, Vector3(width * 0.30, storey.height + 2.37, depth * 0.75))
	var roof_y := House.HEIGHT * floors
	_box(root, Vector3(0, roof_y, center.y), Vector3(width + 0.4, 0.18, depth + 0.48), "iron")
	for side: float in [-1.0, 1.0]:
		var roof := _box(root, Vector3(side * width * 0.26, roof_y + 0.24, center.y),
			Vector3(width * 0.56, 0.13, depth + 0.5), "iron")
		roof.rotation.z = -side * deg_to_rad(11.0 if floors == 1 else 7.0)
		_box(root, Vector3(side * (width * 0.5 - 0.035), 0.125, center.y), Vector3(0.085, 0.23, depth), "wood")
	_box(root, Vector3(-width * 0.28, roof_y + 0.61, center.y - 0.61), Vector3(0.35, 0.88, 0.39), "brick")
	_box(root, Vector3(-width * 0.28, roof_y + 1.03, center.y - 0.61), Vector3(0.48, 0.15, 0.49), "iron")
	for opening: Vector3 in fixture.room_doors:
		for side: float in [-1.0, 1.0]:
			_box(root, opening + Vector3(side * 0.55, 1.07, 0), Vector3(0.10, 2.14, 0.20), "wood")
		_box(root, opening + Vector3(0, 2.20, 0), Vector3(1.18, 0.12, 0.20), "wood")
	var shelf_y := 1.9 if floors > 1 else 1.47
	var shelf_depth := 0.18
	var rear := bounds.end.y - 0.16
	var cabinet_x := -width * 0.24 if int(site.id) % 2 == 0 else width * 0.24
	_box(root, Vector3(cabinet_x, shelf_y, rear), Vector3(1.25, 0.08, shelf_depth), "wood")
	for item: int in range(2 + (int(site.id) % 4)):
		var shape := CylinderMesh.new()
		shape.top_radius = 0.045 + item * 0.006
		shape.bottom_radius = shape.top_radius * 0.8
		shape.height = 0.18 if int(site.id) % 2 == 0 else 0.27
		var cup := MeshInstance3D.new()
		cup.mesh = shape
		cup.material_override = colors.plaster if item % 3 == 0 else colors.iron
		cup.position = Vector3(cabinet_x - 0.40 + float(item) * 0.18, shelf_y + 0.04 + shape.height * 0.5, rear)
		root.add_child(cup)

func _dress_stairs(root: Node3D, stair: House.Stair) -> void:
	const TREADS := 18
	var run_length := absf(stair.from.x - stair.to.x)
	for tread in TREADS:
		var where := stair.from.lerp(stair.to, (float(tread) + 0.5) / TREADS)
		_box(root, where - Vector3.UP * 0.065, Vector3(run_length / TREADS + 0.008, 0.13, House.STAIR_WIDTH), "wood")
	for side: float in [-1.0, 1.0]:
		var offset := Vector3(0, 0.82, side * House.STAIR_WIDTH * 0.49)
		# Keep both ends open where the walking model lets the crew turn onto a landing.
		_beam(root, stair.from.lerp(stair.to, 1.0 / 6.0) + offset,
			stair.from.lerp(stair.to, 5.0 / 6.0) + offset, 0.055, 0.065, "wood")
		for post in range(3, TREADS, 3):
			var at := stair.from.lerp(stair.to, float(post) / TREADS) + Vector3(0, 0.41, offset.z)
			_box(root, at, Vector3(0.052, 0.82, 0.052), "iron")

func _path_point(raw: Array) -> Vector3:
	return Footing.path_point(raw)

func _build_bridge(edge: Dictionary) -> void:
	var root := Node3D.new()
	add_child(root)
	var path: Array = edge.path
	for i in range(1, path.size()):
		var from := _path_point(path[i - 1])
		var to := _path_point(path[i])
		_beam(root, from - Vector3.UP * 0.11, to - Vector3.UP * 0.11, Footing.DECK_WIDTH, 0.22, "wood", true)
		var heading := (to - from).normalized()
		var side := heading.cross(Vector3.UP).normalized() * 0.73
		# The crew needs room to round a joint without the next span's rail across the path.
		var trim := minf(0.82, from.distance_to(to) * 0.24)
		var rail_from := from + heading * trim
		var rail_to := to - heading * trim
		if i < path.size() - 1:
			_box(root, to - Vector3.UP * 0.11, Vector3(Footing.JOINT_WIDTH, 0.21, Footing.JOINT_WIDTH), "wood", true)
		for flip: float in [-1.0, 1.0]:
			_beam(root, rail_from + side * flip + Vector3.UP * 0.9, rail_to + side * flip + Vector3.UP * 0.9, 0.07, 0.07, "rope", true)
			_beam(root, rail_from + side * flip + Vector3.UP * 0.52, rail_to + side * flip + Vector3.UP * 0.52, 0.07, 0.08, "rope", true)
	if edge.kind == "winch":
		bridge = root
		for end: int in [0, 1]:
			var point := _path_point(path[0 if end == 0 else path.size() - 1])
			var other := _path_point(path[1 if end == 0 else path.size() - 2])
			var offset := (other - point).cross(Vector3.UP).normalized()
			_box(self, point + offset * 0.59 + Vector3.UP * 0.3, Vector3(0.26, 0.6, 0.25), "iron")
			winches.append({"house": int(edge.a if end == 0 else edge.b), "point": point + offset * 0.59})
		_set_bridge(false)
	else:
		walkways.append(root)

func _set_bridge(lowered: bool) -> void:
	bridge_is_open = lowered
	bridge.visible = lowered
	for child: Node in bridge.get_children():
		_set_solid(child as StaticBody3D, lowered)

func _set_solid(node: StaticBody3D, enabled: bool) -> void:
	node.visible = enabled
	node.get_node("CollisionShape3D").set_deferred("disabled", not enabled)

func _build_lift() -> void:
	var foyer: House = houses[0].fixture
	var box := Node3D.new()
	add_child(box)
	box.position = foyer.to_world(Vector3(foyer.floor_bounds.position.x - 0.12, 0.15, foyer.floor_bounds.get_center().y))
	lift_spot = box.to_global(Vector3(0, 0, -LIFT_DEPTH * 0.5))
	_box(box, Vector3(0, -0.12, -LIFT_DEPTH * 0.5), Vector3(1.35, 0.22, LIFT_DEPTH), "iron", true)
	_box(box, Vector3(0, 2.26, -LIFT_DEPTH * 0.5), Vector3(1.35, 0.12, LIFT_DEPTH), "iron", true)
	for side: float in [-1.0, 1.0]:
		_box(box, Vector3(side * 0.72, 1.1, -LIFT_DEPTH * 0.5), Vector3(0.11, 2.20, LIFT_DEPTH), "iron", true)
	_box(box, Vector3(0, 1.1, -LIFT_DEPTH), Vector3(1.55, 2.2, 0.12), "iron", true)
	lift_gate = _box(box, Vector3(0, 1.09, 0), Vector3(1.24, 2.18, 0.08), "iron", true)
	_set_solid(lift_gate, false)
	_lamp(box, Vector3(0, 2.04, -LIFT_DEPTH + 0.1))

func _build_crew() -> void:
	player.floor_snap_length = 0.27
	player.floor_max_angle = deg_to_rad(45)
	add_child(player)
	player.position = spawn
	var collider := CollisionShape3D.new()
	var body := CapsuleShape3D.new()
	body.height = 1.68
	body.radius = 0.21
	collider.shape = body
	collider.position.y = 0.84
	player.add_child(collider)
	player.add_child(camera)
	camera.position.y = 1.56
	camera.current = true
	player.rotation.y = PI
	add_child(watch_camera)
func _build_rigger() -> void:
	rigger = (load(RIGGER_PATH) as PackedScene).instantiate()
	add_child(rigger)
	rigger.hide()
	var players := rigger.find_children("*", "AnimationPlayer")
	if not players.is_empty():
		animation = players[0] as AnimationPlayer
		for key: StringName in animation.get_animation_list():
			if key != &"RESET":
				climb_animation = key
				break
	hand = (load(HAND_PATH) as PackedScene).instantiate()
	add_child(hand)
	hand.hide()
	rope.mesh = ribbon
	add_child(rope)
	load_sound.stream = load(WARNING_PATH) as AudioStream
	load_sound.unit_size = 5.0
	load_sound.max_distance = 42.0
	add_child(load_sound)

func _build_hud() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	add_child(cue_player)
	for label: Label in [hud, prompt, subtitles]:
		canvas.add_child(label)
		label.add_theme_color_override("font_color", Color("#ffd9a6"))
		label.add_theme_color_override("font_outline_color", Color("#1b1615"))
		label.add_theme_constant_override("outline_size", 6)
		label.add_theme_font_size_override("font_size", 22)
	hud.position = Vector2(24, 22)
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.position.y -= 126.0
	prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	subtitles.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	subtitles.position.y -= 64.0
	subtitles.grow_horizontal = Control.GROW_DIRECTION_BOTH
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func look_input(event: InputEvent) -> void:
	if caught:
		# A caught player's own body and facing stay as the host last accepted them.
		var next: bool = (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E) \
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)
		if next and watching:
			next_watch()
		if event is InputEventMouseButton and event.pressed and DisplayServer.get_name() != "headless":
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		player.rotate_y(-event.relative.x * 0.0023)
		camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.0023, -1.42, 1.42)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _by_lift() -> bool:
	return player.position.distance_to(lift_spot) < 1.05

func _at_winch() -> Dictionary:
	for winch: Dictionary in winches:
		if player.position.distance_to(winch.point) < 1.25:
			return winch
	return {}

func _by_door() -> int:
	for i in houses.size():
		var fixture: House = houses[i].fixture
		var at := fixture.to_local(player.position)
		if Vector2(at.x, at.z).length() < 1.12 and absf(at.y) < 0.6:
			return i
	return -1

## Correct a predicted step when a newer door or deck state disagrees with the host.
func reconcile(body: Move.Body) -> void:
	var accepted := Vector3(body.x, body.y, body.z)
	var predicted := player.position
	if not walk_model.walk_clear(accepted, accepted):
		return
	if not walk_model.walk_clear(predicted, predicted) or (accepted.distance_to(predicted) > 0.24 and not walk_model.walk_clear(accepted, predicted)):
		player.position = accepted

func _move(motion: Vector3, delta: float) -> void:
	player.position = walk_model.walk(player.position, Vector2(motion.x, motion.z) * delta)

func _draw_arm(fixture: House, local_points: PackedVector3Array) -> void:
	if local_points == previous_arm:
		return
	previous_arm = local_points.duplicate()
	ribbon.clear_surfaces()
	hand.visible = local_points.size() > 1
	if not hand.visible:
		return
	var points := PackedVector3Array()
	for point: Vector3 in local_points:
		points.append(fixture.to_world(point))
	hand.position = points[-1]
	var final := (points[-1] - points[-2]).normalized()
	if absf(final.dot(Vector3.UP)) < 0.98 and not final.is_zero_approx():
		hand.look_at(hand.position + final, Vector3.UP, true)
	var rings: Array[PackedVector3Array] = []
	const SIDES := 8
	for i in points.size():
		var tangent := (points[mini(i + 1, points.size() - 1)] - points[maxi(0, i - 1)]).normalized()
		var side := tangent.cross(Vector3.UP).normalized()
		if side.is_zero_approx():
			side = Vector3.RIGHT
		var up := tangent.cross(side).normalized()
		var ring := PackedVector3Array()
		for j in SIDES:
			var angle := TAU * j / SIDES
			ring.append(points[i] + lerpf(0.085, 0.055, float(i) / (points.size() - 1)) * (side * cos(angle) + up * sin(angle)))
		rings.append(ring)
	ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLES, colors.arm)
	for i in range(points.size() - 1):
		for j in SIDES:
			var k := (j + 1) % SIDES
			for vertex: Vector2i in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i, k), Vector2i(i, k), Vector2i(i + 1, j), Vector2i(i + 1, k)]:
				var surface_point := rings[vertex.x][vertex.y]
				ribbon.surface_set_normal((surface_point - points[vertex.x]).normalized())
				ribbon.surface_add_vertex(surface_point)
	ribbon.surface_end()
