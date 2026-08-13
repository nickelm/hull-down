extends TestCase

## A thousand resolutions at fixed range, facing and exposure, from one pinned stream.
##
## The seed is fixed, so this file is deterministic in the strict sense: it passes forever or fails
## forever, and it cannot flake. The assertions are nonetheless **bands and orderings** rather than
## exact counts, because an exact count is a test of the generator's bit pattern rather than of the
## rules — retuning `base_hit_chance` by a thousandth would break it for no reason at all, and the
## next author would delete it rather than read it.
##
## Band width is four standard errors of a binomial proportion at n = 1000, about six points at
## p = 0.5 and narrower at the tails. Four sigma is sized against the **retuning** risk, not the
## sampling risk — with a fixed seed there is no sampling risk.
##
## The loop is stationary only because `HitResolver.resolve_shot` does not mutate: it emits events
## and `EventApplier` applies them, and this file deliberately never applies. A resolver that wrote
## through would degrade its own target across the thousand trials and the measured distribution
## would drift into a band it was never meant to occupy — which would look exactly like a tuning
## problem and would not be one.

const TRIALS: int = 1000
const SIGMAS: float = 4.0
const PINNED_SEED: int = 20260808

var cfg: Config
var hp: HitParams


func setup() -> void:
	cfg = Config.load_default()
	hp = HitParams.from_config(cfg)


## Four standard errors of a binomial proportion at `TRIALS` samples.
func _band(p: float) -> float:
	return SIGMAS * sqrt(maxf(p * (1.0 - p), 0.0001) / float(TRIALS))


func _flat(size: int) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, type_name: String, facing: int) -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), type_name)
	u.side = side
	u.facing = facing
	u.turret = facing
	return u


## Roll `TRIALS` shots at one fixed geometry and tally the outcomes, applying nothing.
##
## `range_tiles` is measured along a row, so the bearing is due east and the plate struck follows
## only from `target_facing` — which is what lets a caller vary the facing and nothing else.
func _run(
	range_tiles: int, target_facing: int, exposure: int,
	firer_type: String = "medium", target_type: String = "medium"
) -> Dictionary:
	var md: MapData = _flat(range_tiles + 12)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 4, firer_type, Grid.E))
	m.add_unit(_unit(md, 2, 4 + range_tiles, 4, target_type, target_facing))

	var rng: RandomNumberGenerator = Rng.stream(PINNED_SEED, Rng.Stream.COMBAT)
	var crit: RandomNumberGenerator = Rng.stream(PINNED_SEED, Rng.Stream.CRITS)

	var out: Dictionary = {
		"fires": 0, "misses": 0, "hits": 0, "penetrations": 0,
		"shreds": 0, "shakes": 0, "criticals": 0, "destroyed": 0,
		"immobilised": 0, "gun_damaged": 0, "trace": PackedStringArray(),
	}

	for _trial: int in TRIALS:
		var events: Array[ActionEvent] = []
		HitResolver.resolve_shot(md, cfg, hp, m, rng, crit, 0, 1, exposure, 0, false, events)
		for e: ActionEvent in events:
			out["trace"].append(e.describe())
			match e.kind:
				ActionEvent.Kind.FIRE: out["fires"] += 1
				ActionEvent.Kind.MISS: out["misses"] += 1
				ActionEvent.Kind.HIT:
					out["hits"] += 1
					if e.penetrated():
						out["penetrations"] += 1
				ActionEvent.Kind.SHRED: out["shreds"] += 1
				ActionEvent.Kind.SHAKEN: out["shakes"] += 1
				ActionEvent.Kind.CRITICAL:
					out["criticals"] += 1
					if e.component() == HitResolver.Component.IMMOBILISED:
						out["immobilised"] += 1
					else:
						out["gun_damaged"] += 1
				ActionEvent.Kind.DESTROYED: out["destroyed"] += 1
				_: pass
	return out


func _hit_rate(r: Dictionary) -> float:
	return float(r["hits"]) / float(TRIALS)


# --- 1. no null results — an exact identity, and completely retune-proof ---------------------------

