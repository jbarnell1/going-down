## The opt-in developer overlay: a passive readout and current-level map.
extends Control

const Floor = preload("res://sim/floor.gd")
const LocalRoom = preload("res://net/local_room.gd")
const PALETTE := {
	Floor.CORRIDOR: Color("#9baaa5"),
	Floor.ROOM: Color("#657b74"),
	Floor.LANDING: Color("#79c9a4"),
	Floor.STAIR: Color("#e6bb68"),
	Floor.ATRIUM_OPEN: Color("#304441"),
}
const PANEL_W := 362.0
const MAP_EDGE := 168.0
const ROW_HEIGHT := 18.0
const TYPE_PX := 1.45

var _plan: Floor.FloorPlan
var _level := 0
var _maps: Dictionary = {}
var _rows: PackedStringArray = []
var _feet := Vector2.ZERO
var _yaw := 0.0
var _resident := {}
var _tapes: Array = []

static func allowed(requested: bool, room: Variant) -> bool:
	return requested and room is LocalRoom

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	position = Vector2(16, 74)
	hide()

func present(plan: Floor.FloorPlan, s: Dictionary, yaw: float, fps: float, frame_ms: float, host_ms: float) -> void:
	if plan == null or not s.get("me") is Dictionary:
		hide()
		return
	if plan != _plan:
		_plan = plan
		_maps.clear()
	var me: Dictionary = s["me"]
	var cell: Dictionary = me["cell"]
	var inst: Dictionary = s["inst"]
	var tapes: Dictionary = s["tapes"]
	var o: Dictionary = s["orderly"]
	var call: Dictionary = s["call"] if s.get("call") is Dictionary else {}
	var light := "BLACKOUT" if s.get("blackout", false) else ("BLINK" if s.get("dark", false) else "LIT")
	var vote := str(me.get("side")) if me.get("side") != null else "-"
	var lift := "OPEN" if s.get("doorsOpen", false) else "SHUT"
	if call.has("eta"):
		lift += "  %.1f S" % float(call["eta"])
	_rows = PackedStringArray([
		"SOLO DIAGNOSTICS",
		"%.0f FPS   %.1f MS FRAME   %.2f MS HOST" % [fps, frame_ms, host_ms],
		"FLOOR %d  %s   %s" % [int(s["depth"]), str(s["phase"]).to_upper(), light],
		"LIFT %s   VOTE %s" % [lift, vote.to_upper()],
		"LEVEL %d   CELL %d,%d   YAW %.0f" % [int(cell["level"]), int(cell["x"]), int(cell["y"]), rad_to_deg(yaw)],
		"POS %.2f %.2f %.2f" % [float(me["x"]), float(me["y"]), float(me["z"])],
		"INSTRUMENT %s   TAPES %d   %.0f C" % [str(inst["needle"]).to_upper(), int(tapes["count"]), float(tapes["value"])],
	])
	if o.get("pose") is Dictionary:
		var squeak: Dictionary = o.get("squeak", {})
		_rows.append("RESIDENT %s   SQUEAK %.2f" % [str(o["mode"]).to_upper(), float(squeak.get("gain", 0.0))])
	_rows.append("F  USE   ESC  MENU")
	if OS.has_feature("windows"):
		_rows.append("F6  HOST PLAYTEST")
	_level = int(cell["level"])
	_feet = Vector2(float(me["x"]), float(me["z"]))
	_yaw = yaw
	_resident = o["pose"] if o.get("pose") is Dictionary else {}
	_tapes = s.get("floorTapes", [])
	if not _maps.has(_level):
		var raster := Image.create(plan.width, plan.height, false, Image.FORMAT_RGB8)
		for z in plan.height:
			for x in plan.width:
				var kind := Floor.cell_at(plan, _level, x, z)
				raster.set_pixel(x, z, PALETTE.get(kind, Color("#172321")))
		_maps[_level] = ImageTexture.create_from_image(raster)
	show()
	queue_redraw()

func _draw() -> void:
	if _plan == null or not _maps.has(_level):
		return
	var scale_ := MAP_EDGE / maxi(_plan.width, _plan.height)
	var map_size := Vector2(_plan.width, _plan.height) * scale_
	var map_origin := Vector2(12, 12 + ROW_HEIGHT * _rows.size())
	draw_rect(Rect2(Vector2.ZERO, Vector2(PANEL_W, map_origin.y + map_size.y + 12)), Color("#14211df2"))
	for i in _rows.size():
		PixelFont.draw(self, _rows[i], Vector2(12, 12 + ROW_HEIGHT * i), TYPE_PX,
			Color("#e6bb68") if i == 0 else Color("#ecf3e9"))
	draw_texture_rect(_maps[_level], Rect2(map_origin, map_size), false)
	var metres := scale_ / _plan.cell_size
	for row: Dictionary in _tapes:
		var at: Dictionary = row["at"]
		if int(at["level"]) == _level:
			draw_circle(map_origin + Vector2(float(at["x"]), float(at["z"])) * metres, 2.5, Color("#f0bb54"))
	if not _resident.is_empty() and int(_resident.get("level", -1)) == _level:
		var at := Vector2(float(_resident["x"]), float(_resident["z"]))
		draw_circle(map_origin + at * metres, 3.0, Color("#ff8476"))
	var player := map_origin + _feet * metres
	var forward := Vector2(-sin(_yaw), -cos(_yaw))
	draw_circle(player, 3.0, Color.WHITE)
	draw_line(player, player + forward * 8.0, Color.WHITE, 2.0)

func describe() -> Dictionary:
	return {"visible": is_visible_in_tree(), "rows": _rows, "map": _maps.has(_level)}
