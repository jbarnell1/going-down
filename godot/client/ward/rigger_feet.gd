# RR1 stage 2: the crawling Rigger's feet on the surfaces he crawls (client only; the host's rules never read this).
# A modifier on his skeleton (assets/ward/rigger_v2.glb), after his clip each frame: for each of his eight legs, a hold
# is found on a real solid of the Ward under the hip (a ray from the hip towards the surface his back is away from,
# splayed outward, against the same boxes his surface graph is built from: sim/ward/rigger_graph.gd), and the leg is
# solved to it by two-bone IK (the knee bending away from the surface, the lower leg pointing down at the hold). A
# planted foot stays where it is until the hold under the hip is more than STEP from it; then it steps there, lifted
# in an arc, the two sets of four legs (L1 R2 L3 R4 and the others) taking turns, so he walks over a roof, across a
# wall and under a walkway rather than floating. A leg with no hold within reach keeps its clip's pose.
extends SkeletonModifier3D

const G = preload("res://sim/ward/rigger_graph.gd")

const LEGS := ["L1", "L2", "L3", "L4", "R1", "R2", "R3", "R4"]
const SET_A := ["L1", "R2", "L3", "R4"]
## How far a hold may be (metres along the ray), how far the hold under the hip may drift before the foot steps, how
## long a step takes and how high it lifts, how long each set has its turn.
const RAY := 6.5
const STEP := 1.1
const STEP_TIME := 0.25
const LIFT := 0.35
const TURN := 0.3
## How far out from straight at the surface each try of a leg's ray leans.
const SPLAYS := [0.6, 0.0, -0.5]
## The lower leg (tarsus) above its hold, along the surface's normal.
const TARSUS := 0.9

## The Ward's solids (a graph with only its solids built: G.solids_only).
var solids: G = null
## Host time (client/ward/view.gd sets it each frame); the steps are timed by it.
var now := 0.0
## Each leg: [coxa, femur, tibia, tarsus] bone ids.
var chains: Array = []
var lengths: Array = []
## Each leg: the planted foot (world), the step's start, its target, its start time (-1 not stepping).
var planted: Array = []
var step_from: Array = []
var step_to: Array = []
var step_at: Array = []
## Tests: the last foot point each leg was solved to (world), or INF when it kept its clip.
var feet: Array = []

func setup(sk: Skeleton3D, solids_: G) -> void:
	solids = solids_
	chains.clear()
	lengths.clear()
	for leg: String in LEGS:
		var ids := PackedInt32Array()
		for part: String in ["coxa", "femur", "tibia", "tarsus"]:
			ids.append(sk.find_bone("leg_%s_%s" % [leg, part]))
		chains.append(ids)
		if ids.has(-1):
			lengths.append([0.0, 0.0])
			continue
		var femur := sk.get_bone_rest(ids[2]).origin.length()
		var tibia := sk.get_bone_rest(ids[3]).origin.length()
		lengths.append([femur, tibia])
	planted.resize(LEGS.size())
	step_from.resize(LEGS.size())
	step_to.resize(LEGS.size())
	step_at.resize(LEGS.size())
	feet.resize(LEGS.size())
	reset()

## Forget every hold (he was drawn somewhere new: out of his lair, or a jump in the host's pose).
func reset() -> void:
	for i in LEGS.size():
		planted[i] = Vector3.INF
		step_at[i] = -1.0
		feet[i] = Vector3.INF

func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null or solids == null or chains.is_empty():
		return
	var to_world := sk.global_transform
	var to_skel := to_world.affine_inverse()
	var up := to_world.basis.y.normalized()
	var forward := to_world.basis.z.normalized()
	var centre := to_world.origin
	for i in LEGS.size():
		var ids: PackedInt32Array = chains[i]
		if ids.has(-1):
			continue
		var hip := to_world * sk.get_bone_global_pose(ids[1]).origin
		var out := hip - centre
		out -= up * out.dot(up)
		out = out.normalized() if out.length() > 1e-4 else Vector3.ZERO
		# Splayed out first; then straight at the surface; then tucked in (a narrow deck or a corner).
		var hold := Vector3.INF
		for splay: float in SPLAYS:
			hold = ray_hold(hip, (-up + out * splay).normalized())
			if hold != Vector3.INF:
				break
		# Hanging off a house to reach in (his reach poses), the house is ahead of him: forward, then forward and down.
		if hold == Vector3.INF:
			for lean: Vector3 in [forward + out * 0.5, forward - up * 0.5, forward]:
				hold = ray_hold(hip, lean.normalized())
				if hold != Vector3.INF:
					break
		if hold == Vector3.INF:
			feet[i] = Vector3.INF
			planted[i] = Vector3.INF
			continue
		var foot := _stepped(i, hold, up)
		feet[i] = foot
		var ankle := foot + up * TARSUS
		solve_leg(sk, ids, lengths[i], to_skel * ankle, to_skel.basis * up, to_skel * foot)

