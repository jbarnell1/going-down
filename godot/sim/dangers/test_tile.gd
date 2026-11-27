# Dangers (DG0): the template kind, test_tile. Tests only (data/dangers.json "test_only"): `all` never turns it on.
# A floor tile that clicks when an up player steps on it at a walk or a sprint, then danger.test_tile.delay seconds
# later makes a noise of danger.test_tile.loud metres where it is, blamed on them. Idle -> armed -> spent.
# Placed on one walkable cell far from the lift, clear of everything the base keeps clear. Copy this file's shape.
extends "res://sim/dangers/kind.gd"

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Settings = preload("res://sim/settings.gd")

const DELAY := 1.0
const LOUD := 10.0
## Half the tile's side (metres): a body whose centre is this near its middle stands on it.
const HALF := 0.6

func kind_name() -> StringName:
	return &"test_tile"

func states() -> Array[StringName]:
	return [&"idle", &"armed", &"spent"]

## One tile on the reachable cell furthest from the lift whose middle is clear (ties: the first in cell order).
func place(p: Api.Place) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if p.plan == null:
		return out
	var best := -1
	var best_steps := -1
	var cs := float(p.plan.cell_size)
	for i in p.lift_steps.size():
		var steps := p.lift_steps[i]
		if steps <= best_steps:
			continue
		var pos := Floor.pos_from_index(p.plan, i)
		if not p.clear(pos.level, (pos.x + 0.5) * cs, (pos.y + 0.5) * cs, HALF):
			continue
		best = i
		best_steps = steps
	if best < 0:
		return out
	var at := Move.body_at_cell(p.plan, Floor.pos_from_index(p.plan, best))
	out.append({"x": at.x, "y": at.y, "z": at.z, "level": at.level, "yaw": 0.0, "n": [], "k": {"by": ""}})
	return out

func step(rec: Dictionary, k: Api.Tick, ask: Api.Asks) -> void:
	match StringName(rec["state"]):
		&"idle":
			for w in k.players:
				if w.up and (w.speed == &"walk" or w.speed == &"sprint") and _on(rec, w.body):
					ask.set_state(rec, &"armed")
					rec["k"]["by"] = w.id
					ask.cue(rec, &"click", _at(rec))
					return
		&"armed":
			if k.t - float(rec["since"]) >= Settings.f(k.tuning, &"danger.test_tile.delay", DELAY) - 1e-9:
				ask.noise(rec, _at(rec), Settings.f(k.tuning, &"danger.test_tile.loud", LOUD), str(rec["k"].get("by", "")))
				ask.set_state(rec, &"spent")

static func _on(rec: Dictionary, b: Move.Body) -> bool:
	return b != null and b.level == int(rec["level"]) and absf(b.x - float(rec["x"])) <= HALF and absf(b.z - float(rec["z"])) <= HALF

static func _at(rec: Dictionary) -> Move.Body:
	return Move.Body.make(float(rec["x"]), float(rec["z"]), int(rec["level"]), float(rec["y"]))
