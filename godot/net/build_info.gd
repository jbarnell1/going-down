# Which build this is. The client sends it as the fifth element of its hello (net/room_client.gd); the
# server compares it with its own (net/ws_server.gd) and refuses a different one with close code 4007 and
# OUT_OF_DATE, which the join screen shows (client/main.gd _close_words).
#
# The id is written by `npm run godot:export` (tools/godot.mjs) into res://build_id.gd just before the
# export: the short commit, plus "-dirty" when godot/ had changes not yet committed. That file is not in
# git (godot/.gitignore). Without it (running from source before any export) the id is DEV, and a server
# whose own id is DEV takes every build: local tests and source runs are never refused.
extends RefCounted

const GENERATED := "res://build_id.gd"
const DEV := "dev"
const OUT_OF_DATE := "Your game is out of date. Ask the host for the new GoingDown.zip."
const MAX_LENGTH := 64

static var _id := ""

## This build's id (cached after the first call).
static func id() -> String:
	if _id.is_empty():
		_id = DEV
		if ResourceLoader.exists(GENERATED):
			var s: Variant = load(GENERATED)
			if s is GDScript:
				var c: Dictionary = (s as GDScript).get_script_constant_map()
				if valid(c.get("BUILD")):
					_id = c["BUILD"]
	return _id

## A build id as it may travel: 1 to MAX_LENGTH characters of letters, digits and . _ + -.
static func valid(b: Variant) -> bool:
	if not b is String or (b as String).is_empty() or (b as String).length() > MAX_LENGTH:
		return false
	for i in (b as String).length():
		var ch := (b as String).unicode_at(i)
		var ok := (ch >= 0x30 and ch <= 0x39) or (ch >= 0x41 and ch <= 0x5a) or (ch >= 0x61 and ch <= 0x7a) or ch == 0x2e or ch == 0x5f or ch == 0x2b or ch == 0x2d
		if not ok:
			return false
	return true

## Whether a server built as `server_build` lets in a client that said `client_build` ("" for a hello
## without one). A DEV server takes everyone; otherwise the ids must be equal.
static func accepts(server_build: String, client_build: String) -> bool:
	return server_build == DEV or client_build == server_build
