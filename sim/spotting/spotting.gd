class_name Spotting
extends RefCounted

## Who can see whom — docs/decisions/0024, and docs/design/rules.md 3.3.
##
## **There is no spotting roll.** A target is seen when some living unit of the observing side has
## line of sight to it and the range is inside that observer's effective spotting range. Nothing here
## touches an RNG, and `tests/test_determinism`'s source scan enforces the letter of it.
##
## Being deterministic is not merely a determinism convenience. It is what lets the move preview say
## *where you will be seen* before you commit to driving there — `plan_move` is pure, so it may ask
## this question on every mouse move, and a roll would make the answer it gave a lie half the time.
##
## Effective range is the observer's optics multiplied by three modifiers, and **all three are
## properties of the target**:
##
##   * the concealment of the ground it stands on, per movement class (data/terrain.json, 0028)
##   * how hard it drove this turn, as a ramp from stationary to flat out
##   * how exposed it is *to this observer* — hull down is harder to see than in the open
##
## Which makes spotting **asymmetric**: A seeing B implies nothing about B seeing A. Different optics,
## different ground, different exposure, and the whole reason a recon vehicle has a job.

## Whether `observer` can see `target` right now. The single-pair question, and the one an AI asks
## speculatively — it mutates nothing.
static func can_see(
	md: MapData, cfg: Config, p: SpottingParams, state: MatchState, observer: int, target: int
) -> bool:
	var o: UnitState = state.unit(observer)
	var t: UnitState = state.unit(target)
	if o == null or t == null or o == t:
		return false
	# A wreck is terrain now, not a contact. It still blocks and conceals — through `blocker_dyn`,
	# which `Los` already reads — but nobody spots it and nobody shoots at it. 0031.
	if not o.alive or not t.alive:
		return false
	# A wave that has not arrived is not on the board to see or be seen — 2g.
	if not o.on_board or not t.on_board:
		return false

	# A muzzle flash is not subtle. Having fired, a unit is seen by anything that can see the ground
	# it is standing on, **at any range**, until the start of its own next turn — which is what makes
	# firing a commitment rather than a free action.
	#
	# This is read before the range test rather than after it, and that ordering is the rule. A firer
	# hiding in heavy woods is exactly the case worth revealing, and it is also exactly the case the
	# early-out below would have thrown away first. Line of sight still applies, though: you cannot
	# see a flash through a hill.
	var revealed: bool = t.fired_this_turn

	var dist: float = md.dist_m(o.tile, t.tile)

	# The early-out, and the reason `test_config` pins every exposure multiplier at or below 1.0.
	# Exposure can only ever shrink a range, so a target already beyond the pre-exposure range is
	# beyond every version of it — and can be rejected without casting a ray. On a 2 km map that
	# prunes most pairs before touching the expensive half of this function.
	var reach: float = target_range_m(md, cfg, p, state, observer, target)
	if not revealed and dist > reach and dist > p.point_blank_m:
		return false

	var exposure: int = Los.classify(md, cfg, o.tile, t.tile)
	if exposure == Los.Exposure.MASKED:
		return false
	# A dug-in tank is hull down whatever the ground says — 2f, docs/decisions/0041. Clamped here
	# and in `exposure_between`, the two places geometry becomes exposure, and nowhere else.
	if t.entrenched and exposure == Los.Exposure.EXPOSED:
		exposure = Los.Exposure.HULL_DOWN

	if revealed or dist <= p.point_blank_m:
		return true
	return dist <= reach * p.exposure_mult[exposure]


