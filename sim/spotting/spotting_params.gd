class_name SpottingParams
extends RefCounted

## The `spotting` section of rules.json, read once.
##
## `Config.f` walks a dotted path on every call, and spotting is evaluated per (step x observer x
## target) — a fifteen-tile move on a six-unit board is several hundred lookups that all return the
## same six numbers. This is those six numbers.
##
## The second reason is better than the first. `Config` records every path it could not resolve in
## `missing`, and `tests/test_config` asserts that list stays empty. Reading every path here, at
## construction, means a mistyped key lands in `missing` the moment a `SpottingParams` is built —
## which a test can force in one line — rather than the first time somebody drives past a hedge.

var point_blank_m: float = 60.0
## Indexed by `Los.Exposure`. The `MASKED` slot is never read: a masked target has already returned.
var exposure_mult: PackedFloat32Array = PackedFloat32Array([0.0, 0.55, 1.0])
var stationary_mult: float = 1.0
var moved_max_mult: float = 1.6
var ghost_turns: int = 2


static func from_config(cfg: Config) -> SpottingParams:
	var p := SpottingParams.new()
	p.point_blank_m = cfg.f("spotting.point_blank_m", 60.0)
	p.stationary_mult = cfg.f("spotting.stationary_mult", 1.0)
	p.moved_max_mult = cfg.f("spotting.moved_max_mult", 1.6)
	p.ghost_turns = cfg.i("spotting.ghost_turns", 2)

	p.exposure_mult = PackedFloat32Array([
		0.0,
		cfg.f("spotting.hull_down_mult", 0.55),
		cfg.f("spotting.exposed_mult", 1.0),
	])
	return p


## How much a unit's movement this turn widens the range it can be seen at.
##
## A ramp rather than a switch. A tank that crept one tile is nearly as quiet as one that never moved;
## a tank that spent its whole allowance is loud. `mp_max` rather than `mp_left` is the denominator on
## purpose — the question is how hard it drove, not how much it has in reserve.
func movement_mult(mp_moved: int, mp_max: int) -> float:
	if mp_moved <= 0 or mp_max <= 0:
		return stationary_mult
	var frac: float = clampf(float(mp_moved) / float(mp_max), 0.0, 1.0)
	return stationary_mult + (moved_max_mult - stationary_mult) * frac