## docs/decisions/0004's central promise, counted rather than sampled.
##
## Every shot produces exactly one terminal outcome. Every hit that bounced shredded or shook; every
## hit that went through destroyed or crippled. No amount of retuning can break this without breaking
## the rule, which is why it is the first test in the file.
func test_there_are_no_null_results() -> void:
	var r: Dictionary = _run(20, Grid.W, Los.Exposure.EXPOSED)

	assert_eq(r["fires"], TRIALS, "a shot did not produce exactly one FIRE")
	assert_eq(r["misses"] + r["hits"], TRIALS, "a shot neither missed nor hit")

	var bounced: int = r["hits"] - r["penetrations"]
	assert_eq(r["shreds"] + r["shakes"], bounced,
		"a non-penetrating hit did nothing at all — %d bounced, %d shreds, %d shakes"
			% [bounced, r["shreds"], r["shakes"]])
	assert_eq(r["criticals"] + r["destroyed"], r["penetrations"],
		"a penetrating hit did nothing at all — %d through, %d criticals, %d destroyed"
			% [r["penetrations"], r["criticals"], r["destroyed"]])

	# And the whole thousand accounts for itself, exactly once each.
	assert_eq(
		r["misses"] + r["shreds"] + r["shakes"] + r["criticals"] + r["destroyed"], TRIALS,
		"the outcomes do not add up to the shots fired"
	)
	assert_eq(r["immobilised"] + r["gun_damaged"], r["criticals"], "a critical broke nothing")


# --- 2. the curve has the intended shape — orderings, also retune-proof ----------------------------

## Reasoned from the JSON rather than from the code. This is the test that catches an inverted sign,
## and it survives any retune that keeps the design intact.
func test_the_curve_has_the_intended_shape() -> void:
	var near: Dictionary = _run(8, Grid.W, Los.Exposure.EXPOSED)
	var far: Dictionary = _run(90, Grid.W, Los.Exposure.EXPOSED)
	assert_gt(_hit_rate(near), _hit_rate(far), "shots do not get harder with range")

	var exposed: Dictionary = _run(30, Grid.W, Los.Exposure.EXPOSED)
	var hull_down: Dictionary = _run(30, Grid.W, Los.Exposure.HULL_DOWN)
	assert_gt(_hit_rate(exposed), _hit_rate(hull_down), "hull down is no harder to hit")

	# The flanking claim, and the reason the armor model exists. Same gun, same range, same shots —
	# only the plate the target is presenting differs.
	var front: Dictionary = _run(30, Grid.W, Los.Exposure.EXPOSED, "medium", "heavy")
	var rear: Dictionary = _run(30, Grid.E, Los.Exposure.EXPOSED, "medium", "heavy")
	assert_gt(float(rear["penetrations"]), float(front["penetrations"]),
		"getting behind a heavy tank bought nothing: %d through the rear, %d through the front"
			% [rear["penetrations"], front["penetrations"]])

	var close_pen: Dictionary = _run(8, Grid.W, Los.Exposure.EXPOSED, "medium", "heavy")
	var long_pen: Dictionary = _run(90, Grid.W, Los.Exposure.EXPOSED, "medium", "heavy")
	assert_gt(float(close_pen["penetrations"]), float(long_pen["penetrations"]),
		"closing the range did not help the round get through")


## The other half of "no null results" being worth having: a gun that cannot penetrate still does
## something. A light tank shooting a heavy frontally should almost never get through and should
## still be wearing the plate down every time it connects.
func test_a_gun_that_cannot_penetrate_still_makes_progress() -> void:
	var r: Dictionary = _run(30, Grid.W, Los.Exposure.EXPOSED, "light", "heavy")
	assert_eq(r["penetrations"], 0, "a 45 mm gun penetrated a heavy tank's frontal plate")
	assert_gt(float(r["hits"]), 0.0, "the fixture never connected at all")
	assert_eq(r["shreds"] + r["shakes"], r["hits"], "connecting with a useless gun did nothing")
	assert_gt(float(r["shreds"]), 0.0, "no hit ever shredded, so armor cannot be worn down")


# --- 3 & 4. the rates match the stated chances — bands --------------------------------------------

## Mildly tautological, and worth having: it catches an inverted comparison, a `<` for `<=` at the
## clamp, and a shot drawing from the wrong stream.
func test_the_hit_rate_matches_the_stated_chance() -> void:
	var md: MapData = _flat(42)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 4, "medium", Grid.E))
	m.add_unit(_unit(md, 2, 34, 4, "medium", Grid.W))
	var stated: float = HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false)
	assert_in_range(stated, 0.15, 0.9, "the fixture sits against a clamp and tests nothing")

	var r: Dictionary = _run(30, Grid.W, Los.Exposure.EXPOSED)
	assert_almost_eq(_hit_rate(r), stated, _band(stated),
		"the hit rate over %d shots is outside four standard errors of the stated %.3f"
			% [TRIALS, stated])


## A light tank shooting a heavy in the back at eight hundred meters: 55 mm of penetration against
## 55 mm of rear plate, which lands almost exactly in the middle of the band. Chosen that way on
## purpose — at either end the answer is 0 or 1 and the rate tells you nothing about the roll.
const PEN_RANGE_TILES: int = 80
const PEN_TARGET_FACING: int = Grid.E   # facing away, so a shot from the west strikes the rear


