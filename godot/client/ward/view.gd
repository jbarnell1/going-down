# Native Ward view for the game's explicitly selected local review.
extends Node3D

const Layout = preload("res://sim/ward/layout.gd")
const Move = preload("res://sim/move.gd")
const Footing = preload("res://sim/ward/footing.gd")
const House = preload("res://sim/ward/house.gd")
const Ward = preload("res://sim/ward/state.gd")
## WF2: the main game's look: its mouse sensitivity, pitch limit and field of view.
const Main = preload("res://client/main.gd")
const RIGGER_PATH := "res://assets/ward/rigger.glb"
const HAND_PATH := "res://assets/ward/search-hand.glb"
## AW1: the Ward's surfaces and sky (CC0 photographs at one world scale, the lift's shaft, the cavern's roof, the mist).
const WardSkin = preload("res://client/ward/skin.gd")
## AW1: the height fog under the decks (world y, density): the drop reads as haze, not a black void.
const FOG_HEIGHT := -4.0
const FOG_HEIGHT_DENSITY := 0.08
## The loaded line: the library's net creak (assets/sfx/playroom/net_flap.ogg, the owner's; SOURCES.md).
const WARNING_PATH := "res://assets/sfx/playroom/net_flap.ogg"
## The rig (assets_src/blender/rigger/build_rigger.py) is authored around the abdomen. The forward wrist sits 3.82 m
## ahead of that origin; the host supplies the contact at the sill, not the abdomen.
const RIGGER_WRIST := Vector3(1.81, 0.88, 3.82)
## MR1: the owner's Meshy figure, rigged by hand (assets_src/blender/rigger/build_rigger_v2.py), shown unless the
## game was started with `figures=old` (client/figures.gd) or the file is missing. Its origin is the abdomen's centre; its wrist (the
## hand bone's head while "Rigger Climb" plays, where the arm and body are held at rest) is measured by the build and
## checked by tests/test_rigger_v2.gd. Its own hand is folded away in that clip: search-hand.glb stays the only hand.
const RIGGER_V2_PATH := "res://assets/ward/rigger_v2.glb"
const RIGGER_WRIST_V2 := Vector3(0.788, 2.484, 4.965)
## The helmet lamp: weak and short, so it never shows him before the loaded line and the climb are heard. It only
## exists while he is drawn (climbing or searching), and lights about 3 m around his head.
const LAMP_ENERGY := 0.6
const LAMP_RANGE := 3.0
## RW1: the new figure's clip while he hangs outside a house searching it (the build's "hang": legs holding, body and
## arm at rest, wrist at RIGGER_WRIST_V2, his own hand folded), played looping. Today's figure has none and holds its
## climb clip as before.
const HOLD_CLIP := &"hang"
## RW1: the new figure's own clips and how each plays (glTF carries no loop flag; set here rather than in the
## .import file, which the editor would rewrite at length). "Rigger Climb" is sought, never played on its own.
const V2_LOOPS := {&"climb": Animation.LOOP_LINEAR, &"hang": Animation.LOOP_LINEAR, &"search": Animation.LOOP_LINEAR,
	&"reach": Animation.LOOP_NONE, &"withdraw": Animation.LOOP_NONE}

## Sets V2_LOOPS on a player's clips (the imported resources, shared by every instance).
static func set_v2_loops(player: AnimationPlayer) -> void:
	for clip: StringName in V2_LOOPS:
		if player.has_animation(clip):
			player.get_animation(clip).loop_mode = V2_LOOPS[clip]
## RW1: the drawn arm's thickness (radius at the wrist, at the hand) and colour. The new figure's forearm is about
## 0.13 m thick at the wrist and the colour of its skin there (measured from rigger_v2.glb's albedo), so the paid-out
## arm continues it; today's figure keeps its own.
const ARM_RADII := Vector2(0.085, 0.055)
const ARM_RADII_V2 := Vector2(0.13, 0.055)
const ARM_COLOR_V2 := "#847076"
## RR1 stage 2: the crawling Rigger's feet (client/ward/rigger_feet.gd), or null without the new figure.
var feet: SkeletonModifier3D = null
## RR1 stage 2: the light under his belly (figure space: -Y towards the surface), cold and weak.
var rim_light: OmniLight3D = null
const RIM_COLOR := "#8fa6c8"
const RIM_ENERGY := 1.4
const RIM_RANGE := 7.0
const RIM_UNDER := -1.8
const Graph = preload("res://sim/ward/rigger_graph.gd")
## True when this run asked for the new figures (read once, in _init; tests may set it before the view is added).
var figures_new := false
var rigger_wrist := RIGGER_WRIST
var lamp_light: OmniLight3D
var hold_animation: StringName = &""
var arm_radii := ARM_RADII
var arm_material := "arm"

## The shared choice (client/figures.gd): the new figures unless started with `figures=old`.
static func new_figures() -> bool:
	return Figures.use_new()
const LIFT_DEPTH := 3.0

var seed_value: int
var walk_model: Ward
## WL1: the look round the layout (railings, hangers, the roof, the lift car, the doors): client/ward/dress.gd.
const Dress = preload("res://client/ward/dress.gd")
## WL1: the cavern's roof (world y), where every line is fixed.
var roof_y := 25.0
## WL1: the game's lift car (client/lift.gd), its doors open while the lift waits.
var lift_car: Lift
## WL1: each house's front door on its hinge (0 shut, Dress.DOOR_SWING open) and where it is turning to.
var door_hinges: Array[Node3D] = []
var _door_swing: Array[float] = []
## WL1: the drawbridge's own dressing (hidden with it while it is raised).
var bridge_dress: Node3D
## WN4: the walk's wire rounding and the refused-step check (client/ward/net_walk.gd).
const NetWalk = preload("res://client/ward/net_walk.gd")
var net_walk := NetWalk.new()
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
## IV1: the game's announcer (client/announcer.gd ward_line) when this view is drawn inside the main game: the lift's
## lines then go through its one queue (subtitled, on the Voice bus, never over another line). Unset: this view's
## own player, as before.
var say: Callable
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
## WF3: false when the scene draws the main game's HUD and crew figures instead (client/ward/review.gd): the
## labels still hold the Ward's lines for it, unseen, and no grey capsules are drawn.
var own_hud := true
var capsules := true
## WN1: false when the main scene plays the Ward as a normal level (client/ward/floor.gd): the main game's camera,
## environment and mouse are used; the Ward's environment is kept in `environment` for the main scene to take.
var own_camera := true
var own_environment := true
var environment: Environment

## WG1: `layout` the Ward block's layout options ([] today's Ward; sim/ward/layout.gd from_wire).
func _init(seed_: int, spawn_: Vector3, layout: Array = []) -> void:
	seed_value = seed_
	walk_model = Ward.new(seed_, Layout.from_wire(layout))
	spawn = spawn_
	figures_new = new_figures()

