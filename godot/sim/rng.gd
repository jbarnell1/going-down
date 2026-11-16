# Seeded random numbers. Everything about a building comes from one seed, so every player
# who has the seed builds the same floors. No engine randomness anywhere in sim/.
# Port of src/sim/rng.ts (mulberry32 seeded by a 32-bit FNV-1a hash); bit for bit the same.
extends RefCounted

const M = preload("res://sim/jsmath.gd")
const Rng = preload("res://sim/rng.gd")

## The seed this generator was made from (TypeScript: the closure's `base`).
var base: int
## The running 32-bit state (TypeScript: the closure's `a`), kept unsigned.
var a: int

func _init(seed32: int) -> void:
	base = seed32 & M.MASK32
	a = base

## Turns any string into a 32-bit seed. (TypeScript hashes UTF-16 code units; seeds are ASCII.)
static func hash_seed(text: String) -> int:
	var h := 2166136261
	for i in text.length():
		h ^= text.unicode_at(i)
		h = M.imul(h, 16777619)
	return h & M.MASK32

## makeRng(seed): a String is hashed, an int is taken as `seed >>> 0`.
static func make_rng(seed: Variant) -> Rng:
	if seed is String or seed is StringName:
		return new(hash_seed(String(seed)))
	return new(int(seed) & M.MASK32)

## A float in [0, 1).
func next() -> float:
	a = (a + 0x6d2b79f5) & M.MASK32
	var t := M.imul(a ^ (a >> 15), 1 | a)
	t = M.to_int32(t + M.imul(t ^ ((t & M.MASK32) >> 7), 61 | t)) ^ t
	return float((t ^ ((t & M.MASK32) >> 14)) & M.MASK32) / 4294967296.0

## An integer in [min, max], both included. (TypeScript: int)
func int_in(lo: int, hi: int) -> int:
	return lo + int(floor(next() * float(hi - lo + 1)))

## True with the given probability.
func chance(p: float) -> bool:
	return next() < p

## One item from a non-empty list.
func pick(items: Array) -> Variant:
	if items.is_empty():
		push_error("pick from an empty list")
		return null
	return items[int(floor(next() * float(items.size())))]

## pick() for a packed int list.
func pick_int(items: PackedInt32Array) -> int:
	if items.is_empty():
		push_error("pick from an empty list")
		return 0
	return items[int(floor(next() * float(items.size())))]

## A new, independent generator derived from this seed and a label. Drawing from it does not disturb this one.
func fork(label: String) -> Rng:
	return new(hash_seed("%d:%s" % [base, label]))
