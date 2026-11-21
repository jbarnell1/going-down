# LS1 on screen (North Star B7; client/last_stand_view.gd, client/wipe_scene.gd, client/standee.gd, client/crew_watch.gd's
# lock, client/music.gd's quiet). Proved here:
#   1. The spotlight's screen: the survivor reads the bonus the host stamped, the others whom every camera is on; an out
#      player's view is locked on the survivor (LEFT CLICK or E does nothing); the music's target is silence while it
#      lasts and comes back after; a crew of one never gets a line.
#   2. The wipe's scene: arrive, doors open, a pause of about two seconds, the figure steps in, the doors close, it rides
#      up, black, inside the empty car's ride up (it adds nothing to the host's timing); identical on two clients that
#      decoded one host world, and it names the resident that made the last catch (a real wipe: the Orderly caught p0).
#      The Orderly's real figure walks into the car; the Reactor's four and the Ward's Rigger fall back to black.
#   3. The standee: the last-caught player's own drawn face on both clients (one has it from the host's "F", the other
#      is that player); the default face for one who drew none; the next wipe's player replaces it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const LastStandView = preload("res://client/last_stand_view.gd")
const WipeScene = preload("res://client/wipe_scene.gd")
const Standee = preload("res://client/standee.gd")
const CrewWatch = preload("res://client/crew_watch.gd")
const Paint = preload("res://face/face_paint.gd")
const RulesBridge = preload("res://client/rules_bridge.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Prison = preload("res://sim/prison.gd")
const PrisonView = preload("res://client/prison_view.gd")
const PropLastStand = preload("res://tests/prop_last_stand.gd")

const NAMES := {"p0": "Ann", "p1": "Bob", "p2": "Cy", "p3": "Di"}

static func fig(id: String, status: String, index: int) -> Dictionary:
	return {"id": id, "status": status, "index": index, "active": true, "x": float(index), "y": 0.0, "z": 0.0, "yaw": 0.1 * index, "pitch": 0.0, "gait": "walk"}

# ---------------------------------------------------------------------------------------------
# 1. The spotlight on screen.

func test_the_spotlight_line_lock_and_music(t: T) -> void:
	var s := {"stand": {"id": "p2", "since": 10.0, "mult": 1.5}, "hostNow": 12.0}
	t.eq(LastStandView.line_for(s, "p2", NAMES), "LAST ONE UP. YOUR TAPE PAYS X1.5 WHILE YOU STAY THAT WAY", "the survivor reads the bonus")
	t.eq(LastStandView.line_for(s, "p0", NAMES), "ALL CAMERAS ON CY. THE LAST ONE UP", "the others read whom the cameras are on")
	t.eq(LastStandView.line_for({}, "p0", NAMES), "", "no spotlight: no line")
	t.eq(LastStandView.mult_text(1.25), "X1.25", "the number as the host stamped it")
	t.eq(LastStandView.lock_for(s, "p0"), "p2", "an out player's view goes to the survivor")
	t.eq(LastStandView.lock_for(s, "p2"), "", "never to yourself")
	t.check(LastStandView.music_quiet(s, 12.0), "the music is silent while it lasts")
	t.check(not LastStandView.music_quiet({"hostNow": 13.0}, 13.0), "and not after")
	# The watch view, locked: an out player, two crewmates watchable, the lock on the second.
	var w := CrewWatch.new()
	var snap := {"me": {"status": "out"}, "others": [fig("p1", "down", 1), fig("p2", "ok", 2)], "stand": s["stand"]}
	w.update(snap, "p0", NAMES, true, [], false, [], LastStandView.lock_for(snap, "p0"))
	t.check(w.watching and w.watch_id == "p2" and w.locked, "locked on Cy: %s" % str(w.describe()))
	t.check(w.caption.contains("CY") and not w.caption.contains("NEXT"), "the caption offers no next: %s" % w.caption)
	for k in 3:
		w.next()
		w.update(snap, "p0", NAMES, true, [], false, [], LastStandView.lock_for(snap, "p0"))
		t.eq(w.watch_id, "p2", "LEFT CLICK or E does not move it (%d)" % k)
	# The spotlight over: the view is free again and can be moved.
	var free := snap.duplicate()
	free.erase("stand")
	w.update(free, "p0", NAMES, true)
	w.next()
	w.update(free, "p0", NAMES, true)
	t.check(not w.locked and w.watch_id == "p1", "after it, LEFT CLICK moves on: %s" % w.watch_id)

func test_the_music_target_is_silence(t: T) -> void:
	var m: Node = (load("res://client/music.gd") as GDScript).new()
	for i in 80:
		m.drive("floor", "", false)
		m.step(0.05)
	t.eq(m.track, "floor", "on the floor: the bed")
	for i in 80:
		m.drive("floor", "", false, true)
		m.step(0.05)
	t.eq(m.track, "", "the spotlight: no track")
	t.check(float(m.levels["floor"]) == 0.0, "the bed has faded to nothing: %s" % str(m.levels))
	# The wipe's scene on the ride up holds the report's stamp until it is over.
	for i in 40:
		m.drive("lift", "day 1", false, true)
		m.step(0.05)
	t.eq(m.track, "", "the wipe's scene: still silent, the stamp waits")
	for i in 10:
		m.drive("lift", "day 1", false)
		m.step(0.05)
	t.eq(m.track, "report", "after the scene the day's stamp plays")
	m.free()

# ---------------------------------------------------------------------------------------------
# 2. The wipe's scene.

func test_the_timeline(t: T) -> void:
	t.check(WipeScene.LEN <= Run.RIDE_UP_TIME + 1e-9, "the scene (%.1f s) fits in the empty car's ride up (%.1f s): the report waits for nothing" % [WipeScene.LEN, Run.RIDE_UP_TIME])
	t.check(WipeScene.LEN >= 7.5, "about eight seconds")
	t.check(not WipeScene.doors_open(0.0) and not WipeScene.doors_open(WipeScene.OPEN - 0.01), "the empty landing: doors shut as the car arrives")
	t.check(WipeScene.doors_open(WipeScene.OPEN) and WipeScene.doors_open(WipeScene.CLOSE - 0.01), "the doors open")
	var pause := WipeScene.WALK - (WipeScene.OPEN + Lift.DOOR_SECONDS)
	t.check(pause >= 1.5 and pause <= 2.5, "a pause of about two seconds once they are open (%.2f s)" % pause)
	t.check(not WipeScene.doors_open(WipeScene.CLOSE) and WipeScene.CLOSE < WipeScene.RIDE and WipeScene.RIDE < WipeScene.LEN, "the doors close, then it rides up")
	t.eq(WipeScene.fade(0.0), 0.0, "no black at first")
	t.eq(WipeScene.fade(WipeScene.LEN), 1.0, "black at the end")
	var d := 3.0
	var before := WipeScene.figure_local(WipeScene.WALK - 0.01, d, 4.0)
	t.check(not bool(before["show"]), "nothing steps in before the pause is over")
	var inside := WipeScene.figure_local(WipeScene.WALK_END, d, 4.0)
	t.check(bool(inside["show"]) and (inside["pos"] as Vector3).z < -1.0 and str(inside["anim"]) == "idle", "it is in the car: %s" % str(inside))
	var walking := WipeScene.figure_local((WipeScene.WALK + WipeScene.WALK_END) * 0.5, d, 4.0)
	t.eq(str(walking["anim"]), "walk", "it walks in on its walk clip")
	var turned := WipeScene.figure_local(WipeScene.TURN_END, d, 4.0)
	t.check((turned["face"] as Vector3).distance_to(Vector3(0, 0, 1)) < 1e-6, "and turns to face out")
	t.eq(WipeScene.cues().size(), 4, "ding, doors, doors, ride")
	t.check(not WipeScene.playing(null, 5.0) and not WipeScene.playing({}, 5.0), "no block: nothing")
	t.check(WipeScene.playing({"at": 3.0}, 3.0) and WipeScene.playing({"at": 3.0}, 10.9) and not WipeScene.playing({"at": 3.0}, 11.0), "it plays for LEN from the host's time")

func test_two_clients_one_host_event(t: T) -> void:
	# A real wipe: p1 out, the Orderly catches p0, down, out.
	var got := PropLastStand.caught_wipe("ls1-wipe-0", true)
	var s: Run.RunState = got[0]
	t.check(not (got[1] as Array).is_empty(), "the seed wipes")
	var net := Transport.MemoryNetwork.new("ls1-scene")
	var host := Host.new(net.connect_peer("host"), "ls1-wipe-0", PropLastStand.ids_of(2), 0.0)
	host.state = s
	var wire := Protocol.world_json(host.world())
	var a := Protocol.dec_world(Protocol._V.new(), JSON.parse_string(wire))
	var b := Protocol.dec_world(Protocol._V.new(), JSON.parse_string(wire))
	t.check(a.get("wipe") is Dictionary and str(a["wipe"]["by"]) == "orderly" and str(a["wipe"]["last"]) == "p0", "it names the Orderly, and p0: %s" % str(a.get("wipe")))
	t.eq(a.get("standee"), "p0", "and the standee is p0")
	var plan := s.plan
	var car := Run.car_geometry(plan)
	var xf := Transform3D(Basis(Vector3(car.right_x, 0, car.right_z), Vector3.UP, -Vector3(car.in_x, 0, car.in_z)), Vector3(car.door_x, car.floor_y, car.door_z))
	var d := WipeScene.landing_depth(plan, xf, plan.landing.level)
	t.check(d >= WipeScene.CAM_NEAR and d <= WipeScene.CAM_FAR, "the camera stands on the landing (%.2f m out)" % d)
	var at := float(a["wipe"]["at"])
	var same := 0
	for k in 33:
		var hn := at + k * 0.25
		var fa := WipeScene.frame_at(a["wipe"], hn, d, Run.CAR_DEPTH, false)
		var fb := WipeScene.frame_at(b["wipe"], hn, d, Run.CAR_DEPTH, false)
		if str(fa) == str(fb):
			same += 1
		else:
			t.check(false, "at %.2f s the two screens differ: %s / %s" % [k * 0.25, str(fa), str(fb)])
	t.eq(same, 33, "every quarter second of the scene is the same on both screens")
	t.check(not bool(WipeScene.frame_at(a["wipe"], at + 2.0, d, Run.CAR_DEPTH, false)["figure"]), "nothing in the doorway during the pause")
	t.check(bool(WipeScene.frame_at(a["wipe"], at + 5.0, d, Run.CAR_DEPTH, false)["figure"]), "the Orderly steps in")

func test_the_figure_and_the_fallbacks(t: T) -> void:
	for by: String in ["orderly", "temp", "minder", "groundskeeper"]:
		t.check(WipeScene.shows_figure(by, false), "%s walks in" % by)
	for by: String in ["four", "rigger", ""]:
		t.check(not WipeScene.shows_figure(by, false), "%s: black with the lift's sounds" % by)
	t.check(not WipeScene.shows_figure("orderly", true), "the Ward drawn natively: black")
	var w := {"at": 0.0, "by": "four", "n": 1}
	t.eq(float(WipeScene.frame_at(w, 1.0, 2.4, 4.0, false)["fade"]), 1.0, "the fallback is black from the start")
	# The Orderly's real figure, in a real lift on a real Clinic floor, walking into the car.
	var tree := Engine.get_main_loop() as SceneTree
	var plan := Places.generate("ls1-figure", 1, Places.FULL)
	var lift := Lift.new()
	tree.root.add_child(lift)
	lift.build(RulesBridge._car_plain(Run.car_geometry(plan)))
	var cam := Camera3D.new()
	tree.root.add_child(cam)
	var scene := WipeScene.new()
	tree.root.add_child(scene)
	var lv := Level.new()
	scene.begin({"at": 100.0, "depth": 1, "day": 1, "by": "orderly", "n": 2, "last": "p0"}, plan, lv, lift, "ls1-figure", [] as Array[String], false)
	t.check(scene.figure is OrderlyView, "the Orderly's own view: %s" % str(scene.figure))
	var f := scene.show_at(105.0, cam, lift, null)
	t.check(scene.figure.visible and bool(f["figure"]), "drawn as it walks in")
	var local := lift.to_local(scene.figure.global_position)
	t.check(local.z < 2.0 and local.z > -Run.CAR_DEPTH, "between the landing and the back of the car (car-local z %.2f)" % local.z)
	scene.show_at(100.0 + WipeScene.TURN_END, cam, lift, null)
	local = lift.to_local(scene.figure.global_position)
	t.check(local.z < -1.0, "in the car when the doors close (z %.2f)" % local.z)
	var c := lift.to_local(cam.global_position)
	t.check(c.z > 1.0, "the camera stands out on the landing (z %.2f)" % c.z)
	scene.end()
	t.check(scene.figure == null, "the scene's figure goes with it")
	scene.free()
	cam.free()
	lift.free()
	lv.free()

# ---------------------------------------------------------------------------------------------
# 3. The standee.

func test_the_standee_on_both_clients(t: T) -> void:
	var face := FaceCodec.encode(Paint.starter("smile"))
	# Client A has p0's face from the host's "F"; client B is p0 and has its own.
	var faces_a := {"p0": face, "p1": ""}
	var a := Standee.new()
	a.build(str(faces_a["p0"]), "ANN")
	var b := Standee.new()
	b.build(face, "ANN")
	var want := CrewView.texture_hash(FaceCodec.decode(face))
	t.check(a.face_hash() == want and b.face_hash() == want and want != "", "both show p0's own face (%s)" % want)
	var plain := Standee.new()
	plain.build("", "BOB")
	t.eq(plain.face_hash(), CrewView.texture_hash(CrewView.default_face()), "no face drawn: the plain default face")
	t.check(plain.face_hash() != want, "and not someone else's")
	a.free()
	b.free()
	plain.free()
	# In the prison: by the lift, and the next wipe's player replaces it.
	var pp := Prison.prison_plan()
	var level := Level.new()
	level.build(PlanDump.dump(pp, Run.car_geometry(pp)), "ls1-prison")
	var pv: PrisonView = level.get_meta(&"prison")
	pv.show_standee(face, "ANN")
	var first: Node3D = pv.standee
	t.check(first != null and first.call(&"face_hash") == want, "the prison's standee wears Ann's face")
	var lobby := level.cell_center(0, Prison.LANDING_CELL.x, Prison.LANDING_CELL.y)
	t.check(Vector2(first.position.x - lobby.x, first.position.z - lobby.z).length() < Prison.CELL_SIZE, "in the lift lobby (%s)" % str(first.position))
	pv.show_standee(face, "ANN")
	t.check(pv.standee == first, "the same standee is kept frame to frame")
	pv.show_standee("", "BOB")
	t.check(pv.standee != first and pv.standee.call(&"face_hash") == CrewView.texture_hash(CrewView.default_face()) and str(pv.standee.get("player_name")) == "BOB",
		"the next wipe's player replaces it")
	level.free()