func _ready() -> void:
	var layout := walk_model.layout
	_setup_world()
	roof_y = Dress.roof_y(layout)
	for site: Dictionary in layout.houses:
		_build_house(site)
	for edge: Dictionary in layout.bridges:
		_build_bridge(edge)
	_build_lift()
	# WL1: the railings, the walkways' stringers and hangers, and the cavern's roof (client/ward/dress.gd).
	var docked := Dress.docked_sides(layout)
	for site: Dictionary in layout.houses:
		Dress.gallery_rail(self, site, docked.get(int(site.id), []), lift_spot.x if int(site.id) == 0 else INF)
	Dress.cavern_roof(self, layout, roof_y)
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
		if i < _door_swing.size():
			_door_swing[i] = 0.0 if closed else Dress.DOOR_SWING
	var phase: String = ward.phase
	var close_gate := phase == "away" or phase == "departed"
	if lift_gate.visible != close_gate:
		_set_solid(lift_gate, close_gate)
	if lift_car != null:
		# WL1: the car's doors as on every floor: open while the lift waits for the crew, shut while it is away.
		lift_car.set_doors(not close_gate, local_phase == "")
	local_phase = phase
	caught = ward.caught.has(id)
	var extras: Dictionary = ward.get("extras", {})
	# WH1c: a home's inner doors, shut or open, in the walk model and on the screen.
	if extras.get("inner") is Array:
		walk_model.set_inner_doors_wire(extras["inner"])
		_show_inner_doors()
	shown_lift = ward.get("lift", {})
	called = extras.get("called", false) == true
	var webbed_rows: Dictionary = extras.get("web", {})
	webbed_me = webbed_rows.has(id)
	_show_station(extras)
	_show_web(extras, host_now, id, crew)
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
	if called:
		# WC1: every floor's lift, called from the station: no clock to show.
		text = called_line(ward.get("lift", {}), phase, ward, id, station_name)
		# The intercom says the call's two moments once each as the lift's phase changes.
		var lift_phase := str((ward.get("lift", {}) as Dictionary).get("phase", ""))
		if lift_phase != _spoken_lift_phase:
			_spoken_lift_phase = lift_phase
			if say.is_valid():
				if lift_phase == "away" and station_name != "":
					say.call("ward_station")
				elif lift_phase == "coming":
					say.call("ward_called")
	var left_out: bool = (ward.get("leftBehind", []) as Array).has(id)
	if left_out and not _left_said and say.is_valid():
		say.call("ward_left_behind")
	_left_said = left_out
	hud.text = text
	var winch := _at_winch()
	var door := _by_door()
	prompt.text = ""
	cut_fill = -1.0
	if webbed_me:
		# WC1: hung in the web; the screen's own sequence (client/ward/web_view.gd) shows it.
		prompt.text = "WRAPPED IN WEB. A CREWMATE CAN CUT YOU DOWN"
	elif caught:
		if caught_at < 0.0:
			caught_at = host_now
		prompt.text = "THE HAND CAUGHT YOU"
		if host_now - caught_at >= WATCH_DELAY:
			prompt.text = _watch(watch_targets(crew, ward, id), crew)
	elif phase != "departed":
		var cut := _cut_prompt(extras, host_now, id)
		if cut != "":
			prompt.text = cut
		elif not winch.is_empty():
			prompt.text = "F   RAISE BRIDGE" if bridge_is_open else "F   LOWER BRIDGE"
		elif door >= 0:
			prompt.text = "F   CLOSE DOOR" if ward.doors[door] else "F   OPEN DOOR"
	_show_rigger(ward, host_now)
	_show_crew(crew, id)

## WC1: the lift called from the station (net/host_rules.gd ward_call; the block's extras), this player hung in the web,
## the station's house as a name, and the cut's progress for the HUD's bar (-1: none).
var called := false
var webbed_me := false
var _spoken_lift_phase := ""
var _left_said := false
var station_name := ""
var cut_fill := -1.0
var station_node: Node3D = null
var station_light: ShaderMaterial = null
var car_paint: Node3D = null
## Cocoons drawn, by the hung player's id.
var cocoons := {}
## The bundle the hand carries while a catch is carried to its hang point.
var carried: Node3D = null

## WC1: the HUD's line for the Ward's lift when it is called (every floor's words where they are true). `lift`: the run's
## own lift as the snapshot has it (client/main.gd: phase, floorsAway, bellLeft).
static func called_line(lift: Dictionary, ward_phase: String, ward: Dictionary, id: String, house_name: String) -> String:
	var phase := str(lift.get("phase", ward_phase))
	match phase:
		"arriving", "unloading":
			return "STEP OUT OF THE LIFT"
		"away":
			return "THE LIFT'S CALL BUTTON IS IN THE %s" % house_name if house_name != "" else "CALL THE LIFT FROM THE FAR HOUSE"
		"coming":
			var away: Variant = lift.get("floorsAway")
			if away != null and int(away) > 0:
				return "LIFT COMING: %d FLOOR%s AWAY" % [int(away), "" if int(away) == 1 else "S"]
			return "LIFT COMING"
		"boarding":
			return "DOORS CLOSE IN %d   LEFT: BANK   RIGHT: DOWN" % maxi(0, ceili(float(lift.get("bellLeft", 0.0))))
	if (ward.get("boarded", []) as Array).has(id):
		return "ABOARD"
	if (ward.get("leftBehind", []) as Array).has(id):
		return "LEFT BEHIND"
	return "LIFT DEPARTED"

## A house's style as words: "lampkeepers_cottage" is "LAMPKEEPERS COTTAGE".
static func house_words(style: String) -> String:
	return style.replace("_", " ").to_upper()

