extends RefCounted

const T = preload("res://tests/t.gd")
const ShopView = preload("res://client/shop_view.gd")
const InventoryView = preload("res://client/inventory_view.gd")
const SearchView = preload("res://client/search_view.gd")
const PropSearch = preload("res://tests/prop_search.gd")
const Move = preload("res://sim/move.gd")
const Protocol = preload("res://net/protocol.gd")

class Heard extends RefCounted:
	var cues: Array = []

	func play(name: String, _gain_db := 0.0) -> void:
		cues.append([name])

	func play_at(name: String, pos: Vector3) -> void:
		cues.append([name, pos])

func test_search_sounds_follow_confirmed_actions(t: T) -> void:
	var view := SearchView.new()
	var run := PropSearch.find_run("search-sounds", PropSearch._ids(2))
	view.use_plan(run.plan)
	var id: int = view.pieces_plain()[0]["id"]
	var heard := Heard.new()
	view.on_events([
		{"type": "searchStart", "playerId": "p0", "kind": "drawers_low", "fast": false},
		{"type": "searchStart", "playerId": "p0", "kind": "side_table", "fast": false},
		{"type": "searchStart", "playerId": "p1", "kind": "drawers_low", "fast": false},
		{"type": "searchStart", "playerId": "p0", "kind": "drawers_low", "fast": true},
		{"type": "searchNoise", "playerId": "p0", "piece": id},
		{"type": "searchFull", "playerId": "p0", "piece": id},
		{"type": "searchDone", "playerId": "p1", "piece": id, "what": "juice", "credits": 0, "note": ""},
		{"type": "searchDone", "playerId": "p0", "piece": id, "what": "juice", "credits": 0, "note": ""},
		{"type": "searchDone", "playerId": "p0", "piece": id, "what": "note", "credits": 0, "note": "stillness-1"},
	], "p0", heard, 0)
	t.eq(heard.cues, [["search_drawer"], ["search_locker"], ["search_rifle", view.piece_point(id)],
		["search_carton"], ["search_paper"]], "one positional rifle, extras only for the confirmed searcher")

func test_inventory_sounds_follow_confirmed_actions(t: T) -> void:
	var view := InventoryView.new()
	var body := Move.Body.make(6.0, 8.0, 1, 3.2)
	var other_body := Move.Body.make(7.0, 8.0, 1, 3.2)
	var events: Array = Protocol.plain([
		{"type": "invRefused", "playerId": "p0", "why": "empty"},
		{"type": "itemTaken", "playerId": "p0"},
		{"type": "itemGiven", "playerId": "p0", "to": "p1", "item": "juice"},
		{"type": "itemDropped", "playerId": "p0", "why": "drop", "t": 1.0, "pickup": 1, "at": body},
		{"type": "itemDropped", "playerId": "p0", "why": "down", "t": 2.0, "pickup": 2, "at": body},
		{"type": "itemDropped", "playerId": "p0", "why": "down", "t": 2.0, "pickup": 3, "at": body},
		{"type": "itemDropped", "playerId": "p1", "why": "down", "t": 2.0, "pickup": 4, "at": other_body},
	])
	var giver := Heard.new()
	var receiver := Heard.new()
	var bystander := Heard.new()
	for listener: Array in [["p0", giver], ["p1", receiver], ["p2", bystander]]:
		view.reset()
		view.on_events(events.slice(0, 5), listener[0], {}, 0, listener[1])
		view.on_events(events.slice(5), listener[0], {}, 16, listener[1])
	var drops := [["item_drop", Vector3(6, 3.3, 8)], ["item_drop", Vector3(6, 3.3, 8)],
		["item_drop", Vector3(7, 3.3, 8)]]
	t.eq(giver.cues, [["item_pickup"], ["item_handoff"]] + drops, "the taker and giver each hear their action once")
	t.eq(receiver.cues, [["item_handoff"]] + drops, "the recipient hears the hand-over once")
	t.eq(bystander.cues, drops, "nearby crew hear drops in place, once per spill")
	view.free()

func test_shop_item_sounds_follow_only_accepted_local_uses(t: T) -> void:
	var view := ShopView.new()
	var heard := Heard.new()
	view.on_events([
		{"type": "invRefused", "playerId": "me", "item": "salts"},
		{"type": "itemUsed", "playerId": "other", "item": "flash"},
		{"type": "itemUsed", "playerId": "me", "item": "flash"},
		{"type": "itemUsed", "playerId": "me", "item": "speed"},
		{"type": "itemUsed", "playerId": "me", "item": "glow"},
		{"type": "itemUsed", "playerId": "me", "item": "salts"},
		{"type": "itemUsed", "playerId": "me", "item": "toy"},
		{"type": "itemUsed", "playerId": "me", "item": "marker"},
	], "me", 273, heard)
	t.eq(heard.cues, [["shop_flash"], ["shop_juice"], ["shop_glow"], ["shop_salts"], ["shop_toy_wind"]],
		"only confirmed own recorded uses sound")
	t.eq(view.flash_at, 273, "the flash effect still follows the accepted event")
	view.free()

func test_orderly_proximity_and_moving_shriek(t: T) -> void:
	var sfx := preload("res://client/sfx.gd").new()
	var world := Node3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.make_current()
	world.add_child(sfx)
	sfx.setup(world)
	var pose := {"x": 0.0, "y": 0.0, "z": -24.0, "anim": "walk"}
	var frame := {"pose": pose}
	camera.position.y = 2.2
	var shot := sfx.play_at("shriek", Vector3(0, 2.2, -24))
	var far_gain := shot.volume_db
	var far_cutoff := shot.attenuation_filter_cutoff_hz
	sfx._orderly(0.02, frame)
	t.check(not sfx.orderly_breath.playing, "distant breath stays silent")
	camera.position.z = -20
	pose.z = -21.0
	sfx._orderly(0.02, frame)
	t.check(sfx.orderly_breath.playing, "adjacent unseen Orderly breathes")
	t.check(shot.position.is_equal_approx(Vector3(0, 2.2, -21)) and shot.volume_db > far_gain + 8.0 and shot.attenuation_filter_cutoff_hz > far_cutoff, "ongoing shriek tracks both current poses")
	frame.held = true
	sfx._orderly(0.02, frame)
	t.check(not sfx.orderly_breath.playing, "being watched silences the breath")
	world.free()

func test_second_wind_plays_one_nonlooped_exertion_take_at_the_player(t: T) -> void:
	var sfx := preload("res://client/sfx.gd").new()
	var world := Node3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(world)
	world.add_child(sfx)
	sfx.setup(world)
	var position := Vector3(4, 1.45, 6)
	var shot := sfx.play_at("second_wind", position)
	if t.check(shot != null, "accepted gasp resolves the existing crew take"):
		t.check(shot.global_position.is_equal_approx(position), "placed sound at the player")
		var stream := shot.stream as AudioStreamOggVorbis
		var breath := sfx.breath.stream as AudioStreamOggVorbis
		t.check(stream != null and not stream.loop and breath != null and breath.loop, "gasp plays once without changing the winded loop")
		t.check(stream.resource_path.ends_with("player/second_wind.ogg") and stream.get_length() < 1.0, "uses the short exertion excerpt")
	world.free()
