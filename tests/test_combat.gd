extends TestCase

## Combat resolution — docs/decisions/0004, 0029 and 0031.
##
## The rules, with a fixed stream wherever a draw is needed. The *distributions* are
## `tests/test_combat_distribution.gd`; this file is about answers that have to be exactly right.

var cfg: Config
var sp: SpottingParams
var hp: HitParams


func setup() -> void:
	cfg = Config.load_default()
	sp = SpottingParams.from_config(cfg)
	hp = HitParams.from_config(cfg)


func _flat(size: int = 24) -> MapData:
	var md := MapData.create(size)
	md.move_cost.fill(10)
	md.terrain.fill(TerrainTyper.Type.OPEN)
	Quantizer.classify_transitions(md, cfg)
	return md


func _unit(md: MapData, side: int, x: int, y: int, type_name: String = "medium") -> UnitState:
	var u: UnitState = UnitState.create(md, cfg, md.idx(x, y), type_name)
	u.side = side
	u.facing = Grid.E
	u.turret = Grid.E
	return u


## A firer at (4,12) and a target at (10,12) — sixty meters apart, in the open, seen by both sides.
func _duel(md: MapData, firer_type: String = "medium", target_type: String = "medium") -> MatchState:
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 4, 12, firer_type))
	m.add_unit(_unit(md, 2, 10, 12, target_type))
	Spotting.recompute_all(md, cfg, sp, m)
	return m


func _resolver(md: MapData, m: MatchState, seed_value: int = 4242) -> ActionResolver:
	return ActionResolver.new(md, cfg, m, seed_value)


# --- which plate a shot lands on ------------------------------------------------------------------

## All sixty-four `(hull, bearing)` pairs against a table written independently of the one under
## test. Front takes three eighths of the circle, each side two, the rear one — and getting
## *directly* behind is therefore worth strictly more than reaching a rear quarter, which is the
## geometry 0004's "position is the primary damage multiplier" rests on.
func test_every_bearing_lands_on_the_plate_it_should() -> void:
	# Independently written: for each relative bearing, the plate it must strike.
	var expected: Array[int] = [
		Armor.Facing.FRONT,   # 0 — dead ahead
		Armor.Facing.FRONT,   # 1
		Armor.Facing.RIGHT,   # 2
		Armor.Facing.RIGHT,   # 3
		Armor.Facing.REAR,    # 4 — dead astern
		Armor.Facing.LEFT,    # 5
		Armor.Facing.LEFT,    # 6
		Armor.Facing.FRONT,   # 7
	]
	var tally: Array[int] = [0, 0, 0, 0, 0]
	for hull: int in 8:
		for bearing: int in 8:
			var got: int = Armor.facing_struck(hull, bearing)
			assert_eq(got, expected[posmod(bearing - hull, 8)],
				"hull %d shot from %d landed on the wrong plate" % [hull, bearing])
			if hull == 0:
				tally[got] += 1

	assert_eq(tally[Armor.Facing.FRONT], 3, "the front does not cover three eighths of the circle")
	assert_eq(tally[Armor.Facing.LEFT], 2, "the left side does not cover two eighths")
	assert_eq(tally[Armor.Facing.RIGHT], 2, "the right side does not cover two eighths")
	assert_eq(tally[Armor.Facing.REAR], 1, "the rear is not the narrowest arc on the tank")
	assert_eq(tally[Armor.Facing.TOP], 0, "direct fire struck the roof")


## The bug this function exists to avoid, as a regression test for something that has not happened.
##
## `Grid.dir_between` snaps by sign, so ten tiles east and one north comes back NE — and a tank being
## shot squarely in the side would take it on the front-right plate. `Armor.bearing` quantizes by
## angle instead, in integers, because 0010 says float determinism is not promised across engine
## versions and the boundary cases really do occur.
func test_a_shallow_angle_is_a_flank_shot_and_not_a_diagonal() -> void:
	var md: MapData = _flat(40)
	var from: int = md.idx(20, 20)

	assert_eq(Armor.bearing(md, from, md.idx(30, 19)), Grid.E,
		"ten east and one north was not read as a flank shot")
	assert_eq(Grid.dir_between(20, 20, 30, 19), Grid.NE,
		"the fixture no longer demonstrates the difference it was written for")

	# The octant boundary itself. 5/12 is 22.6 degrees — a tenth of a degree past the line.
	assert_eq(Armor.bearing(md, from, md.idx(32, 25)), Grid.SE, "just past the boundary is diagonal")
	assert_eq(Armor.bearing(md, from, md.idx(32, 24)), Grid.E, "just inside the boundary is lateral")

	assert_eq(Armor.bearing(md, from, from), -1, "a shot from a tile onto itself has a bearing")