## WC1: the call button at the station: the landing's own (client/lift.gd: a dark plate and its orange button, lit
## while the car comes) on an iron post; and BANK and DOWN painted on the car's floor, as every car has.
func _show_station(extras: Dictionary) -> void:
	if not called:
		if station_node != null:
			station_node.visible = false
		if car_paint != null:
			car_paint.visible = false
		return
	if station_node == null and extras.get("station") is Array:
		var p: Array = extras["station"]
		station_node = Node3D.new()
		station_node.name = "CallStation"
		add_child(station_node)
		station_node.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
		_box(station_node, Vector3(0, 0.6, 0), Vector3(0.08, 1.2, 0.08), "iron")
		var dark := StandardMaterial3D.new()
		dark.albedo_color = Color("#1b1b18")
		var plate := MeshInstance3D.new()
		var plate_mesh := BoxMesh.new()
		plate_mesh.size = Vector3(0.14, 0.26, 0.03)
		plate.mesh = plate_mesh
		plate.material_override = dark
		plate.position = Vector3(0, 1.12, 0.055)
		station_node.add_child(plate)
		station_light = Level.glow_material(Color(1.0, 0.55, 0.15), 0.25)
		var button := MeshInstance3D.new()
		var button_mesh := BoxMesh.new()
		button_mesh.size = Vector3(0.06, 0.06, 0.02)
		button.mesh = button_mesh
		button.material_override = station_light
		button.position = Vector3(0, 1.12, 0.075)
		station_node.add_child(button)
		var house := int(extras.get("stationHouse", -1))
		if house >= 0 and house < walk_model.layout.houses.size():
			station_name = house_words(str(walk_model.layout.houses[house].style))
			# The plate faces the room's door it stands behind.
			var fixture: House = walk_model.houses[house]
			var door := fixture.to_world(fixture.room_doors[1])
			var flat := Vector3(door.x, station_node.position.y, door.z)
			if flat.distance_to(station_node.position) > 0.05:
				station_node.look_at(flat, Vector3.UP, true)
	if station_light != null:
		station_light.set_shader_parameter("energy", 1.6 if local_phase == "away" and str(shown_lift.get("phase", "")) == "coming" else 0.25)
	if car_paint == null:
		car_paint = Node3D.new()
		car_paint.name = "CarPaint"
		add_child(car_paint)
		car_paint.position = walk_model.lift_door()
		for side: float in [-1.0, 1.0]:
			var half := MeshInstance3D.new()
			var q := PlaneMesh.new()
			q.size = Vector2(0.62, 2.6)
			half.mesh = q
			var m := StandardMaterial3D.new()
			m.albedo_color = Color("#e8a21c") if side < 0.0 else Color("#b8231c")
			half.material_override = m
			half.position = Vector3(side * 0.33, 0.012, -1.55)
			car_paint.add_child(half)
			var word := Label3D.new()
			word.text = "BANK" if side < 0.0 else "DOWN"
			word.font_size = 64
			word.pixel_size = 0.004
			word.modulate = Color("#2a1a05") if side < 0.0 else Color("#f6efe6")
			word.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
			word.position = Vector3(side * 0.33, 0.02, -1.55)
			car_paint.add_child(word)
	car_paint.visible = true

## The run's lift as client/main.gd last gave it (the block's "lift").
var shown_lift := {}

## WC1: the web as every screen draws it from the host's times: while a catch is carried (caughtAt to hangAt) a wrapped
## bundle at the hand; from hangAt a cocoon hanging from the ceiling at the hang point, swaying slowly; gone once cut.
func _show_web(extras: Dictionary, host_now: float, _id: String, _crew: Array) -> void:
	var rows: Dictionary = extras.get("web", {})
	var points: Array = extras.get("hangPoints", [])
	var carrying := false
	for wid: String in rows:
		var row: Dictionary = rows[wid]
		var k := int(row.point)
		if host_now < float(row.hangAt):
			carrying = true
			continue
		if not cocoons.has(wid) and k < points.size():
			var c := make_cocoon(colors)
			c.name = "Cocoon_%s" % wid
			add_child(c)
			var p: Array = points[k]
			c.position = Vector3(float(p[0]), float(p[1]) + House.HEIGHT - 0.02, float(p[2]))
			cocoons[wid] = c
	for wid: String in cocoons.keys():
		if not rows.has(wid):
			(cocoons[wid] as Node3D).queue_free()
			cocoons.erase(wid)
			continue
		var c: Node3D = cocoons[wid]
		var phase := float(hash(wid) % 628) / 100.0
		c.rotation = Vector3(sin(host_now * 0.55 + phase) * 0.03, host_now * 0.05 + phase, cos(host_now * 0.7 + phase) * 0.035)
	if carrying and hand != null and hand.visible:
		if carried == null:
			carried = make_cocoon(colors, 0.55)
			carried.name = "CarriedBundle"
			add_child(carried)
		carried.visible = true
		carried.position = hand.global_position + Vector3.UP * 0.6
	elif carried != null:
		carried.visible = false

## WC1: the cocoon, built here from nothing: an upside-down wrapped body (the feet bound together at the top, tied to the
## ceiling by a few strands, the head a rounded bulge at the bottom), pale silk with darker wound strands round it. Its
## origin is the tie at the ceiling; it hangs 2.05 m below (scaled by `size`). No flat sprites.
static func make_cocoon(palette: Dictionary, size := 1.0) -> Node3D:
	var root := Node3D.new()
	var silk := StandardMaterial3D.new()
	silk.albedo_color = Color("#d9d3c4")
	silk.roughness = 0.95
	var strand := StandardMaterial3D.new()
	strand.albedo_color = Color("#a59e8c")
	strand.roughness = 1.0
	var length := 2.05 * size
	# The body: a lathe of rings from the tie (top) down to the head (bottom).
	var rings := 18
	var sides := 12
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var profile: Array[Vector2] = []
	for i in rings + 1:
		var f := float(i) / rings
		# Narrow at the bound feet, fuller at the hips and shoulders, a waist at the neck, round at the head.
		var r := 0.06 + 0.25 * sin(PI * clampf(f * 1.05, 0.0, 1.0)) ** 0.7
		if f > 0.72:
			r = lerpf(r, 0.17, smoothstep(0.72, 0.8, f)) * (1.0 - 0.1 * sin(PI * (f - 0.72) / 0.28))
		if f > 0.97:
			r *= (1.0 - f) / 0.03
		profile.append(Vector2(r * size, -length * f))
	for i in rings:
		for j in sides:
			var a0 := TAU * j / sides
			var a1 := TAU * (j + 1) / sides
			var p00 := Vector3(cos(a0) * profile[i].x, profile[i].y, sin(a0) * profile[i].x)
			var p01 := Vector3(cos(a1) * profile[i].x, profile[i].y, sin(a1) * profile[i].x)
			var p10 := Vector3(cos(a0) * profile[i + 1].x, profile[i + 1].y, sin(a0) * profile[i + 1].x)
			var p11 := Vector3(cos(a1) * profile[i + 1].x, profile[i + 1].y, sin(a1) * profile[i + 1].x)
			for v: Vector3 in [p00, p10, p01, p01, p10, p11]:
				st.set_normal(Vector3(v.x, 0.0, v.z).normalized() if Vector2(v.x, v.z).length() > 0.001 else Vector3.DOWN)
				st.add_vertex(v)
	var body := MeshInstance3D.new()
	body.name = "Wrap"
	body.mesh = st.commit()
	body.material_override = silk
	root.add_child(body)
	# Wound strands: thin tori round the body at a slant, and a few lines up to the ceiling.
	for k in 7:
		var f := 0.12 + 0.11 * k
		var i := clampi(int(f * rings), 0, rings)
		var band := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = profile[i].x + 0.004
		torus.outer_radius = profile[i].x + 0.02 * size
		torus.rings = 12
		torus.ring_segments = 4
		band.mesh = torus
		band.material_override = strand
		band.position = Vector3(0.0, profile[i].y, 0.0)
		band.rotation = Vector3(0.35 * (1.0 if k % 2 == 0 else -1.0), float(k) * 0.9, 0.2)
		root.add_child(band)
	for k in 3:
		var line := MeshInstance3D.new()
		var stick := CylinderMesh.new()
		stick.top_radius = 0.006
		stick.bottom_radius = 0.006
		stick.height = 0.3 * size
		line.mesh = stick
		line.material_override = strand
		var a := TAU * k / 3.0
		line.position = Vector3(cos(a) * 0.04, -0.12 * size, sin(a) * 0.04)
		line.rotation = Vector3(sin(a) * 0.25, 0.0, cos(a) * 0.25)
		root.add_child(line)
	return root

