# WN1: the Hanging Ward as a normal level. The owner, 20 Nov: "Why do we treat floors 76 and 7 differently? They
# should just be like normal levels like the other ones in the game?" With the run flag `ward_place`
# (net/host_rules.gd, the last parameter after cycles_) the main scene never steps aside on floor 6: it hosts the
# Ward's world (client/ward/floor.gd) in its own picture and walks its own player through the Ward's walk model.
#   1. Off, the rules are tick for tick the same as on (the flag only marks the snapshot), the Ward's block is the
#      thirteen fields it was, and the main game still swaps (FL1); on, the block says `native`.
#   2. On, in the real game scene: F6 to floor 6, no scene change; the Ward drawn in the main picture from the main
#      camera; the main game's own keys walk the player out of the lift, the host accepting every step; the HUD shows
#      STEP OUT OF THE LIFT and then LIFT RETURNS IN; F works the winch; F6 opens the picker over the Ward; Esc shows
#      the menu; caught, the screen watches; when the lift has gone the main scene's own level and lift come back.
# Part 2 runs everywhere: the Ward's figures and sounds ship in the game (IP1).
extends RefCounted

const T = preload("res://tests/t.gd")
const Game = preload("res://client/main.gd")
const GameScene = preload("res://main.tscn")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Move = preload("res://sim/move.gd")
const WardWire = preload("res://net/ward_wire.gd")
const Ward = preload("res://sim/ward/state.gd")
## WG1: a block's layout options (sim/ward/layout.gd from_wire), so the test builds the host's Ward.
const WardLayout = preload("res://sim/ward/layout.gd")

static func _room(native: bool, seed_: String) -> LocalRoom:
	var room := LocalRoom.new()
	room.open_local(seed_, "Tester", true)
	room.late_archive_root = ""
	room.ward_place = native
	# WC1: this file is the Ward as a normal level with its own clock (ward.lift_clock, the host's fallback); the lift
	# called from the station and the web are tests/prop_ward_call.gd's and tests/test_ward_web_view.gd's.
	room.ward_call = false
	room.ward_web = false
	# WG1: this compares the block with ward_place off and on only; today's layout keeps its 13 and 14 fields
	# (tests/prop_ward_layout.gd checks the generated layout's fifteenth).
	room.ward_layout = false
	room.start_playtest(HostRules.WARD_DEPTH)
	return room

func test_the_flag_is_the_last_parameter_and_off_by_default(t: T) -> void:
	var names: Array = []
	for m: Dictionary in HostRules.new(true, 1).get_method_list():
		if m["name"] == "_init":
			for a: Dictionary in m["args"]:
				names.append(a["name"])
	t.eq(names[names.find("cycles_") + 1], "ward_place_", "ward_place_ comes right after cycles_ (reactor_place_ follows it)")
	t.eq(names[names.find("cycles_") + 2], "reactor_place_", "reactor_place_ follows it (later flags such as pressures_ come after)")
	t.check(not HostRules.new(true, 1).ward_place, "off by default")
	var args: Array = []
	for i in names.size():
		args.append(true if i >= 2 else (true if i == 0 else 1))
	args[2] = []
	t.check(HostRules.new.callv(args).ward_place, "on when asked, with the late floors")
	args[names.find("late_floors_")] = false
	t.check(not HostRules.new.callv(args).ward_place, "never without the late floors")

