extends RefCounted
## FD12 passive preview. This reading is per floor and never enters signed progression.

const FULL := 100.0
const NEAR_METRES := 8.0
const DARK := -3.0
const NEAR_RESIDENT := -2.0
const APART := -1.0
const WITH_CREW := 1.0
const WITNESSED_CATCH := 15.0
const SHAKEN_BELOW := 25.0
const SHAKEN_SPRINT := 3.0
const SHAKEN_SEARCH := 4.0

static func step(value: float, dt: float, dark: bool, near_resident: bool, apart: bool, with_crew: bool) -> float:
	var rate := (DARK if dark else 0.0) + (NEAR_RESIDENT if near_resident else 0.0)
	rate += (APART if apart else 0.0) + (WITH_CREW if with_crew else 0.0)
	return clampf(value + rate * dt, 0.0, FULL)

## The host sends the same rates its own step uses. The view can print them without guessing.
static func view(value: float) -> Array[float]:
	return [value, DARK, NEAR_RESIDENT, APART, WITH_CREW, -WITNESSED_CATCH, 1.0 if shaken(value) else 0.0]

static func shaken(value: float) -> bool:
	return value < SHAKEN_BELOW