func test_the_penetration_rate_matches_the_stated_chance() -> void:
	var md: MapData = _flat(PEN_RANGE_TILES + 12)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 4, "light", Grid.E))
	m.add_unit(_unit(md, 2, 4 + PEN_RANGE_TILES, 4, "heavy", PEN_TARGET_FACING))

	var plate: int = Armor.facing_struck(
		m.unit(1).facing, Armor.bearing(md, m.unit(1).tile, m.unit(0).tile)
	)
	assert_eq(plate, Armor.Facing.REAR, "the fixture is not a rear shot any more")

	var stated: float = HitResolver.pen_chance(
		hp,
		HitResolver.penetration_at_m(cfg, hp, &"light", md.dist_m(m.unit(0).tile, m.unit(1).tile)),
		Armor.current_mm(cfg, m.unit(1), plate)
	)
	assert_in_range(stated, 0.1, 0.9, "the fixture sits at an end of the band and tests nothing")

	var r: Dictionary = _run(PEN_RANGE_TILES, PEN_TARGET_FACING, Los.Exposure.EXPOSED, "light", "heavy")
	assert_gt(float(r["hits"]), 200.0, "too few hits to say anything about penetration")
	var rate: float = float(r["penetrations"]) / float(r["hits"])
	assert_almost_eq(rate, stated, _band(stated),
		"the penetration rate over %d hits is outside four standard errors of the stated %.3f"
			% [r["hits"], stated])


## The shred/shake split, which is the one number in 0029 that has no other test.
func test_the_shred_and_shake_split_matches_its_share() -> void:
	var r: Dictionary = _run(30, Grid.W, Los.Exposure.EXPOSED, "light", "heavy")
	var bounced: int = r["shreds"] + r["shakes"]
	assert_gt(float(bounced), 100.0, "too few bounces to say anything")
	assert_almost_eq(
		float(r["shreds"]) / float(bounced), hp.shred_share, _band(hp.shred_share) * 2.0,
		"the shred share is not the share the rules give it"
	)


# --- 5. reproducibility, and that the streams are genuinely separate -------------------------------

## The test that proves 0005's stream separation is load-bearing rather than decorative.
##
## Run the thousand twice from freshly seeded streams and the sequences must hash identically. Then
## run a third time with the `AI` stream drawn from between every shot, and the combat sequence must
## still be **bit-identical** — because adding an AI call must never shift a combat roll.
func test_a_thousand_resolutions_are_reproducible_under_interleaving() -> void:
	var first: Dictionary = _run(20, Grid.W, Los.Exposure.EXPOSED)
	var second: Dictionary = _run(20, Grid.W, Los.Exposure.EXPOSED)
	assert_eq(
		Rng.fnv1a("\n".join(first["trace"])), Rng.fnv1a("\n".join(second["trace"])),
		"two identically seeded runs produced different outcomes"
	)

	var md: MapData = _flat(32)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 4, "medium", Grid.E))
	m.add_unit(_unit(md, 2, 24, 4, "medium", Grid.W))

	var rng: RandomNumberGenerator = Rng.stream(PINNED_SEED, Rng.Stream.COMBAT)
	var crit: RandomNumberGenerator = Rng.stream(PINNED_SEED, Rng.Stream.CRITS)
	var ai: RandomNumberGenerator = Rng.stream(PINNED_SEED, Rng.Stream.AI)

	var trace := PackedStringArray()
	for _trial: int in TRIALS:
		for _think: int in 3:
			ai.randf()
		var events: Array[ActionEvent] = []
		HitResolver.resolve_shot(
			md, cfg, hp, m, rng, crit, 0, 1, Los.Exposure.EXPOSED, 0, false, events
		)
		for e: ActionEvent in events:
			trace.append(e.describe())

	assert_eq(Rng.fnv1a("\n".join(trace)), Rng.fnv1a("\n".join(first["trace"])),
		"drawing from the AI stream between shots changed the combat outcomes")


## And the critical *component* comes from `CRITS`, not `COMBAT` — so the criticals that happen split
## between the two components at the share the rules give, independently of everything rolled before
## them. This is the first place the fourth stream earns its keep.
func test_the_critical_component_splits_at_its_share() -> void:
	var r: Dictionary = _run(20, Grid.E, Los.Exposure.EXPOSED, "heavy", "light")
	assert_gt(float(r["criticals"]), 40.0, "too few criticals to say anything")
	assert_almost_eq(
		float(r["immobilised"]) / float(r["criticals"]),
		hp.critical_immobilised_share,
		_band(hp.critical_immobilised_share) * 3.0,
		"the two components do not come up at the share the rules give them"
	)
