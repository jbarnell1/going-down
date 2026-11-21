# OR2: the Orderly's trolley heard through the air of the floor, not straight through walls and floors. Client only:
# the rules' own number (sim/entity.gd audibility, a straight line to HEAR_RANGE) is unchanged and still what every
# recorded result holds; this is what the screens play.
#
# The owner (20 Nov): "The two orderlies still have super loud breathing throughout the whole clinic level ... I can
# still hear the breathing on lower floors, instead of sound having to travel through air and not open spaces." The
# breath loops were already near and on the listener's storey only (client/sfx.gd breath_db, BREATH_FAR 8 m). What
# carried across the floor was the trolley's wheels: its squeak and roll loop, audible to 34 m in a straight line
# through any wall and through the floor between storeys, and through a wall made LOUDER (the low-pass and
# MUFFLED_DB +5 dB) while its distance took only 3 dB off (client/sfx.gd update). Low-passed through walls, the
# rolling loop reads as a heavy breath.
#
# Now: the distance is the walk through the floor's air (Floor.distances_from the listener's cell, steps x cell size,
# never less than the straight line), so a room behind a wall with the door at the far end is as far as the walk to
# it, and the other storey is as far as the stair; the other storey loses CROSS_STOREY of its gain on top, and a
# place with no walk to it is silent. The gain then falls on Sfx.trolley_db's curve.
extends RefCounted

const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const M = preload("res://sim/jsmath.gd")

## The gain left on the other storey (on top of the walk by the stair).
const CROSS_STOREY := 0.25

## One walk field, from the listener's cell asked for last (the listener moves a cell in many frames).
static var _plan: Floor.FloorPlan = null
static var _from := -1
static var _field := PackedInt32Array()

## The walk in cells from the listener's cell to every cell of `plan` (-1: none), cached for the last cell asked.
static func field_from(plan: Floor.FloorPlan, cell: Floor.Pos) -> PackedInt32Array:
	var index := Floor.pos_index(plan, cell)
	if _plan != plan or _from != index:
		_plan = plan
		_from = index
		_field = Floor.distances_from(plan, cell)
	return _field

## The listener's cell for the walk: their own, or the nearest walkable one round it (in the car, on a threshold).
static func _ear_cell(plan: Floor.FloorPlan, body: Move.Body) -> Floor.Pos:
	var c := Move.cell_of(plan, body)
	if Floor.is_walkable(plan, c.level, c.x, c.y):
		return c
	for r: int in [1, 2]:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if Floor.is_walkable(plan, c.level, c.x + dx, c.y + dy):
					return Floor.Pos.make(c.level, c.x + dx, c.y + dy)
	return null

## Metres walked from the listener's cell to `source`'s (steps x cell size), or -1 for no walk.
static func air_metres(plan: Floor.FloorPlan, listener: Move.Body, source: Move.Body) -> float:
	var ear := _ear_cell(plan, listener)
	var at := _ear_cell(plan, source)
	if ear == null or at == null:
		return -1.0
	var steps := field_from(plan, ear)[Floor.pos_index(plan, at)]
	if steps < 0:
		return -1.0
	return float(steps) * float(plan.cell_size)

## The rules' audibility of a moving Orderly, through the air (see the header). A body that clicks (the Temp) is
## left as the rules give it.
static func audibility(plan: Floor.FloorPlan, state: Entity.OrderlyState, listener: Move.Body, eye: float) -> Entity.Audibility:
	var a := Entity.audibility(plan, state, listener, eye)
	var k := Entity.kind_of(state)
	if a.gain <= 0.0 or k.clicks() or state.relocated:
		return a
	var walk := air_metres(plan, listener, state.body)
	if walk < 0.0:
		return Entity.Audibility.make(0.0, false)
	# Never nearer than the rules' own straight line, from the wheels to the ear.
	var ear := Sight.eye_point(listener, eye)
	var b := state.body
	var d := maxf(walk, M.hypot3(b.x - ear.x, b.y + k.sound_height - ear.y, b.z - ear.z))
	if d >= k.hear_range:
		return Entity.Audibility.make(0.0, false)
	var g := M.pow_js(1.0 - d / k.hear_range, 2.0)
	var other := listener.level != state.body.level
	if other:
		g *= CROSS_STOREY
	# Never louder than the rules' own number (its muffling through a wall stays).
	return Entity.Audibility.make(minf(g * (Entity.MUFFLED_GAIN if a.muffled else 1.0), a.gain), a.muffled or other)