func test_off_is_tick_for_tick_the_same_rules_and_the_old_block(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var off := _room(false, "wn1-same")
	var on := _room(true, "wn1-same")
	t.check(not off.rules.ward_place and on.rules.ward_place, "the rooms differ only in the flag")
	var now := 0.0
	var same := true
	var first_diff := ""
	var spawn: Vector3 = Ward.new(int(off.host.world().ward.seed), WardLayout.from_wire(off.host.world().ward.get("layout"))).lift_door() + Vector3(-0.28, 0.02, -0.55)
	for i in 160:
		now += 0.05
		# The same walk out of the car for both: a step along +z each tick, as a client would send it.
		var lf := Client.LocalFrame.new()
		var z := spawn.z + minf(4.0, float(i) * 0.05 * 1.85)
		lf.body = Move.Body.make(spawn.x, z, 0, spawn.y if z < spawn.z + 0.6 else 0.0)
		lf.eye = 1.65
		for room: LocalRoom in [off, on]:
			room.frame(now, lf)
			room.poll(now)
		var a: Dictionary = off.host.world()
		var b: Dictionary = on.host.world()
		if i == 0:
			t.check(not (a.ward as Dictionary).has("native"), "off: no native mark")
			t.check((b.ward as Dictionary).get("native", false) == true, "on: the block says native")
		var bw: Dictionary = (b.ward as Dictionary).duplicate()
		bw.erase("native")
		b = b.duplicate()
		b["ward"] = bw
		a = _plain(a)
		b = _plain(b)
		if JSON.stringify(a) != JSON.stringify(b) and same:
			same = false
			first_diff = "tick %d:" % i
			for k: String in a:
				if JSON.stringify(a[k]) != JSON.stringify(b.get(k)):
					first_diff += " " + k
	t.check(same, "160 ticks of the same walk: the host's world is the same, apart from the mark (%s)" % first_diff)
	t.eq(str(off.host.world().ward.phase), "away", "and the walk took the crew out of the lift on both")
	var block: Dictionary = off.host.world().ward
	t.eq(WardWire.encode(block).size(), 13, "off: the wire block is the thirteen fields it always was")
	var marked: Dictionary = on.host.world().ward
	t.eq(WardWire.encode(marked).size(), 14, "on: one more")
	t.eq(WardWire.decode(WardWire.encode(marked)).get("native"), true, "and it reads back")
	t.check(not WardWire.decode(WardWire.encode(block)).has("native"), "off reads back without it")
	var bad := WardWire.encode(block)
	bad.append(false)
	t.check(WardWire.decode(bad).is_empty(), "a fourteenth field that is not true is refused")
	t.eq(Game.floor_handover(off.client.latest), "ward", "off: the main game swaps to the Ward's scene, as FL1 did")
	t.eq(Game.floor_handover(on.client.latest), "", "on: the main game stays")
	off.leave()
	on.leave()
	Session.deck = original

## Host facts as plain values: a body (an object) by its numbers, so two rooms' worlds compare by value.
static func _plain(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k: Variant in v:
			out[k] = _plain(v[k])
		return out
	if v is Array:
		return (v as Array).map(func(x: Variant) -> Variant: return _plain(x))
	if v is Object:
		var o: Object = v
		var fields := {}
		for p: Dictionary in o.get_property_list():
			if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				fields[p["name"]] = _plain(o.get(p["name"]))
		return fields
	return v

# --- 2. In the real game scene. ---

static func _key(_game: Node, code: Key, down: bool) -> void:
	var k := InputEventKey.new()
	k.pressed = down
	k.keycode = code
	k.physical_keycode = code
	# Into the engine's input (what the game's movement and use keys read); the tree hands it to the game's own
	# _input too, so a key the game acts on (F6, Esc) arrives once.
	Input.parse_input_event(k)
	Input.flush_buffered_events()

static func _frames(game: Node, n: int) -> void:
	for i in n:
		game._process(1.0 / 60.0)
		OS.delay_usec(16667)

static func _ward_of(game: Node) -> Dictionary:
	var lc: Variant = game.link.client() if game.link != null else null
	return lc.latest.get("ward", {}) if lc != null and lc.latest is Dictionary else {}

func test_the_main_scene_plays_the_ward(t: T) -> void:
	var original := Session.deck
	var tree := Engine.get_main_loop() as SceneTree
	var game := GameScene.instantiate() as Game
	game.automated = true
	tree.root.add_child(game)
	game.start.playtest_available = true
	# Four seconds on the title first, as a player would: the room's clock then starts behind the game's, which is
	# what the lift's clock must not be read against.
	_frames(game, 240)
	game._open_playtest()
	game.start.press(str(HostRules.WARD_DEPTH))
	var lr := game.link.rc as LocalRoom
	t.check(lr.rules.ward_place, "the sandbox's floor 6 has the Ward as a normal level")
	# WC1: the game's rooms call the Ward's lift from its station (net/host_rules.gd ward_call). This test walks the
	# Ward's own clock (the host's fallback, ward.lift_clock) through the main scene; the called lift is
	# tests/prop_ward_call.gd's and tools/play_late.mjs's.
	t.check(lr.rules.ward_call and lr.host._ward_review != null and lr.host._ward_review.called, "the game's room calls the Ward's lift from the station")
	if lr.host._ward_review != null:
		lr.host._ward_review.called = false
	_frames(game, 20)
	t.check(is_instance_valid(game) and game.is_inside_tree() and game.link != null and game.link.rc == lr, "no scene change: the main scene is still the game")
	t.check(not game._floor_entry_pending, "and no swap is queued")
	var wf: Node3D = game._ward_floor
	if not t.check(wf != null and wf.view != null, "the main scene hosts the Ward's world"):
		game.free()
		Session.deck = original
		return
	t.check(wf.get_viewport() == game.sub and game.cam.current and game.cam.get_viewport() == game.sub, "in the main game's picture, from its own camera")
	t.check(not game.level.visible and not game.lift.visible, "in place of the floor plan's level and lift")
	t.eq(game.hud.prompt, "STEP OUT OF THE LIFT", "the HUD's prompt in the lift")
	var door: Vector3 = wf.model.lift_door()
	# The main game's own keys walk the player out through the Ward's walk model.
	var clamped: int = lr.host.stats.clamped_inputs
	_key(game, KEY_W, true)
	var out := 0.0
	for i in 300:
		_frames(game, 1)
		out = game.link.body.z - door.z
		if out > 3.0:
			break
	_key(game, KEY_W, false)
	_frames(game, 10)
	t.check(out > 3.0, "W walks the main game's player out of the lift (%.2f m past the doors)" % out)
	var accepted: Variant = null
	for row: Dictionary in game.link.client().latest.players:
		if str(row.id) == game.link.my_id():
			accepted = row.body
	t.check(accepted != null and float(accepted.z) - door.z > 2.5, "the host accepted the walk")
	t.eq(int(lr.host.stats.clamped_inputs), clamped, "and refused no step")
	t.eq(str(_ward_of(game).get("phase", "")), "away", "the lift has left the crew")
	t.check(game.hud.tenant_line.begins_with("LIFT RETURNS IN "), "LIFT RETURNS IN under PLAY: " + game.hud.tenant_line)
	var parts := game.hud.tenant_line.trim_prefix("LIFT RETURNS IN ").split(":")
	var shown := int(parts[0]) * 60 + int(parts[1]) if parts.size() == 2 else -1
	var left := float(_ward_of(game).get("collectionAt", 0.0)) - float(lr.host.state.t)
	t.check(absf(float(shown) - left) <= 2.0, "the line is the host's time left, on the room's clock (%d against %.1f s)" % [shown, left])
	t.check(is_equal_approx(game.cam.position.y - game.link.body.y, game.link.eye), "the camera is the main game's, at its eye height")
	# F works the winch (the Ward's own rule, through the main game's use key).
	var winch: Vector3 = lr.host._ward_review.switches[0]["position"]
	lr.host._place(LocalRoom.ME, Move.Body.make(winch.x, winch.z, 0, winch.y), lr.host.state.depth, lr.host.state)
	_frames(game, 10)
	var lowered := bool(_ward_of(game).get("bridgeLowered", false))
	_key(game, KEY_F, true)
	_frames(game, 6)
	_key(game, KEY_F, false)
	_frames(game, 10)
	t.check(bool(_ward_of(game).get("bridgeLowered", false)) != lowered, "F at the winch works the drawbridge")
	# F6 over the Ward: the picker, and RESUME back to the same game.
	_key(game, KEY_F6, true)
	_key(game, KEY_F6, false)
	t.eq(game.start.screen, "playtest", "F6 opens the floor picker on the Ward")
	game.start.press("resume")
	t.check(game.start.screen == "" and game.link.rc == lr, "RESUME goes back to the same Ward")
	# Esc: the main game's menu.
	_key(game, KEY_ESCAPE, true)
	_key(game, KEY_ESCAPE, false)
	_frames(game, 2)
	# Under automation the card itself is not drawn (main.gd: never in a test); the game is in its Esc menu.
	t.check(game._esc_menu, "Esc opens the main game's menu (brightness and hints on it)")
	_key(game, KEY_ESCAPE, true)
	_key(game, KEY_ESCAPE, false)
	# Caught: the screen watches from above (alone, no one to watch through).
	lr.host._ward_review.caught.append(LocalRoom.ME)
	_frames(game, 150)
	t.check(wf.view.caught, "the Ward's view knows this player was caught")
	var watch: Variant = wf.watch_transform()
	t.check(watch is Transform3D and game.cam.global_transform.is_equal_approx(watch), "and the main camera watches")
	t.eq(game.hud.prompt, "NO ONE LEFT TO WATCH", "with the Ward's line")
	# The lift comes back and goes: the Ward leaves the main scene, which carries on.
	var ward: Variant = lr.host._ward_review
	ward.caught.clear()
	lr.host._place(LocalRoom.ME, Move.Body.make(door.x, door.z - 1.4, 0, door.y + 0.02), lr.host.state.depth, lr.host.state)
	ward.collection_at = lr.host.state.t + 0.5
	lr.time_scale = 30.0
	var departed := false
	var gone := false
	var back := false
	var same := false
	for i in 900:
		_frames(game, 1)
		var w := _ward_of(game)
		if w.is_empty() or str(w.get("phase", "")) == "departed":
			# Read on the very frame the lift has gone (cycles then ride on down to the Reactor, a scene of its own
			# until its rebuild lands, and a loaded machine could get there within a few frames).
			departed = true
			# The first frame this scene draws with the lift gone (a frame with no new snapshot draws nothing new).
			for k in 30:
				if game._ward_floor == null:
					break
				_frames(game, 1)
			gone = game._ward_floor == null and game.link != null and game.link.walker.is_null()
			back = game.level != null and game.level.visible and game.lift.visible
			same = game.is_inside_tree() and game.link != null and game.link.rc == lr
			break
	lr.time_scale = 1.0
	t.check(departed, "the lift came back and left")
	t.check(gone, "the Ward is gone from the main scene, its walk with it")
	t.check(back, "and the main game's own level and lift are back for the ride")
	t.check(same, "the same scene and room ride on")
	game.free()
	Session.deck = original