## WC1: "HOLD F  CUT DOWN" under a hung crewmate (sim/ward/state.gd CUT_REACH, a little inside it), with the cut's
## progress from the host's cut times on the HUD's bar.
func _cut_prompt(extras: Dictionary, host_now: float, id: String) -> String:
	var rows: Dictionary = extras.get("web", {})
	if rows.is_empty() or caught:
		return ""
	var going: Variant = (extras.get("cuts", {}) as Dictionary).get(id)
	if going is Dictionary:
		cut_fill = clampf((host_now - float(going.from)) / maxf(0.01, float(going.done) - float(going.from)), 0.0, 1.0)
		return "CUTTING THEM DOWN. KEEP HOLDING F"
	var points: Array = extras.get("hangPoints", [])
	var feet := player.position
	for wid: String in rows:
		var row: Dictionary = rows[wid]
		if wid == id or host_now < float(row.hangAt) or int(row.point) >= points.size():
			continue
		var p: Array = points[int(row.point)]
		if Vector2(feet.x - float(p[0]), feet.z - float(p[2])).length() <= Ward.CUT_REACH - 0.05 and absf(feet.y - float(p[1])) <= Ward.CUT_RISE:
			cut_fill = 0.0
			return "HOLD F  CUT %s DOWN" % str(names.get(wid, "THEM")).to_upper()
	return ""

## WL1: the house doors swing to where the host says, and the lift's doors slide, as on every floor.
func _process(delta: float) -> void:
	for i in door_hinges.size():
		door_hinges[i].rotation.y = move_toward(door_hinges[i].rotation.y, _door_swing[i], delta * Dress.DOOR_SPEED)
	if lift_car != null:
		lift_car.update(delta)

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
	watch_camera.current = own_camera
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

## RW1: what the screen shows of the Rigger (the test channel's `state`, client/main.gd; tools/rigger_views.gd): the
## host's encounter and house as last shown, whether he is drawn, where (his place, head and wrist; the search hand),
## the clip and its time, and whether his helmet lamp is lit.
func describe_rigger() -> Dictionary:
	var out := {"encounter": str(shown_ward.get("encounter", "")), "house": int(shown_ward.get("house", -1)),
		"phase": str(shown_ward.get("phase", "")), "startedAt": float(shown_ward.get("startedAt", -1.0)),
		"drawn": rigger != null and rigger.visible, "figure": rigger.scene_file_path if rigger != null else "",
		"at": [], "head": [], "wrist": [], "hand": [], "handDrawn": hand != null and hand.visible,
		"clip": "", "clipTime": 0.0, "lamp": lamp_light != null and lamp_light.is_visible_in_tree()}
	if rigger == null:
		return out
	out.at = _plain(rigger.global_position)
	out.wrist = _plain(rigger.global_transform * rigger_wrist)
	out.head = _plain(rigger_head())
	if hand != null:
		out.hand = _plain(hand.global_position)
	if animation != null and animation.assigned_animation != &"":
		out.clip = str(animation.assigned_animation)
		out.clipTime = animation.current_animation_position
	return out

static func _plain(p: Vector3) -> Array:
	return [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)]

## The figure's head (its skeleton's head bone, posed), or a metre above his place without one.
func rigger_head() -> Vector3:
	var found := rigger.find_children("*", "Skeleton3D", true, false)
	if not found.is_empty():
		var skeleton := found[0] as Skeleton3D
		var bone := skeleton.find_bone("head")
		if bone >= 0:
			return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
	return rigger.global_position + Vector3.UP

## RW1: where a player stands in a house for the test channel's `wardhouse` (client/main.gd), feet in world space:
## "corner" the entry corner away from the first room door (where sim/ward/bots.gd's careful recorder hides), or one of
## the house's own rooms ("entry", "middle", "rear": the probe points the hand searches, at floor level).
static func house_spot(fixture: House, spot: String) -> Vector3:
	if spot == "corner":
		var half := fixture.floor_bounds.size.x * 0.5
		var side := -signf(fixture.room_doors[0].x) if fixture.room_doors[0].x != 0.0 else 1.0
		return fixture.to_world(Vector3(side * (half - 0.42), 0, 0.5))
	if not fixture.areas.has(StringName(spot)):
		return Vector3.INF
	var at: Vector3 = fixture.areas[StringName(spot)]
	return fixture.to_world(Vector3(at.x, 0, at.z))

## The Ward block last shown (show_host), for describe_rigger.
var shown_ward := {}

func _show_rigger(ward: Dictionary, host_now: float) -> void:
	shown_ward = ward
	if ward.has("rigger"):
		_show_roaming(ward, host_now)
		return
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
	rigger.position -= rigger.basis * rigger_wrist
	if animation != null and hold_animation != &"" and ward.encounter == "searching":
		# RW1: hanging outside while the arm searches; the clip loops on its own.
		if animation.assigned_animation != hold_animation or not animation.is_playing():
			animation.play(hold_animation)
			animation.advance(0.0)  # posed this frame, not the next
	elif animation != null and climb_animation != &"":
		animation.play(climb_animation)
		animation.pause()
		animation.seek(fmod(progress * Ward.CLIMB_SECONDS, 1.75), true)
	var packed := PackedVector3Array()
	if figures_new and hold_animation != &"" and ward.encounter == "climbing" and not (ward.armPoints as Array).is_empty():
		# RW1: on the line, the host's limb (his grip above, sim/ward/state.gd posed_limb) is drawn on from the
		# figure's own wrist, so his arm runs up to the hand on the line instead of stopping short at the wrist.
		packed.append(fixture.to_local(rigger.position + rigger.basis * rigger_wrist))
	for raw: Array in ward.armPoints:
		packed.append(fixture.to_local(Vector3(raw[0], raw[1], raw[2])))
	_draw_arm(fixture, packed)

