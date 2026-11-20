# IP1: the Hanging Ward and the Reactor ship everything they need inside the game, like every other floor. The
# owner, 20 Nov: "We don't want the extra packs. It should be fully integrated into the game like everything else."
# Nothing here mounts a pack or reads GD_PACKS_DIR; each test runs on a plain checkout.
#   1. The Ward: the Rigger's figure (assets/ward/rigger.glb) and his hand (assets/ward/search-hand.glb), built by
#      assets_src/blender/rigger/build_rigger.py, load and are placed in a Ward built from a seed; the Ward's lines and
#      the loaded line's sound load.
#   2. The Reactor: the four's crawl and run (assets/station/crew_zombie.glb) resolve on the crew skeleton, their four
#      face drawings (assets/station/faces/) are present, and the recovered tape plays from the game's files.
#   3. No code names either old pack file, and no floor mounts a pack.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/ward/view.gd")
const House = preload("res://sim/ward/house.gd")
const Ward = preload("res://sim/ward/state.gd")
const Crew = preload("res://client/station_crew_view.gd")
const Faces = preload("res://client/station_faces.gd")
const Screening = preload("res://client/reactor_screening.gd")

## Nothing from the old packs is mounted in this process: their own files are not in res://.
static func _no_pack(t: T) -> void:
	for path: String in ["res://crew23_motion.glb", "res://reactor_campaign.tscn", "res://faces/seat-1.png", "res://reactor_media/crew23.ogv"]:
		t.check(not ResourceLoader.exists(path), "no pack is mounted (%s is not in the game)" % path)

# --- 1. The Ward. ---

func test_the_riggers_figure_and_hand_are_placed_in_a_ward_with_no_pack(t: T) -> void:
	_no_pack(t)
	var tree := Engine.get_main_loop() as SceneTree
	# FD1: this checks the old rigger.glb (its many parts, RIGGER_WRIST), so it draws the old figure;
	# tests/test_rigger_v2.gd places the new one the same way.
	Figures.override = "old"
	var view := View.new(8143, Vector3.ZERO)
	Figures.override = ""
	view.own_hud = false
	tree.root.add_child(view)
	if not t.check(view.rigger != null and view.hand != null, "the Rigger and his hand are built from the game's files"):
		view.free()
		return
	var meshes := view.rigger.find_children("*", "MeshInstance3D", true, false)
	t.check(meshes.size() > 100, "the Rigger is a full 3D figure (%d mesh parts)" % meshes.size())
	t.check(view.animation != null and view.animation.has_animation(view.climb_animation) and str(view.climb_animation).contains("Rigger Climb"),
		"his climb clip is there (%s)" % view.climb_animation)
	t.check(view.hand.find_child("Wrist", true, false) != null, "the hand carries its wrist marker")
	t.check(view.hand.find_children("*", "MeshInstance3D", true, false).size() == 1, "the hand is one mesh")
	t.check(view.load_sound.stream != null, "the loaded line's sound loads (%s)" % View.WARNING_PATH)
	# A search under way in house 0: the body hangs at the shoulder, the hand at the arm's last point.
	var room: Dictionary = view.houses[0]
	var fixture: House = room.fixture
	var shoulder := fixture.to_world(fixture.shoulder)
	var reach := fixture.to_world(fixture.shoulder + Vector3(0, -0.4, 1.0))
	var tip := fixture.to_world(fixture.shoulder + Vector3(0, -0.6, 2.0))
	var ward := {"encounter": "searching", "house": 0, "startedAt": 0.0,
		"armPoints": [[reach.x, reach.y, reach.z], [tip.x, tip.y, tip.z]]}
	view._show_rigger(ward, Ward.WARN_SECONDS + Ward.CLIMB_SECONDS + 5.0)
	t.check(view.rigger.visible and view.rigger.is_inside_tree(), "the Rigger is shown while he searches")
	var wrist := view.rigger.position + view.rigger.basis * View.RIGGER_WRIST
	t.check(wrist.distance_to(shoulder) < 0.01, "his forward wrist is at the house's shoulder (%.3f m off)" % wrist.distance_to(shoulder))
	t.check(view.hand.visible and view.hand.position.distance_to(tip) < 0.01, "the hand is at the end of the arm (%.3f m off)" % view.hand.position.distance_to(tip))
	view.free()

func test_the_wards_lines_ship_in_the_game(t: T) -> void:
	for cue: String in ["ward_lift_departed", "ward_lift_last_minute", "ward_lift_returned", "ward_lift_final_call", "ward_lift_closed"]:
		var path := "res://assets/ward/voice/bella/%s.mp3" % cue
		var stream: AudioStream = load(path) if ResourceLoader.exists(path) else null
		t.check(stream != null and stream.get_length() > 1.0, "%s loads (%.2f s)" % [path, stream.get_length() if stream != null else 0.0])

# --- 2. The Reactor. ---