func test_the_eight_cardinal_bearings_are_right() -> void:
	var md: MapData = _flat(40)
	var from: int = md.idx(20, 20)
	assert_eq(Armor.bearing(md, from, md.idx(20, 10)), Grid.N, "north")
	assert_eq(Armor.bearing(md, from, md.idx(30, 10)), Grid.NE, "north-east")
	assert_eq(Armor.bearing(md, from, md.idx(30, 20)), Grid.E, "east")
	assert_eq(Armor.bearing(md, from, md.idx(30, 30)), Grid.SE, "south-east")
	assert_eq(Armor.bearing(md, from, md.idx(20, 30)), Grid.S, "south")
	assert_eq(Armor.bearing(md, from, md.idx(10, 30)), Grid.SW, "south-west")
	assert_eq(Armor.bearing(md, from, md.idx(10, 20)), Grid.W, "west")
	assert_eq(Armor.bearing(md, from, md.idx(10, 10)), Grid.NW, "north-west")


# --- armor never regenerates ---------------------------------------------------------------------

## 0004, as an assertion rather than a sentence. Fifty hits on one plate: thickness is non-increasing
## at every step and never goes below zero — a plate shredded to nothing is paper, not a hole that
## penetrates itself.
func test_armor_only_ever_falls() -> void:
	var md: MapData = _flat()
	var u: UnitState = _unit(md, 2, 10, 12, "heavy")
	var last: int = Armor.current_mm(cfg, u, Armor.Facing.FRONT)
	assert_gt(float(last), 0.0, "the fixture starts with no armor")

	for _shot: int in 50:
		Armor.shred(cfg, u, Armor.Facing.FRONT, 16)
		var now: int = Armor.current_mm(cfg, u, Armor.Facing.FRONT)
		assert_le(float(now), float(last), "a plate got thicker")
		assert_ge(float(now), 0.0, "a plate went negative")
		last = now
	assert_eq(last, 0, "fifty heavy hits did not strip the plate")

	# And shredding one plate leaves the others alone.
	assert_eq(Armor.current_mm(cfg, u, Armor.Facing.REAR),
		Armor.base_mm(cfg, u.unit_type, Armor.Facing.REAR),
		"shredding the front thinned the rear")


# --- the two rolls --------------------------------------------------------------------------------

## Monotone in range, and clamped at both ends. The clamp is the rule that keeps a bad position
## survivable and a good one from being a formality.
func test_the_hit_chance_falls_with_range_and_stays_inside_its_clamp() -> void:
	var md: MapData = _flat(120)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 5, 60))
	m.add_unit(_unit(md, 2, 10, 60))
	Spotting.recompute_all(md, cfg, sp, m)

	var last: float = 2.0
	for x: int in [10, 20, 40, 60, 90, 115]:
		m.unit(1).tile = md.idx(x, 60)
		var chance: float = HitResolver.hit_chance(
			md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false
		)
		assert_in_range(chance, hp.min_hit_chance, hp.max_hit_chance, "the clamp leaked at x=%d" % x)
		assert_le(chance, last, "the hit chance rose with range between %d and there" % x)
		last = chance


## Every modifier is a penalty, and each is asserted on its own rather than through a scenario that
## moves several at once.
func test_each_modifier_makes_the_shot_worse() -> void:
	var md: MapData = _flat()
	var m: MatchState = _duel(md)
	var base: float = HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false)

	assert_lt(HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.HULL_DOWN, false), base,
		"a hull-down target is no harder to hit than one in the open")
	assert_lt(HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, true), base,
		"reaction fire is no worse than a deliberate shot")
	assert_eq(HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.MASKED, false), 0.0,
		"a masked target can be shot at")

	m.unit(0).mp_moved = 100
	assert_lt(HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false), base,
		"firing on the move costs nothing")
	m.unit(0).mp_moved = 0

	m.unit(0).shaken_turns = 1
	assert_lt(HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false), base,
		"a shaken crew shoots as well as a steady one")
	m.unit(0).shaken_turns = 0

	m.unit(0).gun_damaged = true
	assert_lt(HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false), base,
		"a damaged gun shoots as well as a working one")