## RR1: the crawling Rigger (the run flag rigger_roam): drawn exactly at the host's pose (the snapshot's, blended by the
## client as every resident is: net/client.gd rigger_drawn), the figure's own frame being the graph's (sim/ward/
## rigger_graph.gd: abdomen at the origin, back up, torso forward). He holds still in "hang" while he searches, stays or
## rears; "reach" (the arm drawn up) is his rearing before a grab; "climb" while he crawls. His paid-out arm runs from the
## figure's wrist to the host's arm. The lamp lives on the figure and is lit only while he is out of his lair (drawn).
## The lines and walkways he weighs on strain for a moment (play_event "ward_weight").
func _show_roaming(ward: Dictionary, host_now: float) -> void:
	var r: Dictionary = ward.rigger
	_show_weights(host_now)
	var out := bool(r.get("out", false))
	rigger.visible = out
	walk_model_rigger(r)
	if rim_light != null:
		rim_light.visible = out
	if feet != null:
		if not out or not feet.active:
			feet.call("reset")
		feet.active = out
		feet.set("now", host_now)
	if not out:
		ribbon.clear_surfaces()
		previous_arm.clear()
		hand.hide()
		return
	var at := Vector3(r.at[0], r.at[1], r.at[2])
	var q := Quaternion(r.rot[0], r.rot[1], r.rot[2], r.rot[3]).normalized()
	rigger.global_transform = Transform3D(Basis(q), at)
	var encounter := str(ward.encounter)
	if animation != null and hold_animation != &"":
		var want: StringName = &"climb"
		if encounter in ["searching", "lingering", "warning"]:
			want = hold_animation
		elif encounter == "rearing" and animation.has_animation(&"reach"):
			want = &"reach"
		if animation.has_animation(want) and (animation.assigned_animation != want or not animation.is_playing()):
			animation.play(want)
			animation.advance(0.0)
	var points: Array = ward.armPoints
	var fixture: House = houses[int(ward.house)].fixture if int(ward.house) >= 0 else houses[0].fixture
	var packed := PackedVector3Array()
	if points.size() > 1 and encounter == "searching":
		# From his own wrist to the host's arm at the opening (the reach pose puts the wrist on it, or within 1 m).
		packed.append(fixture.to_local(rigger.global_transform * rigger_wrist))
	if points.size() > 1:
		for raw: Array in points:
			packed.append(fixture.to_local(Vector3(raw[0], raw[1], raw[2])))
	_draw_arm(fixture, packed)

## The walk model on this screen keeps his body solid where the host has him (sim/ward/roam.gd blocks).
func walk_model_rigger(r: Dictionary) -> void:
	if walk_model.roam == null:
		walk_model.enable_roam(true)
	walk_model.roam.at = Vector3(r.at[0], r.at[1], r.at[2])
	walk_model.roam.turn = Quaternion(r.rot[0], r.rot[1], r.rot[2], r.rot[3]).normalized()
	walk_model.roam.trip = &"" if not bool(r.get("out", false)) else &"shown"

## RR1: his weight on a house's line or a walkway, for WEIGHT_SHOW seconds: the house's loaded support and take-up
## levers swing (as today's climb), a walkway's ropes and deck dip; a player standing on that walkway feels a brief tug.
const WEIGHT_SHOW := 1.6
var _weights: Array = []
## Host time of the last tug this player felt (the main game may nudge its camera from it).
var tug_at := -INF

func _show_weights(host_now: float) -> void:
	var keep: Array = []
	for w: Dictionary in _weights:
		var k := (host_now - float(w.at)) / WEIGHT_SHOW
		var pull := 0.0 if k < 0.0 or k > 1.0 else 0.2 * sin(k * TAU * 2.0) * (1.0 - k)
		if int(w.house) >= 0 and int(w.house) < houses.size():
			_set_house_load(houses[int(w.house)], pull)
		if w.node != null and is_instance_valid(w.node):
			(w.node as Node3D).position.y = -absf(pull) * 0.3
		if k <= 1.0:
			keep.append(w)
	_weights = keep

func _weight_event(event: Dictionary) -> void:
	var at := Vector3(float(event.get("x", 0.0)), float(event.get("y", 0.0)), float(event.get("z", 0.0)))
	load_sound.global_position = at
	load_sound.play()
	var row := {"at": float(event.get("at", event.get("t", 0.0))), "house": -1, "node": null}
	if str(event.get("surface", "")) == "walkway":
		var b := int(event.get("bridge", -1))
		row.node = _walkway_node(b)
		if _on_bridge(b):
			tug_at = row.at
	else:
		row.house = int(event.get("house", -1))
	_weights.append(row)

## The drawn walkway (or the bridge) of layout bridge `b`.
func _walkway_node(b: int) -> Node3D:
	var fixed := 0
	for i: int in walk_model.layout.bridges.size():
		var winch: bool = walk_model.layout.bridges[i].kind == "winch"
		if i == b:
			return bridge if winch else (walkways[fixed] if fixed < walkways.size() else null)
		if not winch:
			fixed += 1
	return null

## Whether this screen's player stands on layout bridge `b`.
func _on_bridge(b: int) -> bool:
	if b < 0 or b >= walk_model.layout.bridges.size():
		return false
	var path: Array = walk_model.layout.bridges[b].path
	var feet := player.position
	for i in range(1, path.size()):
		var from := Footing.path_point(path[i - 1])
		var to := Footing.path_point(path[i])
		var near := Geometry3D.get_closest_point_to_segment(feet, from, to)
		if near.distance_to(feet) <= Footing.DECK_WIDTH:
			return true
	return false

func _show_crew(crew: Array, my_id: String) -> void:
	for ghost: MeshInstance3D in peers.values():
		ghost.hide()
	if not capsules:
		return
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
	# RR1: his weight where it is (the crawling Rigger's cues carry their place).
	if event.type == "ward_weight" or event.type == "ward_rear" or (event.type == "ward_line_loaded" and event.has("x")):
		_weight_event(event)
		return
	if event.type == "ward_line_loaded":
		var house: Dictionary = houses[int(event.house)]
		var support: Node3D = house.lines[(house.fixture as House).loaded_support_index()]
		load_sound.global_position = support.global_position
		load_sound.play()
		return
	if event.type == "ward_hung" or event.type == "ward_cut":
		# WC1: the lines creak as the cocoon is hung, and as it is cut (the loaded line's own take, on its own player).
		var creak := AudioStreamPlayer3D.new()
		creak.stream = load_sound.stream
		creak.unit_size = load_sound.unit_size
		creak.max_distance = load_sound.max_distance
		add_child(creak)
		creak.global_position = Vector3(float(event.get("x", 0.0)), float(event.get("y", 0.0)) + 2.0, float(event.get("z", 0.0)))
		creak.finished.connect(creak.queue_free)
		creak.play()
		if say.is_valid():
			say.call("ward_hung" if event.type == "ward_hung" else "ward_cut")
		return
	var cues := {"ward_departed":"ward_lift_departed", "ward_last_minute":"ward_lift_last_minute",
		"ward_returned":"ward_lift_returned", "ward_final_call":"ward_lift_final_call", "ward_closed":"ward_lift_closed"}
	var cue := str(cues.get(event.type, ""))
	if cue.is_empty():
		return
	if say.is_valid():
		say.call(cue)
		return
	var path := "res://assets/ward/voice/bella/%s.mp3" % cue
	if ResourceLoader.exists(path):
		cue_player.stream = load(path)
		cue_player.play()
