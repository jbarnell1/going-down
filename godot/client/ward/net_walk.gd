# WN4: the old swapped-in Ward room's walk over the network (client/ward/view.gd, client/ward/review.gd), made safe
# the way WN3 made the main scene's (client/ward/floor.gd walk and reconcile):
#   - step: the Ward's own walk, but a step whose feet, rounded to the wire's centimetre (net/protocol.gd q_body),
#     would stand inside a wall's clearance ends on the nearest clear centimetre point instead, so every body sent
#     is one the host can walk on from;
#   - reconcile: by input number. When the host's body is not the one this screen sent with the input the host last
#     answered for, the host refused a step: the player is put where the host has them.
extends RefCounted

const Ward = preload("res://sim/ward/state.gd")
const Protocol = preload("res://net/protocol.gd")
const Move = preload("res://sim/move.gd")

## How far the host's body may be from the one sent before the screen goes back to the host's.
const SNAP_GAP := 0.03

var _sent := {}
var _last_seq := -1

static func step(model: Ward, from: Vector3, motion: Vector2) -> Vector3:
	var to := model.walk(from, motion)
	if to == from:
		return from
	var y := snappedf(to.y, 0.01)
	var exact := Vector3(snappedf(to.x, 0.01), y, snappedf(to.z, 0.01))
	if model.walk_clear(exact, exact):
		return to
	var best := Vector3.INF
	for gx: float in [floorf(to.x * 100.0) / 100.0, ceilf(to.x * 100.0) / 100.0]:
		for gz: float in [floorf(to.z * 100.0) / 100.0, ceilf(to.z * 100.0) / 100.0]:
			var c := Vector3(gx, y, gz)
			if c.distance_to(to) < best.distance_to(to) and model.walk_clear(c, c) and model.walk_clear(from, c):
				best = c
	return from if best == Vector3.INF else best

## After this frame's input went out: `predicted` the screen's feet, `accepted` the host's newest body for this
## player, `sent_seq` the newest input sent, `ack_seq` the newest input the host had taken, `placed` whether the host
## placed the player this frame. Returns the host's body when it refused a step, else null.
func refused(predicted: Vector3, accepted: Vector3, sent_seq: int, ack_seq: int, placed: bool) -> Variant:
	if placed:
		_sent.clear()
		_last_seq = sent_seq
		return null
	if sent_seq != _last_seq:
		_last_seq = sent_seq
		var q := Protocol.q_body(Move.Body.make(predicted.x, predicted.z, 0, predicted.y))
		_sent[sent_seq] = Vector3(q.x, q.y, q.z)
	if not _sent.has(ack_seq):
		return null
	var was: Vector3 = _sent[ack_seq]
	for k: int in _sent.keys():
		if k < ack_seq:
			_sent.erase(k)
	if was.distance_to(accepted) > SNAP_GAP:
		_sent.clear()
		return accepted
	return null