## Height is worth a little, and only a little — the cap is what stops a tall hill being a win
## condition.
func test_shooting_downhill_helps_and_is_capped() -> void:
	# Far enough out that range has pulled the base chance clear of the clamp. At sixty meters a
	# medium gun is already at `max_hit_chance` and the bonus has nowhere to go — which is correct
	# behavior and would make this test pass or fail for the wrong reason.
	var md: MapData = _flat(60)
	var m: MatchState = MatchState.create(2)
	m.add_unit(_unit(md, 1, 5, 30))
	m.add_unit(_unit(md, 2, 45, 30))
	Spotting.recompute_all(md, cfg, sp, m)

	var level: float = HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false)
	assert_lt(level, hp.max_hit_chance, "the fixture is still pinned against the clamp")

	md.level[m.unit(0).tile] = 8
	var uphill: float = HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false)
	assert_gt(uphill, level, "height bought the gunner nothing")

	md.level[m.unit(0).tile] = 400
	var mountain: float = HitResolver.hit_chance(md, cfg, hp, m, 0, 1, Los.Exposure.EXPOSED, false)
	assert_le(mountain - level, hp.max_elevation_bonus + 0.0001,
		"the elevation bonus is not capped")


## The penetration band, at its boundaries exactly. `<` against `<=` here is a silent
## one-in-a-thousand bug that nothing else would ever surface.
func test_the_penetration_band_is_exact_at_its_edges() -> void:
	var plate: int = 100
	assert_eq(HitResolver.pen_chance(hp, float(plate) * hp.no_pen_ratio, plate), 0.0,
		"a round exactly at the no-penetration ratio got through sometimes")
	assert_eq(HitResolver.pen_chance(hp, float(plate) * hp.certain_pen_ratio, plate), 1.0,
		"a round exactly at the certain-penetration ratio bounced sometimes")
	assert_eq(HitResolver.pen_chance(hp, float(plate) * (hp.no_pen_ratio - 0.01), plate), 0.0,
		"a round below the band got through")
	assert_eq(HitResolver.pen_chance(hp, float(plate) * (hp.certain_pen_ratio + 0.01), plate), 1.0,
		"a round above the band bounced")

	# Monotone in between, and genuinely a band rather than a step.
	var mid: float = HitResolver.pen_chance(
		hp, float(plate) * (hp.no_pen_ratio + hp.certain_pen_ratio) * 0.5, plate
	)
	assert_in_range(mid, 0.05, 0.95, "the middle of the band is effectively a step")
	assert_eq(HitResolver.pen_chance(hp, 50.0, 0), 1.0, "a plate of nothing stopped a round")


## Penetration falls off with range and has a floor, and it is quoted at 1000 m — so that is where
## the nominal figure has to come back exactly, or every gun in the roster is secretly rescaled.
func test_penetration_is_quoted_at_a_thousand_meters_and_falls_off_from_there() -> void:
	var nominal: float = float((cfg.unit("medium")["gun"] as Dictionary)["penetration_mm"])
	assert_almost_eq(
		HitResolver.penetration_at_m(cfg, hp, &"medium", HitParams.PEN_REFERENCE_M), nominal, 0.01,
		"the gun does not deliver its quoted penetration at the range it is quoted at"
	)
	assert_gt(HitResolver.penetration_at_m(cfg, hp, &"medium", 200.0), nominal,
		"closing the range bought nothing")
	assert_lt(HitResolver.penetration_at_m(cfg, hp, &"medium", 2000.0), nominal,
		"range cost nothing")
	assert_ge(HitResolver.penetration_at_m(cfg, hp, &"medium", 100000.0), nominal * hp.pen_min_fraction,
		"penetration fell through its floor")