func _setup_world() -> void:
	for key: String in ["plaster", "brick", "wood", "rope", "iron", "light", "glass", "arm", "arm_v2"]:
		var material := StandardMaterial3D.new()
		var shades := {"plaster":"#978377", "brick":"#553f37", "wood":"#735341", "rope":"#9d806a",
			"iron":"#33383a", "light":"#ffd09a", "glass":"#456575", "arm":"#81665c", "arm_v2":ARM_COLOR_V2}
		material.albedo_color = Color(shades[key])
		if key == "glass":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.albedo_color.a = 0.18
		if key == "light":
			material.emission_enabled = true
			material.emission = Color(shades[key])
		colors[key] = material
	# AW1: every other surface is a CC0 photograph at one world scale (client/ward/skin.gd): the houses' walls, slabs and
	# partitions one material ("house"), planks, rope, iron, the doors' wood, slates, the cavern's rock.
	WardSkin.materials(colors)
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
	# AW1: under the decks the air thickens into a haze the lamps light a little (the mist, WardSkin.depths).
	env.fog_height = FOG_HEIGHT
	env.fog_height_density = FOG_HEIGHT_DENSITY
	world.environment = env
	environment = env
	if own_environment:
		add_child(world)
	else:
		world.free()

func _box(parent: Node3D, at: Vector3, dims: Vector3, color: String, solid := false) -> Node3D:
	var anchor: Node3D = StaticBody3D.new() if solid else Node3D.new()
	parent.add_child(anchor)
	anchor.position = at
	var picture := MeshInstance3D.new()
	if color == "house":
		# AW1: a house's wall, slab or partition: brick outside, the room's plaster inside (client/ward/skin.gd).
		picture.mesh = WardSkin.house_box(parent, at, dims)
	else:
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
	# WG1: the house's own facing (today's: the parlour -PI/2, the rest 0).
	root.rotation.y = fixture.yaw()
	# AW1: what the house's own boxes need to know to draw their faces (client/ward/skin.gd house_box).
	root.set_meta(&"ward_house", WardSkin.house_info(fixture, site, seed_value))
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
	if fixture.homes():
		# WH1: a home (the run flag ward_homes): its walls, rooms, stairs and plain box furniture (dressing is stage 2).
		_build_home(root, site, fixture)
	else:
		for wall: AABB in fixture.walls:
			var outside := wall.size.y > 2.9 and wall.size.z >= bounds.size.y - 0.01 and wall.size.x < 0.2
			if outside and site.id == 0 and wall.position.x < bounds.position.x:
				_lift_wall(root, wall)
			elif outside:
				_window_wall(root, wall, fixture.search_window.has_volume() and is_equal_approx(wall.position.x, fixture.search_window.position.x))
			else:
				# AW1: one material for every wall and slab: each face brick or the room's plaster (client/ward/skin.gd).
				_box(root, wall.get_center(), wall.size, "house", true)
		_dress_house(root, site, fixture)
		WardSkin.dress_house(self, root, site, fixture, seed_value)
	var door := fixture.door
	var leaf := _box(root, door.get_center(), door.size, "wood", true) as StaticBody3D
	door_houses.append(leaf)
	_set_solid(leaf, false)
	# WL1: the shut door's body stays for sight lines only; the door seen is the leaf on its hinge (client/ward/dress.gd).
	(leaf.get_child(0) as Node3D).visible = false
	door_hinges.append(Dress.door_leaf(self, root, door))
	_door_swing.append(Dress.DOOR_SWING)
	door_hinges[-1].rotation.y = Dress.DOOR_SWING
	if not fixture.homes():
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
				# WL1: up to the cavern's roof, where each line is fixed.
				lines.append(_beam(deck, edge - Vector3.UP * 18.0, Vector3(edge.x, roof_y - deck.position.y, edge.z), 0.07, 0.07, "rope"))
	var support := lines[fixture.loaded_support_index()]
	var ties: Array[Node3D] = []
	if not fixture.homes():
		ties = _interior_ties(root, fixture, root.to_local(support.global_position), int(site.id) == 0)
	houses.append({"fixture": fixture, "lines": lines, "support": support, "root": root, "ties": ties, "deck": deck})

## The suspension shoe feeds a tie through the frame of each storey to the rear wall.
## The weighted take-up lever swings on its iron pin when the line bears weight.
func _interior_ties(root: Node3D, fixture: House, shoe: Vector3, lift_house := false) -> Array[Node3D]:
	var ties: Array[Node3D] = []
	var rear: Vector3 = fixture.areas[&"rear"]
	for floor: House.Storey in fixture.storeys:
		# FX2: in the lift's house the tie runs under the ceiling, over the lift's doorway (it crossed it at head height).
		var height := float(floor.height) + (Dress.LIFT_HOUSE_TIE if lift_house else 2.12)
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


## WH1: a home drawn plainly from its rules (sim/ward/house.gd with the run flag ward_homes): every wall, slab and
## partition with its windows cut, the lift's wall as today's, the stairs, a lintel and posts at each inner doorway,
## each piece of furniture a plain box where the rules have it, one lamp in every room, and a roof. Stage 2 dresses it.
func _build_home(root: Node3D, site: Dictionary, fixture: House) -> void:
	var bounds := fixture.floor_bounds
	var holes: Array[AABB] = []
	for o: Dictionary in fixture.openings():
		if (o.hole as AABB).has_volume():
			holes.append(o.hole)
	var boxes: Array[AABB] = fixture.walls.duplicate()
	boxes.append_array(fixture.upper_envelope)
	for storey: House.Storey in fixture.storeys:
		boxes.append_array(storey.slab)
		boxes.append_array(storey.partitions)
	for box: AABB in boxes:
		var outside := box.size.y > 2.9 and box.size.z >= bounds.size.y - 0.01 and box.size.x < 0.2 and box.position.y < 0.01
		if outside and int(site.id) == 0 and box.position.x < bounds.position.x:
			_lift_wall(root, box)
			continue
		var pieces: Array[AABB] = [box]
		for hole in holes:
			var next: Array[AABB] = []
			for piece in pieces:
				next.append_array(House._subtract(piece, hole))
			pieces = next
		for piece in pieces:
			if piece.size.x > 0.001 and piece.size.y > 0.001 and piece.size.z > 0.001:
				_box(root, piece.get_center(), piece.size, "house", true)
	for hole in holes:
		var frame := hole.grow(0.02)
		_box(root, Vector3(frame.get_center().x, frame.position.y, frame.get_center().z), Vector3(frame.size.x, 0.06, frame.size.z), "wood")
	for stair: House.Stair in fixture.stairs:
		_dress_home_stair(root, stair)
	for door: Dictionary in fixture.inner_doors:
		var leaf: AABB = door.leaf
		var along_x := leaf.size.x > leaf.size.z
		for end: float in [0.0, 1.0]:
			var post := leaf.get_center()
			if along_x:
				post.x = lerpf(leaf.position.x, leaf.end.x, end)
			else:
				post.z = lerpf(leaf.position.z, leaf.end.z, end)
			post.y = leaf.position.y + House.OPENING_HEIGHT * 0.5
			_box(root, post, Vector3(0.08 if along_x else 0.18, House.OPENING_HEIGHT, 0.18 if along_x else 0.08), "wood")
	# WH1c: each inner door's leaf, drawn (and solid) while the rules have it shut (_show_inner_doors).
	for k in fixture.inner_doors.size():
		var leaf_box: AABB = fixture.inner_doors[k].leaf
		var leaf := _box(root, leaf_box.get_center(), leaf_box.size, "wood", true) as StaticBody3D
		_set_solid(leaf, false)
		inner_leaves.append({"house": houses.size(), "door": k, "node": leaf})
	for piece: Dictionary in fixture.furniture:
		var box: AABB = piece.box
		var color := "iron" if [&"range", &"copper", &"stove", &"mangle"].has(piece.kind) else ("plaster" if [&"bath", &"sink", &"toilet"].has(piece.kind) else "wood")
		_box(root, box.get_center(), box.size, color, true)
	for level in fixture.rooms_by_level.size():
		var probes: Dictionary = fixture.areas if level == 0 else fixture.upper_areas(level)
		for room: StringName in probes:
			var at: Vector3 = probes[room]
			_lamp(root, Vector3(at.x, float(level) * House.HEIGHT + 2.45, at.z))
	var roof_y := House.HEIGHT * float(fixture.rooms_by_level.size())
	_box(root, Vector3(0, roof_y, bounds.get_center().y), Vector3(bounds.size.x + 0.4, 0.18, bounds.size.y + 0.48), "iron")

