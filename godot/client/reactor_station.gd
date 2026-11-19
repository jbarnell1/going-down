extends Node
## Mounted only when the reactor room brings its crew home.
const Review = preload("res://net/reactor_review.gd")
const Screen = preload("res://client/reactor_screening.gd")

var game: Variant
var station: Node3D
var overlay := CanvasLayer.new()
var hint := Label.new()
var screen := Screen.new()
var nearby := false
var archive: Dictionary = {}
var open := false

func _ready() -> void:
	game = get_parent()
	add_child(overlay)
	overlay.layer = 8
	overlay.add_child(hint)
	hint.position = Vector2(26, 128)
	overlay.add_child(screen)
	screen.hide()
	screen.request.connect(func(op: String, ticket: int) -> void: game.link.rc.reactor_screening(op, ticket))

func _process(_dt: float) -> void:
	if game.link == null:
		overlay.hide()
		return
	var client: Variant = game.link.client()
	if client == null or client.latest == null or game.level == null or not game.level.has_meta("prison"):
		hint.hide()
		screen.hide()
		open = false
		return
	var reactor: Variant = client.latest.get("reactor")
	if reactor == null or not reactor.lift:
		hint.hide()
		screen.hide()
		return
	if not is_instance_valid(station):
		_mount()
	archive = reactor.archive
	var me: Dictionary = game.snap.get("me", {})
	nearby = me.has("x") and Review.at_prison_station(me.x, me.z)
	if not nearby and open:
		close_screen()
	hint.visible = not open and not game._esc_menu
	hint.text = "E  USE PRISON CASSETTE DECK" if nearby else ("Recovered cassette  /  Tape deck in east cell block" if archive.recovered else "")
	if open:
		screen.show_archive(archive, game.link.my_id())

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or game._esc_menu: return
	if open and event.physical_keycode == KEY_ESCAPE:
		close_screen()
	elif nearby and event.physical_keycode == KEY_E:
		if open:
			screen.press()
		else:
			open = true
			screen.show_archive(archive, game.link.my_id())
	else:
		return
	get_viewport().set_input_as_handled()

func close_screen() -> void:
	if screen.ticket != 0:
		screen.stopped_early = not screen.reported_end
		game.link.rc.reactor_screening("skip",screen.ticket)
	screen.video.stop()
	screen.ticket = 0
	open = false
	screen.hide()

func _mount() -> void:
	station = Node3D.new()
	station.name = "CassettePlayer"
	game.level.add_child(station)
	station.position = Review.STATION_POSITION
	_box(Vector3(0,-0.2,0),Vector3(0.77,0.63,0.29),Color("#393f40"))
	_box(Vector3(0,-0.14,0.15),Vector3(0.59,0.38,0.02),Color("#9eae8e"))
	_box(Vector3(0,-0.43,0.16),Vector3(0.30,0.045,0.02),Color("#15181b"))
	var label := Label3D.new()
	label.text = "PRISON CASSETTE DECK"
	label.pixel_size = 0.0014
	label.position = Vector3(0,0.23,0.16)
	station.add_child(label)
	print("REACTOR PRISON STATION id=%s depth=%s" % [game.link.my_id(),game.link.client().latest.depth])

func _box(at: Vector3, size: Vector3, color: Color) -> void:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material = material
	node.mesh = mesh
	node.position = at
	station.add_child(node)