## The range this target could be seen at before its exposure to any particular observer is known:
## optics x ground x movement. Needs no line of sight, which is what makes it a legal early-out.
static func target_range_m(
	md: MapData, cfg: Config, p: SpottingParams, state: MatchState, observer: int, target: int
) -> float:
	var o: UnitState = state.unit(observer)
	var t: UnitState = state.unit(target)
	if o == null or t == null:
		return 0.0
	var range_m: float = (
		optics_m(cfg, o)
		* cfg.concealment(t.movement_class, md.terrain[t.tile])
		* p.movement_mult(t.mp_moved, t.mp_max)
	)
	# Entrenchment is camouflage on top of whatever the ground gives — 2f. A multiplier at or below
	# 1.0 (tests/test_config pins it), so the early-out this range feeds stays sound.
	if t.entrenched:
		range_m *= cfg.f("entrenchment.concealment_mult", 0.5)
	return range_m


## The full effective range, exposure included. What the distance is actually compared against.
static func effective_range_m(
	md: MapData, cfg: Config, p: SpottingParams, state: MatchState,
	observer: int, target: int, exposure: int
) -> float:
	if exposure <= Los.Exposure.MASKED:
		return 0.0
	var e: int = clampi(exposure, 0, p.exposure_mult.size() - 1)
	return target_range_m(md, cfg, p, state, observer, target) * p.exposure_mult[e]


## The observer's own contribution: what its optics are worth in the open against a stationary target.
static func optics_m(cfg: Config, o: UnitState) -> float:
	var optics: Dictionary = cfg.unit(String(o.unit_type)).get("optics", {})
	return float(optics.get("base_range_m", 0.0))


## Exposure of `target` as `observer` sees it. This is the seam the dug-in stance was promised —
## an entrenched target is hull down whatever the geometry says (2f, docs/decisions/0041) — and
## `FireAction` reads exposure through here for that reason, so a gun and an eye agree about what a
## dug-in tank presents.
static func exposure_between(
	md: MapData, cfg: Config, state: MatchState, observer: int, target: int
) -> int:
	var o: UnitState = state.unit(observer)
	var t: UnitState = state.unit(target)
	if o == null or t == null:
		return Los.Exposure.MASKED
	var exposure: int = Los.classify(md, cfg, o.tile, t.tile)
	if t.entrenched and exposure == Los.Exposure.EXPOSED:
		return Los.Exposure.HULL_DOWN
	return exposure


## Bring one side's knowledge up to date against the board as it stands, and report what changed.
##
## Mutates `state.knowledge[side]`, which is the point — this is the only thing outside `EventApplier`
## entitled to. The deltas come back in the caller's arrays so that a fifteen-tile move does not
## allocate thirty of them, and so the weave can turn each one into an event.
##
## Returns true if anything changed at all, which is the cheap test for "was this step worth an
## event".
static func recompute_side(
	md: MapData, cfg: Config, p: SpottingParams, state: MatchState, side: int,
	out_gained: PackedInt32Array, out_lost: PackedInt32Array
) -> bool:
	out_gained.clear()
	out_lost.clear()

	var k: SideKnowledge = state.knowledge_for(side)
	if k == null:
		return false

	var observers: PackedInt32Array = state.side_units(side)
	for target: int in state.units.size():
		var t: UnitState = state.units[target]
		if t.side == side:
			continue

		var seen: bool = false
		for oi: int in observers.size():
			if can_see(md, cfg, p, state, observers[oi], target):
				seen = true
				break

		if seen:
			if k.mark_seen(target):
				out_gained.append(target)
		elif k.sees(target):
			# The freeze happens here because here is the last moment the position was true.
			if k.mark_lost(target, t.tile, t.facing, p.ghost_turns):
				out_lost.append(target)

	return not (out_gained.is_empty() and out_lost.is_empty())


## Every side's knowledge, refreshed. The turn-boundary sweep, and the belt to the event stream's
## braces — it is idempotent, it costs nothing next to a turn change, and it is what catches a contact
## that changed for a reason no event described.
static func recompute_all(md: MapData, cfg: Config, p: SpottingParams, state: MatchState) -> void:
	var gained := PackedInt32Array()
	var lost := PackedInt32Array()
	for side: int in range(1, state.side_count + 1):
		recompute_side(md, cfg, p, state, side, gained, lost)
