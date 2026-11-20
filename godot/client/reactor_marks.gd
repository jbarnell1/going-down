extends Node3D
## RX1: what the repository added to the Reactor's old compiled scene (res://reactor_campaign.tscn, shipped
## separately until IP1 and no longer in the game; kept for a build that still has it):
##  - the cassette glows (the design: "A glowing VHS cassette lies near the elevator door"): its pieces get an
##    emissive amber material and a small warm light sits over it while it lies there;
##  - the HUD says when E will take the tape or the fuse. The pack's joined-mode HUD only ever prompted the
##    install; the reach and the order mirror sim/reactor.gd use() exactly, read from the host's block.
## Added by client/reactor_screening.gd (_mark_floor), the one repository script the pack's scene builds.
## Only drawing: it never sends anything and never changes what the host decides.

const TAPE_PROMPT := "\nE  PICK UP CASSETTE"
const FUSE_PROMPT := "\nE  TAKE FUSE"
const GLOW := Color("#ffb347")
## sim/reactor.gd use(): the reach for the fuse and the breaker, then for the tape.
const FUSE_REACH := 2.0
const TAPE_REACH := 2.2
const EMERGENCY := 1

var floor_scene: Node
var glow := OmniLight3D.new()
var _lit := false

func _init(scene: Node = null) -> void:
	floor_scene = scene
	name = "ReactorMarks"

func _ready() -> void:
	glow.light_color = GLOW
	glow.light_energy = 1.1
	glow.omni_range = 2.4
	glow.shadow_enabled = false
	add_child(glow)
	glow.hide()

## Which prompt the host's rules would act on for `seat` now: "fuse", "tape" or "" (sim/reactor.gd use()).
static func prompt_for(frame: Dictionary, seat: String, socket: Vector3) -> String:
	if seat.is_empty() or str(frame.get("status", {}).get(seat, "")) != "up":
		return ""
	var at: Array = frame.get("players", {}).get(seat, [])
	if at.size() < 3:
		return ""
	var feet := Vector3(float(at[0]), float(at[1]), float(at[2]))
	var holder := str(frame.get("holder", 0))
	var emergency := int(frame.get("power", -1)) == EMERGENCY
	if emergency and holder == "0" and feet.distance_to(_vec(frame.get("fuseAt", []))) < FUSE_REACH:
		return "fuse"
	if emergency and holder == seat and feet.distance_to(socket) < FUSE_REACH:
		return "" # the pack's own INSTALL FUSE prompt
	if not bool(frame.get("cassette", true)) and feet.distance_to(_vec(frame.get("tapeAt", []))) < TAPE_REACH:
		return "tape"
	return ""

static func _vec(a: Variant) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3(INF, INF, INF)

func _light_tape(tape: Node3D) -> void:
	_lit = true
	for piece: Node in tape.find_children("*", "MeshInstance3D", true, false):
		var mesh := piece as MeshInstance3D
		var look := StandardMaterial3D.new()
		var was: Material = mesh.get_active_material(0)
		look.albedo_color = (was as StandardMaterial3D).albedo_color if was is StandardMaterial3D else Color("#371c0e")
		look.emission_enabled = true
		look.emission = GLOW
		look.emission_energy_multiplier = 0.9
		mesh.material_override = look

func _process(_dt: float) -> void:
	if floor_scene == null or not is_instance_valid(floor_scene):
		return
	var tape: Variant = floor_scene.get("cassette")
	if tape is Node3D:
		if not _lit:
			_light_tape(tape)
		var body: Node3D = tape.get_child(0) if tape.get_child_count() > 0 and tape.get_child(0) is Node3D else tape
		glow.global_position = body.global_position + Vector3(0, .3, 0)
		glow.visible = (tape as Node3D).is_visible_in_tree()
	var hud: Variant = floor_scene.get("hud")
	var frame: Variant = floor_scene.get("frame")
	if not (hud is Label) or not (frame is Dictionary):
		return
	var socket: Variant = floor_scene.get("socket")
	var which := prompt_for(frame, str(floor_scene.get("view_id")), socket if socket is Vector3 else Vector3(INF, INF, INF))
	var label := hud as Label
	for kind: String in ["fuse", "tape"]:
		var line := FUSE_PROMPT if kind == "fuse" else TAPE_PROMPT
		if kind == which and not label.text.contains(line):
			label.text += line
		elif kind != which and label.text.contains(line):
			label.text = label.text.replace(line, "")