func test_the_fours_crawl_and_run_resolve_on_the_crew_skeleton_with_no_pack(t: T) -> void:
	_no_pack(t)
	var tree := Engine.get_main_loop() as SceneTree
	var probe := CrewView.new()
	tree.root.add_child(probe)
	var lib := Crew.zombie_library(probe)
	if t.check(lib != null, "the two clips load from %s and every track resolves on the crew skeleton" % Crew.ZOMBIE_MOTION):
		for name: String in Crew.ZOMBIE_CLIPS:
			var a := lib.get_animation(name)
			t.check(a != null and a.get_track_count() >= 20 and a.length > 0.5, "%s: %d tracks, %.2f s" % [name, a.get_track_count() if a else 0, a.length if a else 0.0])
			t.eq(a.loop_mode if a else -1, Animation.LOOP_LINEAR, "%s loops" % name)
	# Were the file missing (the owner's fallback), the library is null and the four play the rig's own clips.
	t.check(Crew.zombie_library(probe, "res://assets/station/not-there.glb") == null, "no file: no library, no error")
	probe.free()
	var keep := Crew.zombie_motion
	Crew.zombie_motion = false
	var crew := Crew.new()
	tree.root.add_child(crew)
	t.check(not crew.zombie_clips, "without the downloaded clips")
	t.eq(crew.clip_for("crawling"), "crawl", "the four crawl with the rig's own crawl")
	t.eq(crew.clip_for("pursuing"), "run", "and run with its own run")
	for v: CrewView in crew.figures:
		t.check(v.ap.has_animation(&"crawl") and v.ap.has_animation(&"run"), "%s has the rig's crawl and run" % v.name)
	crew.free()
	Crew.zombie_motion = keep

func test_the_fours_faces_ship_in_the_game(t: T) -> void:
	for n in range(1, 5):
		var path := Faces.FACE % n
		var tex: Texture2D = load(path) if ResourceLoader.exists(path) else null
		t.check(tex != null and tex.get_width() == 192 and tex.get_height() == 144, "%s is the tape's 192 x 144 drawing" % path)
		t.check(CrewView.image_hash(Faces.drawing(n)) != CrewView.image_hash(Faces.own_drawing(n)), "seat %d uses it, not the fallback" % n)

func test_the_tape_plays_from_the_games_files(t: T) -> void:
	_no_pack(t)
	t.check(Screening.tape() != null, "the recovered tape is in the game and intact")
	# Each copy decodes: its first frames come out at its size and its clock moves.
	for path: String in Screening.FILMS:
		var want := Vector2i(480, 270) if path.ends_with("_web.ogv") else Vector2i(960, 540)
		if not t.check(FileAccess.file_exists(path) and FileAccess.get_sha256(path) == Screening.FILMS[path], "%s is present and intact" % path):
			continue
		var stream := load(path) as VideoStream
		if not t.check(stream != null, "%s opens" % path):
			continue
		var player := VideoStreamPlayer.new()
		player.volume_db = -80.0
		(Engine.get_main_loop() as SceneTree).root.add_child(player)
		player.stream = stream
		player.play()
		for i in 20:
			OS.delay_usec(20000)
			player.notification(Node.NOTIFICATION_INTERNAL_PROCESS)
		var tex: Texture2D = player.get_video_texture()
		t.check(tex != null and Vector2i(tex.get_width(), tex.get_height()) == want, "%s decodes at %s (%s)" % [path, want, Vector2i(tex.get_width(), tex.get_height()) if tex else Vector2i.ZERO])
		t.check(player.is_playing(), "%s plays (%.2f s in)" % [path, player.stream_position])
		player.stop()
		player.free()
	var tree := Engine.get_main_loop() as SceneTree
	var screen := Screening.new()
	tree.root.add_child(screen)
	screen.show_archive({"recovered": true, "discovered": false, "playing": {"me": 3}}, "me")
	t.check(screen.film != null and screen.video.stream == screen.film and not screen.button.disabled, "the prison's deck plays it")
	screen.free()

# --- 3. No pack. ---

## Every file under `dir` (absolute) whose name ends with one of `ends`.
static func _files(dir: String, ends: Array[String], out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f: String in d.get_files():
		for e: String in ends:
			if f.ends_with(e):
				out.append(dir.path_join(f))
				break
	for sub: String in d.get_directories():
		_files(dir.path_join(sub), ends, out)

func test_no_code_names_the_old_packs_or_mounts_one_for_these_floors(t: T) -> void:
	var project := ProjectSettings.globalize_path("res://")
	var files: Array[String] = []
	_files(project.path_join("client"), [".gd"], files)
	_files(project.path_join("../scripts"), [".mjs", ".js", ".txt", ".sh"], files)
	files.append(project.path_join("../scripts/hooks/pre-commit"))
	var read := 0
	var mounts: Array[String] = []
	for f: String in files:
		var src := FileAccess.get_file_as_string(f)
		if src.is_empty():
			continue
		read += 1
		for name: String in ["WardGroundMedia", "ReactorCampaign", "floor-packs", "GD_FLOOR_PACKS", "GD_PACKS_DIR"]:
			t.check(not src.contains(name), "%s does not name %s" % [f.get_file(), name])
		if src.contains("load_resource_pack"):
			mounts.append(f.get_file())
	t.check(read > 50, "the client and the scripts were read (%d files)" % read)
	# The one mount left is the two earlier prototypes' (client/main.gd _start_owner_review, WardReview and Crew23Review).
	t.eq(mounts, ["main.gd"] as Array[String], "only the main game mounts a file, for the two earlier prototypes")
	var main := FileAccess.get_file_as_string("res://client/main.gd")
	t.eq(main.count("load_resource_pack"), 1, "once, in _start_owner_review")
	for floor_file: String in ["res://client/ward/view.gd", "res://client/ward/floor.gd", "res://client/ward/review.gd",
			"res://client/station_crew_view.gd", "res://client/station_faces.gd", "res://client/reactor_screening.gd"]:
		t.check(not FileAccess.get_file_as_string(floor_file).contains(".pck"), "%s names no pack file" % floor_file)
