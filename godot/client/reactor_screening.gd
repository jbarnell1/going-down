extends Control
## The recovered tape, an Ogg Theora film shipped in the game (assets/station/tape): the full 960 x 540 copy in the
## desktop build, a lighter 480 x 270 copy of the same length in the browser build (assets_src/station/tape_web.mjs;
## export_presets.cfg keeps each out of the other build). Only the local decoder emits natural end.
signal request(operation: String, ticket: int)
## Each copy with its checksum: the first one present and intact plays.
const FILMS := {
	"res://assets/station/tape/crew23.ogv": "f8750e67bcf117187b19ad036078a9489d5feaa50bcbea47ba84a8c68cfcbcbd",
	"res://assets/station/tape/crew23_web.ogv": "4119dbf31322da63f646d5761a06e32d0771d2a505dcf70046c4abbc353ec805",
}
const Marks = preload("res://client/reactor_marks.gd")
var video := VideoStreamPlayer.new()
var title := Label.new()
var status := Label.new()
var button := Button.new()
var handing_off := false
var ticket := 0
var film: VideoStream
var archive := {}
var reported_end := false
var stopped_early := false
var next_acknowledgement_ms := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var wall := ColorRect.new()
	wall.color = Color("#16222a")
	add_child(wall)
	wall.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := VBoxContainer.new()
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 48
	panel.offset_top = 24
	panel.offset_right = -48
	panel.offset_bottom = -24
	title.text = "PRISON CASSETTE DECK"
	title.add_theme_font_size_override("font_size",24)
	panel.add_child(title)
	panel.add_child(video)
	video.expand = true
	video.size_flags_vertical = Control.SIZE_EXPAND_FILL
	video.finished.connect(natural_end)
	panel.add_child(status)
	panel.add_child(button)
	button.pressed.connect(press)
	film = tape()
	_mark_floor()
	_mark_floor.call_deferred() # and once more after this frame, should the scene not hold the HUD layer yet

## The tape this build carries (the first copy in FILMS that is present and intact), or null.
static func tape() -> VideoStream:
	for path: String in FILMS:
		if FileAccess.file_exists(path) and FileAccess.get_sha256(path) == FILMS[path]:
			return load(path) as VideoStream
	return null

## RX1: inside the Reactor's compiled scene (the pack's game_client.gd puts this screen on its HUD layer) add the
## repository's marks (client/reactor_marks.gd: the glowing tape and the E prompts). Not in the prison.
func _mark_floor() -> void:
	var layer := get_parent()
	var scene := layer.get_parent() if layer != null else null
	if scene is Node3D and "cassette" in scene and "frame" in scene and "hud" in scene and scene.get_node_or_null("ReactorMarks") == null:
		scene.add_child(Marks.new(scene))

func show_archive(value: Dictionary, player_id: String) -> void:
	# The legacy optional station scene owns the room until the real host places the crew home.
	var source := get_tree().current_scene if is_inside_tree() else null
	if source != null and source.scene_file_path == "res://reactor_campaign.tscn":
		var room: Variant = source.get("game")
		if room != null and room.client != null and room.client.latest != null and room.client.latest.depth == 0:
			if not handing_off:
				handing_off = true
				_open_prison.call_deferred(source, room)
			return
	show()
	archive = value
	var next := int(value.playing.get(player_id,0))
	if ticket!=next:
		stopped_early = ticket != 0 and next == 0 and not reported_end
		video.stop()
		ticket = next
		reported_end = false
		if ticket!=0 and film!=null:
			video.stream = film
			video.play()
	if reported_end and ticket != 0 and not video.is_playing() and Time.get_ticks_msec() >= next_acknowledgement_ms:
		# The sound device may finish a fraction before the host receives its final elapsed tick.
		next_acknowledgement_ms = Time.get_ticks_msec() + 350
		request.emit("end",ticket)
	button.disabled = not value.recovered or film==null
	button.text = "Skip and rewind  [E]" if ticket!=0 else ("Replay tape  [E]" if value.discovered else "Play tape  [E]")
	status.text = "Cassette left below. It can be recovered on a later visit."
	if value.recovered:
		if value.discovered:
			status.text = "Full playback logged for your crew. Cassette ready to replay."
		elif stopped_early:
			status.text = "Cassette rewound. No full viewing recorded."
		else:
			status.text = "Cassette stored. Play it now or leave it here."
	if ticket!=0: status.text = "Playing recovered cassette."
	if film==null and value.recovered: status.text = "The recovered film is missing from this build."

func _open_prison(source: Node, room: Variant) -> void:
	var tree := get_tree()
	var main := (load("res://main.tscn") as PackedScene).instantiate()
	main.set("ward_room", room)
	main.set("reactor_prison", true)
	source.set("game", null)
	source.set_physics_process(false)
	tree.root.remove_child(source)
	tree.root.add_child(main)
	tree.current_scene = main
	source.queue_free()

func press() -> void:
	if not visible or button.disabled: return
	request.emit("skip" if ticket!=0 else "watch",ticket)

func natural_end() -> void:
	if ticket!=0:
		reported_end = true
		next_acknowledgement_ms = Time.get_ticks_msec() + 350
		request.emit("end",ticket)
