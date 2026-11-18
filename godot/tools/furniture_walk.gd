# A scripted walk through furnished rooms with the client's own `walkto` (client/play_link.gd walk_to, the
# command godot/tools/playthrough.mjs drives the player with), headless: playing alone (net/local_room.gd) with
# solid furniture on, first on a Clinic, then on an Annex. On each it puts the player at a doorway of the
# room with the most plain pieces, walks to the cell under its plain piece furthest from there, and checks that the walk
# arrives, that the body never stood inside a solid piece on the way, and that it passed close beside one.
# Exit code 0 when both walks pass.
#   "$GODOT" --headless --path godot --script res://tools/furniture_walk.gd
extends SceneTree

const LocalRoom = preload("res://net/local_room.gd")
const PlayLink = preload("res://client/play_link.gd")
const Session = preload("res://net/session.gd")
const Furniture = preload("res://sim/furniture.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Playroom = preload("res://sim/playroom.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 1.0 / 30.0
const INP := {"dt": DT, "f": 0.0, "r": 0.0, "sprint": false, "creep": false, "yaw": 0.0, "pitch": 0.0, "hfov": 90.0, "vfov": 70.0}

func _init() -> void:
	_main.call_deferred()

## The pipes deliver on the main loop, so every step waits a frame.
func _main() -> void:
	var failed := 0
	for place: StringName in [&"clinic", &"annex"]:
		if not await _walk(place):
			failed += 1
	Session.deck = Places_clinic()
	print("furniture walk: %s" % ("PASS" if failed == 0 else "FAIL (%d)" % failed))
	quit(0 if failed == 0 else 1)

static func Places_clinic() -> Array[StringName]:
	var d: Array[StringName] = [&"clinic"]
	return d

func _walk(place: StringName) -> bool:
	var deck: Array[StringName] = [place]
	Session.deck = deck
	var lr := LocalRoom.new()
	lr.open_local("furniture-walk", "WALKER", false)
	lr.furniture = true
	lr.start_run()
	var link := PlayLink.new(lr, true)
	var now := 0.0
	for _i in 900:
		now += DT
		link.step(now, INP)
		await process_frame
		if link.body != null and link.plan != null:
			break
	if link.plan == null or link.body == null:
		print("%s: the run never started (seed %s, latest %s, plan %s, body %s, room %s, vt %.1f)" % [place, link.client().seed, link.client().latest != null, link.plan, link.body, lr.status, lr.room_time()])
		return false
	var plan := link.plan
	var latest: Dictionary = link.client().latest
	if latest.get("solid") == null:
		print("%s: the host does not say the furniture is solid" % place)
		return false
	var pieces := Furniture.pieces_for(plan)
	var solids := Furniture.solids_of(plan)
	# The room with the most plain pieces.
	var counts := {}
	for pc in pieces:
		if pc.hide < 0 and pc.room >= 0:
			counts[pc.room] = int(counts.get(pc.room, 0)) + 1
	var best_room := -1
	for rid: int in counts:
		if best_room < 0 or int(counts[rid]) > int(counts[best_room]):
			best_room = rid
	var room: Floor.Room = null
	for r in plan.rooms:
		if r.id == best_room:
			room = r
	var doors := Playroom._door_cells(plan)
	var start: Floor.Pos = null
	for y in range(room.y, room.y + room.h):
		for x in range(room.x, room.x + room.w):
			if start == null and doors.has(Floor.pos_index(plan, Floor.Pos.make(room.level, x, y))):
				start = Floor.Pos.make(room.level, x, y)
	var dist := Floor.distances_from(plan, start)
	# The goal: the cell under the room's plain piece furthest from the doorway, so the walk ends beside it.
	var goal := start
	for pc in pieces:
		if pc.room != room.id or pc.hide >= 0:
			continue
		var cell := Floor.Pos.make(pc.level, pc.x / 200, pc.y / 200)
		var k := Floor.pos_index(plan, cell)
		if dist[k] > dist[Floor.pos_index(plan, goal)]:
			goal = cell
	link.teleport(start.level, start.x, start.y)
	var r: Dictionary = link.walk_to(goal.level, goal.x, goal.y, 1.4)
	if not r.get("ok", false):
		print("%s: walkto refused: %s" % [place, str(r)])
		return false
	var nearest := INF
	var inside := 0
	var frames := 0
	while frames < 30 * 90 and link.auto_status == "walking":
		now += DT
		frames += 1
		link.step(now, INP)
		await process_frame
		var b := link.body
		var c := Move.box_clearance(solids, b.level, b.x, b.z)
		nearest = minf(nearest, c)
		if c < PlayLink.PLAYER_RADIUS - 1e-6:
			inside += 1
	var at := Move.cell_of(plan, link.body)
	var ok := link.auto_status == "done" and at.level == goal.level and at.x == goal.x and at.y == goal.y and inside == 0 and nearest < 0.6
	print("%s %s/%d: room %d (%s, %d plain pieces) from %d,%d to %d,%d: %s after %.1f s, nearest a piece %.2f m, %d frames inside one: %s" % [
		place, plan.seed, plan.depth, room.id, room.kind, int(counts[best_room]), start.x, start.y, goal.x, goal.y, link.auto_status,
		frames * DT, nearest, inside, "PASS" if ok else "FAIL"])
	lr.leave()
	return ok