# --- the forecast cannot lie ----------------------------------------------------------------------

## The preview and the shot have to agree field by field. A forecast that can silently disagree with
## what the shot actually charged is the worst bug this game can have, because it does not look like
## a bug — it looks like bad luck.
func test_the_forecast_agrees_with_the_shot_it_forecasts() -> void:
	var md: MapData = _flat()
	var m: MatchState = _duel(md)
	var resolver: ActionResolver = _resolver(md, m)

	var f: FireForecast = resolver.preview_fire(0, 1)
	assert_true(f.ok(), "the fixture cannot fire: %d" % f.status)

	var target: UnitState = m.unit(1)
	var expect_plate: int = Armor.facing_struck(
		target.facing, Armor.bearing(md, target.tile, m.unit(0).tile)
	)
	assert_eq(f.facing_struck, expect_plate, "the forecast names the wrong plate")
	assert_eq(f.plate_mm, Armor.current_mm(cfg, target, expect_plate),
		"the forecast disagrees about how thick that plate is")
	assert_almost_eq(f.range_m, md.dist_m(m.unit(0).tile, target.tile), 0.01, "range")
	assert_eq(f.exposure, Los.classify(md, cfg, m.unit(0).tile, target.tile), "exposure")
	assert_eq(f.shots, FireAction.shots_for(cfg, m.unit(0)), "shots per action")

	var r: ActionResult = resolver.resolve_fire(0, 1)
	assert_true(r.ok(), "the shot was refused after the forecast said it was legal")
	for e: ActionEvent in r.events:
		if e.kind == ActionEvent.Kind.HIT:
			assert_eq(e.plate(), f.facing_struck, "the shot struck a different plate from the forecast")


## The preview is pure: calling it does not advance a stream, so hovering cannot change a roll.
func test_previewing_does_not_move_the_dice() -> void:
	var md: MapData = _flat()
	var a: MatchState = _duel(md)
	var b: MatchState = _duel(md)

	var ra: ActionResolver = _resolver(md, a)
	for _hover: int in 50:
		ra.preview_fire(0, 1)
	var with_hover: int = ra.resolve_fire(0, 1).fingerprint()

	var without: int = _resolver(md, b).resolve_fire(0, 1).fingerprint()
	assert_eq(with_hover, without, "hovering over a target changed the shot that followed")


# --- what firing costs ----------------------------------------------------------------------------

## Firing spends a round, forfeits the rest of the action in progress (0021 — `commit_action`'s first
## caller), reveals the firer, and ends its turn (0003).
func test_firing_costs_a_whole_action_and_the_turn() -> void:
	var md: MapData = _flat()
	var m: MatchState = _duel(md)
	var f: UnitState = m.unit(0)
	# Captured before the shot: `shots_for` is capped by what is in the racks, so asking afterwards
	# would be asking about a different tank.
	var ammo: int = f.ammo
	var shots: int = FireAction.shots_for(cfg, f)
	var expected_mp: int = f.mp_after_action(cfg)

	var r: ActionResult = _resolver(md, m).resolve_fire(0, 1)
	assert_true(r.ok(), "the shot was refused: %d" % r.status)

	assert_eq(f.ammo, ammo - shots, "firing did not spend exactly one round per shot")
	assert_eq(f.mp_left, expected_mp, "firing did not forfeit the rest of the action in progress")
	assert_true(f.fired_this_turn, "firing did not set the reveal flag")
	assert_true(f.activated, "firing did not end the unit's turn")