## WH1c: the homes' inner door leaves ({house, door, node}); shown where the walk model has them shut.
var inner_leaves: Array[Dictionary] = []

func _show_inner_doors() -> void:
	for row: Dictionary in inner_leaves:
		var shut := walk_model.houses[int(row.house)].inner_open[int(row.door)] == 0
		if (row.node as Node3D).visible != shut:
			_set_solid(row.node, shut)

## WH1: a home's stair, along x or along z (a home's may run front to back).
func _dress_home_stair(root: Node3D, stair: House.Stair) -> void:
	const TREADS := 18
	var along_z := stair.from.x == stair.to.x
	var run_length := absf(stair.to.z - stair.from.z) if along_z else absf(stair.to.x - stair.from.x)
	for tread in TREADS:
		var where := stair.from.lerp(stair.to, (float(tread) + 0.5) / TREADS)
		var size := Vector3(House.STAIR_WIDTH, 0.13, run_length / TREADS + 0.008) if along_z else Vector3(run_length / TREADS + 0.008, 0.13, House.STAIR_WIDTH)
		_box(root, where - Vector3.UP * 0.065, size, "wood")

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
			Vector3(wall.size.x, wall.size.y, side_width), "house", true)
	var lintel := _box(root, Vector3(middle.x, 2.615, middle.z), Vector3(wall.size.x, 0.87, 1.24), "house", true)
	# FX2: the body stays for sight lines; the brick seen starts over the car's doors, not across them.
	(lintel.get_child(0) as Node3D).visible = false
	Dress.lift_lintel(self, root, wall)

func _window_wall(root: Node3D, wall: AABB, open_sash := false) -> void:
	var pane := Vector3(wall.size.x, 1.25, 1.42)
	var center := wall.get_center()
	var sill := 0.82
	var top := sill + pane.y
	_box(root, Vector3(center.x, sill * 0.5, center.z), Vector3(wall.size.x, sill, wall.size.z), "house", true)
	_box(root, Vector3(center.x, (top + wall.end.y) * 0.5, center.z), Vector3(wall.size.x, wall.end.y - top, wall.size.z), "house", true)
	var side_width := (wall.size.z - pane.z) * 0.5
	for side: float in [-1.0, 1.0]:
		_box(root, Vector3(center.x, sill + pane.y * 0.5, center.z + side * (side_width + pane.z) * 0.5),
			Vector3(wall.size.x, pane.y, side_width), "house", true)
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
				Vector3(width, House.HEIGHT, 0.15), "house")
			_box(root, Vector3(side * width * 0.5, base + 1.27, center.y),
				Vector3(0.04, 0.94, 1.1), "light")
	for storey: House.Storey in fixture.storeys:
		for slab: AABB in storey.slab:
			_box(root, slab.get_center(), slab.size, "house", true)
		for jamb: AABB in storey.partitions:
			_box(root, jamb.get_center(), jamb.size, "house", true)
		if storey.incoming != null:
			_dress_stairs(root, storey.incoming)
		if storey.height > 0 and storey.height < House.HEIGHT * floors:
			_lamp(root, Vector3(-width * 0.30, storey.height + 2.37, depth * 0.28))
			_lamp(root, Vector3(width * 0.30, storey.height + 2.37, depth * 0.75))
	var roof_y := House.HEIGHT * floors
	_box(root, Vector3(0, roof_y, center.y), Vector3(width + 0.4, 0.18, depth + 0.48), "iron")
	for side: float in [-1.0, 1.0]:
		var roof := _box(root, Vector3(side * width * 0.26, roof_y + 0.24, center.y),
			Vector3(width * 0.56, 0.13, depth + 0.5), "slate")
		roof.rotation.z = -side * deg_to_rad(11.0 if floors == 1 else 7.0)
		# FX2: the skirting along the lift's wall leaves the car's doorway clear (it lay across it as a kerb).
		Dress.skirting(self, root, Vector3(side * (width * 0.5 - 0.035), 0.125, center.y), depth,
			Dress.LIFT_GAP if int(site.id) == 0 and side < 0.0 else 0.0)
	_box(root, Vector3(-width * 0.28, roof_y + 0.61, center.y - 0.61), Vector3(0.35, 0.88, 0.39), "house")
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
	# WL1: stringers, threshold plates, posts and hangers (client/ward/dress.gd), in a node of their own: the bridge's
	# root holds only its solid parts (_set_bridge).
	var dressing := Node3D.new()
	dressing.name = "WalkwayDress"
	add_child(dressing)
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
			for rail: Array in [[0.9, 0.07, 0.07], [0.52, 0.07, 0.08]]:
				var a := rail_from + side * flip + Vector3.UP * float(rail[0])
				var b := rail_to + side * flip + Vector3.UP * float(rail[0])
				var body := _beam(root, a, b, float(rail[1]), float(rail[2]), "rope", true)
				# AW1: the rail's body stays as it was; the rail seen is a thin rope on the same line (Dress.RAIL_ROPE).
				(body.get_child(0) as Node3D).visible = false
				# On a fixed walkway it dips with the deck under his weight; the drawbridge's root holds bodies only.
				_beam(dressing if edge.kind == "winch" else root, a, b, Dress.RAIL_ROPE, Dress.RAIL_ROPE, "rope").add_to_group(WardSkin.GROUP)
	Dress.walkway(self, dressing, path, roof_y)
	if edge.kind == "winch":
		bridge = root
		bridge_dress = dressing
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
	if bridge_dress != null:
		bridge_dress.visible = lowered
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
	# WL1: the car seen is the game's own (client/lift.gd, built by client/ward/dress.gd); these walls, roof and gate
	# stay as bodies for sight lines, unseen.
	var shell: Array[Node3D] = [_box(box, Vector3(0, 2.26, -LIFT_DEPTH * 0.5), Vector3(1.35, 0.12, LIFT_DEPTH), "iron", true)]
	for side: float in [-1.0, 1.0]:
		shell.append(_box(box, Vector3(side * 0.72, 1.1, -LIFT_DEPTH * 0.5), Vector3(0.11, 2.20, LIFT_DEPTH), "iron", true))
	shell.append(_box(box, Vector3(0, 1.1, -LIFT_DEPTH), Vector3(1.55, 2.2, 0.12), "iron", true))
	lift_gate = _box(box, Vector3(0, 1.09, 0), Vector3(1.24, 2.18, 0.08), "iron", true)
	_set_solid(lift_gate, false)
	shell.append(lift_gate)
	for part: Node3D in shell:
		(part.get_child(0) as Node3D).visible = false
	lift_car = Dress.build_lift(self, walk_model.lift_door(), roof_y)
	# AW1: the timber-and-iron shaft the car runs in, from far below up to its head frame under the roof.
	WardSkin.lift_shaft(self, lift_car, roof_y)

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
	camera.fov = Main.VFOV
	camera.current = own_camera
	watch_camera.fov = Main.VFOV
	player.rotation.y = PI
	add_child(watch_camera)
