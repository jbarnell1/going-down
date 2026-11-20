# WF3: the Hanging Ward on screen is the same game as floors 1 to 5. The owner: "the last two floors open
# separate games?", "The last two levels are extremely messy....", and chose "Ward look and HUD".
#   1. the picture: the Ward is drawn at 480x270 through client/tape.gdshader (client/main.gd make_picture,
#      make_screen), words and the Esc card crisp over it, the Rigger's warning heard from inside the picture;
#   2. the HUD: client/hud.gd, fed the Ward's lines (LIFT RETURNS IN m:ss under PLAY, STEP OUT OF THE LIFT as the
#      prompt), the tapes on the counter, the instrument drawn into the picture (client/instrument_view.gd);
#   3. crewmates: client/others_view.gd crew figures with faces and name tags (client/main.gd name_tag);
#   4. the camera drops when you creep (client/eye_height.gd).
# The Ward is entered as the game enters it (test_ward_exit.gd _enter), from the game's own files.
extends RefCounted

const T = preload("res://tests/t.gd")
const Exit = preload("res://tests/test_ward_exit.gd")
const Main = preload("res://client/main.gd")
const Client = preload("res://net/client.gd")
const Move = preload("res://sim/move.gd")
const EyeHeight = preload("res://client/eye_height.gd")

func _ward(t: T) -> Dictionary:
	return Exit.new()._enter(t)

func test_the_ward_is_drawn_through_the_tape(t: T) -> void:
	var w := _ward(t)
	if w.is_empty():
		return
	var scene: Node = w.scene
	var picture: SubViewport = scene.get("picture")
	var screen: TextureRect = scene.get("screen")
	t.eq(picture.size, Vector2i(480, 270), "the picture is every floor's 480x270")
	t.check(picture.msaa_3d == Viewport.MSAA_DISABLED and picture.audio_listener_enable_3d, "with the main game's picture settings")
	t.check(w.view.get_viewport() == picture, "the Ward's world is drawn into that picture")
	t.check(w.view.camera.get_viewport() == picture and w.view.watch_camera.get_viewport() == picture, "from the player's camera (and a watcher's)")
	t.check(screen.texture == picture.get_texture() and (screen.material as ShaderMaterial).shader == load("res://client/tape.gdshader"), "shown through the tape look")
	t.check(screen.material == scene.get("tape_mat"), "the brightness and the out-of-breath dark are set on that same tape")
	var root := (Engine.get_main_loop() as SceneTree).root
	t.check(scene.get("hud").get_viewport() == root and scene.get("card").get_viewport() == root, "the HUD's words and the Esc card stay crisp over the tape, at window size")
	t.check(w.view.load_sound.get_viewport() == picture, "the Rigger's loaded line is heard in the picture's world (its listener is the camera)")
	var screen_layer := screen.get_parent() as CanvasLayer
	t.check(screen_layer != null and screen_layer.layer < 1, "the tape sits under the HUD (%d)" % (screen_layer.layer if screen_layer != null else 99))
	Exit._leave(w)

func test_the_ward_has_the_main_games_hud(t: T) -> void:
	var w := _ward(t)
	if w.is_empty():
		return
	var scene: Node = w.scene
	var hud: Hud = scene.get("hud")
	Exit._frame(scene)
	t.eq(hud.prompt, "STEP OUT OF THE LIFT", "in the lift, the HUD's prompt says to step out")
	t.eq(hud.tenant_line, "", "with no clock yet: it starts when the lift leaves the crew")
	t.check(hud.osd_on and hud.end_lines.is_empty(), "the camcorder's display (PLAY, the counter) is up")
	t.check(not (w.view.hud.get_parent() as CanvasLayer).visible, "the Ward's own plain labels are not drawn")
	Exit._walk_out(w, KEY_W)
	Exit._frame(scene)
	t.check(hud.tenant_line.begins_with("LIFT RETURNS IN "), "out of the lift: LIFT RETURNS IN under PLAY: " + hud.tenant_line)
	t.check(hud.tenant_line == "LIFT RETURNS IN 10:00" or hud.tenant_line.begins_with("LIFT RETURNS IN 9:"), "the design's ten minutes: " + hud.tenant_line)
	# WN1: the clock is read on the room's own time (a room on this machine runs on virtual time; reading host time
	# off the process's clock put the line minutes out, by however long the game had been open).
	var parts := hud.tenant_line.trim_prefix("LIFT RETURNS IN ").split(":")
	var shown := int(parts[0]) * 60 + int(parts[1]) if parts.size() == 2 else -1
	var room: Variant = w.room
	var left := float(room.client.latest.ward.collectionAt) - float(room.host.state.t)
	t.note("clock %s, host says %.1f s left; process clock %.1f s ahead of the room's" % [hud.tenant_line, left, Time.get_ticks_usec() / 1000000.0 - float(room._now)])
	t.check(absf(float(shown) - left) <= 2.0, "the line is the host's time left (%d against %.1f s)" % [shown, left])
	t.check(not hud.tenant_warn, "not yet in the warning colour")
	t.eq(hud.prompt, "", "and no prompt once out")
	# The instrument, drawn into the picture: E raises it, as on every floor.
	var inst: InstrumentView = scene.get("inst_view")
	t.check(inst.get_viewport() == scene.get("picture"), "the instrument is drawn into the picture, under the tape")
	scene._unhandled_input(Exit._press(KEY_E))
	for i in 30:
		Exit._frame(scene)
	t.check(inst.raise > 0.9, "E brings the instrument up on screen (%.2f)" % inst.raise)
	scene._unhandled_input(Exit._press(KEY_E))
	Exit._leave(w)

