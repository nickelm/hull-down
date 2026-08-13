class_name FireAction
extends RefCounted

## The rules of one firing action.
##
## Mirrors `MoveAction`'s three-way split with one honest asymmetry, and the asymmetry is worth
## stating rather than hiding: **`MoveAction` can `plan` its whole stream because a move is
## deterministic. Firing cannot, because the stream depends on rolls.** So `preview` takes the place
## of `plan` for the pure half — everything the player needs to decide, computed without a draw — and
## the stream itself is built in `resolve`.
##
## Firing costs a whole action point and therefore forfeits the unused remainder of the action in
## progress (0021, and `UnitState.commit_action` finally has its first caller). It also ends the
## unit's turn (0003), which is what overwatch exists to answer and the reason overwatch costs the
## same.


## Whether `firer` may shoot at `target`, as a `Status`. Allocates nothing; an AI asks this in a loop.
static func legality(
	md: MapData, cfg: Config, sp: SpottingParams, state: MatchState, firer: int, target: int
) -> int:
	var f: UnitState = state.unit(firer)
	var t: UnitState = state.unit(target)
	if f == null or t == null:
		return ActionResult.Status.NO_UNIT
	if not f.alive:
		return ActionResult.Status.NO_UNIT
	if f.side != state.active_side:
		return ActionResult.Status.WRONG_SIDE
	if f.activated:
		return ActionResult.Status.ALREADY_ACTED
	if firer == target or t.side == f.side:
		return ActionResult.Status.FRIENDLY
	if not t.alive:
		return ActionResult.Status.TARGET_GONE
	if f.gun_damaged:
		return ActionResult.Status.GUN_DAMAGED
	if f.ammo <= 0:
		return ActionResult.Status.NO_AMMO
	# rules.md 2.4: a unit that crossed a rough transition this turn cannot fire. Computed as
	# `PathResult.blocks_firing` since iteration 1 and read here for the first time.
	if f.fire_blocked:
		return ActionResult.Status.FIRE_BLOCKED

	# The side has to know it is there. Knowledge is side-level (0024), so any of your units having
	# seen it is enough — which is exactly the point of spotting coming before combat.
	var k: SideKnowledge = state.knowledge_for(f.side)
	if k == null or not k.sees(target):
		return ActionResult.Status.NOT_VISIBLE

	# The gun has to bear. A question about the *hull*, because traversing inside the arc is free —
	# docs/decisions/0027.
	if not f.can_bear_on(Armor.bearing(md, f.tile, t.tile), cfg):
		return ActionResult.Status.OUT_OF_ARC

	# And this firer, specifically, has to be able to see it. Side-level knowledge says the tank is
	# there; it does not say this gunner can lay on it.
	if Los.classify(md, cfg, f.tile, t.tile) == Los.Exposure.MASKED:
		return ActionResult.Status.NOT_VISIBLE
	return ActionResult.Status.OK


## Everything the player needs before committing. Pure, and safe to call on every mouse move.
static func preview(
	md: MapData, cfg: Config, sp: SpottingParams, hp: HitParams,
	state: MatchState, firer: int, target: int
) -> FireForecast:
	var out := FireForecast.new()
	out.status = legality(md, cfg, sp, state, firer, target)
	if not out.ok():
		return out

	var f: UnitState = state.unit(firer)
	var t: UnitState = state.unit(target)

	# Through the spotting seam, not raw geometry: an entrenched target is hull down to the gun
	# exactly as it is to the eye — 2f, docs/decisions/0041.
	out.exposure = Spotting.exposure_between(md, cfg, state, firer, target)
	out.range_m = md.dist_m(f.tile, t.tile)
	out.hit_chance = HitResolver.hit_chance(md, cfg, hp, state, firer, target, out.exposure, false)

	out.facing_struck = Armor.facing_struck(t.facing, Armor.bearing(md, t.tile, f.tile))
	out.plate_mm = Armor.current_mm(cfg, t, out.facing_struck)
	out.pen_mm = HitResolver.penetration_at_m(cfg, hp, f.unit_type, out.range_m)
	out.pen_chance = HitResolver.pen_chance(hp, out.pen_mm, out.plate_mm)
	out.shots = shots_for(cfg, f)
	return out


## Rounds one firing action puts downrange. `gun.shots_per_action`, capped by what is in the racks —
## a two-shot gun with one round left fires one.
static func shots_for(cfg: Config, f: UnitState) -> int:
	var gun: Dictionary = cfg.unit(String(f.unit_type)).get("gun", {})
	return maxi(mini(int(gun.get("shots_per_action", 1)), f.ammo), 1)


## Fire. Rolls, and builds the stream; changes nothing itself.
##
## The caller applies it — `ActionResolver.resolve_fire` — for the same reason `HitResolver` emits
## rather than writes: it keeps exactly one place that knows how an event changes the world (0026).
static func resolve(
	md: MapData, cfg: Config, sp: SpottingParams, hp: HitParams, state: MatchState,
	rng: RandomNumberGenerator, crit_rng: RandomNumberGenerator, firer: int, target: int
) -> ActionResult:
	var r := ActionResult.new()
	r.unit = firer
	r.status = legality(md, cfg, sp, state, firer, target)
	if r.status != ActionResult.Status.OK:
		return r

	var f: UnitState = state.unit(firer)
	var t: UnitState = state.unit(target)
	r.mp_before = f.mp_left
	r.mp_after = f.mp_after_action(cfg)

	r.events.append(ActionEvent.begin(firer, f.tile, f.facing, f.mp_left))

	# Lay the gun. Free and within the arc, which `legality` has already checked — so this is the
	# turret catching up with a decision already made, not a cost.
	var bearing: int = Armor.bearing(md, f.tile, t.tile)
	if bearing >= 0 and bearing != f.turret:
		r.events.append(ActionEvent.turret(firer, f.tile, bearing, f.mp_left))

	# The same seam the preview reads, so the two cannot disagree about a dug-in target (0041).
	var exposure: int = Spotting.exposure_between(md, cfg, state, firer, target)
	var shots: int = shots_for(cfg, f)
	for k: int in shots:
		# Re-read exposure per shot, but not the target's state: `HitResolver` is stationary by
		# design and the events of shot one have not been applied yet when shot two is rolled. A
		# two-shot gun therefore fires both rounds at the tank as it was, which is what "one action"
		# means and is also what keeps the statistical test honest.
		HitResolver.resolve_shot(
			md, cfg, hp, state, rng, crit_rng, firer, target, exposure, k, false, r.events
		)
		if _destroyed_in(r.events, target):
			break

	if hp.shots_end_the_turn:
		r.events.append(ActionEvent.activated(firer, f.tile, f.facing, r.mp_after))
	r.events.append(ActionEvent.finish(firer, f.tile, f.facing, r.mp_after))
	return r


## Whether the stream so far has killed `target`. Stops a two-shot gun putting its second round into
## a wreck, which would waste ammunition and read as the gunner not noticing.
static func _destroyed_in(events: Array[ActionEvent], target: int) -> bool:
	for e: ActionEvent in events:
		if e.kind == ActionEvent.Kind.DESTROYED and e.other == target:
			return true
	return false
