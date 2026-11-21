# CS1: each resident's own caught scene on the caught player's screen (client/caught_scene.gd, started by client/main.gd).
# The owner, 21 Nov: "Can we also make custom caught screens for each resident?  Frightening jump scare style?"
#   1. Every resident the host can send a catch for has its own scene, started by the catch event on the caught
#      player's screen: the Orderly (Clinic), the Temp (Annex), the Minder (Playroom), the Groundskeeper (Arboretum) and
#      the Reactor's crew, each with its own model file and its own clip.
#   2. The scene is the real 3D figure (a skinned model under a Skeleton3D, no sprite), in front of the camera.
#   3. It ends within about 1.2 s, and then the downed state (the ring) shows: the catch's picture window with a scene
#      and the down rule is the scene's own length; without a scene it is the black cut and the noise as before.
#   4. Only the caught player's screen and an out player watching them through their eyes play it; anyone else none.
#   5. It plays the same frames from the event's arrival, whatever the delay.
#   6. CAUGHT SCENES: SOFT keeps the scene without the camera snap or shove, the flash and noise halved; saved locally.
#   7. The Hanging Ward: nothing new plays (its web sequence is the Rigger's catch).
#   8. The Minder takes a found player when its own mode is catch or grab, not at the found event from afar.
extends RefCounted

const T = preload("res://tests/t.gd")
const CaughtScene = preload("res://client/caught_scene.gd")
const CaughtPref = preload("res://client/caught_pref.gd")
const Main = preload("res://client/main.gd")
const DownView = preload("res://client/down_view.gd")
const PDR = preload("res://tests/prop_down_ring.gd")
const SettingsPanel = preload("res://client/settings_panel.gd")

## The owner's limit: the downed state never hidden beyond about 1.2 s.
const LIMIT_MS := 1200
const PLACES := {"clinic": "orderly", "annex": "temp", "playroom": "minder", "arboretum": "keeper", "reactor": "crew"}

## A camera and a scene in the running tree (the Reactor's figure loads on entering it).
static func _rig() -> Array:
	var holder := Node3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(holder)
	var cam := Camera3D.new()
	cam.fov = Main.VFOV
	cam.near = 0.05
	holder.add_child(cam)
	cam.position = Vector3(1.0, 1.5, 2.0)
	cam.rotation = Vector3(0.0, 0.6, 0.0)
	var scene := CaughtScene.new()
	holder.add_child(scene)
	holder.add_child(scene.overlay)
	return [holder, cam, scene]

static func _caught(id: String) -> Dictionary:
	return {"type": "caught", "t": 10.0, "playerId": id}

func test_every_catching_resident_has_its_own_scene(t: T) -> void:
	var rig := _rig()
	var scene: CaughtScene = rig[2]
	var models := {}
	for place: String in PLACES:
		var kind := Main.caught_scene_kind(_caught("me"), "me", "", place, {"depth": 2})
		t.eq(kind, PLACES[place], "%s: a catch of mine starts the %s's scene" % [place, PLACES[place]])
		t.check(scene.start(kind, 5000, true), "%s: the scene starts" % kind)
		var d := scene.describe(5000)
		t.check(bool(d["on"]) and d["kind"] == kind, "%s: on from the event's first frame (%s)" % [kind, d])
		t.eq(str(d["model"]), CaughtScene.path_for(kind), "%s: the figure its world view draws" % kind)
		t.check((CaughtScene.CLIPS[kind] as Array).has(str(d["clip"])), "%s: its own clip (%s)" % [kind, d["clip"]])
		models[str(d["model"])] = true
		scene.stop()
	t.eq(models.size(), 5, "five residents, five different figures")
	(rig[0] as Node).free()

