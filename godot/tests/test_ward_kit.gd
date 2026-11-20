# WN2: what a crew carries works on the Hanging Ward played as a normal level. The owner, 20 Nov: "They should just be
# like normal levels like the other ones in the game?" With the run flag `ward_place` on (net/host_rules.gd) the host
# steps the run's own item rules after the Ward's tick (net/host.gd _step_ward_kit, sim/run.gd step_ward_kit):
#   1. the lamp switches on, burns its charge and lights where the player looks;
#   2. a flare is issued, thrown through the Ward's own walls (sim/ward/state.gd throw_landing), and its burst is a noise
#      the Ward hears in the house it lands in (the Rigger's line loads, as for a sprint);
#   3. an item is dropped and taken back (the four-slot inventory);
#   4. a caught player's bag falls where they stood, as a downed player's does on any floor; the catch is the Ward's own.
# With the flag off, the same presses do nothing on the Ward, as before WN2.
extends RefCounted

const T = preload("res://tests/t.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Inventory = preload("res://sim/inventory.gd")
const Flare = preload("res://sim/flare.gd")
const Ward = preload("res://sim/ward/state.gd")

class Rig:
	var room: LocalRoom
	var now := 0.0
	var body: Move.Body
	var yaw := 0.0

	func _init(native: bool, seed_: String) -> void:
		room = LocalRoom.new()
		room.open_local(seed_, "Tester", true)
		room.late_archive_root = ""
		room.ward_place = native
		room.start_playtest(HostRules.WARD_DEPTH)
		# Flares and the lamp are the host's command-line switches (flare=1, lamp=1: net/host_rules.gd); on here.
		room.host.state = Run.with_lamp(Run.with_flare(room.host.state))

	## One frame: the body as the client sends it, and at most one inventory request.
	func tick(op := "", arg: Variant = null, sel := -1) -> void:
		now += 0.05
		var lf := Client.LocalFrame.new()
		lf.body = body
		lf.eye = 1.65
		lf.yaw = yaw
		lf.inv_op = op
		lf.inv_arg = arg
		lf.inv_select = sel
		room.frame(now, lf)
		room.poll(now)

	func ticks(n: int) -> void:
		for i in n:
			tick()

	## Out of the car along +z, as test_ward_native walks it: the lift then leaves the crew.
	func walk_out() -> void:
		var spawn: Vector3 = room.host._ward_review.lift_door() + Vector3(-0.28, 0.02, -0.55)
		for i in 100:
			var z := spawn.z + minf(4.0, float(i) * 0.05 * 1.85)
			body = Move.Body.make(spawn.x, z, 0, spawn.y if z < spawn.z + 0.6 else 0.0)
			tick()

	func state() -> Run.RunState:
		return room.host.state

	func bag() -> Inventory.Bag:
		return Inventory.bag_of(state().bags, LocalRoom.ME)

	func events_since(seq: int, type: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for le in room.host.event_log:
			if le.seq > seq and str(le.e.get("type", "")) == type:
				out.append(le.e)
		return out

	func last_seq() -> int:
		return room.host.event_log.back().seq if not room.host.event_log.is_empty() else 0

static func _deck_on() -> Array:
	var original := Session.deck
	Session.deck = Places.FULL
	return [original]

func test_the_lamp_works_on_the_ward(t: T) -> void:
	var keep := _deck_on()
	var on := Rig.new(true, "wn2-lamp")
	var off := Rig.new(false, "wn2-lamp")
	for rig: Rig in [on, off]:
		rig.walk_out()
	t.check(on.state().lamp, "the run carries the lamp")
	t.eq(str(on.room.host.world().ward.phase), "away", "the lift has left the crew")
	var from := on.last_seq()
	on.tick("lamp", 1)
	off.tick("lamp", 1)
	on.ticks(20)
	off.ticks(20)
	var lamp := Run.lamp_of(on.state(), LocalRoom.ME)
	t.check(bool(lamp.get("on", false)), "on: L switches the lamp on (%s)" % str(lamp))
	t.eq(on.events_since(from, "lampSwitched").size(), 1, "on: once, said as on any floor")
	var full := Run.Lamp.new_charge(on.state().tuning)
	t.check(float(lamp.get("charge", full)) < full - 0.9, "on: it burns its charge (%.2f of %.2f)" % [float(lamp.get("charge", -1.0)), full])
	t.check(absf(float(lamp.get("x", 0.0)) - on.body.x) < 0.5 and absf(float(lamp.get("z", 0.0)) - on.body.z) < 0.5, "on: it shines from where the player stands")
	var lamps: Array = on.room.host.world().get("lamps", [])
	t.check(lamps.any(func(r: Dictionary) -> bool: return str(r.playerId) == LocalRoom.ME and bool(r.on)), "on: the snapshot carries the lit lamp for every screen")
	t.check(not bool(Run.lamp_of(off.state(), LocalRoom.ME).get("on", false)), "off: L does nothing on the Ward, as before")
	on.tick("lamp", 0)
	on.tick()
	t.check(not bool(Run.lamp_of(on.state(), LocalRoom.ME).get("on", true)), "on: and off again")
	on.room.leave()
	off.room.leave()
	Session.deck = keep[0]

func test_a_flare_is_thrown_through_the_wards_walls_and_heard(t: T) -> void:
	var keep := _deck_on()
	var on := Rig.new(true, "wn2-flare")
	var off := Rig.new(false, "wn2-flare")
	for rig: Rig in [on, off]:
		rig.walk_out()
	t.check(on.state().flare, "the run carries flares")
	var slot := -1
	for k in Inventory.SLOTS:
		if on.bag().item(k) == Flare.ITEM:
			slot = k
	t.check(slot >= 0, "on: the floor's flare is issued into the bag, as on any floor")
	var off_slot := -1
	for k in Inventory.SLOTS:
		if off.bag().item(k) == Flare.ITEM:
			off_slot = k
	var ward: Ward = on.room.host._ward_review
	t.eq(String(ward.encounter), "idle", "nothing has heard the crew yet")
	var from := on.last_seq()
	on.yaw = PI  # facing +z, on into the house
	on.tick("use", null, slot)
	on.tick()
	off.tick("use", null, maxi(0, off_slot))
	off.tick()
	var used := on.events_since(from, "flareUsed")
	if not t.check(used.size() == 1, "on: the flare is used (%d)" % used.size()):
		on.room.leave()
		off.room.leave()
		Session.deck = keep[0]
		return
	t.eq(on.bag().count(slot), 0, "on: and leaves the hand")
	var burst: Dictionary = used[0]
	var feet := Vector3(on.body.x, on.body.y, on.body.z)
	var reach := Run.Settings.f(on.state().tuning, &"flare.throw", Flare.THROW)
	var direction := Flare.forward(on.yaw) * reach
	var expect := Ward.new(int(on.room.host.world().ward.seed))
	expect.phase = ward.phase
	expect.bridge_lowered = ward.bridge_lowered
	expect.requested_doors = ward.requested_doors.duplicate()
	var lands := expect.throw_landing(feet, direction)
	t.check(Vector3(float(burst.x), float(burst.y), float(burst.z)).distance_to(lands) < 0.02,
		"on: it comes down where the Ward's own walls stop it (%.2f, %.2f, %.2f against %s)" % [float(burst.x), float(burst.y), float(burst.z), str(lands)])
	t.check(not bool(burst.get("stunned", true)), "on: it stuns nothing (the floor plan's resident is not here)")
	t.check(not (on.room.host.world().get("flares", []) as Array).is_empty(), "on: the burst is in the snapshot for every screen")
	t.eq(on.events_since(from, "ward_line_loaded").size(), 1, "on: the Ward hears the burst: the Rigger's line loads")
	t.check(String(ward.encounter) != "idle", "on: and he comes (%s)" % ward.encounter)
	t.eq(off.events_since(0, "flareUsed").size(), 0, "off: no flare on the Ward, as before")
	t.eq(String((off.room.host._ward_review as Ward).encounter), "idle", "off: nothing heard")
	on.room.leave()
	off.room.leave()
	Session.deck = keep[0]

func test_items_are_dropped_and_taken_back_on_the_ward(t: T) -> void:
	var keep := _deck_on()
	var on := Rig.new(true, "wn2-bag")
	var off := Rig.new(false, "wn2-bag")
	for rig: Rig in [on, off]:
		rig.walk_out()
	t.check(on.state().inventory, "the run carries the four-slot inventory")
	var slot := -1
	for k in Inventory.SLOTS:
		if on.bag().count(k) > 0:
			slot = k
	if not t.check(slot >= 0, "on: something in the bag"):
		on.room.leave()
		off.room.leave()
		Session.deck = keep[0]
		return
	var item := on.bag().item(slot)
	var from := on.last_seq()
	on.tick("", null, slot)
	on.tick("drop")
	on.tick()
	t.eq(on.events_since(from, "itemDropped").size(), 1, "on: G drops what is in the hand")
	t.eq(on.bag().count(slot), 0, "on: out of the bag")
	t.eq(on.state().pickups.size(), 1, "on: onto the Ward's floor")
	var pk: Inventory.Pickup = on.state().pickups[0]
	t.check(absf(pk.at.x - on.body.x) < 0.01 and absf(pk.at.z - on.body.z) < 0.01, "on: at the player's feet")
	on.tick("take", pk.id)
	on.tick()
	t.eq(on.events_since(from, "itemTaken").size(), 1, "on: F takes it back")
	t.eq(on.bag().totals().get(item, 0), 1, "on: back in the bag")
	t.eq(on.state().pickups.size(), 0, "on: and off the floor")
	var before := off.bag().slots.duplicate(true)
	off.tick("", null, slot)
	off.tick("drop")
	off.tick()
	t.eq(off.events_since(0, "itemDropped").size(), 0, "off: G does nothing on the Ward, as before")
	t.eq(off.bag().slots, before, "off: the bag is as it was")
	on.room.leave()
	off.room.leave()
	Session.deck = keep[0]

func test_a_caught_players_bag_falls_where_they_were(t: T) -> void:
	var keep := _deck_on()
	var on := Rig.new(true, "wn2-caught")
	on.walk_out()
	var held := 0
	for k in Inventory.SLOTS:
		held += on.bag().count(k)
	t.check(held > 0, "the player carries something (%d)" % held)
	# The Rigger's hand: the Ward's own contact cue (sim/ward/state.gd), as the arm raises it.
	var ward: Ward = on.room.host._ward_review
	ward.caught.append(LocalRoom.ME)
	var cue := {"kind": &"contact", "at": on.state().t + 0.05, "house": 0, "id": LocalRoom.ME}
	var s := on.state()
	var rows := {LocalRoom.ME: {"position": Vector3(on.body.x, on.body.y, on.body.z), "aboard": false, "active": true}}
	var cues: Array[Dictionary] = [cue.merged({"type": "ward_contact", "t": cue.at})]
	var none: Array[Run.PlayerInput] = []
	var r := Run.step_ward(s, none, rows, PackedVector3Array(), &"away", 0.0, [] as Array[String], 0.05, cues)
	t.eq(String(r.state.players[0].status), "caught", "the hand's contact is the Ward's catch")
	on.room.host._step_ward_kit(r, none, r.state.t)
	var dropped := r.events.filter(func(e: Dictionary) -> bool: return e["type"] == "itemDropped" and e.get("why") == "down")
	t.eq(dropped.size(), Inventory.SLOTS - on.bag().slots.filter(func(x: Array) -> bool: return int(x[1]) <= 0).size(), "on: every item they held falls")
	var total := 0
	for k in Inventory.SLOTS:
		total += Inventory.bag_of(r.state.bags, LocalRoom.ME).count(k)
	t.eq(total, 0, "on: the bag is empty")
	t.eq(r.state.pickups.size(), dropped.size(), "on: and it lies on the Ward's floor for a crewmate")
	on.room.leave()
	Session.deck = keep[0]

## With the flag off nothing changes, tick for tick: the same Ward run with every item key pressed is the same world as
## the same run with none pressed (before WN2 the Ward stepped no item, so no press could change anything).
func test_off_the_ward_is_as_it_was(t: T) -> void:
	var keep := _deck_on()
	var pressed := Rig.new(false, "wn2-off")
	var quiet := Rig.new(false, "wn2-off")
	pressed.walk_out()
	quiet.walk_out()
	var ops := [["lamp", 1, -1], ["use", null, 0], ["drop", null, 1], ["take", 1, -1], ["", null, 2], ["use", null, 2]]
	var same := true
	var at := ""
	for i in 60:
		var op: Array = ops[i % ops.size()]
		pressed.tick(str(op[0]), op[1], int(op[2]))
		quiet.tick()
		var a := JSON.stringify(_plain(pressed.room.host.world()))
		var b := JSON.stringify(_plain(quiet.room.host.world()))
		if a != b and same:
			same = false
			at = "tick %d" % i
	t.check(same, "off: 60 ticks of item keys on the Ward change nothing (%s)" % at)
	pressed.room.leave()
	quiet.room.leave()
	Session.deck = keep[0]

# --- In the real game scene (needs the private WardGroundMedia.pck in GD_PACKS_DIR; SKIPS without it, as on CI). ---

static func _frames(game: Node, n: int) -> void:
	for i in n:
		game._process(1.0 / 60.0)
		OS.delay_usec(16667)

## The lamp's beam and a flare's light hang in the Ward's world (the floor plan's level is hidden there), and an item
## on the floor in reach keeps the main game's F prompt.
func test_the_main_scene_shows_the_lamp_and_the_take_prompt_on_the_ward(t: T) -> void:
	var dir := OS.get_environment("GD_PACKS_DIR")
	if dir.is_empty() or not FileAccess.file_exists(dir.path_join("WardGroundMedia.pck")):
		t.note("skipped: pack not found (set GD_PACKS_DIR to the folder holding WardGroundMedia.pck)")
		return
	var keep := _deck_on()
	var tree := Engine.get_main_loop() as SceneTree
	var game := (load("res://main.tscn") as PackedScene).instantiate()
	game.automated = true
	game.pack_dir = dir
	tree.root.add_child(game)
	game.start.playtest_available = true
	_frames(game, 30)
	game._open_playtest()
	game.start.press(str(HostRules.WARD_DEPTH))
	var lr := game.link.rc as LocalRoom
	lr.host.state = Run.with_lamp(Run.with_flare(lr.host.state))
	_frames(game, 20)
	var wf: Node3D = game._ward_floor
	if not t.check(wf != null and lr.rules.ward_place, "the main scene hosts the Ward"):
		game.free()
		Session.deck = keep[0]
		return
	# Out of the lift with the main game's own W (as test_ward_native), so the Ward has no line of its own to show.
	var door: Vector3 = wf.model.lift_door()
	var w := InputEventKey.new()
	w.keycode = KEY_W
	w.physical_keycode = KEY_W
	w.pressed = true
	Input.parse_input_event(w)
	Input.flush_buffered_events()
	for i in 300:
		_frames(game, 1)
		if game.link.body.z - door.z > 3.0:
			break
	var up := w.duplicate() as InputEventKey
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()
	_frames(game, 20)
	t.eq(str(lr.host.world().ward.phase), "away", "walked out: the lift has left")
	game.pending_inv_op = "lamp"
	game.pending_inv_arg = 1
	_frames(game, 20)
	var beams: Dictionary = game.lamp_view.beams
	var beam: Variant = beams.get(game.link.my_id())
	t.check(beam is SpotLight3D and is_instance_valid(beam), "the lamp is lit on screen")
	t.check(beam is SpotLight3D and (beam as Node).get_parent() == wf and (beam as Node3D).is_visible_in_tree(), "in the Ward's world, not the hidden level")
	game.pending_inv_op = "drop"
	game.pending_inv_arg = 0
	_frames(game, 20)
	t.eq(lr.host.state.pickups.size(), 1, "G drops the flare on the Ward's floor")
	t.check(game.inv_view.prompt != "" and game.hud.prompt == game.inv_view.prompt, "and the HUD says F takes it (%s / %s)" % [game.hud.prompt, game.inv_view.prompt])
	game.free()
	Session.deck = keep[0]

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