func test_crewmates_are_the_crew_figures_with_faces_and_tags(t: T) -> void:
	var w := _ward(t)
	if w.is_empty():
		return
	var scene: Node = w.scene
	Exit._walk_out(w, KEY_W)
	Exit._frame(scene)
	var room: Variant = w.room
	var view: Node3D = w.view
	var cam: Camera3D = view.camera
	# A crewmate 1.5 m in front of the camera, as the frame interpolates them.
	var ahead := cam.global_position - cam.global_transform.basis.z * 1.5
	var frame := Client.Frame.new()
	var feet := Vector3(ahead.x, view.player.position.y, ahead.z)
	frame.players = [{"id": "p2", "body": Move.Body.make(feet.x, feet.z, 0, feet.y), "yaw": 0.0, "pitch": 0.0, "gait": "walk", "status": "ok", "active": true}]
	var world := {"players": [{"id": "me"}, {"id": "p2"}], "crew": [{"id": "p2", "raised": true}]}
	var rows: Array = scene.crew_rows(world, {"caught": []}, frame, room.client, {"p2": "Bob"})
	t.eq(rows.size(), 1, "one crewmate row")
	var others: OthersView = scene.get("others")
	others.update(1.0 / 60.0, rows, cam.global_position)
	var fig := others.describe("p2")
	t.check(not fig.is_empty() and fig.drawn, "the crewmate is the crew figure, drawn")
	t.check(others.get_viewport() == scene.get("picture"), "in the Ward's picture")
	t.check(fig.get("raised", false) and int(fig.get("index", -1)) == 1, "with the instrument up and dressed as crew number 2")
	# The Ward's view is told of the crewmate as the snapshot lists them, and draws no grey capsule for them.
	view._show_crew([{"id": "p2", "connected": true, "body": Move.Body.make(feet.x, feet.z, 0, feet.y)}], "me")
	t.check(view.peers.is_empty(), "and no grey capsule")
	# Walking: the figure plays a moving clip, as on every floor.
	for i in 20:
		feet.z += 3.0 / 60.0
		frame.players[0]["body"] = Move.Body.make(feet.x, feet.z, 0, feet.y)
		others.update(1.0 / 60.0, scene.crew_rows(world, {"caught": []}, frame, room.client, {"p2": "Bob"}), cam.global_position)
	fig = others.describe("p2")
	t.check(float(fig.speed) > 1.0, "walking, the figure moves at their pace (%.2f m/s, clip %s)" % [float(fig.speed), fig.clip])
	# Caught by the hand: lying as a caught player does on every floor.
	rows = scene.crew_rows(world, {"caught": ["p2"]}, frame, room.client, {"p2": "Bob"})
	t.eq(str(rows[0].status), "caught", "a player the hand caught is caught")
	# The name tag, over the head, from the main game's tag (client/main.gd name_tag) with the Ward's walls.
	feet = Vector3(ahead.x, view.player.position.y, ahead.z)
	frame.players[0]["body"] = Move.Body.make(feet.x, feet.z, 0, feet.y)
	rows = scene.crew_rows(world, {"caught": []}, frame, room.client, {"p2": "Bob"})
	var tag := Main.name_tag(rows[0], cam, Vector2(1920, 1080), false, func(_at: Vector3, _level: int) -> bool: return true)
	t.eq(str(tag.get("text", "")), "BOB", "the name tag reads BOB")
	# The scene's own frame path: the frame's crewmates become figures and HUD tags (names from the room's people).
	var ward: Dictionary = room.client.latest.ward
	# A headless window is 64 pixels square; tags are placed for a real one.
	scene.set("tag_window", Vector2(1920, 1080))
	scene._show_hud(world, ward, room.client, frame, Time.get_ticks_usec() / 1000000.0, 1.0 / 60.0)
	var hud: Hud = scene.get("hud")
	var texts: Array = hud.tags.map(func(g: Dictionary) -> String: return str(g["text"]))
	t.check(texts.has("P2"), "the scene puts the crewmate's tag on the HUD, seen past the Ward's walls: %s" % [texts])
	t.check(others.describe("p2").drawn, "and draws their figure")
	Exit._leave(w)

func test_the_camera_drops_when_you_creep(t: T) -> void:
	var w := _ward(t)
	if w.is_empty():
		return
	var scene: Node = w.scene
	var view: Node3D = w.view
	Exit._frame(scene)
	t.check(is_equal_approx(view.camera.position.y, EyeHeight.STAND), "standing, the eyes are where they are on every floor")
	Exit._key(KEY_CTRL, true)
	for i in 30:
		Exit._frame(scene)
	t.check(is_equal_approx(view.camera.position.y, EyeHeight.CREEP), "creeping, the camera drops to the creep height")
	Exit._key(KEY_CTRL, false)
	for i in 30:
		Exit._frame(scene)
	t.check(is_equal_approx(view.camera.position.y, EyeHeight.STAND), "and comes back up")
	Exit._leave(w)