func test_the_scene_is_the_real_3d_figure_in_front_of_the_camera(t: T) -> void:
	var rig := _rig()
	var cam: Camera3D = rig[1]
	var scene: CaughtScene = rig[2]
	for kind: String in CaughtScene.KINDS:
		scene.start(kind, 0, true, {"seat": 3})
		var seen := 0
		for ms in range(0, CaughtScene.LENGTH_MS, 50):
			scene.step(ms, cam)
			var d := scene.describe(ms)
			if bool(d["shown"]):
				seen += 1
				var f: Dictionary = scene._figures[kind]
				var face := (f["root"] as Node3D).global_transform * scene._face_point(f)
				# The Minder drops in from above and the crew rise from the floor: in the picture from 300 ms on.
				if ms >= 300:
					t.check(cam.is_position_in_frustum(face) and face.distance_to(cam.global_position) < 2.0,
						"%s at %d ms: its face is in front of the lens (%.2f m)" % [kind, ms, face.distance_to(cam.global_position)])
				t.check(int(d["skinned"]) >= 1 and int(d["flat"]) == 0, "%s: a skinned 3D model, no sprite (%s)" % [kind, d])
		t.check(seen >= 8, "%s: the figure is on screen for most of the scene (%d frames)" % [kind, seen])
		t.check(scene.figure != null and scene.figure.find_children("*", "Skeleton3D", true, false).size() >= 1, "%s: under a skeleton" % kind)
		scene.stop()
		t.check(scene.figure == null and not scene._light.visible, "%s: nothing left on screen after it" % kind)
	(rig[0] as Node).free()

func test_it_ends_in_time_and_the_ring_shows(t: T) -> void:
	var rig := _rig()
	var cam: Camera3D = rig[1]
	var scene: CaughtScene = rig[2]
	var window := Main.catch_window_ms(true, true)
	t.check(window <= LIMIT_MS, "with a scene and the down rule the catch holds the picture %d ms (limit %d)" % [window, LIMIT_MS])
	t.eq(Main.catch_window_ms(false, true), Main.BLACK_MS + Main.NOISE_MS, "no scene: the black cut and the noise as before")
	t.eq(Main.catch_window_ms(true, false), Main.BLACK_MS + Main.NOISE_MS, "no down rule: as before")
	var dv := DownView.new()
	var names := {"a": "Ann", "b": "Bob"}
	for kind: String in CaughtScene.KINDS:
		scene.start(kind, 1000, true)
		var ended := -1
		for ms in range(1000, 1000 + 3000, 16):
			var r := scene.step(ms, cam)
			if not bool(r["on"]):
				ended = ms - 1000
				break
		t.check(ended > 0 and ended <= LIMIT_MS and ended <= window + 16, "%s: the scene ended at %d ms" % [kind, ended])
		# The frame it ends: the catch's window is over, so the down timer is shown (main.gd _show_down: not noise).
		var noise := ended < window
		dv.update(PDR.snap_at(100.0 + ended / 1000.0, 30.0), "a", names, false)
		var head := dv.head if not noise else ""
		t.check(head.begins_with("DOWN") and dv.left > 0.9, "%s: at %d ms the down ring shows (%s, %.2f)" % [kind, ended, head, dv.left])
	(rig[0] as Node).free()

func test_only_the_caught_player_and_whoever_watches_them(t: T) -> void:
	t.eq(Main.caught_scene_kind(_caught("bob"), "me", "", "clinic", {"depth": 2}), "", "a crewmate's catch: no scene on my screen")
	t.eq(Main.caught_scene_kind(_caught("bob"), "me", "bob", "clinic", {"depth": 2}), "orderly", "out and watching Bob: his scene")
	t.eq(Main.caught_scene_kind(_caught("bob"), "me", "cy", "annex", {"depth": 2}), "", "watching Cy: not Bob's")
	t.eq(Main.caught_scene_kind(_caught(""), "me", "", "clinic", {"depth": 2}), "", "no player: none")
	var rig := _rig()
	var scene: CaughtScene = rig[2]
	scene.start("orderly", 0, false)
	t.check(not scene.snaps(), "watching: the camera is not snapped (it is the crewmate's)")
	scene.stop()
	scene.start("orderly", 0, true)
	t.check(scene.snaps(), "my own, FULL: the camera snaps round to it")
	(rig[0] as Node).free()

