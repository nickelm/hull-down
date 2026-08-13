class_name Overwatch
extends RefCounted

## Reaction fire — docs/decisions/0030, and the thing 0003 says answers the alpha strike.
##
## A unit lays its gun down a bearing and gives up the rest of its turn for it. During the *enemy's*
## turn, the first mover that enters a tile inside that arc, in sight, gets shot at.
##
## This class decides **whether** a watcher fires. It does not decide what happens when it does —
## that is `HitResolver`, unchanged and unaware that this is not an ordinary shot beyond one
## multiplier. Keeping the trigger and the resolution apart is what stopped overwatch needing a second
## copy of the combat rules.
##
## No draws anywhere in here. The trigger is deterministic, exactly as spotting is, so a player can
## reason about where an ambush covers.


## Whether `unit_index` may go on overwatch along `aim_dir`.
static func legality(
	md: MapData, cfg: Config, state: MatchState, unit_index: int, aim_dir: int
) -> int:
	var u: UnitState = state.unit(unit_index)
	if u == null or not u.alive:
		return ActionResult.Status.NO_UNIT
	if u.side != state.active_side:
		return ActionResult.Status.WRONG_SIDE
	if u.activated:
		return ActionResult.Status.ALREADY_ACTED
	if u.gun_damaged:
		return ActionResult.Status.GUN_DAMAGED
	if u.ammo <= 0:
		return ActionResult.Status.NO_AMMO
	if aim_dir < 0:
		return ActionResult.Status.SAME_TILE
	# The gun has to be able to point there without turning the hull — 0027. Overwatch aims at a
	# place, and a place the turret cannot reach is not one you can promise to cover.
	if not u.can_bear_on(aim_dir, cfg):
		return ActionResult.Status.OUT_OF_ARC
	if u.fire_blocked:
		return ActionResult.Status.FIRE_BLOCKED
	return ActionResult.Status.OK


## Lay the gun and settle in. Costs the whole action in progress and ends the turn — 0003, and the
## reason overwatch is a real decision rather than something you do with a spare moment.
static func plan(cfg: Config, state: MatchState, unit_index: int, aim_dir: int) -> ActionResult:
	var r := ActionResult.new()
	r.unit = unit_index
	var u: UnitState = state.unit(unit_index)
	if u == null:
		r.status = ActionResult.Status.NO_UNIT
		return r

	r.status = ActionResult.Status.OK
	r.mp_before = u.mp_left
	r.mp_after = u.mp_after_action(cfg)

	r.events.append(ActionEvent.begin(unit_index, u.tile, u.facing, u.mp_left))
	if aim_dir != u.turret:
		r.events.append(ActionEvent.turret(unit_index, u.tile, aim_dir, u.mp_left))
	r.events.append(
		ActionEvent.watch(
			unit_index, u.tile, aim_dir, r.mp_after, cfg.i("combat.overwatch_shots", 1)
		)
	)
	r.events.append(ActionEvent.activated(unit_index, u.tile, u.facing, r.mp_after))
	r.events.append(ActionEvent.finish(unit_index, u.tile, u.facing, r.mp_after))
	return r


## Whether `watcher` shoots at `mover`, right now, where they both currently stand.
##
## Reads the live `MatchState` rather than taking a tile override, and that is the payoff of the weave
## applying as it walks (0026): by the time this is asked, the mover really is on the tile in
## question. An override parameter would have made this un-askable by an AI wanting a speculative
## answer.
static func triggers(
	md: MapData, cfg: Config, p: SpottingParams, state: MatchState, watcher: int, mover: int
) -> bool:
	var w: UnitState = state.unit(watcher)
	var m: UnitState = state.unit(mover)
	if w == null or m == null or not w.alive or not m.alive:
		return false
	if w.side == m.side:
		return false
	if w.overwatch_dir < 0 or w.overwatch_shots_left <= 0 or w.ammo <= 0 or w.gun_damaged:
		return false

	# Inside the lane the gun was laid down. Tighter than the turret's own arc: a watching gunner is
	# looking down a road, not sweeping the horizon.
	var bearing: int = Armor.bearing(md, w.tile, m.tile)
	if bearing < 0:
		return false
	if Grid.turn_steps(w.overwatch_dir, bearing) > cfg.i("combat.overwatch_arc_steps", 2):
		return false

	# And it has to be able to see it. Spotting runs before this on every step, so by now the
	# watcher's side either holds the contact or does not — but the *watcher* is the one shooting, so
	# this asks about the watcher rather than about its side.
	return Spotting.can_see(md, cfg, p, state, watcher, mover)


## Every unit that would fire at `mover` right now, in **ascending index order**.
##
## The order is the determinism guarantee. Two watchers covering the same lane must resolve in a
## fixed sequence, or which one gets the first shot depends on iteration order and the match stops
## being reconstructible from its seed.
static func watchers_against(
	md: MapData, cfg: Config, p: SpottingParams, state: MatchState,
	mover: int, out: PackedInt32Array
) -> void:
	out.clear()
	for k: int in state.units.size():
		if triggers(md, cfg, p, state, k, mover):
			out.append(k)
