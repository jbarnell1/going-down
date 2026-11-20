# WN1: the Hanging Ward as a normal level. With the run flag `ward_place` on (net/host_rules.gd), the host marks the
# Ward's snapshot block `native` and the main scene (client/main.gd) never steps aside: it keeps its own player,
# camera, tape picture, HUD, Esc card, instrument, F6 and F8, name tags and crew figures, and hosts this node as the
# floor's level view in its world, where it would otherwise show the floor plan's level and lift.
#
# What this node does for the main scene:
#   - draws the Ward's world (client/ward/view.gd, unchanged: houses, walkways, the drawbridge, the lift gate, the
#     Rigger and his arm, the Ward's lamps and look) from the snapshot's block, every frame;
#   - walks the main game's player through the Ward's own walk model (sim/ward/state.gd walk, the same footing and
#     clearance the host checks every input against), in place of the floor plan's (client/play_link.gd `walker`);
#   - gives the main HUD the Ward's lines: the lift's clock (LIFT RETURNS IN m:ss, DOORS CLOSE IN n, as the design
#     names them) and the prompt (STEP OUT OF THE LIFT, the winch, the doors, being caught and watching);
#   - the line of sight for name tags (the Ward's walls), and a caught player's watching camera.
# Without the Ward's media pack the walk and the lines still work; only the pictures are missing (the main scene
# says which file to put beside the game).
extends Node3D

const View = preload("res://client/ward/view.gd")
const Ward = preload("res://sim/ward/state.gd")
const Move = preload("res://sim/move.gd")

var seed_value := 0
## The Ward's world on screen, or null without the media pack.
var view: View = null
## The walk model the player is moved through: the view's own (kept in step by show_host), or one of this node's.
var model: Ward
var phase := ""
var clock_line := ""
var clock_warn := false
var prompt_line := ""
var _event_index := 0

func setup(seed_: int, media: bool, events_seen: int) -> void:
	seed_value = seed_
	_event_index = events_seen
	if media:
		view = View.new(seed_, Vector3.ZERO)
		view.own_hud = false
		view.capsules = false
		view.own_camera = false
		view.own_environment = false
		view.name = "WardView"
		add_child(view)
		model = view.walk_model
	else:
		model = Ward.new(seed_)

## One step of the main game's own player, through the Ward's footing and walls: the body after moving (dx, dz).
func walk(body: Move.Body, dx: float, dz: float) -> Move.Body:
	var to := model.walk(Vector3(body.x, body.y, body.z), Vector2(dx, dz))
	return Move.Body.make(to.x, to.z, body.level, to.y)

## Whether a point is in view from `from` past the Ward's walls (name tags).
func sees(from: Vector3, at: Vector3) -> bool:
	if view == null:
		return true
	var space := view.get_world_3d().direct_space_state
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(from, at)).is_empty()

## Per frame, from the newest snapshot: the Ward block, host time now, this player's id and feet, the snapshot's
## players (for the watch and the gate), the client's events (the Ward's cues).
func update(ward: Dictionary, host_now: float, my_id: String, feet: Vector3, players: Array, events: Array, names: Dictionary) -> void:
	phase = str(ward.get("phase", ""))
	if view != null:
		view.player.position = feet
		view.names = names
		view.show_host(ward, host_now, my_id, players)
		while _event_index < events.size():
			view.play_event(events[_event_index])
			_event_index += 1
		clock_line = view.hud.text
		prompt_line = view.prompt.text
	else:
		_sync(ward)
		clock_line = lift_line(ward, host_now, my_id)
		prompt_line = ""
	clock_warn = phase == "boarding" or (phase == "away" and float(ward.get("collectionAt", -1.0)) - host_now <= 60.0)
	if phase == "unloading":
		# Before the lift leaves the crew there is no clock: the line is the prompt.
		if prompt_line == "":
			prompt_line = clock_line
		clock_line = ""

## The walk model's doors, bridge and lift phase from the block (the view does this itself when it is drawn).
func _sync(ward: Dictionary) -> void:
	model.bridge_lowered = bool(ward.get("bridgeLowered", false))
	model.phase = StringName(str(ward.get("phase", "unloading")))
	var doors: Array = ward.get("doors", [])
	for i in doors.size():
		model.requested_doors[i] = bool(doors[i])

## The lift's line without the view (the same words as client/ward/view.gd show_host).
static func lift_line(ward: Dictionary, host_now: float, id: String) -> String:
	match str(ward.get("phase", "")):
		"away":
			var seconds := maxi(0, ceili(float(ward.collectionAt) - host_now))
			return "LIFT RETURNS IN %d:%02d" % [seconds / 60, seconds % 60]
		"boarding":
			return "DOORS CLOSE IN %d" % maxi(0, ceili(float(ward.departAt) - host_now))
		"departed":
			if (ward.get("boarded", []) as Array).has(id):
				return "ABOARD"
			if (ward.get("leftBehind", []) as Array).has(id):
				return "LEFT BEHIND"
			return "LIFT DEPARTED"
	return "STEP OUT OF THE LIFT"

## A caught player's watching camera (client/ward/view.gd _watch), or null while not watching.
func watch_transform() -> Variant:
	if view == null or not view.watching:
		return null
	return view.watch_camera.global_transform

## The Ward's look on the main scene's environment (its background, ambient light and fog).
func apply_environment(env: Environment) -> void:
	if view == null or view.environment == null:
		return
	var own := view.environment
	env.background_color = own.background_color
	env.ambient_light_source = own.ambient_light_source
	env.ambient_light_color = own.ambient_light_color
	env.ambient_light_energy = own.ambient_light_energy
	env.fog_enabled = own.fog_enabled
	env.fog_light_color = own.fog_light_color
	env.fog_density = own.fog_density