func test_it_plays_the_same_on_any_delay(t: T) -> void:
	var rig := _rig()
	var cam: Camera3D = rig[1]
	var scene: CaughtScene = rig[2]
	for kind: String in CaughtScene.KINDS:
		var runs: Array = []
		for arrived: int in [2000, 2350, 9100]:
			scene.start(kind, arrived, true)
			var frames: Array = []
			for ms in range(0, CaughtScene.LENGTH_MS + 50, 40):
				scene.step(arrived + ms, cam)
				var d := scene.describe(arrived + ms)
				frames.append([d["on"], d["shown"], snappedf(float(d["dist"]), 1e-6), snappedf(float(d["snow"]), 1e-6), snappedf(float(d["flash"]), 1e-6), snappedf(float(d["black"]), 1e-6)])
			runs.append(frames)
			scene.stop()
		t.check(runs[0] == runs[1] and runs[0] == runs[2], "%s: the same frames from the event's arrival whatever the delay" % kind)
	(rig[0] as Node).free()

func test_soft_keeps_the_scene_without_the_snap_and_halves_flash_and_noise(t: T) -> void:
	var rig := _rig()
	var cam: Camera3D = rig[1]
	var scene: CaughtScene = rig[2]
	for kind: String in CaughtScene.KINDS:
		var full_shove := 0.0
		var peaks := {}
		for soft: bool in [false, true]:
			scene.soft = soft
			scene.start(kind, 0, true)
			t.check(scene.snaps() != soft, "%s soft %s: the snap" % [kind, str(soft)])
			for ms in range(0, CaughtScene.LENGTH_MS, 20):
				scene.step(ms, cam)
				var d := scene.describe(ms)
				var key := "%d" % ms
				if not soft:
					full_shove = maxf(full_shove, Vector2(d["shove"][0], d["shove"][1]).length())
					peaks[key] = [d["snow"], d["glitch"], d["flash"], d["bar"], d["shown"]]
				else:
					var f: Array = peaks[key]
					t.check(is_equal_approx(float(d["snow"]), float(f[0]) * 0.5) and is_equal_approx(float(d["glitch"]), float(f[1]) * 0.5)
						and is_equal_approx(float(d["flash"]), float(f[2]) * 0.5) and is_equal_approx(float(d["bar"]), float(f[3]) * 0.5),
						"%s soft at %d ms: the noise, flash and bar halved (%s against %s)" % [kind, ms, [d["snow"], d["glitch"], d["flash"], d["bar"]], f])
					t.check(Vector2(d["shove"][0], d["shove"][1]) == Vector2.ZERO, "%s soft at %d ms: no shove" % [kind, ms])
					t.eq(d["shown"], f[4], "%s soft at %d ms: the same figure on screen" % [kind, ms])
			scene.stop()
		t.check(full_shove > 0.005, "%s full: the camera is shoved (%.3f m)" % [kind, full_shove])
	scene.soft = false
	# The setting: FULL by default, SOFT saved and read back on this computer, never under automation.
	var path := "user://test_caught_pref.cfg"
	var pref := CaughtPref.new()
	pref.save_path = path
	pref.load_saved()
	t.check(not pref.soft and pref.text() == "FULL", "FULL by default")
	pref.set_soft(true)
	pref.save()
	var again := CaughtPref.new()
	again.save_path = path
	again.load_saved()
	t.check(again.soft and again.text() == "SOFT", "SOFT read back")
	var auto := CaughtPref.new()
	auto.save_path = path
	auto.persist = false
	auto.load_saved()
	t.check(not auto.soft, "an automated run plays FULL whatever is saved")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# The panel's row on the player's own page.
	var panel := SettingsPanel.new()
	var p2 := CaughtPref.new()
	p2.persist = false
	panel.caught_pref = p2
	t.check(panel.caught_set(true) and p2.soft, "the panel sets SOFT")
	t.eq(str(panel.describe()["sound"]["caught"]), "SOFT", "the page says SOFT")
	t.check(panel.caught_set(false) and not p2.soft, "and FULL again")
	panel.free()
	(rig[0] as Node).free()

