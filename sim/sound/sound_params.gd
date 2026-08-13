class_name SoundParams
extends RefCounted

## The `sound` section of rules.json, read once. The sibling of `SpottingParams`, for both of its
## reasons.
##
## The first is cost: the sound pass runs per (noise x hearing side x candidate listener), and every
## one of those would otherwise walk a dotted path to fetch the same seven numbers.
##
## The second is better. `Config` records every path it could not resolve in `missing`, and
## `tests/test_config` asserts that list stays empty. Reading every path here, at construction, means a
## mistyped key lands in `missing` the moment a `SoundParams` is built — which a test forces in one
## line — rather than the first time somebody fires a gun with nobody looking.

## How far each kind of noise carries. Deliberately much further than optics, which run 320–500 m
## against a measured median clear sightline of 141 m: hearing something you cannot see is the entire
## point of the layer, and a radius inside optics range would make it decoration.
var fire_radius_m: float = 1200.0
var move_radius_m: float = 500.0
## The fraction of its allowance a unit has to spend before the drive is worth hearing.
var noisy_mp_frac: float = 0.35

var error_base_m: float = 20.0
var error_per_100m: float = 18.0
var error_max_m: float = 200.0
var turns: int = 1


static func from_config(cfg: Config) -> SoundParams:
	var p := SoundParams.new()
	p.fire_radius_m = cfg.f("sound.fire_radius_m", 1200.0)
	p.move_radius_m = cfg.f("sound.move_radius_m", 500.0)
	p.noisy_mp_frac = cfg.f("sound.noisy_mp_frac", 0.35)
	p.error_base_m = cfg.f("sound.error_base_m", 20.0)
	p.error_per_100m = cfg.f("sound.error_per_100m", 18.0)
	p.error_max_m = cfg.f("sound.error_max_m", 200.0)
	p.turns = cfg.i("sound.turns", 1)
	return p


func radius_m(source: int) -> float:
	return move_radius_m if source == SideSound.Source.MOVE else fire_radius_m


## How wrong the marker is, given how far the noise was from the hearing side's nearest unit.
##
## Grows with distance and then stops. The floor is not zero — even a noise next door places to a tile
## or two, and an error of zero would put the marker exactly on the tank, which is a sighting. The
## ceiling is what keeps a contact on the far side of the map from being a ripple the size of the
## board, saying nothing while covering everything.
##
## Returned in **decimeters**, as an integer, because this figure is stored, fingerprinted and shipped
## through an event, and the one thing it must never do is come back different on a replay.
func error_dm(dist_m: float) -> int:
	var m: float = error_base_m + error_per_100m * (maxf(dist_m, 0.0) / 100.0)
	return int(round(minf(m, error_max_m) * 10.0))


## Whether a move that spent `mp_moved` of `mp_max` was worth hearing.
##
## `mp_max` rather than `mp_left` is the denominator for the reason `SpottingParams.movement_mult`
## gives: the question is how hard it drove, not what it has in reserve. Unlike that one this is a
## threshold rather than a ramp — a contact either exists or it does not, and there is no third thing
## for a fractional loudness to express.
func is_noisy_move(mp_moved: int, mp_max: int) -> bool:
	if mp_moved <= 0 or mp_max <= 0:
		return false
	return float(mp_moved) / float(mp_max) >= noisy_mp_frac
