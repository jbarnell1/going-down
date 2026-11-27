# Dangers (DG0) on screen: every kind's view. A kind whose file does not exist yet is skipped. One line per kind,
# alphabetical; kinds never edit this list.
extends RefCounted

const VIEWS := {
	&"badge_doors": "res://client/dangers/badge_doors_view.gd",
	&"failing_lights": "res://client/dangers/failing_lights_view.gd",
	&"grabber": "res://client/dangers/grabber_view.gd",
	&"gusts": "res://client/dangers/gusts_view.gd",
	&"roost": "res://client/dangers/roost_view.gd",
	&"snare": "res://client/dangers/snare_view.gd",
	&"steam": "res://client/dangers/steam_view.gd",
	&"test_tile": "res://client/dangers/test_tile_view.gd",
	&"trapdoor": "res://client/dangers/trapdoor_view.gd",
	&"waking_toys": "res://client/dangers/waking_toys_view.gd",
}

static var _scripts := {}

## The view script of a kind, or null.
static func script_of(kind: StringName) -> Script:
	if _scripts.has(kind):
		return _scripts[kind]
	var s: Script = null
	if VIEWS.has(kind) and ResourceLoader.exists(String(VIEWS[kind])):
		s = load(String(VIEWS[kind]))
	_scripts[kind] = s
	return s