## Every refusal reason is reachable, and each names itself. `sim/` carries no English, so a wrong
## enum here is a wrong sentence on screen.
func test_every_refusal_reason_is_reachable() -> void:
	var md: MapData = _flat()

	var friendly: MatchState = _duel(md)
	friendly.add_unit(_unit(md, 1, 5, 12))
	assert_eq(FireAction.legality(md, cfg, sp, friendly, 0, 2), ActionResult.Status.FRIENDLY,
		"shooting a friend was allowed")
	assert_eq(FireAction.legality(md, cfg, sp, friendly, 0, 0), ActionResult.Status.FRIENDLY,
		"shooting itself was allowed")

	var no_ammo: MatchState = _duel(md)
	no_ammo.unit(0).ammo = 0
	assert_eq(FireAction.legality(md, cfg, sp, no_ammo, 0, 1), ActionResult.Status.NO_AMMO, "ammo")

	var broken: MatchState = _duel(md)
	broken.unit(0).gun_damaged = true
	assert_eq(FireAction.legality(md, cfg, sp, broken, 0, 1), ActionResult.Status.GUN_DAMAGED, "gun")

	var rough: MatchState = _duel(md)
	rough.unit(0).fire_blocked = true
	assert_eq(FireAction.legality(md, cfg, sp, rough, 0, 1), ActionResult.Status.FIRE_BLOCKED, "rough")

	var spent: MatchState = _duel(md)
	spent.unit(0).activated = true
	assert_eq(FireAction.legality(md, cfg, sp, spent, 0, 1), ActionResult.Status.ALREADY_ACTED, "acted")

	var dead: MatchState = _duel(md)
	dead.unit(1).alive = false
	assert_eq(FireAction.legality(md, cfg, sp, dead, 0, 1), ActionResult.Status.TARGET_GONE, "wreck")

	var idle: MatchState = _duel(md)
	assert_eq(FireAction.legality(md, cfg, sp, idle, 1, 0), ActionResult.Status.WRONG_SIDE, "side")

	# Not spotted: the side's contact list is what gates firing, not this gunner's eyes alone.
	var blind: MatchState = _duel(md)
	blind.knowledge_for(1).mark_lost(1, blind.unit(1).tile, Grid.N, 0)
	assert_eq(FireAction.legality(md, cfg, sp, blind, 0, 1), ActionResult.Status.NOT_VISIBLE, "unseen")

	# Out of arc: the target is behind the hull, and traversing that far means turning.
	var behind: MatchState = _duel(md)
	behind.unit(0).facing = Grid.W
	behind.unit(0).turret = Grid.W
	assert_eq(FireAction.legality(md, cfg, sp, behind, 0, 1), ActionResult.Status.OUT_OF_ARC, "arc")


## A gun that bears already does not emit a pointless traverse; one that does not, does.
func test_the_gun_is_laid_only_when_it_needs_laying() -> void:
	var md: MapData = _flat()
	var already: MatchState = _duel(md)
	var r: ActionResult = _resolver(md, already).resolve_fire(0, 1)
	for e: ActionEvent in r.events:
		assert_ne(e.kind, ActionEvent.Kind.TURRET, "an already-laid gun was traversed anyway")

	var off_axis: MatchState = _duel(md)
	off_axis.unit(0).turret = Grid.N
	var r2: ActionResult = _resolver(md, off_axis).resolve_fire(0, 1)
	var laid: bool = false
	for e2: ActionEvent in r2.events:
		if e2.kind == ActionEvent.Kind.TURRET:
			laid = true
			assert_eq(e2.facing, Grid.E, "the gun was laid somewhere other than at the target")
	assert_true(laid, "an off-axis gun was never traversed onto the target")
	assert_eq(off_axis.unit(0).turret, Grid.E, "the turret did not end up on the target")


# --- wrecks — docs/decisions/0031 -----------------------------------------------------------------

func test_a_wreck_blocks_its_tile_and_conceals_what_is_behind_it() -> void:
	var md: MapData = _flat()
	var m: MatchState = _duel(md)
	var t: int = m.unit(1).tile

	var before: int = Los.classify(md, cfg, m.unit(0).tile, md.idx(16, 12))
	assert_eq(before, Los.Exposure.EXPOSED, "the fixture is not clear ground to start with")

	EventApplier.apply(cfg, md, m, ActionEvent.destroyed(0, 1, t, 0))
	assert_false(m.unit(1).alive, "the target survived being destroyed")
	assert_gt(md.blocker_dyn[t], 0.0, "the wreck left no cover behind")

	assert_lt(float(Los.classify(md, cfg, m.unit(0).tile, md.idx(16, 12))), float(before),
		"a wreck conceals nothing behind it")
	assert_eq(m.unit_at(t), 1, "a wreck stopped occupying its tile")
	assert_eq(int(m.occupancy(md.n)[t]), 1, "a wreck stopped blocking its tile")
	assert_eq(m.side_units(2).size(), 0, "a wreck is still counted as a fighting unit")
	assert_false(m.is_selectable(1), "a wreck can still be selected")