func test_nothing_new_on_the_hanging_ward(t: T) -> void:
	var native := {"depth": 6, "ward": {"native": true, "phase": "open", "caught": ["me"]}}
	var swapped := {"depth": 6, "ward": {"native": false}}
	for place: String in ["clinic", "ward", ""]:
		t.eq(Main.caught_scene_kind(_caught("me"), "me", "", place, native), "", "the native Ward (place %s): no scene, the web is its catch" % place)
		t.eq(Main.caught_scene_kind(_caught("me"), "me", "", place, swapped), "", "the Ward's own room (place %s): no scene" % place)
	for place: String in ["prison", "orientation", "ward", "reactor_old", ""]:
		t.eq(CaughtScene.kind_for(place), "", "%s: no resident scene" % place)
	t.eq(CaughtScene.kind_for("clinic", true), "", "kind_for with the Ward: none")
	var rig := _rig()
	var scene: CaughtScene = rig[2]
	t.check(not scene.start("", 0) and not scene.start("rigger", 0) and not scene.playing(0), "no scene can start for the Rigger")
	(rig[0] as Node).free()

func test_the_minder_takes_when_it_reaches_you(t: T) -> void:
	var s := {"mySeek": {"status": "found"}, "orderly": {"mode": "run"}}
	t.check(not Main.minder_takes_now(s), "found, it is still running at you: not yet")
	s["orderly"] = {"mode": "catch"}
	t.check(Main.minder_takes_now(s), "found and it catches: now")
	s["orderly"] = {"mode": "grab"}
	t.check(Main.minder_takes_now(s), "grabbed outside a count: now")
	s["mySeek"] = {"status": "ok"}
	t.check(not Main.minder_takes_now(s), "not found: never")
	t.check(not Main.minder_takes_now({"orderly": {"mode": "catch"}}), "no seek row: never")

func test_the_temps_ink_runs_from_the_eyes(t: T) -> void:
	var page := CaughtScene.TempView.photocopy(CaughtScene.TempView.blank_face(), "cs1-ink")
	var dark := func(img: Image) -> int:
		var n := 0
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).get_luminance() < 0.15:
					n += 1
		return n
	var a: int = dark.call(CaughtScene.ink_run(page, 0.3))
	var b: int = dark.call(CaughtScene.ink_run(page, 1.0))
	var base: int = dark.call(page)
	t.check(a > base and b > a, "the ink runs further over the scene (%d, %d, %d dark pixels)" % [base, a, b])
	t.check(CaughtScene.ink_run(page, 0.65).get_data() == CaughtScene.ink_run(page, 0.65).get_data(), "the same page runs the same")

## LS1 with CS1: the wipe's scene waits for a caught scene on this screen, the caught player's own (caught_at) and
## the one an out player sees watching the crewmate who is caught (no caught_at on that screen: only the scene).
func test_the_wipe_waits_for_the_caught_scene(t: T) -> void:
	t.check(Main.CATCH_KEEP_MS > CaughtScene.LENGTH_MS, "the wipe's hold (%d ms) is longer than the scene (%d ms)" % [Main.CATCH_KEEP_MS, CaughtScene.LENGTH_MS])
	t.check(Main.wipe_held(1000, 1000, 1000 + CaughtScene.LENGTH_MS - 1), "the caught player: held while the scene plays")
	t.check(not Main.wipe_held(1000, -1, 1000 + Main.CATCH_KEEP_MS), "the caught player: the wipe plays after the hold")
	t.check(Main.wipe_held(-1, 5000, 5000), "a watcher: held as the watched crewmate's scene starts")
	t.check(Main.wipe_held(-1, 5000, 5000 + CaughtScene.LENGTH_MS - 1), "a watcher: held while that scene plays")
	t.check(not Main.wipe_held(-1, -1, 5000), "no catch and no scene: the wipe plays at once")
	t.check(not Main.wipe_held(-1, 5000, 5000 + Main.CATCH_KEEP_MS), "a watcher: the wipe plays after the hold")
