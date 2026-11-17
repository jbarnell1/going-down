# The Prison hub: the fixed floor plan the crew returns to after BANK (docs/floors/prison.md, section 4).
# Rules data only. The plan is hand-laid and the same on every call: no seed, no random draws.
#
# One level (level 0; level 1 is all void). A grid of 2 m cells, 16 wide by 14 tall. Facing east out of
# the lift, from the top (north) of the map:
#
#   row 7      five cells, 2 wide and 1 deep, doors onto the hall at x = 4, 6, 8, 10, 12 (bunk numbers 1..5)
#   row 8      the hall: ten corridor cells (20 m), x = 4..13, mugshot wall at its east end
#   row 9..11  the bank room (x = 4..7, first door on the right of the hall), then three more cells,
#              2 wide and 1 deep, doors at x = 8, 10, 12 (bunk numbers 6..8)
#   row 12     behind the bank counter, x = 4..7: the tellers' side, void (no one walks there; the
#              look draws it behind the glass)
#   x = 3      the lift lobby, one cell, the landing; its door opens east onto the hall
#   x = 1..2   the lift shaft zone (see SHAFT_*), kept void on both levels
#
# The cells are one cell (2 m) deep so the bunk, along each cell's back wall, is in the door cell: the
# farthest bunk is then 20 m of walking from the lift. Three deep put it at 24 m.
#
# Room kinds are the ones floor.gd's text map already knows: the lobby is &"lobby", the bank room is
# &"ward", each cell is &"closet". Every room is branch &"main"; nothing here is a side branch.
# FloorPlan has no "none" for the entity: entity_start is set to the landing (the same value the
# clinic falls back to), because hash_plan reads it. No entity is ever spawned from it in the hub.
extends RefCounted

const Floor = preload("res://sim/floor.gd")

const PLACE := &"prison"
const CELL_SIZE := 2
const WIDTH := 16
const HEIGHT := 14

## The lift lobby cell, and the hall that leads away from it.
const LANDING_CELL := Vector2i(3, 8)
const HALL_ROW := 8
const HALL_X0 := 4
const HALL_X1 := 13

## The shaft zone reserved for the lift (owner decision V9: the car becomes about 4 m square, so a
## 2 by 2 cell block). It lies directly west of the landing, behind the lobby's west wall, and is void
## on both levels. Rect2i position and size, in cells: x 1..2, y 7..8.
const SHAFT_ZONE := Rect2i(1, 7, 2, 2)

## The bank room: x 4..7, y 9..11, door on the hall at (5, 8) / (5, 9). Its south wall is the counter.
const BANK_ROOM := Rect2i(4, 9, 4, 3)
const BANK_DOOR_X := 5
## The tellers' side of the counter, behind the glass: void, not walkable, drawn by the look only.
const TELLER_SIDE := Rect2i(4, 12, 4, 1)
## The way a player at a window faces: south, across the counter, toward the tellers' side.
const COUNTER_FACING := Vector2i(0, 1)

## The four teller windows: the cell you stand on to face each one, numbered 1..4 left to right as you
## face the counter. Facing south your left is east, so window 1 is the east end. The glass is the
## room's south wall (between rows 11 and 12).
const WINDOWS: Array[Vector2i] = [Vector2i(7, 11), Vector2i(6, 11), Vector2i(5, 11), Vector2i(4, 11)]
## The report board: the stand cell in front of it, on the bank room's east wall.
const REPORT_BOARD := Vector2i(7, 9)
## The day board, beside the lift doors, and the mugshot wall at the hall's far end: both stand cells.
const DAY_BOARD := Vector2i(4, 8)
const MUGSHOT_WALL := Vector2i(13, 8)

## Cells in bunk order 1..8: the door-side x of each, and which side of the hall.
## North cells are row 7, south cells row 9: one row deep, so the door cell is also the back row.
const CELL_DOOR_X_NORTH: Array[int] = [4, 6, 8, 10, 12]
const CELL_DOOR_X_SOUTH: Array[int] = [8, 10, 12]
const NORTH_ROWS := Vector2i(7, 1)  # first row, depth
const SOUTH_ROWS := Vector2i(9, 1)

## The longest walk from the lift to any bunk, in metres (the design: quick, bunks close to the lift).
const MAX_BUNK_WALK_M := 20