## A wreck conceals a hull and leaves a turret — the same threshold light woods is chosen against.
## Below the hull line it is decoration; above the turret line, destroying a tank blinds everyone
## behind it.
func test_a_wreck_is_cover_and_not_a_wall() -> void:
	var wreck: float = cfg.f("combat.wreck_blocker_h_m", 2.0)
	assert_gt(wreck, cfg.f("visibility.hull_h_m", 1.4), "a wreck below the hull line covers nothing")
	assert_lt(wreck, cfg.f("visibility.turret_h_m", 2.6), "a wreck above the turret line is a wall")


## The assertion that keeps every pinned seed pinned. `blocker_dyn` is match state, so it must stay
## out of the map's identity — otherwise destroying a tank changes what map you are playing on.
func test_destroying_a_tank_does_not_change_the_map() -> void:
	var md: MapData = _flat()
	var m: MatchState = _duel(md)
	var before: String = md.content_hash()

	EventApplier.apply(cfg, md, m, ActionEvent.destroyed(0, 1, m.unit(1).tile, 0))
	assert_eq(md.content_hash(), before, "a wreck changed the map's content hash")


## An immobilised tank still fights and still traverses; it simply does not go anywhere again. A
## thrown track takes the hull, not the turret ring — docs/decisions/0029 and 0035.
func test_an_immobilised_tank_can_still_shoot_but_not_drive() -> void:
	var md: MapData = _flat()
	var m: MatchState = _duel(md)
	m.unit(0).immobilised = true

	assert_eq(MoveAction.legality(cfg, m, 0, md.idx(6, 12)), ActionResult.Status.IMMOBILISED,
		"an immobilised tank drove off")
	assert_eq(FireAction.legality(md, cfg, sp, m, 0, 1), ActionResult.Status.OK,
		"an immobilised tank could not shoot")
	assert_eq(
		TurretAction.legality(cfg, m, 0, posmod(m.unit(0).turret + 1, 8)),
		ActionResult.Status.OK,
		"an immobilised tank could not traverse its gun"
	)


# --- replay -------------------------------------------------------------------------------------

## Combat's arms are the non-idempotent ones — ammunition and shred — so this is where 0026's rule is
## most load-bearing. Applying a fire stream from the pre-action state must reproduce it exactly.
func test_replaying_a_fire_stream_reproduces_what_resolving_left() -> void:
	var md: MapData = _flat()
	var m: MatchState = _duel(md, "heavy", "light")
	var f: UnitState = m.unit(0)
	var t: UnitState = m.unit(1)

	var before: Array = [
		f.ammo, f.mp_left, f.activated, f.fired_this_turn, f.turret,
		t.alive, t.shaken_turns, t.immobilised, t.gun_damaged, t.shred_mm.duplicate(),
		md.blocker_dyn.duplicate(),
	]

	var r: ActionResult = _resolver(md, m).resolve_fire(0, 1)
	assert_true(r.ok(), "the shot was refused: %d" % r.status)
	var after: String = "%d %d %s %s %d | %s %d %s %s %s" % [
		f.ammo, f.mp_left, f.activated, f.fired_this_turn, f.turret,
		t.alive, t.shaken_turns, t.immobilised, t.gun_damaged, str(t.shred_mm),
	]

	f.ammo = before[0]; f.mp_left = before[1]; f.activated = before[2]
	f.fired_this_turn = before[3]; f.turret = before[4]
	t.alive = before[5]; t.shaken_turns = before[6]; t.immobilised = before[7]
	t.gun_damaged = before[8]; t.shred_mm = before[9]
	md.blocker_dyn = before[10]

	EventApplier.apply_all(cfg, md, m, r.events)
	var replayed: String = "%d %d %s %s %d | %s %d %s %s %s" % [
		f.ammo, f.mp_left, f.activated, f.fired_this_turn, f.turret,
		t.alive, t.shaken_turns, t.immobilised, t.gun_damaged, str(t.shred_mm),
	]
	assert_eq(replayed, after, "replaying a fire stream did not reproduce what resolving left")
