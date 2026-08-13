class_name HitResolver
extends RefCounted

## The two rolls of docs/decisions/0004, and the no-null-results branch of 0029.
##
## **`resolve_shot` is pure except for its draws.** It reads the board, rolls, and *emits* events;
## `EventApplier` is what changes anything. That is not fastidiousness — it is what makes the
## thousand-resolution statistical test stationary. A resolver that wrote through would degrade its
## own target across the loop, and the measured distribution would drift into a band it was never
## meant to occupy, which looks exactly like a tuning problem and is not one.
##
## **Draw order is contract.** To hit, then penetration, then the shred/shake split, then whether a
## penetration cripples instead of killing — all from `COMBAT`. The *component* that breaks comes from
## `CRITS`. That separation is the first real use of 0005's named streams: adding a shred roll can
## never reshuffle which component a critical takes out.

## Which component a critical took out. Two in iteration 2, and 0004 names both.
enum Component { IMMOBILISED = 0, GUN_DAMAGED = 1 }


## The chance a shot connects, before anything is rolled. Clamped, so there is neither a certainty
## nor a hopeless shot — the clamp is the rule that keeps a bad position survivable and a good one
## from being a formality.
static func hit_chance(
	md: MapData, cfg: Config, p: HitParams, state: MatchState,
	firer: int, target: int, exposure: int, overwatch: bool
) -> float:
	var f: UnitState = state.unit(firer)
	var t: UnitState = state.unit(target)
	if f == null or t == null or exposure == Los.Exposure.MASKED:
		return 0.0

	var gun: Dictionary = cfg.unit(String(f.unit_type)).get("gun", {})
	var chance: float = p.base_hit_chance * float(gun.get("accuracy", 1.0))

	# Range costs accuracy beyond point blank, and only beyond it. Inside that band a gun is as good
	# as it gets, which is what makes closing worth the exposure it costs.
	var range_m: float = md.dist_m(f.tile, t.tile)
	var over: float = maxf(range_m - p.point_blank_m, 0.0)
	chance -= (over / 100.0) * p.range_falloff_per_100m

	chance *= p.exposure_hit_mult[clampi(exposure, 0, p.exposure_hit_mult.size() - 1)]
	if f.mp_moved > 0:
		chance *= p.firer_moved_mult
	if t.mp_moved > 0:
		chance *= p.target_moved_mult
	if f.shaken_turns > 0:
		chance *= p.shaken_hit_mult
	if f.gun_damaged:
		chance *= p.gun_damaged_hit_mult
	if overwatch:
		chance *= p.overwatch_hit_mult

	# Shooting downhill is worth a little, and it is capped so that a tall hill is not a win
	# condition. Measured in the 0.5 m quanta `MapData` already stores.
	var drop: int = md.level[f.tile] - md.level[t.tile]
	chance += clampf(
		float(drop) * p.elevation_bonus_per_level, -p.max_elevation_bonus, p.max_elevation_bonus
	)

	return clampf(chance, p.min_hit_chance, p.max_hit_chance)


## What a gun's round will still go through at a given range.
##
## `gun.penetration_mm` is quoted at 1000 m, so the falloff is measured from there: closer is better,
## further is worse, and the whole thing has a floor so that a very long shot is weak rather than
## harmless.
static func penetration_at_m(cfg: Config, p: HitParams, unit_type: StringName, range_m: float) -> float:
	var gun: Dictionary = cfg.unit(String(unit_type)).get("gun", {})
	var nominal: float = float(gun.get("penetration_mm", 0))
	var delta: float = (range_m - HitParams.PEN_REFERENCE_M) / 100.0
	return nominal * maxf(1.0 - delta * p.pen_falloff_per_100m, p.pen_min_fraction)


## The chance a round defeats a plate, as a band around the ratio rather than a step.
##
## A step at parity would make every engagement a lookup: either your gun works on that tank or it
## does not, and there is nothing to play. The band is deliberately wide, so "nearly enough" is a
## frequent, legible outcome — the shot that shreds instead of killing, and shreds the plate that
## makes the *next* shot work.
static func pen_chance(p: HitParams, pen_mm: float, plate_mm: int) -> float:
	if plate_mm <= 0:
		return 1.0
	var ratio: float = pen_mm / float(plate_mm)
	if ratio <= p.no_pen_ratio:
		return 0.0
	if ratio >= p.certain_pen_ratio:
		return 1.0
	return (ratio - p.no_pen_ratio) / maxf(p.certain_pen_ratio - p.no_pen_ratio, 0.0001)


