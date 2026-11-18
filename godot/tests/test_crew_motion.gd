# The retargeted crew model and poses seen by other players.
extends RefCounted

const T = preload("res://tests/t.gd")
const Client = preload("res://net/client.gd")
const Main = preload("res://client/main.gd")
const Move = preload("res://sim/move.gd")
const PlayLink = preload("res://client/play_link.gd")
const Playroom = preload("res://sim/playroom.gd")
const Protocol = preload("res://net/protocol.gd")
const RoomClient = preload("res://net/room_client.gd")

func test_all_clips_ship_and_emote_codes_stay_stable(t: T) -> void:
	var world := _world()
	world.update(0.0, [_figure("crew", "ok", 2.0)], Vector3.ZERO)
	var view: CrewView = world.figures["crew"]["view"]
	for name: String in ["idle", "walk", "run", "sneak", "crouch_idle", "crawl", "taken", "down_idle", "get_up", "help", "prone", "sit"]:
		t.check(view.ap.has_animation(name), "imported clip %s" % name)
	var names := ["wave", "look_behind", "pray", "dance_spin", "dance_snake", "button", "point", "cheer", "scared"]
	t.eq(Main.EMOTE_LABELS.size(), names.size(), "the wheel offers every network emote")
	for i in names.size():
		var name: String = names[i]
		t.eq(JSON.parse_string(Protocol.encode({"type": "emote", "emote": name})), [1.0, "E", float(i)], "wire code for %s" % name)
		var wire := Protocol.encode({"type": "emoted", "player": "crew", "emote": name, "t": 0.0})
		var event: Dictionary = Protocol.decode(wire)
		world.play_emote(str(event["player"]), str(event.get("emote", "")))
		t.eq(view.clip, name, "received %s plays on the remote player" % name)
	view.set_gait(&"walk", 1.0)
	view._process(1.0 / 60.0)
	t.eq(view.clip, "walk", "movement cancels a gesture")
	world.free()

func test_remote_crew_fall_crawl_get_up_and_go_out(t: T) -> void:
	var world := _world()
	var crew := _figure("crew", "down", 2.0)
	world.update(0.0, [crew], Vector3.ZERO)
	var view: CrewView = world.figures["crew"]["view"]
	t.eq(view.clip, "taken", "a catch begins with the fall")
	for i in 235:
		view._process(1.0 / 60.0)
	t.eq(view.clip, "down_idle", "still down, hurt on the floor")
	var hurt_y := view.mask_height()
	t.check(hurt_y < 0.5, "hurt pose keeps the mask low (%.2f m)" % hurt_y)
	view.set_gait(&"walk", 0.6)
	view._process(1.0 / 60.0)
	t.eq(view.clip, "crawl", "moving while down crawls")
	for i in 55:
		view._process(1.0 / 60.0)
	var crawl_y := view.mask_height()
	t.check(crawl_y < 0.75, "crawl keeps the mask low (%.2f m)" % crawl_y)
	crew["status"] = "ok"
	world.update(0.0, [crew], Vector3.ZERO)
	view._process(1.0 / 60.0)
	t.eq(view.clip, "get_up", "a healed crewmate gets up")
	for i in 160:
		view._process(1.0 / 60.0)
	t.eq(view.clip, "idle", "getting up hands back to locomotion")
	t.check(view.mask_height() > 1.4, "the healed player is back on their feet")
	t.note("mask height: down %.2f m, crawling %.2f m, back on feet %.2f m" % [hurt_y, crawl_y, view.mask_height()])
	crew["status"] = "down"
	world.update(0.0, [crew], Vector3.ZERO)
	crew["status"] = "out"
	world.update(0.0, [crew], Vector3.ZERO)
	t.check(not view.visible, "an out crewmate is hidden")
	crew["status"] = "ok"
	world.update(0.0, [crew], Vector3.ZERO)
	view._process(1.0 / 60.0)
	t.eq(view.clip, "idle", "an out crewmate who reappears was not healed on this spot")
	world.free()

func test_host_help_bed_and_seat_reach_remote_crew(t: T) -> void:
	var play := PlayLink.new(RoomClient.new(), true)
	var bed := Playroom.Hide.new()
	bed.id = 0
	bed.kind = &"bed"
	bed.eye = 20
	bed.gap = &"s"
	bed.capacity = 1
	play.hides.append(bed)
	var seat := Playroom.Seat.new()
	seat.facing = &"n"
	play.seats.append(seat)
	var frame := Client.Frame.new()
	for i in 4:
		var row := _figure("crew%d" % i, "down" if i == 1 else "ok", 2.0 + float(i))
		row["body"] = Move.Body.make(float(row["x"]), 0.0, 0, 0.0)
		frame.players.append(row)
	var latest := {"players": frame.players, "crew": [], "downs": {"down": [{"id": "crew1", "healer": "crew0", "healFrom": 2.0}]},
		"seek": {"players": [
			{"id": "crew2", "hide": 0, "phase": "inside", "status": "ok", "seat": -1},
			{"id": "crew3", "hide": -1, "phase": "out", "status": "taken", "seat": 0},
		]}}
	var rows := play._others(frame, latest)
	var world := _world()
	world.update(0.0, rows, Vector3.ZERO)
	for id: String in ["crew0", "crew2", "crew3"]:
		var view: CrewView = world.figures[id]["view"]
		for j in 35:
			view._process(1.0 / 60.0)
		match id:
			"crew0":
				t.eq(view.clip, "help", "the host's helper kneels")
				t.check(absf(angle_difference(view.body_yaw, -PI / 2.0)) < 0.02, "the helper faces the downed player")
			"crew2":
				t.eq(view.clip, "prone", "the player under a bed lies flat")
				t.check(view.mask_height() < 0.4, "prone pose keeps the mask low (%.2f m)" % view.mask_height())
				t.note("prone mask height %.2f m" % view.mask_height())
			"crew3":
				t.eq(view.clip, "sit", "the player at the party table sits")
				var mask_y := view.position.y + view.mask_height()
				t.check(absf(mask_y - PlayLink.SEAT_EYE) < 0.05, "seated mask matches the camera (%.2f m)" % mask_y)
				t.note("seated mask height %.2f m" % mask_y)
	latest["downs"]["down"] = []
	world.update(0.0, play._others(frame, latest), Vector3.ZERO)
	var healer: CrewView = world.figures["crew0"]["view"]
	healer._process(1.0 / 60.0)
	t.eq(healer.clip, "idle", "releasing the host heal hold ends the help pose")
	world.free()

static func _figure(id: String, status: String, x: float) -> Dictionary:
	return {"id": id, "status": status, "x": x, "y": 0.0, "z": 0.0, "yaw": 0.0, "pitch": 0.0, "index": 0,
		"gait": "walk", "active": true, "raised": false}

static func _world() -> OthersView:
	var world := OthersView.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(world)
	return world