func _build_rigger() -> void:
	var path := RIGGER_PATH
	if figures_new and ResourceLoader.exists(RIGGER_V2_PATH):
		path = RIGGER_V2_PATH
		rigger_wrist = RIGGER_WRIST_V2
	rigger = (load(path) as PackedScene).instantiate()
	add_child(rigger)
	rigger.hide()
	var players := rigger.find_children("*", "AnimationPlayer")
	if not players.is_empty():
		animation = players[0] as AnimationPlayer
		for key: StringName in animation.get_animation_list():
			if key != &"RESET":
				climb_animation = key
				break
		# The v2 figure has more clips; the view plays the one with today's name.
		if path == RIGGER_V2_PATH and animation.has_animation(&"Rigger Climb"):
			climb_animation = &"Rigger Climb"
		if path == RIGGER_V2_PATH:
			set_v2_loops(animation)
			if animation.has_animation(HOLD_CLIP):
				hold_animation = HOLD_CLIP
	if path == RIGGER_V2_PATH:
		arm_radii = ARM_RADII_V2
		arm_material = "arm_v2"
	# RR1 stage 2: his feet on the surfaces he crawls (client/ward/rigger_feet.gd), only while the crawling Rigger is
	# drawn (_show_roaming turns it on).
	var skeletons := rigger.find_children("*", "Skeleton3D", true, false)
	if path == RIGGER_V2_PATH and not skeletons.is_empty():
		feet = (load("res://client/ward/rigger_feet.gd") as GDScript).new()
		feet.name = "RiggerFeet"
		feet.active = false
		(skeletons[0] as Skeleton3D).add_child(feet)
		feet.setup(skeletons[0] as Skeleton3D, Graph.solids_only(walk_model.layout, walk_model.houses, walk_model.lift_door()))
	var lamp := rigger.find_child("Lamp", true, false) as Node3D
	if path == RIGGER_V2_PATH and lamp != null:
		lamp_light = OmniLight3D.new()
		lamp_light.light_color = Color("#ffc98a")
		lamp_light.light_energy = LAMP_ENERGY
		lamp_light.omni_range = LAMP_RANGE
		lamp_light.shadow_enabled = false
		lamp.add_child(lamp_light)
		# RR1 stage 2: a weak, cold light under his belly (between him and the wall or deck he holds: what the house's
		# own windows throw on him), so his shape reads from inside a house against the dark outside the glass. It
		# belongs to the drawn figure, so like the lamp it exists only while he is drawn, and is lit only for the
		# crawling Rigger (_show_roaming).
		rim_light = OmniLight3D.new()
		rim_light.light_color = Color(RIM_COLOR)
		rim_light.light_energy = RIM_ENERGY
		rim_light.omni_range = RIM_RANGE
		rim_light.shadow_enabled = false
		rim_light.position = Vector3(0.0, RIM_UNDER, 1.0)
		rim_light.visible = false
		rigger.add_child(rim_light)
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
	canvas.visible = own_hud
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
	if DisplayServer.get_name() != "headless" and own_hud:
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
		turn(event.relative)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## A mouse movement on the player's own facing, as in the main game (client/main.gd SENS, MAX_PITCH).
func turn(relative: Vector2) -> void:
	player.rotate_y(-relative.x * Main.SENS)
	camera.rotation.x = clampf(camera.rotation.x - relative.y * Main.SENS, -Main.MAX_PITCH, Main.MAX_PITCH)

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

## Correct a predicted step when a newer door or deck state disagrees with the host. WN4: with the input numbers
## (`sent_seq` the newest sent, `ack_seq` the newest the host had taken, client/ward/net_walk.gd), also when the
## host refused a step: back to where the host has the player.
func reconcile(body: Move.Body, sent_seq := -1, ack_seq := -1, placed := false) -> void:
	var accepted := Vector3(body.x, body.y, body.z)
	var predicted := player.position
	if sent_seq >= 0 and net_walk.refused(predicted, accepted, sent_seq, ack_seq, placed) != null:
		player.position = accepted
		return
	if not walk_model.walk_clear(accepted, accepted):
		return
	if not walk_model.walk_clear(predicted, predicted) or (accepted.distance_to(predicted) > 0.24 and not walk_model.walk_clear(accepted, predicted)):
		player.position = accepted

func _move(motion: Vector3, delta: float) -> void:
	player.position = NetWalk.step(walk_model, player.position, Vector2(motion.x, motion.z) * delta)

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
	elif figures_new and not final.is_zero_approx():
		# RW1: straight up the line (his grip while he climbs): the palm faces the house, not a stale way.
		hand.look_at(hand.position + final, rigger.basis.z, true)
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
			ring.append(points[i] + lerpf(arm_radii.x, arm_radii.y, float(i) / (points.size() - 1)) * (side * cos(angle) + up * sin(angle)))
		rings.append(ring)
	ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLES, colors[arm_material])
	for i in range(points.size() - 1):
		for j in SIDES:
			var k := (j + 1) % SIDES
			for vertex: Vector2i in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i, k), Vector2i(i, k), Vector2i(i + 1, j), Vector2i(i + 1, k)]:
				var surface_point := rings[vertex.x][vertex.y]
				ribbon.surface_set_normal((surface_point - points[vertex.x]).normalized())
				ribbon.surface_add_vertex(surface_point)
	ribbon.surface_end()
