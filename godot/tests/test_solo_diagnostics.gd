extends RefCounted

const T = preload("res://tests/t.gd")
const LocalRoom = preload("res://net/local_room.gd")
const RoomClient = preload("res://net/room_client.gd")
const Diagnostics = preload("res://client/solo_diagnostics.gd")
const Clinic = preload("res://sim/clinic.gd")

func test_debug_panel_requires_opt_in_and_a_local_room(t: T) -> void:
	t.check(Diagnostics.allowed(true, LocalRoom.new()), "explicit opt-in enables local room diagnostics")
	t.check(not Diagnostics.allowed(false, LocalRoom.new()), "ordinary solo keeps the production HUD")
	t.check(not Diagnostics.allowed(true, RoomClient.new()), "the query does not expose shared-room diagnostics")
	t.check(not Diagnostics.allowed(true, null), "the title screen has no room diagnostics")

func test_debug_panel_shows_labels_and_a_map_without_taking_input(t: T) -> void:
	var panel := Diagnostics.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(panel)
	var floor := Clinic.generate_clinic("diagnostic-map", 1)
	var cell := {"level": floor.landing.level, "x": floor.landing.x, "y": floor.landing.y}
	var me := {"cell": cell, "x": float(cell["x"]) * 2.0 + 1.0, "y": 0.0, "z": float(cell["y"]) * 2.0 + 1.0, "side": null}
	panel.present(floor, {"me": me, "inst": {"needle": "off"}, "tapes": {"count": 1, "value": 12.0},
		"orderly": {}, "depth": 1, "phase": "away", "blackout": true, "doorsOpen": false}, 0.0, 60.0, 16.7, 2.5)
	var view := panel.describe()
	t.check(view["visible"] and view["map"] and view["rows"].has("FLOOR 1  AWAY   BLACKOUT"),
		"the panel draws the real floor map and state")
	t.check(panel.mouse_filter == Control.MOUSE_FILTER_IGNORE and panel.focus_mode == Control.FOCUS_NONE,
		"the read-only panel cannot intercept controls")
	panel.free()