## The foot of leg i this frame: planted until the hold drifts STEP away, then stepping there in its set's turn.
func _stepped(i: int, hold: Vector3, up: Vector3) -> Vector3:
	if planted[i] == Vector3.INF or (planted[i] as Vector3).distance_to(hold) > STEP * 3.0:
		planted[i] = hold
		step_at[i] = -1.0
		return hold
	if float(step_at[i]) >= 0.0:
		var k := clampf((now - float(step_at[i])) / STEP_TIME, 0.0, 1.0)
		var at: Vector3 = (step_from[i] as Vector3).lerp(step_to[i], k) + up * LIFT * sin(PI * k)
		if k >= 1.0:
			planted[i] = step_to[i]
			step_at[i] = -1.0
		return at
	var turn := int(floorf(now / TURN)) % 2 == (0 if SET_A.has(LEGS[i]) else 1)
	if turn and (planted[i] as Vector3).distance_to(hold) > STEP:
		step_from[i] = planted[i]
		step_to[i] = hold
		step_at[i] = now
	return planted[i]

## The nearest point a ray from `from` along `dir` meets a solid within RAY metres, or INF.
func ray_hold(from: Vector3, dir: Vector3) -> Vector3:
	var best := RAY
	for k in solids.ob_o.size():
		var d := from - solids.ob_o[k]
		if d.length() - solids.ob_r[k] > RAY:
			continue
		var o := Vector3(solids.ob_x[k].dot(d), solids.ob_y[k].dot(d), solids.ob_z[k].dot(d))
		var v := Vector3(solids.ob_x[k].dot(dir), solids.ob_y[k].dot(dir), solids.ob_z[k].dot(dir))
		var h := solids.ob_h[k]
		var low := 0.0
		var high := best
		var hit := true
		for axis in 3:
			if absf(v[axis]) < 1e-9:
				if absf(o[axis]) > h[axis]:
					hit = false
					break
				continue
			var t1 := (-h[axis] - o[axis]) / v[axis]
			var t2 := (h[axis] - o[axis]) / v[axis]
			low = maxf(low, minf(t1, t2))
			high = minf(high, maxf(t1, t2))
			if low > high:
				hit = false
				break
		if hit and low > 1e-4 and low < best:
			best = low
	return from + dir * best if best < RAY else Vector3.INF

## Two-bone IK in skeleton space: the femur and tibia put the tibia's end (the ankle) at `ankle` (or as near as their
## lengths allow), the knee bending towards `pole`; the tarsus then points at `foot`.
static func solve_leg(sk: Skeleton3D, ids: PackedInt32Array, lens: Array, ankle: Vector3, pole: Vector3, foot: Vector3) -> void:
	var a := float(lens[0])
	var b := float(lens[1])
	if a <= 0.0 or b <= 0.0:
		return
	var hip := sk.get_bone_global_pose(ids[1]).origin
	var reach := ankle - hip
	var d := clampf(reach.length(), absf(a - b) + 1e-3, a + b - 1e-3)
	var axis := reach.normalized()
	var bend := pole - axis * pole.dot(axis)
	if bend.length() < 1e-4:
		bend = axis.cross(Vector3.RIGHT)
	bend = bend.normalized()
	var along := (a * a - b * b + d * d) / (2.0 * d)
	var knee := hip + axis * along + bend * sqrt(maxf(0.0, a * a - along * along))
	var end := hip + axis * d
	_aim(sk, ids[1], ids[2], knee - hip)
	_aim(sk, ids[2], ids[3], end - knee)
	var tarsus := sk.get_bone_global_pose(ids[3])
	var down := foot - tarsus.origin
	if down.length() > 1e-4:
		var parent := sk.get_bone_global_pose(sk.get_bone_parent(ids[3]))
		var cur := tarsus.basis.y.normalized()
		var turn := Quaternion(cur, down.normalized())
		sk.set_bone_pose_rotation(ids[3], Quaternion((parent.basis.inverse() * Basis(turn) * tarsus.basis).orthonormalized()))

## Turns `bone` so that its child's head lies along `dir` (skeleton space), as client/crew_view.gd RaiseArm does.
static func _aim(sk: Skeleton3D, bone: int, child: int, dir: Vector3) -> void:
	if dir.length() < 1e-5:
		return
	var pg := sk.get_bone_global_pose(sk.get_bone_parent(bone))
	var g := pg * Transform3D(Basis(sk.get_bone_pose_rotation(bone)), sk.get_bone_pose_position(bone))
	var cur := (g.basis * sk.get_bone_pose_position(child)).normalized()
	var turn := Quaternion(cur, dir.normalized())
	sk.set_bone_pose_rotation(bone, Quaternion((pg.basis.inverse() * Basis(turn) * g.basis).orthonormalized()))
