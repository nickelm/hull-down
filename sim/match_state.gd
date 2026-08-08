class_name MatchState
extends RefCounted

## Who is on the board, whose turn it is, and which unit is selected.
##
## Iteration 1 is hot-seat: two units a side, side-alternating, and the player drives both sides
## because there is no AI yet (docs/decisions/0012). Ending a turn hands control over rather than
## triggering anything.
##
## Pure data, like everything in `sim/`. The view layer reads this and follows it; it never reaches
## back. Selection lives here rather than in `PlayerController` so that "which unit is selected"
## and "whose turn is it" cannot disagree — the controller used to hold a `_selected: bool` that
## nothing read, which is what happens when that state has no owner.


var units: Array[UnitState] = []
var turn: int = 1
var active_side: int = 1
var side_count: int = 2
## Index into `units`, or -1 when nothing is selected.
var selected: int = -1


static func create(sides: int = 2) -> MatchState:
	var m := MatchState.new()
	m.side_count = maxi(sides, 1)
	return m


func add_unit(u: UnitState) -> int:
	units.append(u)
	return units.size() - 1


func unit(index: int) -> UnitState:
	if index < 0 or index >= units.size():
		return null
	return units[index]


func selected_unit() -> UnitState:
	return unit(selected)


## Indices of one side's units, in deployment order.
func side_units(side: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: int in units.size():
		if units[k].side == side:
			out.append(k)
	return out


## Select a unit, if it belongs to the side whose turn it is. Returns false and changes nothing
## otherwise — an inactive side's units are inspectable on the map but not orderable.
func select(index: int) -> bool:
	var u: UnitState = unit(index)
	if u == null or u.side != active_side:
		return false
	selected = index
	return true


func is_selectable(index: int) -> bool:
	var u: UnitState = unit(index)
	return u != null and u.side == active_side


## Step the selection through the active side's units, wrapping. Returns the new index, or -1 if
## the side has no units at all.
##
## Units that have already acted are skipped on the first sweep, so Tab walks the units still worth
## giving orders to. Once every one of them is done it falls back to plain wraparound, because a
## Tab that does nothing reads as a broken key rather than as a finished turn.
func cycle(step: int) -> int:
	var side: PackedInt32Array = side_units(active_side)
	if side.is_empty():
		return -1

	var n: int = side.size()
	var at: int = -1
	for k: int in n:
		if side[k] == selected:
			at = k
			break

	var dir: int = 1 if step >= 0 else -1
	# With nothing selected, start one step behind the direction of travel so the first hop lands
	# on the first unit rather than skipping it.
	var base: int = at if at >= 0 else posmod(-dir, n)

	for hop: int in range(1, n + 1):
		var cand: int = side[posmod(base + dir * hop, n)]
		if not units[cand].activated:
			selected = cand
			return cand

	selected = side[posmod(base + dir, n)]
	return selected


func mark_activated(index: int) -> void:
	var u: UnitState = unit(index)
	if u != null:
		u.activated = true


## Units on the active side that can still be given an order.
func remaining_on_side() -> int:
	var left: int = 0
	for k: int in units.size():
		if units[k].side == active_side and not units[k].activated:
			left += 1
	return left


func all_activated() -> bool:
	return remaining_on_side() == 0


## Hand over to the next side that has any units, restore its movement points, and select its first
## unit that can still act.
##
## The side search is bounded by `side_count` and skips empty sides, so a match set up with only one
## side populated still advances the turn counter and refills movement points instead of stalling.
func end_turn() -> void:
	for k: int in units.size():
		if units[k].side == active_side:
			units[k].activated = true

	for _hop: int in side_count:
		active_side += 1
		if active_side > side_count:
			active_side = 1
			turn += 1
		if not side_units(active_side).is_empty():
			break

	for k2: int in units.size():
		if units[k2].side == active_side:
			units[k2].begin_turn()

	selected = -1
	var side: PackedInt32Array = side_units(active_side)
	if not side.is_empty():
		selected = side[0]


## The unit standing on a tile, or -1. Linear over a handful of units; there is no index to keep in
## sync and nothing calls this in a hot loop.
func unit_at(tile: int) -> int:
	for k: int in units.size():
		if units[k].tile == tile:
			return k
	return -1
