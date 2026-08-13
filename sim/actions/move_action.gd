class_name MoveAction
extends RefCounted

## The rules of one move: whether it is allowed, what it would consist of, and applying it.
##
## All static, and split three ways on purpose — docs/decisions/0022.
##
##   `legality`  asks a question and allocates nothing. The click handler and an iteration-2 AI ask
##               it identically, which they could not do while the answers were interleaved with the
##               strings that reported them.
##   `plan`      is pure. It builds the whole event stream without touching `MatchState`, so the
##               hover preview may call it on every mouse move and a search may call it a thousand
##               times, with no consequence for anything.
##   `commit`    walks the events into the state. It is the only thing that mutates.
##
## `commit` replaying the events, rather than applying the path wholesale, is what makes "the event
## stream is the authoritative account of what happened" a property a test can check. It is also the
## shape iteration 2 needs: an interruption that stops the unit at the sixth tile is the remaining
## events not being applied, and needs no special case anywhere.


## Whether `unit_index` may be ordered to `goal_tile`.
##
## `reach` is the reachable set from `ActionResolver.reachable`, and may be empty — the caller
## usually has one already because the movement overlay is drawn from it, and passing it turns a
## hopeless order into an answer without running a search. When it is empty the check is simply
## skipped and an unreachable goal comes back as `NO_ROUTE` from the search instead.
static func legality(
	cfg: Config, state: MatchState, unit_index: int, goal_tile: int,
	reach: PackedInt32Array = PackedInt32Array()
) -> int:
	var u: UnitState = state.unit(unit_index)
	if u == null:
		return ActionResult.Status.NO_UNIT
	if u.side != state.active_side:
		return ActionResult.Status.WRONG_SIDE
	if not u.alive:
		return ActionResult.Status.NO_UNIT
	if u.activated:
		return ActionResult.Status.ALREADY_ACTED
	# A thrown track is permanent. The unit still fights, still turns its turret, and still takes its
	# free hull step — it simply does not go anywhere again. docs/decisions/0029.
	if u.immobilised:
		return ActionResult.Status.IMMOBILISED
	if not u.can_act(cfg):
		return ActionResult.Status.NO_MOVEMENT
	if goal_tile < 0 or goal_tile == u.tile:
		return ActionResult.Status.SAME_TILE

	# Ahead of the reachability check, because an occupied tile is also an unreachable one — it is a
	# blocker in the flood fill — and "someone is standing there" is the more useful of the two
	# true answers.
	if state.unit_at(goal_tile) >= 0:
		return ActionResult.Status.OCCUPIED

	if goal_tile < reach.size() and reach[goal_tile] < 0:
		return ActionResult.Status.UNREACHABLE
	return ActionResult.Status.OK


## Build the full event stream for an uninterrupted move. Changes nothing.
static func plan(
	md: MapData, cfg: Config, state: MatchState, pf: TankPathfinder,
	unit_index: int, goal_tile: int,
	reach: PackedInt32Array = PackedInt32Array(),
	blockers: PackedByteArray = PackedByteArray()
) -> ActionResult:
	var r := ActionResult.new()
	r.unit = unit_index
	r.status = legality(cfg, state, unit_index, goal_tile, reach)
	if r.status != ActionResult.Status.OK:
		return r

	var u: UnitState = state.unit(unit_index)
	r.mp_before = u.mp_left
	r.mp_after = u.mp_left

	r.path = pf.find_path(u.tile, u.facing, goal_tile, u.mp_left, blockers)
	if not r.path.found or r.path.length() < 2:
		r.status = ActionResult.Status.NO_ROUTE
		r.path = null
		return r

	_build_events(md, cfg, r, u, unit_index)
	return r