## Resolve one round and append what happened to `out`. Rolls; changes nothing.
##
## Emits exactly one outcome chain per shot, which is 0004's central promise as a shape rather than a
## sentence: `FIRE`, then `MISS` or `HIT`, and after a `HIT` exactly one of `SHRED`, `SHAKEN`,
## `CRITICAL` or `DESTROYED`. There is no path through this function that produces a hit and nothing
## else.
static func resolve_shot(
	md: MapData, cfg: Config, p: HitParams, state: MatchState,
	rng: RandomNumberGenerator, crit_rng: RandomNumberGenerator,
	firer: int, target: int, exposure: int, ordinal: int, overwatch: bool,
	out: Array[ActionEvent]
) -> void:
	var f: UnitState = state.unit(firer)
	var t: UnitState = state.unit(target)
	if f == null or t == null:
		return

	var range_m: float = md.dist_m(f.tile, t.tile)
	var mp_after: int = f.mp_after_action(cfg) if ordinal == 0 and not overwatch else f.mp_left

	# Ammunition and the reveal flag ride on the FIRE event, as absolute snapshots — `EventApplier`
	# assigns rather than decrements, for the reason 0026 gives.
	var flags: int = ActionEvent.F_OVERWATCH if overwatch else 0
	out.append(ActionEvent.fire(
		firer, target, ordinal, t.tile, f.turret, mp_after, maxi(f.ammo - ordinal - 1, 0), flags
	))

	if rng.randf() >= hit_chance(md, cfg, p, state, firer, target, exposure, overwatch):
		out.append(ActionEvent.miss(firer, target, t.tile, mp_after, flags))
		return

	var bearing: int = Armor.bearing(md, t.tile, f.tile)
	var plate: int = Armor.facing_struck(t.facing, bearing)
	var plate_mm: int = Armor.current_mm(cfg, t, plate)
	var pen_mm: float = penetration_at_m(cfg, p, f.unit_type, range_m)
	var went_through: bool = rng.randf() < pen_chance(p, pen_mm, plate_mm)

	out.append(ActionEvent.hit(firer, target, t.tile, mp_after, plate, went_through, flags))

	if not went_through:
		# No null results — 0004. A hit that bounces still shreds the plate or shakes the crew, so a
		# player who set up a flank and connected has made progress on a bad penetration roll.
		if rng.randf() < p.shred_share:
			var gun: Dictionary = cfg.unit(String(f.unit_type)).get("gun", {})
			var nominal: int = int(gun.get("shred_mm", p.shred_min_mm))
			# Scaled by how close the round came. A shot that nearly got through takes more off than
			# one that spanged away, which is what makes shredding a heavy with a light gun slow
			# rather than impossible.
			var ratio: float = pen_mm / float(maxi(plate_mm, 1))
			var mm: int = maxi(
				int(round(float(nominal) * clampf(ratio * p.shred_ratio_scale, 0.0, 1.0))),
				p.shred_min_mm
			)
			out.append(ActionEvent.shred(firer, target, t.tile, mp_after, plate, mm, flags))
		else:
			out.append(ActionEvent.shaken(firer, target, t.tile, mp_after, p.shaken_turns, flags))
		return

	# It went through. Mostly that is the end of the tank; sometimes the round finds a component
	# instead of a crew compartment and leaves something that still fights badly.
	if rng.randf() < p.critical_chance:
		# The component comes from CRITS, not COMBAT — 0005. Adding a roll above must never change
		# which part breaks, and this is the line where that promise is kept.
		var component: int = (
			Component.IMMOBILISED if crit_rng.randf() < p.critical_immobilised_share
			else Component.GUN_DAMAGED
		)
		out.append(ActionEvent.critical(firer, target, t.tile, mp_after, component, flags))
	else:
		out.append(ActionEvent.destroyed(firer, target, t.tile, mp_after, flags))
