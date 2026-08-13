class_name AiRunner
extends RefCounted

## The turn executor — docs/decisions/0038.
##
## Walks the active side's units in deployment order and asks that side's policy what each should do
## next, resolving every answer through the same `ActionResolver` entry points a click goes through.
## The AI therefore obeys every rule the player does, by construction: an illegal order is refused by
## the resolver, not vetoed by AI-specific code, and the legality tables stay in one place.
##
## This file and `AiView` are the two objects on the boundary — the only files under `sim/ai/`
## entitled to hold a `MatchState`. The scan in `tests/test_ai_scaffold.gd` names them as its
## allowlist. `AiRunner` builds the view, feeds the policy, and applies the answers; the policy
## never sees the board, only the view.
##
## Deliberately does NOT call `end_turn`. The caller owns the turn boundary for the same reason the
## player's End Turn button does: a game layer wants to replay the collected streams before the
## hand-over, and a headless match loop wants to interleave victory checks. One entry point that
## did both would be convenient exactly until either of those wanted to happen between.

## Orders one unit may be given in one turn before the runner stands it down. A guard against a
## policy that answers TURRET forever — traversing is free, so nothing else would terminate it.
## Generous on purpose: a legitimate turn is two or three orders, and a policy hitting this cap is
## buggy, not ambitious.
const MAX_ORDERS_PER_UNIT := 8


## Run one full turn for the active side. Returns every committed result, in resolution order —
## the streams a game layer filters and replays, exactly as a human turn produces them one by one.
static func run_turn(resolver: ActionResolver, policy: Policy) -> Array[ActionResult]:
	return _run(resolver, policy, 0, [])


## As `run_turn`, but each committed result is paired with the events `spectator` is entitled to
## watch of it, filtered against that side's knowledge **as it stood before the order resolved** —
## the ordering `tests/test_replay_filter.gd` pins for the human's own orders, applied here per AI
## order for the same reason: an AI side resolves its whole turn before a frame is drawn, so a mask
## taken any later says everything the turn revealed had been visible all along (0034).
##
## Entries are `{ "result": ActionResult, "events": Array[ActionEvent] }`, ready for
## `ActionQueue.submit`.
static func run_turn_watched(
	resolver: ActionResolver, policy: Policy, spectator: int
) -> Array[Dictionary]:
	var watched: Array[Dictionary] = []
	_run(resolver, policy, spectator, watched)
	return watched


static func _run(
	resolver: ActionResolver, policy: Policy, spectator: int, out_watched: Array[Dictionary]
) -> Array[ActionResult]:
	var out: Array[ActionResult] = []
	var state: MatchState = resolver.state
	var side: int = state.active_side
	var view: AiView = AiView.create(resolver, side)

	# Snapshot the roster before anything moves. A unit killed by overwatch mid-turn stays in the
	# list and is skipped by the liveness check below — mutating the list under the walk would be
	# the same bug `side_units` re-queried per unit would hide.
	var roster: PackedInt32Array = state.side_units(side)

	for k: int in roster.size():
		var unit_index: int = roster[k]
		for _hop: int in MAX_ORDERS_PER_UNIT:
			var u: UnitState = state.unit(unit_index)
			if u == null or not u.alive or u.activated:
				break

			var order: AiOrder = policy.decide(view, unit_index)
			if order == null or order.kind == AiOrder.Kind.PASS:
				# A pass is a decision, not an absence of one — the unit is stood down so the turn
				# provably terminates and `all_activated` means what it says.
				state.mark_activated(unit_index)
				break

			# The mask belongs to the moment before the action happens — see run_turn_watched.
			var mask := PackedByteArray()
			if spectator > 0:
				mask = ViewState.all(state, spectator)

			var r: ActionResult = _resolve(resolver, order)
			if r != null and r.ok():
				out.append(r)
				if spectator > 0:
					out_watched.append({
						"result": r,
						"events": ViewState.filter(r.events, mask, spectator),
					})
			else:
				# A refused order means the policy's picture and the rules disagree — stale
				# knowledge, or a bug. Stand the unit down rather than ask again: the policy that
				# produced an illegal answer once will produce it again, and a loop of refusals
				# would spin the cap down for nothing.
				state.mark_activated(unit_index)
				break

		# The cap tripping leaves the unit un-activated; close it out so the turn always ends.
		var left: UnitState = state.unit(unit_index)
		if left != null and left.alive and not left.activated:
			state.mark_activated(unit_index)

	return out


## One order, through the one entry point its kind maps onto.
static func _resolve(resolver: ActionResolver, order: AiOrder) -> ActionResult:
	match order.kind:
		AiOrder.Kind.MOVE:
			return resolver.resolve_move(order.unit, order.goal_tile)
		AiOrder.Kind.FIRE:
			return resolver.resolve_fire(order.unit, order.target)
		AiOrder.Kind.OVERWATCH:
			return resolver.resolve_overwatch(order.unit, order.bearing)
		AiOrder.Kind.TURRET:
			return resolver.resolve_turret(order.unit, order.bearing)
	return null
