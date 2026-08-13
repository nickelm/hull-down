class_name TurretAction
extends RefCounted

## Traversing the gun — docs/decisions/0035, which supersedes 0032.
##
## Free, unlimited within the arc, and legal at zero movement points. That combination is the whole
## point: a tank that has spent everything and is facing the wrong way still has a decision left,
## because it can still bring its gun to bear. What it cannot do is turn its hull, and that is the
## trade — the armor you present is settled by where you *drove*, and only movement changes it.
##
## The hull swivel this replaces (0032) got the split backwards. It gave away a free 45° of hull for
## nothing but the loss of overwatch, which meant a tank could reorient its armor after seeing the
## board, and flanking quietly stopped being about position. Rotating the turret gives the same relief
## from the feel-bad without touching the armor facing at all.
##
## **Unlimited, and deliberately uncapped.** A cap would be arithmetic in search of a reason: the arc
## already bounds where the gun can point (`combat.turret_arc_steps`, ±135° from the hull — 0027), and
## within that a crew traverses as often as it likes in the time a turn represents. What is scarce is
## hull rotation, and that has a price already.
##
## Takes an **absolute** bearing rather than a number of notches, because that is what `UnitState.turret`
## stores and what `Overwatch` lays along. A relative order would have to be resolved against the
## current bearing somewhere, and doing it at the call site is how the two drift (0027).


## Whether `unit` may lay its gun on `bearing`.
##
## Deliberately does **not** refuse an activated unit or one out of movement points. Being spent is
## precisely the case this exists for.
static func legality(cfg: Config, state: MatchState, unit_index: int, bearing: int) -> int:
	var u: UnitState = state.unit(unit_index)
	if u == null:
		return ActionResult.Status.NO_UNIT
	# A wreck takes no orders. `NO_UNIT` rather than `TARGET_GONE`, which is about something being shot
	# at rather than about something being told what to do.
	if not u.alive:
		return ActionResult.Status.NO_UNIT
	if u.side != state.active_side:
		return ActionResult.Status.WRONG_SIDE
	if bearing < 0 or bearing >= Grid.DX.size():
		return ActionResult.Status.NO_ROUTE
	# Already there. Refused rather than emitted as a zero-length stream, for the reason `SAME_TILE`
	# exists on a move: an order that changes nothing should not produce an account of having happened.
	if bearing == u.turret:
		return ActionResult.Status.SAME_TILE
	# Measured from the **hull**, not from where the gun currently points — the arc is a property of the
	# mounting, and a turret does not earn extra travel by having already traveled (0027).
	if not u.can_bear_on(bearing, cfg):
		return ActionResult.Status.OUT_OF_ARC
	return ActionResult.Status.OK


## Build the stream. Pure, like every `plan`.
static func plan(cfg: Config, state: MatchState, unit_index: int, bearing: int) -> ActionResult:
	var r := ActionResult.new()
	r.unit = unit_index
	r.status = legality(cfg, state, unit_index, bearing)
	if r.status != ActionResult.Status.OK:
		return r

	var u: UnitState = state.unit(unit_index)
	r.mp_before = u.mp_left
	r.mp_after = u.mp_left

	# `BEGIN` and `END` both carry the **hull** facing, which this action does not touch. That is not a
	# formality: `ActionPlayer` seeds its hull interpolation from `BEGIN.facing`, so naming the turret
	# bearing here would swing the whole tank.
	r.events.append(ActionEvent.begin(unit_index, u.tile, u.facing, u.mp_left))
	r.events.append(ActionEvent.turret(unit_index, u.tile, bearing, u.mp_left))

	# A watching tank re-lays its watch along the new bearing rather than losing it.
	#
	# 0032 made the free hull turn *cancel* overwatch, because without that price a watcher re-aimed for
	# free every turn and "overwatch costs your whole turn" stopped meaning anything. That argument does
	# not carry over, for two reasons. The bearing a unit watches down **is** where its gun points, so
	# leaving them disagreed would be a bug rather than a cost. And orders are only issued on your own
	# turn: re-aiming between the moment you lay the ambush and the moment you end the turn tells you
	# nothing you did not already know when you laid it.
	if u.overwatch_dir >= 0:
		r.events.append(
			ActionEvent.watch(unit_index, u.tile, bearing, u.mp_left, u.overwatch_shots_left)
		)

	r.events.append(ActionEvent.finish(unit_index, u.tile, u.facing, u.mp_left))
	return r
