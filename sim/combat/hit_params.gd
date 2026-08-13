class_name HitParams
extends RefCounted

## The `combat` section of rules.json, read once — the counterpart of `SpottingParams`, and for the
## same two reasons: the dotted-path walk is not free on a hot path, and reading every key at
## construction means a mistyped one lands in `Config.missing` where a test can see it rather than
## the first time somebody pulls a trigger.

var base_hit_chance: float = 0.95
var range_falloff_per_100m: float = 0.045
var min_hit_chance: float = 0.05
var max_hit_chance: float = 0.95
var point_blank_m: float = 100.0

## Indexed by `Los.Exposure`. The `MASKED` slot is never read — a masked target cannot be shot at.
var exposure_hit_mult: PackedFloat32Array = PackedFloat32Array([0.0, 0.55, 1.0])
var firer_moved_mult: float = 0.70
var target_moved_mult: float = 0.85
var shaken_hit_mult: float = 0.75
var gun_damaged_hit_mult: float = 0.50
var overwatch_hit_mult: float = 0.80

var elevation_bonus_per_level: float = 0.010
var max_elevation_bonus: float = 0.10

var no_pen_ratio: float = 0.80
var certain_pen_ratio: float = 1.30
var pen_falloff_per_100m: float = 0.025
var pen_min_fraction: float = 0.35

var shred_share: float = 0.65
var shred_min_mm: int = 1
var shred_ratio_scale: float = 1.0
var shaken_turns: int = 1

var critical_chance: float = 0.35
var critical_immobilised_share: float = 0.50

var default_ammo: int = 12
var shots_end_the_turn: bool = true
var turret_arc_steps: int = 3
var wreck_blocker_h_m: float = 2.0

var overwatch_shots: int = 1
var overwatch_arc_steps: int = 2
var overwatch_interrupts_move: bool = true

## The range `gun.penetration_mm` is quoted at, from the roster's own comment. A structural fact about
## how the data is written rather than a tunable — moving it would silently rescale every gun.
const PEN_REFERENCE_M: float = 1000.0


static func from_config(cfg: Config) -> HitParams:
	var p := HitParams.new()
	p.base_hit_chance = cfg.f("combat.base_hit_chance", 0.95)
	p.range_falloff_per_100m = cfg.f("combat.range_falloff_per_100m", 0.045)
	p.min_hit_chance = cfg.f("combat.min_hit_chance", 0.05)
	p.max_hit_chance = cfg.f("combat.max_hit_chance", 0.95)
	p.point_blank_m = cfg.f("combat.point_blank_m", 100.0)

	p.exposure_hit_mult = PackedFloat32Array([
		0.0,
		cfg.f("combat.hull_down_hit_mult", 0.55),
		cfg.f("combat.exposed_hit_mult", 1.0),
	])
	p.firer_moved_mult = cfg.f("combat.firer_moved_mult", 0.70)
	p.target_moved_mult = cfg.f("combat.target_moved_mult", 0.85)
	p.shaken_hit_mult = cfg.f("combat.shaken_hit_mult", 0.75)
	p.gun_damaged_hit_mult = cfg.f("combat.gun_damaged_hit_mult", 0.50)
	p.overwatch_hit_mult = cfg.f("combat.overwatch_hit_mult", 0.80)

	p.elevation_bonus_per_level = cfg.f("combat.elevation_bonus_per_level", 0.010)
	p.max_elevation_bonus = cfg.f("combat.max_elevation_bonus", 0.10)

	p.no_pen_ratio = cfg.f("combat.no_pen_ratio", 0.80)
	p.certain_pen_ratio = cfg.f("combat.certain_pen_ratio", 1.30)
	p.pen_falloff_per_100m = cfg.f("combat.pen_falloff_per_100m", 0.025)
	p.pen_min_fraction = cfg.f("combat.pen_min_fraction", 0.35)

	p.shred_share = cfg.f("combat.shred_share", 0.65)
	p.shred_min_mm = cfg.i("combat.shred_min_mm", 1)
	p.shred_ratio_scale = cfg.f("combat.shred_ratio_scale", 1.0)
	p.shaken_turns = cfg.i("combat.shaken_turns", 1)

	p.critical_chance = cfg.f("combat.critical_chance", 0.35)
	p.critical_immobilised_share = cfg.f("combat.critical_immobilised_share", 0.50)

	p.default_ammo = cfg.i("combat.default_ammo", 12)
	p.shots_end_the_turn = cfg.b("combat.shots_end_the_turn", true)
	p.turret_arc_steps = cfg.i("combat.turret_arc_steps", 3)
	p.wreck_blocker_h_m = cfg.f("combat.wreck_blocker_h_m", 2.0)

	p.overwatch_shots = cfg.i("combat.overwatch_shots", 1)
	p.overwatch_arc_steps = cfg.i("combat.overwatch_arc_steps", 2)
	p.overwatch_interrupts_move = cfg.b("combat.overwatch_interrupts_move", true)
	return p