static func _carve(cells: Array, x: int, y: int, w: int, h: int, k: StringName) -> void:
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			cells[yy * WIDTH + xx] = k

static func _room(rooms: Array[Floor.Room], kind: StringName, x: int, y: int, w: int, h: int) -> Floor.Room:
	var r := Floor.Room.new()
	r.id = rooms.size()
	r.level = 0
	r.kind = kind
	r.x = x
	r.y = y
	r.w = w
	r.h = h
	r.branch = &"main"
	rooms.append(r)
	return r

## Where each bunk is, in bunk order 1..8 (index 0 is bunk 1): the cell the bunk is drawn in, against
## the cell's back wall (the wall facing its door) in the door's column, where a player stands to climb
## in. The day rules (bed count, wake position) and the look (client/prison_view.gd) both use these.
static func bunk_positions() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for x in CELL_DOOR_X_NORTH:
		out.append(Vector2i(x, NORTH_ROWS.x))
	for x in CELL_DOOR_X_SOUTH:
		out.append(Vector2i(x, SOUTH_ROWS.x + SOUTH_ROWS.y - 1))
	return out

## The four teller window stand cells, numbered left to right as the player faces the counter.
static func window_positions() -> Array[Vector2i]:
	return WINDOWS.duplicate()

## The hand-laid plan. Same every call.
static func prison_plan() -> Floor.FloorPlan:
	var cells: Array[Array] = [[], []]
	for level in 2:
		var c: Array = []
		c.resize(WIDTH * HEIGHT)
		c.fill(Floor.VOID)
		cells[level] = c
	var rooms: Array[Floor.Room] = []
	var doors: Array[Floor.Door] = []
	var l0: Array = cells[0]

	# The hall.
	_carve(l0, HALL_X0, HALL_ROW, HALL_X1 - HALL_X0 + 1, 1, Floor.CORRIDOR)

	# The lift lobby: one cell, the landing. Door east onto the hall.
	_room(rooms, &"lobby", LANDING_CELL.x, LANDING_CELL.y, 1, 1)
	_carve(l0, LANDING_CELL.x, LANDING_CELL.y, 1, 1, Floor.ROOM)
	l0[LANDING_CELL.y * WIDTH + LANDING_CELL.x] = Floor.LANDING
	doors.append(Floor.Door.make(0, HALL_X0, HALL_ROW, LANDING_CELL.x, LANDING_CELL.y))

	# The bank room, the first door on the right of the hall.
	_room(rooms, &"ward", BANK_ROOM.position.x, BANK_ROOM.position.y, BANK_ROOM.size.x, BANK_ROOM.size.y)
	_carve(l0, BANK_ROOM.position.x, BANK_ROOM.position.y, BANK_ROOM.size.x, BANK_ROOM.size.y, Floor.ROOM)
	doors.append(Floor.Door.make(0, BANK_DOOR_X, HALL_ROW, BANK_DOOR_X, BANK_ROOM.position.y))

	# The cell block: five cells on the left of the hall, three on the right beyond the bank room.
	for x in CELL_DOOR_X_NORTH:
		_room(rooms, &"closet", x, NORTH_ROWS.x, 2, NORTH_ROWS.y)
		_carve(l0, x, NORTH_ROWS.x, 2, NORTH_ROWS.y, Floor.ROOM)
		doors.append(Floor.Door.make(0, x, HALL_ROW, x, NORTH_ROWS.x + NORTH_ROWS.y - 1))
	for x in CELL_DOOR_X_SOUTH:
		_room(rooms, &"closet", x, SOUTH_ROWS.x, 2, SOUTH_ROWS.y)
		_carve(l0, x, SOUTH_ROWS.x, 2, SOUTH_ROWS.y, Floor.ROOM)
		doors.append(Floor.Door.make(0, x, HALL_ROW, x, SOUTH_ROWS.x))

	var plan := Floor.FloorPlan.new()
	plan.place = PLACE
	plan.seed = "prison"
	plan.depth = 0
	plan.width = WIDTH
	plan.height = HEIGHT
	plan.cell_size = CELL_SIZE
	plan.cells = cells
	plan.rooms = rooms
	plan.doors = doors
	plan.stairs = []
	plan.landing = Floor.Pos.make(0, LANDING_CELL.x, LANDING_CELL.y)
	plan.entity_start = plan.landing
	plan.sightlines = []
	return plan