## Turn a route into the ordered account of driving it.
##
## `facings[k]` is the heading the tank *departs* `tiles[k]` with, because `find_path` collapses
## turn-in-place states and keeps the last facing held on each tile. So the turn on a tile comes
## before the step off it, and the step into the next tile is made on that same heading — driving
## does not change which way a hull points, which is what makes a reverse leg need no special case.
static func _build_events(
	md: MapData, cfg: Config, r: ActionResult, u: UnitState, unit_index: int
) -> void:
	var path: PathResult = r.path
	var last: int = path.tiles.size() - 1
	var mp: int = u.mp_left

	# The turret is dragged, never searched for — docs/decisions/0027. Its whole track is a pure
	# function of the hull's, so it is reconstructed here by a linear walk rather than being a second
	# axis in `find_path`. That is what keeps this function pure and the hover preview able to show
	# the gun swinging before the player commits to the move.
	var arc: int = cfg.i("combat.turret_arc_steps", 3)
	var turret: int = u.turret

	r.events.append(ActionEvent.begin(unit_index, path.tiles[0], u.facing, mp))

	for k: int in path.tiles.size():
		var tc: int = path.turn_cost[k]
		if tc > 0:
			mp = maxi(mp - tc, 0)
			r.events.append(ActionEvent.turn(unit_index, path.tiles[k], path.facings[k], tc, mp))

			# After the hull, because the drag is a consequence of where the hull ended up. A turret
			# already inside the arc emits nothing at all, which is the common case.
			var dragged: int = UnitState.clamp_turret(path.facings[k], turret, arc)
			if dragged != turret:
				turret = dragged
				r.events.append(ActionEvent.turret(unit_index, path.tiles[k], turret, mp))
		if k >= last:
			continue

		var from_tile: int = path.tiles[k]
		var to_tile: int = path.tiles[k + 1]
		var sc: int = path.step_cost[k + 1]
		mp = maxi(mp - sc, 0)

		var flags: int = 0
		if path.reversed[k + 1] == 1:
			flags |= ActionEvent.F_REVERSED
		var travel: int = Grid.dir_between(
			md.tx(from_tile), md.ty(from_tile), md.tx(to_tile), md.ty(to_tile)
		)
		if travel >= 0 and md.transition(from_tile, travel) == MapData.Trans.ROUGH:
			flags |= ActionEvent.F_ROUGH

		r.events.append(
			ActionEvent.step(unit_index, to_tile, path.facings[k], sc, mp, flags)
		)

	r.mp_after = mp
	close_stream(cfg, r.events, unit_index, path.destination(), path.final_facing(), mp)


## Close a movement stream off wherever it actually stopped: mark the unit spent if it is, then say
## the action is over.
##
## Extracted so that the tail has exactly one implementation. The resolver's weave truncates a move
## by simply not appending the rest of it, and then calls this against the tile the tank really
## reached — so an interrupted stream is a complete, self-consistent account of a *shorter* move
## rather than a full one with the end torn off. `commit` never learns an interruption happened,
## which is what 0022 predicted and 0026 made true.
##
## The activation test is arithmetic and it is emitted here, which is the whole point: by the time
## the stream is applied the unit is marked, and no view was involved in deciding it.
static func close_stream(
	cfg: Config, events: Array[ActionEvent], unit_index: int, tile: int, facing: int, mp: int
) -> void:
	if mp < cfg.i("movement.base_ortho", 10):
		events.append(ActionEvent.activated(unit_index, tile, facing, mp))
	events.append(ActionEvent.finish(unit_index, tile, facing, mp))


## Apply a planned result. Returns false if there was nothing to apply or it has already been
## applied — spending a result twice would double-charge the movement points.
##
## The `match` that used to live here is now `EventApplier.apply` (docs/decisions/0026). This is not
## a thinner `commit`, it is a `commit` that has stopped being the *definition* of what an event
## means and gone back to being what 0022 said it was: the thing that walks a stream into the state.
## A resolver that interleaves other units' reactions applies each event as it appends it, and it has
## to reach the same definition this does or the two drift.
static func commit(
	cfg: Config, md: MapData, state: MatchState, result: ActionResult
) -> bool:
	if result == null or result.committed or not result.ok():
		return false
	if state.unit(result.unit) == null:
		return false

	EventApplier.apply_all(cfg, md, state, result.events)
	result.committed = true
	return true
